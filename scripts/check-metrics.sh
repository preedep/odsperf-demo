#!/bin/bash
# Check ODS Service metrics

set -e

echo "📊 Checking ODS Service metrics..."
echo ""

# Port forward in background
kubectl port-forward -n ods-service svc/ods-service 8890:80 > /dev/null 2>&1 &
PF_PID=$!

# Wait for port forward to be ready
sleep 3

echo "🔍 Fetching metrics from http://localhost:8890/metrics"
echo ""

# Fetch and display metrics
METRICS=$(curl -s http://localhost:8890/metrics 2>/dev/null)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 System Metrics (Gauge):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$METRICS" | grep -E '^(process_|node_)' | grep -v '#' || echo "No system metrics found"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗄️  Database Pool Metrics (Gauge):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$METRICS" | grep -E '^db_pool_' | grep -v '#' || echo "No pool metrics found"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔢 Database Query Metrics (Counter):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$METRICS" | grep -E '^db_queries_total' | grep -v '#' || echo "No query counter found"
echo "$METRICS" | grep -E '^db_errors_total' | grep -v '#' || echo "No error counter found"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Database Query Duration (Histogram):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$METRICS" | grep -E '^db_query_duration_seconds' | grep -v '#' | head -10 || echo "No duration histogram found"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 HTTP Metrics (existing):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$METRICS" | grep -E '^http_requests_total' | grep -v '#' | head -5 || echo "No HTTP metrics found"

# Cleanup
kill $PF_PID 2>/dev/null
wait $PF_PID 2>/dev/null || true

echo ""
echo "✅ Metrics check complete!"
