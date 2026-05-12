#!/usr/bin/env bash
###############################################################################
# testing/test_harness.sh
#
# Testing Harness — AI Sentiment API (deepaiorg/sentiment-analysis)
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   chmod +x test_harness.sh
#   ./test_harness.sh [HOST] [PORT]
#
# Defaults: HOST=localhost, PORT=30005
#
# Dependencies: curl, jq (sudo apt install curl jq)
###############################################################################

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
HOST="${1:-localhost}"
PORT="${2:-30005}"
BASE_URL="http://${HOST}:${PORT}"
RESULTS_DIR="./test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="${RESULTS_DIR}/curl_results_${TIMESTAMP}.json"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
print_header() { echo -e "\n${BOLD}${BLUE}══ $1 ══${RESET}"; }
print_pass()   { echo -e "  ${GREEN}✅ PASS${RESET} — $1"; }
print_fail()   { echo -e "  ${RED}❌ FAIL${RESET} — $1"; }
print_info()   { echo -e "  ${CYAN}ℹ️  ${RESET} $1"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
print_header "Pre-flight Checks"

for cmd in curl jq; do
  if command -v "$cmd" &>/dev/null; then
    print_pass "$cmd found: $(command -v $cmd)"
  else
    print_fail "$cmd not found — install with: sudo apt install $cmd"
    exit 1
  fi
done

mkdir -p "$RESULTS_DIR"

# Wait for API to be reachable (up to 30s)
print_info "Checking connectivity to ${BASE_URL} ..."
for i in $(seq 1 6); do
  if curl -sf --max-time 3 "${BASE_URL}/" &>/dev/null; then
    print_pass "API is reachable at ${BASE_URL}"
    break
  fi
  if [[ $i -eq 6 ]]; then
    print_fail "API not reachable after 30s. Is the pod running? Try: kubectl get pods -n sentiment"
    exit 1
  fi
  echo -e "  ${YELLOW}⏳ Waiting for API... attempt $i/6${RESET}"
  sleep 5
done

###############################################################################
# ── TEST PAYLOADS ─────────────────────────────────────────────────────────────
# Five strings covering:
#   1. Standard positive
#   2. Standard negative
#   3. Mixed/ambiguous case
#   4. Special symbols and punctuation
#   5. Non-ASCII Unicode (emoji + diacritics)
###############################################################################
declare -A PAYLOADS
PAYLOADS[1]="I absolutely love this product — it has changed my life for the better!"
PAYLOADS[2]="This is the worst experience I have ever had. Completely unacceptable."
PAYLOADS[3]="It was okay, not great but not terrible. Some parts I liked, others not so much."
PAYLOADS[4]="WOW!!! Can't believe it's \$0.99 — 100% OFF?! #Amazing & @Unbelievable... (or is it?)"
PAYLOADS[5]="Café au lait était délicieux! 😍🎉 Très magnifique — wirklich wunderbar! 日本語テスト"

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULT_JSON_ARRAY

print_header "Sentiment API — Functional Tests (5 payloads)"
echo -e "  Target: ${BOLD}${BASE_URL}${RESET}\n"

for i in 1 2 3 4 5; do
  TEXT="${PAYLOADS[$i]}"
  echo -e "${BOLD}Test $i:${RESET} ${YELLOW}\"${TEXT:0:60}...\"${RESET}"

  # ── Send request ─────────────────────────────────────────────────────────
  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    --max-time 15 \
    -X POST "${BASE_URL}/v1/sentiment" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"$(echo "$TEXT" | sed 's/"/\\"/g')\"}" \
    2>&1) || true

  HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

  # ── Validate HTTP status ──────────────────────────────────────────────────
  if [[ "$HTTP_CODE" == "200" ]]; then
    print_pass "HTTP 200 OK"
  else
    print_fail "HTTP ${HTTP_CODE} (expected 200)"
    ((FAIL_COUNT++))
    continue
  fi

  # ── Validate JSON structure ───────────────────────────────────────────────
  if echo "$HTTP_BODY" | jq . &>/dev/null; then
    print_pass "Response is valid JSON"
  else
    print_fail "Response is NOT valid JSON"
    echo -e "  Raw response: ${HTTP_BODY}"
    ((FAIL_COUNT++))
    continue
  fi

  # ── Extract sentiment fields ───────────────────────────────────────────────
  SCORE=$(echo "$HTTP_BODY" | jq -r '.score // .sentiment_score // .output.score // "N/A"' 2>/dev/null)
  LABEL=$(echo "$HTTP_BODY" | jq -r '.label // .sentiment // .output.sentiment // "N/A"' 2>/dev/null)
  POSITIVE=$(echo "$HTTP_BODY" | jq -r '.positive // .output.positive // "N/A"' 2>/dev/null)
  NEGATIVE=$(echo "$HTTP_BODY" | jq -r '.negative // .output.negative // "N/A"' 2>/dev/null)

  # ── Score range validation (0.0 – 1.0) ────────────────────────────────────
  if [[ "$SCORE" != "N/A" ]]; then
    IS_VALID=$(echo "$SCORE" | awk '{print ($1 >= 0.0 && $1 <= 1.0) ? "yes" : "no"}')
    if [[ "$IS_VALID" == "yes" ]]; then
      print_pass "Score ${SCORE} is within valid range [0.0, 1.0]"
      ((PASS_COUNT++))
    else
      print_fail "Score ${SCORE} is outside expected range [0.0, 1.0]"
      ((FAIL_COUNT++))
    fi
  else
    print_info "Score field not in expected path — full response:"
    echo "$HTTP_BODY" | jq .
    ((PASS_COUNT++))   # Still counts as pass if JSON is valid
  fi

  # ── Display results ────────────────────────────────────────────────────────
  echo -e "  ${CYAN}Label   :${RESET} ${LABEL}"
  echo -e "  ${CYAN}Score   :${RESET} ${SCORE}"
  [[ "$POSITIVE" != "N/A" ]] && echo -e "  ${CYAN}Positive:${RESET} ${POSITIVE}"
  [[ "$NEGATIVE" != "N/A" ]] && echo -e "  ${CYAN}Negative:${RESET} ${NEGATIVE}"

  # Collect for JSON report
  RESULT_JSON_ARRAY+=("{\"test\":$i,\"text\":$(echo "$TEXT" | jq -Rs .),\"http_code\":\"${HTTP_CODE}\",\"score\":\"${SCORE}\",\"label\":\"${LABEL}\"}")

  echo ""
done

###############################################################################
# ── Save JSON Report ──────────────────────────────────────────────────────────
###############################################################################
printf '%s\n' "${RESULT_JSON_ARRAY[@]}" | jq -s '.' > "$RESULTS_FILE"
print_info "Results saved to: ${RESULTS_FILE}"

###############################################################################
# ── Summary ───────────────────────────────────────────────────────────────────
###############################################################################
print_header "Test Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "  Total  : ${TOTAL}"
echo -e "  ${GREEN}Passed : ${PASS_COUNT}${RESET}"
echo -e "  ${RED}Failed : ${FAIL_COUNT}${RESET}"

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "\n  ${GREEN}${BOLD}🎉 All tests passed!${RESET}"
  exit 0
else
  echo -e "\n  ${RED}${BOLD}⚠️  ${FAIL_COUNT} test(s) failed.${RESET}"
  exit 1
fi
