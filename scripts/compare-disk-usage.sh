#!/usr/bin/env bash
# =============================================================================
# compare-disk-usage.sh — Compare disk usage between PostgreSQL and MongoDB
#
# Dynamic discovery: all tables in the PostgreSQL schema and all collections
# in the MongoDB database are auto-detected. No code changes needed when
# adding new tables or collections.
#
# Usage:
#   ./scripts/compare-disk-usage.sh
#   DATABASE_URL=... MONGODB_URI=... MONGODB_DB=... ./scripts/compare-disk-usage.sh
#
# Options:
#   --skip-counts   Use pg_stat estimates instead of COUNT(*) (faster)
#
# Dependencies: psql, mongosh, jq, bc
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
PG_SCHEMA="${PG_SCHEMA:-odsperf}"
SKIP_COUNTS=false

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --skip-counts) SKIP_COUNTS=true ;;
    *) printf "${YELLOW}ℹ${NC}  Unknown option: %s (ignored)\n" "$arg" ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log_ok()      { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail()    { printf "${RED}✘${NC}  %s\n" "$1" >&2; exit 1; }
log_info()    { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }
log_section() { printf "\n${BOLD}${CYAN}══════ %s ══════${NC}\n" "$1"; }

bytes_to_human() {
  local bytes=${1:-0}
  if (( bytes < 1024 )); then
    printf "%d B" "$bytes"
  elif (( bytes < 1048576 )); then
    printf "%.2f KB" "$(echo "scale=4; $bytes / 1024" | bc)"
  elif (( bytes < 1073741824 )); then
    printf "%.2f MB" "$(echo "scale=4; $bytes / 1048576" | bc)"
  else
    printf "%.2f GB" "$(echo "scale=4; $bytes / 1073741824" | bc)"
  fi
}

# fmt_num: add thousand separators portably (avoid locale-dependent %'d)
fmt_num() {
  local n=${1:-0}
  printf "%d" "$n" | sed ':a;s/\B[0-9]\{3\}\>/, /;ta' | tr -d ' ' | \
    sed 's/,/, /g' | tr -d ' ' 2>/dev/null || printf "%d" "$n"
  # fallback: just print the number
  true
}
# simpler version that works everywhere:
fmt_num() { printf "%d" "${1:-0}"; }

SEP="─────────────────────────────────────────────────────────────────────"
HDR_FMT="${BOLD}%-30s | %15s | %15s${NC}"
ROW_FMT="%-30s | %15s | %15s"

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${BLUE}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║        Disk Usage Comparison — PostgreSQL vs MongoDB        ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"
if $SKIP_COUNTS; then
  printf "${YELLOW}ℹ${NC}  Row counts: using pg_stat estimates (--skip-counts)\n"
fi

# =============================================================================
# STEP 1 — Collect PostgreSQL data
# =============================================================================
log_section "PostgreSQL Disk Usage"

log_info "Connecting to PostgreSQL..."
psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1 || \
  log_fail "Cannot connect to PostgreSQL. Run:
    kubectl port-forward svc/postgresql 5432:5432 -n database-pg &"
log_ok "Connected to PostgreSQL"

# Get all table names + byte sizes in one query → JSON array
# Includes tables added in the future automatically (no hardcoding)
PG_SIZES_JSON=$(psql "$DATABASE_URL" -t -A -c "
SELECT COALESCE(
  json_agg(row_to_json(t) ORDER BY t.total_bytes DESC),
  '[]'
)
FROM (
  SELECT
    c.relname                       AS name,
    pg_relation_size(c.oid)         AS data_bytes,
    pg_indexes_size(c.oid)          AS index_bytes,
    pg_total_relation_size(c.oid)   AS total_bytes
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = '${PG_SCHEMA}'
    AND c.relkind = 'r'
) t;" 2>/dev/null)

# Enrich each table entry with an exact row count (or pg_stat estimate)
# Result: PG_JSON = [{name, data_bytes, index_bytes, total_bytes, rows}, ...]
PG_JSON="[]"
while IFS= read -r tbl; do
  if $SKIP_COUNTS; then
    # Use pg_stat_user_tables estimate (may lag behind actual count)
    cnt=$(psql "$DATABASE_URL" -t -A -c \
      "SELECT COALESCE(n_live_tup, 0) FROM pg_stat_user_tables
       WHERE schemaname='${PG_SCHEMA}' AND relname='${tbl}';" \
      2>/dev/null | xargs || echo "0")
  else
    # Exact count (slower for large tables, but accurate)
    cnt=$(psql "$DATABASE_URL" -t -A -c \
      "SELECT COUNT(*) FROM ${PG_SCHEMA}.${tbl};" \
      2>/dev/null | xargs || echo "0")
  fi
  entry=$(echo "$PG_SIZES_JSON" | jq \
    --arg n "$tbl" --argjson c "${cnt:-0}" \
    '.[] | select(.name == $n) | . + {rows: $c}')
  PG_JSON=$(echo "$PG_JSON" | jq --argjson e "$entry" '. + [$e]')
done < <(echo "$PG_SIZES_JSON" | jq -r '.[].name')

# ── Per-table pretty output (psql native) ─────────────────────────────────────
echo ""
printf "${CYAN}Per-Table Statistics:${NC}\n"
psql "$DATABASE_URL" -c "
SELECT
    c.relname                                              AS \"Table\",
    pg_size_pretty(pg_relation_size(c.oid))               AS \"Data Size\",
    pg_size_pretty(pg_indexes_size(c.oid))                AS \"Index Size\",
    pg_size_pretty(pg_total_relation_size(c.oid))         AS \"Total Size\",
    COALESCE(to_char(s.n_live_tup, 'FM999,999,999'), '?') AS \"Est. Rows\"
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s
       ON s.relname = c.relname AND s.schemaname = n.nspname
WHERE n.nspname = '${PG_SCHEMA}'
  AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;" 2>/dev/null

# ── Index details ─────────────────────────────────────────────────────────────
echo ""
printf "${CYAN}Index Details:${NC}\n"
psql "$DATABASE_URL" -c "
SELECT
    tablename                                                       AS \"Table\",
    indexname                                                       AS \"Index\",
    pg_size_pretty(pg_relation_size(schemaname||'.'||indexname))   AS \"Size\"
FROM pg_indexes
WHERE schemaname = '${PG_SCHEMA}'
ORDER BY tablename, pg_relation_size(schemaname||'.'||indexname) DESC;" 2>/dev/null

# ── Schema totals ─────────────────────────────────────────────────────────────
PG_TOTAL_ROWS=$(echo  "$PG_JSON" | jq '[.[].rows]        | add // 0')
PG_DATA_BYTES=$(echo  "$PG_JSON" | jq '[.[].data_bytes]  | add // 0')
PG_INDEX_BYTES=$(echo "$PG_JSON" | jq '[.[].index_bytes] | add // 0')
PG_TOTAL_BYTES=$(echo "$PG_JSON" | jq '[.[].total_bytes] | add // 0')
PG_TABLE_COUNT=$(echo "$PG_JSON" | jq  'length')

echo ""
printf "${CYAN}Schema Total (${PG_SCHEMA}):${NC}\n"
printf "  Tables      : ${BOLD}%s${NC}\n"  "$PG_TABLE_COUNT"
printf "  Rows        : ${BOLD}%s${NC}\n"  "$(fmt_num "$PG_TOTAL_ROWS")"
printf "  Data Size   : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$PG_DATA_BYTES")"
printf "  Index Size  : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$PG_INDEX_BYTES")"
printf "  Total Size  : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$PG_TOTAL_BYTES")"

