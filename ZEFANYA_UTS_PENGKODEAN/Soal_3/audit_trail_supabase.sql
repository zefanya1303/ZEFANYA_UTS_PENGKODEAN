
-- =====================================================
-- 3.2 AUDIT TRAIL & IMMUTABILITY
-- Voucher Entri Transaksi Kas Keluar
-- Database: Supabase / PostgreSQL
-- =====================================================

-- 1. Mengaktifkan ekstensi untuk hash SHA-256
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- 2. Membuat tabel voucher jurnal
CREATE TABLE IF NOT EXISTS journal_vouchers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no VARCHAR(50) UNIQUE NOT NULL,
    transaction_date DATE NOT NULL,
    description TEXT,

    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT', 'POSTED', 'REVERSED')),

    created_by UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    posted_by UUID,
    posted_at TIMESTAMPTZ,

    reversal_of UUID REFERENCES journal_vouchers(id),
    hash_checksum TEXT
);


-- 3. Membuat tabel detail jurnal
CREATE TABLE IF NOT EXISTS journal_details (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    voucher_id UUID NOT NULL
        REFERENCES journal_vouchers(id),

    account_code VARCHAR(20) NOT NULL,
    account_name VARCHAR(100) NOT NULL,

    debit NUMERIC(18,2) NOT NULL DEFAULT 0
        CHECK (debit >= 0),

    credit NUMERIC(18,2) NOT NULL DEFAULT 0
        CHECK (credit >= 0),

    CHECK (
        (debit > 0 AND credit = 0)
        OR
        (credit > 0 AND debit = 0)
    )
);


-- 4. Membuat tabel audit log
CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    voucher_id UUID REFERENCES journal_vouchers(id),
    action VARCHAR(50) NOT NULL,
    performed_by UUID,
    performed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    details JSONB
);


-- 5. Fungsi mengunci transaksi POSTED
CREATE OR REPLACE FUNCTION prevent_posted_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IN ('POSTED', 'REVERSED') THEN
        RAISE EXCEPTION
            'Transaksi yang sudah diposting atau dibalik tidak boleh diubah atau dihapus. Gunakan jurnal pembalik.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;


-- 6. Memasang trigger pada tabel voucher
CREATE TRIGGER trg_protect_journal_vouchers
BEFORE UPDATE OR DELETE ON journal_vouchers
FOR EACH ROW
EXECUTE FUNCTION prevent_posted_modification();


-- 7. Fungsi melindungi detail jurnal
CREATE OR REPLACE FUNCTION prevent_posted_detail_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_voucher_id UUID;
    v_status VARCHAR(20);
BEGIN
    IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
        v_voucher_id := OLD.voucher_id;
    ELSE
        v_voucher_id := NEW.voucher_id;
    END IF;

    SELECT status
    INTO v_status
    FROM journal_vouchers
    WHERE id = v_voucher_id
    FOR UPDATE;

    IF v_status IN ('POSTED', 'REVERSED') THEN
        RAISE EXCEPTION
            'Detail jurnal POSTED tidak boleh diubah atau dihapus.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;


-- 8. Memasang trigger pada detail jurnal
CREATE TRIGGER trg_protect_journal_details
BEFORE INSERT OR UPDATE OR DELETE ON journal_details
FOR EACH ROW
EXECUTE FUNCTION prevent_posted_detail_modification();


-- 9. Fungsi menghitung hash checksum
CREATE OR REPLACE FUNCTION calculate_voucher_hash(
    p_voucher_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_hash TEXT;
BEGIN
    SELECT encode(
        digest(
            convert_to(
                jsonb_build_object(
                    'voucher', to_jsonb(v),
                    'details', COALESCE(
                        (
                            SELECT jsonb_agg(
                                to_jsonb(d)
                                ORDER BY d.id
                            )
                            FROM journal_details d
                            WHERE d.voucher_id = v.id
                        ),
                        '[]'::jsonb
                    )
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    INTO v_hash
    FROM journal_vouchers v
    WHERE v.id = p_voucher_id;

    RETURN v_hash;
END;
$$;


-- 10. Fungsi posting transaksi
CREATE OR REPLACE FUNCTION post_transaction(
    p_voucher_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_status VARCHAR(20);
    v_total_debit NUMERIC(18,2);
    v_total_credit NUMERIC(18,2);
    v_user_id UUID;
    v_hash TEXT;
BEGIN
    -- Identitas pengguna dari Supabase Auth
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Pengguna harus login sebelum melakukan posting.';
    END IF;

    -- Mengunci baris voucher selama proses posting
    SELECT status
    INTO v_status
    FROM journal_vouchers
    WHERE id = p_voucher_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher tidak ditemukan.';
    END IF;

    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION
            'Hanya voucher DRAFT yang dapat diposting.';
    END IF;

    -- Menghitung total debit dan kredit
    SELECT
        COALESCE(SUM(debit), 0),
        COALESCE(SUM(credit), 0)
    INTO v_total_debit, v_total_credit
    FROM journal_details
    WHERE voucher_id = p_voucher_id;

    IF v_total_debit <= 0
       OR v_total_debit <> v_total_credit THEN
        RAISE EXCEPTION
            'Posting ditolak: total debit dan kredit harus sama dan lebih besar dari nol.';
    END IF;

    -- Menghitung checksum dari data voucher dan detail jurnal
    v_hash := calculate_voucher_hash(p_voucher_id);

    -- Mengubah status menjadi POSTED
    UPDATE journal_vouchers
    SET status = 'POSTED',
        posted_by = v_user_id,
        posted_at = now(),
        hash_checksum = v_hash
    WHERE id = p_voucher_id;

    -- Mencatat aktivitas posting
    INSERT INTO audit_logs (
        voucher_id,
        action,
        performed_by,
        details
    )
    VALUES (
        p_voucher_id,
        'POSTED',
        v_user_id,
        jsonb_build_object(
            'total_debit', v_total_debit,
            'total_credit', v_total_credit,
            'hash_checksum', v_hash
        )
    );
END;
$$;


-- 11. Fungsi memeriksa integritas checksum
CREATE OR REPLACE FUNCTION verify_checksum(
    p_voucher_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_stored_hash TEXT;
    v_current_hash TEXT;
BEGIN
    SELECT hash_checksum
    INTO v_stored_hash
    FROM journal_vouchers
    WHERE id = p_voucher_id;

    IF NOT FOUND OR v_stored_hash IS NULL THEN
        RETURN FALSE;
    END IF;

    v_current_hash :=
        calculate_voucher_hash(p_voucher_id);

    RETURN v_stored_hash = v_current_hash;
END;
$$;


-- 12. Mengaktifkan Row Level Security
ALTER TABLE journal_vouchers
ENABLE ROW LEVEL SECURITY;

ALTER TABLE journal_details
ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit_logs
ENABLE ROW LEVEL SECURITY;

-- Catatan:
-- Kebijakan akses RLS dan GRANT harus ditentukan
-- sesuai peran pengguna aplikasi.
-- Jangan memberikan akses publik tanpa pembatasan.


-- =====================================================
-- AKHIR KODE AUDIT TRAIL & IMMUTABILITY
-- =====================================================
