"""Open-loop TTS load: Poisson arrivals against POST /v1/audio/speech, one JSONL record per request.

usage: python3 tts-load.py --url http://tts-epp/v1/audio/speech --rate 4 --duration 120 \
           [--objective live] [--stream audio] [--words 20] [--out run.jsonl]

Each record: t0 (unix s), ttfb_ms (first body byte), total_ms, status, bytes, error. With
--stream audio the engine sends PCM as it is generated, so ttfb_ms is time to first audio.
"""

import argparse
import json
import random
import threading
import time
import urllib.error
import urllib.request

WORDS = ("the quick brown fox jumps over the lazy dog while the batch gateway narrates every "
         "chapter of the book in a calm and steady voice").split()


def one_request(args, results, lock):
    text = " ".join(random.choice(WORDS) for _ in range(args.words))
    body = {"model": args.model, "input": text, "voice": args.voice, "response_format": args.format}
    if args.stream:
        body["stream"] = True
        body["stream_format"] = args.stream
    headers = {"Content-Type": "application/json"}
    if args.objective:
        headers["x-llm-d-inference-objective"] = args.objective
    req = urllib.request.Request(args.url, data=json.dumps(body).encode(), headers=headers, method="POST")
    rec = {"t0": time.time(), "ttfb_ms": None, "total_ms": None, "status": 0, "bytes": 0, "error": None}
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            rec["status"] = resp.status
            first = resp.read(1)
            rec["ttfb_ms"] = (time.perf_counter() - start) * 1000
            n = len(first)
            while chunk := resp.read(65536):
                n += len(chunk)
            rec["bytes"] = n
    except urllib.error.HTTPError as e:
        rec["status"] = e.code
        rec["error"] = e.read()[:200].decode(errors="replace")
    except Exception as e:  # noqa: BLE001 - every failure is a data point
        rec["error"] = f"{type(e).__name__}: {e}"[:200]
    rec["total_ms"] = (time.perf_counter() - start) * 1000
    with lock:
        results.append(rec)


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))] if values else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--rate", type=float, required=True, help="mean requests per second (Poisson)")
    ap.add_argument("--duration", type=float, required=True, help="seconds of arrivals")
    ap.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
    ap.add_argument("--voice", default="vivian")
    ap.add_argument("--format", default="pcm")
    ap.add_argument("--stream", default="", help='"audio" for raw streamed PCM')
    ap.add_argument("--objective", default="")
    ap.add_argument("--words", type=int, default=20)
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    results, lock, threads = [], threading.Lock(), []
    end = time.time() + args.duration
    while time.time() < end:
        t = threading.Thread(target=one_request, args=(args, results, lock), daemon=True)
        t.start()
        threads.append(t)
        time.sleep(random.expovariate(args.rate))
    for t in threads:
        t.join(timeout=args.timeout)

    if args.out:
        with open(args.out, "w") as f:
            for r in sorted(results, key=lambda r: r["t0"]):
                f.write(json.dumps(r) + "\n")
    ok = [r for r in results if r["status"] == 200 and not r["error"]]
    ttfb = [r["ttfb_ms"] for r in ok]
    total = [r["total_ms"] for r in ok]
    print(json.dumps({
        "offered_rps": args.rate, "requests": len(results), "errors": len(results) - len(ok),
        "ttfb_p50_ms": round(pct(ttfb, 0.5)), "ttfb_p99_ms": round(pct(ttfb, 0.99)),
        "total_p50_ms": round(pct(total, 0.5)), "total_p99_ms": round(pct(total, 0.99)),
    }))


if __name__ == "__main__":
    main()
