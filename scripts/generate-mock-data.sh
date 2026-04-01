#!/bin/bash
# =============================================================================
# Mock Data Generator Script for PostgreSQL
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DATABASE_URL="${DATABASE_URL:-postgresql://odsuser:odspassword@localhost:5432/odsperf}"
BUILD_MODE="${BUILD_MODE:-release}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PostgreSQL Mock Data Generator for ODS Performance Demo  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if PostgreSQL is accessible
echo -e "${YELLOW}🔍 Checking PostgreSQL connection...${NC}"
if psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ PostgreSQL is accessible${NC}"
else
    echo -e "${RED}❌ Cannot connect to PostgreSQL${NC}"
    echo -e "${YELLOW}💡 Make sure PostgreSQL is running and accessible${NC}"
    echo ""
    echo "If running in Kubernetes, start port-forward first:"
    echo "  cd infra && make port-forward-postgresql &"
    echo ""
    exit 1
fi

# Check if schema exists
echo -e "${YELLOW}🔍 Checking if schema exists...${NC}"
if psql "$DATABASE_URL" -c "SELECT 1 FROM odsperf.account_transaction LIMIT 1;" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Schema exists${NC}"
    
    # Count existing records
    EXISTING_COUNT=$(psql "$DATABASE_URL" -t -c "SELECT COUNT(*) FROM odsperf.account_transaction;" | xargs)
    echo -e "${BLUE}📊 Existing records: ${EXISTING_COUNT}${NC}"
    
    if [ "$EXISTING_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Table already contains data${NC}"
        read -p "Do you want to truncate the table first? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}🗑️  Truncating table...${NC}"
            psql "$DATABASE_URL" -c "TRUNCATE TABLE odsperf.account_transaction;"
            echo -e "${GREEN}✅ Table truncated${NC}"
        fi
    fi
else
    echo -e "${RED}❌ Schema does not exist${NC}"
    echo -e "${YELLOW}💡 Creating schema...${NC}"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    
    if [ -f "$PROJECT_ROOT/infra/postgresql/init-schema.sql" ]; then
        psql "$DATABASE_URL" -f "$PROJECT_ROOT/infra/postgresql/init-schema.sql"
        echo -e "${GREEN}✅ Schema created${NC}"
    else
        echo -e "${RED}❌ init-schema.sql not found${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${YELLOW}🔨 Building mock data generator...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --bin generate_mock_data
    BINARY_PATH="target/release/generate_mock_data"
else
    cargo build --bin generate_mock_data
    BINARY_PATH="target/debug/generate_mock_data"
fi

echo -e "${GREEN}✅ Build completed${NC}"
echo ""

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Starting Data Generation                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Run the generator
DATABASE_URL="$DATABASE_URL" "$BINARY_PATH"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  Generation Complete!                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verify data
echo -e "${YELLOW}🔍 Verifying data...${NC}"
FINAL_COUNT=$(psql "$DATABASE_URL" -t -c "SELECT COUNT(*) FROM odsperf.account_transaction;" | xargs)
echo -e "${GREEN}📊 Total records in database: ${FINAL_COUNT}${NC}"

# Show date range
echo -e "${YELLOW}📅 Date range:${NC}"
psql "$DATABASE_URL" -c "SELECT MIN(dtrans) as min_date, MAX(dtrans) as max_date FROM odsperf.account_transaction;"

echo ""
echo -e "${BLUE}💡 Next steps:${NC}"
echo "  1. Test the API: ./scripts/test-api.sh"
echo "  2. View data: psql \"$DATABASE_URL\" -c \"SELECT * FROM odsperf.account_transaction LIMIT 10;\""
echo "  3. Check Grafana dashboards for performance metrics"
echo ""
