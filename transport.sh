#!/usr/bin/env bash
# Usage: transport.sh sql|redis
# Redeploys the gateway and dispatcher for one llm-d-async transport. The gateway control
# plane stays on Postgres either way; only async dispatch moves. Needs GATEWAY_CHART (charts/
# batch-gateway on wseaton/llm-d-batch-gateway:allpg-sim) and ASYNC_CHART (charts/llm-d-async
# on the #452 branch). GATEWAY_EXTRA_VALUES layers one more gateway values file.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
h() { helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
case "$1" in
  sql) gw=(-f "$D/gateway-values.yaml"); disp="$D/dispatcher-values.yaml" ;;
  redis) gw=(-f "$D/gateway-values.yaml" -f "$D/gateway-values-redis.yaml"); disp="$D/dispatcher-values-redis.yaml" ;;
  *) echo "usage: $0 sql|redis" >&2; exit 2 ;;
esac
[ -n "${GATEWAY_EXTRA_VALUES:-}" ] && gw+=(-f "$GATEWAY_EXTRA_VALUES")
k exec bench-redis -- redis-cli flushall >/dev/null
h upgrade batch-gateway "${GATEWAY_CHART:?}" "${gw[@]}" --wait --timeout 5m >/dev/null
k rollout restart sts/batch-gateway-processor deploy/batch-gateway-apiserver >/dev/null
k rollout status sts/batch-gateway-processor --timeout=300s >/dev/null
k rollout status deploy/batch-gateway-apiserver --timeout=300s >/dev/null
h upgrade dispatcher "${ASYNC_CHART:?}" -f "$disp" --wait --timeout 4m >/dev/null
k rollout status deploy/dispatcher-llm-d-async --timeout=180s >/dev/null
echo "transport: $1 ($(k get cm batch-gateway-processor-config -o jsonpath='{.data.config\.yaml}' | grep -m1 -oE 'transport: *"?[a-z-]+'))"
