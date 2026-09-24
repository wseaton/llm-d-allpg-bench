# All-Postgres stack: fixes log

Bugs found by the all-Postgres e2e, the sim harness, and the waldorf bench.
Newest first. "Where" is the commit on the named local branch; nothing below
is pushed unless it says so.

| # | Found by | Bug | Fix | Where | Status |
|---|---|---|---|---|---|
| 20 | real-vLLM probe (150 req/s, HTTP/1.1 streaming) | Fix 19's `max_connection_duration` fires on every connection, not only at shutdown. When it expires after a streamed response's headers are out, Envoy closes without `Connection: close`; Go reuses the pooled connection, and the POST sits unread through the 1 s delayed close, then gets an RST: 219 of 8601 requests on one proxy (Envoy never counted 218). | Replace it with HCM `max_requests_per_connection: 1`, which sets `Connection: close` on the response itself. Same probe: 0 errors on pod and Service. Both proxies killed under 80 req/s of real vLLM (Qwen3-32B, 8 x H200): 0 live errors across the kills, 1 unrelated engine reset in 32,369 requests. | llm-d/llm-d-router#3029 `e1f433b4` | pushed, verified |
| 19 | proxy chaos | Envoy exits on SIGTERM with no preStop, cutting every in-flight stream on a restarted proxy (626 live errors for two proxy restarts at 80 req/s). | Proxy Deployment preStop sleep 25 s, grace 45 s, HCM `max_connection_duration` 10 s so connections drain before SIGTERM: 1 live error. | llm-d/llm-d-router#3029 | replaced by #20 |
| 18 | pool-derived bounds runs | endpoint-scrape admits every request while one cached reading is open: the dispatcher overshot a 64-slot EPP batch queue to ~1900, so 4627 batch requests expired in EPP and were retried (8 engines). | `admission: counted`: each reading grants its free slots (capacity from EPP's ready endpoint count) and the gate admits at most that many until the next reading. 8 engines: queue 60/64, 0 expirations, same batch throughput. | 452 `b9dcfaf` | pushed, verified |
| 17 | HA chaos (primary EPP kill) | Router chart's Envoy health-checks EPP on the ext_proc port 9002, whose built-in gRPC health service stays SERVING through graceful shutdown while ext_proc rejects with "flow controller shutting down": ~30 s of live 503s per primary restart, even with priority routing. | Probe the drain-aware health server instead: `health_check_config.port_value: 9003` with a plaintext `transport_socket_matches` entry. HA chaos: primary-EPP loss went from ~2400 live errors to 31. | llm-d/llm-d-router#3029 | PR open |
| 16 | chaos (engine kills) | Transport errors (connection refused/reset while an engine or proxy restarts) are fatal in llm-d-async: 21k of 36k batch requests failed in one chaos run. | Transport errors retry with backoff unless the request's own context ended; 4xx stays fatal. Chaos rerun: 0 batch failures. | 452 `33d370c` | pushed (supersedes #5, #10) |
| 15 | chaos run | nyann-bench aborts after 5 consecutive errors, hard-coded: the first chaos run ended at the first engine kill. | `--max-consecutive-errors` (negative never aborts). | nyann-bench fork `slo-bench` `9ddf3f8` | pushed |
| 14 | SLO sustained run (16 engines) | endpoint-scrape gate on EPP `queue_size{priority="-10"}` deadlocks: EPP garbage-collects an idle band's series, the gate reads "no samples", falls back closed, and batch never reaches EPP to recreate it (129k refusals, 0 dispatched in 10 min). | `absent_value` gate param: a successful scrape with no matching series reads as that value; a failed scrape still fails closed. | 452 `545cf5b` | pushed |
| 13 | waldorf deploy | #677's 0002_batch_events fails (42P07) on a database #676 already set up. | `IF NOT EXISTS` in 0002. | gateway `allpg-sim` `e57fa4a` | committed; bench upgraded cleanly |
| 12 | waldorf bench (r3, r8) | Queue tables vacuumed/analyzed while all-dead record reltuples=0 over nonzero relpages; planner then prices refilled table as empty. Result pop nested-looped the table (3 s/pop at 84k rows), dispatch and CancelledKeys scanned it. 14k -> 1.8k req/s for ~1 min after each drain. | Key-driven statements (ctid / seq = ANY / id = ANY); ordered picks moved into `async_dispatch` / `async_pop_results` SQL functions with `SET enable_seqscan/bitmapscan = off`. Test reads executed plans via auto_explain notices. | 452 `6cf121e`; vendored in gateway `allpg-sim` `107bca2` | pushed (452); bench r11-r14: 0 failures, first run after restart 8.2k req/s (was 1.8k), steady 14k |
| 11 | waldorf bench (r7) | Inference `http.Transport` `MaxIdleConns: 100` overrides per-host 1024; connections churn into TIME_WAIT, dispatcher exhausts ephemeral ports (`cannot assign requested address`). On main since #287. | `MaxIdleConns: totalConcurrency` | 452 `d3710c6` | pushed; verified r9/r10 0 failures at 14-16k req/s |
| 10 | waldorf bench (r8) | Reused keep-alive conn closed by engine -> `EOF` on POST, not retried (transport errors fatal). | See #16. | - | superseded by #16 |
| 9 | sim harness | Gateway schema created concurrently by components (42P07 race). | Use gateway PR #677 migrations; compose `migrate` one-shot; 0002_batch_events. | gateway `allpg-sim` `40ed9e5` | committed; sim 16 pass / 3 skip |
| 8 | waldorf bench | Gateway read async results one row per call (1k req/s ceiling). | Batched `GetResults` (256/read). | gateway `allpg-sim` `58c7e2a0f` | committed; 1k -> 3-4k req/s |
| 7 | sim harness | Gateway result poll gave up on an empty window while ctx live (latency). | Keep polling through empty windows. | gateway `allpg-sim` `7ee2fad` | committed |
| 6 | sim harness | Async error results lost custom_id (bug on upstream main since #581). | Fill custom_id/model/submitted_at from pending message. | gateway `allpg-sim` `c654dd6` | committed |
| 5 | sim harness | llm-d-async treats transport errors as fatal (engine resets fail requests). | See #16. | - | superseded by #16 |
| 4 | e2e deploy | dev-deploy loaded stale images (buildx without `--load`); composed deploy used Redis async values. | Makefile `BUILD_LOAD_FLAG`; sql values on install. | gateway `allpg-e2e` `5a89dc7` | committed |
| 3 | Veil model QuotaRateShared | Short-window rate gate deleted a long-window gate's log entries -> over-admit. | Per-(key, window) log. | 452 `c12076a` | pushed |
| 2 | Veil model QuotaSlots | Retried release after lost reply over-admits; lost acquire reply leaks a slot. | Holder retirement, no retries. | 452 `640b603` | pushed |
| 1 | quota bench | sqlqueue never configured database/sql pool (12k backends forked in 10 s). | `max_connections`, idle = open. | 452 `77d97e1` | pushed |

## Known, not fixed

- Active-passive EPP failback: a restarted primary takes traffic back without the standby's in-flight
  state (upstream ships only a no-op `local-syncer`), so live TTFT spikes for ~20-30 s (~1000 requests
  over SLO, once per primary restart). Adding engine-side utilization to the saturation signal did not
  fix it and cost steady-state SLO (98.2% vs 99.99%). Needs a real cross-replica syncer upstream.
  Accepted as a known limitation (2026-09-24): it fires only when the primary EPP restarts.
- Engines abort in-flight work on SIGTERM by default (vLLM and vcr `shutdown_timeout` 0): scaling
  engines down drops the requests running on them. An engine deployment setting.

- redis-quota has the same shared-window bug as #3 (held by Will).
- llm-d-async sql schema has no versioned migrations: Migrate's presence
  check skips `CREATE OR REPLACE` once the newest object exists, so changed
  function bodies never reach an existing database.
