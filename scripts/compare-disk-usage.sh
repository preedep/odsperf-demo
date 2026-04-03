#!/usr/bin/env bash
# =============================================================================
# compare-disk-usage.sh — Compare disk usage between PostgreSQL and MongoDB
#
# Shows per-table breakdown + totals across all tables in odsperf schema.
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
log_ok()      { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail()    { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info()    { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }
log_section() { printf "\n${BOLD}${CYAN}══════ %s ══════${NC}\n" "$1"; }

bytes_to_human() {
  local bytes=${1:-0}
  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes} B"
  elif [ "$bytes" -lt 1048576 ]; then
    printf "%.2f KB" "$(echo "scale=4; $bytes / 1024" | bc)"
  elif [ "$bytes" -lt 1073741824 ]; then
    printf "%.2f MB" "$(echo "scale=4; $bytes / 1048576" | bc)"
  else
    printf "%.2f GB" "$(echo "scale=4; $bytes / 1073741824" | bc)"
  fi
}

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

# ── Per-table stats ───────────────────────────────────────────────────────────
echo ""
printf "${CYAN}Per-Table Statistics:${NC}\n"
psql "$DATABASE_URL" -c "
SELECT
    t.table_name                                              AS \"Table\",
    to_char(s.n_live_tup, '999,999,999')                     AS \"Rows\",
    pg_size_pretty(pg_relation_size(c.oid))                  AS \"Data Size\",
    pg_size_pretty(pg_indexes_size(c.oid))                   AS \"Index Size\",
    pg_size_pretty(pg_total_relation_size(c.oid))            AS \"Total Size\"
FROM information_schema.tables t
JOIN pg_class c ON c.relname = t.table_name
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.table_schema
LEFT JOIN pg_stat_user_tables s ON s.relname = t.table_name AND s.schemaname = t.table_schema
WHERE t.table_schema = 'odsperf'
  AND t.table_type = 'BASE TABLE'
ORDER BY pg_total_relation_size(c.oid) DESC;
" 2>/dev/null

# ── Accurate row counts (pg_stat can lag — use COUNT) ────────────────────────
PG_ROWS_TXN=$(psql "$DATABASE_URL" -t -c \
  "SELECT COUNT(*) FROM odsperf.account_transaction;" 2>/dev/null | xargs || echo "0")

PG_ROWS_ACC=$(psql "$DATABASE_URL" -t -c \
  "SELECT COUNT(*) FROM odsperf.account_master;" 2>/dev/null | xargs || echo "0")

PG_ROWS_TOTAL=$((PG_ROWS_TXN + PG_ROWS_ACC))

# ── Totals across all tables in schema ────────────────────────────────────────
PG_DATA_BYTES=$(psql "$DATABASE_URL" -t -c "
SELECT COALESCE(SUM(pg_relation_size(c.oid)), 0)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

PG_INDEX_BYTES=$(psql "$DATABASE_URL" -t -c "
SELECT COALESCE(SUM(pg_indexes_size(c.oid)), 0)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

PG_TOTAL_BYTES=$(psql "$DATABASE_URL" -t -c "
SELECT COALESCE(SUM(pg_total_relation_size(c.oid)), 0)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

PG_DATA_SIZE=$(psql "$DATABASE_URL" -t -c "
SELECT pg_size_pretty(COALESCE(SUM(pg_relation_size(c.oid)), 0))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

PG_INDEX_SIZE=$(psql "$DATABASE_URL" -t -c "
SELECT pg_size_pretty(COALESCE(SUM(pg_indexes_size(c.oid)), 0))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

PG_TOTAL_SIZE=$(psql "$DATABASE_URL" -t -c "
SELECT pg_size_pretty(COALESCE(SUM(pg_total_relation_size(c.oid)), 0))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'odsperf' AND c.relkind = 'r';
" 2>/dev/null | xargs || echo "0")

echo ""
printf "${CYAN}Schema Total (all tables):${NC}\n"
printf "  Rows (txn)    : ${BOLD}%'d${NC}\n" "$PG_ROWS_TXN"
printf "  Rows (acct)   : ${BOLD}%'d${NC}\n" "$PG_ROWS_ACC"
printf "  Data Size     : ${BOLD}%s${NC}\n"  "$PG_DATA_SIZE"
printf "  Index Size    : ${BOLD}%s${NC}\n"  "$PG_INDEX_SIZE"
printf "  Total Size    : ${BOLD}%s${NC}\n"  "$PG_TOTAL_SIZE"

# ── Index details per table ───────────────────────────────────────────────────
echo ""
printf "${CYAN}Index Details:${NC}\n"
psql "$DATABASE_URL" -c "
SELECT
    tablename                                                          AS \"Table\",
    indexname                                                          AS \"Index\",
    pg_size_pretty(pg_relation_size(schemaname||'.'||indexname))      AS \"Size\"
FROM pg_indexes
WHERE schemaname = 'odsperf'
ORDER BY tablename, pg_relation_size(schemaname||'.'||indexname) DESC;
" 2>/dev/null

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

# ── Per-collection stats ──────────────────────────────────────────────────────
echo ""
printf "${CYAN}Per-Collection Statistics:${NC}\n"
mongosh "$MONGODB_URI" --quiet --eval "
const db2 = db.getSiblingDB('${MONGODB_DB}');
const cols = ['account_transaction', 'account_master'];
const pad = (s, n) => String(s).padStart(n);
const padL = (s, n) => String(s).padEnd(n);
const fmt = (b) => {
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b/1024).toFixed(2) + ' KB';
  if (b < 1073741824) return (b/1048576).toFixed(2) + ' MB';
  return (b/1073741824).toFixed(2) + ' GB';
};
console.log('  ' + padL('Collection', 22) + ' | ' + pad('Docs', 12) + ' | ' + pad('Data Size', 12) + ' | ' + pad('Index Size', 12) + ' | ' + pad('Total Size', 12));
console.log('  ' + '-'.repeat(78));
cols.forEach(name => {
  try {
    const s = db2[name].stats();
    const total = (s.storageSize || 0) + (s.totalIndexSize || 0);
    console.log('  ' + padL(name, 22) + ' | ' + pad(s.count.toLocaleString(), 12) + ' | ' + pad(fmt(s.storageSize || 0), 12) + ' | ' + pad(fmt(s.totalIndexSize || 0), 12) + ' | ' + pad(fmt(total), 12));
  } catch(e) {
    console.log('  ' + padL(name, 22) + ' | ' + pad('N/A', 12) + ' | ' + pad('N/A', 12) + ' | ' + pad('N/A', 12) + ' | ' + pad('N/A', 12));
  }
});
" 2>/dev/null

# ── Per-collection + totals ───────────────────────────────────────────────────
MONGO_STATS=$(mongosh "$MONGODB_URI" --quiet --eval "
const db2 = db.getSiblingDB('${MONGODB_DB}');
const cols = ['account_transaction', 'account_master'];
let result = { txn: {}, acc: {}, totalDocs: 0, totalStorage: 0, totalIndex: 0 };
cols.forEach(name => {
  try {
    const s = db2[name].stats();
    const entry = { docs: s.count || 0, storage: s.storageSize || 0, index: s.totalIndexSize || 0, total: (s.storageSize||0) + (s.totalIndexSize||0) };
    result.totalDocs    += entry.docs;
    result.totalStorage += entry.storage;
    result.totalIndex   += entry.index;
    if (name === 'account_transaction') result.txn = entry;
    if (name === 'account_master')      result.acc = entry;
  } catch(e) {}
});
result.totalSize = result.totalStorage + result.totalIndex;
print(JSON.stringify(result));
" 2>/dev/null)

MONGO_ROWS_TXN=$(echo "$MONGO_STATS"       | jq -r '.txn.docs // 0')
MONGO_ROWS_ACC=$(echo "$MONGO_STATS"       | jq -r '.acc.docs // 0')
MONGO_ROWS_TOTAL=$(echo "$MONGO_STATS"     | jq -r '.totalDocs // 0')
MONGO_TXN_DATA_BYTES=$(echo "$MONGO_STATS" | jq -r '.txn.storage // 0')
MONGO_TXN_IDX_BYTES=$(echo "$MONGO_STATS"  | jq -r '.txn.index // 0')
MONGO_TXN_TOTAL_BYTES=$(echo "$MONGO_STATS"| jq -r '.txn.total // 0')
MONGO_ACC_DATA_BYTES=$(echo "$MONGO_STATS" | jq -r '.acc.storage // 0')
MONGO_ACC_IDX_BYTES=$(echo "$MONGO_STATS"  | jq -r '.acc.index // 0')
MONGO_ACC_TOTAL_BYTES=$(echo "$MONGO_STATS"| jq -r '.acc.total // 0')
MONGO_STORAGE_BYTES=$(echo "$MONGO_STATS"  | jq -r '.totalStorage // 0')
MONGO_INDEX_BYTES=$(echo "$MONGO_STATS"    | jq -r '.totalIndex // 0')
MONGO_TOTAL_BYTES=$(echo "$MONGO_STATS"    | jq -r '.totalSize // 0')

echo ""
printf "${CYAN}Database Total (all collections):${NC}\n"
printf "  Docs (txn)    : ${BOLD}%'d${NC}\n" "$MONGO_ROWS_TXN"
printf "  Docs (acct)   : ${BOLD}%'d${NC}\n" "$MONGO_ROWS_ACC"
printf "  Storage Size  : ${BOLD}%s${NC} (with compression/padding)\n" "$(bytes_to_human $MONGO_STORAGE_BYTES)"
printf "  Index Size    : ${BOLD}%s${NC}\n"   "$(bytes_to_human $MONGO_INDEX_BYTES)"
printf "  Total Size    : ${BOLD}%s${NC}\n"   "$(bytes_to_human $MONGO_TOTAL_BYTES)"

# ── Index details per collection ──────────────────────────────────────────────
echo ""
printf "${CYAN}Index Details:${NC}\n"
mongosh "$MONGODB_URI" --quiet --eval "
const db2 = db.getSiblingDB('${MONGODB_DB}');
const cols = ['account_transaction', 'account_master'];
const fmt = (b) => (b/1048576).toFixed(2) + ' MB';
cols.forEach(col => {
  try {
    const sizes = db2[col].stats().indexSizes;
    db2[col].getIndexes().forEach(idx => {
      const sz = sizes[idx.name] || 0;
      console.log('  ' + col.padEnd(22) + '  ' + idx.name.padEnd(36) + ' : ' + fmt(sz));
    });
  } catch(e) {}
});
" 2>/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# Fetch PostgreSQL per-table bytes for summary
# ─────────────────────────────────────────────────────────────────────────────
pg_table_bytes() {  # args: table_name, metric (relation|indexes|total)
  local tbl="odsperf.$1"
  case "$2" in
    data)  psql "$DATABASE_URL" -t -c "SELECT pg_relation_size('${tbl}');"       2>/dev/null | xargs || echo "0" ;;
    index) psql "$DATABASE_URL" -t -c "SELECT pg_indexes_size('${tbl}');"        2>/dev/null | xargs || echo "0" ;;
    total) psql "$DATABASE_URL" -t -c "SELECT pg_total_relation_size('${tbl}');" 2>/dev/null | xargs || echo "0" ;;
  esac
}

PG_TXN_DATA_BYTES=$(pg_table_bytes account_transaction data)
PG_TXN_IDX_BYTES=$(pg_table_bytes  account_transaction index)
PG_TXN_TOTAL_BYTES=$(pg_table_bytes account_transaction total)
PG_ACC_DATA_BYTES=$(pg_table_bytes account_master data)
PG_ACC_IDX_BYTES=$(pg_table_bytes  account_master index)
PG_ACC_TOTAL_BYTES=$(pg_table_bytes account_master total)

# ─────────────────────────────────────────────────────────────────────────────
# Comparison Summary
# ─────────────────────────────────────────────────────────────────────────────
log_section "Comparison Summary"

SEP="─────────────────────────────────────────────────────────────────────"
HDR="${BOLD}%-30s | %15s | %15s${NC}"
ROW="%-30s | %15s | %15s"
DIV="%s\n"

printf "\n${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║               Disk Usage Comparison (Per Table)                 ║\n"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

printf "\n$HDR\n" "Metric" "PostgreSQL" "MongoDB"
printf "$DIV" "$SEP"

# ── account_transaction ───────────────────────────────────────────────────────
printf "${BOLD}  account_transaction${NC}\n"
printf "$ROW\n" "    Rows / Docs"   "$(printf "%'d" $PG_ROWS_TXN)"                    "$(printf "%'d" $MONGO_ROWS_TXN)"
printf "$ROW\n" "    Data Size"     "$(bytes_to_human $PG_TXN_DATA_BYTES)"            "$(bytes_to_human $MONGO_TXN_DATA_BYTES)"
printf "$ROW\n" "    Index Size"    "$(bytes_to_human $PG_TXN_IDX_BYTES)"             "$(bytes_to_human $MONGO_TXN_IDX_BYTES)"
printf "$ROW\n" "    Total Size"    "$(bytes_to_human $PG_TXN_TOTAL_BYTES)"           "$(bytes_to_human $MONGO_TXN_TOTAL_BYTES)"

printf "$DIV" "$SEP"

# ── account_master ────────────────────────────────────────────────────────────
printf "${BOLD}  account_master${NC}\n"
printf "$ROW\n" "    Rows / Docs"   "$(printf "%'d" $PG_ROWS_ACC)"                    "$(printf "%'d" $MONGO_ROWS_ACC)"
printf "$ROW\n" "    Data Size"     "$(bytes_to_human $PG_ACC_DATA_BYTES)"            "$(bytes_to_human $MONGO_ACC_DATA_BYTES)"
printf "$ROW\n" "    Index Size"    "$(bytes_to_human $PG_ACC_IDX_BYTES)"             "$(bytes_to_human $MONGO_ACC_IDX_BYTES)"
printf "$ROW\n" "    Total Size"    "$(bytes_to_human $PG_ACC_TOTAL_BYTES)"           "$(bytes_to_human $MONGO_ACC_TOTAL_BYTES)"

printf "$DIV" "$SEP"

# ── Grand total ───────────────────────────────────────────────────────────────
printf "${BOLD}  TOTAL (all tables)${NC}\n"
printf "$ROW\n" "    Rows / Docs"   "$(printf "%'d" $PG_ROWS_TOTAL)"                  "$(printf "%'d" $MONGO_ROWS_TOTAL)"
printf "$ROW\n" "    Data Size"     "$PG_DATA_SIZE"                                   "$(bytes_to_human $MONGO_STORAGE_BYTES)"
printf "$ROW\n" "    Index Size"    "$PG_INDEX_SIZE"                                  "$(bytes_to_human $MONGO_INDEX_BYTES)"
printf "${BOLD}$ROW${NC}\n" "    Total Size"  "$PG_TOTAL_SIZE"                        "$(bytes_to_human $MONGO_TOTAL_BYTES)"

# ── Winner ────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}Storage Efficiency (total):${NC}\n"

if [ "${PG_TOTAL_BYTES:-0}" -gt 0 ] && [ "${MONGO_TOTAL_BYTES:-0}" -gt 0 ]; then
  if [ "$PG_TOTAL_BYTES" -lt "$MONGO_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=2; ($MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES) * 100 / $PG_TOTAL_BYTES" | bc)
    printf "  ${GREEN}✔ PostgreSQL uses less total disk space${NC}\n"
    printf "  MongoDB uses ${BOLD}%.1f%%${NC} more (${BOLD}%s${NC} larger)\n" "$DIFF" \
      "$(bytes_to_human $(echo "$MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES" | bc))"
  elif [ "$MONGO_TOTAL_BYTES" -lt "$PG_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=2; ($PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES) * 100 / $MONGO_TOTAL_BYTES" | bc)
    printf "  ${GREEN}✔ MongoDB uses less total disk space${NC}\n"
    printf "  PostgreSQL uses ${BOLD}%.1f%%${NC} more (${BOLD}%s${NC} larger)\n" "$DIFF" \
      "$(bytes_to_human $(echo "$PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES" | bc))"
  else
    printf "  ${YELLOW}Both databases use the same amount of space${NC}\n"
  fi
fi

# ── Per-row storage efficiency ────────────────────────────────────────────────
echo ""
printf "${BOLD}Bytes per Row/Doc:${NC}\n"
printf "${BOLD}%-30s | %15s | %15s${NC}\n" "Table" "PostgreSQL" "MongoDB"
printf "$DIV" "$SEP"

if [ "${PG_ROWS_TXN:-0}" -gt 0 ] && [ "${MONGO_ROWS_TXN:-0}" -gt 0 ]; then
  PG_BPR_TXN=$(echo "scale=1; $PG_TXN_TOTAL_BYTES / $PG_ROWS_TXN" | bc)
  MG_BPR_TXN=$(echo "scale=1; $MONGO_TXN_TOTAL_BYTES / $MONGO_ROWS_TXN" | bc)
  printf "$ROW\n" "  account_transaction" "${PG_BPR_TXN} B/row" "${MG_BPR_TXN} B/doc"
fi

if [ "${PG_ROWS_ACC:-0}" -gt 0 ] && [ "${MONGO_ROWS_ACC:-0}" -gt 0 ]; then
  PG_BPR_ACC=$(echo "scale=1; $PG_ACC_TOTAL_BYTES / $PG_ROWS_ACC" | bc)
  MG_BPR_ACC=$(echo "scale=1; $MONGO_ACC_TOTAL_BYTES / $MONGO_ROWS_ACC" | bc)
  printf "$ROW\n" "  account_master" "${PG_BPR_ACC} B/row" "${MG_BPR_ACC} B/doc"
fi

echo ""
printf "${GREEN}${BOLD}✓ Disk usage comparison complete!${NC}\n\n"
