# Batch TTS: flow control on the llm-d router

Qwen3-TTS-12Hz-1.7B-CustomVoice on vllm-omni v0.28.0, one H200, behind a `tts` router release
using llm-d's text-to-speech EPP config (active-request scorer, data layer defaults off). Live
traffic: `tts-load.py`, streaming PCM (`stream_format: audio`), Poisson 6 req/s for 5 minutes,
objective `tts-live` (priority 100). Batch: 4000-line `/v1/audio/speech` batch through the gateway
and llm-d-async, submitted 60 s before live traffic. SLO: time to first audio at most 500 ms.

## Calibration (live only)

| Offered | TTFA p50 / p99 | Mean in flight |
|---|---|---|
| 2 req/s | 142 / 213 ms | 10 |
| 4 req/s | 145 / 206 ms | 17 |
| 6 req/s | 167 / 258 ms | 29 |
| 8 req/s | 212 / 343 ms | 42 |
| 12 req/s | 306 / 2188 ms | 67 |
| 16 req/s | 9.7 / 22 s | 253 |

The SLO holds to ~45 in flight; the concurrency detector uses `maxConcurrency: 50`.

## Live next to batch

| Scenario | TTFA p50 / p99 | Live within SLO | Batch in window |
|---|---|---|---|
| Live only | 170 / 266 ms | 100% | - |
| Batch flood, no flow control (batch without an objective) | 272 s / 294 s | 0% | 2311 done, 324 failed |
| Flow control, holdback minCeiling 0.8, counted admission | 245 / 2528 ms | 80.2% | 518 done, 0 failed |
| Flow control, holdback minCeiling 0.4, counted admission | 177 / 375 ms | 100% | 164 done, 0 failed |

Holdback holds new batch dispatch past the ceiling, but a batch request already running keeps
its slot for the whole clip (seconds). Live at 6 req/s needs ~26 slots, so the batch ceiling has
to leave that much under the ~45-slot knee: 0.8 x 50 = 40 batch slots is too many, 0.4 x 50 = 20
fits. The cost is batch throughput while live traffic is present.

## Findings for the router and the TTS guide

- Flow control works for `/v1/audio/speech`: priority bands, holdback and the concurrency
  detector count audio requests with no engine metrics.
- Without flow control, the guide's config rejects every negative-priority request: the legacy
  admission controller's utilization detector sees no metrics (data layer defaults off), reports
  saturation, and sheds all sheddable requests with 429 even on an idle engine.
- With the data layer defaults off, `llm_d_epp_ready_endpoints` reads 0, so gates that size
  capacity from it (llm-d-async `endpoint-scrape` with `pods_metric`) need a fixed capacity.
- The guide's `apiVersion: inference.networking.x-k8s.io/v1alpha1` fails on router `main`
  images; `llm-d.ai/v1alpha1` works.
- The default `token-producer` still runs with `injectDefaults: false` and logs an ERROR per
  audio request ("unsupported request body type").
- vllm-omni rejects `response_format: aac` (400); wav, mp3, flac, opus and pcm work.
