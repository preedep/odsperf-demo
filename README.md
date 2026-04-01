# ODS Performance Demo — PostgreSQL vs MongoDB (Rust)

เปรียบเทียบประสิทธิภาพ (Performance) ระหว่าง **PostgreSQL** และ **MongoDB** โดยเขียนด้วยภาษา **Rust**
บน Kubernetes Infrastructure พร้อม Monitoring ด้วย Prometheus + Grafana

---

## สารบัญ

- [โครงสร้างโปรเจค](#โครงสร้างโปรเจค)
- [ความต้องการของระบบ (Prerequisites)](#ความต้องการของระบบ-prerequisites)
- [Step 1: ติดตั้ง Infrastructure](#step-1-ติดตั้ง-infrastructure)
- [การตรวจสอบสถานะ](#การตรวจสอบสถานะ)
- [การเข้าถึง UI ต่าง ๆ](#การเข้าถึง-ui-ต่าง-ๆ)
- [Step 2: ODS Service (Rust + Axum)](#step-2-ods-service-rust--axum)
- [Step 3: Database Schema](#step-3-database-schema)
- [การลบ Infrastructure ทั้งหมด](#การลบ-infrastructure-ทั้งหมด)

---

## โครงสร้างโปรเจค

```
odsperf-demo/
├── docs/
│   └── schema-account-transaction.md  # DB2→PostgreSQL schema reference
├── infra/                          # Infrastructure as Code
│   ├── namespaces.yaml             # Kubernetes Namespaces + ResourceQuotas
│   ├── istio/
│   │   ├── gateway.yaml            # Istio Gateway (Gateway API)
│   │   ├── httproute.yaml          # HTTP Routes (Grafana, Prometheus, ODS)
│   │   └── reference-grants.yaml   # Cross-namespace permissions
│   ├── monitoring/
│   │   └── kube-prometheus-values.yaml  # Prometheus + Grafana config
│   ├── postgresql/
│   │   ├── values.yaml             # PostgreSQL Helm values
│   │   └── init-schema.sql         # DDL — account_transaction table
│   ├── mongodb/
│   │   └── values.yaml             # MongoDB Helm values
│   └── Makefile                    # Orchestrate deployment
├── src/
│   └── main.rs                     # Rust application (Step 3)
├── Cargo.toml
└── README.md
```

### Namespace Layout

| Namespace        | วัตถุประสงค์                            | Istio Sidecar |
|-----------------|----------------------------------------|---------------|
| `ingress`       | Istio Gateway — รับ HTTP traffic ทั้งหมด | Enabled       |
| `ods-service`   | Rust ODS Application (Step 2)          | Enabled       |
| `monitoring`    | Prometheus + Grafana                   | Enabled       |
| `database-pg`   | PostgreSQL + postgres_exporter         | Disabled      |
| `database-mongo`| MongoDB + mongodb_exporter             | Disabled      |

> แยก namespace ระหว่าง PostgreSQL และ MongoDB เพื่อให้ ResourceQuota เท่ากัน (fair benchmark) และ lifecycle เป็นอิสระต่อกัน

---

## ความต้องการของระบบ (Prerequisites)

### เครื่องมือที่ต้องติดตั้ง

| เครื่องมือ   | Version แนะนำ | วิธีติดตั้ง |
|-------------|--------------|------------|
| `kubectl`   | ≥ 1.29       | https://kubernetes.io/docs/tasks/tools/ |
| `helm`      | ≥ 3.14       | https://helm.sh/docs/intro/install/ |
| `istioctl`  | 1.22.x       | https://istio.io/latest/docs/setup/getting-started/ |
| `Rust`      | ≥ 1.78 (stable) | https://rustup.rs |

### Kubernetes Cluster

เลือกอย่างใดอย่างหนึ่ง:

**Docker Desktop** (macOS / Windows)
1. เปิด Docker Desktop
2. ไปที่ Settings → Kubernetes → Enable Kubernetes
3. กด Apply & Restart
4. รอจนขึ้น `Kubernetes running`

**minikube** (Linux / macOS / Windows)
```bash
# ติดตั้ง minikube
brew install minikube   # macOS
# หรือ: https://minikube.sigs.k8s.io/docs/start/

# เริ่ม cluster (แนะนำ resource ขั้นต่ำ)
minikube start \
  --cpus=4 \
  --memory=8192 \
  --driver=docker

# เปิด LoadBalancer support สำหรับ Gateway
minikube tunnel   # รันใน terminal แยก
```

### ตรวจสอบ Resource ขั้นต่ำ

| Resource | ขั้นต่ำ  | แนะนำ   |
|----------|---------|--------|
| CPU      | 4 cores | 6 cores|
| Memory   | 8 GB    | 12 GB  |
| Disk     | 20 GB   | 40 GB  |

---

## Step 1: ติดตั้ง Infrastructure

เข้าไปที่ไดเรกทอรี `infra/` ก่อนรัน command ทั้งหมด:

```bash
cd infra
```

### 1.1 ตรวจสอบ Prerequisites

```bash
make prerequisites
```

ผลลัพธ์ที่ควรได้:
```
[INFO] All prerequisites satisfied ✓
  kubectl  : Client Version: v1.30.x
  helm     : v3.15.x
  istioctl : 1.22.x
  context  : docker-desktop
```

### 1.2 Deploy ทั้งหมดในคำสั่งเดียว

```bash
make all
```

คำสั่งนี้จะรัน 6 ขั้นตอนตามลำดับ:
1. ติดตั้ง Gateway API CRDs
2. สร้าง Namespaces
3. ติดตั้ง Istio
4. Apply Gateway + HTTPRoutes
5. ติดตั้ง Prometheus + Grafana
6. ติดตั้ง PostgreSQL + MongoDB

> ⏱ ใช้เวลาประมาณ 5-10 นาที ขึ้นอยู่กับความเร็ว Internet

---

### หรือ Deploy ทีละขั้นตอน

#### ขั้นตอนที่ 1: Gateway API CRDs

```bash
make gateway-api-crds
```

ติดตั้ง CRD ของ Kubernetes Gateway API (stable v1.1.0)
ซึ่ง Istio ใช้แทน IngressGateway แบบเก่า

#### ขั้นตอนที่ 2: สร้าง Namespaces

```bash
make namespaces
```

สร้าง 4 namespaces: `ingress`, `ods-service`, `monitoring`, `databases`

#### ขั้นตอนที่ 3: ติดตั้ง Istio

```bash
make istio
```

ติดตั้ง Istio ผ่าน Helm (istio-base + istiod) พร้อมเปิดใช้งาน Gateway API

#### ขั้นตอนที่ 4: Apply Gateway Resources

```bash
make gateway
```

สร้าง Istio Gateway + ReferenceGrants + HTTPRoutes สำหรับ:
- `grafana.local` → Grafana
- `prometheus.local` → Prometheus
- `ods.local` → ODS Service (Step 2)

#### ขั้นตอนที่ 5: ติดตั้ง Monitoring Stack

```bash
make monitoring
```

ติดตั้ง `kube-prometheus-stack` ซึ่งประกอบด้วย:
- **Prometheus** — เก็บ metrics จาก PostgreSQL exporter และ MongoDB exporter
- **Grafana** — แสดง dashboard (pre-loaded: PostgreSQL, MongoDB, Kubernetes)

#### ขั้นตอนที่ 6: ติดตั้ง Databases

```bash
make postgresql   # ติดตั้ง PostgreSQL พร้อม postgres_exporter
make mongodb      # ติดตั้ง MongoDB พร้อม mongodb_exporter
```

---

## การตรวจสอบสถานะ

### ดู status ทั้งหมด

```bash
make status
```

### ตรวจสอบ Pod ทั้งหมด

```bash
kubectl get pods -n monitoring
kubectl get pods -n database-pg
kubectl get pods -n database-mongo
kubectl get pods -n ingress
```

ทุก Pod ควรมีสถานะ `Running`:
```
NAMESPACE        NAME                                      READY   STATUS
monitoring       kube-prometheus-stack-grafana-xxx         1/1     Running
monitoring       kube-prometheus-stack-prometheus-xxx      1/1     Running
database-pg      postgresql-0                              2/2     Running
database-mongo   mongodb-0                                 2/2     Running
```

> ℹ️ PostgreSQL และ MongoDB มี 2/2 containers (app + metrics exporter)

### ตรวจสอบ Gateway

```bash
kubectl get gateway -n ingress
kubectl get httproutes -n ingress
```

---

## การเข้าถึง UI ต่าง ๆ

### วิธีที่ 1: Port Forward (ง่ายที่สุด)

```bash
# Grafana
make port-forward-grafana
# เปิด: http://localhost:3000  (admin / admin)

# Prometheus
make port-forward-prometheus
# เปิด: http://localhost:9090
```

### วิธีที่ 2: ผ่าน Gateway (ต้องแก้ /etc/hosts)

```bash
# ดู Gateway IP
make gateway-ip

# แสดง hosts entries ที่ต้องเพิ่ม
make hosts-entry
```

เพิ่ม hosts ที่ `/etc/hosts` (macOS/Linux) หรือ `C:\Windows\System32\drivers\etc\hosts` (Windows):
```
127.0.0.1  grafana.local
127.0.0.1  prometheus.local
127.0.0.1  ods.local
```

> ⚠️ สำหรับ minikube: ต้องรัน `minikube tunnel` ไว้ใน terminal แยก
> แล้วใช้ IP ที่ได้จาก `make gateway-ip` แทน `127.0.0.1`

จากนั้นเปิด browser:
| URL                        | บริการ     | Login         |
|---------------------------|-----------|---------------|
| http://grafana.local       | Grafana   | admin / admin |
| http://prometheus.local    | Prometheus | —            |

### Grafana Dashboards ที่ติดตั้งไว้

หลังจาก login Grafana ไปที่ **Dashboards → ODS Performance**:

| Dashboard          | รายละเอียด                                    |
|-------------------|----------------------------------------------|
| PostgreSQL         | Query stats, connections, cache hit rate      |
| MongoDB            | Operations/sec, document reads, latency       |
| Kubernetes Cluster | CPU, Memory, Pod status                       |

---

## Connection Strings

### PostgreSQL (ภายใน Cluster)

```
postgresql://odsuser:odspassword@postgresql.database-pg.svc.cluster.local:5432/odsperf
```

### MongoDB (ภายใน Cluster)

```
mongodb://odsuser:odspassword@mongodb.database-mongo.svc.cluster.local:27017/odsperf
```

### Connection จาก Local Machine (Port Forward)

```bash
# Terminal 1: Port forward PostgreSQL
make port-forward-postgresql
# Connection: postgresql://odsuser:odspassword@localhost:5432/odsperf

# Terminal 2: Port forward MongoDB
make port-forward-mongodb
# Connection: mongodb://odsuser:odspassword@localhost:27017/odsperf
```

---

## Step 2: ODS Service (Rust + Axum)

### โครงสร้าง Source Code

```
src/
├── main.rs              # Entry point — init logging, DB, server
├── config.rs            # Config จาก environment variables
├── error.rs             # AppError → HTTP response (thiserror)
├── state.rs             # AppState — shared PgPool + MongoDB Database
├── models.rs            # Request / Response / PgTransaction / MongoTransaction DTOs
├── db/
│   ├── postgres.rs      # PgPoolOptions::connect()
│   └── mongodb.rs       # Client::with_uri_str() + ping
└── handlers/
    ├── mod.rs           # Router + middleware stack
    ├── health.rs        # GET  /health
    ├── pg.rs            # POST /v1/query-pg
    └── mongo.rs         # POST /v1/query-mongo
```

### Build และ Deploy

```bash
# 1. Build Docker image (ทำจาก project root)
docker build -t odsperf-demo:latest .

# 2. Deploy ลง Kubernetes
kubectl apply -f infra/ods-service/deployment.yaml
kubectl apply -f infra/ods-service/service.yaml

# 3. Apply HTTPRoute (ถ้ายังไม่ได้ apply)
kubectl apply -f infra/istio/httproute.yaml

# 4. ตรวจสอบ
kubectl get pods -n ods-service
kubectl logs -n ods-service -l app=ods-service -f
```

### Test API

```bash
# ผ่าน port-forward
kubectl port-forward -n ods-service svc/ods-service 8080:80

curl -s -X POST http://localhost:8080/v1/query-pg \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1, "start_year": 2025,
    "end_month":   12, "end_year": 2025
  }' | jq '{db,total,elapsed_ms}'
```

ดู API Reference เต็มที่ [docs/api-reference.md](docs/api-reference.md)

### Environment Variables

| Variable         | Required | Default  | Description                        |
|-----------------|----------|----------|------------------------------------|
| `DATABASE_URL`  | ✅        | —        | PostgreSQL connection string       |
| `MONGODB_URI`   | ✅        | —        | MongoDB connection string          |
| `MONGODB_DB`    | ❌        | odsperf  | MongoDB database name              |
| `PORT`          | ❌        | 8080     | HTTP listen port                   |
| `RUST_LOG`      | ❌        | info     | Log level (debug/info/warn/error)  |
| `RUST_LOG_FORMAT` | ❌     | pretty   | `json` สำหรับ Kubernetes          |

---

## Step 3: Database Schema

### PostgreSQL

ตาราง ODS แปลงจาก DB2 — ดูรายละเอียดเต็มได้ที่ [docs/schema-account-transaction.md](docs/schema-account-transaction.md)

| Table | Schema | Primary Key | SQL |
|-------|--------|-------------|-----|
| `account_transaction` | `odsperf` | `iacct, drun, cseq` | [init-schema.sql](infra/postgresql/init-schema.sql) |

**รัน DDL:**

```bash
make port-forward-postgresql &
sleep 2
psql "postgresql://odsuser:odspassword@localhost:5432/odsperf" \
  -f infra/postgresql/init-schema.sql
```

### MongoDB

Schema สำหรับ MongoDB จะถูกสร้างใน Step 3 (Rust service) — MongoDB เป็น schemaless
แต่ใช้ collection ชื่อ `account_transaction` ใน database `odsperf` เช่นกัน เพื่อให้ benchmark เปรียบเทียบได้ตรงกัน

---

## Step 3: (Coming Soon) — Rust ODS Service

Rust application สำหรับ benchmark และเปรียบเทียบ performance ระหว่าง PostgreSQL และ MongoDB:
- CRUD operations benchmark
- Concurrent load testing
- Latency / Throughput comparison
- ส่ง custom metrics ไปยัง Prometheus

---

## การลบ Infrastructure ทั้งหมด

```bash
# ลบทุกอย่าง (Helm releases + Namespaces)
make clean

# ลบเฉพาะ PostgreSQL (และ PVC)
make clean-pg

# ลบเฉพาะ MongoDB (และ PVC)
make clean-mongo
```

> ⚠️ `make clean` จะลบ PersistentVolumeClaim ของ PostgreSQL และ MongoDB ด้วย
> ข้อมูลจะหายทั้งหมด

---

## Architecture Overview

```
                         Internet / Local
                               │
                    ┌──────────▼──────────┐
                    │   Istio Gateway      │  namespace: ingress
                    │  (Gateway API v1)    │
                    └──────┬──────┬────────┘
                           │      │
              HTTPRoute     │      │  HTTPRoute
           grafana.local    │      │  prometheus.local
                           │      │
              ┌────────────▼┐    ┌▼────────────────┐
              │   Grafana   │    │   Prometheus     │
              └─────────────┘    └──────────────────┘
               namespace: monitoring
                    │ scrape metrics
         ┌──────────┴──────────┐
         │                     │
┌────────▼────────┐   ┌────────▼────────┐
│   PostgreSQL    │   │    MongoDB      │
│ + pg_exporter   │   │ + mongo_exporter│
└─────────────────┘   └─────────────────┘
    namespace: databases
```

---

## Troubleshooting

### Gateway IP ไม่ได้รับ (Pending)

**Docker Desktop**: ตรวจสอบว่า Kubernetes เปิดอยู่และ LoadBalancer ทำงานได้

**minikube**: รัน `minikube tunnel` ใน terminal แยก:
```bash
minikube tunnel
```

### Pod ค้างอยู่ที่ Pending

ตรวจสอบ resource:
```bash
kubectl describe pod <pod-name> -n <namespace>
# ดูที่ Events section
```

อาจเกิดจาก resource ไม่เพียงพอ ลองเพิ่ม Memory/CPU ให้ minikube:
```bash
minikube stop
minikube start --cpus=6 --memory=12288
```

### Prometheus ไม่เห็น metrics จาก PostgreSQL หรือ MongoDB

ตรวจสอบ ServiceMonitor:
```bash
kubectl get servicemonitor -n monitoring
kubectl get servicemonitor -n databases
```

ตรวจสอบ Prometheus targets:
```
http://localhost:9090/targets
```

### Grafana Dashboard ไม่แสดงข้อมูล

รอประมาณ 2-3 นาทีหลังจากติดตั้ง เพื่อให้ Prometheus เก็บ metrics ได้ก่อน
แล้วลอง refresh dashboard
