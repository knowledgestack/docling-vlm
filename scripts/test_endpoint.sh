#!/usr/bin/env bash
set -euo pipefail

# ── Load config ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env or environment}"
: "${RUNPOD_ENDPOINT_ID:?Set RUNPOD_ENDPOINT_ID in .env or environment}"

BASE_URL="https://${RUNPOD_ENDPOINT_ID}.api.runpod.ai/openai/v1"
AUTH="Authorization: Bearer ${RUNPOD_API_KEY}"

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { printf "\033[32m✓ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$1"; }

echo ""
echo "Endpoint: ${BASE_URL}"
echo ""

# ── Test 1: GET /v1/models (with cold-start polling) ────────────────────────
echo "── Test 1: GET /v1/models ──────────────────────────────"
echo "   Waiting for endpoint (cold start can take 1-3 min)..."

POLL_INTERVAL=5
MAX_WAIT=300
WAITED=0
MODELS_BODY=""
MODELS_CODE=""

while (( WAITED < MAX_WAIT )); do
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    "${BASE_URL}/models" \
    -H "$AUTH" \
    --max-time 30 2>&1) || true

  MODELS_CODE=$(echo "$RESPONSE" | tail -1)
  MODELS_BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$MODELS_CODE" == "200" ]]; then
    break
  fi

  WAITED=$((WAITED + POLL_INTERVAL))
  printf "\r   %3ds elapsed — HTTP %s, retrying..." "$WAITED" "$MODELS_CODE"
  sleep "$POLL_INTERVAL"
done
echo ""

if [[ "$MODELS_CODE" == "200" ]]; then
  pass "/v1/models returned 200 (after ${WAITED}s)"
  info "Response: ${MODELS_BODY}"

  if echo "$MODELS_BODY" | grep -qi "granite"; then
    MODEL_ID=$(echo "$MODELS_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
    pass "Model found: ${MODEL_ID}"
  else
    fail "granite-docling model not found in response"
  fi
else
  fail "/v1/models never returned 200 after ${MAX_WAIT}s (last HTTP: ${MODELS_CODE})"
  info "Last response: ${MODELS_BODY}"
  echo ""
  echo "── Aborting (endpoint not ready) ─────────────────────"
  exit 1
fi

# ── Test 2: POST /v1/chat/completions ────────────────────────────────────────
echo ""
echo "── Test 2: POST /v1/chat/completions (text) ────────────"

MODEL_NAME="${MODEL_ID:-granite-docling-258M}"
info "Using model name: ${MODEL_NAME}"

CHAT_START=$(python3 -c "import time; print(time.time())")
CHAT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/chat/completions" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  --max-time 300 \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}],
    \"temperature\": 0.0,
    \"max_tokens\": 64
  }")
CHAT_END=$(python3 -c "import time; print(time.time())")

HTTP_CODE=$(echo "$CHAT_RESPONSE" | tail -1)
BODY=$(echo "$CHAT_RESPONSE" | sed '$d')
ELAPSED=$(python3 -c "print(f'{${CHAT_END} - ${CHAT_START}:.1f}')")

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "/v1/chat/completions returned 200 (${ELAPSED}s)"

  CONTENT=$(echo "$BODY" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r['choices'][0]['message']['content'][:200])
" 2>/dev/null || echo "(could not parse)")
  info "Response: ${CONTENT}"
else
  fail "/v1/chat/completions returned HTTP ${HTTP_CODE} (${ELAPSED}s)"
  info "Response: ${BODY}"
fi

# ── Test 3: Hot-start latency ────────────────────────────────────────────────
echo ""
echo "── Test 3: Hot-start latency ───────────────────────────"

HOT_START=$(python3 -c "import time; print(time.time())")
HOT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/chat/completions" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  --max-time 300 \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}],
    \"temperature\": 0.0,
    \"max_tokens\": 16
  }")
HOT_END=$(python3 -c "import time; print(time.time())")

HTTP_CODE=$(echo "$HOT_RESPONSE" | tail -1)
ELAPSED=$(python3 -c "print(f'{${HOT_END} - ${HOT_START}:.1f}')")

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "Hot-start completed (${ELAPSED}s)"
else
  fail "Hot-start failed with HTTP ${HTTP_CODE} (${ELAPSED}s)"
  BODY=$(echo "$HOT_RESPONSE" | sed '$d')
  info "Response: ${BODY}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "── Done ────────────────────────────────────────────────"
echo ""
echo "ks-backend .env.dev values:"
echo "  VLM_ENDPOINT=${BASE_URL}/chat/completions"
echo "  VLM_MODEL=${MODEL_NAME}"
echo "  VLM_API_KEY=<your runpod api key>"
