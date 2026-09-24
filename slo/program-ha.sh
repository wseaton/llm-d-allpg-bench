#!/usr/bin/env bash
# Active-passive router: one sustained trial to confirm the SLO holds in HA mode, then chaos
# (primary EPP, one proxy pod, dispatcher). Results appended to runs/program-ha.log.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program-ha.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "itl_p50_ms", "batch_done", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
./slo/run.sh slo-HA-S16 router-ha 80 600 36000 && summ slo-HA-S16
./slo/chaos-ha.sh slo-HA-CH16 & ./slo/run.sh slo-HA-CH16 router-ha 80 600 36000 && summ slo-HA-CH16; wait
echo done >> "$D/runs/program-ha.log"
