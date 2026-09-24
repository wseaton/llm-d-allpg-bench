#!/usr/bin/env bash
# Usage: vcr-mode.sh throughput|slo
#   throughput  4 zero-latency engines, 4 CPUs each, so the batch path is the bottleneck
#   slo         16 engines with the knobs in slo/vcr.env, 1 CPU requested each
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
case "$1" in
  throughput)
    nodes=${VCR_THROUGHPUT_NODES:-g80d16c}
    k set env deploy/vcr MOCK_TTFT_MS=0 MOCK_ITL_MS=0 MOCK_MAX_NUM_SEQS- MOCK_TTFT_STDDEV_MS- \
      MOCK_ITL_STDDEV_MS- MOCK_TIME_FACTOR_UNDER_LOAD- >/dev/null
    k set resources deploy/vcr --requests=cpu=4,memory=8Gi --limits=cpu=6,memory=12Gi >/dev/null
    replicas=4
    ;;
  slo)
    nodes=${VCR_SLO_NODES:-gf41fb2,gff1e4a}
    # shellcheck disable=SC2046
    k set env deploy/vcr $(grep -E '^MOCK_' "$D/slo/vcr.env") >/dev/null
    k set resources deploy/vcr --requests=cpu=1,memory=2Gi --limits=cpu=4,memory=4Gi >/dev/null
    replicas=16
    ;;
  *) echo "usage: $0 throughput|slo" >&2; exit 2 ;;
esac
values=$(printf '"%s",' ${nodes//,/ }); values="[${values%,}]"
k patch deploy/vcr --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"In\",\"values\":$values}]}]}}}}}}}" >/dev/null
k scale deploy/vcr --replicas="$replicas" >/dev/null
k rollout status deploy/vcr --timeout=600s >/dev/null
echo "vcr: $1, $replicas replicas on $nodes"
