#!/usr/bin/env bash
# Router from the local chart branch (EPP health port 9003, proxy drain) with saturation =
# max(concurrency, engine queue depth); dispatcher with transport retries and counted admission.
# A steady 10-minute trial, then every failure in one 10-minute run.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090
CHART=${ROUTER_CHART:?set ROUTER_CHART to config/charts/llm-d-router-standalone in a checkout of wseaton/llm-d-router}
helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench upgrade slo "$CHART" \
  -f "${ROUTER_BASE_VALUES:?set ROUTER_BASE_VALUES to guides/recipes/router/base.values.yaml in llm-d/llm-d}" -f "$D/router-holdback-maxsat.values.yaml" \
  -f "$D/router-ha.values.yaml" -f "$D/router-ha-fasthc.values.yaml" --set provider.name=none --force-conflicts --wait --timeout 8m >/dev/null || exit 1
kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench rollout status deploy/slo-proxy --timeout=300s >/dev/null
kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench rollout status sts/slo-epp --timeout=300s >/dev/null
sleep 30
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program-final.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "batch_done", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
./slo/run.sh slo-FIN-S16 router-counted 80 600 36000 && summ slo-FIN-S16
./slo/chaos-all.sh slo-FIN-ALL & ./slo/run.sh slo-FIN-ALL router-counted 80 600 36000 && summ slo-FIN-ALL; wait
echo done >> "$D/runs/program-final.log"
