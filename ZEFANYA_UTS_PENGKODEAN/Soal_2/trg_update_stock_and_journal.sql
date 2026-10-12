
-- ============================================
-- FUNCTION DAN TRIGGER
-- Nama: trg_update_stock_and_journal
-- Tujuan:
-- a. Memperbarui stock_qty secara otomatis
-- b. Mencegah stok negatif saat penjualan
-- ============================================


-- 1. MEMBUAT TRIGGER FUNCTION

CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock_qty INT;
    v_new_stock INT;
    v_qty_change INT;
BEGIN

    -- Mengambil dan mengunci stok barang
    SELECT stock_qty
    INTO v_stock_qty
    FROM inventory_items
    WHERE item_id = NEW.item_id
    FOR UPDATE;

    -- Memeriksa apakah barang tersedia
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Barang dengan ID % tidak ditemukan',
            NEW.item_id;
    END IF;

    -- Menentukan perubahan stok
    IF NEW.trx_type = 'PURCHASE' THEN

        IF NEW.qty <= 0 THEN
            RAISE EXCEPTION
                'Jumlah pembelian harus positif';
        END IF;

        v_qty_change := NEW.qty;

    ELSIF NEW.trx_type = 'SALE' THEN

        IF NEW.qty <= 0 THEN
            RAISE EXCEPTION
                'Jumlah penjualan harus positif';
        END IF;

        v_qty_change := -NEW.qty;

    ELSIF NEW.trx_type = 'ADJUSTMENT' THEN

        v_qty_change := NEW.qty;

    END IF;

    -- Menghitung stok setelah transaksi
    v_new_stock := v_stock_qty + v_qty_change;

    -- Mencegah stok negatif
    IF v_new_stock < 0 THEN
        RAISE EXCEPTION
            'Stok tidak mencukupi untuk barang %.
             Stok tersedia: %, perubahan: %',
            NEW.item_id,
            v_stock_qty,
            v_qty_change;
    END IF;

    -- Memperbarui stok secara otomatis
    UPDATE inventory_items
    SET stock_qty = v_new_stock
    WHERE item_id = NEW.item_id;

    RETURN NEW;

END;
$$;


-- 2. MEMBUAT TRIGGER

CREATE TRIGGER trg_update_stock_and_journal
BEFORE INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION trg_update_stock_and_journal();
