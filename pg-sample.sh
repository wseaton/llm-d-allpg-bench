#!/usr/bin/env bash
# Sample the benchmark Postgres while load runs: commit rate, backend counts,
# and container CPU. Without this, "Postgres saturated" is an assertion rather
# than a measurement.
set -uo pipefail
CTX=${KUBE_CONTEXT:-coreweave-waldorf}
NS=pgscale
OUT="${1:?usage: pg-sample.sh <out.csv> [seconds]}"
DUR="${2:-900}"
PSQL=(kubectl --context "$CTX" -n "$NS" exec bench-postgres -- psql -U postgres -d batchgateway -tAc)

echo "t,xacts_per_s,commits_total,backends,active,waiting,cpu_cores,pg_rows_requests,pg_rows_results" > "$OUT"
prev=0
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  now=$(( $(date +%s) - start ))
  commits=$("${PSQL[@]}" "select coalesce(sum(xact_commit),0) from pg_stat_database" 2>/dev/null | tr -d '\r ')
  backends=$("${PSQL[@]}" "select count(*) from pg_stat_activity" 2>/dev/null | tr -d '\r ')
  active=$("${PSQL[@]}" "select count(*) from pg_stat_activity where state='active'" 2>/dev/null | tr -d '\r ')
  waiting=$("${PSQL[@]}" "select count(*) from pg_stat_activity where wait_event is not null and state='active'" 2>/dev/null | tr -d '\r ')
  reqs=$("${PSQL[@]}" "select count(*) from async_requests" 2>/dev/null | tr -d '\r ')
  res=$("${PSQL[@]}" "select count(*) from async_results" 2>/dev/null | tr -d '\r ')
  cpu=$(kubectl --context "$CTX" -n "$NS" top pod bench-postgres --no-headers 2>/dev/null | awk '{print $2}' | tr -d 'm')
  [ -z "${commits:-}" ] && commits=0
  rate=0
  if [ "$prev" -gt 0 ] && [ -n "$commits" ]; then rate=$(( (commits - prev) / 5 )); fi
  prev=${commits:-0}
  echo "$now,$rate,${commits:-0},${backends:-0},${active:-0},${waiting:-0},$(awk "BEGIN{print ${cpu:-0}/1000}"),${reqs:-0},${res:-0}" >> "$OUT"
  sleep 5
done
