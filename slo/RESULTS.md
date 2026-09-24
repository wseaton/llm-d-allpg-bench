# Live SLO under batch load: flow control with InferenceObjective

Setup (waldorf, namespace allpg-bench):

- 4 vllm-vcr engines: max_num_seqs 64, TTFT 60±10 ms, ITL 20±3 ms, latency scaling
  linearly to 3x at a full batch (`vcr.env`).
- llm-d router standalone chart, release `slo` (pool `slo`), EPP image from chart v0,
  `flowControl` feature gate, `concurrency-detector` at 64 per endpoint, bands 100/0/-10,
  60 s TTL (`router.values.yaml`).
- InferenceObjectives `live` (priority 100) and `batch` (priority -10) (`objectives.yaml`).
- Live: nyann-bench in-cluster (`slo-runner`), Poisson 16 req/s, 256 in / 128 out, header
  `x-llm-d-inference-objective: live`. Needs nyann-bench `slo-bench` (headers option,
  per-stage rates).
- Batch: batch gateway -> Postgres -> llm-d-async sql dispatcher (1024 workers), 6000
  requests of 256 in / 128 out, objective `batch` on the queue.
- SLO: live TTFT <= 500 ms. Attainment = share of live requests meeting it.

Pool capacity with live alone (`sweep.star`): TTFT p99 136 / 167 / 215 / 273 ms at 8 / 16 /
24 / 30 req/s, then 6.2 s at 38 req/s. The pool saturates between 30 and 38 req/s.

| Run | Batch path | Live TTFT p99 | SLO | Live ITL p50 | Batch req/s | Batch TTL evictions | Mean saturation |
|---|---|---|---|---|---|---|---|
| A1 | none | 166 ms | 100% | 28 ms | - | - | - |
| B1 | dispatcher -> engines (no router) | 62 s | 0% | 60 ms | 29 | - | - |
| C1 | router, flow control | 6.1 s | 14% | 60 ms | 18 | 57 | - |
| D1 | C + dispatcher gate on pool saturation (close at 0.75) | 5.9 s | 44% | 59 ms | 18 | 0 | 0.98 |
| E1 | router, flow control + priority-holdback (batch ceiling 0.6) | 256 ms | 100% | 44 ms | 12.7 | 692 | 0.61 |
| F1 | E + dispatcher gate on EPP batch queue depth (256) | 257 ms | 100% | 44 ms | 13.1 | 530 | 0.61 |
| E-c07 | holdback, batch ceiling 0.7 | 283 ms | 99.97% | 48 ms | 14.1 | 458 | 0.72 |
| E-c08 | holdback, batch ceiling 0.8 | 301 ms | 100% | 52 ms | 15.6 | 177 | 0.81 |
| E-c09 | holdback, batch ceiling 0.9 | 1551 ms | 97.8% | 56 ms | 16.2 | 82 | 0.92 |
| G-burst08 | ceiling 0.8, live 16 -> 28 -> 16 req/s | 304 ms | 100% | - | 13.6 | - | 0.82 (max 0.99) |
| **H-bounded08** | **ceiling 0.8 + composite gate: queue depth 256 AND local-max-concurrency 384** | **301 ms** | **100%** | **52 ms** | **16.0** | **0** | **0.81** |

Findings:

1. Without the router (B) batch takes the whole pool and live TTFT goes to a minute.
2. Flow control with objectives (C) orders EPP's queue by priority, but EPP keeps every
   engine at exactly 64 in flight (engine-side waiting stays ~0), so a live request waits for
   a slot to turn over, and at a full batch every slot turns over 3x slower. Priority
   ordering alone does not create headroom.
3. The dispatcher gate cannot create headroom either (D): anything already buffered in EPP's
   batch band fills every slot live does not claim. It closed ~37k times yet saturation
   stayed at 0.98.
4. priority-holdback (E) is what preserves the SLO: EPP holds batch once saturation passes the
   batch ceiling, live's queue in EPP stays empty, and live TTFT p99 is within 90 ms of the
   live-only baseline. The price is batch throughput (12.7 vs 18 req/s) and live ITL (44 vs
   28 ms: the running batch is still 60% full).
