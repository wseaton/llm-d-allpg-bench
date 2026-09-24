#!/usr/bin/env bash
# Live-only sweep on the Qwen3-32B pool (8 x H200) through the router, to calibrate the EPP
# concurrency detector: per-engine running requests at the rate where live TTFT p99 crosses
# the SLO. Router: router-vllm (holdback 0.8, placeholder maxConcurrency) + HA + fast health
# checks; vcr scaled to 0. Needs ROUTER_CHART and ROUTER_BASE_VALUES. Summaries:
# runs/program-vllm-cal.log.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
cd "$D/.."
export ROUTER=10.16.3.16 EPP_METRICS=slo-epp-0.slo-epp-headless.allpg-bench.svc.cluster.local:9090 ENGINES=app=vllm-slo TOKENIZER=10.16.3.36:8000
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
k scale deploy/vcr --replicas=0 >/dev/null
helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench upgrade slo "${ROUTER_CHART:?}" \
  -f "${ROUTER_BASE_VALUES:?}" -f "$D/router-vllm.values.yaml" -f "$D/router-ha.values.yaml" \
  -f "$D/router-ha-fasthc.values.yaml" --set provider.name=none --force-conflicts --wait --timeout 8m >/dev/null || exit 1
k rollout status deploy/slo-proxy --timeout=300s >/dev/null
k rollout status sts/slo-epp --timeout=300s >/dev/null
sleep 30
for rate in 30 40 50 60 70; do
  ./slo/run.sh "vl-cal-$rate" live-only "$rate" 180 0 || continue
  python3 - "$D/runs/vl-cal-$rate" "$rate" >> "$D/runs/program-vllm-cal.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/summary.json"))
s = d.get("samples", {})
print(f"rate {sys.argv[2]}: delivered {d['live_rps']} req/s, ttft p50/p99 {d['ttft_p50_ms']}/{d['ttft_p99_ms']} ms, "
      f"slo {d['slo_attainment']}, errors {d['live_errors']}, engine running {s.get('engine_running')}, waiting {s.get('engine_waiting')}")
PY
done
echo done >> "$D/runs/program-vllm-cal.log"
