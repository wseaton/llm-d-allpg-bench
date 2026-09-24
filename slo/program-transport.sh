#!/usr/bin/env bash
# The SLO battery on both llm-d-async transports (sql, redis-sortedset), 16 vcr engines,
# holdback 0.8, active-passive router, counted admission. Each scenario runs on sql then
# redis back to back so both see the same cluster. Needs ROUTER_CHART, ROUTER_BASE_VALUES,
# GATEWAY_CHART and ASYNC_CHART (see the README). Summaries: runs/program-transport.log.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090 ENGINES=app=vcr
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench upgrade slo "${ROUTER_CHART:?}" \
  -f "${ROUTER_BASE_VALUES:?}" -f "$D/router-holdback-0.8.values.yaml" -f "$D/router-ha.values.yaml" \
  -f "$D/router-ha-fasthc.values.yaml" --set provider.name=none --force-conflicts --wait --timeout 8m >/dev/null || exit 1
k rollout status deploy/slo-proxy --timeout=300s >/dev/null
k rollout status sts/slo-epp --timeout=300s >/dev/null
./vcr-mode.sh slo
sleep 30
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program-transport.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "batch_done", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
base() { case "$1" in sql) echo "$D/../dispatcher-values.yaml" ;; redis) echo "$D/../dispatcher-values-redis.yaml" ;; esac; }
for t in sql redis; do ./transport.sh "$t"; DISPATCHER_BASE=$(base "$t") ./slo/run.sh "tr-$t-S16" router-counted 80 600 36000 && summ "tr-$t-S16"; done
for t in sql redis; do ./transport.sh "$t"; DISPATCHER_BASE=$(base "$t") ./slo/run.sh "tr-$t-NC16" router-counted 110 300 21000 && summ "tr-$t-NC16"; done
for t in sql redis; do
  ./transport.sh "$t"
  ./slo/burst.sh "tr-$t-BU16" 40 180 120 & DISPATCHER_BASE=$(base "$t") ./slo/run.sh "tr-$t-BU16" router-counted 80 480 30000 && summ "tr-$t-BU16"; wait
done
for t in sql redis; do
  ./transport.sh "$t"
  ./slo/chaos-all.sh "tr-$t-ALL" & DISPATCHER_BASE=$(base "$t") ./slo/run.sh "tr-$t-ALL" router-counted 80 600 36000 && summ "tr-$t-ALL"; wait
done
echo done >> "$D/runs/program-transport.log"
