#!/usr/bin/env bash
# probe.sh NAME TARGET [SCENARIO]: one live-only nyann run against TARGET (an OpenAI base URL),
# then a one-line summary of requests, errors and latency. Results land in $OUT/NAME.jsonl.
set -euo pipefail
cd "$(dirname "$0")"
NAME=$1 TARGET=$2 SCENARIO=${3:-probe150.star}
OUT=${OUT:-runs/probes}
TOKENIZER=${TOKENIZER:-10.16.3.36:8000}
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
mkdir -p "$OUT"
k exec slo-runner -- sh -c "rm -rf '/runs/$NAME' && mkdir -p '/runs/$NAME'"
k cp "$SCENARIO" "slo-runner:/runs/$NAME/scenario.star" >/dev/null
k exec slo-runner -- /nyann-bench generate --target "$TARGET" --model sim-model \
  --tokenizer-target "http://$TOKENIZER/v1" --config "/runs/$NAME/scenario.star" \
  --output-dir "/runs/$NAME" --log-level warn --max-consecutive-errors -1 >/dev/null 2>&1 || true
k cp "slo-runner:/runs/$NAME/requests_0.jsonl" "$OUT/$NAME.jsonl" >/dev/null 2>&1
python3 - "$OUT/$NAME.jsonl" "$NAME" <<'EOF'
import json, sys, collections
rs = [json.loads(l) for l in open(sys.argv[1])]
ok = [r for r in rs if r["status"] == "ok"]
err = [r for r in rs if r["status"] != "ok"]
q = lambda a, p: a[int(p * (len(a) - 1))] if a else float("nan")
t = sorted(r["ttft_ms"] for r in ok if r.get("ttft_ms"))
l = sorted(r["latency_ms"] for r in ok)
print(f"{sys.argv[2]}: {len(rs)} req, {len(err)} err, ttft p50/p99 {q(t,.5):.0f}/{q(t,.99):.0f} ms, e2e p50/p99 {q(l,.5):.0f}/{q(l,.99):.0f} ms")
for msg, n in collections.Counter(str(r.get("error"))[-60:] for r in err).most_common(3):
    print(f"  {n} x ...{msg}")
EOF
