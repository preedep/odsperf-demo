#!/usr/bin/env bash
# =============================================================================
# init-pg-accounts.sh — Initialize PostgreSQL account_master table
# Creates odsperf.account_master table (requires odsperf schema from init-pg-schema.sh)
#
# Usage:
#   ./scripts/init-pg-accounts.sh
#   DATABASE_URL=postgresql://... ./scripts/init-pg-accounts.sh
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
DATABASE_URL="${DATABASE_URL:-postgresql://odsuser:odspassword@localhost:5432/odsperf}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCHEMA_FILE="${PROJECT_ROOT}/infra/postgresql/init-schema-accounts.sql"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_ok()   { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail() { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info() { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║    PostgreSQL account_master Schema — ODS Performance        ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

log_info "Database   : ${DATABASE_URL%%@*}@..."
log_info "Schema file: ${SCHEMA_FILE}"

# ── Check schema file exists ──────────────────────────────────────────────────
[ -f "$SCHEMA_FILE" ] || log_fail "Schema file not found: ${SCHEMA_FILE}"

# ── Check PostgreSQL connection ───────────────────────────────────────────────
log_info "Testing PostgreSQL connection..."
psql "$DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1 || \
  log_fail "Cannot connect to PostgreSQL. Start port-forward first:
    kubectl port-forward svc/postgresql 5432:5432 -n database-pg &"
log_ok "Connected to PostgreSQL"

# ── Check odsperf schema exists (created by init-pg-schema.sh) ───────────────
SCHEMA_EXISTS=$(psql "$DATABASE_URL" -t -c \
  "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'odsperf');" \
  | xargs)
if [ "$SCHEMA_EXISTS" != "t" ]; then
  log_fail "Schema 'odsperf' does not exist. Run ./scripts/init-pg-schema.sh first."
fi

# ── Execute schema SQL ────────────────────────────────────────────────────────
log_info "Creating account_master table..."
psql "$DATABASE_URL" -f "$SCHEMA_FILE" || log_fail "Failed to execute schema SQL"
log_ok "account_master table created"

# ── Verify table exists ───────────────────────────────────────────────────────
TABLE_EXISTS=$(psql "$DATABASE_URL" -t -c \
  "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'odsperf' AND table_name = 'account_master');" \
  | xargs)

if [ "$TABLE_EXISTS" = "t" ]; then
  log_ok "Table odsperf.account_master exists"

  echo ""
  printf "${CYAN}Table structure:${NC}\n"
  psql "$DATABASE_URL" -c "\d odsperf.account_master"

  echo ""
  printf "${CYAN}Indexes:${NC}\n"
  psql "$DATABASE_URL" -c "\di odsperf.account_master*"
else
  log_fail "Table verification failed"
fi

echo ""
printf "${GREEN}${BOLD}✓ account_master schema ready!${NC}\n"
printf "  Next: ${CYAN}./scripts/seed.sh${NC}  (or ${CYAN}./scripts/seed.sh --accounts-only${NC})\n\n"
