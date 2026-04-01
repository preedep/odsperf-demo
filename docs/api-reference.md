# API Reference — ODS Performance Demo

Base URL (via Istio Gateway): `http://ods.local`
Base URL (port-forward):      `http://localhost:8080`

---

## Endpoints

| Method | Path              | Database   | Description                     |
|--------|-------------------|------------|---------------------------------|
| GET    | `/health`         | —          | Health check / liveness probe   |
| POST   | `/v1/query-pg`    | PostgreSQL | Query account transactions      |
| POST   | `/v1/query-mongo` | MongoDB    | Query account transactions      |

---

## GET /health

### Response `200 OK`

```json
{
  "status":  "ok",
  "service": "odsperf-demo",
  "version": "0.1.0"
}
```

---

## POST /v1/query-pg

Query `odsperf.account_transaction` in **PostgreSQL** for a given account number and month/year range.

### Request Headers

| Header          | Required | Description                          |
|-----------------|----------|--------------------------------------|
| `Content-Type`  | ✅        | `application/json`                   |
| `x-request-id`  | ❌        | Custom request ID (auto-generated if omitted) |

### Request Body

```json
{
  "account_no":  "12345678901",
  "start_month": 1,
  "start_year":  2025,
  "end_month":   3,
  "end_year":    2025
}
```

| Field         | Type    | Required | Constraint            | Description               |
|---------------|---------|----------|-----------------------|---------------------------|
| `account_no`  | string  | ✅        | max 11 chars          | Account number (`iacct`)  |
| `start_month` | integer | ✅        | 1–12                  | Start month               |
| `start_year`  | integer | ✅        | —                     | Start year                |
| `end_month`   | integer | ✅        | 1–12                  | End month (inclusive)     |
| `end_year`    | integer | ✅        | —                     | End year                  |

Date range: from **first day** of start month to **last day** of end month (inclusive).

### Response `200 OK`

```json
{
  "request_id": "018e2c4a-1f3b-7b2a-9d4e-5c8f1a2b3c4d",
  "db":         "postgresql",
  "account_no": "12345678901",
  "period": {
    "from": "2025-01",
    "to":   "2025-03"
  },
  "total":      45,
  "elapsed_ms": 12,
  "data": [
    {
      "iacct":       "12345678901",
      "drun":        "2025-01-15",
      "cseq":        1,
      "dtrans":      "2025-01-15",
      "ddate":       "2025-01-15",
      "ttime":       "10:30",
      "cmnemo":      "TRF",
      "cchannel":    "MOB",
      "ctr":         "01",
      "cbr":         "0001",
      "cterm":       "T0001",
      "camt":        "D",
      "aamount":     "1500.00",
      "abal":        "48500.00",
      "description": "Transfer out",
      "time_hms":    "10:30:45"
    }
  ]
}
```

### Response Fields

| Field        | Type    | Description                                    |
|-------------|---------|------------------------------------------------|
| `request_id` | string  | Correlation ID (from header or auto-generated) |
| `db`         | string  | `"postgresql"` or `"mongodb"`                  |
| `account_no` | string  | Echo of the requested account number           |
| `period`     | object  | `from` / `to` in `YYYY-MM` format              |
| `total`      | integer | Number of records returned                     |
| `elapsed_ms` | integer | Query + serialization time in milliseconds     |
| `data`       | array   | Transaction records (nullable fields omitted)  |

### Error Responses

| Status | Code              | Cause                               |
|--------|-------------------|-------------------------------------|
| 400    | `BAD_REQUEST`     | Invalid account_no, dates, or range |
| 500    | `DB_ERROR`        | PostgreSQL query failed             |
| 500    | `INTERNAL_ERROR`  | Unexpected server error             |

```json
{
  "error": {
    "code":    "BAD_REQUEST",
    "message": "account_no must not be empty"
  }
}
```

---

## POST /v1/query-mongo

Identical request/response schema to `/v1/query-pg` but queries **MongoDB** `account_transaction` collection.

`"db"` field in response will be `"mongodb"`.

---

## Logging

All requests produce structured log lines. In Kubernetes (`RUST_LOG_FORMAT=json`):

```json
{
  "timestamp": "2025-04-01T09:00:00.123Z",
  "level":     "INFO",
  "span":      "http",
  "method":    "POST",
  "path":      "/v1/query-pg",
  "request_id":"018e2c4a-...",
  "status":    200,
  "latency_ms": 12
}
```

Query spans emit additional fields:

```json
{
  "span":       "query_pg",
  "db":         "postgresql",
  "account_no": "12345678901",
  "start":      "2025-01",
  "end":        "2025-03",
  "total":      45,
  "elapsed_ms": 10
}
```

---

## curl Examples

```bash
# Health check
curl http://ods.local/health

# Query PostgreSQL
curl -s -X POST http://ods.local/v1/query-pg \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1,
    "start_year":  2025,
    "end_month":   12,
    "end_year":    2025
  }' | jq .

# Query MongoDB
curl -s -X POST http://ods.local/v1/query-mongo \
  -H "Content-Type: application/json" \
  -d '{
    "account_no":  "12345678901",
    "start_month": 1,
    "start_year":  2025,
    "end_month":   12,
    "end_year":    2025
  }' | jq .

# Compare elapsed_ms between both DBs
for db in pg mongo; do
  echo "=== $db ===";
  curl -s -X POST http://ods.local/v1/query-${db} \
    -H "Content-Type: application/json" \
    -d '{"account_no":"12345678901","start_month":1,"start_year":2025,"end_month":12,"end_year":2025}' \
    | jq '{db: .db, total: .total, elapsed_ms: .elapsed_ms}';
done
```
