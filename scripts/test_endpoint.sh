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

BASE_URL="https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/openai/v1"
AUTH="Authorization: Bearer ${RUNPOD_API_KEY}"

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() { printf "\033[32m✓ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }

# ── Test 1: GET /v1/models ───────────────────────────────────────────────────
echo ""
echo "── Test 1: GET /v1/models ──────────────────────────────"

MODELS_START=$(date +%s)
MODELS_RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/models" \
  -H "$AUTH" \
  --max-time 120)
MODELS_END=$(date +%s)

HTTP_CODE=$(echo "$MODELS_RESPONSE" | tail -1)
BODY=$(echo "$MODELS_RESPONSE" | sed '$d')
ELAPSED=$((MODELS_END - MODELS_START))

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "/v1/models returned 200 (${ELAPSED}s)"

  if echo "$BODY" | grep -qi "granite-docling"; then
    MODEL_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
    pass "Model found: ${MODEL_ID}"
  else
    fail "granite-docling model not found in response"
    info "Response: ${BODY}"
  fi
else
  fail "/v1/models returned HTTP ${HTTP_CODE} (${ELAPSED}s)"
  info "Response: ${BODY}"
fi

# ── Test 2: POST /v1/chat/completions (text-only) ───────────────────────────
echo ""
echo "── Test 2: POST /v1/chat/completions (text) ────────────"

CHAT_START=$(date +%s)
CHAT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/chat/completions" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  --max-time 300 \
  -d '{
    "model": "granite-docling-258M",
    "messages": [{"role": "user", "content": "Hello"}],
    "temperature": 0.0,
    "max_tokens": 64
  }')
CHAT_END=$(date +%s)

HTTP_CODE=$(echo "$CHAT_RESPONSE" | tail -1)
BODY=$(echo "$CHAT_RESPONSE" | sed '$d')
ELAPSED=$((CHAT_END - CHAT_START))

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "/v1/chat/completions returned 200 (${ELAPSED}s)"

  CONTENT=$(echo "$BODY" | python3 -c "
import sys, json
r = json.load(sys.stdin)
print(r['choices'][0]['message']['content'][:120])
" 2>/dev/null || echo "(could not parse)")
  info "Response preview: ${CONTENT}"
else
  fail "/v1/chat/completions returned HTTP ${HTTP_CODE} (${ELAPSED}s)"
  info "Response: ${BODY}"
fi

# ── Test 3: Hot-start latency ────────────────────────────────────────────────
echo ""
echo "── Test 3: Hot-start latency ───────────────────────────"

HOT_START=$(date +%s)
HOT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${BASE_URL}/chat/completions" \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  --max-time 300 \
  -d '{
    "model": "granite-docling-258M",
    "messages": [{"role": "user", "content": "Hello"}],
    "temperature": 0.0,
    "max_tokens": 16
  }')
HOT_END=$(date +%s)

HTTP_CODE=$(echo "$HOT_RESPONSE" | tail -1)
ELAPSED=$((HOT_END - HOT_START))

if [[ "$HTTP_CODE" == "200" ]]; then
  pass "Hot-start request completed (${ELAPSED}s)"
else
  fail "Hot-start request failed with HTTP ${HTTP_CODE} (${ELAPSED}s)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "── Done ────────────────────────────────────────────────"