5. The dispatcher overshoots into EPP by roughly its concurrency: the gate is a per-request
   boolean on a reading up to the cache TTL old, so 1024 workers dispatch ~1000 requests
   before the first refresh, and what EPP cannot admit within its 60 s TTL is evicted and
   retried. Gating on queue depth (F) trims evictions but does not bound the burst.
6. The holdback ceiling is the trade-off knob. 0.8 is the knee: live TTFT p99 301 ms (SLO
   held), batch at 87% of its unprotected throughput. At 0.9 the p99 jumps to 1.5 s.
7. Bursts: with live stepped to 28 req/s (near pool capacity) for a minute, TTFT p99 stayed
   at 288-333 ms in every 20 s window and live never queued in EPP; batch yielded (saturation
   peaked at 0.99, batch averaged 13.6 req/s). Caveat: nyann-bench waits for a stage's
   requests before starting the next, so each transition has a ~6 s arrival gap and the
   burst ran ~51 s.
8. Bounding the dispatcher (H) removes the churn: a composite gate of EPP batch-queue depth
   AND local-max-concurrency 384 gave zero TTL evictions, zero retries, the EPP batch buffer
   at ~265 against a 256 target, and the best protected batch throughput (16.0 req/s).

Recommended configuration: EPP flow control with `priority-holdback-policy` (batch
`minCeiling` 0.8) and the dispatcher on a composite gate that bounds what it buffers in EPP
(`dispatcher-router-bounded.values.yaml`). Flow control priority alone, or a dispatcher
saturation gate alone, does not hold a live TTFT SLO.

Open:
- priority-holdback is alpha (`--allow-experimental-plugins`).
- The 384 in-flight cap is sized by hand from the ceiling and pool size; a gate that derives
  it from EPP's reported capacity would not need retuning when the pool scales.
- `PropagatePriority` (EPP -> engine priority scheduling) untested.
- One trial per configuration; no repeat runs yet.

## High RPS: 16 engines

Engines scaled to 16 (1 CPU each, 1024 batch slots). Live-only capacity (`sweep16.star`): TTFT
p99 169 / 182 / 212 / 286 ms at 40 / 80 / 96 / 121 req/s, then 2.1 s at 139 and 7.4 s at 157. The
pool saturates at about 130 req/s. All runs below: holdback ceiling 0.8, batch 256 in / 128 out
through the batch gateway and the sql dispatcher, live Poisson through the router
(`program.sh`, strictly sequential).

| Run | Live offered | Live TTFT p50 / p99 | SLO | Live errors | Batch req/s | Batch failed | TTL evictions |
|---|---|---|---|---|---|---|---|
| S16-t1 (10 min) | 80 | 239 / 364 ms | 99.99% | 0 | 44.3 | 0 | 0 |
| S16-t2 (10 min) | 80 | 237 / 362 ms | 99.99% | 0 | 44.5 | 0 | 0 |
| S16-t3 (10 min) | 80 | 239 / 363 ms | 99.98% | 0 | 44.9 | 0 | 0 |
| NC16 (5 min) | 110 (104 delivered) | 237 / 336 ms | 99.99% | 0 | 19.1 | 0 | 1910 |
| BU16 (8 min) | 80, +40 for 128 s | 238 / 357 ms (321 in burst) | 99.98% | 0 | 35.9 | 0 | 1944 |
| OL16 (3 min) | 150 (122 delivered) | 6.6 / 13.2 s | 4% | 6 | 4.8 | 0 | 2209 |
| OL16 live only | 150 (124 delivered) | 4.8 / 12.4 s | 12% | 13 | - | - | - |

- Sustained at 80 req/s live plus batch the pool runs at ~122 req/s (94% of capacity) with the
  SLO held; three 10-minute trials agree to within 2 ms at p99.
- Near capacity and during a 50% live surge (continuous second stream, no stage gap) the SLO
  holds; batch yields (44 -> 19 req/s).
