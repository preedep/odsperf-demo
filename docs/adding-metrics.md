# Adding Metrics to ODS Service

## 📊 Overview

ODS Service ใช้ `metrics` crate และ `metrics-exporter-prometheus` สำหรับ export metrics ไปยัง Prometheus

## 🔧 Current Metrics

ตอนนี้มี metrics อยู่แล้ว:
- `http_requests_total` - จำนวน requests ทั้งหมด (counter)
- `http_request_duration_seconds` - ระยะเวลาในการ process request (histogram)

## ➕ How to Add New Metrics

### 1. **Counter Metrics** (นับจำนวน)

เหมาะสำหรับ: จำนวน events, errors, operations

```rust
// ใน handler หรือ function ที่ต้องการ track
use metrics;

// เพิ่มค่า counter
metrics::counter!("db_queries_total", 
    "database" => "postgresql",
    "operation" => "select"
).increment(1);

// หรือเพิ่มหลายค่าพร้อมกัน
metrics::counter!("cache_hits_total").increment(10);
```

**ตัวอย่าง: Track Database Errors**
```rust
// ใน src/handlers/pg.rs หรือ mongo.rs
if let Err(e) = query_result {
    metrics::counter!("db_errors_total",
        "database" => "postgresql",
        "error_type" => "connection_failed"
    ).increment(1);
    return Err(e);
}
```

### 2. **Gauge Metrics** (ค่าที่เปลี่ยนแปลงได้)

เหมาะสำหรับ: memory usage, active connections, queue size

```rust
// Set ค่า gauge
metrics::gauge!("db_pool_connections_active").set(active_count as f64);
metrics::gauge!("db_pool_connections_idle").set(idle_count as f64);

// เพิ่ม/ลดค่า
metrics::gauge!("active_requests").increment(1.0);
metrics::gauge!("active_requests").decrement(1.0);
```

**ตัวอย่าง: Track Connection Pool**
```rust
// ใน src/state.rs หรือที่ setup connection pool
pub async fn get_pool_metrics(pool: &PgPool) {
    let size = pool.size();
    let idle = pool.num_idle();
    let active = size - idle;
    
    metrics::gauge!("db_pool_connections_total").set(size as f64);
    metrics::gauge!("db_pool_connections_active").set(active as f64);
    metrics::gauge!("db_pool_connections_idle").set(idle as f64);
}
```

### 3. **Histogram Metrics** (กระจายของค่า)

เหมาะสำหรับ: latency, request size, query duration

```rust
// Record ค่า histogram
let start = std::time::Instant::now();
// ... do work ...
let duration = start.elapsed();

metrics::histogram!("db_query_duration_seconds",
    "database" => "postgresql",
    "query_type" => "join"
).record(duration.as_secs_f64());
```

**ตัวอย่าง: Track Query Duration**
```rust
// ใน src/handlers/pg.rs
pub async fn handle(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<QueryRequest>,
) -> Result<Json<QueryResponse>, AppError> {
    let start = std::time::Instant::now();
    
    let result = sqlx::query_as::<_, PgTransaction>(&payload.query)
        .fetch_all(&state.pg_pool)
        .await?;
    
    let duration = start.elapsed();
    
    // Record query duration
    metrics::histogram!("db_query_duration_seconds",
        "database" => "postgresql",
        "query_type" => "select"
    ).record(duration.as_secs_f64());
    
    Ok(Json(QueryResponse { data: result }))
}
```

## 📝 Complete Example: Add Memory & CPU Metrics

### Step 1: Add Dependencies

```toml
# Cargo.toml
[dependencies]
sysinfo = "0.30"  # For system metrics
```

### Step 2: Create Metrics Module

