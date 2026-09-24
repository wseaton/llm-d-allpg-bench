"""Render the write-up figures from the run data under ../runs and ../../runs.

usage: uv run --with matplotlib python3 make_figures.py
"""

import json
import re
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

HERE = Path(__file__).resolve().parent
SLO_RUNS = HERE.parent / "runs"
BENCH_RUNS = HERE.parent.parent / "runs"
SWEEPS = SLO_RUNS / "sweeps"
SLO_MS = 500

for font in [Path.home() / "Library/Fonts/TX-02-Regular.otf", Path.home() / "Documents/fonts/Archive/TX-02-Bold.otf"]:
    if font.exists():
        font_manager.fontManager.addfont(str(font))
if any(f.name == "TX-02" for f in font_manager.fontManager.ttflist):
    plt.rcParams["font.family"] = "TX-02"
plt.rcParams.update({"figure.dpi": 150, "axes.spines.top": False, "axes.spines.right": False, "font.size": 9})

LIVE, BATCH, BAD, NEUTRAL = "#2b6cb0", "#dd8a2e", "#c53030", "#718096"


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))] if values else float("nan")


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def summary(run):
    return json.loads((SLO_RUNS / run / "summary.json").read_text())


def samples(run):
    """Per-tick EPP and engine readings from a run's samples.log."""
    ticks, cur = [], None
    for line in (SLO_RUNS / run / "samples.log").read_text().splitlines():
        if line.startswith("T "):
            cur = defaultdict(float, t=int(line.split()[1]))
            ticks.append(cur)
            continue
        m = re.search(r"(\S+)\{([^}]*)\} (\S+)$", line)
        if not m or cur is None:
            continue
        name, labels, value = m.group(1).split()[-1], dict(re.findall(r'(\w+)="([^"]*)"', m.group(2))), float(m.group(3))
        if name.endswith("pool_saturation") and labels.get("stage") == "effective":
            cur["saturation"] = value
        elif name.endswith("queue_size"):
            cur["q" + labels.get("priority", "")] += value
        elif name == "vllm:num_requests_running":
            cur["running"] += value
    return ticks


def save(fig, name):
    fig.tight_layout()
    fig.savefig(HERE / f"{name}.png", bbox_inches="tight")
    plt.close(fig)


def fig_throughput():
    runs = []
    for i in range(1, 15):
        log = BENCH_RUNS / f"sat-64-r{i}" / "driver.log"
        m = re.search(r"e2e_rps=([0-9.]+).*failed=(\d+)", log.read_text())
        if m is None:
            raise ValueError(f"no RESULT line in {log}")
        runs.append((i, float(m.group(1)), int(m.group(2))))
    phases = [
        (1, 1, "baseline"), (2, 3, "batched result reads"), (4, 6, "same code, fresh stats"),
        (7, 7, "port exhaustion"), (8, 8, "stale plans"), (9, 10, "idle-pool fix"), (11, 14, "estimate-proof plans"),
    ]
    fig, ax = plt.subplots(figsize=(8, 3.4))
    colors = [BAD if f or r in (7, 8) else LIVE for r, _, f in runs]
    ax.bar([r for r, _, _ in runs], [v / 1000 for _, v, _ in runs], color=colors)
    for r, v, f in runs:
        if f:
            ax.annotate(f"{f} failed", (r, v / 1000), ha="center", va="bottom", fontsize=7, color=BAD)
    for n, (lo, hi, label) in enumerate(phases):
        y = 19.4 if n % 2 == 0 else 17.9
        ax.plot([lo - 0.35, hi + 0.35], [y - 0.35, y - 0.35], color=NEUTRAL, lw=0.8)
        ax.annotate(label, ((lo + hi) / 2, y), ha="center", fontsize=7, color=NEUTRAL)
    ax.set_ylim(0, 20.5)
    ax.set_xticks(range(1, 15))
    ax.set_xlabel("bench run (200k requests, 64-token prompts)")
    ax.set_ylabel("end-to-end k req/s")
    ax.set_title("Batch throughput through gateway + Postgres + dispatcher")
    save(fig, "01-throughput")


def stage_points(path):
    rs = sorted(records(path), key=lambda r: r["t0"])
    t = [r["t0"] for r in rs]
    bounds = [0] + [i for i in range(1, len(t)) if t[i] - t[i - 1] > 1.0] + [len(t)]
    out = []
    for a, b in zip(bounds, bounds[1:]):
        g = rs[a:b]
        ok = [r["ttft_ms"] for r in g if r["status"] == "ok"]
        out.append((len(g) / (g[-1]["t0"] - g[0]["t0"]), pct(ok, 0.99)))
    return out


