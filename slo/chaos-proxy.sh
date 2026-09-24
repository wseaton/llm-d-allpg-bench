#!/usr/bin/env bash
# Usage: slo/chaos-proxy.sh NAME
# Deletes one proxy pod at +120 s and the other (by then the older one) at +300 s, logged to
# runs/NAME/chaos.log.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT=$D/runs/$1
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
until [ -f "$OUT/live-start" ]; do sleep 2; done
start=$(cat "$OUT/live-start")
at() { while [ $(( $(date +%s) - start )) -lt "$1" ]; do sleep 1; done; }
oldest() { k get pods --sort-by=.metadata.creationTimestamp -o name | grep slo-proxy | head -1; }
at 120; p=$(oldest); echo "$(date +%s) delete $p" >> "$OUT/chaos.log"; k delete "$p" --wait=false >/dev/null
at 300; p=$(oldest); echo "$(date +%s) delete $p" >> "$OUT/chaos.log"; k delete "$p" --wait=false >/dev/null