```rust
// src/metrics.rs
use sysinfo::{System, SystemExt, ProcessExt};
use std::sync::Arc;
use tokio::time::{interval, Duration};

pub fn start_system_metrics_collector() {
    tokio::spawn(async {
        let mut sys = System::new_all();
        let mut interval = interval(Duration::from_secs(5));
        
        loop {
            interval.tick().await;
            
            sys.refresh_all();
            
            // Memory metrics
            if let Some(process) = sys.process(sysinfo::get_current_pid().unwrap()) {
                let memory_bytes = process.memory() * 1024; // KB to bytes
                metrics::gauge!("process_resident_memory_bytes")
                    .set(memory_bytes as f64);
                
                let cpu_usage = process.cpu_usage() as f64;
                metrics::gauge!("process_cpu_usage_percent")
                    .set(cpu_usage);
            }
            
            // System metrics
            let total_memory = sys.total_memory() * 1024;
            let used_memory = sys.used_memory() * 1024;
            
            metrics::gauge!("node_memory_MemTotal_bytes")
                .set(total_memory as f64);
            metrics::gauge!("node_memory_MemUsed_bytes")
                .set(used_memory as f64);
        }
    });
}
```

### Step 3: Initialize in Main

```rust
// src/main.rs
mod metrics as metrics_collector;

#[tokio::main]
async fn main() -> Result<()> {
    // ... existing setup ...
    
    // Start system metrics collector
    metrics_collector::start_system_metrics_collector();
    
    // ... rest of main ...
}
```

## 🎯 Best Practices

### 1. **Naming Convention**
- ใช้ snake_case: `http_requests_total`
- ลงท้ายด้วย unit: `_seconds`, `_bytes`, `_total`
- Counter ลงท้ายด้วย `_total`: `db_queries_total`

### 2. **Labels**
- ใช้ labels สำหรับ dimensions: `database`, `method`, `status`
- อย่าใช้ labels ที่มี cardinality สูง (เช่น user_id, request_id)
- จำกัดจำนวน labels ไม่เกิน 5-7 labels

### 3. **Performance**
- Metrics มี overhead น้อยมาก แต่อย่าเรียกใน tight loop
- ใช้ sampling สำหรับ high-frequency events
- Cache metric instances ถ้าใช้บ่อย

## 📊 Testing Metrics

### 1. **Local Testing**

```bash
# Start service
cargo run

# Check metrics endpoint
curl http://localhost:8080/metrics

# Should see output like:
# http_requests_total{method="GET",path="/health",status="200"} 10
# http_request_duration_seconds_bucket{method="GET",path="/health",le="0.005"} 10
```

### 2. **Prometheus Query**

```promql
# Rate of requests
rate(http_requests_total[1m])

# 95th percentile latency
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[1m]))

# Memory usage
process_resident_memory_bytes
```

## 🔗 Resources

- [metrics crate docs](https://docs.rs/metrics/)
- [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/)
- [Prometheus best practices](https://prometheus.io/docs/practices/instrumentation/)

## 📝 Common Metrics to Add

### Database Metrics
```rust
// Connection pool
metrics::gauge!("db_pool_connections_active").set(active as f64);
metrics::gauge!("db_pool_connections_idle").set(idle as f64);
metrics::gauge!("db_pool_connections_max").set(max as f64);

// Query metrics
metrics::counter!("db_queries_total", "database" => "postgresql").increment(1);
metrics::histogram!("db_query_duration_seconds", "database" => "postgresql").record(duration);
metrics::counter!("db_errors_total", "database" => "postgresql", "type" => "timeout").increment(1);
```

### Cache Metrics
```rust
metrics::counter!("cache_hits_total").increment(1);
metrics::counter!("cache_misses_total").increment(1);
metrics::gauge!("cache_size_bytes").set(size as f64);
metrics::gauge!("cache_entries_total").set(count as f64);
```

### Business Metrics
```rust
metrics::counter!("transactions_processed_total", "type" => "payment").increment(1);
metrics::histogram!("transaction_amount_dollars").record(amount);
metrics::gauge!("active_users").set(count as f64);
```

## 🚀 Next Steps

1. เพิ่ม metrics ที่ต้องการใน code
2. Build และ deploy service ใหม่
3. Verify metrics ใน `/metrics` endpoint
4. เพิ่ม panels ใน Grafana dashboard
5. Setup alerts ใน Prometheus (optional)
