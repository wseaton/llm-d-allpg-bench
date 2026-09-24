"""Build writeup.html (figures inlined) for upload to Google Docs.

usage: python3 build_doc.py
"""

import base64
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXES = HERE.parent.parent / "FIXES.md"
QUOTA_DIAGRAM = HERE / "09-quota.png"


def img(path, caption, width=640):
    data = base64.b64encode(Path(path).read_bytes()).decode()
    return f'<p><img src="data:image/png;base64,{data}" width="{width}"></p><p><i>{caption}</i></p>'


def table(header, rows):
    head = "".join(f"<th>{h}</th>" for h in header)
    body = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<table border="1" cellpadding="4" style="border-collapse:collapse"><tr>{head}</tr>{body}</table>'


def link(url, text):
    return f'<a href="{url}">{text}</a>'


PR452 = link("https://github.com/llm-d/llm-d-async/pull/452", "llm-d-async #452")
PR3029 = link("https://github.com/llm-d/llm-d-router/pull/3029", "llm-d-router #3029")
GW676 = link("https://github.com/llm-d/llm-d-batch-gateway/pull/676", "batch-gateway #676")
GW677 = link("https://github.com/llm-d/llm-d-batch-gateway/pull/677", "batch-gateway #677")
GW653 = link("https://github.com/llm-d/llm-d-batch-gateway/pull/653", "batch-gateway #653")
FORMAL = link("https://github.com/wseaton/llm-d-async-formal", "llm-d-async-formal")
KIT_URL = "https://github.com/wseaton/llm-d-allpg-bench"
KIT = link(KIT_URL, "wseaton/llm-d-allpg-bench")
RESULTS = link(f"{KIT_URL}/blob/main/slo/RESULTS.md", "RESULTS.md")
FIXES_LINK = link(f"{KIT_URL}/blob/main/FIXES.md", "FIXES.md")
ROUTER_SHA = "8c043cadb7aa09890a5d84e7653ecd051471ccee"
ROUTER_SRC = lambda path, text: link(f"https://github.com/llm-d/llm-d-router/blob/{ROUTER_SHA}/{path}", text)
HOLDBACK = ROUTER_SRC("pkg/epp/framework/plugins/flowcontrol/usagelimits/priorityholdback/README.md", "priority-holdback")
FLOWCONTROL = ROUTER_SRC("pkg/epp/flowcontrol/README.md", "flow control")
OBJECTIVE = ROUTER_SRC("apix/v1alpha2/inferenceobjective_types.go", "InferenceObjective")
LOCAL_SYNCER = ROUTER_SRC("pkg/epp/framework/plugins/datalayer/cross_plugin/local/README.md", "local-syncer")
HEALTH_PORT = ROUTER_SRC("pkg/epp/server/options.go#L235", "--grpc-health-port")
NYANN = link("https://github.com/wseaton/nyann-bench/tree/slo-bench", "nyann-bench")
VCR = link("https://github.com/neuralmagic/vllm-vcr", "vllm-vcr")
VLLM_SHUTDOWN = link("https://github.com/vllm-project/vllm/pull/34730", "vLLM #34730")
ENVOY_DRAIN = link("https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining", "Envoy draining")
ENVOY_PROTO = link("https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/core/v3/protocol.proto#config-core-v3-httpprotocoloptions", "HttpProtocolOptions")
ENVOY_DELAYED = link("https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto", "delayed_close_timeout")
GO_RETRY = link("https://pkg.go.dev/net/http#Transport", "net/http Transport")
EG_SHUTDOWN = link("https://gateway.envoyproxy.io/docs/tasks/operations/graceful-shutdown/", "Envoy Gateway graceful shutdown")
PG_CLASS = link("https://www.postgresql.org/docs/current/catalog-pg-class.html", "reltuples")
PG_ESTIMATE = link("https://www.postgresql.org/docs/current/row-estimation-examples.html", "planner")
AUTO_EXPLAIN = link("https://www.postgresql.org/docs/current/auto-explain.html", "auto_explain")
VEIL = link("https://github.com/verse-lab/veil", "Veil")
GW_BRANCH = link("https://github.com/wseaton/llm-d-batch-gateway/tree/allpg-sim", "allpg-sim")


def runs(*names):
    return ", ".join(link(f"{KIT_URL}/tree/main/slo/runs/{n}", n) for n in names)
F = lambda n: HERE / n