- Overload (offered live above capacity) cannot meet any SLO; batch falls to 4.8 req/s and live
  p99 is within 7% of the live-only overload. Holdback does not preempt batch already running,
  so live p50 is worse than live-only (6.6 vs 4.8 s); EPP eviction is the lever for that.
- TTL evictions at near capacity and in the burst come from the 1024-deep EPP batch buffer:
  when batch is squeezed to ~19 req/s the buffer takes ~54 s to drain against a 60 s TTL. They
  are retried and nothing fails, but the buffer only needs to cover the dispatcher gate's
  reaction time (`dispatcher-router-bounded16b.values.yaml`, 128 deep).

Bugs found on the way:

- endpoint-scrape gate deadlock on EPP's garbage-collected queue series (fixed, 452 `545cf5b`,
  `absent_value`).
- nyann-bench: per-stage rates ignored (`a363339`), abort after 5 consecutive errors not
  configurable, which ended the first chaos run at the first engine kill (`9ddf3f8`).

Invalid runs are kept in `runs/invalid-overlap/`: a chained waiter started later programs on top
of running trials, and the mixed traffic looked like EPP admitting batch past its ceiling. With
the runs serialized (`run.sh` now takes a lock) no such collapse occurs.

### Right-sized EPP batch buffer, failures, and HA (`program2.sh`, `program-ha.sh`)

`dispatcher-router-bounded16b.values.yaml`: EPP batch buffer 128 (covers the gate's reaction
time, not a backlog), 512 in flight.

| Run | Setup | Live TTFT p99 | SLO | Live errors | Batch req/s | Batch failed | TTL evictions |
|---|---|---|---|---|---|---|---|
| S16b (10 min) | 80 req/s live | 370 ms | 99.97% | 1 | 45.1 | 0 | 0 |
| NC16b (5 min) | 110 req/s live | 339 ms | 99.99% | 0 | 17.7 | 0 | 0 (1910 with the 1024 buffer) |
| BU16b (8 min) | 80, +40 for 128 s | 361 ms | 99.98% | 1 | 35.3 | 0 | 203 (1944) |
| HA-S16 (10 min) | active-passive router (2 EPP, 2 proxies) | 372 ms | 99.97% | 2 | 44.8 | 0 | 0 |

Failure injection during 10-minute runs at 80 req/s live plus batch:

| Run | Router | Killed at +120 / +240 / +360 s | Live errors | SLO | Batch failed |
|---|---|---|---|---|---|
| CH16b | single EPP | 2 engines / EPP / dispatcher | 774 | 98.35% | **21013 of 36000** |
| CH16r | single EPP, transport retries | same | 741 | 98.40% | **0** |
| HA-CH16 | active-passive, chart defaults | primary EPP / 1 proxy / dispatcher | 2512 | 91.5% | 0 |
| HA-CH16-hc9003 | active-passive, EPP probed on 9003 | same | 359 | 99.0% | 0 |

- Transport errors were fatal in llm-d-async: every request dispatched to a dying engine or
  proxy failed the batch line. Retrying them with backoff (local branch
  `sql-transport-retry`) took batch failures under chaos to zero.
- The router chart probes EPP on the ext_proc port, whose health service stays SERVING through
  graceful shutdown, so a primary restart returned 503 "flow controller shutting down" for
  ~30 s. Probing the drain-aware health server (port 9003) cut it to 31 errors and one 20 s
  window at 1.5 s p99 while the new primary took over.
- What remains is a proxy kill: Envoy exits on SIGTERM with no preStop drain, cutting its
  in-flight streams (~330 live requests here). Batch is unaffected (retried).
- Engine kills cost live traffic the requests running on those engines (unexpected EOF) and
  nothing else; the dispatcher kill cost nothing.

## Verdict

At 94% of pool capacity (80 req/s live + ~45 req/s batch on 16 engines), with flow control,
InferenceObjective priorities and priority-holdback at 0.8, the live TTFT SLO (500 ms) holds at
99.97-99.99% across three 10-minute trials (p99 362-370 ms, vs 182 ms live-only), near
capacity, and through a 50% live surge; batch uses the remaining capacity and yields when live
grows. Batch loses nothing through engine, EPP, proxy and dispatcher kills once transport
errors retry.

