# ODS Performance Demo — PostgreSQL vs MongoDB (Rust)

เปรียบเทียบประสิทธิภาพ (Performance) ระหว่าง **PostgreSQL** และ **MongoDB** โดยเขียนด้วยภาษา **Rust**
บน Kubernetes Infrastructure พร้อม Monitoring ด้วย Prometheus + Grafana

---

## สารบัญ

- [Quick Start](#quick-start)
- [โครงสร้างโปรเจค](#โครงสร้างโปรเจค)
- [ความต้องการของระบบ (Prerequisites)](#ความต้องการของระบบ-prerequisites)
- [Step 1: ติดตั้ง Infrastructure](#step-1-ติดตั้ง-infrastructure)
- [Step 2: Database Schema](#step-2-database-schema)
- [Step 3: Generate Mock Data](#step-3-generate-mock-data)
- [Step 4: Build & Deploy ODS Service](#step-4-build--deploy-ods-service)
- [Step 5: ทดสอบ API](#step-5-ทดสอบ-api)
- [การตรวจสอบสถานะ](#การตรวจสอบสถานะ)
- [การเข้าถึง UI ต่าง ๆ](#การเข้าถึง-ui-ต่าง-ๆ)
- [Architecture Overview](#architecture-overview)
- [การลบ Infrastructure ทั้งหมด](#การลบ-infrastructure-ทั้งหมด)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

สำหรับผู้ที่ต้องการติดตั้งและทดสอบอย่างรวดเร็ว (ใช้เวลาประมาณ 20-30 นาที):

```bash
# 1. ติดตั้ง Infrastructure (Istio, Gateway, Monitoring, Databases)
cd infra
make all
cd ..

# 2. เพิ่ม /etc/hosts
echo "127.0.0.1 ods.local grafana.local prometheus.local" | sudo tee -a /etc/hosts

# 3. Port forward databases
kubectl port-forward svc/postgresql 5432:5432 -n database-pg &
kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &

# 4. Generate และ load ข้อมูล (รวมสร้าง schema + indexes อัตโนมัติ)
./scripts/seed.sh

# 5. Build และ Deploy ODS Service
./scripts/deploy-ods.sh

# 6. ทดสอบ API
./scripts/test-api.sh --repeat 10

# 7. เปิด Grafana Dashboard
# http://grafana.local (admin/admin)
```

**หมายเหตุ:**
- Build Docker image ครั้งแรกใช้เวลา 5-10 นาที
- Seed ข้อมูล 1M rows ใช้เวลาประมาณ 2-3 นาที
- ดูรายละเอียดแต่ละ step ด้านล่าง

---

## โครงสร้างโปรเจค

```
odsperf-demo/
├── data/                               # Generated CSV (gitignored)
│   └── mock_transactions.csv           # 1M rows — shared source for PG + Mongo
├── docs/
│   ├── schema-account-transaction.md   # DB2→PostgreSQL→MongoDB type mapping
│   ├── api-reference.md                # REST API specification
│   ├── grafana-dashboard.md            # ODS Service Grafana Dashboard setup
│   └── hot-document-test.md            # Hot document write performance test guide
├── scripts/
│   ├── init-pg-schema.sh               # สร้าง PostgreSQL schema + table (ครั้งแรก)
│   ├── init-mongo-indexes.sh           # สร้าง MongoDB indexes (ครั้งแรก)
│   ├── seed.sh                         # Pipeline: generate CSV → load PG → load Mongo
│   ├── deploy-ods.sh                   # Build Docker image + Deploy ODS Service (รองรับ --force)
│   ├── test-api.sh                     # Shell script ทดสอบ API + Comparison summary
│   ├── test-hot-document.sh            # ทดสอบ hot document write performance (MongoDB)
│   ├── compare-disk-usage.sh           # เปรียบเทียบ disk usage PG vs MongoDB
│   ├── check-metrics.sh                # ตรวจสอบ Prometheus metrics จาก ODS Service
│   └── update-dashboard-configmap.sh   # อัปเดต Grafana dashboard ConfigMap
├── infra/                              # Infrastructure as Code
│   ├── namespaces.yaml                 # Kubernetes Namespaces + ResourceQuotas
│   ├── istio/
│   │   ├── gateway.yaml                # Istio Gateway (Gateway API v1)
│   │   ├── httproute.yaml              # HTTP Routes: Grafana, Prometheus, ODS
│   │   └── reference-grants.yaml       # Cross-namespace ReferenceGrants
│   ├── monitoring/
│   │   ├── kube-prometheus-values.yaml # Prometheus + Grafana Helm values
│   │   └── dashboards/
│   │       ├── ods-service-dashboard.json         # Grafana dashboard JSON
│   │       └── ods-service-dashboard-configmap.yaml # Dashboard ConfigMap
│   ├── postgresql/
│   │   ├── values.yaml                 # PostgreSQL Helm values
│   │   └── init-schema.sql             # DDL — odsperf.account_transaction
│   ├── mongodb/
│   │   ├── values.yaml                 # MongoDB Helm values
│   │   └── init-schema.js              # Collection + $jsonSchema validator
│   ├── ods-service/
│   │   ├── deployment.yaml             # Deployment: odsperf-demo image
│   │   ├── service.yaml                # ClusterIP Service port 80→8080
│   │   └── servicemonitor.yaml         # Prometheus ServiceMonitor
│   └── Makefile                        # Orchestrate deployment commands
├── src/
│   ├── main.rs                         # Entry point: init logging, DB, metrics, server
│   ├── config.rs                       # Config จาก environment variables
│   ├── error.rs                        # AppError → HTTP response (thiserror)
│   ├── state.rs                        # AppState: PgPool + MongoDB Database + pool metrics
│   ├── models.rs                       # Request / Response / DTO structs
│   ├── metrics_collector.rs            # System metrics collector (CPU, Memory)
│   ├── db/
│   │   ├── postgres.rs                 # PgPoolOptions::connect()
│   │   └── mongodb.rs                  # Client::with_uri_str() + ping
│   ├── handlers/
│   │   ├── mod.rs                      # Router + middleware (HTTP metrics, tracing)
│   │   ├── health.rs                   # GET  /health
│   │   ├── pg.rs                       # POST /v1/query-pg (with DB metrics)
│   │   ├── pg_join.rs                  # POST /v1/query-pg-join
│   │   └── mongo.rs                    # POST /v1/query-mongo (with DB metrics)
│   └── bin/
│       ├── generate_csv.rs             # Step 1: generate data/mock_transactions.csv
│       ├── load_pg.rs                  # Step 2: CSV → PostgreSQL (batch INSERT)
│       ├── load_mongo.rs               # Step 3: CSV → MongoDB (batch insert_many)
│       └── test_hot_document.rs        # Hot document write test (embedded arrays)
├── Dockerfile                          # Multi-stage: rust:1.88-slim + debian-slim
├── Cargo.toml
└── README.md
```

### Namespace Layout

| Namespace         | วัตถุประสงค์                              | Istio Sidecar |
|------------------|------------------------------------------|---------------|
| `ingress`        | Istio Gateway — รับ HTTP traffic ทั้งหมด  | Enabled       |
| `ods-service`    | Rust ODS Application                     | Enabled       |
| `monitoring`     | Prometheus + Grafana                     | Enabled       |
| `database-pg`    | PostgreSQL + postgres_exporter           | Disabled      |
| `database-mongo` | MongoDB + mongodb_exporter               | Disabled      |

> แยก namespace ระหว่าง PostgreSQL และ MongoDB เพื่อให้ ResourceQuota เท่ากัน (fair benchmark) และ lifecycle เป็นอิสระต่อกัน

---

## ความต้องการของระบบ (Prerequisites)

### เครื่องมือที่ต้องติดตั้ง

| เครื่องมือ   | Version แนะนำ    | วิธีติดตั้ง |
|-------------|----------------|------------|
| `kubectl`   | ≥ 1.29         | https://kubernetes.io/docs/tasks/tools/ |
| `helm`      | ≥ 3.14         | https://helm.sh/docs/intro/install/ |
| `istioctl`  | 1.28.x         | https://istio.io/latest/docs/setup/getting-started/ |
| `Rust`      | ≥ 1.88 (stable) | https://rustup.rs |
| `Docker`    | ≥ 24.x         | https://docs.docker.com/get-docker/ |

> ⚠️ Rust ≥ 1.88 จำเป็นสำหรับ dependency MSRV: `darling 0.23`, `time 0.3.47`, `serde_with 3.18`

### Kubernetes Cluster

**Docker Desktop** (macOS / Windows) — แนะนำสำหรับ local development:
1. เปิด Docker Desktop
2. Settings → Kubernetes → Enable Kubernetes → Apply & Restart
3. Settings → General → เปิด **"Use containerd for pulling and storing images"** → Apply & Restart
4. รอจนขึ้น `Kubernetes running`

> ⚠️ ต้องเปิด containerd image store เพื่อให้ `docker build` image ถูก share ให้ Kubernetes ได้โดยตรง

**minikube** (Linux / macOS / Windows):
```bash
minikube start --cpus=4 --memory=8192 --driver=docker
minikube tunnel   # รันใน terminal แยก (สำหรับ LoadBalancer)
```

### ตรวจสอบ Resource ขั้นต่ำ

| Resource | ขั้นต่ำ  | แนะนำ   |
|----------|---------|--------|
| CPU      | 4 cores | 6 cores|
| Memory   | 8 GB    | 12 GB  |
| Disk     | 20 GB   | 40 GB  |

---

## Step 1: ติดตั้ง Infrastructure

```bash
cd infra
```

### 1.1 ตรวจสอบ Prerequisites

```bash
make prerequisites
```

### 1.2 Deploy ทั้งหมดในคำสั่งเดียว

```bash
make all
```

รัน 6 ขั้นตอนตามลำดับ: Gateway API CRDs → Namespaces → Istio → Gateway/HTTPRoutes → Monitoring → Databases

> ⏱ ใช้เวลาประมาณ 5–10 นาที

### หรือ Deploy ทีละขั้นตอน

```bash
make gateway-api-crds   # ติดตั้ง CRD ของ Kubernetes Gateway API
make namespaces         # สร้าง 5 namespaces
make istio              # ติดตั้ง Istio ผ่าน Helm
make gateway            # Apply Gateway + ReferenceGrants + HTTPRoutes
make monitoring         # ติดตั้ง kube-prometheus-stack (Prometheus + Grafana)
make postgresql         # ติดตั้ง PostgreSQL + postgres_exporter
make mongodb            # ติดตั้ง MongoDB + mongodb_exporter
```

### Connection Strings (ภายใน Cluster)

```
PostgreSQL : postgresql://odsuser:odspassword@postgresql.database-pg.svc.cluster.local:5432/odsperf
MongoDB    : mongodb://odsuser:odspassword@mongodb.database-mongo.svc.cluster.local:27017/odsperf
```

---

## Step 2: Database Schema

> 💡 **หมายเหตุ:** ถ้าคุณใช้ `./scripts/seed.sh` (แนะนำ) จะไม่ต้องรัน scripts 
> ในส่วนนี้แยก เพราะ `seed.sh` จะสร้าง schema, tables และ indexes ให้อัตโนมัติ

### PostgreSQL

ตาราง `odsperf.account_transaction` แปลงจาก DB2 — ดูรายละเอียดที่ [docs/schema-account-transaction.md](docs/schema-account-transaction.md)

```bash
# Port-forward แล้วรัน DDL (ถ้าต้องการสร้างแยก)
make port-forward-postgresql &
sleep 2
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -f infra/postgresql/init-schema.sql
```

### MongoDB

สร้าง collection พร้อม `$jsonSchema` validator และ indexes:

```bash
# สร้าง collection + schema validator (ถ้าต้องการสร้างแยก)
mongosh "mongodb://odsuser:odspassword@localhost:27017/odsperf" \
  infra/mongodb/init-schema.js   # รันจาก project root

# สร้าง indexes (ถ้าต้องการสร้างแยก)
./scripts/init-mongo-indexes.sh
```

ดูรายละเอียด schema ทั้งหมดได้ที่ [docs/schema-account-transaction.md](docs/schema-account-transaction.md)

---

## Step 3: Generate Mock Data

สร้างข้อมูลทดสอบสำหรับ benchmark ก่อน deploy ODS Service

### ภาพรวม — Architecture ใหม่ (CSV-first)

ทั้ง PostgreSQL และ MongoDB ต้องใช้ **ข้อมูลชุดเดียวกัน** เพื่อให้ benchmark เปรียบเทียบได้จริง (apple-to-apple)

```mermaid
graph LR
    subgraph GEN["Step 1 — No DB dependency"]
        GenBin["⚙️ generate_csv\nsrc/bin/generate_csv.rs"]
    end

    CSV[("📄 data/mock_transactions.csv\n1,000,000 rows · ~113 MB\nสร้างครั้งเดียว — ใช้ร่วมกัน")]

    subgraph LOAD["Step 2 & 3 — Load ข้อมูลชุดเดียวกัน"]
        LoadPG["⚙️ load_pg\nsrc/bin/load_pg.rs\nbatch INSERT 5,000 rows"]
        LoadMongo["⚙️ load_mongo\nsrc/bin/load_mongo.rs\nbatch insert_many 5,000 docs"]
    end

    subgraph DBS["Databases"]
        PG["🐘 PostgreSQL\nON CONFLICT DO NOTHING\nidempotent"]
        Mongo["🍃 MongoDB\ninsert_many\nbson::DateTime / Decimal128"]
    end

    GenBin -->|"seed.sh --csv-only"| CSV
    CSV -->|"seed.sh --pg-only"| LoadPG
    CSV -->|"seed.sh --mongo-only"| LoadMongo
    LoadPG --> PG
    LoadMongo --> Mongo
```

| Binary                    | หน้าที่                                    |
|--------------------------|-------------------------------------------|
| `src/bin/generate_csv.rs` | สร้าง CSV 1M rows (ไม่ต่อ DB)             |
| `src/bin/load_pg.rs`      | อ่าน CSV → PostgreSQL (batch INSERT)      |
| `src/bin/load_mongo.rs`   | อ่าน CSV → MongoDB (batch insert_many)    |

### 3.1 เตรียม Port Forward

```bash
# รันใน terminal แยก — ค้างไว้ตลอด
kubectl port-forward svc/postgresql 5432:5432 -n database-pg &
kubectl port-forward svc/mongodb    27017:27017 -n database-mongo &
```

### 3.2 รัน Pipeline ทั้งหมดในคำสั่งเดียว (แนะนำ)

```bash
./scripts/seed.sh
```

Script จะรัน 5 ขั้นตอนตามลำดับ:
0. **ตรวจสอบ Schema** → สร้าง PostgreSQL/MongoDB schema + tables ถ้ายังไม่มี
1. **Generate CSV** → `data/mock_transactions.csv` (ไม่ต่อ DB)
2. **Load PostgreSQL** → อ่าน CSV และ insert batch ทีละ 5,000 rows
3. **Load MongoDB** → อ่าน CSV ชุดเดียวกัน และ insert_many batch ทีละ 5,000 docs
4. **Create Indexes** → สร้าง indexes อัตโนมัติทั้ง PostgreSQL และ MongoDB

> ✅ **ไม่ต้องรัน `init-pg-schema.sh` หรือ `init-mongo-indexes.sh` แยก**  
> `seed.sh` จะจัดการให้หมดแล้ว

### 3.3 รันแยกทีละขั้นตอน (ทางเลือก)

```bash
# ขั้นตอน 1: สร้าง CSV
cargo build --release --bin generate_csv
./target/release/generate_csv
# → data/mock_transactions.csv (~100 MB, 1M rows)

# ขั้นตอน 2: Load PostgreSQL (สร้าง schema + indexes อัตโนมัติถ้ายังไม่มี)
cargo build --release --bin load_pg
DATABASE_URL="postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  ./target/release/load_pg

# ขั้นตอน 3: Load MongoDB
cargo build --release --bin load_mongo
MONGODB_URI="mongodb://odsuser:odspassword@localhost:27017/odsperf" \
  ./target/release/load_mongo

# ขั้นตอน 4: สร้าง MongoDB indexes (ถ้ารันแยก)
./scripts/init-mongo-indexes.sh
```

> 💡 **Tip:** ถ้าใช้ `seed.sh` จะไม่ต้องรัน step 4 เพราะสร้างให้อัตโนมัติแล้ว

### 3.4 Options ของ seed.sh

```bash
./scripts/seed.sh                    # full pipeline (CSV + PG + Mongo + indexes)
./scripts/seed.sh --accounts-only    # สร้าง account_master เท่านั้น
./scripts/seed.sh --txn-only         # สร้าง transactions เท่านั้น (ข้าม accounts)
./scripts/seed.sh --csv-only         # สร้าง CSV เท่านั้น
./scripts/seed.sh --pg-only          # load PG เท่านั้น (CSV ต้องมีอยู่แล้ว)
./scripts/seed.sh --mongo-only       # load Mongo + indexes (CSV ต้องมีอยู่แล้ว)
./scripts/seed.sh --no-mongo         # CSV + PG เท่านั้น
./scripts/seed.sh --no-accounts      # ข้าม account_master pipeline
```

> ✅ **Indexes สร้างอัตโนมัติ** ทุกครั้งที่ load ข้อมูล

### 3.5 ตัวอย่าง Output

```
══════ Step 1 — Generate CSV ══════
🚀 Mock Transaction CSV Generator
📊 Target  : 1000000 records
📁 Output  : data/mock_transactions.csv
   10% |   100000 rows | 2.1s elapsed | 47619 rows/s
  ...
  100% |  1000000 rows | 21.3s elapsed | 46948 rows/s
✅ Done! 1000000 records → data/mock_transactions.csv (98.4 MB)

══════ Step 2 — Load PostgreSQL ══════
✓ Batch    1 |      5000 / 1000000 | 0.22s batch | 22727 rows/s
...
🎉 PostgreSQL load complete! 1000000 rows — 45.2s

══════ Step 3 — Load MongoDB ══════
✓ Batch    1 |      5000 / 1000000 | 0.18s batch | 27777 docs/s
...
🎉 MongoDB load complete! 1000000 docs — 36.8s
```

### 3.6 ข้อมูลที่ Generate

| Field       | รายละเอียด                                              |
|------------|--------------------------------------------------------|
| `iacct`    | Random 11-digit account number                         |
| `dtrans`   | วันที่ random ระหว่าง 2025-01-01 ถึง 2025-12-31        |
| `camt`     | `C` (Credit) หรือ `D` (Debit) — 50/50                 |
| `aamount`  | จำนวนเงิน random 1.00 – 10,000.00                     |
| `abal`     | ยอดคงเหลือ random 10.00 – 100,000.00                  |
| `cmnemo`   | DEP / WDL / TRF / CHQ / FEE / INT / ATM / POS         |
| `cchannel` | ATM / INET / MOB / BRNC                               |

### 3.7 ตรวจสอบข้อมูลหลัง Generate

**PostgreSQL:**
```bash
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" -c "
  SELECT COUNT(*) AS total,
         MIN(dtrans) AS min_date,
         MAX(dtrans) AS max_date
  FROM odsperf.account_transaction;"

# ดูตัวอย่าง
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -c "SELECT iacct, dtrans, camt, aamount, cmnemo FROM odsperf.account_transaction LIMIT 5;"

# ขนาด storage
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" -c "
  SELECT pg_size_pretty(pg_total_relation_size('odsperf.account_transaction')) AS total,
         pg_size_pretty(pg_relation_size('odsperf.account_transaction'))       AS table_only,
         pg_size_pretty(pg_indexes_size('odsperf.account_transaction'))        AS indexes;"
```

**MongoDB:**
```bash
mongosh "mongodb://odsuser:odspassword@localhost:27017/odsperf" --eval "
  const col = db.account_transaction;
  print('Total:', col.countDocuments());
  const r = col.aggregate([{\$group:{_id:null,min:{\$min:'\$dtrans'},max:{\$max:'\$dtrans'}}}]).toArray();
  printjson(r[0]);
  printjson(db.runCommand({collStats:'account_transaction',scale:1048576})).storageSize + ' MB';
"
```

---

## Step 4: Build & Deploy ODS Service

### 4.1 Deploy ด้วย Script (แนะนำ)

```bash
./scripts/deploy-ods.sh
```

Script จะทำงานอัตโนมัติ:
1. ✅ Build Docker image `odsperf-demo:latest`
2. ✅ Deploy ลง namespace `ods-service`
3. ✅ รอให้ pod พร้อม (timeout 120s)
4. ✅ แสดงสถานะ pod, service, และ logs

**Options:**
```bash
./scripts/deploy-ods.sh --skip-build   # Deploy only (ใช้ image ที่มีอยู่)
./scripts/deploy-ods.sh --build-only   # Build only (ไม่ deploy)
./scripts/deploy-ods.sh --restart      # Force rollout restart after deploy
./scripts/deploy-ods.sh --force        # Build with unique tag (bypass cache) - แนะนำ!
```

> ⏱ Build ครั้งแรกประมาณ 5–10 นาที (compile + download crates)
> 💡 **แนะนำ:** ใช้ `--force` เพื่อ build ด้วย unique tag (เช่น `v20260403-182307`) เพื่อหลีกเลี่ยงปัญหา image cache
> 💡 รองรับทั้ง **Docker Desktop Kubernetes** และ **minikube** อัตโนมัติ

### 4.2 Deploy แบบ Manual (ทางเลือก)

```bash
# 1. Build Docker image
docker build -t odsperf-demo:latest .

# 2. สำหรับ minikube (ถ้าใช้)
eval $(minikube docker-env)
docker build -t odsperf-demo:latest .

# 3. Deploy to Kubernetes
kubectl apply -f infra/ods-service/deployment.yaml
kubectl apply -f infra/ods-service/service.yaml

# 4. ตรวจสอบสถานะ
kubectl get pods -n ods-service -w
kubectl logs -n ods-service -l app=ods-service -f
```

### 4.3 ทดสอบ Service

```bash
# Test health endpoint (port-forward)
kubectl port-forward -n ods-service svc/ods-service 8080:80 &
curl http://localhost:8080/health

# Test via Istio Gateway (ต้องเพิ่ม /etc/hosts ก่อน)
curl http://ods.local/health
```

### 4.4 เพิ่ม /etc/hosts (ถ้ายังไม่ได้ทำ)

```bash
# ดู Istio Gateway IP
kubectl get svc -n ingress

# Docker Desktop ใช้ 127.0.0.1
echo "127.0.0.1 ods.local grafana.local prometheus.local" | sudo tee -a /etc/hosts
```

### 4.5 Deploy Monitoring Dashboard (Optional)

ODS Service มี Prometheus metrics endpoint (`/metrics`) สำหรับติดตาม TPS และ latency

```bash
# 1. Deploy ServiceMonitor (ให้ Prometheus scrape metrics)
kubectl apply -f infra/ods-service/servicemonitor.yaml

# 2. Deploy Grafana Dashboard
kubectl apply -f infra/monitoring/dashboards/ods-service-dashboard-configmap.yaml

# 3. Verify metrics endpoint
kubectl port-forward -n ods-service svc/ods-service 8080:80 &
curl http://localhost:8080/metrics
```

**Metrics ที่ expose:**

**HTTP Metrics:**
- `http_requests_total{method, path, status}` — Request counter
- `http_request_duration_seconds{method, path}` — Latency histogram (p50, p95, p99)

**System Metrics:**
- `process_resident_memory_bytes` — Process memory usage
- `process_cpu_usage_percent` — CPU usage percentage
- `node_memory_MemTotal_bytes` — Total system memory
- `node_memory_MemUsed_bytes` — Used system memory
- `node_memory_MemAvailable_bytes` — Available system memory

**Database Metrics:**
- `db_pool_connections_total{database}` — Total connections in pool
- `db_pool_connections_active{database}` — Active connections
- `db_pool_connections_idle{database}` — Idle connections
- `db_queries_total{database, operation}` — Query counter
- `db_errors_total{database, operation}` — Error counter
- `db_query_duration_seconds{database, operation}` — Query duration histogram

**เข้าถึง Dashboard:**
- Grafana → Dashboards → ODS folder → **"ODS Service Performance"**
- Dashboard แสดง 15 panels: HTTP metrics, System metrics, Database metrics
- ดูรายละเอียดเพิ่มเติม: [docs/adding-metrics.md](docs/adding-metrics.md)

### Environment Variables

| Variable           | Required | Default   | Description                       |
|-------------------|----------|-----------|-----------------------------------|
| `DATABASE_URL`    | ✅        | —         | PostgreSQL connection string      |
| `MONGODB_URI`     | ✅        | —         | MongoDB connection string         |
| `MONGODB_DB`      | ❌        | `odsperf` | MongoDB database name             |
| `PORT`            | ❌        | `8080`    | HTTP listen port                  |
| `RUST_LOG`        | ❌        | `info`    | Log level: debug/info/warn/error  |
| `RUST_LOG_FORMAT` | ❌        | `pretty`  | `json` สำหรับ Kubernetes          |

---

## Step 5: ทดสอบ API

ดู API specification เต็มที่ [docs/api-reference.md](docs/api-reference.md)

### ใช้ test-api.sh (แนะนำ)

```bash
# ทดสอบทั้ง 2 endpoints พร้อมกัน
./scripts/test-api.sh

# ยิงตรงที่ Pod (bypass Istio) เมื่อ Gateway ยังไม่พร้อม
kubectl port-forward svc/ods-service 8080:80 -n ods-service &
./scripts/test-api.sh --host localhost:8080

# Benchmark 10 รอบ เปรียบเทียบ latency
./scripts/test-api.sh --repeat 10

# เทสเฉพาะ PostgreSQL, JOIN, หรือ MongoDB
./scripts/test-api.sh --pg      # PostgreSQL only
./scripts/test-api.sh --join    # PostgreSQL JOIN only
./scripts/test-api.sh --mongo   # MongoDB only

# ดู response เต็ม
./scripts/test-api.sh --verbose
```

### ตรวจสอบ Metrics

```bash
./scripts/check-metrics.sh
```

Script จะแสดง metrics ทั้งหมดที่ ODS Service expose:
- **System Metrics:** Process memory, CPU usage, Node memory
- **Database Pool Metrics:** Total, Active, Idle connections
- **Database Query Metrics:** Query counters, Error counters
- **Database Duration Metrics:** Query duration histogram
- **HTTP Metrics:** Request counters, Duration histogram

**ตัวอย่าง output:**
```
📊 Checking ODS Service metrics...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📈 System Metrics (Gauge):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
process_resident_memory_bytes 6651904
process_cpu_usage_percent 0
node_memory_MemTotal_bytes 12528861184
...
```

### เปรียบเทียบ Disk Usage

```bash
./scripts/compare-disk-usage.sh
```

Script จะแสดง:
- ✅ จำนวน rows/documents
- ✅ ขนาด data, indexes, และ total size
- ✅ รายละเอียด indexes แต่ละตัว
- ✅ เปรียบเทียบ storage efficiency (% difference)
- ✅ Bytes per row/document

**ตัวอย่าง Output:**
```
══════ Comparison Summary ══════
╔══════════════════════════════════════════════════════════════════╗
║                    Disk Usage Comparison                         ║
╚══════════════════════════════════════════════════════════════════╝

Metric               |     PostgreSQL |        MongoDB
─────────────────────────────────────────────────────────────────
Rows/Documents       |      1,000,000 |      1,000,000
Data Size            |         123 MB |         156 MB
Index Size           |          45 MB |          38 MB
Total Size           |         168 MB |         194 MB

Storage Efficiency:
  PostgreSQL uses less disk space
  MongoDB uses 15.5% more space (26 MB larger)

  PostgreSQL: 176.00 bytes/row
  MongoDB   : 203.00 bytes/document
```

### ทดสอบ Hot Document Performance (MongoDB)

ทดสอบ scenario การเขียน document เดียวกันซ้ำ ๆ (hot document) โดยจำลองการทำ batch aggregation ที่ append statements เข้า array:

```bash
./scripts/test-hot-document.sh
```

**สิ่งที่ทดสอบ:**
- 📝 Document growth performance (array append operations)
- 🔥 Write contention บน hot documents
- 📊 Embedded document approach (account + date + statements)
- ⚡ Write throughput และ latency เมื่อ document โต
- 🔑 Compound index performance `{iacct: 1, dtrans: 1}`

**Test Configuration:**
- **Collection:** `final_statements`
- **Document structure:** 1 document = 1 account + 1 วัน (compound key)
- **Hot accounts:** 10 accounts
- **Hot dates:** อ่านจาก `account_transaction` (หรือ 365 วันถ้า collection ว่าง)
- **Writes per document:** 100 ครั้ง (จำลอง batch writes ซ้ำ)
- **Statements per write:** 10 statements
- **Total:** ~365,000 writes, ~3,650,000 statements (ถ้ามี 365 วัน)

**Document Example:**
```json
{
  "iacct": "10000000000",
  "dtrans": ISODate("2025-01-15"),
  "statements": [/* transactions ทั้งหมดของวันนี้ */]
}
```

ดูรายละเอียดเพิ่มเติม: [docs/hot-document-test.md](docs/hot-document-test.md)

### curl โดยตรง

```bash
# Health check
curl http://ods.local/health

# Query PostgreSQL (transactions only)
curl -s -X POST http://ods.local/v1/query-pg \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1, "start_year":  2025,
    "end_month":   12, "end_year":  2025
  }' | jq '{db, total, elapsed_ms}'

# Query PostgreSQL JOIN (account + transactions)
curl -s -X POST http://ods.local/v1/query-pg-join \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1, "start_year":  2025,
    "end_month":   12, "end_year":  2025
  }' | jq '{db, total, elapsed_ms, data: {iacct, custid, segment}}'

# Query MongoDB
curl -s -X POST http://ods.local/v1/query-mongo \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1, "start_year":  2025,
    "end_month":   12, "end_year":  2025
  }' | jq '{db, total, elapsed_ms}'

# เปรียบเทียบ elapsed_ms สั้น ๆ
for db in pg mongo; do
  echo "=== $db ===";
  curl -s -X POST http://ods.local/v1/query-${db} \
    -H "Content-Type: application/json" \
    -d '{"account_no":"12345678901","start_month":1,"start_year":2025,"end_month":12,"end_year":2025}' \
    | jq '{db, total, elapsed_ms}';
done
```

---

## การตรวจสอบสถานะ

```bash
# ดู status ทั้งหมด
make status

# ดู Pod ทุก namespace
kubectl get pods -A | grep -E "NAMESPACE|ods-service|monitoring|database|ingress"
```

ผลลัพธ์ที่ควรได้:
```
NAMESPACE        NAME                                 READY   STATUS
ingress          istio-ingressgateway-xxx             1/1     Running
monitoring       kube-prometheus-stack-grafana-xxx    1/1     Running
monitoring       prometheus-kube-prometheus-xxx       2/2     Running
database-pg      postgresql-0                         2/2     Running
database-mongo   mongodb-xxx                          2/2     Running
ods-service      ods-service-xxx                      2/2     Running
```

> ℹ️ Pods ที่มี `2/2` คือ app container + Istio sidecar (หรือ metrics exporter)

---

## การเข้าถึง UI ต่าง ๆ

### วิธีที่ 1: Port Forward (ง่ายที่สุด)

```bash
make port-forward-grafana      # http://localhost:3000  (admin / admin)
make port-forward-prometheus   # http://localhost:9090
```

### วิธีที่ 2: ผ่าน Gateway

เพิ่ม `/etc/hosts`:
```
127.0.0.1  grafana.local
127.0.0.1  prometheus.local
127.0.0.1  ods.local
```

| URL                     | บริการ     | Login         |
|------------------------|-----------|---------------|
| http://grafana.local    | Grafana   | admin / admin |
| http://prometheus.local | Prometheus | —            |
| http://ods.local/health | ODS API   | —             |

### Grafana Dashboards

Dashboards ทั้งหมดอยู่ใน folder **ODS Performance** (จัดกลุ่มอัตโนมัติ):

```mermaid
graph TD
    subgraph GrafanaFolder["📁 Grafana Folder: ODS Performance"]
        D1["📊 ODS Service Performance\nTPS · Latency p50/p95/p99\nHTTP Status Codes · Error Rate\nuid: ods-service-perf"]
        D2["🐘 PostgreSQL\nQuery stats · Connections\nCache hit rate · Table size"]
        D3["🍃 MongoDB\nOps/sec · Document reads\nWiredTiger cache · Latency"]
        D4["☸️ Kubernetes Cluster\nCPU · Memory\nPod status · Network"]
    end

    CM["ConfigMap\nods-service-dashboard\ngrafana_folder: ODS Performance"]
    HV["Helm values\ndashboards.default.*\ngnetId: 9628 / 2583 / 7249"]

    CM -->|"sidecar reload ~30s"| D1
    HV -->|"Helm provision"| D2
    HV -->|"Helm provision"| D3
    HV -->|"Helm provision"| D4
```

**ติดตั้ง / อัปเดต Dashboard ConfigMap:**

```bash
# Apply ครั้งแรก (หรือหลังแก้ไข JSON)
cd infra
make dashboards

# หรือรัน kubectl โดยตรง
kubectl apply -f infra/monitoring/dashboards/ods-service-dashboard-configmap.yaml

# Grafana sidecar จะ reload อัตโนมัติภายใน ~30 วินาที
# ไม่จำเป็นต้อง restart Grafana pod
```

**ไฟล์ที่เกี่ยวข้อง:**

| ไฟล์                                                              | หน้าที่                                             |
|------------------------------------------------------------------|-----------------------------------------------------|
| `infra/monitoring/dashboards/ods-service-dashboard.json`         | Dashboard JSON (source of truth — แก้ไขไฟล์นี้)     |
| `infra/monitoring/dashboards/ods-service-dashboard-configmap.yaml` | K8s ConfigMap ที่ wrap JSON + annotation folder      |
| `infra/monitoring/kube-prometheus-values.yaml`                   | Grafana sidecar config (`folderAnnotation`)         |

---

## Architecture Overview

```mermaid
graph TD
    Client(["👤 Developer / Client"])

    subgraph NS_INGRESS["📦 namespace: ingress"]
        GW["🔀 Istio Gateway\nGateway API v1\nHTTPRoute + ReferenceGrant"]
    end

    subgraph NS_ODS["📦 namespace: ods-service  〔Istio sidecar〕"]
        ODS["⚙️ ODS Service\nRust · Axum 0.7\n─────────────────────\nGET  /health\nPOST /v1/query-pg\nPOST /v1/query-pg-join\nPOST /v1/query-mongo"]
    end

    subgraph NS_MON["📦 namespace: monitoring  〔Istio sidecar〕"]
        Grafana["📈 Grafana\nDashboards · admin/admin"]
        Prom["📊 Prometheus\nMetrics Store"]
    end

    subgraph NS_PG["📦 namespace: database-pg"]
        PG["🐘 PostgreSQL 16\nodsperf.account_transaction\nschema + indexes"]
        PGExp["postgres_exporter\n:9187"]
    end

    subgraph NS_MONGO["📦 namespace: database-mongo"]
        Mongo["🍃 MongoDB 8.x\nodsperf.account_transaction\ncollection + indexes"]
        MongoExp["mongodb_exporter\n:9216"]
    end

    %% Ingress traffic
    Client -->|"HTTP — ods.local"| GW
    Client -->|"HTTP — grafana.local"| GW
    Client -->|"HTTP — prometheus.local"| GW

    %% Gateway routing
    GW -->|"ods.local → :8080"| ODS
    GW -->|"grafana.local → :3000"| Grafana
    GW -->|"prometheus.local → :9090"| Prom

    %% Application → Database
    ODS -->|"sqlx · batch SELECT\nby iacct + date range"| PG
    ODS -->|"mongodb driver · find\nby iacct + dtrans range"| Mongo

    %% Monitoring pipeline
    PGExp -.->|"collect metrics"| PG
    MongoExp -.->|"collect metrics"| Mongo
    Prom -.->|"scrape :9187"| PGExp
    Prom -.->|"scrape :9216"| MongoExp
    Grafana -->|"PromQL query"| Prom
```

---

## การลบ Infrastructure ทั้งหมด

```bash
make clean        # ลบทุกอย่าง (Helm releases + Namespaces + PVC)
make clean-pg     # ลบเฉพาะ PostgreSQL
make clean-mongo  # ลบเฉพาะ MongoDB
```

> ⚠️ `make clean` จะลบ PersistentVolumeClaim ด้วย — ข้อมูลจะหายทั้งหมด

---

## Troubleshooting

### ErrImageNeverPull — Docker Desktop

**สาเหตุ:** Docker Desktop ≥ 4.12 แยก image store ระหว่าง Docker daemon กับ Kubernetes containerd
**แก้ไข:**
1. Docker Desktop → Settings → General → เปิด **"Use containerd for pulling and storing images"** → Apply & Restart
2. Build image ใหม่: `docker build -t odsperf-demo:latest .`
3. `kubectl rollout restart deployment/ods-service -n ods-service`

หรือเปลี่ยน `imagePullPolicy` ใน `deployment.yaml` เป็น `IfNotPresent` ชั่วคราว

---

### Could not resolve host: ods.local

```bash
# ดู Gateway IP
kubectl get svc -n istio-system

# เพิ่ม /etc/hosts (Docker Desktop ใช้ 127.0.0.1)
echo "127.0.0.1 ods.local grafana.local prometheus.local" | sudo tee -a /etc/hosts
```

---

### Gateway IP ไม่ได้รับ (Pending)

**Docker Desktop**: ตรวจสอบว่า Kubernetes เปิดอยู่
**minikube**: รัน `minikube tunnel` ใน terminal แยก

---

### Pod ค้างอยู่ที่ Pending

```bash
kubectl describe pod <pod-name> -n <namespace>
# ดูที่ Events section — มักเกิดจาก resource ไม่เพียงพอ
```

---

### Rust Build ล้มเหลว — MSRV Error

```
error: rustc X.Y.Z is not supported by the following packages:
  darling@0.23.0 requires rustc 1.88.0
```

Dockerfile ต้องใช้ `rust:1.88-slim` หรือใหม่กว่า:
```bash
# ตรวจสอบ Dockerfile
head -10 Dockerfile
# ควรเห็น: FROM rust:1.88-slim AS builder
```

---

### Prometheus ไม่เห็น Metrics

```bash
# ตรวจสอบ ServiceMonitor ทั้งหมด
kubectl get servicemonitor -n monitoring
kubectl get servicemonitor -n database-pg
kubectl get servicemonitor -n database-mongo
kubectl get servicemonitor -n ods-service

# เช็ค Prometheus targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
# เปิด http://localhost:9090/targets
# ควรเห็น: ods-service/ods-service/0 (1/1 up)
```

**ตรวจสอบ ODS Service metrics endpoint:**
```bash
# Port-forward ODS Service
kubectl port-forward -n ods-service svc/ods-service 8080:80

# ทดสอบ metrics endpoint
curl http://localhost:8080/metrics

# ควรเห็น metrics เช่น:
# http_requests_total{method="GET",path="/health",status="200"} 5
# http_request_duration_seconds_bucket{method="POST",path="/v1/query-pg",le="0.005"} 10
```

**ถ้า metrics ไม่มี:**
- ตรวจสอบว่า ODS Service ถูก rebuild ด้วย metrics support
- ดู logs: `kubectl logs -n ods-service -l app=ods-service`
- Verify ServiceMonitor labels ตรงกับ Service selector

---

### ODS Service ต่อ DB ไม่ได้

```bash
# ดู logs
kubectl logs -n ods-service -l app=ods-service --tail=50

# ทดสอบ connectivity จากภายใน cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n ods-service -- \
  curl -s postgresql.database-pg.svc.cluster.local:5432 || true
```

---

### MongoDB ช้ามาก (ช้ากว่า PostgreSQL หลายร้อยเท่า)

**สาเหตุ:** MongoDB ไม่มี indexes → ใช้ collection scan

**ตรวจสอบ:**
```bash
# Port-forward MongoDB
kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &

# ดู indexes ที่มีอยู่
mongosh "mongodb://odsuser:odspassword@localhost:27017/odsperf" --eval "
  db.account_transaction.getIndexes()
"

# ควรเห็น indexes อย่างน้อย 5 ตัว:
# - _id_ (default)
# - idx_pk_account_transaction (unique)
# - idx_acctxn_iacct_dtrans
# - idx_acctxn_drun
# - idx_acctxn_camt
```

**แก้ไข:**
```bash
# สร้าง indexes
./scripts/init-mongo-indexes.sh

# หรือ re-seed ข้อมูลใหม่ (จะสร้าง indexes อัตโนมัติ)
./scripts/seed.sh --mongo-only
```

**ผลลัพธ์ที่คาดหวัง:**
- PostgreSQL: ~2-5ms (มี B-tree index)
- MongoDB: ~5-15ms (มี index + document overhead)
- **MongoDB ควรช้ากว่า PostgreSQL แค่ 2-5 เท่า** ไม่ใช่ 100-300 เท่า!

---

### init-mongo-indexes.sh Error: "Index already exists"

**สาเหตุ:** Script รุ่นเก่าพยายามสร้าง index ที่มีอยู่แล้ว

**แก้ไข:**
```bash
# Pull code ล่าสุด (มี fix แล้ว)
git pull

# รัน script อีกครั้ง (จะ skip indexes ที่มีอยู่แล้ว)
./scripts/init-mongo-indexes.sh
```

Script รุ่นใหม่จะตรวจสอบและ skip indexes ที่มีอยู่แล้วอัตโนมัติ
