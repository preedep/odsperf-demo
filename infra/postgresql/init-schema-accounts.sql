-- =============================================================================
-- ODS Account Master Table — PostgreSQL DDL
-- Used for JOIN testing: account_transaction JOIN account_master ON iacct
-- =============================================================================

-- =============================================================================
-- Table: odsperf.account_master
-- =============================================================================
DROP TABLE IF EXISTS odsperf.account_master;

CREATE TABLE odsperf.account_master (

    -- -----------------------------------------------------------------------
    -- Primary Key
    -- -----------------------------------------------------------------------
    iacct           VARCHAR(11)     NOT NULL,   -- เลขที่บัญชี (Account Number)

    -- -----------------------------------------------------------------------
    -- Customer / Account columns
    -- -----------------------------------------------------------------------
    custid          VARCHAR(10)     NOT NULL,   -- รหัสลูกค้า (Customer ID)
    ctype           CHAR(3)         NOT NULL,   -- ประเภทบัญชี: SAV / CHK / CUR / FXD
    dopen           DATE            NOT NULL,   -- วันที่เปิดบัญชี (Account Open Date)
    dclose          DATE,                       -- วันที่ปิดบัญชี (Account Close Date, NULL = still open)
    cstatus         CHAR(4)         NOT NULL,   -- สถานะ: ACTV / INAC / CLSD
    cbranch         VARCHAR(4)      NOT NULL,   -- สาขาที่เปิดบัญชี (Branch Code)
    segment         VARCHAR(6)      NOT NULL,   -- กลุ่มลูกค้า: RETAIL / SME / CORP / PRIV
    credit_limit    NUMERIC(15, 2),             -- วงเงิน (Credit Limit, NULL = ไม่มี)

    -- -----------------------------------------------------------------------
    -- Primary Key Constraint
    -- -----------------------------------------------------------------------
    CONSTRAINT pk_account_master PRIMARY KEY (iacct)
);

-- =============================================================================
-- Indexes
-- =============================================================================

-- ค้นหาบัญชีตาม customer
CREATE INDEX idx_acctmaster_custid
    ON odsperf.account_master (custid);

-- filter ตามประเภทบัญชี
CREATE INDEX idx_acctmaster_ctype
    ON odsperf.account_master (ctype);

-- filter ตามสาขา
CREATE INDEX idx_acctmaster_cbranch
    ON odsperf.account_master (cbranch);

-- filter ตาม segment (สำหรับ analytics)
CREATE INDEX idx_acctmaster_segment
    ON odsperf.account_master (segment);

-- =============================================================================
-- Comments
-- =============================================================================
COMMENT ON TABLE  odsperf.account_master              IS 'ODS Account Master — reference data for JOIN testing';
COMMENT ON COLUMN odsperf.account_master.iacct        IS 'เลขที่บัญชี (Account Number) — PK, shared pool with account_transaction';
COMMENT ON COLUMN odsperf.account_master.custid       IS 'รหัสลูกค้า (Customer ID)';
COMMENT ON COLUMN odsperf.account_master.ctype        IS 'ประเภทบัญชี: SAV=ออมทรัพย์, CHK=กระแสรายวัน, CUR=เงินตรา, FXD=ฝากประจำ';
COMMENT ON COLUMN odsperf.account_master.dopen        IS 'วันที่เปิดบัญชี (Account Open Date)';
COMMENT ON COLUMN odsperf.account_master.dclose       IS 'วันที่ปิดบัญชี (Account Close Date) — NULL = ยังเปิดอยู่';
COMMENT ON COLUMN odsperf.account_master.cstatus      IS 'สถานะบัญชี: ACTV=Active, INAC=Inactive, CLSD=Closed';
COMMENT ON COLUMN odsperf.account_master.cbranch      IS 'สาขาที่เปิดบัญชี (Branch Code) — matches cbr in account_transaction';
COMMENT ON COLUMN odsperf.account_master.segment      IS 'กลุ่มลูกค้า: RETAIL, SME, CORP, PRIV';
COMMENT ON COLUMN odsperf.account_master.credit_limit IS 'วงเงิน NUMERIC(15,2) — NULL = ไม่มีวงเงิน';
