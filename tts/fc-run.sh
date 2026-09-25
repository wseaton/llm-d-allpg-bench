#!/usr/bin/env bash
# Usage: tts/fc-run.sh NAME BATCH_LINES
# Live streaming TTS (tts-live objective, 6 req/s for LIVE_SECONDS) next to a TTS batch of
# BATCH_LINES submitted through the gateway WARMUP seconds earlier (0 = live only). Leftover batch
# work is cancelled afterwards. Results in runs/tts/NAME: live.jsonl, summary.json, batch.json.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
NAME=$1 LINES=$2 LIVE_RATE=${LIVE_RATE:-6} LIVE_SECONDS=${LIVE_SECONDS:-300} WARMUP=${WARMUP:-60}
OUT=$D/../runs/tts/$NAME; mkdir -p "$OUT"
k() { kubectl --context "${KUBE_CONTEXT:-coreweave-waldorf}" -n allpg-bench "$@"; }
API=http://localhost:18000; AUTH='Authorization: Bearer benchmark'
pgrep -f 'port-forward svc/batch-gateway-apiserver 18000' >/dev/null || { k port-forward svc/batch-gateway-apiserver 18000:8000 >/dev/null 2>&1 & sleep 3; }
bid=""
if [ "$LINES" -gt 0 ]; then
  python3 - "$LINES" > "$OUT/batch.jsonl" <<'PY'
import json, random, sys
words = "the narrator reads each chapter slowly so every listener can follow the story from beginning to end".split()
for i in range(int(sys.argv[1])):
    text = " ".join(random.choice(words) for _ in range(random.randint(25, 45)))
    print(json.dumps({"custom_id": f"ch-{i}", "method": "POST", "url": "/v1/audio/speech",
                      "body": {"model": "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice", "input": text, "voice": "ryan", "response_format": "mp3"}}))
PY
  fid=$(curl -s -H "$AUTH" -F purpose=batch -F file=@"$OUT/batch.jsonl" $API/v1/files | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
  bid=$(curl -s -H "$AUTH" -H 'Content-Type: application/json' -d "{\"input_file_id\":\"$fid\",\"endpoint\":\"/v1/audio/speech\",\"completion_window\":\"24h\"}" $API/v1/batches | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
  echo "$bid" > "$OUT/batch-id"
  sleep "$WARMUP"
fi
k exec tts-runner -- python3 /tts-load.py --url http://tts-epp.allpg-bench.svc.cluster.local/v1/audio/speech \
  --rate "$LIVE_RATE" --duration "$LIVE_SECONDS" --stream audio --objective tts-live --out /tmp/live.jsonl > "$OUT/summary.json"
k cp tts-runner:/tmp/live.jsonl "$OUT/live.jsonl" >/dev/null
if [ -n "$bid" ]; then
  curl -s -H "$AUTH" $API/v1/batches/$bid > "$OUT/batch.json"
  curl -s -X POST -H "$AUTH" $API/v1/batches/$bid/cancel >/dev/null
fi
echo "$NAME $(cat "$OUT/summary.json") batch=$( [ -n "$bid" ] && python3 -c "import json;d=json.load(open('$OUT/batch.json'));print(d['status'], d.get('request_counts'))" || echo none)"
