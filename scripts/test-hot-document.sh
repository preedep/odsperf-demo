#!/bin/bash
# =============================================================================
# Hot Document Write Test Script for MongoDB
# =============================================================================
# Tests MongoDB performance with hot documents by simulating batch writes
# that repeatedly append to the same document's "statements" array.
# This mimics aggregation/final statement scenarios where the same document
# is written multiple times.
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Default values
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"
BUILD_MODE="${BUILD_MODE:-release}"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         MongoDB Hot Document Write Performance Test                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if MongoDB is accessible
echo -e "${YELLOW}🔍 Checking MongoDB connection...${NC}"
if mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ ping: 1 })" > /dev/null 2>&1; then
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

echo ""
echo -e "${CYAN}📋 Test Scenario:${NC}"
echo -e "   This test simulates a ${YELLOW}hot document${NC} scenario where multiple batch"
echo -e "   processes write to the same documents repeatedly, appending to an"
echo -e "   embedded array (similar to aggregating transactions into final statements)."
echo ""
echo -e "${CYAN}🎯 What This Tests:${NC}"
echo -e "   • Document growth performance (array append operations)"
echo -e "   • Write contention on frequently updated documents"
echo -e "   • MongoDB's handling of document updates vs inserts"
echo -e "   • Real-world batch aggregation scenarios"
echo ""

# Build the binary
echo -e "${YELLOW}🔨 Building test binary...${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

if [ "$BUILD_MODE" = "release" ]; then
    echo -e "${CYAN}   Mode: Release (optimized)${NC}"
    cargo build --release --bin test_hot_document 2>&1 | grep -E "(Compiling|Finished|error)" || true
    BINARY_PATH="target/release/test_hot_document"
else
    echo -e "${CYAN}   Mode: Debug${NC}"
    cargo build --bin test_hot_document 2>&1 | grep -E "(Compiling|Finished|error)" || true
    BINARY_PATH="target/debug/test_hot_document"
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}❌ Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Build completed${NC}"
echo ""

# Show environment
echo -e "${CYAN}🔧 Configuration:${NC}"
echo -e "   • MongoDB URI: ${MONGODB_URI}"
echo -e "   • Database: ${MONGODB_DB}"
echo -e "   • Collection: ${MAGENTA}final_statements${NC}"
echo ""

# Confirm before running
echo -e "${YELLOW}⚠️  This test will:${NC}"
echo -e "   1. Drop the existing 'final_statements' collection (if any)"
echo -e "   2. Create compound index {iacct: 1, dtrans: 1} for efficient lookups"
echo -e "   3. Create 10 hot account documents"
echo -e "   4. Perform 10,000 write operations (1,000 writes × 10 accounts)"
echo -e "   5. Append 10 statements per write (100,000 total statements)"
echo ""
read -p "$(echo -e ${CYAN}Continue with the test? [y/N]:${NC} )" -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Test cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                     Starting Performance Test                          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Run the test
START_TIME=$(date +%s)
MONGODB_URI="$MONGODB_URI" MONGODB_DB="$MONGODB_DB" "$BINARY_PATH"
EXIT_CODE=$?
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Test Completed Successfully!                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📊 Additional Information:${NC}"
    echo -e "   • Total execution time: ${TOTAL_DURATION} seconds"
    echo ""
    echo -e "${BLUE}💡 Next Steps:${NC}"
    echo "  1. Query the collection:"
    echo "     mongosh \"$MONGODB_URI\" --eval 'db.final_statements.findOne()'"
    echo ""
    echo "  2. Check document sizes:"
    echo "     mongosh \"$MONGODB_URI\" --eval 'db.final_statements.stats()'"
    echo ""
    echo "  3. Compare with normalized approach:"
    echo "     ./scripts/test-api.sh"
    echo ""
    echo "  4. View metrics in Grafana dashboards"
    echo ""
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                         Test Failed!                                   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Please check the error messages above for details.${NC}"
    echo ""
    exit 1
fi