# =============================================================================
# STEP 2 — Collect MongoDB data
# =============================================================================
log_section "MongoDB Disk Usage"

log_info "Connecting to MongoDB..."
mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | \
  grep -q "1" || \
  log_fail "Cannot connect to MongoDB. Run:
    kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &"
log_ok "Connected to MongoDB"

# Discover all collections + stats in one mongosh call → JSON array
# [{name, docs, data_bytes, index_bytes, total_bytes}, ...]
MONGO_JSON=$(mongosh "$MONGODB_URI" --quiet --eval "
const db2   = db.getSiblingDB('${MONGODB_DB}');
const names = db2.getCollectionNames()
                 .filter(n => !n.startsWith('system.'))
                 .sort();
const result = [];
names.forEach(name => {
  try {
    const s = db2[name].stats();
    result.push({
      name:        name,
      docs:        s.count            || 0,
      data_bytes:  s.storageSize      || 0,
      index_bytes: s.totalIndexSize   || 0,
      total_bytes: (s.storageSize || 0) + (s.totalIndexSize || 0)
    });
  } catch(e) {
    result.push({ name: name, docs: 0, data_bytes: 0, index_bytes: 0, total_bytes: 0 });
  }
});
result.sort((a, b) => b.total_bytes - a.total_bytes);
print(JSON.stringify(result));
" 2>/dev/null)

# ── Per-collection pretty output ──────────────────────────────────────────────
echo ""
printf "${CYAN}Per-Collection Statistics:${NC}\n"
printf "  %-26s | %12s | %12s | %12s | %12s\n" \
  "Collection" "Docs" "Data Size" "Index Size" "Total Size"
printf "  %s\n" "$(printf '%.0s─' {1..84})"
while IFS= read -r name; do
  docs=$(echo "$MONGO_JSON" | jq -r --arg n "$name" \
    '.[] | select(.name == $n) | .docs')
  data=$(echo "$MONGO_JSON" | jq -r --arg n "$name" \
    '.[] | select(.name == $n) | .data_bytes')
  idx=$(echo  "$MONGO_JSON" | jq -r --arg n "$name" \
    '.[] | select(.name == $n) | .index_bytes')
  tot=$(echo  "$MONGO_JSON" | jq -r --arg n "$name" \
    '.[] | select(.name == $n) | .total_bytes')
  printf "  %-26s | %12s | %12s | %12s | %12s\n" \
    "$name" \
    "$(fmt_num "$docs")" \
    "$(bytes_to_human "$data")" \
    "$(bytes_to_human "$idx")" \
    "$(bytes_to_human "$tot")"
done < <(echo "$MONGO_JSON" | jq -r '.[].name')

# ── Index details ─────────────────────────────────────────────────────────────
echo ""
printf "${CYAN}Index Details:${NC}\n"
mongosh "$MONGODB_URI" --quiet --eval "
const db2   = db.getSiblingDB('${MONGODB_DB}');
const names = db2.getCollectionNames().filter(n => !n.startsWith('system.'));
const fmt   = (b) => b < 1048576
  ? (b/1024).toFixed(2)    + ' KB'
  : (b/1048576).toFixed(2) + ' MB';
names.sort().forEach(col => {
  try {
    const sizes = db2[col].stats().indexSizes;
    db2[col].getIndexes().forEach(idx => {
      const sz = sizes[idx.name] || 0;
      print('  ' + col.padEnd(26) + '  ' + idx.name.padEnd(36) + ' : ' + fmt(sz));
    });
  } catch(e) {}
});
" 2>/dev/null

# ── Database totals ───────────────────────────────────────────────────────────
MONGO_TOTAL_DOCS=$(echo  "$MONGO_JSON" | jq '[.[].docs]        | add // 0')
MONGO_DATA_BYTES=$(echo  "$MONGO_JSON" | jq '[.[].data_bytes]  | add // 0')
MONGO_INDEX_BYTES=$(echo "$MONGO_JSON" | jq '[.[].index_bytes] | add // 0')
MONGO_TOTAL_BYTES=$(echo "$MONGO_JSON" | jq '[.[].total_bytes] | add // 0')
MONGO_COL_COUNT=$(echo   "$MONGO_JSON" | jq 'length')

echo ""
printf "${CYAN}Database Total (${MONGODB_DB}):${NC}\n"
printf "  Collections : ${BOLD}%s${NC}\n"  "$MONGO_COL_COUNT"
printf "  Docs        : ${BOLD}%s${NC}\n"  "$(fmt_num "$MONGO_TOTAL_DOCS")"
printf "  Data Size   : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$MONGO_DATA_BYTES")"
printf "  Index Size  : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$MONGO_INDEX_BYTES")"
printf "  Total Size  : ${BOLD}%s${NC}\n"  "$(bytes_to_human "$MONGO_TOTAL_BYTES")"

