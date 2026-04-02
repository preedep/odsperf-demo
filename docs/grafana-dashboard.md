# ODS Service Grafana Dashboard

## Overview
Professional Grafana dashboard for monitoring ODS Service performance metrics including:
- **TPS (Transactions Per Second)** - Request rate by endpoint
- **Latency Percentiles** - p50, p95, p99 response times
- **HTTP Status Codes** - Success/error rate tracking
- **Error Rate** - 5xx error percentage

## Deployment

### 1. Apply ServiceMonitor
```bash
kubectl apply -f infra/ods-service/servicemonitor.yaml
```

### 2. Deploy Dashboard ConfigMap
```bash
kubectl apply -f infra/monitoring/dashboards/ods-service-dashboard-configmap.yaml
```

### 3. Rebuild and Deploy ODS Service
The service needs to be rebuilt with metrics support:

```bash
# Build Docker image with metrics
docker build -t odsperf-demo:latest .

# Restart the deployment to pick up new image
kubectl rollout restart deployment/ods-service -n ods-service

# Wait for rollout to complete
kubectl rollout status deployment/ods-service -n ods-service
```

### 4. Access Grafana
```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open browser to http://localhost:3000
# Login: admin / admin
# Navigate to Dashboards → ODS folder → "ODS Service Performance"
```

## Metrics Exposed

### HTTP Request Counter
```
http_requests_total{method, path, status}
```

### HTTP Request Duration Histogram
```
http_request_duration_seconds{method, path}
```

## Dashboard Panels

1. **Request Rate (TPS) by Endpoint** - Line chart showing requests/sec per API endpoint
2. **Total TPS** - Gauge showing overall request rate
3. **p95 Latency** - Gauge showing 95th percentile response time
4. **Response Time Percentiles** - Line chart with p50, p95, p99
5. **p95 Latency by Endpoint** - Per-endpoint latency tracking
6. **HTTP Status Codes** - Stacked area chart of status codes
7. **Error Rate (5xx)** - Gauge showing error percentage
8. **Total Requests (5m window)** - Request count stat

## Troubleshooting

### Dashboard not showing data
1. Check ServiceMonitor is created:
   ```bash
   kubectl get servicemonitor -n ods-service
   ```

2. Check Prometheus targets:
   ```bash
   kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
   # Open http://localhost:9090/targets
   # Look for ods-service endpoint
   ```

3. Verify metrics endpoint:
   ```bash
   kubectl port-forward -n ods-service svc/ods-service 8080:80
   curl http://localhost:8080/metrics
   ```

### Metrics not appearing
- Ensure the ODS service pod is running with the updated image
- Check pod logs: `kubectl logs -n ods-service -l app=ods-service`
- Verify Prometheus is scraping: Check Prometheus UI targets page