sections = []
sections.append(f"""
<h1>All-Postgres llm-d batch stack: throughput, live SLO preservation, failure handling</h1>
<p>Will Eaton, 2026-09-24. Waldorf (CoreWeave), namespace allpg-bench. Kit, configs and run summaries: {KIT}.</p>

<h2>Summary</h2>
<ul>
<li>The batch gateway ({GW676}, {GW677}) and llm-d-async's sql transport ({PR452}) run on one Postgres with no Redis. The Kind e2e suite passes (67 specs); the fault-injection harness ({GW653}) passes 16 scenarios, with 3 that need Kind skipped.</li>
<li>Batch throughput through gateway, Postgres and dispatcher went from 1.0k to 14-16k requests/s; three fixes found under load remove the collapses that took it back to 1.8-5.8k.</li>
<li>Live traffic keeps its SLO next to batch only with llm-d router {FLOWCONTROL}, {OBJECTIVE} priorities and the {HOLDBACK} usage limit. Priority ordering alone, or a dispatcher-side gate alone, does not hold it.</li>
<li>At 94% of pool capacity on 16 engines, 99.97-99.99% of live requests meet a 500 ms TTFT SLO across three 10-minute trials (p99 362-370 ms), near capacity and through a 50% live surge.</li>
<li>With engines, the primary EPP, a proxy and the dispatcher killed in one run, batch loses nothing and 97.95% of live requests meet the SLO.</li>
<li>Fixes: {PR452} (pushed) and {PR3029} (draft while its proxy drain is reworked; see fix 20). Accepted limitation: a restarted primary EPP causes ~20 s of live requests over the SLO.</li>
</ul>

<h2>Setup</h2>
<ul>
<li>Batch path: batch gateway apiserver and processor (branch {GW_BRANCH}), Postgres (one pod, 8 cores), llm-d-async dispatcher with the sql transport (partition leases, 1024-2048 workers).</li>
<li>Inference: {VCR} engines behind the llm-d router (standalone chart, active-passive EPP with priority routing, two Envoy proxies). Each engine runs at most 64 sequences; excess waits in the engine queue. TTFT 60 ms, ITL 20 ms, latency scaling linearly to 3x at a full batch.</li>
<li>Traffic classes: InferenceObjective <code>live</code> (priority 100) and <code>batch</code> (priority -10). llm-d-async stamps <code>x-llm-d-inference-objective</code> per queue; live traffic comes from {NYANN} (Poisson arrivals, 256 in / 128 out) with a new <code>headers</code> option.</li>
<li>SLO: live TTFT at most 500 ms. Attainment is the share of live requests meeting it.</li>
</ul>
""")

sections.append(f"""
<h2>Batch throughput</h2>
<p>200k requests per run, 64-token prompts, 4 engines with no latency, so the batch path itself is the bottleneck.</p>
{img(F("01-throughput.png"), f"Figure 1. End-to-end batch requests/s per bench run. Data: {link(KIT_URL + '/tree/main/runs', 'runs/sat-64-r*')}.")}
<ul>
<li><b>Batched result reads</b> (runs 2-3): the gateway popped async results one call at a time; reading in batches of 256 took 1.0k to 3.8k requests/s.</li>
<li><b>Idle connection pool</b> (run 7): the dispatcher's HTTP transport capped idle connections at 100 for 1024 workers, so connections churned into TIME_WAIT until ephemeral ports ran out and 767 requests failed. Fixed in {PR452}.</li>
<li><b>Estimate-proof query plans</b> (runs 3 and 8): a queue table vacuumed while all-dead records {PG_CLASS} = 0, and the {PG_ESTIMATE} then walks the whole table per pop or dispatch (3 s per pop at 84k rows). Statements now reach rows by key, and the ordered picks run in SQL functions with seq and bitmap scans off. A test reads each statement's executed plan through {AUTO_EXPLAIN}. Fixed in {PR452}.</li>
</ul>
""")

