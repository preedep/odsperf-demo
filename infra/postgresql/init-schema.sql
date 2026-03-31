-- =============================================================================
-- ODS Transaction Table — PostgreSQL DDL
-- Converted from DB2 schema
-- =============================================================================
-- DB2 → PostgreSQL type mapping:
--   CHAR(n)        → CHAR(n)          fixed-length, pads with spaces (ตรงกับ DB2)
--   DATE           → DATE             format YYYY-MM-DD
--   INTEGER        → INTEGER
--   DECIMAL(p,s)   → NUMERIC(p,s)     exact numeric, no floating-point error
-- =============================================================================

-- สร้าง schema สำหรับ ODS (ถ้ายังไม่มี)
CREATE SCHEMA IF NOT EXISTS odsperf;

-- =============================================================================
-- Table: odsperf.account_transaction
-- =============================================================================
DROP TABLE IF EXISTS odsperf.account_transaction;

CREATE TABLE odsperf.account_transaction (

    -- -----------------------------------------------------------------------
    -- Key columns (NOT NULL)
    -- -----------------------------------------------------------------------
    iacct           CHAR(11)        NOT NULL,   -- เลขที่บัญชี
    drun            DATE            NOT NULL,   -- วันที่ RUN ข้อมูล
    cseq            INTEGER         NOT NULL,   -- ลำดับ
    ddate           DATE            NOT NULL,   -- วันที่รายการนั้นมีผล

    -- -----------------------------------------------------------------------
    -- Transaction columns (Nullable)
    -- -----------------------------------------------------------------------
    dtrans          DATE,                       -- วันที่ทำรายการ
    ttime           CHAR(5),                    -- เวลาที่ทำรายการ (HH:MM)
    cmnemo          CHAR(3),                    -- รหัสการทำรายการ
    cchannel        CHAR(4),                    -- ช่องทางที่ทำรายการ
    ctr             CHAR(2),                    -- เลขที่โอน
    cbr             CHAR(4),                    -- สาขาที่ทำรายการ
    cterm           CHAR(5),                    -- TERMINAL ID
    camt            CHAR(1),                    -- CREDIT/DEBIT  ('C' | 'D')
    aamount         NUMERIC(13, 2),             -- จำนวนเงินที่ทำรายการ
    abal            NUMERIC(13, 2),             -- ยอดเงินคงเหลือ
    description     VARCHAR(20),                -- รายละเอียดของรายการ
    time_hms        CHAR(8),                    -- เวลา HH:MM:SS

    -- -----------------------------------------------------------------------
    -- Primary Key — iacct + drun + cseq (uniquely identifies a transaction)
    -- -----------------------------------------------------------------------
    CONSTRAINT pk_account_transaction PRIMARY KEY (iacct, drun, cseq)
);

-- =============================================================================
-- Indexes — ช่วย query performance สำหรับ ODS workload
-- =============================================================================

-- ค้นหารายการตามบัญชี + วันที่ทำรายการ (use case หลัก)
CREATE INDEX idx_acctxn_iacct_dtrans
    ON odsperf.account_transaction (iacct, dtrans);

-- ค้นหารายการตาม run date (batch processing)
CREATE INDEX idx_acctxn_drun
    ON odsperf.account_transaction (drun);

-- filter CREDIT/DEBIT
CREATE INDEX idx_acctxn_camt
    ON odsperf.account_transaction (camt);

-- =============================================================================
-- Comments
-- =============================================================================
COMMENT ON TABLE  odsperf.account_transaction           IS 'ODS Account Transaction — converted from DB2';
COMMENT ON COLUMN odsperf.account_transaction.iacct     IS 'เลขที่บัญชี (Account Number)';
COMMENT ON COLUMN odsperf.account_transaction.drun      IS 'วันที่ RUN ข้อมูล (Batch Run Date)';
COMMENT ON COLUMN odsperf.account_transaction.cseq      IS 'ลำดับรายการ (Sequence)';
COMMENT ON COLUMN odsperf.account_transaction.dtrans    IS 'วันที่ทำรายการ (Transaction Date)';
COMMENT ON COLUMN odsperf.account_transaction.ddate     IS 'วันที่รายการนั้นมีผล (Value Date)';
COMMENT ON COLUMN odsperf.account_transaction.ttime     IS 'เวลาที่ทำรายการ HH:MM';
COMMENT ON COLUMN odsperf.account_transaction.cmnemo    IS 'รหัสการทำรายการ (Transaction Mnemonic)';
COMMENT ON COLUMN odsperf.account_transaction.cchannel  IS 'ช่องทางที่ทำรายการ (Channel)';
COMMENT ON COLUMN odsperf.account_transaction.ctr       IS 'เลขที่โอน (Transfer Ref)';
COMMENT ON COLUMN odsperf.account_transaction.cbr       IS 'สาขาที่ทำรายการ (Branch)';
COMMENT ON COLUMN odsperf.account_transaction.cterm     IS 'Terminal ID';
COMMENT ON COLUMN odsperf.account_transaction.camt      IS 'Credit/Debit flag — C=Credit, D=Debit';
COMMENT ON COLUMN odsperf.account_transaction.aamount   IS 'จำนวนเงินที่ทำรายการ (Transaction Amount)';
COMMENT ON COLUMN odsperf.account_transaction.abal      IS 'ยอดเงินคงเหลือ (Balance After Transaction)';
COMMENT ON COLUMN odsperf.account_transaction.description IS 'รายละเอียดของรายการ (Description)';
COMMENT ON COLUMN odsperf.account_transaction.time_hms  IS 'เวลา HH:MM:SS';
