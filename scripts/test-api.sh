#!/usr/bin/env bash
# =============================================================================
# test-api.sh — ODS Performance Demo API Test Script
# Tests /v1/query-pg, /v1/query-pg-join, /v1/query-mongo, and /v1/query-mongo-nojoin endpoints
# Usage:
#   ./scripts/test-api.sh                        # run all tests (default params)
#   ./scripts/test-api.sh --host localhost:8080  # hit service directly (bypass Istio)
#   ./scripts/test-api.sh --account 98765432100  # custom account number
#   ./scripts/test-api.sh --pg                   # PostgreSQL only
#   ./scripts/test-api.sh --join                 # PostgreSQL JOIN only
#   ./scripts/test-api.sh --mongo                # MongoDB only
#   ./scripts/test-api.sh --nojoin               # MongoDB no-join only
#   ./scripts/test-api.sh --repeat 5             # run each test 5 times (latency check)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
BASE_URL="http://ods.local"
ACCOUNT_NO="10000007942"  # Real account from CSV (has 2 transactions)
START_MONTH=1
START_YEAR=2025
END_MONTH=12
END_YEAR=2025
RUN_PG=true
RUN_PG_JOIN=false
RUN_MONGO=true
RUN_MONGO_NOJOIN=false
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
    --pg)          RUN_MONGO=false; RUN_PG_JOIN=false; RUN_MONGO_NOJOIN=false; shift   ;;
    --join)        RUN_PG=false; RUN_MONGO=false; RUN_PG_JOIN=true; RUN_MONGO_NOJOIN=false; shift ;;
    --mongo)       RUN_PG=false; RUN_PG_JOIN=false; RUN_MONGO_NOJOIN=false; shift   ;;
    --nojoin)      RUN_PG=false; RUN_PG_JOIN=false; RUN_MONGO=false; RUN_MONGO_NOJOIN=true; shift ;;
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
      # Check response type
      local has_statements has_nojoin_statements
      has_statements=$(jq 'has("data") and (.data | has("statements"))' /tmp/ods_response.json 2>/dev/null || echo false)
      has_nojoin_statements=$(jq 'has("Statements")' /tmp/ods_response.json 2>/dev/null || echo false)
      
      if [[ "$has_nojoin_statements" == "true" ]]; then
        # MongoDB no-join response - show account info and statement count
        printf "  Account: "
        jq -c '{iacct, custid, ctype, segment}' /tmp/ods_response.json 2>/dev/null || true
        local stmt_count
        stmt_count=$(jq '.Statements | length' /tmp/ods_response.json 2>/dev/null || echo 0)
        printf "  Statements: %d transactions\n" "$stmt_count"
        if [[ "$stmt_count" -gt 0 ]]; then
          printf "  Sample (first txn): "
          jq -c '.Statements[0] | {dtrans, camt, aamount}' /tmp/ods_response.json 2>/dev/null || true
        fi
      elif [[ "$has_statements" == "true" ]]; then
        # JOIN response - show account info and statement count
        printf "  Account: "
        jq -c '.data | {iacct, custid, ctype, segment}' /tmp/ods_response.json 2>/dev/null || true
        local stmt_count
        stmt_count=$(jq '.data.statements | length' /tmp/ods_response.json 2>/dev/null || echo 0)
        printf "  Statements: %d transactions\n" "$stmt_count"
        if [[ "$stmt_count" -gt 0 ]]; then
          printf "  Sample (first txn): "
          jq -c '.data.statements[0] | {dtrans, camt, aamount}' /tmp/ods_response.json 2>/dev/null || true
        fi
      else
        # Regular response - show first row as sample
        local row_count
        row_count=$(jq '.data | length' /tmp/ods_response.json 2>/dev/null || echo 0)
        if [[ "$row_count" -gt 0 ]]; then
          printf "  Sample (first row): "
          jq -c '.data[0] | {iacct, dtrans, camt, aamount}' /tmp/ods_response.json 2>/dev/null || true
        else
          log_info "No rows returned for account=${ACCOUNT_NO} in ${START_MONTH}/${START_YEAR}–${END_MONTH}/${END_YEAR}"
        fi
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
  local result_var="$3"  # Variable name to store results

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

  # Calculate average
  local avg_ms="N/A"
  if [[ "$success" -gt 0 ]]; then
    avg_ms=$(echo "scale=2; $total_ms / $success" | bc)
  fi

  # Store results in associative array format
  if [[ -n "$result_var" ]]; then
    eval "${result_var}_success=$success"
    eval "${result_var}_fail=$fail"
    eval "${result_var}_min=$min_ms"
    eval "${result_var}_avg=$avg_ms"
    eval "${result_var}_max=$max_ms"
  fi

  if [[ "$REPEAT" -gt 1 ]]; then
    printf "\n${BOLD}Summary${RESET} (%s)\n" "$label"
    printf "  Success : %d / %d\n" "$success" "$REPEAT"
    if [[ "$success" -gt 0 ]]; then
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

