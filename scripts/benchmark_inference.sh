#!/usr/bin/env bash
set -euo pipefail

# ── Inference Latency Benchmark (with real document image) ───────────────────
#
# Measures realistic inference times by sending an actual document page image
# to the endpoint, simulating real ingestion workloads.
#
# Measures:
#   1. Image download + base64 encoding overhead
#   2. Single document inference (full output)
#   3. Warm sequential inference (N requests)
#   4. Burst concurrent inference (N parallel requests)
#
# Prerequisites:
#   - RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID in .env or environment
#   - Endpoint should already be WARM (run benchmark_coldstart.sh first)
#
# Usage:
#   ./scripts/benchmark_inference.sh                          # defaults
#   WARM_REQUESTS=10 BURST_SIZE=10 ./scripts/benchmark_inference.sh
#   SAMPLE_IMAGE=/path/to/your/doc.png ./scripts/benchmark_inference.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env or environment}"
: "${RUNPOD_ENDPOINT_ID:?Set RUNPOD_ENDPOINT_ID in .env or environment}"

BASE_URL="https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/openai/v1"
AUTH="Authorization: Bearer ${RUNPOD_API_KEY}"
WARM_REQUESTS=${WARM_REQUESTS:-3}
BURST_SIZE=${BURST_SIZE:-3}
MAX_TOKENS=${MAX_TOKENS:-4096}

# ── Helpers ──────────────────────────────────────────────────────────────────
ts()   { python3 -c "import time; print(time.time())"; }
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }
ok()   { printf "\033[32m  ✓ %s\033[0m\n" "$1"; }
err()  { printf "\033[31m  ✗ %s\033[0m\n" "$1"; }
hr()   { echo "────────────────────────────────────────────────────────"; }

RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="${RESULTS_DIR}/inference_$(date +%Y%m%d_%H%M%S).json"

# ── Prepare sample document image ────────────────────────────────────────────
hr
bold "Preparing document image"

SAMPLE_IMG_URL="https://huggingface.co/ibm-granite/granite-docling-258M/resolve/main/examples/input/wikipedia_example.png"

if [[ -n "${SAMPLE_IMAGE:-}" && -f "${SAMPLE_IMAGE}" ]]; then
  info "Using provided image: ${SAMPLE_IMAGE}"
  SAMPLE_B64=$(base64 < "$SAMPLE_IMAGE")
  IMG_SIZE_KB=$(( $(wc -c < "$SAMPLE_IMAGE") / 1024 ))
else
  info "Downloading sample from HuggingFace..."
  TMP_IMG=$(mktemp /tmp/sample_page_XXXX.png)
  if curl -sL -o "$TMP_IMG" "$SAMPLE_IMG_URL" && [[ -s "$TMP_IMG" ]]; then
    SAMPLE_B64=$(base64 < "$TMP_IMG")
    IMG_SIZE_KB=$(( $(wc -c < "$TMP_IMG") / 1024 ))
    rm -f "$TMP_IMG"
  else
    err "Could not download sample image. Provide one via SAMPLE_IMAGE=/path/to/doc.png"
    rm -f "$TMP_IMG"
    exit 1
  fi
fi

