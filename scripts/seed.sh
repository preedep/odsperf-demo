#!/usr/bin/env bash
# =============================================================================
# seed.sh — Full data seeding pipeline (apple-to-apple benchmark)
#
# Flow:
#   1. generate_csv   → data/mock_transactions.csv (1M rows, NO DB needed)
#   2. load_pg        → PostgreSQL  (reads same CSV)
#   3. load_mongo     → MongoDB     (reads same CSV)
#
# Both DBs get IDENTICAL data → fair performance comparison
#
# Usage:
#   ./scripts/seed.sh                  # full pipeline
#   ./scripts/seed.sh --csv-only       # step 1 only
#   ./scripts/seed.sh --pg-only        # step 2 only (CSV must exist)
#   ./scripts/seed.sh --mongo-only     # step 3 only (CSV must exist)
#   ./scripts/seed.sh --no-mongo       # steps 1+2 only
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
CSV_PATH="${CSV_PATH:-data/mock_transactions.csv}"
DATABASE_URL="${DATABASE_URL:-postgresql://odsuser:odspassword@localhost:5432/odsperf}"
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"
BUILD_MODE="${BUILD_MODE:-release}"

# ── Flags ─────────────────────────────────────────────────────────────────────
DO_CSV=true
DO_PG=true
DO_MONGO=true

for arg in "$@"; do
  case "$arg" in
    --csv-only)   DO_PG=false;  DO_MONGO=false ;;
    --pg-only)    DO_CSV=false; DO_MONGO=false ;;
    --mongo-only) DO_CSV=false; DO_PG=false    ;;
    --no-mongo)   DO_MONGO=false               ;;
    --no-pg)      DO_PG=false                  ;;
    --help|-h)
      grep "^#" "$0" | grep -E "Usage:|  \." | sed 's/^# //'
      exit 0 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log_section() { printf "\n${BOLD}${CYAN}══════ %s ══════${NC}\n" "$1"; }
log_ok()      { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail()    { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info()    { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }

build_bin() {
  local bin="$1"
  log_info "Building ${bin} (${BUILD_MODE})..."
  if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --bin "$bin" 2>&1 | tail -3
    echo "target/release/${bin}"
  else
    cargo build --bin "$bin" 2>&1 | tail -3
    echo "target/debug/${bin}"
  fi
}

check_psql() {
  psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1 || \
    log_fail "Cannot connect to PostgreSQL. Start port-forward first:
    kubectl port-forward svc/postgresql 5432:5432 -n database-pg &"
}

check_mongo() {
  mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | \
    grep -q "1" || \
    log_fail "Cannot connect to MongoDB. Start port-forward first:
    kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &"
}

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${BLUE}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║        ODS Performance Demo — Data Seeding Pipeline         ║\n"
printf "║              (apple-to-apple benchmark data)                ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"
log_info "CSV path   : ${CSV_PATH}"
log_info "PostgreSQL : ${DATABASE_URL%%@*}@..."
log_info "MongoDB    : ${MONGODB_URI%%@*}@..."
log_info "Steps      : CSV=${DO_CSV}  PG=${DO_PG}  Mongo=${DO_MONGO}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Generate CSV
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_CSV" = true ]; then
  log_section "Step 1 — Generate CSV"

  if [ -f "$CSV_PATH" ]; then
    ROW_COUNT=$(tail -n +2 "$CSV_PATH" | wc -l | xargs)
    log_info "Existing CSV found: ${CSV_PATH} (${ROW_COUNT} rows)"
    read -p "Regenerate? (y/N): " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_ok "Keeping existing CSV"
    else
      BIN=$(build_bin generate_csv)
      OUTPUT_PATH="$CSV_PATH" "$BIN"
    fi
  else
    BIN=$(build_bin generate_csv)
    OUTPUT_PATH="$CSV_PATH" "$BIN"
  fi

  [ -f "$CSV_PATH" ] && log_ok "CSV ready: ${CSV_PATH}" || log_fail "CSV generation failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Load PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_PG" = true ]; then
  log_section "Step 2 — Load PostgreSQL"
  [ -f "$CSV_PATH" ] || log_fail "CSV not found: ${CSV_PATH}. Run without --pg-only first."
  check_psql

  # Check existing rows
  EXISTING=$(psql "$DATABASE_URL" -t -c \
    "SELECT COUNT(*) FROM odsperf.account_transaction;" 2>/dev/null | xargs || echo "0")
  if [ "$EXISTING" -gt 0 ]; then
    log_info "PostgreSQL already has ${EXISTING} rows"
    read -p "Truncate and reload? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      psql "$DATABASE_URL" -c "TRUNCATE TABLE odsperf.account_transaction;" > /dev/null
      log_ok "Table truncated"
    else
      log_info "Skipping PostgreSQL load (existing data kept)"
      DO_PG=false
    fi
  fi

  if [ "$DO_PG" = true ]; then
    BIN=$(build_bin load_pg)
    CSV_PATH="$CSV_PATH" DATABASE_URL="$DATABASE_URL" "$BIN"

    FINAL=$(psql "$DATABASE_URL" -t -c \
      "SELECT COUNT(*) FROM odsperf.account_transaction;" | xargs)
    log_ok "PostgreSQL: ${FINAL} rows loaded"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Load MongoDB
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_MONGO" = true ]; then
  log_section "Step 3 — Load MongoDB"
  [ -f "$CSV_PATH" ] || log_fail "CSV not found: ${CSV_PATH}. Run without --mongo-only first."
  check_mongo

  # Check existing documents
  EXISTING=$(mongosh "$MONGODB_URI" --quiet --eval \
    "db.getSiblingDB('${MONGODB_DB}').account_transaction.countDocuments()" \
    2>/dev/null | tr -d '[:space:]' | grep -o '[0-9]*' | head -1 || echo "0")

  if [ "${EXISTING:-0}" -gt 0 ]; then
    log_info "MongoDB already has ${EXISTING} documents"
    read -p "Delete all and reload? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      mongosh "$MONGODB_URI" --quiet --eval \
        "db.getSiblingDB('${MONGODB_DB}').account_transaction.deleteMany({})" > /dev/null
      log_ok "Collection cleared"
    else
      log_info "Skipping MongoDB load (existing data kept)"
      DO_MONGO=false
    fi
  fi

  if [ "$DO_MONGO" = true ]; then
    BIN=$(build_bin load_mongo)
    CSV_PATH="$CSV_PATH" MONGODB_URI="$MONGODB_URI" MONGODB_DB="$MONGODB_DB" "$BIN"

    FINAL=$(mongosh "$MONGODB_URI" --quiet --eval \
      "db.getSiblingDB('${MONGODB_DB}').account_transaction.countDocuments()" \
      2>/dev/null | tr -d '[:space:]' | grep -o '[0-9]*' | head -1)
    log_ok "MongoDB: ${FINAL} documents loaded"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
printf "\n${GREEN}${BOLD}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║                   Seeding Complete!                         ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"
log_info "Both DBs now have identical data — ready for benchmark"
printf "\n${CYAN}Next steps:${NC}\n"
printf "  ./scripts/test-api.sh --repeat 10    # compare latency\n"
printf "  ./scripts/test-api.sh --verbose      # inspect responses\n\n"
