#!/usr/bin/env bash
# Usage: tput-ab.sh [REPS]
# Batch throughput, sql vs redis-sortedset transport, on 4 zero-latency vcr engines:
# 10 batches x 20000 requests, 64-token prompts, 16 output tokens. Reps alternate the
# transports so drift on the shared cluster lands on both. Each switch runs a 2000-request
# smoke first. Progress is written every second (gateway-values-progress1s.yaml). Results: runs/tp-<transport>-r<N>/ (driver.log, cpu.log, pgss.txt, and
# redis-commandstats.txt on redis).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
REPS=${1:-3}
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
export GATEWAY_EXTRA_VALUES=$D/gateway-values-progress1s.yaml
"$D/vcr-mode.sh" throughput
for rep in $(seq "$REPS"); do
  for t in sql redis; do
    "$D/transport.sh" "$t"
    smoke=$("$D/run.sh" "tp-$t-smoke" 1 2000 64 16)
    echo "$smoke" | grep -q 'failed=0' || { echo "smoke failed on $t: $smoke" >&2; exit 1; }
    k exec bench-redis -- redis-cli config resetstat >/dev/null
    echo "tp-$t-r$rep: $("$D/run.sh" "tp-$t-r$rep" 10 20000 64 16)"
    [ "$t" = redis ] && k exec bench-redis -- redis-cli info commandstats > "$D/runs/tp-$t-r$rep/redis-commandstats.txt"
  done
done
