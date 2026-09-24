#!/usr/bin/env bash
# Counted admission (dispatcher-router-counted.values.yaml): 8 engines at 40 req/s live, where
# budget admission had 4627 TTL evictions, then 16 -> 10 engines mid-run at 60 req/s live.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
engines() { k scale deploy/vcr --replicas="$1" >/dev/null; k rollout status deploy/vcr --timeout=300s >/dev/null; sleep 20; }
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program-counted.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "batch_done", "batch_failed")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"), "batch_q", d.get("samples", {}).get("epp_queue_p-10"))
PY
}
engines 8;  ./slo/run.sh slo-CNT-8 router-counted 40 600 18000 && summ slo-CNT-8
engines 16
( until [ -f "$D/runs/slo-CNT-scale/live-start" ]; do sleep 2; done; s=$(cat "$D/runs/slo-CNT-scale/live-start")
  while [ $(( $(date +%s) - s )) -lt 200 ]; do sleep 1; done; echo "$(date +%s) scale 16->10" >> "$D/runs/slo-CNT-scale/chaos.log"; k scale deploy/vcr --replicas=10 >/dev/null ) &
./slo/run.sh slo-CNT-scale router-counted 60 600 30000 && summ slo-CNT-scale; wait
engines 16
echo done >> "$D/runs/program-counted.log"