# =============================================================================
# STEP 3 — Side-by-side comparison (fully dynamic)
# =============================================================================
log_section "Comparison Summary"

printf "\n${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════════╗\n"
printf "║               Disk Usage Comparison (Per Table)                 ║\n"
printf "╚══════════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

printf "\n$HDR_FMT\n" "Metric" "PostgreSQL" "MongoDB"
printf "%s\n" "$SEP"

# Union of all table/collection names from both databases, sorted
# Tables missing from one side are shown with a "(DB only)" label
ALL_NAMES=$(
  { echo "$PG_JSON"    | jq -r '.[].name';
    echo "$MONGO_JSON" | jq -r '.[].name'; } \
  | sort -u
)


while IFS= read -r name; do
  # ── Check presence in each DB ───────────────────────────────────────────────
  in_pg=$(echo "$PG_JSON"    | jq --arg n "$name" 'map(select(.name == $n)) | length')
  in_mg=$(echo "$MONGO_JSON" | jq --arg n "$name" 'map(select(.name == $n)) | length')

  # ── Extract PG values ───────────────────────────────────────────────────────
  if [ "$in_pg" -gt 0 ]; then
    pg_rows=$(echo "$PG_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .rows')
    pg_data=$(echo "$PG_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .data_bytes')
    pg_idx=$(echo  "$PG_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .index_bytes')
    pg_tot=$(echo  "$PG_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .total_bytes')
    fmt_pg_rows=$(fmt_num "$pg_rows")
    fmt_pg_data=$(bytes_to_human "$pg_data")
    fmt_pg_idx=$(bytes_to_human  "$pg_idx")
    fmt_pg_tot=$(bytes_to_human  "$pg_tot")
  else
    pg_rows=0; pg_tot=0
    fmt_pg_rows="—"; fmt_pg_data="—"; fmt_pg_idx="—"; fmt_pg_tot="—"
  fi

  # ── Extract Mongo values ────────────────────────────────────────────────────
  if [ "$in_mg" -gt 0 ]; then
    mg_docs=$(echo "$MONGO_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .docs')
    mg_data=$(echo "$MONGO_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .data_bytes')
    mg_idx=$(echo  "$MONGO_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .index_bytes')
    mg_tot=$(echo  "$MONGO_JSON" | jq -r --arg n "$name" \
      '.[] | select(.name == $n) | .total_bytes')
    fmt_mg_docs=$(fmt_num "$mg_docs")
    fmt_mg_data=$(bytes_to_human "$mg_data")
    fmt_mg_idx=$(bytes_to_human  "$mg_idx")
    fmt_mg_tot=$(bytes_to_human  "$mg_tot")
  else
    mg_docs=0; mg_tot=0
    fmt_mg_docs="—"; fmt_mg_data="—"; fmt_mg_idx="—"; fmt_mg_tot="—"
  fi

  # ── Table header: show "only" label when table exists in one DB only ─────────
  if   [ "$in_pg" -eq 0 ]; then
    printf "${BOLD}  %s ${YELLOW}(MongoDB only)${NC}\n" "$name"
  elif [ "$in_mg" -eq 0 ]; then
    printf "${BOLD}  %s ${YELLOW}(PostgreSQL only)${NC}\n" "$name"
  else
    printf "${BOLD}  %s${NC}\n" "$name"
  fi

  printf "$ROW_FMT\n" "    Rows / Docs"  "$fmt_pg_rows"  "$fmt_mg_docs"
  printf "$ROW_FMT\n" "    Data Size"    "$fmt_pg_data"  "$fmt_mg_data"
  printf "$ROW_FMT\n" "    Index Size"   "$fmt_pg_idx"   "$fmt_mg_idx"
  printf "$ROW_FMT\n" "    Total Size"   "$fmt_pg_tot"   "$fmt_mg_tot"
  printf "%s\n" "$SEP"

done <<< "$ALL_NAMES"

# ── Grand total ───────────────────────────────────────────────────────────────
printf "${BOLD}  TOTAL (all tables / collections)${NC}\n"
printf "$ROW_FMT\n" "    Rows / Docs" \
  "$(fmt_num "$PG_TOTAL_ROWS")"  "$(fmt_num "$MONGO_TOTAL_DOCS")"
printf "$ROW_FMT\n" "    Data Size" \
  "$(bytes_to_human "$PG_DATA_BYTES")"   "$(bytes_to_human "$MONGO_DATA_BYTES")"
printf "$ROW_FMT\n" "    Index Size" \
  "$(bytes_to_human "$PG_INDEX_BYTES")"  "$(bytes_to_human "$MONGO_INDEX_BYTES")"
printf "${BOLD}$ROW_FMT${NC}\n" "    Total Size" \
  "$(bytes_to_human "$PG_TOTAL_BYTES")"  "$(bytes_to_human "$MONGO_TOTAL_BYTES")"

# ── Storage efficiency winner ─────────────────────────────────────────────────
echo ""
printf "${BOLD}Storage Efficiency (total):${NC}\n"

if [ "${PG_TOTAL_BYTES:-0}" -gt 0 ] && [ "${MONGO_TOTAL_BYTES:-0}" -gt 0 ]; then
  if [ "$PG_TOTAL_BYTES" -lt "$MONGO_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=1; ($MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES) * 100 / $PG_TOTAL_BYTES" | bc)
    DELTA=$(echo "$MONGO_TOTAL_BYTES - $PG_TOTAL_BYTES" | bc)
    printf "  ${GREEN}✔ PostgreSQL uses less total disk space${NC}\n"
    printf "  MongoDB uses ${BOLD}%s%%${NC} more (${BOLD}%s${NC} larger)\n" \
      "$DIFF" "$(bytes_to_human "$DELTA")"
  elif [ "$MONGO_TOTAL_BYTES" -lt "$PG_TOTAL_BYTES" ]; then
    DIFF=$(echo "scale=1; ($PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES) * 100 / $MONGO_TOTAL_BYTES" | bc)
    DELTA=$(echo "$PG_TOTAL_BYTES - $MONGO_TOTAL_BYTES" | bc)
    printf "  ${GREEN}✔ MongoDB uses less total disk space${NC}\n"
    printf "  PostgreSQL uses ${BOLD}%s%%${NC} more (${BOLD}%s${NC} larger)\n" \
      "$DIFF" "$(bytes_to_human "$DELTA")"
  else
    printf "  ${YELLOW}Both databases use the same total disk space${NC}\n"
  fi
fi

# ── Bytes per row — all tables/collections, "—" where absent ─────────────────
echo ""
printf "${BOLD}Bytes per Row/Doc:${NC}\n"
printf "${BOLD}%-30s | %15s | %15s${NC}\n" "Table / Collection" "PostgreSQL" "MongoDB"
printf "%s\n" "$SEP"

while IFS= read -r name; do
  in_pg=$(echo "$PG_JSON"    | jq --arg n "$name" 'map(select(.name == $n)) | length')
  in_mg=$(echo "$MONGO_JSON" | jq --arg n "$name" 'map(select(.name == $n)) | length')

  # PostgreSQL side
  if [ "$in_pg" -gt 0 ]; then
    pg_rows=$(echo "$PG_JSON" | jq -r --arg n "$name" '.[] | select(.name == $n) | .rows')
    pg_tot=$(echo  "$PG_JSON" | jq -r --arg n "$name" '.[] | select(.name == $n) | .total_bytes')
    if [ "${pg_rows:-0}" -gt 0 ]; then
      pg_bpr=$(echo "scale=1; $pg_tot / $pg_rows" | bc)
      fmt_pg_bpr="${pg_bpr} B/row"
    else
      fmt_pg_bpr="0 rows"
    fi
  else
    fmt_pg_bpr="—"
  fi

  # MongoDB side
  if [ "$in_mg" -gt 0 ]; then
    mg_docs=$(echo "$MONGO_JSON" | jq -r --arg n "$name" '.[] | select(.name == $n) | .docs')
    mg_tot=$(echo  "$MONGO_JSON" | jq -r --arg n "$name" '.[] | select(.name == $n) | .total_bytes')
    if [ "${mg_docs:-0}" -gt 0 ]; then
      mg_bpr=$(echo "scale=1; $mg_tot / $mg_docs" | bc)
      fmt_mg_bpr="${mg_bpr} B/doc"
    else
      fmt_mg_bpr="0 docs"
    fi
  else
    fmt_mg_bpr="—"
  fi

  printf "$ROW_FMT\n" "  $name" "$fmt_pg_bpr" "$fmt_mg_bpr"
done <<< "$ALL_NAMES"

echo ""
printf "${GREEN}${BOLD}✓ Disk usage comparison complete!${NC}\n\n"