sections.append(f"""
<h2>Live SLO next to batch</h2>
{img(F("02-capacity.png"), f"Figure 2. Live traffic alone: the 4-engine pool saturates at ~32 req/s, the 16-engine pool at ~130 req/s. Data: live-only sweeps in {RESULTS}.")}
<p>With 4 engines, live at 16 req/s (half of capacity) and 6000 batch requests:</p>
{img(F("03-scenarios.png"), f"Figure 3. Which mechanism protects live traffic. Data: {runs('slo-A1', 'slo-B1', 'slo-C1', 'slo-D1', 'slo-E1', 'slo-F1')}.")}
<ul>
<li>Batch sent straight to the engines takes the pool; live TTFT reaches a minute.</li>
<li>Flow control with objectives orders EPP's queue by priority, but EPP keeps every engine full, so a live request waits for a running request to finish, three times slower at a full batch.</li>
<li>A dispatcher gate on pool saturation cannot create headroom either: batch already buffered in EPP refills every free slot.</li>
<li>priority-holdback holds batch in EPP once pool saturation passes the batch ceiling. Live never queues and its p99 stays within 90 ms of the live-only baseline.</li>
</ul>
{img(F("04-holdback.png"), f"Figure 4. The holdback ceiling trades batch throughput for live latency. 0.8 is the knee: p99 301 ms at 87% of unprotected batch throughput; 0.9 breaks the SLO. Data: {runs('slo-E1', 'slo-E-c07', 'slo-E-c08', 'slo-E-c09')}.")}
""")

sections.append(f"""
<h2>High RPS: 16 engines</h2>
<p>Holdback ceiling 0.8. Live 80 req/s plus ~45 req/s of batch is 94% of pool capacity.</p>
{img(F("05-timeline.png"), f"Figure 5. Live TTFT p99 per 20 s: a 10-minute sustained trial, and a run with a second 40 req/s live stream added for 128 s. Data: {runs('slo-S16-t1', 'slo-BU16')}.")}
<p>Data: {runs("slo-S16-t1", "slo-S16-t2", "slo-S16-t3", "slo-NC16", "slo-BU16", "slo-HA-S16", "slo-OL16")}.</p>
{table(["Run", "Live offered (req/s)", "TTFT p50 / p99", "SLO met", "Batch req/s", "Batch failed"], [
    ["Sustained, trial 1 (10 min)", "80", "239 / 364 ms", "99.99%", "44.3", "0"],
    ["Sustained, trial 2", "80", "237 / 362 ms", "99.99%", "44.5", "0"],
    ["Sustained, trial 3", "80", "239 / 363 ms", "99.98%", "44.9", "0"],
    ["Near capacity (5 min)", "110", "237 / 336 ms", "99.99%", "19.1", "0"],
    ["Surge (+40 for 128 s)", "80 -> 120", "238 / 357 ms", "99.98%", "35.9", "0"],
    ["Active-passive router (10 min)", "80", "238 / 372 ms", "99.97%", "44.8", "0"],
    ["Overload", "150", "6.6 / 13.2 s", "4%", "4.8", "0"],
])}
<p>Batch yields as live grows (44 to 19 req/s near capacity). Offered live load above pool capacity cannot meet any SLO; there live latency matches a live-only overload.</p>
""")

sections.append(f"""
<h2>Dispatcher admission</h2>
<p>The dispatcher gates batch on the depth of EPP's batch queue. Sizing that buffer from the pool (8 slots per ready engine, read from <code>llm_d_epp_ready_endpoints</code>) removes the hand-set limits, but exposed an overshoot: the gate admits every request while one cached reading is open, so the queue ran to ~1900 against a 64-slot target and 4627 batch requests expired in EPP and were retried.</p>
{img(F("06-queue.png"), f"Figure 6. EPP batch queue depth, 8 engines. Counted admission grants each reading's free slots and no more. Data: {runs('slo-DYN-8', 'slo-CNT-8')}.")}
<p>With <code>admission: counted</code> (in {PR452}) the queue holds at its target, nothing expires, and batch throughput is unchanged (22.8 vs 22.4 req/s). The same config held the SLO at 8 and 16 engines and through a 16 to 10 engine scale-down mid-run.</p>
""")