Not production-ready until:
1. Transport-error retries land in llm-d-async (branch `sql-transport-retry`, needs your call).
2. The router chart probes EPP's drain-aware health port and drains Envoy on shutdown.
3. priority-holdback leaves alpha (`--allow-experimental-plugins`).
4. The dispatcher's EPP-buffer and in-flight bounds derive from pool size instead of being
   hand-set per pool.
Overload above pool capacity cannot meet the SLO by design; EPP eviction (untested) is the
lever for preempting running batch.

### Pool-derived bounds (`program-dyn.sh`, `program-counted.sh`)

The hand-set bounds are replaced by pool-derived ones: the EPP batch buffer is 8 slots per
ready engine (EPP's `llm_d_epp_ready_endpoints`), and there is no in-flight cap beyond the
dispatcher's worker count. Same config at every pool size.

| Run | Pool | Live | Admission | Live TTFT p99 | SLO | Batch failed | EPP batch queue mean / max (target) | TTL evictions |
|---|---|---|---|---|---|---|---|---|
| DYN-16 | 16 | 80 | budget | 371 ms | 99.99% | 0 | 740 / 1767 (128) | 0 |
| DYN-8 | 8 | 40 | budget | 323 ms | 100% | 0 | 1159 / 1913 (64) | 4627 |
| DYN-scale | 16 -> 10 at +200 s | 60 | budget | 339 ms | 99.52% | 0 | 925 / 1932 | 4031 |
| CNT-8 | 8 | 40 | counted | 317 ms | 100% | 0 | 60 / 64 (64) | 0 |
| CNT-scale | 16 -> 10 at +200 s | 60 | counted | 344 ms | 99.61% | 0 | 102 / 128 | 0 |

- The SLO never depends on the dispatcher bounds; priority-holdback in EPP holds it.
- Budget admission lets every worker through while one cached reading is open, so the queue
  overshot its target up to 30x and batch expired in EPP. Counted admission (llm-d-async
  `b9dcfaf`) holds the queue at its target with zero expirations and unchanged throughput.
- The 137-169 live errors in the scale-down runs are requests running on the deleted engines:
  vcr, like vLLM's default `shutdown_timeout` of 0, aborts in-flight work on SIGTERM. Engine
  deployments need a shutdown timeout and grace period to scale down without dropping work.

### Every failure at once, all fixes in place

Router from the chart branch with the EPP health-port fix and proxy drain; dispatcher with
transport retries and counted admission; pool-derived bounds. 10 minutes at 80 req/s live
plus batch; two engines killed at +90 s, the primary EPP at +210 s, a proxy at +330 s, the
dispatcher at +450 s (`slo-ALL`).

| Failure | Live errors | Notes |
|---|---|---|
| 2 engines | 50 | requests running on the killed engines (engine aborts on SIGTERM) |
| primary EPP | 19 | failover to the standby within ~2 s |
| primary EPP failback (~40 s later) | 0 | ~900 requests over SLO for ~20 s: the new primary starts without the standby's in-flight state |
| proxy | 1 | connections drained before SIGTERM |
| dispatcher | 0 | |
| **Run total** | **70 of 46.9k** | SLO 97.95%; batch 0 failed, 0 expired in EPP |

Proxy restarts alone (`slo-PX-*`): 626 live errors without drain, 1 with it.

A max(concurrency, engine utilization) saturation signal (`router-holdback-maxsat.values.yaml`)
did not remove the failback spike and cost steady state (p99 538 ms, SLO 98.2%, batch 37 req/s),
because the utilization detector's KV term (threshold capped at 1.0) sits above the holdback
ceiling. Kept concurrency-only.

## Where it stands

Holds: live TTFT SLO at 94% of pool capacity over repeated 10-minute trials; near capacity; live
surges; pool sizes 8-16 and scale-down with one pool-derived config; no batch loss through
engine, EPP, proxy, and dispatcher failures.

Changes that make it so:
- llm-d-async PR 452: `absent_value` (`545cf5b`), transport-error retries (`33d370c`), counted
  admission (`b9dcfaf`). Pushed; PR not merged.
- llm-d/llm-d-router#3029: EPP health-port health checks and proxy drain. Open.
- nyann-bench fork branches `feature/request-headers`, `slo-bench`: headers, per-stage rates,
  configurable error abort. Pushed, no PRs yet.

Accepted limitation: active-passive EPP failback. A restarted primary takes traffic back
without the standby's in-flight state, costing ~20 s of live TTFT above SLO (~1000 requests at
80 req/s) once per primary restart. Fixing it needs cross-replica in-flight sync in the router
(upstream ships only a no-op syncer). priority-holdback is still alpha.

