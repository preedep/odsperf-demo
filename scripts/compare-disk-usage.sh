#!/usr/bin/env bash
# =============================================================================
# compare-disk-usage.sh — Compare disk usage between PostgreSQL and MongoDB
#
# Usage:
#   ./scripts/compare-disk-usage.sh
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
DATABASE_URL="${DATABASE_URL:-postgresql://odsuser:odspassword@localhost:5432/odsperf}"
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_ok()   { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail() { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info() { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }
log_section() { printf "\n${BOLD}${CYAN}══════ %s ══════${NC}\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${BLUE}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║        Disk Usage Comparison — PostgreSQL vs MongoDB        ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL Disk Usage
# ─────────────────────────────────────────────────────────────────────────────
log_section "PostgreSQL Disk Usage"

log_info "Connecting to PostgreSQL..."
psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1 || \
  log_fail "Cannot connect to PostgreSQL. Start port-forward first:
    kubectl port-forward svc/postgresql 5432:5432 -n database-pg &"

log_ok "Connected to PostgreSQL"

# Get row count
PG_ROWS=$(psql "$DATABASE_URL" -t -c \
  "SELECT COUNT(*) FROM odsperf.account_transaction;" 2>/dev/null | xargs || echo "0")

# Get table size (data only)
PG_TABLE_SIZE=$(psql "$DATABASE_URL" -t -c \
  "SELECT pg_size_pretty(pg_relation_size('odsperf.account_transaction'));" 2>/dev/null | xargs || echo "0")

# Get total size (table + indexes)
PG_TOTAL_SIZE=$(psql "$DATABASE_URL" -t -c \
  "SELECT pg_size_pretty(pg_total_relation_size('odsperf.account_transaction'));" 2>/dev/null | xargs || echo "0")

# Get index sizes
PG_INDEXES_SIZE=$(psql "$DATABASE_URL" -t -c \
  "SELECT pg_size_pretty(pg_indexes_size('odsperf.account_transaction'));" 2>/dev/null | xargs || echo "0")

# Get table size in bytes for calculation
PG_TABLE_BYTES=$(psql "$DATABASE_URL" -t -c \
  "SELECT pg_relation_size('odsperf.account_transaction');" 2>/dev/null | xargs || echo "0")

PG_TOTAL_BYTES=$(psql "$DATABASE_URL" -t -c \
  "SELECT pg_total_relation_size('odsperf.account_transaction');" 2>/dev/null | xargs || echo "0")

printf "\n${CYAN}PostgreSQL Statistics:${NC}\n"
printf "  Rows          : ${BOLD}%'d${NC}\n" "$PG_ROWS"
printf "  Table Size    : ${BOLD}%s${NC}\n" "$PG_TABLE_SIZE"
printf "  Indexes Size  : ${BOLD}%s${NC}\n" "$PG_INDEXES_SIZE"
printf "  Total Size    : ${BOLD}%s${NC}\n" "$PG_TOTAL_SIZE"

# Show index details
echo ""
printf "${CYAN}Index Details:${NC}\n"
psql "$DATABASE_URL" -c \
  "SELECT 
    indexname AS index_name,
    pg_size_pretty(pg_relation_size(schemaname||'.'||indexname)) AS size
   FROM pg_indexes 
   WHERE schemaname = 'odsperf' 
     AND tablename = 'account_transaction'
   ORDER BY pg_relation_size(schemaname||'.'||indexname) DESC;" 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# MongoDB Disk Usage
# ─────────────────────────────────────────────────────────────────────────────
log_section "MongoDB Disk Usage"

log_info "Connecting to MongoDB..."
mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | \
  grep -q "1" || \
  log_fail "Cannot connect to MongoDB. Start port-forward first:
    kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &"

log_ok "Connected to MongoDB"

# Get collection stats
MONGO_STATS=$(mongosh "$MONGODB_URI" --quiet --eval "
  const stats = db.getSiblingDB('${MONGODB_DB}').account_transaction.stats();
  print(JSON.stringify({
    count: stats.count,
    size: stats.size,
    storageSize: stats.storageSize,
    totalIndexSize: stats.totalIndexSize,
    totalSize: stats.totalSize || (stats.storageSize + stats.totalIndexSize)
  }));
" 2>/dev/null)

# Parse JSON
MONGO_ROWS=$(echo "$MONGO_STATS" | jq -r '.count // 0')
MONGO_DATA_BYTES=$(echo "$MONGO_STATS" | jq -r '.size // 0')
MONGO_STORAGE_BYTES=$(echo "$MONGO_STATS" | jq -r '.storageSize // 0')
MONGO_INDEX_BYTES=$(echo "$MONGO_STATS" | jq -r '.totalIndexSize // 0')
MONGO_TOTAL_BYTES=$(echo "$MONGO_STATS" | jq -r '.totalSize // 0')

# Convert to human readable
bytes_to_human() {
  local bytes=$1
  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes} B"
  elif [ "$bytes" -lt 1048576 ]; then
    echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
  elif [ "$bytes" -lt 1073741824 ]; then
    echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
  else
    echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
  fi
}

MONGO_DATA_SIZE=$(bytes_to_human "$MONGO_DATA_BYTES")
MONGO_STORAGE_SIZE=$(bytes_to_human "$MONGO_STORAGE_BYTES")
MONGO_INDEX_SIZE=$(bytes_to_human "$MONGO_INDEX_BYTES")
MONGO_TOTAL_SIZE=$(bytes_to_human "$MONGO_TOTAL_BYTES")

printf "\n${CYAN}MongoDB Statistics:${NC}\n"
printf "  Documents     : ${BOLD}%'d${NC}\n" "$MONGO_ROWS"
printf "  Data Size     : ${BOLD}%s${NC}\n" "$MONGO_DATA_SIZE"
printf "  Storage Size  : ${BOLD}%s${NC} (with padding)\n" "$MONGO_STORAGE_SIZE"
printf "  Indexes Size  : ${BOLD}%s${NC}\n" "$MONGO_INDEX_SIZE"
printf "  Total Size    : ${BOLD}%s${NC}\n" "$MONGO_TOTAL_SIZE"

# Show index details
echo ""
printf "${CYAN}Index Details:${NC}\n"
mongosh "$MONGODB_URI" --quiet --eval "
  const indexes = db.getSiblingDB('${MONGODB_DB}').account_transaction.getIndexes();
  const stats = db.getSiblingDB('${MONGODB_DB}').account_transaction.stats().indexSizes;
  indexes.forEach(idx => {
    const size = stats[idx.name] || 0;
    const sizeKB = (size / 1024).toFixed(2);
    const sizeMB = (size / 1048576).toFixed(2);
    print(\`  \${idx.name.padEnd(30)} : \${sizeMB} MB\`);
  });
" 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# Comparison Summary
# ─────────────────────────────────────────────────────────────────────────────
log_section "Comparison Summary"

printf "\n${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║                    Disk Usage Comparison                         ║\n"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

printf "\n${BOLD}%-20s | %15s | %15s${NC}\n" "Metric" "PostgreSQL" "MongoDB"
printf "${BOLD}%s${NC}\n" "─────────────────────────────────────────────────────────────────"

printf "%-20s | %15s | %15s\n" "Rows/Documents" "$(printf "%'d" $PG_ROWS)" "$(printf "%'d" $MONGO_ROWS)"
printf "%-20s | %15s | %15s\n" "Data Size" "$PG_TABLE_SIZE" "$MONGO_STORAGE_SIZE"
printf "%-20s | %15s | %15s\n" "Index Size" "$PG_INDEXES_SIZE" "$MONGO_INDEX_SIZE"
printf "%-20s | %15s | %15s\n" "Total Size" "$PG_TOTAL_SIZE" "$MONGO_TOTAL_SIZE"

# Calculate winner (lower is better)
echo ""
printf "${BOLD}Storage Efficiency:${NC}\n"

if [ "$PG_TOTAL_BYTES" -gt 0 ] && [ "$MONGO_TOTAL_BYTES" -gt 0 ]; then
  if [ "$PG_TOTAL_BYTES" -lt "$MONGO_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=2; ($MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES) / $PG_TOTAL_BYTES * 100" | bc)
    DIFF_SIZE=$(bytes_to_human $(echo "$MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES" | bc))
    printf "  ${GREEN}PostgreSQL uses less disk space${NC}\n"
    printf "  MongoDB uses ${BOLD}%.1f%%${NC} more space (${BOLD}%s${NC} larger)\n" "$DIFF" "$DIFF_SIZE"
  elif [ "$MONGO_TOTAL_BYTES" -lt "$PG_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=2; ($PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES) / $MONGO_TOTAL_BYTES * 100" | bc)
    DIFF_SIZE=$(bytes_to_human $(echo "$PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES" | bc))
    printf "  ${GREEN}MongoDB uses less disk space${NC}\n"
    printf "  PostgreSQL uses ${BOLD}%.1f%%${NC} more space (${BOLD}%s${NC} larger)\n" "$DIFF" "$DIFF_SIZE"
  else
    printf "  ${YELLOW}Both databases use the same amount of space${NC}\n"
  fi
fi

# Per-row storage
if [ "$PG_ROWS" -gt 0 ]; then
  PG_BYTES_PER_ROW=$(echo "scale=2; $PG_TOTAL_BYTES / $PG_ROWS" | bc)
  printf "\n  PostgreSQL: ${BOLD}%.2f bytes/row${NC}\n" "$PG_BYTES_PER_ROW"
fi

if [ "$MONGO_ROWS" -gt 0 ]; then
  MONGO_BYTES_PER_DOC=$(echo "scale=2; $MONGO_TOTAL_BYTES / $MONGO_ROWS" | bc)
  printf "  MongoDB   : ${BOLD}%.2f bytes/document${NC}\n" "$MONGO_BYTES_PER_DOC"
fi

echo ""
printf "${GREEN}${BOLD}✓ Disk usage comparison complete!${NC}\n\n"
