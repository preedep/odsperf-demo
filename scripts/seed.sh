#!/usr/bin/env bash
# =============================================================================
# seed.sh — Full data seeding pipeline (apple-to-apple benchmark)
#
# Flow:
#   0. generate_account_csv → data/mock_accounts.csv  (account master)
#   0b. load_pg_accounts    → PostgreSQL odsperf.account_master
#   0c. load_mongo_accounts → MongoDB account_master collection
#   1. generate_csv         → data/mock_transactions.csv (1M rows, JOIN-ready)
#   2. load_pg              → PostgreSQL odsperf.account_transaction
#   3. load_mongo           → MongoDB account_transaction collection
#
# Both DBs get IDENTICAL data → fair performance comparison
# Transactions reference accounts in the bounded pool → JOIN testing enabled
#
# Usage:
#   ./scripts/seed.sh                    # full pipeline (accounts + transactions)
#   ./scripts/seed.sh --accounts-only    # step 0 only (generate + load accounts)
#   ./scripts/seed.sh --txn-only         # steps 1-3 only (transactions, CSV must exist)
#   ./scripts/seed.sh --csv-only         # steps 0+1 only (generate CSVs, no DB load)
#   ./scripts/seed.sh --pg-only          # load PG only (both CSVs must exist)
#   ./scripts/seed.sh --mongo-only       # load Mongo only (both CSVs must exist)
#   ./scripts/seed.sh --no-mongo         # skip all MongoDB steps
#   ./scripts/seed.sh --no-accounts      # skip account master pipeline
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
CSV_PATH="${CSV_PATH:-data/mock_transactions.csv}"
ACCOUNTS_CSV_PATH="${ACCOUNTS_CSV_PATH:-data/mock_accounts.csv}"
ACCOUNT_POOL_SIZE="${ACCOUNT_POOL_SIZE:-10000}"
DATABASE_URL="${DATABASE_URL:-postgresql://odsuser:odspassword@localhost:5432/odsperf}"
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"
BUILD_MODE="${BUILD_MODE:-release}"

# ── Flags ─────────────────────────────────────────────────────────────────────
DO_ACCOUNTS=true
DO_CSV=true
DO_PG=true
DO_MONGO=true