def fig_capacity():
    fig, ax = plt.subplots(figsize=(6.5, 3.4))
    for name, path, color in [("4 engines", SWEEPS / "sweep2.jsonl", NEUTRAL), ("16 engines", SWEEPS / "sweep16.jsonl", LIVE)]:
        pts = stage_points(path)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], "o-", color=color, label=name)
    ax.axhline(SLO_MS, color=BAD, ls="--", lw=1)
    ax.annotate("SLO 500 ms", (2, SLO_MS * 1.15), color=BAD, fontsize=7)
    ax.set_yscale("log")
    ax.set_xlabel("live requests/s offered (no batch)")
    ax.set_ylabel("TTFT p99 (ms, log)")
    ax.set_title("Pool capacity: live traffic alone")
    ax.legend(frameon=False)
    save(fig, "02-capacity")


def fig_scenarios():
    rows = [
        ("A1", "live only"), ("B1", "batch bypasses router"), ("C1", "flow control + objectives"),
        ("D1", "+ dispatcher saturation gate"), ("E1", "+ priority-holdback 0.6"), ("F1", "+ EPP queue-depth gate"),
    ]
    data = [(label, summary(f"slo-{run}")) for run, label in rows]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9, 3.2), gridspec_kw={"width_ratios": [3, 2]})
    y = range(len(data))
    ax1.barh(y, [d["ttft_p99_ms"] for _, d in data], color=[LIVE if d["ttft_p99_ms"] <= SLO_MS else BAD for _, d in data])
    ax1.axvline(SLO_MS, color=BAD, ls="--", lw=1)
    ax1.set_xscale("log")
    ax1.set_yticks(list(y), [label for label, _ in data])
    ax1.invert_yaxis()
    ax1.set_xlabel("live TTFT p99 (ms, log)")
    ax1.set_title("4 engines, 16 req/s live + batch")
    ax2.barh(y, [100 * d["slo_attainment"] for _, d in data], color=[LIVE if d["slo_attainment"] >= 0.99 else BAD for _, d in data])
    ax2.set_yticks([])
    ax2.invert_yaxis()
    ax2.set_xlim(0, 100)
    ax2.set_xlabel("live requests within SLO (%)")
    save(fig, "03-scenarios")


def fig_holdback():
    rows = [("0.6", "slo-E1"), ("0.7", "slo-E-c07"), ("0.8", "slo-E-c08"), ("0.9", "slo-E-c09")]
    p99, batch = [], []
    for _, run in rows:
        d = summary(run)
        p99.append(d["ttft_p99_ms"])
        batch.append(d["epp_requests"].get("p-10/Dispatched", 0) / d["window_s"])
    fig, ax = plt.subplots(figsize=(5.5, 3.2))
    x = [float(c) for c, _ in rows]
    ax.plot(x, p99, "o-", color=LIVE, label="live TTFT p99")
    ax.axhline(SLO_MS, color=BAD, ls="--", lw=1)
    ax.set_xlabel("priority-holdback ceiling for batch")
    ax.set_ylabel("live TTFT p99 (ms)", color=LIVE)
    ax2 = ax.twinx()
    ax2.plot(x, batch, "s--", color=BATCH, label="batch req/s")
    ax2.set_ylabel("batch req/s", color=BATCH)
    ax2.spines["right"].set_visible(True)
    ax.set_title("Holdback ceiling trade-off (4 engines)")
    save(fig, "04-holdback")


