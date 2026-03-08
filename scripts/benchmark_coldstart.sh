#!/usr/bin/env bash
set -euo pipefail

# ── Cold Start & Latency Benchmark for RunPod Serverless GPU ─────────────────
#
# Measures:
#   1. Cold start time   — how long until the endpoint is ready (from idle)
#   2. First inference    — first request latency (model may still be warming)
#   3. Warm inference     — average latency over N requests on a hot worker
#   4. Burst throughput   — N concurrent requests to simulate bursty ingestion
#
# Prerequisites:
#   - RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID set in .env or environment
#   - Endpoint should be IDLE (0 active workers) for accurate cold start measurement
#     You can scale to 0 in the RunPod dashboard before running this.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in .env or environment}"
: "${RUNPOD_ENDPOINT_ID:?Set RUNPOD_ENDPOINT_ID in .env or environment}"

BASE_URL="https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/openai/v1"
AUTH="Authorization: Bearer ${RUNPOD_API_KEY}"
WARM_REQUESTS=${WARM_REQUESTS:-5}
BURST_SIZE=${BURST_SIZE:-5}
POLL_INTERVAL=5
MAX_WAIT=300

# ── Helpers ──────────────────────────────────────────────────────────────────
ts()   { python3 -c "import time; print(time.time())"; }
bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }
ok()   { printf "\033[32m  ✓ %s\033[0m\n" "$1"; }
err()  { printf "\033[31m  ✗ %s\033[0m\n" "$1"; }
hr()   { echo "────────────────────────────────────────────────────────"; }

RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="${RESULTS_DIR}/coldstart_$(date +%Y%m%d_%H%M%S).json"

cat <<BANNER

$(bold "RunPod Serverless GPU — Cold Start Benchmark")
  Endpoint:        ${RUNPOD_ENDPOINT_ID}
  Warm requests:   ${WARM_REQUESTS}
  Burst size:      ${BURST_SIZE}
  Results file:    ${RESULTS_FILE}

BANNER

# Helper: make a simple chat request, return "elapsed_seconds http_code"
do_request() {
  local start end code response elapsed
  start=$(ts)
  response=$(curl -s -w "\n%{http_code}" \
    "${BASE_URL}/chat/completions" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    --max-time 300 \
    -d '{
      "model": "'"${MODEL_NAME}"'",
      "messages": [{"role": "user", "content": "Hello"}],
      "temperature": 0.0,
      "max_tokens": 16
    }' 2>&1) || true
  end=$(ts)
  code=$(echo "$response" | tail -1)
  elapsed=$(python3 -c "print(f'{${end} - ${start}:.3f}')")
  echo "${elapsed} ${code}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Cold Start — poll /v1/models until ready
# ══════════════════════════════════════════════════════════════════════════════
hr
bold "Phase 1: Cold Start (polling /v1/models)"
info "Tip: scale endpoint to 0 workers first for an accurate measurement."
echo ""

COLD_START_BEGIN=$(ts)
WAITED=0
READY=false

while (( WAITED < MAX_WAIT )); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "${BASE_URL}/models" \
    -H "$AUTH" \
    --max-time 30 2>/dev/null) || CODE="000"

  if [[ "$CODE" == "200" ]]; then
    READY=true
    break
  fi

  WAITED=$((WAITED + POLL_INTERVAL))
  printf "\r  ⏳ %3ds — HTTP %s" "$WAITED" "$CODE"
  sleep "$POLL_INTERVAL"
done
echo ""

COLD_START_END=$(ts)
COLD_START_SECS=$(python3 -c "print(f'{${COLD_START_END} - ${COLD_START_BEGIN}:.1f}')")

if $READY; then
  ok "Endpoint ready in ${COLD_START_SECS}s"
else
  err "Endpoint not ready after ${MAX_WAIT}s — aborting"
  exit 1
fi

# Discover model name
MODEL_NAME=$(curl -s "${BASE_URL}/models" -H "$AUTH" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null \
  || echo "granite-docling-258M")
