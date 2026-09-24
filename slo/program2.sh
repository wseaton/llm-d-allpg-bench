#!/usr/bin/env bash
# Second high-RPS program: chaos measured through every failure, then near-capacity, sustained
# and burst with the EPP batch buffer sized to gate lag (dispatcher-router-bounded16b).
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program2.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "itl_p50_ms", "batch_done", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
./slo/chaos.sh slo-CH16b & ./slo/run.sh slo-CH16b router-bounded16b 80 600 36000 && summ slo-CH16b; wait
./slo/run.sh slo-NC16b router-bounded16b 110 300 21000 && summ slo-NC16b
./slo/run.sh slo-S16b router-bounded16b 80 600 36000 && summ slo-S16b
./slo/burst.sh slo-BU16b 40 180 120 & ./slo/run.sh slo-BU16b router-bounded16b 80 480 30000 && summ slo-BU16b; wait
echo done >> "$D/runs/program2.log"
