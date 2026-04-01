#!/usr/bin/env bash
# =============================================================================
# test-api.sh — ODS Performance Demo API Test Script
# Tests both /v1/query-pg and /v1/query-mongo endpoints
# Usage:
#   ./scripts/test-api.sh                        # run all tests (default params)
#   ./scripts/test-api.sh --host localhost:8080  # hit service directly (bypass Istio)
#   ./scripts/test-api.sh --account 98765432100  # custom account number
#   ./scripts/test-api.sh --pg                   # PostgreSQL only
#   ./scripts/test-api.sh --mongo                # MongoDB only
#   ./scripts/test-api.sh --repeat 5             # run each test 5 times (latency check)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
BASE_URL="http://ods.local"
ACCOUNT_NO="89036188857"  # Real account from CSV (has 2 transactions)
START_MONTH=1
START_YEAR=2025
END_MONTH=12
END_YEAR=2025
RUN_PG=true
RUN_MONGO=true
REPEAT=1
VERBOSE=false

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       BASE_URL="http://$2"; shift 2 ;;
    --account)    ACCOUNT_NO="$2";      shift 2 ;;
    --start-month) START_MONTH="$2";   shift 2 ;;
    --start-year)  START_YEAR="$2";    shift 2 ;;
    --end-month)   END_MONTH="$2";     shift 2 ;;
    --end-year)    END_YEAR="$2";      shift 2 ;;
    --pg)          RUN_MONGO=false;    shift   ;;
    --mongo)       RUN_PG=false;       shift   ;;
    --repeat)      REPEAT="$2";        shift 2 ;;
    --verbose|-v)  VERBOSE=true;       shift   ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# ====/p' "$0" | grep -E "^#" | sed 's/^# //'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log_section() { printf "\n${BOLD}${CYAN}═══ %s ═══${RESET}\n" "$1"; }
log_ok()      { printf "${GREEN}✔${RESET}  %s\n" "$1"; }
log_fail()    { printf "${RED}✘${RESET}  %s\n" "$1"; }
log_info()    { printf "${YELLOW}ℹ${RESET}  %s\n" "$1"; }

require_cmd() {
  command -v "$1" &>/dev/null || { log_fail "Required command not found: $1"; exit 1; }
}

require_cmd curl
require_cmd jq

PAYLOAD=$(cat <<EOF
{
  "account_no": "${ACCOUNT_NO}",
  "start_month": ${START_MONTH},
  "start_year":  ${START_YEAR},
  "end_month":   ${END_MONTH},
  "end_year":    ${END_YEAR}
}
EOF
)

# ── Health Check ─────────────────────────────────────────────────────────────
check_health() {
  log_section "Health Check"
  log_info "GET ${BASE_URL}/health"

  HTTP_STATUS=$(curl -s -o /tmp/ods_health.json -w "%{http_code}" \
    --max-time 10 \
    "${BASE_URL}/health" 2>/dev/null) || {
      log_fail "Connection failed — is ${BASE_URL} reachable?"
      printf "\n${YELLOW}Hint:${RESET} Check /etc/hosts has entry for the hostname.\n"
      printf "      Run: ${CYAN}kubectl get svc -n istio-system${RESET}\n"
      printf "      Then: ${CYAN}echo \"<GATEWAY-IP> ods.local\" | sudo tee -a /etc/hosts${RESET}\n\n"
      exit 1
    }

  if [[ "$HTTP_STATUS" == "200" ]]; then
    log_ok "Health OK (HTTP ${HTTP_STATUS})"
    jq '.' /tmp/ods_health.json 2>/dev/null || true
  else
    log_fail "Health check failed (HTTP ${HTTP_STATUS})"
    cat /tmp/ods_health.json 2>/dev/null || true
    exit 1
  fi
}

