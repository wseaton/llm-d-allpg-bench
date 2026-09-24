# llm-d all-Postgres batch stack: bench kit

The scripts, Helm values, scenarios and run summaries behind the all-Postgres llm-d batch
evaluation. The stack has these parts:

- the batch gateway (Postgres control plane),
- llm-d-async (sql transport),
- the llm-d router (EPP flow control with InferenceObjectives and priority-holdback),
- vllm-vcr or real vLLM engines.

It measures three things:

- batch throughput through the gateway, Postgres and dispatcher;
- live TTFT SLO preservation next to batch traffic;
- failure handling: engine, EPP, proxy and dispatcher kills.

Results are in [`slo/RESULTS.md`](slo/RESULTS.md). Every bug found along the way, with its
fix and where the fix lives, is in [`FIXES.md`](FIXES.md).

## Code under test

| Component | Source | Notes |
|---|---|---|
| llm-d-async dispatcher | [llm-d/llm-d-async#452](https://github.com/llm-d/llm-d-async/pull/452), branch [`wseaton/llm-d-async:sql-transport-partition-leases`](https://github.com/wseaton/llm-d-async/tree/sql-transport-partition-leases) | sql transport, sql-quota, transport-error retries, `endpoint-scrape` with `absent_value` and `admission: counted` |
| Batch gateway | [`wseaton/llm-d-batch-gateway:allpg-sim`](https://github.com/wseaton/llm-d-batch-gateway/tree/allpg-sim) | upstream main + [#676](https://github.com/llm-d/llm-d-batch-gateway/pull/676) (Postgres control plane) + [#677](https://github.com/llm-d/llm-d-batch-gateway/pull/677) migrations + the async-sql producer, with fixes 4, 6-9 and 13 from `FIXES.md` |
| llm-d router chart | [llm-d/llm-d-router#3029](https://github.com/llm-d/llm-d-router/pull/3029), branch [`wseaton/llm-d-router:weaton/epp-drain-health`](https://github.com/wseaton/llm-d-router/tree/weaton/epp-drain-health) | Envoy probes EPP's drain-aware health port; the proxy drains before SIGTERM |
| Load generator | [`wseaton/nyann-bench:slo-bench`](https://github.com/wseaton/nyann-bench/tree/slo-bench) | adds the `headers` workload option (sets `x-llm-d-inference-objective`), per-stage rates and `--max-consecutive-errors` |
| Engines | [vllm-vcr](https://github.com/neuralmagic/vllm-vcr) `0.2.2-vllm0.27`, or `vllm/vllm-openai:v0.30.0` (`slo/vllm/`) | vcr knobs in `slo/vcr.env`; real vLLM runs Qwen3-32B TP1 on 8 x H200 with `--shutdown-timeout=60` |
| Formal models | [wseaton/llm-d-async-formal](https://github.com/wseaton/llm-d-async-formal) | Veil (Lean 4) models of dispatch and sql-quota |

The values files reference `quay.io/wseaton/*` images. Those repositories are private, so
build your own from the branches above and override `image.repository` and `image.tag`:

```sh
# llm-d-async, at the head of the #452 branch
make docker-build IMG=<registry>/llm-d-async:<tag>
# batch gateway, on allpg-sim
make image-build IMAGE_TAG=<tag> \
  APISERVER_IMAGE_TAG_BASE=<registry>/batch-gateway-apiserver \
  PROCESSOR_IMAGE_TAG_BASE=<registry>/batch-gateway-processor
# nyann-bench, on slo-bench; copy the binary into the runner pod as /nyann-bench
GOOS=linux GOARCH=amd64 go build -o nyann-bench ./cmd/nyann-bench
```

## Layout

| Path | What |
|---|---|
| `infra.yaml`, `nodes.env` | Postgres (one pod, 8 cores) and vcr engines, pinned one role per node |
| `gateway-values.yaml`, `dispatcher-values.yaml` | base Helm values for the gateway and the dispatcher |
| `run.sh`, `driver.py`, `driver-job.yaml`, `pg-sample.sh` | batch throughput runs: submit N requests, time end to end, sample Postgres |
| `runs/sat-64-r*` | throughput run summaries (driver logs) |
| `slo/run.sh` | one SLO scenario: batch warmup, then live traffic from nyann-bench; holds a lock so runs never overlap |
| `slo/router*.values.yaml` | router overlays: holdback ceilings, active-passive HA, fast health checks, real-vLLM pool |
| `slo/dispatcher-*.values.yaml` | dispatcher overlays per scenario (direct, through the router, gated, counted) |
| `slo/objectives.yaml` | InferenceObjectives `live` (priority 100) and `batch` (priority -10) |
| `slo/*.star` | nyann-bench scenarios (steady, burst, sweeps, 150 req/s probe) |
| `slo/chaos*.sh`, `slo/burst.sh` | failure and surge injection alongside a run |
| `slo/probe.sh` | one-shot live probe against a URL with a one-line summary |
| `slo/program*.sh` | the run sequences behind each results table |
| `slo/report.py`, `slo/sampler.sh` | per-run summary and the metrics sampler |
| `slo/runs/<run>/` | per-run `summary.json`, EPP and dispatcher metric snapshots, chaos log |
| `slo/figures/` | the figures, `make_figures.py` and `build_doc.py` |

## Running

The scripts assume a namespace `allpg-bench`, and they default to the kube context
`coreweave-waldorf`; set `KUBE_CONTEXT` to use another. Service IPs are cluster-specific,
so override them for your cluster. The defaults are in `slo/run.sh`:

- `ROUTER`: router proxy Service
- `EPP_METRICS`: EPP metrics endpoint
- `TOKENIZER`: any vLLM or vcr endpoint that serves `/tokenize`
- `ENGINES`: engine pod label selector

`slo/run.sh` also needs `ASYNC_CHART`, which points at `charts/llm-d-async` in the llm-d-async
checkout. `slo/program-final.sh` needs `ROUTER_CHART` and `ROUTER_BASE_VALUES`.

```sh
# live-only baseline, 80 req/s for 10 minutes
ROUTER=<proxy svc ip> ./slo/run.sh base live-only 80 600 0
# live next to 6000 batch requests, dispatcher gated by counted admission through the router
ASYNC_CHART=... ./slo/run.sh counted router-counted 80 600 6000
# the same, with both proxies killed in turn
./slo/chaos-proxy.sh px & ./slo/run.sh px live-only 80 420 0
```

## Data

Summaries only. The per-request JSONL from nyann-bench (about 2 GB) and the metric sampler
logs are not in git. So `make_figures.py` redraws the four figures whose inputs are here (throughput, scenarios,
holdback, fixes) and skips the four that need raw data.
