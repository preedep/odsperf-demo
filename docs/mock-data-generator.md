# Mock Data Generator for PostgreSQL

โปรแกรม Rust สำหรับสร้างข้อมูลจำลอง 1 ล้าน records ใน PostgreSQL database

## ข้อมูลที่สร้าง

- **จำนวน**: 1,000,000 records
- **ช่วงเวลา**: 1 มกราคม 2025 - 31 ธันวาคม 2025
- **ตาราง**: `odsperf.account_transaction`

## ข้อมูลที่ถูก Random

- `iacct`: เลขบัญชี 11 หลัก (random)
- `dtrans`, `drun`, `ddate`: วันที่ต่างๆ ในปี 2025
- `cseq`: ลำดับรายการ (1-9999)
- `ttime`, `time_hms`: เวลา 08:00-17:59
- `cmnemo`: รหัสรายการ (DEP, WDL, TRF, CHQ, FEE, INT, ATM, POS)
- `cchannel`: ช่องทาง (ATM, INET, MOB, BRNC)
- `ctr`: เลขที่โอน
- `cbr`: รหัสสาขา
- `cterm`: Terminal ID
- `camt`: Credit/Debit (C/D)
- `aamount`: จำนวนเงิน (1.00 - 10,000.00)
- `abal`: ยอดคงเหลือ (10.00 - 100,000.00)
- `description`: คำอธิบาย (SALARY PAYMENT, ATM WITHDRAWAL, ฯลฯ)

## วิธีใช้งาน

### 1. เตรียม PostgreSQL Database

```bash
# Port-forward PostgreSQL (ถ้ารันใน Kubernetes)
cd infra
make port-forward-postgresql &
sleep 2

# สร้าง schema
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -f postgresql/init-schema.sql
```

### 2. Build โปรแกรม

```bash
# จาก project root
cargo build --release --bin generate_mock_data
```

### 3. รันโปรแกรม

```bash
# ใช้ default connection string (localhost:5432)
DATABASE_URL="postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  cargo run --release --bin generate_mock_data

# หรือถ้ารันใน Kubernetes cluster
DATABASE_URL="postgresql://odsuser:odspassword@postgresql.database-pg.svc.cluster.local:5432/odsperf" \
  cargo run --release --bin generate_mock_data
```

## Performance

- **Batch Size**: 5,000 records ต่อ transaction
- **ความเร็วโดยประมาณ**: 5,000-10,000 records/second (ขึ้นอยู่กับ hardware)
- **เวลาโดยประมาณ**: 2-3 นาที สำหรับ 1 ล้าน records

## ตัวอย่าง Output

```
🚀 Starting PostgreSQL Mock Data Generator
📊 Target: 1000000 records
📦 Batch size: 5000
🔌 Connecting to PostgreSQL...
✅ Connected successfully
✓ Batch 1/200 | Inserted: 5000 | Batch time: 0.85s | Total time: 0.85s | Speed: 5882 rec/s
✓ Batch 2/200 | Inserted: 10000 | Batch time: 0.82s | Total time: 1.67s | Speed: 5988 rec/s
...
✓ Batch 200/200 | Inserted: 1000000 | Batch time: 0.79s | Total time: 156.32s | Speed: 6397 rec/s

🎉 Data generation completed!
📊 Total records inserted: 1000000
⏱️  Total time: 156.32s
⚡ Average speed: 6397 records/second
```

## ตรวจสอบข้อมูล

```bash
# นับจำนวน records
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "SELECT COUNT(*) FROM odsperf.account_transaction;"

# ดูตัวอย่างข้อมูล
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "SELECT * FROM odsperf.account_transaction LIMIT 10;"

# ตรวจสอบช่วงวันที่
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "SELECT MIN(dtrans), MAX(dtrans) FROM odsperf.account_transaction;"
```

## ลบข้อมูล (ถ้าต้องการเริ่มใหม่)

```bash
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "TRUNCATE TABLE odsperf.account_transaction;"
```

## Troubleshooting

### Connection Error

ตรวจสอบว่า PostgreSQL พร้อมใช้งาน:
```bash
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" -c "SELECT 1;"
```

### Slow Performance

- ลด `BATCH_SIZE` ใน code (แก้ไข `src/bin/generate_mock_data.rs`)
- เพิ่ม `max_connections` ใน `PgPoolOptions`
- ปิด indexes ชั่วคราวก่อน insert (แล้วสร้างใหม่หลัง insert เสร็จ)

### Out of Memory

ลด `BATCH_SIZE` จาก 5000 เป็น 1000 หรือ 2000
