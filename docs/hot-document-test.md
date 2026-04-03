# Hot Document Write Performance Test

## Overview

This test simulates a **hot document** scenario in MongoDB where multiple batch processes repeatedly write to the same documents by appending to an embedded array. This mimics real-world aggregation scenarios, such as:

- Batch processing that aggregates transactions into final statements
- Accumulating events or logs into summary documents
- Building denormalized views with embedded arrays

## Test Scenario

The test creates a collection called `account_statements` with documents structured similarly to the `/v1/query-pg-join` API response:

```json
{
  "iacct": "10000000000",
  "custid": "1234567890",
  "ctype": "SAVINGS",
  "dopen": "2020-05-15",
  "dclose": null,
  "cstatus": "ACTIVE",
  "cbranch": "0123",
  "segment": "RETAIL",
  "credit_limit": "50000.00",
  "statements": [
    {
      "iacct": "10000000000",
      "drun": "2025-03-15",
      "cseq": 1234,
      "dtrans": "2025-03-15",
      "ddate": "2025-03-15",
      "ttime": "14:30",
      "cmnemo": "DEP",
      "cchannel": "INET",
      "ctr": "01",
      "cbr": "0123",
      "cterm": "12345",
      "camt": "C",
      "aamount": "5000.00",
      "abal": "125000.00",
      "description": "SALARY PAYMENT",
      "time_hms": "14:30:45"
    }
    // ... more statements
  ]
}
```

## Test Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| Collection | `account_statements` | MongoDB collection name |
| Hot Accounts | 10 | Number of frequently updated documents |
| Writes per Account | 1,000 | Number of update operations per document |
| Statements per Write | 10 | Array elements appended per update |
| **Total Writes** | **10,000** | Total update operations |
| **Total Statements** | **100,000** | Total array elements inserted |

## What This Tests

### 1. Document Growth Performance
- MongoDB's handling of growing documents
- Array append operations (`$push` with `$each`)
- Document reallocation and fragmentation

### 2. Write Contention
- Performance impact of updating the same documents repeatedly
- Lock contention on hot documents
- Write throughput under contention

### 3. Embedded vs Normalized
- Comparison between embedded arrays vs separate collection
- Trade-offs between document size and query complexity
- Impact on read/write performance

## Running the Test

### Prerequisites

1. MongoDB must be running and accessible
2. For Kubernetes deployments, start port-forward:
   ```bash
   cd infra && make port-forward-mongodb &
   ```

### Execute the Test

```bash
./scripts/test-hot-document.sh
```

### Custom Configuration

```bash
# Use custom MongoDB connection
MONGODB_URI="mongodb://user:pass@host:27017/db" ./scripts/test-hot-document.sh

# Use debug build (faster compilation)
BUILD_MODE=debug ./scripts/test-hot-document.sh
```

## Understanding the Output

### Progress Report

```
✓ Iteration  100/1000 | Writes:   1000 | Batch:  45.23ms | Total:   4.52s |  221.2 writes/s |   2212.4 stmt/s
```

- **Iteration**: Current batch iteration (1-1000)
- **Writes**: Total write operations completed
- **Batch**: Time for current batch (all 10 accounts)
- **Total**: Cumulative test duration
- **writes/s**: Write operations per second
- **stmt/s**: Statements (array elements) per second

### Final Summary

```
📊 Write Statistics:
   • Total writes:                10000
   • Total statements:           100000
   • Total duration:              45.23 seconds

⚡ Performance Metrics:
   • Writes per second:           221.19
   • Statements per second:      2211.90

⏱️  Write Latency (ms):
   • Average:                       4.52
   • Minimum:                       2.10
   • Maximum:                      15.80

📄 Document Analysis:
   • Account 10000000000 ( 1/10):  10000 statements,   856432 bytes
   • Account 10000000001 ( 2/10):  10000 statements,   856789 bytes
   ...
```

## Performance Considerations

### Expected Performance

- **Writes/sec**: 200-500 (depends on hardware and MongoDB configuration)
- **Latency**: 2-10ms average (increases as documents grow)
- **Document Size**: ~850KB per document (10,000 statements)

### Factors Affecting Performance

1. **Document Size**: Larger documents may require reallocation
2. **Working Set**: Hot documents should fit in RAM
3. **Write Concern**: Default write concern affects throughput
4. **Index Overhead**: Indexes on array fields impact write speed
5. **Replication**: Replica set configuration affects latency

## Comparison with Normalized Approach

### Embedded (This Test)
✅ Single query to retrieve account + statements  
✅ Atomic updates  
❌ Document size limits (16MB BSON limit)  
❌ Write contention on hot documents  
❌ Slower writes as document grows  

### Normalized (Separate Collections)
✅ No document size limits  
✅ Better write distribution  
✅ Consistent write performance  
❌ Requires JOIN/lookup operations  
❌ No atomic updates across collections  

## Next Steps

After running the test:

1. **Query the collection**:
   ```bash
   mongosh "$MONGODB_URI" --eval 'db.account_statements.findOne()'
   ```

2. **Check collection statistics**:
   ```bash
   mongosh "$MONGODB_URI" --eval 'db.account_statements.stats()'
   ```

3. **Compare with normalized approach**:
   ```bash
   ./scripts/test-api.sh
   ```

4. **View metrics in Grafana** for detailed performance analysis

## Troubleshooting

### Connection Issues
```
❌ Cannot connect to MongoDB
```
- Verify MongoDB is running
- Check connection string
- For Kubernetes: ensure port-forward is active

### Build Failures
```
❌ Build failed
```
- Run `cargo clean` and retry
- Check Rust toolchain: `rustc --version`

### Performance Issues
- Check MongoDB logs for warnings
- Verify sufficient RAM for working set
- Review MongoDB profiler output
- Consider adjusting write concern for testing

## Related Documentation

- [Mock Data Generator](./mock-data-generator.md)
- [API Reference](./api-reference.md)
- [Schema Documentation](./schema-account-transaction.md)
