# docling-vlm

RunPod Serverless endpoint for serving IBM's
[granite-docling-258M](https://huggingface.co/ibm-granite/granite-docling-258M)
vision-language model as an OpenAI-compatible API.

Replaces the always-on Vast.ai GPU (~$650/month) with an auto-scaling-to-zero
serverless endpoint — you only pay when requests come in.

## Architecture

```
ks-backend worker
    │
    ├─ GET  /v1/models               ← health check
    └─ POST /v1/chat/completions     ← page image → docling markup
          │
          ▼
  RunPod Serverless (OpenAI proxy)
  https://api.runpod.ai/v2/{id}/openai/v1/...
          │
          ▼
  runpod/worker-v1-vllm  +  ibm-granite/granite-docling-258M (rev: untied)
```

The `Dockerfile` extends RunPod's pre-built vLLM worker with configuration
for the granite-docling model. No custom serving code required — vLLM natively
supports the Idefics3 architecture this model uses.

## Deploy to RunPod

### 1. Push this repo to GitHub

```bash
git remote add origin git@github.com:<your-org>/docling-vlm.git
git push -u origin main
```

### 2. Connect RunPod to GitHub (one-time)

Go to [RunPod Settings](https://www.runpod.io/console/user/settings) and
authorize RunPod to access your GitHub repositories.

### 3. Create a Serverless Endpoint

1. Go to [RunPod Console → Serverless → New Endpoint](https://www.runpod.io/console/serverless)
2. Select **GitHub Repo** and pick this repository (`docling-vlm`)
3. RunPod will find the `Dockerfile` in the root and build it automatically
4. Configure the endpoint:

| Setting              | Value                          |
|----------------------|--------------------------------|
| GPU Type             | Any with ≥ 4 GB VRAM (model is 258M params) |
| Active Workers       | `0` (scale to zero)            |
| Max Workers          | `1` (increase later if needed) |
| Idle Timeout         | `300` seconds                  |
| Execution Timeout    | `600` seconds                  |

All model configuration (model name, revision, served name) is baked into
the Dockerfile — no need to set env vars manually in the RunPod console.

> **Why `untied` revision?** The `main` branch of this model uses tied
> embeddings, which causes failures in vLLM. The `untied` revision fixes this.

### 4. Test the endpoint

Copy `.env.example` to `.env` and fill in your API key and endpoint ID:

```bash
cp .env.example .env
# edit .env with your RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID
```

Run the test script:

```bash
./scripts/test_endpoint.sh
```

This will:
- Hit `GET /v1/models` and verify `granite-docling-258M` is listed
- Send a text-only chat completion request
- Measure hot-start latency with a follow-up request

The first request will be slow (cold start — GPU spinning up + model loading).
Subsequent requests while the worker is warm should be fast.

### 5. Wire into ks-backend

Add to `ks-backend/.env.dev`:

```
VLM_ENDPOINT=https://api.runpod.ai/v2/<endpoint-id>/openai/v1/chat/completions
VLM_MODEL=granite-docling-258M
VLM_API_KEY=<your-runpod-api-key>
```

Then run the backend and upload a test PDF:

```bash
make dev-api
make dev-worker
```

Watch the worker logs for `vlm_model_available` (success) or
`vlm_endpoint_unreachable` / `vlm_model_not_found` (failure).

## Known issues

**Cold start vs health check timeout** — The backend's health check
(`GET /v1/models`) has a 10-second timeout. RunPod cold starts can take
30–90 seconds. If the health check times out, the worker silently falls back
to the non-VLM pipeline. Workarounds:

1. Pre-warm the endpoint before a batch job (send a manual curl request)
2. Increase the timeout in `ks-backend/src/worker/utils/docling.py:check_vlm_available()`
3. Set Active Workers to `1` instead of `0` (always-on, but still cheaper than Vast.ai)

**Model name mismatch** — The name in `/v1/models` must match `VLM_MODEL`
(case-insensitive). The `OPENAI_SERVED_MODEL_NAME_OVERRIDE` env var ensures
vLLM reports `granite-docling-258M` instead of the full HuggingFace path.

## Environment variables

See the [Dockerfile](./Dockerfile) for defaults. All can be overridden in
the RunPod console.

| Variable | Default | Purpose |
|---|---|---|
| `MODEL_NAME` | `ibm-granite/granite-docling-258M` | HuggingFace model ID |
| `MODEL_REVISION` | `untied` | Required for vLLM compatibility |
| `OPENAI_SERVED_MODEL_NAME_OVERRIDE` | `granite-docling-258M` | Model name exposed via `/v1/models` |
| `GPU_MEMORY_UTILIZATION` | `0.90` | Fraction of GPU VRAM to use |
| `MAX_MODEL_LEN` | `4096` | Max context length in tokens |
| `MAX_CONCURRENCY` | `2` | Max concurrent requests per worker |
