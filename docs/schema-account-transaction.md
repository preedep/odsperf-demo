# Schema: account_transaction

ตาราง ODS สำหรับ benchmark — แปลงจาก DB2 เป็น PostgreSQL

- **Schema:** `odsperf`
- **Table:** `account_transaction`
- **SQL:** [`infra/postgresql/init-schema.sql`](../infra/postgresql/init-schema.sql)

---

## Column Definitions

| Seq | Column Name   | Type (PostgreSQL) | Type (DB2)     | Length | Scale | Null | Default | Description              |
|-----|--------------|-------------------|----------------|--------|-------|------|---------|--------------------------|
| 1   | `iacct`      | `CHAR(11)`        | CHAR           | 11     | 0     | N    | N       | เลขที่บัญชี              |
| 2   | `drun`       | `DATE`            | DATE           | 10     | 0     | N    | N       | วันที่ RUN ข้อมูล        |
| 3   | `cseq`       | `INTEGER`         | INTEGER        | 4      | 0     | N    | N       | ลำดับรายการ              |
| 4   | `dtrans`     | `DATE`            | DATE           | 10     | 0     | Y    | Y       | วันที่ทำรายการ           |
| 5   | `ddate`      | `DATE`            | DATE           | 10     | 0     | N    | N       | วันที่รายการนั้นมีผล     |
| 6   | `ttime`      | `CHAR(5)`         | CHAR           | 5      | 0     | Y    | Y       | เวลาที่ทำรายการ (HH:MM)  |
| 7   | `cmnemo`     | `CHAR(3)`         | CHAR           | 3      | 0     | Y    | Y       | รหัสการทำรายการ          |
| 8   | `cchannel`   | `CHAR(4)`         | CHAR           | 4      | 0     | Y    | Y       | ช่องทางที่ทำรายการ       |
| 9   | `ctr`        | `CHAR(2)`         | CHAR           | 2      | 0     | Y    | Y       | เลขที่โอน                |
| 10  | `cbr`        | `CHAR(4)`         | CHAR           | 4      | 0     | Y    | Y       | สาขาที่ทำรายการ          |
| 11  | `cterm`      | `CHAR(5)`         | CHAR           | 5      | 0     | Y    | Y       | Terminal ID              |
| 12  | `camt`       | `CHAR(1)`         | CHAR           | 1      | 0     | Y    | Y       | Credit/Debit flag        |
| 13  | `aamount`    | `NUMERIC(13,2)`   | DECIMAL        | 13     | 2     | Y    | Y       | จำนวนเงินที่ทำรายการ     |
| 14  | `abal`       | `NUMERIC(13,2)`   | DECIMAL        | 13     | 2     | Y    | Y       | ยอดเงินคงเหลือ           |
| 15  | `description`| `VARCHAR(20)`     | CHAR           | 20     | 0     | Y    | Y       | รายละเอียดของรายการ      |
| 16  | `time_hms`   | `CHAR(8)`         | CHAR           | 8      | 0     | Y    | N       | เวลา HH:MM:SS            |

---

## Constraints

| ชนิด        | ชื่อ                          | Columns                  |
|------------|-------------------------------|--------------------------|
| Primary Key | `pk_account_transaction`     | `iacct`, `drun`, `cseq`  |

---

## Indexes

| ชื่อ Index                  | Columns              | วัตถุประสงค์                          |
|----------------------------|----------------------|--------------------------------------|
| `idx_acctxn_iacct_dtrans`  | `iacct`, `dtrans`    | ค้นหารายการตามบัญชี + วันที่ (use case หลัก) |
| `idx_acctxn_drun`          | `drun`               | ค้นหาตาม batch run date              |
| `idx_acctxn_camt`          | `camt`               | filter Credit / Debit                |

---

## Type Mapping: DB2 → PostgreSQL

| DB2 Type       | PostgreSQL Type  | หมายเหตุ                                                        |
|---------------|-----------------|----------------------------------------------------------------|
| `CHAR(n)`     | `CHAR(n)`       | fixed-length เหมือนกัน, padding ด้วย space                     |
| `DATE`        | `DATE`          | ตรงกัน format `YYYY-MM-DD`                                     |
| `INTEGER`     | `INTEGER`       | ตรงกัน 4 bytes                                                  |
| `DECIMAL(p,s)`| `NUMERIC(p,s)`  | exact precision ไม่มี floating-point error เหมาะกับข้อมูลทางการเงิน |
| `CHAR(20)` description | `VARCHAR(20)` | เปลี่ยนเป็น VARCHAR เพื่อประหยัด storage เมื่อ value สั้น |

---

## ข้อสังเกต

- **`camt`** — ควร validate ว่าเป็น `'C'` (Credit) หรือ `'D'` (Debit) เท่านั้น สามารถเพิ่ม CHECK constraint ได้ภายหลัง
- **`ttime` vs `time_hms`** — มี 2 columns สำหรับเวลา (`CHAR(5)` สำหรับ HH:MM และ `CHAR(8)` สำหรับ HH:MM:SS) ควรตรวจสอบกับ business rule ว่า populate ทั้งคู่หรือ column ใด column หนึ่ง
- **`aamount` / `abal`** — ใช้ `NUMERIC(13,2)` แทน `FLOAT` เสมอสำหรับข้อมูลทางการเงิน เพื่อหลีกเลี่ยง rounding error

---

## รัน Script

```bash
# Port-forward PostgreSQL แล้วรัน DDL
make port-forward-postgresql &
sleep 2

psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -f infra/postgresql/init-schema.sql

# ตรวจสอบ
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "\d odsperf.account_transaction"
```