sections.append(f"""
<h2>Failure handling</h2>
{img(F("08-fixes.png"), f"Figure 7. Before and after each fix, measured under load. Data: {FIXES_LINK}.")}
<ul>
<li><b>Transport-error retries</b> ({PR452}): connection refused or reset while an engine or proxy restarted was fatal, failing 21,013 of 36,000 batch requests in one chaos run. They now retry with backoff; 4xx stays fatal.</li>
<li><b>EPP health port</b> ({PR3029}): Envoy health-checked EPP on the ext_proc port, whose health service stays SERVING through graceful shutdown while ext_proc rejects with "flow controller shutting down". Probing {HEALTH_PORT} fails over in ~2 s.</li>
<li><b>Proxy drain</b> ({PR3029}): Envoy exits on SIGTERM; it drains only when told to through its admin API ({ENVOY_DRAIN}), which is why {EG_SHUTDOWN} runs a sidecar for it. The proxy now sleeps 25 s in preStop so in-flight streams finish before the signal. The first version closed client connections with HCM <code>max_connection_duration</code> (10 s, {ENVOY_PROTO}); on real vLLM at 150 req/s that reset 219 of 8601 live requests on one proxy, because the limit fires on every connection, and when it expires after a streamed response's headers are out, Envoy closes without <code>Connection: close</code>. Go reuses the pooled connection, and the next POST sits unread through Envoy's 1 s {ENVOY_DELAYED}, then gets an RST. Go does not retry it: the {GO_RETRY} retries only idempotent requests. HCM <code>max_requests_per_connection: 1</code> puts <code>Connection: close</code> on each response instead: 0 errors on the same probe, and 0 live errors with both proxies killed under 80 req/s of real vLLM (Qwen3-32B, 8 x H200; {runs("vllm-PX-mrpc")}).</li>
</ul>
{img(F("07-chaos.png"), f"Figure 8. Every failure in one 10-minute run at 80 req/s live plus batch, all fixes in place. Failed requests are attributed to their start time. Data: {runs('slo-ALL')}.")}
{table(["Failure", "Live errors", "Notes"], [
    ["2 engines killed", "50", "requests running on those engines; engines abort in-flight work on SIGTERM"],
    ["Primary EPP killed", "19", "failover to the standby in ~2 s"],
    ["Primary EPP failback (~40 s later)", "0", "~900 requests over SLO for ~20 s"],
    ["Proxy killed", "1", "connections drained first"],
    ["Dispatcher killed", "0", ""],
    ["Run total", "70 of 46.9k", "SLO 97.95%; batch 0 failed, 0 expired"],
])}
""")

sections.append(f"""
<h2>Quota gate correctness</h2>
<p>{PR452} adds a Postgres-backed <code>sql-quota</code> gate with exact global limits (concurrency slots per heartbeated holder, sliding-log rate limits). {VEIL} (Lean 4) models in {FORMAL} found three bugs before load testing:</p>
{img(QUOTA_DIAGRAM, "Figure 9. A release retried after a lost reply subtracts twice: three requests run under a limit of two.", width=560)}
<ul>
<li>A retried release after a lost reply over-admits; a lost acquire reply leaks a slot. Fixed by holder retirement: any statement error retires the holder instead of retrying. <code>QuotaRetire</code> proves 21 invariants inductive.</li>
<li>A short-window rate gate deleted a long-window gate's log entries. Fixed with a log per (key, window); <code>QuotaRateWindowed</code> proves it.</li>
<li>Throughput (laptop): ~100k quota operations/s at 64 keys with per-key group commit, well above realistic dispatch rates.</li>
</ul>
""")

COMMIT_REPOS = [
    (r"^452 `(\w+)`", "wseaton/llm-d-async", f"{PR452} "),
    (r"^gateway `[\w-]+` `(\w+)`", "wseaton/llm-d-batch-gateway", "gateway "),
    (r"^nyann-bench fork `slo-bench` `(\w+)`", "wseaton/nyann-bench", "nyann-bench "),
    (r"^llm-d/llm-d-router#3029 `(\w+)`", "wseaton/llm-d-router", f"{PR3029} "),
]


def where_cell(text):
    for pattern, repo, prefix in COMMIT_REPOS:
        m = re.match(pattern, text)
        if m:
            sha = m.group(1)
            return prefix + link(f"https://github.com/{repo}/commit/{sha}", sha) + md_inline(text[m.end():])
    return md_inline(text)


def md_inline(text):
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = text.replace("llm-d/llm-d-router#3029", PR3029)
    return re.sub(r"^452 ", f"{PR452} ", text)


def fixes_log():
    rows, known, section = [], [], None
    for line in FIXES.read_text().splitlines():
        if line.startswith("## "):
            section = line[3:]
        elif section is None and re.match(r"^\| \d+ \|", line):
            cells = [c.strip() for c in line.strip("|").split(" | ")]
            rows.append([md_inline(c) for c in cells[:4]] + [where_cell(cells[4])] + [md_inline(c) for c in cells[5:]])
        elif section and line.startswith("- "):
            known.append(line[2:])
        elif section and known and line.startswith("  "):
            known[-1] += " " + line.strip()
    return rows, [md_inline(k) for k in known]