## Transport A/B: Postgres control plane, sql vs redis-sortedset async transport (2026-09-24)

Gateway control plane on Postgres (#676) either way; only llm-d-async dispatch moves. Redis 7.4 on
the Postgres node with the same 8 cores (`redis.yaml`, appendonly off, 8 io-threads). Both
transports on identical images: gateway `allpg-8-batchsubmit` (batched redis result reads and
submits, submit batching on every transport), dispatcher `allpg-6-counted`, poll 5 ms, batch 256,
1024 workers. `tput-ab.sh`: 200k requests (10 x 20k, 64-token prompts), 4 zero-latency vcr
engines, reps alternating transports.

| Rep | sql e2e req/s | redis-sortedset e2e req/s |
|---|---|---|
| 1 | 4,129 (first run after deploy) | 2,684 |
| 2 | 12,273 | 2,684 |
| 3 | 13,922 | 2,746 |

No failures on either. Redis server time is ~4 s of each 74 s run and no pod is CPU-bound: the
redis transport's `requestWorker` handles each peeked request serially (cancellation `GET`s,
claim round trip, unbuffered hand-off), 3-4 round trips per request on one goroutine per queue,
which caps it near 2.7k req/s per dispatcher. The sql transport batches its claims and
cancellation checks per poll. Before the gateway parity changes (`tpv1-*`): redis 2,423 req/s,
with one MULTI/EXEC per submitted request (200,007 EXECs; 796 after).

### SLO battery by transport (rebased gateway `allpg-9-rebased`, `program-transport.sh`)

16 vcr engines, holdback 0.8, active-passive router with the per-request proxy drain, counted
admission. Each scenario ran on sql then redis back to back.

| Scenario | Transport | Live TTFT p99 | SLO met | Live errors | Batch req/s | Batch failed |
|---|---|---|---|---|---|---|
| Steady, 80 req/s, 10 min | sql | 373 ms | 99.97% | 1 | 45.4 | 0 |
| | redis | 373 ms | 99.97% | 0 | 45.5 | 0 |
| Near capacity, 110 req/s, 5 min | sql | 338 ms | 99.94% | 2 | 18.6 | 0 |
| | redis | 339 ms | 99.99% | 0 | 19.6 | 0 |
| Surge, 80 + 40 req/s for 120 s | sql | 361 ms | 99.98% | 1 | 35.1 | 0 |
| | redis | 363 ms | 99.98% | 0 | 35.6 | 0 |
| Every failure, 10 min | sql | 8,604 ms | 94.94% | 132 | - | 0 |
| | redis | 370 ms | 99.69% | 134 | - | 0 |

Batch at these rates is far below the redis transport's ~2.8k req/s cap, so steady state, near
capacity and surge are the same on both. The every-failure runs differ only at the primary EPP
failback (+253 s): in the sql run the restarted primary, starting without the standby's
in-flight state, pushed engines to 897 running plus 564 waiting (normal: ~730 and 0), so live
TTFT p99 reached 11.6 s for ~40 s and 2,242 live requests missed the SLO; in the redis run the
same failback peaked at 750 running and 0 waiting. One run each cannot separate transport from
the timing of the failback. Live errors match across transports: engine kills 76-82 (engines
abort in-flight work on SIGTERM), primary EPP kill 49-58 503s, up from 19 in `slo-ALL`.