[[ "$RUN_PG"           == "true" ]] && run_benchmark "PostgreSQL      /v1/query-pg"           "/v1/query-pg"           "PG_RESULT"
[[ "$RUN_PG_JOIN"      == "true" ]] && run_benchmark "PostgreSQL JOIN /v1/query-pg-join"      "/v1/query-pg-join"      "PG_JOIN_RESULT"
[[ "$RUN_MONGO"        == "true" ]] && run_benchmark "MongoDB         /v1/query-mongo"        "/v1/query-mongo"        "MONGO_RESULT"
[[ "$RUN_MONGO_NOJOIN" == "true" ]] && run_benchmark "MongoDB No-Join /v1/query-mongo-nojoin" "/v1/query-mongo-nojoin" "MONGO_NOJOIN_RESULT"

# ── Comparison Summary ────────────────────────────────────────────────────────
if [[ "$RUN_PG" == "true" && "$RUN_MONGO" == "true" ]]; then
  printf "\n${BOLD}${CYAN}"
  printf "╔══════════════════════════════════════════════════════════════════╗\n"
  printf "║              Performance Comparison Summary                      ║\n"
  printf "╚══════════════════════════════════════════════════════════════════╝\n"
  printf "${RESET}"
  
  printf "\n${BOLD}%-15s | %10s | %10s | %10s | %10s${RESET}\n" "Database" "Min (ms)" "Avg (ms)" "Max (ms)" "Success"
  printf "${BOLD}%s${RESET}\n" "─────────────────────────────────────────────────────────────────────"
  
  # PostgreSQL row
  printf "%-15s | %10s | %10s | %10s | %4d/%d\n" \
    "PostgreSQL" \
    "${PG_RESULT_min}" \
    "${PG_RESULT_avg}" \
    "${PG_RESULT_max}" \
    "${PG_RESULT_success}" \
    "$REPEAT"
  
  # MongoDB row
  printf "%-15s | %10s | %10s | %10s | %4d/%d\n" \
    "MongoDB" \
    "${MONGO_RESULT_min}" \
    "${MONGO_RESULT_avg}" \
    "${MONGO_RESULT_max}" \
    "${MONGO_RESULT_success}" \
    "$REPEAT"
  
  # Winner calculation (if both succeeded)
  if [[ "${PG_RESULT_success}" -gt 0 && "${MONGO_RESULT_success}" -gt 0 ]]; then
    printf "\n${BOLD}Winner (by avg latency):${RESET} "
    if (( $(echo "${PG_RESULT_avg} < ${MONGO_RESULT_avg}" | bc -l) )); then
      speedup=$(echo "scale=2; ${MONGO_RESULT_avg} / ${PG_RESULT_avg}" | bc)
      printf "${GREEN}PostgreSQL${RESET} (%.2fx faster)\n" "$speedup"
    elif (( $(echo "${MONGO_RESULT_avg} < ${PG_RESULT_avg}" | bc -l) )); then
      speedup=$(echo "scale=2; ${PG_RESULT_avg} / ${MONGO_RESULT_avg}" | bc)
      printf "${GREEN}MongoDB${RESET} (%.2fx faster)\n" "$speedup"
    else
      printf "${YELLOW}Tie${RESET}\n"
    fi
  fi
fi

printf "\n${GREEN}${BOLD}Done.${RESET}\n\n"
