#!/usr/bin/env bash
# Usage: slo/chaos-all.sh NAME
# Every failure in one run: two engines at +90 s, the primary EPP at +210 s, the oldest proxy
# at +330 s, the dispatcher at +450 s. Logged to runs/NAME/chaos.log.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT=$D/runs/$1
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
until [ -f "$OUT/live-start" ]; do sleep 2; done
start=$(cat "$OUT/live-start")
at() { while [ $(( $(date +%s) - start )) -lt "$1" ]; do sleep 1; done; }
log() { echo "$(date +%s) $*" >> "$OUT/chaos.log"; }
at 90;  log "delete 2 engines"; k delete $(k get pods -l "${ENGINES:-app=vllm-slo}" -o name | head -2) --wait=false >/dev/null
at 210; log "delete primary epp"; k delete pod slo-epp-0 --wait=false >/dev/null
at 330; log "delete oldest proxy"; k delete "$(k get pods --sort-by=.metadata.creationTimestamp -o name | grep slo-proxy | head -1)" --wait=false >/dev/null
at 450; log "delete dispatcher"; k delete "$(k get pods -o name | grep dispatcher-llm-d-async | head -1)" --wait=false >/dev/null
