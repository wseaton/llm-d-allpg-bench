#!/usr/bin/env bash
# The SLO battery on real vLLM: Qwen3-32B on 8 x H200 (vllm/vllm.yaml, --shutdown-timeout=60),
# router-vllm (holdback 0.8, maxConcurrency 22 from program-vllm-cal.sh), active-passive router,
# counted admission, both llm-d-async transports back to back. Live rates are scaled to the
# pool's ~55 req/s SLO knee. The every-failure run's engine kills exercise vLLM's graceful drain.
# Needs ROUTER_CHART, ROUTER_BASE_VALUES, GATEWAY_CHART and ASYNC_CHART. Summaries:
# runs/program-vllm.log.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090 ENGINES=app=vllm-slo TOKENIZER=10.16.3.36:8000
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench upgrade slo "${ROUTER_CHART:?}" \
  -f "${ROUTER_BASE_VALUES:?}" -f "$D/router-vllm.values.yaml" -f "$D/router-ha.values.yaml" \
  -f "$D/router-ha-fasthc.values.yaml" --set provider.name=none --force-conflicts --wait --timeout 8m >/dev/null || exit 1
k rollout status deploy/slo-proxy --timeout=300s >/dev/null
k rollout status sts/slo-epp --timeout=300s >/dev/null
k scale deploy/vcr --replicas=0 >/dev/null
sleep 30
summ() {
  python3 - "$D/runs/$1/summary.json" "$1" >> "$D/runs/program-vllm.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d.get("epp_requests", {})
print(sys.argv[2], json.dumps({k: d.get(k) for k in ("live_rps", "live_errors", "ttft_p50_ms", "ttft_p99_ms", "slo_attainment", "batch_done", "batch_failed", "chaos")}),
      "batch_rps", round(e.get("p-10/Dispatched", 0) / d["window_s"], 1), "ttl_evicted", e.get("p-10/EvictedTTL", 0),
      "worst20s", max(d["ttft_p99_by_20s"].values()), "sat", d.get("samples", {}).get("saturation"))
PY
}
base() { case "$1" in sql) echo "$D/../dispatcher-values.yaml" ;; redis) echo "$D/../dispatcher-values-redis.yaml" ;; esac; }
for t in sql redis; do ./transport.sh "$t"; DISPATCHER_BASE=$(base "$t") ./slo/run.sh "vl-$t-S" router-counted 40 600 12000 && summ "vl-$t-S"; done
for t in sql redis; do ./transport.sh "$t"; DISPATCHER_BASE=$(base "$t") ./slo/run.sh "vl-$t-NC" router-counted 50 300 8000 && summ "vl-$t-NC"; done
for t in sql redis; do
  ./transport.sh "$t"
  ./slo/burst.sh "vl-$t-BU" 15 180 120 & DISPATCHER_BASE=$(base "$t") ./slo/run.sh "vl-$t-BU" router-counted 40 480 10000 && summ "vl-$t-BU"; wait
done
for t in sql redis; do
  ./transport.sh "$t"
  ./slo/chaos-all.sh "vl-$t-ALL" & DISPATCHER_BASE=$(base "$t") ./slo/run.sh "vl-$t-ALL" router-counted 40 600 12000 && summ "vl-$t-ALL"; wait
done
echo done >> "$D/runs/program-vllm.log"