B64_SIZE_KB=$(( ${#SAMPLE_B64} / 1024 ))
ok "Image ready (${IMG_SIZE_KB} KB raw, ${B64_SIZE_KB} KB base64)"

# ── Check endpoint is warm ──────────────────────────────────────────────────
echo ""
hr
bold "Checking endpoint is warm"

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "${BASE_URL}/models" -H "$AUTH" --max-time 15 2>/dev/null) || CODE="000"

if [[ "$CODE" == "200" ]]; then
  ok "Endpoint is ready"
else
  err "Endpoint returned HTTP ${CODE} — run benchmark_coldstart.sh first to warm it up"
  exit 1
fi

MODEL_NAME=$(curl -s "${BASE_URL}/models" -H "$AUTH" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null \
  || echo "granite-docling-258M")
info "Model: ${MODEL_NAME}"

# ── Build the request payload ────────────────────────────────────────────────
# This matches how granite-docling is used: send a page image, get docling markup
PAYLOAD_FILE=$(mktemp /tmp/bench_payload_XXXX.json)
python3 -c "
import json
payload = {
    'model': '${MODEL_NAME}',
    'messages': [{
        'role': 'user',
        'content': [
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,${SAMPLE_B64}'}},
            {'type': 'text', 'text': 'Convert this page to docling markup.'}
        ]
    }],
    'temperature': 0.0,
    'max_tokens': ${MAX_TOKENS}
}
# Write without the base64 in logs
with open('${PAYLOAD_FILE}', 'w') as f:
    json.dump(payload, f)
"
PAYLOAD_SIZE_KB=$(( $(wc -c < "$PAYLOAD_FILE") / 1024 ))
info "Payload size: ${PAYLOAD_SIZE_KB} KB"

cat <<BANNER

$(bold "RunPod Serverless GPU — Inference Benchmark (Document Image)")
  Endpoint:        ${RUNPOD_ENDPOINT_ID}
  Model:           ${MODEL_NAME}
  Image:           ${IMG_SIZE_KB} KB (${B64_SIZE_KB} KB base64)
  Payload:         ${PAYLOAD_SIZE_KB} KB
  Max tokens:      ${MAX_TOKENS}
  Warm requests:   ${WARM_REQUESTS}
  Burst size:      ${BURST_SIZE}
  Results file:    ${RESULTS_FILE}

BANNER

# Helper: send image inference request, return "elapsed_seconds http_code output_tokens"
do_image_request() {
  local start end code response elapsed body tokens
  start=$(ts)
  response=$(curl -s -w "\n%{http_code}" \
    "${BASE_URL}/chat/completions" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    --max-time 600 \
    -d @"${PAYLOAD_FILE}" 2>&1) || true
  end=$(ts)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  elapsed=$(python3 -c "print(f'{${end} - ${start}:.3f}')")
  tokens=$(echo "$body" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    print(r.get('usage', {}).get('completion_tokens', r.get('usage', {}).get('total_tokens', '?')))
except: print('?')
" 2>/dev/null)
  echo "${elapsed} ${code} ${tokens}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: First Document Inference
# ══════════════════════════════════════════════════════════════════════════════
hr
bold "Phase 1: First Document Inference"

read -r FIRST_LAT FIRST_CODE FIRST_TOKENS <<< "$(do_image_request)"

if [[ "$FIRST_CODE" == "200" ]]; then
  ok "First inference: ${FIRST_LAT}s (${FIRST_TOKENS} tokens)"
else
  err "First inference failed: HTTP ${FIRST_CODE} (${FIRST_LAT}s)"
  # Show error body for debugging
  curl -s "${BASE_URL}/chat/completions" \
    -H "$AUTH" -H "Content-Type: application/json" \
    --max-time 60 -d @"${PAYLOAD_FILE}" 2>&1 | python3 -c "
import sys, json
try: print(json.dumps(json.load(sys.stdin), indent=2)[:500])
except: print(sys.stdin.read()[:500])
" || true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Warm Sequential Inference
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Phase 2: Warm Inference (${WARM_REQUESTS} sequential document requests)"

WARM_TOTAL=0
WARM_MIN=999999
WARM_MAX=0
WARM_FAILURES=0
WARM_LATENCIES=""
WARM_TOKENS_TOTAL=0

for i in $(seq 1 "$WARM_REQUESTS"); do
  read -r LAT CODE TOKENS <<< "$(do_image_request)"
  if [[ "$CODE" == "200" ]]; then
    printf "  [%d/%d] %ss (%s tokens)\n" "$i" "$WARM_REQUESTS" "$LAT" "$TOKENS"
    WARM_LATENCIES="${WARM_LATENCIES} ${LAT}"
    WARM_TOTAL=$(python3 -c "print(${WARM_TOTAL} + ${LAT})")
    WARM_MIN=$(python3 -c "print(min(${WARM_MIN}, ${LAT}))")
    WARM_MAX=$(python3 -c "print(max(${WARM_MAX}, ${LAT}))")
    if [[ "$TOKENS" != "?" ]]; then
      WARM_TOKENS_TOTAL=$((WARM_TOKENS_TOTAL + TOKENS))
    fi
  else
    err "[${i}/${WARM_REQUESTS}] HTTP ${CODE} (${LAT}s)"
    WARM_FAILURES=$((WARM_FAILURES + 1))
  fi
done

WARM_SUCCESS=$((WARM_REQUESTS - WARM_FAILURES))
if (( WARM_SUCCESS > 0 )); then
  WARM_AVG=$(python3 -c "print(f'{${WARM_TOTAL} / ${WARM_SUCCESS}:.3f}')")
  WARM_P50=$(python3 -c "
import statistics
lats = [float(x) for x in '${WARM_LATENCIES}'.split()]
print(f'{statistics.median(lats):.3f}')
")
  WARM_TOKENS_AVG=$((WARM_TOKENS_TOTAL / WARM_SUCCESS))
  echo ""
  ok "Avg: ${WARM_AVG}s | P50: ${WARM_P50}s | Min: ${WARM_MIN}s | Max: ${WARM_MAX}s"
  ok "Avg tokens/request: ~${WARM_TOKENS_AVG}"
else
  WARM_AVG="N/A"; WARM_P50="N/A"; WARM_MIN="N/A"; WARM_MAX="N/A"; WARM_TOKENS_AVG=0
  err "All warm requests failed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Burst Test — concurrent document requests
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Phase 3: Burst Test (${BURST_SIZE} concurrent document requests)"

BURST_DIR=$(mktemp -d /tmp/burst_img_XXXX)
BURST_START=$(ts)

for i in $(seq 1 "$BURST_SIZE"); do
  (
    start=$(ts)
    response=$(curl -s -w "\n%{http_code}" \
      "${BASE_URL}/chat/completions" \
      -H "$AUTH" \
      -H "Content-Type: application/json" \
      --max-time 600 \
      -d @"${PAYLOAD_FILE}" 2>&1) || true
    end=$(ts)
    code=$(echo "$response" | tail -1)
    elapsed=$(python3 -c "print(f'{${end} - ${start}:.3f}')")
    echo "${elapsed} ${code}" > "${BURST_DIR}/${i}.txt"
  ) &
done

wait
BURST_END=$(ts)
BURST_WALL=$(python3 -c "print(f'{${BURST_END} - ${BURST_START}:.3f}')")

BURST_LATS=""
BURST_OK=0
BURST_FAIL=0

for f in "${BURST_DIR}"/*.txt; do
  read -r LAT CODE < "$f"
  if [[ "$CODE" == "200" ]]; then
    BURST_LATS="${BURST_LATS} ${LAT}"
    BURST_OK=$((BURST_OK + 1))
    info "[ok] ${LAT}s"
  else
    BURST_FAIL=$((BURST_FAIL + 1))
    err "[HTTP ${CODE}] ${LAT}s"
  fi
done

rm -rf "$BURST_DIR"

echo ""
ok "Wall time: ${BURST_WALL}s | ${BURST_OK}/${BURST_SIZE} succeeded"

if (( BURST_OK > 0 )); then
  BURST_STATS=$(python3 -c "
import statistics
lats = [float(x) for x in '${BURST_LATS}'.split()]
print(f'Avg: {statistics.mean(lats):.3f}s | P50: {statistics.median(lats):.3f}s | Max: {max(lats):.3f}s')
")
  ok "${BURST_STATS}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Summary"
echo ""
printf "  %-30s %s\n" "First doc inference:" "${FIRST_LAT}s (${FIRST_TOKENS} tokens)"
printf "  %-30s %s\n" "Warm avg (${WARM_SUCCESS} reqs):" "${WARM_AVG}s"
printf "  %-30s %s\n" "Warm P50:" "${WARM_P50}s"
printf "  %-30s %s\n" "Warm min/max:" "${WARM_MIN}s / ${WARM_MAX}s"
printf "  %-30s %s\n" "Avg tokens/request:" "~${WARM_TOKENS_AVG}"
printf "  %-30s %s\n" "Burst wall (${BURST_SIZE} reqs):" "${BURST_WALL}s"
echo ""

# ── Write JSON results ───────────────────────────────────────────────────────
python3 -c "
import json, datetime
results = {
    'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
    'endpoint_id': '${RUNPOD_ENDPOINT_ID}',
    'model': '${MODEL_NAME}',
    'image_size_kb': ${IMG_SIZE_KB},
    'payload_size_kb': ${PAYLOAD_SIZE_KB},
    'max_tokens': ${MAX_TOKENS},
    'first_inference_secs': ${FIRST_LAT},
    'first_inference_tokens': '${FIRST_TOKENS}',
    'warm': {
        'requests': ${WARM_SUCCESS},
        'avg_secs': ${WARM_AVG} if '${WARM_AVG}' != 'N/A' else None,
        'p50_secs': ${WARM_P50} if '${WARM_P50}' != 'N/A' else None,
        'min_secs': ${WARM_MIN} if '${WARM_MIN}' != 'N/A' else None,
        'max_secs': ${WARM_MAX} if '${WARM_MAX}' != 'N/A' else None,
        'avg_tokens': ${WARM_TOKENS_AVG},
    },
    'burst': {
        'concurrency': ${BURST_SIZE},
        'wall_secs': ${BURST_WALL},
        'succeeded': ${BURST_OK},
        'failed': ${BURST_FAIL},
    }
}
with open('${RESULTS_FILE}', 'w') as f:
    json.dump(results, f, indent=2)
"

ok "Results written to ${RESULTS_FILE}"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$PAYLOAD_FILE"
echo ""
