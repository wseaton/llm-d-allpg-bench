#!/usr/bin/env bash
# Usage: run.sh NAME NUM_BATCHES BATCH_SIZE PROMPT_TOKENS MAX_TOKENS
# Runs the driver once and records its result, per-pod CPU every 10s, and the
# top Postgres statements by total time under runs/NAME. horizon.log samples
# the oldest backend xmin and dead tuples in the queue tables every 2s.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME=$1; NB=$2; BS=$3; PT=$4; MT=$5
OUT=$D/runs/$NAME; mkdir -p "$OUT"
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
k delete job "$NAME" --ignore-not-found --wait=true >/dev/null
k exec bench-postgres -- psql -U postgres -d batchgateway -qc "SELECT pg_stat_statements_reset()" >/dev/null
sed -e "s/DRIVER_NAME/$NAME/; s/NUM_BATCHES_VAL/$NB/; s/BATCH_SIZE_VAL/$BS/; s/PROMPT_TOKENS_VAL/$PT/; s/MAX_TOKENS_VAL/$MT/" "$D/driver-job.yaml" | k apply -f - >/dev/null
start=$(date +%s)
while true; do
  k exec bench-postgres -- psql -U postgres -d batchgateway -Atq -F' | ' -c "
SELECT extract(epoch from now())::int, 'xmin', coalesce(max(age(backend_xmin)),0), coalesce(max(extract(epoch from now()-xact_start))::int,0),
       (SELECT string_agg(state||':'||left(regexp_replace(query, '\s+', ' ', 'g'),60), ' ; ') FROM pg_stat_activity WHERE backend_xmin IS NOT NULL AND now()-xact_start > interval '5 s')
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
UNION ALL
SELECT extract(epoch from now())::int, relname, n_live_tup, n_dead_tup, coalesce(last_autovacuum::text,'-') FROM pg_stat_user_tables WHERE relname IN ('async_results','async_requests')"
  sleep 2
done > "$OUT/horizon.log" 2>&1 &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT
while true; do
  s=$(k get job "$NAME" -o jsonpath='{.status.succeeded}{.status.failed}' 2>/dev/null || true)
  echo "$(( $(date +%s) - start )) $(k top pod --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')" >> "$OUT/cpu.log"
  [ -n "$s" ] && break
  sleep 10
done
k logs "job/$NAME" > "$OUT/driver.log" 2>&1
k exec bench-postgres -- psql -U postgres -d batchgateway -Atc "SELECT round(total_exec_time::numeric,0) || ' ms | ' || calls || ' calls | ' || round((total_exec_time/calls)::numeric,2) || ' ms/call | ' || left(regexp_replace(query, '\s+', ' ', 'g'), 110) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 15" > "$OUT/pgss.txt"
tail -1 "$OUT/driver.log"