info "Model: ${MODEL_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: First Inference (may include model warm-up overhead)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Phase 2: First Inference"

read -r FIRST_LATENCY FIRST_CODE <<< "$(do_request)"

if [[ "$FIRST_CODE" == "200" ]]; then
  ok "First inference: ${FIRST_LATENCY}s"
else
  err "First inference failed: HTTP ${FIRST_CODE} (${FIRST_LATENCY}s)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Warm Inference — sequential requests on a hot worker
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Phase 3: Warm Inference (${WARM_REQUESTS} sequential requests)"

WARM_TOTAL=0
WARM_MIN=999999
WARM_MAX=0
WARM_FAILURES=0
WARM_LATENCIES=""

for i in $(seq 1 "$WARM_REQUESTS"); do
  read -r LAT CODE <<< "$(do_request)"
  if [[ "$CODE" == "200" ]]; then
    printf "  [%d/%d] %ss\n" "$i" "$WARM_REQUESTS" "$LAT"
    WARM_LATENCIES="${WARM_LATENCIES} ${LAT}"
    WARM_TOTAL=$(python3 -c "print(${WARM_TOTAL} + ${LAT})")
    WARM_MIN=$(python3 -c "print(min(${WARM_MIN}, ${LAT}))")
    WARM_MAX=$(python3 -c "print(max(${WARM_MAX}, ${LAT}))")
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
  echo ""
  ok "Avg: ${WARM_AVG}s | P50: ${WARM_P50}s | Min: ${WARM_MIN}s | Max: ${WARM_MAX}s"
  if (( WARM_FAILURES > 0 )); then
    err "${WARM_FAILURES}/${WARM_REQUESTS} requests failed"
  fi
else
  WARM_AVG="N/A"; WARM_P50="N/A"; WARM_MIN="N/A"; WARM_MAX="N/A"
  err "All warm requests failed"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 4: Burst Test — concurrent requests to simulate ingestion spike
# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
bold "Phase 4: Burst Test (${BURST_SIZE} concurrent requests)"

BURST_DIR=$(mktemp -d /tmp/burst_XXXX)
BURST_START=$(ts)

for i in $(seq 1 "$BURST_SIZE"); do
  (
    start=$(ts)
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      "${BASE_URL}/chat/completions" \
      -H "$AUTH" \
      -H "Content-Type: application/json" \
      --max-time 300 \
      -d '{
        "model": "'"${MODEL_NAME}"'",
        "messages": [{"role": "user", "content": "Hello"}],
        "temperature": 0.0,
        "max_tokens": 16
      }' 2>/dev/null) || code="000"
    end=$(ts)
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
printf "  %-25s %s\n" "Cold start:" "${COLD_START_SECS}s"
printf "  %-25s %s\n" "First inference:" "${FIRST_LATENCY}s"
printf "  %-25s %s\n" "Warm avg (${WARM_SUCCESS} reqs):" "${WARM_AVG}s"
printf "  %-25s %s\n" "Warm P50:" "${WARM_P50}s"
printf "  %-25s %s\n" "Burst wall (${BURST_SIZE} reqs):" "${BURST_WALL}s"
echo ""

# ── Write JSON results ───────────────────────────────────────────────────────
python3 -c "
import json, datetime
results = {
    'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
    'endpoint_id': '${RUNPOD_ENDPOINT_ID}',
    'model': '${MODEL_NAME}',
    'cold_start_secs': ${COLD_START_SECS},
    'first_inference_secs': ${FIRST_LATENCY},
    'warm': {
        'requests': ${WARM_SUCCESS},
        'avg_secs': ${WARM_AVG} if '${WARM_AVG}' != 'N/A' else None,
        'p50_secs': ${WARM_P50} if '${WARM_P50}' != 'N/A' else None,
        'min_secs': ${WARM_MIN} if '${WARM_MIN}' != 'N/A' else None,
        'max_secs': ${WARM_MAX} if '${WARM_MAX}' != 'N/A' else None,
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
echo ""
