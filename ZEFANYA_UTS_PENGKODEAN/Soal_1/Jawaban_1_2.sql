
-- 1. Tabel Chart of Accounts
CREATE TABLE public.chart_of_accounts (
    account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_code VARCHAR(20) NOT NULL UNIQUE,
    account_name VARCHAR(100) NOT NULL,
    normal_balance VARCHAR(6) NOT NULL,
    report_classification VARCHAR(20) NOT NULL,

    CONSTRAINT chk_normal_balance
        CHECK (normal_balance IN ('Debit', 'Credit')),

    CONSTRAINT chk_report_classification
        CHECK (report_classification IN (
            'Asset',
            'Liability',
            'Equity',
            'Revenue',
            'Expense'
        ))
);

-- 2. Tabel Journal Headers
CREATE TABLE public.journal_headers (
    header_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_date DATE NOT NULL,
    reference_no VARCHAR(50) NOT NULL UNIQUE,
    description TEXT NOT NULL,
    posting_status VARCHAR(10) NOT NULL DEFAULT 'Draft',

    CONSTRAINT chk_posting_status
        CHECK (posting_status IN ('Draft', 'Posted'))
);

-- 3. Tabel Journal Lines
CREATE TABLE public.journal_lines (
    line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    header_id BIGINT NOT NULL,
    account_id BIGINT NOT NULL,
    debit NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit NUMERIC(18,2) NOT NULL DEFAULT 0,

    CONSTRAINT fk_lines_header
        FOREIGN KEY (header_id)
        REFERENCES public.journal_headers(header_id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_lines_account
        FOREIGN KEY (account_id)
        REFERENCES public.chart_of_accounts(account_id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_debit_nonnegative
        CHECK (debit >= 0),

    CONSTRAINT chk_credit_nonnegative
        CHECK (credit >= 0),

    CONSTRAINT chk_debit_credit_not_both_zero
        CHECK (debit > 0 OR credit > 0),

    CONSTRAINT chk_debit_credit_exclusive
        CHECK (debit = 0 OR credit = 0)
);

-- Index untuk mempercepat pencarian jurnal
CREATE INDEX idx_journal_lines_header
    ON public.journal_lines(header_id);

CREATE INDEX idx_journal_lines_account
    ON public.journal_lines(account_id);

CREATE INDEX idx_journal_headers_date
    ON public.journal_headers(transaction_date);
