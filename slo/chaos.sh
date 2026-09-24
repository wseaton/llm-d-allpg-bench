#!/usr/bin/env bash
# Usage: slo/chaos.sh NAME
# Run next to `slo/run.sh NAME ...`. Waits for the run's live window to open, then at +120 s
# deletes two engine pods, at +240 s the EPP pod, at +360 s the dispatcher pod. Each action is
# logged as "<unix seconds> <action>" to runs/NAME/chaos.log.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT=$D/runs/$1
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
until [ -f "$OUT/live-start" ]; do sleep 2; done
start=$(cat "$OUT/live-start")
at() { while [ $(( $(date +%s) - start )) -lt "$1" ]; do sleep 1; done; }
at 120; echo "$(date +%s) delete 2 engines" >> "$OUT/chaos.log"
k delete $(k get pods -l app=vcr -o name | head -2) --wait=false >/dev/null
at 240; echo "$(date +%s) delete epp" >> "$OUT/chaos.log"
k delete pod -l llm-d-router-gateway=slo-epp --wait=false >/dev/null
at 360; echo "$(date +%s) delete dispatcher" >> "$OUT/chaos.log"
k delete $(k get pods -o name | grep dispatcher-llm-d-async) --wait=false >/dev/null
