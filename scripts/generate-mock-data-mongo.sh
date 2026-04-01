#!/bin/bash
# =============================================================================
# Mock Data Generator Script for MongoDB
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"
BUILD_MODE="${BUILD_MODE:-release}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    MongoDB Mock Data Generator for ODS Performance Demo    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Check mongosh ─────────────────────────────────────────────────────────────
if ! command -v mongosh &>/dev/null; then
    echo -e "${RED}❌ mongosh not found${NC}"
    echo -e "${YELLOW}💡 Install: https://www.mongodb.com/docs/mongodb-shell/install/${NC}"
    exit 1
fi

# ── Check MongoDB connection ──────────────────────────────────────────────────
echo -e "${YELLOW}🔍 Checking MongoDB connection...${NC}"
if mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
    echo -e "${GREEN}✅ MongoDB is accessible${NC}"
else
    echo -e "${RED}❌ Cannot connect to MongoDB${NC}"
    echo -e "${YELLOW}💡 Make sure MongoDB is running and accessible${NC}"
    echo ""
    echo "If running in Kubernetes, start port-forward first:"
    echo "  cd infra && make port-forward-mongodb &"
    echo ""
    exit 1
fi

# ── Check collection & existing data ─────────────────────────────────────────
echo -e "${YELLOW}🔍 Checking collection...${NC}"

EXISTING_COUNT=$(mongosh "$MONGODB_URI" --quiet --eval \
    "db.getSiblingDB('${MONGODB_DB}').account_transaction.countDocuments()" 2>/dev/null || echo "0")

# Strip non-numeric
EXISTING_COUNT=$(echo "$EXISTING_COUNT" | tr -d '[:space:]' | grep -o '[0-9]*' | head -1)
EXISTING_COUNT="${EXISTING_COUNT:-0}"

if [ "$EXISTING_COUNT" -gt 0 ]; then
    echo -e "${BLUE}📊 Existing documents: ${EXISTING_COUNT}${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Collection already contains data${NC}"
    read -p "Do you want to delete all documents first? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}🗑️  Deleting all documents...${NC}"
        mongosh "$MONGODB_URI" --quiet --eval \
            "db.getSiblingDB('${MONGODB_DB}').account_transaction.deleteMany({})" 2>/dev/null
        echo -e "${GREEN}✅ Collection cleared${NC}"
    fi
else
    echo -e "${GREEN}✅ Collection is empty, ready to insert${NC}"
fi

# ── Build binary ──────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}🔨 Building mock data generator...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --bin generate_mock_data_mongo
    BINARY_PATH="target/release/generate_mock_data_mongo"
else
    cargo build --bin generate_mock_data_mongo
    BINARY_PATH="target/debug/generate_mock_data_mongo"
fi

echo -e "${GREEN}✅ Build completed${NC}"
echo ""

# ── Run generator ─────────────────────────────────────────────────────────────
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Starting Data Generation                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

MONGODB_URI="$MONGODB_URI" MONGODB_DB="$MONGODB_DB" "$BINARY_PATH"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  Generation Complete!                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Verify ────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}🔍 Verifying data...${NC}"

FINAL_COUNT=$(mongosh "$MONGODB_URI" --quiet --eval \
    "db.getSiblingDB('${MONGODB_DB}').account_transaction.countDocuments()" 2>/dev/null | \
    tr -d '[:space:]' | grep -o '[0-9]*' | head -1)

echo -e "${GREEN}📊 Total documents in collection: ${FINAL_COUNT}${NC}"

echo -e "${YELLOW}📅 Date range:${NC}"
mongosh "$MONGODB_URI" --quiet --eval "
  const col = db.getSiblingDB('${MONGODB_DB}').account_transaction;
  const agg = col.aggregate([{
    \$group: {
      _id: null,
      min_date: { \$min: '\$dtrans' },
      max_date: { \$max: '\$dtrans' }
    }
  }]).toArray();
  if (agg.length > 0) printjson(agg[0]);
" 2>/dev/null

echo ""
echo -e "${BLUE}💡 Next steps:${NC}"
echo "  1. Test the API : ./scripts/test-api.sh --mongo"
echo "  2. Compare both : ./scripts/test-api.sh --repeat 10"
echo "  3. Check Grafana dashboards for performance metrics"
echo ""
