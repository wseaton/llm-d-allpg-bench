#!/usr/bin/env bash
# Usage: slo/chaos-ha.sh NAME
# chaos.sh for the active-passive router: at +120 s deletes the primary EPP (slo-epp-0), at
# +240 s one proxy pod, at +360 s the dispatcher pod. Logged to runs/NAME/chaos.log.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT=$D/runs/$1
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
until [ -f "$OUT/live-start" ]; do sleep 2; done
start=$(cat "$OUT/live-start")
at() { while [ $(( $(date +%s) - start )) -lt "$1" ]; do sleep 1; done; }
at 120; echo "$(date +%s) delete primary epp" >> "$OUT/chaos.log"
k delete pod slo-epp-0 --wait=false >/dev/null
at 240; echo "$(date +%s) delete one proxy" >> "$OUT/chaos.log"
k delete "$(k get pods -o name | grep slo-proxy | head -1)" --wait=false >/dev/null
at 360; echo "$(date +%s) delete dispatcher" >> "$OUT/chaos.log"
k delete "$(k get pods -o name | grep dispatcher-llm-d-async | head -1)" --wait=false >/dev/null
