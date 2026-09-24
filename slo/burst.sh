#!/usr/bin/env bash
# Usage: slo/burst.sh NAME RATE AT_SECONDS DURATION_SECONDS
# Run next to `slo/run.sh NAME ...`. Once the run's live window has been open AT_SECONDS,
# adds a second live stream at RATE req/s for DURATION_SECONDS on top of the base traffic
# (a separate nyann-bench process, so the base stream has no stage transition). Records land
# in runs/NAME/burst.jsonl and the window in runs/NAME/burst-window.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME=$1 RATE=$2 AT=$3 DUR=$4
OUT=$D/runs/$NAME
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
until [ -f "$OUT/live-start" ]; do sleep 2; done
start=$(cat "$OUT/live-start")
while [ $(( $(date +%s) - start )) -lt "$AT" ]; do sleep 1; done
sed -e "s/LIVE_RATE/$RATE/; s/LIVE_SECONDS/${DUR}s/" "$D/live.star" > "$OUT/burst.star"
k exec slo-runner -- sh -c "rm -rf /runs/$NAME-burst && mkdir -p /runs/$NAME-burst"
k cp "$OUT/burst.star" "slo-runner:/runs/$NAME-burst/scenario.star" >/dev/null
echo "$(date +%s)" > "$OUT/burst-window"
k exec slo-runner -- /nyann-bench generate --target "http://${ROUTER:-10.16.3.146}/v1" --model sim-model \
  --tokenizer-target "http://${TOKENIZER:-10.16.3.36:8000}/v1" --config "/runs/$NAME-burst/scenario.star" \
  --output-dir "/runs/$NAME-burst" --log-level warn --max-consecutive-errors -1 > "$OUT/burst-nyann.log" 2>&1
echo "$(date +%s)" >> "$OUT/burst-window"
k cp "slo-runner:/runs/$NAME-burst/requests_0.jsonl" "$OUT/burst.jsonl" >/dev/null
