#!/usr/bin/env bash
# =============================================================================
# init-mongo-indexes.sh — Create MongoDB indexes matching PostgreSQL
#
# Usage:
#   ./scripts/init-mongo-indexes.sh
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
MONGODB_URI="${MONGODB_URI:-mongodb://odsuser:odspassword@localhost:27017/odsperf}"
MONGODB_DB="${MONGODB_DB:-odsperf}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_ok()   { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail() { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info() { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║     MongoDB Index Creation — Match PostgreSQL Indexes       ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

log_info "MongoDB URI: ${MONGODB_URI%%@*}@..."

# ── Check MongoDB connection ──────────────────────────────────────────────────
log_info "Testing MongoDB connection..."
mongosh "$MONGODB_URI" --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | \
  grep -q "1" || \
  log_fail "Cannot connect to MongoDB. Start port-forward first:
    kubectl port-forward svc/mongodb 27017:27017 -n database-mongo &"

log_ok "Connected to MongoDB"

# ── Show existing indexes ─────────────────────────────────────────────────────
log_info "Current indexes:"
mongosh "$MONGODB_URI" --quiet --eval "
  db.getSiblingDB('${MONGODB_DB}').account_transaction.getIndexes().forEach(idx => {
    print('  - ' + idx.name + ': ' + JSON.stringify(idx.key));
  });
"

# ── Create indexes matching PostgreSQL ───────────────────────────────────────
echo ""
log_info "Creating indexes to match PostgreSQL..."

# Helper function to create index if it doesn't exist
create_index_if_not_exists() {
  local index_name="$1"
  local index_spec="$2"
  local index_options="$3"
  
  local exists=$(mongosh "$MONGODB_URI" --quiet --eval "
    db.getSiblingDB('${MONGODB_DB}').account_transaction.getIndexes()
      .filter(idx => idx.name === '${index_name}').length > 0
  " 2>/dev/null | tail -1)
  
  if [ "$exists" = "true" ]; then
    log_info "Index ${index_name} already exists, skipping..."
  else
    mongosh "$MONGODB_URI" --quiet --eval "
      db.getSiblingDB('${MONGODB_DB}').account_transaction.createIndex(
        ${index_spec},
        ${index_options}
      );
    " || log_fail "Failed to create index: ${index_name}"
    log_ok "Created: ${index_name}"
  fi
}

# Index 1: Compound index on (iacct, drun, cseq) - equivalent to PRIMARY KEY
create_index_if_not_exists \
  "idx_pk_account_transaction" \
  "{ iacct: 1, drun: 1, cseq: 1 }" \
  "{ name: 'idx_pk_account_transaction', unique: true }"

# Index 2: Compound index on (iacct, dtrans) - main query pattern
create_index_if_not_exists \
  "idx_acctxn_iacct_dtrans" \
  "{ iacct: 1, dtrans: 1 }" \
  "{ name: 'idx_acctxn_iacct_dtrans' }"

# Index 3: Single index on drun - batch processing
create_index_if_not_exists \
  "idx_acctxn_drun" \
  "{ drun: 1 }" \
  "{ name: 'idx_acctxn_drun' }"

# Index 4: Single index on camt - filter CREDIT/DEBIT
create_index_if_not_exists \
  "idx_acctxn_camt" \
  "{ camt: 1 }" \
  "{ name: 'idx_acctxn_camt' }"

# ── Verify indexes ────────────────────────────────────────────────────────────
echo ""
log_info "Verifying indexes..."
mongosh "$MONGODB_URI" --quiet --eval "
  const indexes = db.getSiblingDB('${MONGODB_DB}').account_transaction.getIndexes();
  print('Total indexes: ' + indexes.length);
  print('');
  indexes.forEach(idx => {
    print('  ' + idx.name.padEnd(25) + ' : ' + JSON.stringify(idx.key));
  });
"

# ── Show index sizes ──────────────────────────────────────────────────────────
echo ""
log_info "Index sizes:"
mongosh "$MONGODB_URI" --quiet --eval "
  const stats = db.getSiblingDB('${MONGODB_DB}').account_transaction.stats();
  const indexSizes = stats.indexSizes;
  Object.keys(indexSizes).forEach(name => {
    const sizeMB = (indexSizes[name] / 1048576).toFixed(2);
    print('  ' + name.padEnd(25) + ' : ' + sizeMB + ' MB');
  });
  print('');
  print('  Total index size: ' + (stats.totalIndexSize / 1048576).toFixed(2) + ' MB');
"

echo ""
printf "${GREEN}${BOLD}✓ MongoDB indexes created successfully!${NC}\n"
printf "  MongoDB now has the same indexes as PostgreSQL\n"
printf "  You can now run: ${CYAN}./scripts/compare-disk-usage.sh${NC}\n\n"