for arg in "$@"; do
  case "$arg" in
    --accounts-only) DO_CSV=false;     DO_PG=false;      DO_MONGO=false ;;
    --txn-only)      DO_ACCOUNTS=false                                   ;;
    --csv-only)      DO_PG=false;      DO_MONGO=false                    ;;
    --pg-only)       DO_CSV=false;     DO_MONGO=false;   DO_ACCOUNTS=false ;;
    --mongo-only)    DO_CSV=false;     DO_PG=false;      DO_ACCOUNTS=false ;;
    --no-mongo)      DO_MONGO=false                                      ;;
    --no-pg)         DO_PG=false                                         ;;
    --no-accounts)   DO_ACCOUNTS=false                                   ;;
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
  log_info "Building ${bin} (${BUILD_MODE})..." >&2
  if [ "$BUILD_MODE" = "release" ]; then
    cargo build --release --bin "$bin" 2>&1 | tail -3 >&2
    echo "target/release/${bin}"
  else
    cargo build --bin "$bin" 2>&1 | tail -3 >&2
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
log_info "Transactions CSV : ${CSV_PATH}"
log_info "Accounts CSV     : ${ACCOUNTS_CSV_PATH}"
log_info "Account pool     : ${ACCOUNT_POOL_SIZE} accounts"
log_info "PostgreSQL       : ${DATABASE_URL%%@*}@..."
log_info "MongoDB          : ${MONGODB_URI%%@*}@..."
log_info "Steps            : Accounts=${DO_ACCOUNTS}  CSV=${DO_CSV}  PG=${DO_PG}  Mongo=${DO_MONGO}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Account Master Pipeline
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_ACCOUNTS" = true ]; then
  log_section "Step 0a — Generate Account Master CSV"

  if [ -f "$ACCOUNTS_CSV_PATH" ]; then
    ACC_COUNT=$(tail -n +2 "$ACCOUNTS_CSV_PATH" | wc -l | xargs)
    log_info "Existing accounts CSV: ${ACCOUNTS_CSV_PATH} (${ACC_COUNT} rows)"
    log_ok "Using existing accounts CSV"
  else
    log_info "Accounts CSV not found, generating..."
    BIN=$(build_bin generate_account_csv)
    ACCOUNT_OUTPUT_PATH="$ACCOUNTS_CSV_PATH" ACCOUNT_POOL_SIZE="$ACCOUNT_POOL_SIZE" "$BIN"
    [ -f "$ACCOUNTS_CSV_PATH" ] && log_ok "Accounts CSV generated: ${ACCOUNTS_CSV_PATH}" || log_fail "Account CSV generation failed"
  fi

  if [ "$DO_PG" = true ]; then
    log_section "Step 0b — Load Account Master → PostgreSQL"
    check_psql

    # Ensure account_master table exists (with indexes)
    TABLE_EXISTS=$(psql "$DATABASE_URL" -t -c \
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'odsperf' AND table_name = 'account_master');" \
      2>/dev/null | xargs || echo "f")
    
    if [ "$TABLE_EXISTS" != "t" ]; then
      log_info "Table odsperf.account_master not found, creating schema..."
      "${SCRIPT_DIR}/init-pg-accounts.sh" || log_fail "Failed to initialize account_master schema"
    fi

    EXISTING=$(psql "$DATABASE_URL" -t -c \
      "SELECT COUNT(*) FROM odsperf.account_master;" 2>/dev/null | xargs || echo "0")
    if [ "$EXISTING" -gt 0 ]; then
      log_info "PostgreSQL account_master already has ${EXISTING} rows"
      read -p "Truncate and reload? (y/N): " -n 1 -r; echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        psql "$DATABASE_URL" -c "TRUNCATE TABLE odsperf.account_master;" > /dev/null
        log_ok "account_master truncated"
      else
        log_info "Skipping account_master PG load"
        SKIP_PG_ACCOUNTS=true
      fi
    fi

    if [ "${SKIP_PG_ACCOUNTS:-false}" != "true" ]; then
      BIN=$(build_bin load_pg_accounts)
      CSV_PATH="$ACCOUNTS_CSV_PATH" DATABASE_URL="$DATABASE_URL" "$BIN"
      FINAL=$(psql "$DATABASE_URL" -t -c \
        "SELECT COUNT(*) FROM odsperf.account_master;" | xargs)
      log_ok "PostgreSQL account_master: ${FINAL} rows loaded"
    fi
  fi

  if [ "$DO_MONGO" = true ]; then
    log_section "Step 0c — Load Account Master → MongoDB"
    check_mongo

    EXISTING=$(mongosh "$MONGODB_URI" --quiet --eval \
      "db.getSiblingDB('${MONGODB_DB}').account_master.countDocuments()" \
      2>/dev/null | tr -d '[:space:]' | grep -o '[0-9]*' | head -1 || echo "0")

    if [ "${EXISTING:-0}" -gt 0 ]; then
      log_info "MongoDB account_master already has ${EXISTING} documents"
      read -p "Delete all and reload? (y/N): " -n 1 -r; echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        mongosh "$MONGODB_URI" --quiet --eval \
          "db.getSiblingDB('${MONGODB_DB}').account_master.drop()" > /dev/null 2>&1
        log_ok "account_master collection dropped"
      else
        log_info "Skipping account_master MongoDB load"
        SKIP_MONGO_ACCOUNTS=true
      fi
    fi

    if [ "${SKIP_MONGO_ACCOUNTS:-false}" != "true" ]; then
      BIN=$(build_bin load_mongo_accounts)
      CSV_PATH="$ACCOUNTS_CSV_PATH" MONGODB_URI="$MONGODB_URI" MONGODB_DB="$MONGODB_DB" "$BIN"
      FINAL=$(mongosh "$MONGODB_URI" --quiet --eval \
        "db.getSiblingDB('${MONGODB_DB}').account_master.countDocuments()" \
        2>/dev/null | tr -d '[:space:]' | grep -o '[0-9]*' | head -1)
      log_ok "MongoDB account_master: ${FINAL} documents loaded"

      # Create indexes for account_master
      log_info "Creating account_master indexes..."
      mongosh "$MONGODB_URI" --quiet --eval "
        db.getSiblingDB('${MONGODB_DB}').account_master.createIndex({iacct: 1}, {unique: true, name: 'idx_pk_account_master'});
        db.getSiblingDB('${MONGODB_DB}').account_master.createIndex({custid: 1}, {name: 'idx_acctmaster_custid'});
        db.getSiblingDB('${MONGODB_DB}').account_master.createIndex({ctype: 1}, {name: 'idx_acctmaster_ctype'});
        db.getSiblingDB('${MONGODB_DB}').account_master.createIndex({cbranch: 1}, {name: 'idx_acctmaster_cbranch'});
        db.getSiblingDB('${MONGODB_DB}').account_master.createIndex({segment: 1}, {name: 'idx_acctmaster_segment'});
      " > /dev/null 2>&1
      log_ok "account_master indexes created"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Generate Transaction CSV (JOIN-ready pool)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_CSV" = true ]; then
  log_section "Step 1 — Generate Transaction CSV (JOIN-ready)"

  if [ -f "$CSV_PATH" ]; then
    ROW_COUNT=$(tail -n +2 "$CSV_PATH" | wc -l | xargs)
    log_info "Existing CSV found: ${CSV_PATH} (${ROW_COUNT} rows)"
    log_ok "Using existing CSV file"
  else
    log_info "CSV file not found, generating new one (ACCOUNT_POOL_SIZE=${ACCOUNT_POOL_SIZE})..."
    BIN=$(build_bin generate_csv)
    OUTPUT_PATH="$CSV_PATH" ACCOUNT_POOL_SIZE="$ACCOUNT_POOL_SIZE" "$BIN"
    [ -f "$CSV_PATH" ] && log_ok "CSV generated: ${CSV_PATH}" || log_fail "CSV generation failed"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Load PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_PG" = true ]; then
  log_section "Step 2 — Load PostgreSQL"
  [ -f "$CSV_PATH" ] || log_fail "CSV not found: ${CSV_PATH}. Run without --pg-only first."
  check_psql

  # Ensure schema and table exist (with indexes)
  TABLE_EXISTS=$(psql "$DATABASE_URL" -t -c \
    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'odsperf' AND table_name = 'account_transaction');" \
    2>/dev/null | xargs || echo "f")
  
  if [ "$TABLE_EXISTS" != "t" ]; then
    log_info "Table odsperf.account_transaction not found, creating schema..."
    "${SCRIPT_DIR}/init-pg-schema.sh" || log_fail "Failed to initialize PostgreSQL schema"
  fi

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
      log_info "Dropping collection (faster than deleteMany)..."
      mongosh "$MONGODB_URI" --quiet --eval \
        "db.getSiblingDB('${MONGODB_DB}').account_transaction.drop()" > /dev/null 2>&1
      log_ok "Collection dropped"
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

    # Create indexes after loading data
    log_info "Creating MongoDB indexes..."
    "${SCRIPT_DIR}/init-mongo-indexes.sh" || log_fail "Failed to create MongoDB indexes"
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
printf "\n${CYAN}Data summary:${NC}\n"
printf "  account_master     : ${ACCOUNT_POOL_SIZE} accounts (JOIN reference)\n"
printf "  account_transaction: transactions referencing account pool\n"
printf "\n${CYAN}Next steps:${NC}\n"
printf "  ./scripts/test-api.sh --repeat 10    # compare latency\n"
printf "  ./scripts/test-api.sh --verbose      # inspect responses\n\n"
