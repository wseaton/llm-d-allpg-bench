"""Fill the gateway with a deep backlog and measure the steady-state drain rate.

A batch queue with a deep backlog has no meaningful "offered rate": saturation
throughput is the rate at which the backlog empties. Work is split across
several batches because one multi-hundred-MB upload gets reset.
"""
import itertools
import json
import os
import random
import string
import time
import urllib.request
from concurrent import futures

BASE = os.environ["BATCH_GATEWAY_URL"]
NUM_BATCHES = int(os.environ.get("NUM_BATCHES", "10"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "20000"))
PROMPT_TOKENS = int(os.environ.get("PROMPT_TOKENS", "64"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "128"))
SAMPLE_SECONDS = float(os.environ.get("SAMPLE_SECONDS", "2"))
SUBMIT_WORKERS = int(os.environ.get("SUBMIT_WORKERS", "16"))
POLL_WORKERS = int(os.environ.get("POLL_WORKERS", "16"))
TIMEOUT = float(os.environ.get("RUN_TIMEOUT", "2400"))
VOCAB_SIZE = int(os.environ.get("VOCAB_SIZE", "20000"))
AUTH = {"Authorization": "Bearer benchmark"}

# Four-character words plus a separator hold the byte accounting at 5 B/word
# while a Zipf weighting puts the compression ratio in the range real prose
# lands in. "word " * N compresses ~62x, which hides every storage and WAL cost
# TOAST would otherwise charge for a large prompt.
_rng = random.Random(1234)
VOCAB = ["".join(_rng.choices(string.ascii_lowercase, k=4)) for _ in range(VOCAB_SIZE)]
ZIPF_CUM = list(itertools.accumulate(1.0 / (i + 1) for i in range(VOCAB_SIZE)))


def make_prompt():
    return " ".join(random.choices(VOCAB, cum_weights=ZIPF_CUM, k=PROMPT_TOKENS)) + " "


def call(path, data=None, headers=None):
    req = urllib.request.Request(BASE + path, data=data, headers={**AUTH, **(headers or {})})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())


def make_payload(batch_idx):
    lines = []
    for i in range(BATCH_SIZE):
        lines.append(json.dumps({
            "custom_id": f"b{batch_idx}-req-{i}",
            "method": "POST",
            "url": "/v1/chat/completions",
            "body": {
                "model": "sim-model",
                "messages": [{"role": "user", "content": make_prompt()}],
                "max_tokens": MAX_TOKENS,
            },
        }))
    return ("\n".join(lines) + "\n").encode()


def submit(batch_idx, payload, out):
    boundary = "----BatchBoundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="purpose"\r\n\r\nbatch\r\n'
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="input-{batch_idx}.jsonl"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + payload + f"\r\n--{boundary}--\r\n".encode()
    file_id = call("/v1/files", data=body,
                   headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})["id"]
    batch = call("/v1/batches", data=json.dumps({
        "input_file_id": file_id,
        "endpoint": "/v1/chat/completions",
        "completion_window": "24h",
    }).encode(), headers={"Content-Type": "application/json"})
    out.append(batch["id"])
    print(f"submitted batch={batch['id']} idx={batch_idx} bytes={len(payload)}", flush=True)


total_requests = NUM_BATCHES * BATCH_SIZE
print(f"submitting {NUM_BATCHES} batches x {BATCH_SIZE} = {total_requests} requests", flush=True)
batch_ids = []

tgen = time.time()
payloads = [make_payload(i) for i in range(NUM_BATCHES)]
print(f"generated {sum(len(p) for p in payloads)} bytes in {time.time()-tgen:.1f}s", flush=True)

t0 = time.time()
with futures.ThreadPoolExecutor(max_workers=SUBMIT_WORKERS) as pool:
    list(pool.map(lambda i: submit(i, payloads[i], batch_ids), range(NUM_BATCHES)))
submit_elapsed = time.time() - t0
print(f"all batches submitted in {submit_elapsed:.1f}s ids={len(batch_ids)}", flush=True)

def poll(bid):
    try:
        s = call(f"/v1/batches/{bid}")
    except Exception as exc:  # a poll failure should not end the run
        print(f"poll error {bid}: {exc}", flush=True)
        return 0, 0, 0
    counts = s.get("request_counts") or {}
    failed = counts.get("failed", 0)
    done = counts.get("completed", 0) + failed
    terminal = 1 if s.get("status") in ("completed", "failed", "cancelled", "expired") else 0
    return done, terminal, failed


start = time.time()
samples = []
last = 0
last_t = 0.0
while time.time() - start < TIMEOUT:
    with futures.ThreadPoolExecutor(max_workers=POLL_WORKERS) as pool:
        counted = list(pool.map(poll, batch_ids))
    done = sum(c[0] for c in counted)
    terminal = sum(c[1] for c in counted)
    failed = sum(c[2] for c in counted)
    now = time.time() - start
    rate = (done - last) / (now - last_t) if now > last_t else 0.0
    samples.append((now, done, rate))
    print(f"SAMPLE t={now:.1f} done={done}/{total_requests} rate={rate:.1f} terminal={terminal} failed={failed}",
          flush=True)
    last, last_t = done, now
    if terminal == len(batch_ids):
        break
    time.sleep(SAMPLE_SECONDS)

mid = [r for _, _, r in samples[max(1, len(samples) // 5):max(2, len(samples) * 4 // 5)]]
mid.sort()
if mid:
    drain_elapsed = time.time() - start
    print(f"RESULT steady_state_median_rps={mid[len(mid)//2]:.1f} "
          f"steady_state_mean_rps={sum(mid)/len(mid):.1f} "
          f"peak_rps={max(r for _, _, r in samples):.1f} total_done={last} "
          f"elapsed={drain_elapsed:.1f} "
          f"submit_elapsed={submit_elapsed:.1f} "
          f"drain_rps={last/drain_elapsed:.1f} "
          f"e2e_rps={last/(submit_elapsed+drain_elapsed):.1f} "
          f"failed={failed}", flush=True)
