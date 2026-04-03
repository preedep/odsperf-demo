#!/bin/bash
# Update dashboard ConfigMap from JSON file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_FILE="$PROJECT_ROOT/infra/monitoring/dashboards/ods-service-dashboard.json"
CONFIGMAP_FILE="$PROJECT_ROOT/infra/monitoring/dashboards/ods-service-dashboard-configmap.yaml"

echo "📊 Updating dashboard ConfigMap..."

# Read JSON and escape it properly for YAML
JSON_CONTENT=$(cat "$JSON_FILE" | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')

# Create new ConfigMap with proper indentation
cat > "$CONFIGMAP_FILE" << 'EOF'
# =============================================================================
# Grafana Dashboard ConfigMap for ODS Service
# Mounted by Helm dashboardsConfigMaps.default → provider folder: ODS Performance
# Do NOT add grafana_dashboard: "1" label — sidecar would load it to General (wrong folder)
# =============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: ods-service-dashboard
  namespace: monitoring
data:
  ods-service-dashboard.json: |
EOF

# Append JSON content with proper indentation (4 spaces)
cat "$JSON_FILE" | sed 's/^/    /' >> "$CONFIGMAP_FILE"

echo "✅ ConfigMap updated successfully!"
echo "📝 File: $CONFIGMAP_FILE"
echo ""
echo "To apply changes:"
echo "  kubectl apply -f $CONFIGMAP_FILE"
echo "  kubectl rollout restart deployment grafana -n monitoring"