def ttft_series(run, file="live.jsonl", bucket=20):
    start = int((SLO_RUNS / run / "live-start").read_text())
    by = defaultdict(list)
    for r in records(SLO_RUNS / run / file):
        if r["status"] == "ok":
            by[int((r["t0"] - start) // bucket) * bucket].append(r["ttft_ms"])
    xs = sorted(by)
    return xs, [pct(by[x], 0.99) for x in xs], start


def fig_timeline():
    fig, ax = plt.subplots(figsize=(8, 3.2))
    for run, label, color in [("slo-S16-t1", "sustained, 80 req/s", LIVE), ("slo-BU16", "80 req/s + 40 req/s surge", BATCH)]:
        xs, ys, _ = ttft_series(run)
        ax.plot(xs, ys, "-", color=color, label=label)
    lo, hi = [int(v) - int((SLO_RUNS / "slo-BU16" / "live-start").read_text()) for v in (SLO_RUNS / "slo-BU16" / "burst-window").read_text().split()]
    ax.axvspan(lo, hi, color=BATCH, alpha=0.12, lw=0)
    ax.annotate("surge", ((lo + hi) / 2, 60), ha="center", color=BATCH, fontsize=8)
    ax.axhline(SLO_MS, color=BAD, ls="--", lw=1)
    ax.set_ylim(0, 560)
    ax.set_xlabel("seconds into the run")
    ax.set_ylabel("live TTFT p99 per 20 s (ms)")
    ax.set_title("16 engines at 94% of capacity: live + batch")
    ax.legend(frameon=False, loc="lower right")
    save(fig, "05-timeline")


def fig_queue():
    fig, ax = plt.subplots(figsize=(8, 3.2))
    for run, label, color in [("slo-DYN-8", "budget admission", BAD), ("slo-CNT-8", "counted admission", LIVE)]:
        ticks = samples(run)
        t0 = ticks[0]["t"]
        ax.plot([t["t"] - t0 for t in ticks], [t["q-10"] for t in ticks], color=color, lw=1, label=label)
    ax.axhline(64, color=NEUTRAL, ls="--", lw=1)
    ax.annotate("counted: held at the 64-slot target (8 slots x 8 engines)", (300, 160), color=LIVE, fontsize=7, ha="center")
    ax.set_ylim(0, 2300)
    ax.set_xlabel("seconds into the run")
    ax.set_ylabel("batch requests queued in EPP")
    ax.set_title("Dispatcher overshoot: EPP batch queue, 8 engines")
    ax.legend(frameon=False, loc="upper center", ncol=2)
    save(fig, "06-queue")


def fig_chaos():
    run = "slo-ALL"
    start = int((SLO_RUNS / run / "live-start").read_text())
    err, slow, tot = defaultdict(int), defaultdict(int), defaultdict(int)
    for r in records(SLO_RUNS / run / "live.jsonl"):
        b = int((r["t0"] - start) // 10) * 10
        tot[b] += 1
        if r["status"] != "ok":
            err[b] += 1
        elif r["ttft_ms"] > SLO_MS:
            slow[b] += 1
    xs = sorted(tot)
    fig, ax = plt.subplots(figsize=(8, 3.2))
    ax.bar(xs, [slow[x] for x in xs], width=9, color=BATCH, label="over SLO")
    ax.bar(xs, [err[x] for x in xs], width=9, bottom=[slow[x] for x in xs], color=BAD, label="failed")
    for line in (SLO_RUNS / run / "chaos.log").read_text().splitlines():
        t, what = line.split(maxsplit=1)
        at = int(t) - start
        ax.axvline(at, color=NEUTRAL, ls=":", lw=1)
        ax.annotate(what.replace("delete ", "kill "), (at + 3, 640), fontsize=7, color=NEUTRAL, rotation=90, va="top")
    ax.annotate("failback to\nrestarted\nprimary", (270, 470), fontsize=6.5, color=BATCH)
    ax.set_ylim(0, 650)
    ax.set_xlabel("seconds into the run (80 req/s live, ~800 per 10 s)")
    ax.set_ylabel("live requests per 10 s")
    ax.set_title("Every failure in one run, all fixes in place")
    ax.legend(frameon=False, loc="upper right", bbox_to_anchor=(1, 0.8))
    save(fig, "07-chaos")


def fig_fixes():
    rows = [
        ("batch failed, chaos run\n(transport retries)", 21013, 0),
        ("live errors, primary EPP loss\n(health port 9003)", 2291, 31),
        ("live errors, 2 proxy restarts\n(connection drain)", 626, 1),
        ("batch expired in EPP, 8 engines\n(counted admission)", 4627, 0),
        ("live resets, 150 req/s, one proxy\n(close per request, not by age)", 219, 0),
    ]
    fig, ax = plt.subplots(figsize=(8, 3.6))
    y = range(len(rows))
    ax.barh([i - 0.2 for i in y], [r[1] for r in rows], height=0.4, color=BAD, label="before")
    ax.barh([i + 0.2 for i in y], [max(r[2], 0.8) for r in rows], height=0.4, color=LIVE, label="after")
    for i, r in enumerate(rows):
        ax.annotate(f"{r[1]:,}", (r[1] * 1.1, i - 0.2), va="center", fontsize=7)
        ax.annotate(f"{r[2]:,}", (max(r[2], 0.8) * 1.3, i + 0.2), va="center", fontsize=7)
    ax.set_xscale("log")
    ax.set_xlim(0.5, 120000)
    ax.set_yticks(list(y), [r[0] for r in rows])
    ax.invert_yaxis()
    ax.set_xlabel("count (log)")
    ax.set_title("What each fix changed")
    ax.legend(frameon=False, loc="lower right")
    save(fig, "08-fixes")


if __name__ == "__main__":
    for f in [fig_throughput, fig_capacity, fig_scenarios, fig_holdback, fig_timeline, fig_queue, fig_chaos, fig_fixes]:
        try:
            f()
            print("wrote", f.__name__)
        except FileNotFoundError as e:
            print("skipped", f.__name__, "(raw run data not present:", e.filename + ")")