FIX_ROWS, KNOWN = fixes_log()
sections.append(f"""
<h2>Fixes log</h2>
<p>Every bug the all-Postgres e2e, the sim harness, the waldorf bench and the Veil models found, newest first. Kept in <code>FIXES.md</code> in the bench kit.</p>
{table(["#", "Found by", "Bug", "Fix", "Where", "Status"], FIX_ROWS)}
<p><b>Known, not fixed</b></p>
<ul>{"".join(f"<li>{k}</li>" for k in KNOWN)}</ul>
""")

sections.append(f"""
<h2>Changes and where they live</h2>
{table(["Change", "Where", "State"], [
    ["sql transport, sql-quota, pool fix, estimate-proof plans, idle-pool fix", PR452, "open"],
    ["endpoint-scrape absent_value, transport-error retries, counted admission", PR452, "open"],
    ["EPP drain-aware health checks, proxy drain", PR3029, "draft (drain reworked)"],
    ["Postgres control plane, schema migrations", f"{GW676}, {GW677}", "open (not ours)"],
    ["Migration 0002 adopts a #676-created batch_events; custom_id kept on async errors; batched result reads", "local gateway integration branch", "local"],
    ["nyann-bench: headers option, per-stage rates, configurable error abort", "wseaton/nyann-bench branches", "pushed"],
])}
""")

sections.append("""
<h2>Before production</h2>
<ul>
<li>Merge the two PRs.</li>
<li>priority-holdback is alpha and needs <code>--allow-experimental-plugins</code>.</li>
<li>Accepted limitation: a restarted primary EPP takes traffic back without the standby's in-flight state (the router has no cross-replica syncer beyond the no-op {LOCAL_SYNCER}), costing ~20 s of live TTFT above SLO once per primary restart. Adding engine utilization to the saturation signal did not help and cost steady-state SLO (98.2%).</li>
<li>Engine deployments need a shutdown timeout: vLLM (and vcr) abort in-flight work on SIGTERM by default (<code>--shutdown-timeout</code>, {VLLM_SHUTDOWN}), so scaling engines down drops what runs on them.</li>
</ul>

<h2>Reproducing</h2>
<p>Kit: {KIT} (see its README for the branches, image builds and cluster variables); every table is in {RESULTS} and every fix in {FIXES_LINK}. Per-request data is not published. <code>slo/run.sh NAME SCENARIO LIVE_RATE LIVE_SECONDS BATCH_REQUESTS</code> runs one scenario (holds a lock so runs never overlap); <code>chaos-all.sh</code>, <code>chaos-proxy.sh</code>, <code>burst.sh</code> inject failures and surges; <code>RESULTS.md</code> has every table; <code>figures/make_figures.py</code> redraws these figures from the run data.</p>
""")

sections.append(f"""
<h2>References</h2>
<ul>
<li>Bench kit and run summaries: {KIT}. Results: {RESULTS}. Fixes: {FIXES_LINK}.</li>
<li>Code: {PR452}, {PR3029}, {GW676}, {GW677}, gateway integration branch {GW_BRANCH}, {NYANN} (<code>slo-bench</code>), {FORMAL}.</li>
<li>llm-d router: {FLOWCONTROL}, {OBJECTIVE}, {HOLDBACK}, {LOCAL_SYNCER}, {HEALTH_PORT}.</li>
<li>Envoy: {ENVOY_DRAIN}, {ENVOY_PROTO} (<code>max_connection_duration</code>, <code>max_requests_per_connection</code>), {ENVOY_DELAYED}, {EG_SHUTDOWN}.</li>
<li>Go: {GO_RETRY} (retries only idempotent requests on a reused connection).</li>
<li>vLLM: {VLLM_SHUTDOWN} (<code>--shutdown-timeout</code>); engines {VCR}.</li>
<li>Postgres: {PG_CLASS}, {PG_ESTIMATE}, {AUTO_EXPLAIN}. Formal methods: {VEIL}.</li>
</ul>
""")

html = "<html><head><meta charset='utf-8'></head><body>" + "".join(sections) + "</body></html>"
(HERE / "writeup.html").write_text(html)
print("wrote", HERE / "writeup.html", len(html) // 1024, "KiB")
