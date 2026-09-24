#!/usr/bin/env bash
# High-RPS program on the 16-engine pool, strictly sequential. Each result line is appended to
# runs/program.log. run.sh's lock makes any accidental overlap fail instead of mixing traffic.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "itl_p50_ms", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
for t in 1 2 3; do ./slo/run.sh "slo-S16-t$t" router-bounded16 80 600 36000 && summ "slo-S16-t$t"; done
./slo/run.sh slo-NC16 router-bounded16 110 300 21000 && summ slo-NC16
./slo/run.sh slo-OL16 router-bounded16 150 180 12000 && summ slo-OL16
./slo/run.sh slo-OL16-liveonly live-only 150 180 && summ slo-OL16-liveonly
./slo/burst.sh slo-BU16 40 180 120 & ./slo/run.sh slo-BU16 router-bounded16 80 480 30000 && summ slo-BU16; wait
./slo/chaos.sh slo-CH16 & ./slo/run.sh slo-CH16 router-bounded16 80 600 36000 && summ slo-CH16; wait
echo done >> "$D/runs/program.log"
