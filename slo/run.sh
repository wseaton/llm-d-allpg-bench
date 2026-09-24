#!/usr/bin/env bash
# Usage: slo/run.sh NAME SCENARIO [LIVE_RATE] [LIVE_SECONDS] [BATCH_REQUESTS]
#
# LIVE_TEMPLATE (default live.star) picks the live scenario, e.g. live-burst.star.
#
# SCENARIO picks how batch traffic reaches the engines:
#   live-only  no batch; the SLO baseline
#   direct     dispatcher -> engines, bypassing the router (dispatcher-direct.values.yaml)
#   router     dispatcher -> router under the batch objective (dispatcher-router.values.yaml)
#   router-gate  as router, with the dispatcher gate (dispatcher-router-gate.values.yaml)
#
# Batch requests are submitted first and given WARMUP seconds to reach steady state, then
# nyann-bench sends live traffic under the live objective from the slo-runner pod. Records
# land in runs/NAME: nyann per-request JSONL, EPP and dispatcher metrics before and after
# the live window, and the batch driver log. Leftover batches are cancelled afterwards and
# the request queue is drained before returning.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME=$1 SCENARIO=$2 LIVE_RATE=${3:-16} LIVE_SECONDS=${4:-180} BATCH_REQUESTS=${5:-6000}
WARMUP=${WARMUP:-45}
ROUTER=${ROUTER:-10.16.3.146} EPP_METRICS=${EPP_METRICS:-10.16.3.146:9090} TOKENIZER=${TOKENIZER:-10.16.3.36:8000} ENGINES=${ENGINES:-app=vllm-slo} GATEWAY=10.16.1.122
mkdir "$D/.run.lock" 2>/dev/null || { echo "another slo run holds $D/.run.lock" >&2; exit 1; }
trap 'rmdir "$D/.run.lock"' EXIT
OUT=$D/runs/$NAME; mkdir -p "$OUT"
JOB=$(echo "$NAME-batch" | tr '[:upper:]' '[:lower:]')
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
psqlq() { k exec bench-postgres -- psql -U postgres -d batchgateway -Atc "$1"; }
cpfrom() { for _ in 1 2 3; do k cp "$@" >/dev/null && return 0; sleep 3; done; return 1; }
dispatcher_ip() { k get pods -o wide | awk '/^dispatcher-/{print $6; exit}'; }
snapshot() {
  k exec slo-runner -- wget -qO- "http://$EPP_METRICS/metrics" | grep -E '^llm_d_epp_flow_control_(requests_total|queue_size|pool_saturation)' > "$OUT/epp-$1.prom" || true
  k exec slo-runner -- wget -qO- "http://$(dispatcher_ip):9090/metrics" | grep -E '^llm_d_async_' > "$OUT/dispatcher-$1.prom" || true
}

if [ "$SCENARIO" != live-only ]; then
  helm --kube-context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench upgrade dispatcher \
    "${ASYNC_CHART:?set ASYNC_CHART to charts/llm-d-async in a checkout of wseaton/llm-d-async}" \
    -f "$D/../dispatcher-values.yaml" -f "$D/dispatcher-$SCENARIO.values.yaml" --wait --timeout 4m >/dev/null
  k rollout status deploy/dispatcher-llm-d-async --timeout=180s >/dev/null
  k delete job "$JOB" --ignore-not-found --wait=true >/dev/null
  sed -e "s/DRIVER_NAME/$JOB/; s/NUM_BATCHES_VAL/3/; s/BATCH_SIZE_VAL/$((BATCH_REQUESTS / 3))/; s/PROMPT_TOKENS_VAL/256/; s/MAX_TOKENS_VAL/128/" \
    "$D/../driver-job.yaml" | k apply -f - >/dev/null
  sleep "$WARMUP"
fi

sed -e "s/LIVE_RATE/$LIVE_RATE/g; s/LIVE_SECONDS/${LIVE_SECONDS}s/" "$D/${LIVE_TEMPLATE:-live.star}" > "$OUT/live.star"
k exec slo-runner -- sh -c "rm -rf /runs/$NAME && mkdir -p /runs/$NAME"
k cp "$OUT/live.star" "slo-runner:/runs/$NAME/scenario.star" >/dev/null
snapshot before
vcr_ips=$(k get pods -l "$ENGINES" -o jsonpath='{.items[*].status.podIP}')
k cp "$D/sampler.sh" slo-runner:/runs/sampler.sh >/dev/null
k exec slo-runner -- sh -c "nohup sh /runs/sampler.sh $EPP_METRICS $vcr_ips > /runs/$NAME/samples.log 2>&1 &"
date +%s > "$OUT/live-start"
k exec slo-runner -- /nyann-bench generate --target "http://$ROUTER/v1" --model sim-model \
  --tokenizer-target "http://$TOKENIZER/v1" --config "/runs/$NAME/scenario.star" \
  --output-dir "/runs/$NAME" --log-level warn --max-consecutive-errors -1 > "$OUT/nyann.log" 2>&1
date +%s > "$OUT/live-end"
snapshot after
k exec slo-runner -- pkill -f sampler.sh || true
cpfrom "slo-runner:/runs/$NAME/requests_0.jsonl" "$OUT/live.jsonl"
cpfrom "slo-runner:/runs/$NAME/samples.log" "$OUT/samples.log"

if [ "$SCENARIO" != live-only ]; then
  k logs "job/$JOB" > "$OUT/driver.log" 2>&1 || true
  for id in $(grep -o 'batch=batch_[0-9a-f-]*' "$OUT/driver.log" | cut -d= -f2); do
    k exec slo-runner -- wget -qO- --post-data='' --header 'Authorization: Bearer benchmark' \
      "http://$GATEWAY:8000/v1/batches/$id/cancel" >/dev/null 2>&1 || true
  done
  k delete job "$JOB" --ignore-not-found --wait=false >/dev/null
  for _ in $(seq 120); do
    [ "$(psqlq 'SELECT count(*) FROM async_requests')" = 0 ] && break
    sleep 5
  done
fi
python3 "$D/report.py" "$OUT"
