# Task: RunPod Serverless VLM Endpoint

## Goal

Build a Docker container that serves the `granite-docling-258M` vision model as an
OpenAI-compatible HTTP API, then deploy it on RunPod Serverless so it auto-scales
to zero when idle.

## Context

Our backend worker (`ks-backend`) already knows how to talk to this model. It sends
HTTP requests to two endpoints:

1. `GET /v1/models` — "what models are loaded?" (health check)
2. `POST /v1/chat/completions` — "here's a page image, extract the content"

Currently this runs on a Vast.ai GPU 24/7 (~$650/month). We want RunPod Serverless
so we only pay when requests come in.

### What the backend expects

The backend sends these env vars to configure the connection:

```
VLM_ENDPOINT=http://<host>/v1/chat/completions   # full URL to chat completions
VLM_MODEL=granite-docling-258M                    # model name returned by /v1/models
VLM_API_KEY=<optional bearer token>               # sent as Authorization: Bearer <key>
```

The backend calls `GET /v1/models`, checks that the configured model name appears in
the response list (case-insensitive), and if so, sends chat completion requests with:

```json
{
  "model": "<VLM_MODEL>",
  "messages": [{"role": "user", "content": "Convert this page to docling."}],
  "temperature": 0.0,
  "skip_special_tokens": false
}
```

Images are sent inline in the messages as base64 data URIs (standard OpenAI vision
format). The response must be standard OpenAI chat completion format.

### VLM pipeline settings (from ks-backend ingestion_config.yaml)

- `vlm_concurrency: 2` — up to 2 parallel requests per document
- `vlm_temperature: 0.0`
- `vlm_timeout: 300` — 5 minute timeout per request
- `document_timeout: 7200` — 2 hour max for full document conversion

---

## Tasks

### 1. Find the right model on HuggingFace

- The model is IBM's `granite-docling-258M` (a small vision-language model for
  document understanding)
- HuggingFace ID: look for `ds4sd/docling-granite-258M-preview` or similar under
  the `ibm-granite` or `ds4sd` organizations
- We need either:
  - **The original safetensors** (if using vLLM to serve it), OR
  - **A GGUF conversion** (if using llama.cpp to serve it)
- The model is only 258M parameters — any modern GPU can run it

### 2. Choose a serving approach

Pick ONE of these. Both produce the same OpenAI-compatible API.

#### Option A: RunPod's vLLM worker (recommended — least work)

- RunPod has a pre-built Docker image: `runpod/worker-vllm`
- It loads a model from HuggingFace and serves it with OpenAI-compatible endpoints
- You configure it via environment variables (model name, HF token, etc.)
- RunPod exposes it at: `https://api.runpod.ai/v2/{endpoint_id}/openai/v1/...`
- Docs: https://github.com/runpod-workers/worker-vllm
- **Verify that vLLM supports this specific model** (check vLLM's supported models
  list for vision models)

#### Option B: Custom Docker image with llama.cpp

- Write a `Dockerfile` that:
  1. Starts from a CUDA base image (e.g. `nvidia/cuda:12.4.0-runtime-ubuntu22.04`)
  2. Installs llama.cpp (build from source or use a release binary)
  3. Downloads the GGUF model file at build time (bake it into the image) or at
     container startup
  4. Runs `llama-server` which natively exposes `/v1/chat/completions` and
     `/v1/models`
- The startup command would be something like:
  ```
  llama-server --model /models/granite-docling-258M.gguf --port 8000 --host 0.0.0.0
  ```
- Push the image to Docker Hub (or RunPod's container registry)

### 3. Deploy on RunPod Serverless

1. Go to RunPod → Serverless → New Endpoint
2. If using Option A (vLLM worker): select the vLLM template, configure the model
3. If using Option B (custom image): point it to your Docker Hub image
4. Configure:
   - **GPU type**: cheapest that fits (RTX 4000/3090/4090 — model is tiny)
   - **Active workers**: `0` (this is the whole point — zero cost when idle)
   - **Max workers**: `1` (start with 1, increase later if needed)
   - **Idle timeout**: `300` seconds (5 minutes — GPU shuts down after this)
   - **Execution timeout**: `600` seconds (long enough for big PDFs)

### 4. Verify the endpoint works

Once deployed, test from the command line:

```bash
# Check /v1/models — should list the model name
curl https://api.runpod.ai/v2/{endpoint_id}/openai/v1/models \
  -H "Authorization: Bearer $RUNPOD_API_KEY"

# Send a test chat completion (text-only, no image, just to verify the format)
curl https://api.runpod.ai/v2/{endpoint_id}/openai/v1/chat/completions \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-docling-258M",
    "messages": [{"role": "user", "content": "Hello"}],
    "temperature": 0.0
  }'
```

Both should return standard OpenAI-format JSON responses.

### 5. Measure latency

- **Cold start**: time the first request after the endpoint has been idle (GPU
  spins up from zero). Run the curl above with `time` in front.
- **Hot start**: time a second request immediately after. This is the steady-state
  performance.
- Record both numbers.

### 6. Wire it into ks-backend for testing

Update `ks-backend/.env.dev` with:

```
VLM_ENDPOINT=https://api.runpod.ai/v2/{endpoint_id}/openai/v1/chat/completions
VLM_MODEL=granite-docling-258M
VLM_API_KEY=<your runpod api key>
```

Then:
1. Run `make dev-api` and `make dev-worker`
2. Watch worker logs — look for `vlm_model_available` (success) or
   `vlm_endpoint_unreachable` / `vlm_model_not_found` (failure)
3. Upload a test PDF through the app
4. Confirm VLM-powered ingestion completes

### Potential issues

- **Cold start vs health check timeout**: The backend's health check (`GET /v1/models`)
  has a 10-second timeout. If cold start takes longer, the check will fail and the
  worker falls back to the non-VLM pipeline silently. Fix: pre-warm the endpoint with
  a manual curl before testing, or increase the timeout in
  `ks-backend/src/worker/utils/docling.py:check_vlm_available()`.
- **Model name mismatch**: The model name in `/v1/models` response must match
  `VLM_MODEL` (case-insensitive). Check what name the server actually reports.
- **RunPod URL format**: Make sure the URL path is correct. RunPod's OpenAI-compatible
  proxy lives under `/openai/v1/...` not just `/v1/...`. The full URL would be
  `https://api.runpod.ai/v2/{endpoint_id}/openai/v1/chat/completions`.

## Definition of Done

- Docker image is built and pushed (or vLLM template is configured)
- RunPod serverless endpoint is running with active workers = 0
- `GET /v1/models` returns the model name
- `POST /v1/chat/completions` returns a valid response
- Cold start and hot start times are measured and recorded
- OR: document why it doesn't work and what blocked it
