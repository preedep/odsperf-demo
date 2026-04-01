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

# Index 1: Compound index on (iacct, drun, cseq) - equivalent to PRIMARY KEY
log_info "Creating index: iacct_drun_cseq (PRIMARY KEY equivalent)..."
mongosh "$MONGODB_URI" --quiet --eval "
  db.getSiblingDB('${MONGODB_DB}').account_transaction.createIndex(
    { iacct: 1, drun: 1, cseq: 1 },
    { name: 'idx_iacct_drun_cseq', unique: true }
  );
" || log_fail "Failed to create index: idx_iacct_drun_cseq"
log_ok "Created: idx_iacct_drun_cseq"

# Index 2: Compound index on (iacct, dtrans) - main query pattern
log_info "Creating index: iacct_dtrans (main query pattern)..."
mongosh "$MONGODB_URI" --quiet --eval "
  db.getSiblingDB('${MONGODB_DB}').account_transaction.createIndex(
    { iacct: 1, dtrans: 1 },
    { name: 'idx_iacct_dtrans' }
  );
" || log_fail "Failed to create index: idx_iacct_dtrans"
log_ok "Created: idx_iacct_dtrans"

# Index 3: Single index on drun - batch processing
log_info "Creating index: drun (batch processing)..."
mongosh "$MONGODB_URI" --quiet --eval "
  db.getSiblingDB('${MONGODB_DB}').account_transaction.createIndex(
    { drun: 1 },
    { name: 'idx_drun' }
  );
" || log_fail "Failed to create index: idx_drun"
log_ok "Created: idx_drun"

# Index 4: Single index on camt - filter CREDIT/DEBIT
log_info "Creating index: camt (filter CREDIT/DEBIT)..."
mongosh "$MONGODB_URI" --quiet --eval "
  db.getSiblingDB('${MONGODB_DB}').account_transaction.createIndex(
    { camt: 1 },
    { name: 'idx_camt' }
  );
" || log_fail "Failed to create index: idx_camt"
log_ok "Created: idx_camt"

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