# ── Single API Call ──────────────────────────────────────────────────────────
call_api() {
  local label="$1"
  local endpoint="$2"
  local run="$3"

  printf "\n${BOLD}[Run %d/%d]${RESET} POST %s\n" "$run" "$REPEAT" "${BASE_URL}${endpoint}"

  HTTP_STATUS=$(curl -s \
    -o /tmp/ods_response.json \
    -w "%{http_code}" \
    --max-time 30 \
    -X POST "${BASE_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" 2>/dev/null) || {
      log_fail "Request failed"
      return 1
    }

  if [[ "$HTTP_STATUS" == "200" ]]; then
    local elapsed db total
    elapsed=$(jq -r '.elapsed_ms // "N/A"' /tmp/ods_response.json 2>/dev/null)
    db=$(jq -r '.db // "unknown"'           /tmp/ods_response.json 2>/dev/null)
    total=$(jq -r '.total // 0'             /tmp/ods_response.json 2>/dev/null)

    log_ok "HTTP ${HTTP_STATUS} | db=${db} | rows=${total} | elapsed=${elapsed}ms"

    if [[ "$VERBOSE" == "true" ]]; then
      printf "\n${CYAN}Response:${RESET}\n"
      jq '.' /tmp/ods_response.json
    else
      # Show first 2 rows as sample
      local row_count
      row_count=$(jq '.data | length' /tmp/ods_response.json 2>/dev/null || echo 0)
      if [[ "$row_count" -gt 0 ]]; then
        printf "  Sample (first row): "
        jq -c '.data[0] | {iacct, dtrans, camt, amount}' /tmp/ods_response.json 2>/dev/null || true
      else
        log_info "No rows returned for account=${ACCOUNT_NO} in ${START_MONTH}/${START_YEAR}–${END_MONTH}/${END_YEAR}"
      fi
    fi
  else
    log_fail "HTTP ${HTTP_STATUS}"
    jq '.' /tmp/ods_response.json 2>/dev/null || cat /tmp/ods_response.json || true
    return 1
  fi
}

# ── Benchmark Loop ────────────────────────────────────────────────────────────
run_benchmark() {
  local label="$1"
  local endpoint="$2"

  log_section "${label}"
  log_info "Account  : ${ACCOUNT_NO}"
  log_info "Period   : ${START_MONTH}/${START_YEAR} → ${END_MONTH}/${END_YEAR}"
  log_info "Endpoint : ${BASE_URL}${endpoint}"
  log_info "Repeats  : ${REPEAT}"

  local success=0 fail=0
  local total_ms=0 min_ms=99999 max_ms=0

  for i in $(seq 1 "$REPEAT"); do
    if call_api "$label" "$endpoint" "$i"; then
      success=$((success + 1))
      elapsed=$(jq -r '.elapsed_ms // 0' /tmp/ods_response.json 2>/dev/null || echo 0)
      # Strip non-numeric (safety)
      elapsed=${elapsed//[^0-9.]/}
      elapsed=${elapsed:-0}
      total_ms=$(echo "$total_ms + $elapsed" | bc)
      (( $(echo "$elapsed < $min_ms" | bc -l) )) && min_ms=$elapsed
      (( $(echo "$elapsed > $max_ms" | bc -l) )) && max_ms=$elapsed
    else
      fail=$((fail + 1))
    fi
    # Small pause between repeat calls
    [[ "$REPEAT" -gt 1 && "$i" -lt "$REPEAT" ]] && sleep 0.2
  done

  if [[ "$REPEAT" -gt 1 ]]; then
    printf "\n${BOLD}Summary${RESET} (%s)\n" "$label"
    printf "  Success : %d / %d\n" "$success" "$REPEAT"
    if [[ "$success" -gt 0 ]]; then
      avg_ms=$(echo "scale=2; $total_ms / $success" | bc)
      printf "  Latency : min=%-8sms  avg=%-8sms  max=%sms\n" "$min_ms" "$avg_ms" "$max_ms"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
printf "${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════╗\n"
printf "║       ODS Performance Demo — API Test        ║\n"
printf "╚══════════════════════════════════════════════╝\n"
printf "${RESET}"
log_info "Base URL : ${BASE_URL}"
log_info "Date     : $(date '+%Y-%m-%d %H:%M:%S')"

check_health

[[ "$RUN_PG"    == "true" ]] && run_benchmark "PostgreSQL  /v1/query-pg"    "/v1/query-pg"
[[ "$RUN_MONGO" == "true" ]] && run_benchmark "MongoDB     /v1/query-mongo" "/v1/query-mongo"

printf "\n${GREEN}${BOLD}Done.${RESET}\n\n"
