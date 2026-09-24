"""Summarize one SLO run directory: live latency and SLO attainment, EPP flow-control
outcomes, and dispatcher counter deltas over the live window. Writes summary.json."""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

SLO_TTFT_MS = 500.0


def pct(values, p):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))]


def read_prom(path):
    series = {}
    if not path.exists():
        return series
    for line in path.read_text().splitlines():
        m = re.match(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)$", line)
        if m:
            series[m.group(1) + (m.group(2) or "")] = float(m.group(3))
    return series


def main(out: Path):
    live = [json.loads(line) for line in (out / "live.jsonl").read_text().splitlines() if line.strip()]
    window = int((out / "live-end").read_text()) - int((out / "live-start").read_text())
    ok = [r for r in live if r["status"] == "ok"]
    ttft = [r["ttft_ms"] for r in ok]
    itl = [x for r in ok for x in r["itls_ms"]]
    e2e = [r["latency_ms"] for r in ok]
    within = sum(1 for r in ok if r["ttft_ms"] <= SLO_TTFT_MS)
    summary = {
        "live_requests": len(live),
        "live_errors": len(live) - len(ok),
        "live_rps": round(len(live) / window, 1),
        "ttft_p50_ms": round(pct(ttft, 0.5)),
        "ttft_p90_ms": round(pct(ttft, 0.9)),
        "ttft_p99_ms": round(pct(ttft, 0.99)),
        "itl_p50_ms": round(pct(itl, 0.5), 1),
        "itl_p99_ms": round(pct(itl, 0.99), 1),
        "e2e_p50_ms": round(pct(e2e, 0.5)),
        "e2e_p99_ms": round(pct(e2e, 0.99)),
        "slo_attainment": round(within / len(live), 4) if live else None,
        "window_s": window,
    }

    start = min(r["t0"] for r in live)
    buckets = defaultdict(list)
    for r in ok:
        buckets[int((r["t0"] - start) // 20) * 20].append(r["ttft_ms"])
    summary["ttft_p99_by_20s"] = {f"{t}s": round(pct(v, 0.99)) for t, v in sorted(buckets.items())}

    before, after = read_prom(out / "epp-before.prom"), read_prom(out / "epp-after.prom")
    epp = defaultdict(float)
    for key, value in after.items():
        if key.startswith("llm_d_epp_flow_control_requests_total"):
            labels = dict(re.findall(r'(\w+)="([^"]*)"', key))
            epp[f"p{labels.get('priority')}/{labels.get('outcome')}"] += value - before.get(key, 0.0)
    summary["epp_requests"] = {k: int(v) for k, v in sorted(epp.items()) if v}
    summary["epp_queue_after"] = {
        re.search(r'priority="([^"]*)"', k).group(1): int(v)
        for k, v in after.items()
        if k.startswith("llm_d_epp_flow_control_queue_size") and v
    }

    before, after = read_prom(out / "dispatcher-before.prom"), read_prom(out / "dispatcher-after.prom")
    summary["dispatcher_deltas"] = {
        k: round(after[k] - before.get(k, 0.0), 1)
        for k in sorted(after)
        if ("_total" in k or k.endswith("_count")) and after[k] - before.get(k, 0.0) != 0
    }

    samples = out / "samples.log"
    if samples.exists():
        ticks, cur = [], None
        for line in samples.read_text().splitlines():
            if line.startswith("T "):
                cur = defaultdict(float)
                ticks.append(cur)
            elif cur is not None:
                m = re.search(r"(\S+)\{([^}]*)\} (\S+)$", line)
                if not m:
                    continue
                name, labels, value = m.group(1).split()[-1], dict(re.findall(r'(\w+)="([^"]*)"', m.group(2))), float(m.group(3))
                if name == "llm_d_epp_flow_control_pool_saturation" and labels.get("stage") == "effective":
                    cur["saturation"] = value
                elif name == "llm_d_epp_flow_control_queue_size":
                    cur[f"epp_queue_p{labels.get('priority')}"] += value
                elif name in ("vllm:num_requests_running", "vllm:num_requests_waiting"):
                    cur["engine_" + name.split("_")[-1]] += value
        keys = sorted({k for t in ticks for k in t})
        summary["samples"] = {
            k: {"mean": round(sum(t.get(k, 0.0) for t in ticks) / len(ticks), 2), "max": max(t.get(k, 0.0) for t in ticks)}
            for k in keys
        } if ticks else {}

    driver = out / "driver.log"
    if driver.exists():
        last = [l for l in driver.read_text().splitlines() if l.startswith("SAMPLE")]
        if last:
            m = re.search(r"done=(\d+)/(\d+).*failed=(\d+)", last[-1])
            if m:
                summary["batch_done"], summary["batch_total"], summary["batch_failed"] = map(int, m.groups())
    chaos = out / "chaos.log"
    if chaos.exists():
        start = int((out / "live-start").read_text())
        summary["chaos"] = [f"+{int(l.split()[0]) - start}s {' '.join(l.split()[1:])}" for l in chaos.read_text().splitlines()]

    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
