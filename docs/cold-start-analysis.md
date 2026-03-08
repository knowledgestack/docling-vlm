# Cold Start Analysis: RunPod Serverless GPU

## Context

We serve IBM's [granite-docling-258M](https://huggingface.co/ibm-granite/granite-docling-258M) vision-language model on a RunPod serverless endpoint for document ingestion. Our workloads are bursty — documents arrive in spikes, with idle periods in between. This analysis determines whether we need a warm pool of GPU instances or can rely on scale-to-zero.

## Benchmark Results

All benchmarks ran against endpoint `docling-vlm-2` using `scripts/benchmark_coldstart.sh` and simple text prompts (`max_tokens: 16`). Image-based inference benchmarks (`scripts/benchmark_inference.sh`) should be run separately for realistic per-document latency.

### True Cold Start (first-ever boot, no FlashBoot cache)

| Metric | Value |
|---|---|
| Cold start | **~80s** |
| First inference | 0.75s |

This was observed on the very first request after deploying the endpoint, before RunPod had any cached state.

### FlashBoot Cold Start (0 running workers, $0.00/s billing, but recently used)

| Metric | Value |
|---|---|
| Cold start | **~1.4s** |
| First inference | 0.67s |

Even with 0 running workers and no active billing, RunPod's FlashBoot revived a cached worker in ~1.4s. This was reproducible across multiple runs.

### Warm Inference (worker already running)

| Metric | Value |
|---|---|
| Avg latency (text, 16 tokens) | 0.71s |
| P50 latency | 0.69s |
| Min / Max | 0.65s / 0.80s |

### Burst Test (5 concurrent text requests)

| Metric | Value |
|---|---|
| Wall time | ~3.9s |
| Avg per-request | 2.2s |
| P50 | 2.6s |
| Success rate | 5/5 |

Higher per-request latency during bursts is expected — the endpoint has `MAX_CONCURRENCY=2`, so requests queue behind each other on a single worker.

> **Note:** These numbers are for trivial text prompts. Real document image inference will be significantly slower due to image encoding, vision preprocessing, and longer output generation (500-2000+ tokens). Run `scripts/benchmark_inference.sh` for realistic numbers.

## RunPod Worker Types

| Type | Behavior | Billing | Cold Start |
|---|---|---|---|
| **Active Workers** | Always on, never shut down | Continuous (40% discount) | None |
| **Flex Workers** | Spin up on demand, shut down after idle timeout | Only while running | FlashBoot or full cold start |

- **Active Workers** = minimum workers always running. Set via endpoint config.
- **Max Workers** = ceiling for autoscaling. Flex workers spin up to fill the gap between active and max.
- **Idle Timeout** = how long a flex worker stays alive after finishing its last job (default: 5s). Worker is fully shut down after this expires.

Source: [RunPod Endpoint Configurations](https://docs.runpod.io/serverless/endpoints/endpoint-configurations)

## FlashBoot

FlashBoot is RunPod's container caching system that reduces cold starts by retaining worker state after shutdown. It's free and enabled by default.

### Key characteristics

- **Probabilistic, not time-based.** There is no fixed TTL or cache duration.
- **Decay curve:** Requesting a worker immediately after shutdown gives the highest chance of a FlashBoot hit. The probability decreases over time until eventually you get a full cold start.
- **No guaranteed SLA.** RunPod staff confirmed: *"there isn't a fixed timeframe — it is based on the requests you have and their platform available resources."*
- **Traffic-dependent.** Endpoints with consistent traffic get better FlashBoot hit rates. After extended idle periods, FlashBoot *"is disabled as the instance goes to a deeper sleep."*
- **Image popularity matters.** Container images used by more RunPod customers are cached more aggressively across the platform.

### What we observed

| Scenario | Cold start time |
|---|---|
| First-ever request (no cache) | ~80s |
| Request after ~20 min idle | ~1.4s (FlashBoot hit) |
| Unknown: after hours/days idle | Likely 80s (FlashBoot expired) |

### Sources

- [Introducing FlashBoot: 1-Second Serverless Cold-Start (RunPod Blog)](https://www.runpod.io/blog/introducing-flashboot-serverless-cold-start)
- [Keeping Flashboot active? (RunPod Discord)](https://www.answeroverflow.com/m/1293671895564161116)
- [Flashboot not working after a while (RunPod Discord)](https://www.answeroverflow.com/m/1340825479820611624)
- [Serverless or Regular Pod? How good is Flashboot? (RunPod Discord)](https://www.answeroverflow.com/m/1292890615922561076)
- [Very slow cold starts with FlashBoot (GitHub Issue)](https://github.com/runpod-workers/worker-vllm/issues/111)

## Recommendations

### For bursty workloads with predictable patterns (e.g. business-hours ingestion)

**Set Active Workers = 0, Idle Timeout = 300s.** Workers stay warm between closely-spaced bursts and shut down during long gaps. FlashBoot handles the re-warm if the gap is short enough.

Optionally, send a pre-warm request (e.g. `GET /v1/models`) before kicking off a batch job to absorb the cold start outside the critical path.

### For unpredictable bursts with long idle gaps (hours/days)

**Set Active Workers = 1.** One worker is always warm and handles the first request instantly. Flex workers scale up for the rest of the burst. This costs more (continuous billing at 40% discount) but guarantees no cold start penalty.

### For cost-sensitive, latency-tolerant workloads

**Set Active Workers = 0, rely on FlashBoot.** Accept that the first request after a long gap may take ~80s. Subsequent requests in the same burst will be fast. This is the cheapest option.

### Cost comparison (rough estimate)

Assuming an RTX A4500 at ~$0.29/hr on RunPod serverless:

| Strategy | Monthly idle cost | Cold start risk |
|---|---|---|
| Active Workers = 0 | $0 | 1.4s–80s (unpredictable) |
| Active Workers = 1 | ~$210/mo | None |
| Idle Timeout = 300s | Depends on traffic | None within 5 min of last request |

Compare to the previous always-on Vast.ai GPU at **~$650/mo**.

## Scripts

- `scripts/benchmark_coldstart.sh` — Measures cold start, warm inference, and burst latency with simple text prompts.
- `scripts/benchmark_inference.sh` — Measures realistic inference latency using actual document page images.

### Usage

```bash
# True cold start: scale to 0 in RunPod dashboard, wait for workers to fully terminate
./scripts/benchmark_coldstart.sh

# Realistic document inference (run after endpoint is warm)
./scripts/benchmark_inference.sh

# Custom parameters
WARM_REQUESTS=10 BURST_SIZE=10 ./scripts/benchmark_coldstart.sh
SAMPLE_IMAGE=/path/to/your/doc.png MAX_TOKENS=4096 ./scripts/benchmark_inference.sh
```

Results are saved as timestamped JSON files in `results/` (gitignored).
