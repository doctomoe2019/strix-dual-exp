#!/usr/bin/env python3
"""Phase-4 performance battery client: run the pinned perf fixture battery
against one arm's A/B pair server and record one JSON line per request.

Same request bodies on both arms (verified by request_sha256 during
analysis); the only difference is the model pack behind the server. Every
row carries the response usage/timings plus rank-local and rank-remote disk
counters (/proc/<pid>/io) bracketing the request, so PLE row traffic is
measured, never assumed.

Sections, in run order:
  cold    first requests after start: 1024-token prefills (mt=1) and a
           64-token decode (mt=64) plus its warm repeat -- cold first-gather
           cost, lazy-init share and per-request disk bytes
  canary  the production gate protocol itself (serve-canary.sh): one
           unclassified warmup + three measured 8192-token cycles against
           SERVE_CANARY_TPS=1700
  d1      decode at concurrency 1: eight varied prompts x 256 tokens
  p1      deep prefill: two nonce'd high-entropy soup prompts, mt=1
          (target 32000 "soup tokens"; actual measured prompts are
          ~48k tokenizer tokens -- the id prefix p32k is kept for
          continuity with the retained evidence)
  c32     decode at concurrency 32: 32 clients x 256 tokens (short varied
           prompts); disk counters bracket the whole section
  r1      repetitive decode (small n-gram working set): counting + word
           repetition, 768 tokens
  r2      cache-pressure repetitive decode: echo a ~3k-token item block
           repeated three times in the prompt (distinct PLE rows between
           the BF16 and IQ4 row-cache capacities), 512 tokens
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

MODEL = "Qwen3.8-Flash-Next"
CANARY_TPS = 1700
CANARY_TOKENS = 8192
CANARY_SCRIPT = "/root/strix-dual-exp/scripts/serve-canary.sh"

# ------------------------------------------------------------------ corpus --

D1_PROMPTS = [
    "Explain the difference between latency and throughput in distributed "
    "systems, with one concrete example of each.",
    "Write a short review of a hypothetical restaurant called The Blue "
    "Lantern, mentioning the soup, the service and the price.",
    "Summarize how a hash table handles collisions, then name two common "
    "strategies.",
    "A train leaves at 14:10 and arrives at 17:46. How long was the trip? "
    "Show the subtraction.",
    "Describe the water cycle in five sentences, one sentence per stage.",
    "List six practical uses of rainwater harvesting in a dry city, with a "
    "one-line benefit each.",
    "Compare reading a paper book and an e-reader for studying. Give three "
    "points, then a one-sentence recommendation.",
    "Explain why bridges expand in summer and how engineers accommodate it. "
    "Mention the relevant physical quantity.",
]

C32_PROMPTS = [
    "Name the capital of {c} and one famous landmark there.",
    "Give one safety tip for {a}, in a single sentence.",
    "Translate 'good morning' into {l} and transliterate it.",
    "Name the primary color missing from this list: red, {l2}.",
    "Write a haiku about {t}.",
    "What is {x} times {y}? Reply with just the number.",
    "Name one river in {c2} and say where it empties.",
    "Suggest a plant that survives on a {p} windowsill, one line why.",
]
C32_FILL = {
    "c": ["Norway", "Chile", "Ghana", "Nepal", "Portugal", "Cuba", "Laos",
          "Jordan", "Peru", "Fiji", "Malta", "Iran", "Kenya", "Bhutan"],
    "a": ["camping in bear country", "night cycling", "deep frying",
          "hiking in heat", "using a ladder", "swimming in surf",
          "ice skating on lakes", "lifting furniture"],
    "l": ["Swahili", "Greek", "Vietnamese", "Hindi", "Finnish", "Turkish",
          "Korean", "Polish"],
    "l2": ["blue", "yellow", "green"],
    "t": ["harbor fog", "a copper kettle", "old typewriters", "monsoon rain",
          "a night train", "desert wind", "chalk dust", "city pigeons"],
    "x": [17, 23, 19, 14, 27, 16, 18, 13],
    "y": [4, 6, 3, 9, 5, 7, 8, 12],
    "c2": ["Egypt", "Brazil", "Mongolia", "Ireland", "Thailand"],
    "p": ["north-facing", "sunny", "shaded", "drafty"],
}

R1_PROMPTS = [
    "Count from 1 to 400, one number per line, no other text on any line.",
    "Repeat the word 'buffer' on every line, 600 times, no other text.",
]

_ADJ = ["quick", "lazy", "brass", "hollow", "quiet", "amber", "narrow",
        "solar", "restless", "velvet", "granite", "pale", "southern",
        "winter", "paper", "copper", "hidden", "crooked", "salted", "early"]
_NOUN = ["lantern", "harbor", "engine", "meadow", "ledger", "sparrow",
         "violin", "quarry", "compass", "orchard", "furnace", "canal",
         "hammock", "lighthouse", "caravan", "pocket", "beacon", "mill"]
_VERB = ["crossed", "measured", "circled", "followed", "balanced",
         "shadowed", "warmed", "framed", "opened", "threaded", "answered",
         "doubled", "anchored", "saluted"]
_PLACE = ["the ridge", "the mill yard", "the old pier", "the north gate",
          "the dry aqueduct", "the switching yard", "the cliff path",
          "the winter market", "the ferry slip", "the cricket field"]


def r2_block(seed: int, items: int) -> str:
    """A numbered item list: natural but high-entropy n-grams, so each item's
    PLE rows are distinct and the block's row working set (~items*24*16 rows)
    sits between the BF16 (~26k) and IQ4 (~93k) row-cache capacities."""
    rng = _Rng(seed)
    lines = []
    for i in range(1, items + 1):
        lines.append(
            f"Item {i}: The {rng.choice(_ADJ)} {rng.choice(_NOUN)} "
            f"{rng.choice(_VERB)} the {rng.choice(_ADJ)} {rng.choice(_NOUN)} "
            f"by {rng.choice(_PLACE)} while {rng.randint(3, 97)} "
            f"{rng.choice(_NOUN)}s looked on.")
    return "\n".join(lines)


class _Rng:
    """Deterministic small RNG (independent of Python version subtleties)."""

    def __init__(self, seed: int):
        self.state = seed & 0xFFFFFFFF

    def _next(self) -> int:
        self.state = (1103515245 * self.state + 12345) & 0x7FFFFFFF
        return self.state

    def randint(self, lo: int, hi: int) -> int:
        return lo + self._next() % (hi - lo + 1)

    def choice(self, seq):
        return seq[self._next() % len(seq)]


def soup_prompt(seed: int, want_tokens: int) -> str:
    """High-entropy word soup near want_tokens tokens (no KV/PLE reuse)."""
    rng = _Rng(seed)
    words = []
    chars = int(want_tokens * 4.4)  # ~4.4 chars/token for mixed soup
    while sum(len(w) + 1 for w in words) < chars:
        words.append(rng.choice(_ADJ) if rng.randint(1, 6) == 1 else rng.choice(_NOUN))
        if rng.randint(1, 3) == 1:
            words.append(str(rng.randint(100, 99999)))
    return " ".join(words)


# ---------------------------------------------------------------- helpers --

def post(port: int, body: dict, timeout: int = 900) -> tuple[dict, float, str]:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions", data=data,
        headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            out = json.load(resp)
        return out, (time.time() - t0) * 1000.0, ""
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode()[:400]
        except Exception:
            detail = ""
        return {}, (time.time() - t0) * 1000.0, f"HTTP {e.code}: {detail}"
    except Exception as e:  # noqa: BLE001
        return {}, (time.time() - t0) * 1000.0, f"{type(e).__name__}: {e}"


def chat_body(prompt: str, max_tokens: int) -> dict:
    return {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0,
        "thinking": {"type": "disabled"},
    }


class DiskCounters:
    """read_bytes/rchar of both ranks' serve processes around each section."""

    def __init__(self, pid0_file: str, pid1_file: str, host_b: str):
        self.pid0_file = pid0_file
        self.pid1_file = pid1_file
        self.host_b = host_b

    @staticmethod
    def _parse(text: str) -> dict | None:
        out = {}
        for line in text.splitlines():
            if ":" in line:
                key, _, val = line.partition(":")
                if key in ("read_bytes", "rchar", "write_bytes"):
                    out[key] = int(val.strip())
        return out or None

    def _read_pid(self, path: str) -> str | None:
        try:
            with open(path) as f:
                pid = f.read().strip()
            return pid or None
        except OSError:
            return None

    def snapshot(self) -> dict:
        snap = {"ts": time.strftime("%FT%T%z")}
        pid0 = self._read_pid(self.pid0_file)
        if pid0:
            try:
                with open(f"/proc/{pid0}/io") as f:
                    snap["r0"] = self._parse(f.read())
            except OSError:
                snap["r0"] = None
        pid1 = self._read_pid(self.pid1_file)
        if pid1:
            try:
                text = subprocess.run(
                    ["ssh", f"root@{self.host_b}", f"cat /proc/{pid1}/io"],
                    capture_output=True, text=True, timeout=30).stdout
                snap["r1"] = self._parse(text)
            except Exception:  # noqa: BLE001
                snap["r1"] = None
        return snap


def emit(out, row: dict) -> None:
    out.write(json.dumps(row, sort_keys=True) + "\n")
    out.flush()


def base_row(arm: str, replicate: int, section: str, rid: str, body: dict,
             disk_before: dict | None) -> dict:
    return {
        "arm": arm, "replicate": replicate, "section": section, "id": rid,
        "ts": time.strftime("%FT%T%z"),
        "request_sha256": hashlib.sha256(
            json.dumps(body, sort_keys=True).encode()).hexdigest(),
        "body": {k: v for k, v in body.items() if k != "messages"} | {
            "messages_digest": hashlib.sha256(
                json.dumps(body.get("messages", []), sort_keys=True).encode()
            ).hexdigest()},
        "prompt_chars": sum(
            len(m.get("content") or "") for m in body.get("messages", [])),
        "error": None, "disk_before": disk_before,
    }


def finish_row(row: dict, resp: dict, wall_ms: float, err: str,
               disk_after: dict | None) -> dict:
    content = ((resp.get("choices") or [{}])[0].get("message") or {}).get(
        "content")
    row.update({
        "wall_ms": round(wall_ms, 3), "error": err or None,
        "usage": resp.get("usage"), "timings": resp.get("timings"),
        "content_sha256": hashlib.sha256(
            (content or "").encode()).hexdigest() if content is not None else None,
        "completion_chars": len(content or ""),
        "disk_after": disk_after,
    })
    return row


def run_serial(out, port, arm, replicate, section, items, disk, label_fn):
    """items: list of (id, body). Disk counters bracket every request."""
    for rid, body in items:
        before = disk.snapshot()
        row = base_row(arm, replicate, section, rid, body, before)
        resp, wall, err = post(port, body)
        after = disk.snapshot()
        emit(out, finish_row(row, resp, wall, err, after))
        u = (resp.get("usage") or {})
        print(f"[{time.strftime('%T')}] {section}/{rid}: "
              f"wall={wall:.0f}ms ptok={u.get('prompt_tokens')} "
              f"ctok={u.get('completion_tokens')} err={err or '-'}",
              flush=True)


def run_canary(out, port, arm, replicate, disk) -> list[str]:
    """Invoke the production canary script (its exact protocol) 4x."""
    lines = []
    env = dict(os.environ)
    env.update({
        "SERVE_PORT": str(port), "SERVE_CANARY_TPS": str(CANARY_TPS),
        "SERVE_CANARY_TOKENS": str(CANARY_TOKENS),
        "SERVE_MODEL_NAME": MODEL,
    })
    for label, warmup in (("warmup", "1"), ("c1", "0"), ("c2", "0"),
                          ("c3", "0")):
        env["SERVE_CANARY_LABEL"] = label
        env["SERVE_CANARY_WARMUP"] = warmup
        before = disk.snapshot()
        t0 = time.time()
        proc = subprocess.run(["bash", CANARY_SCRIPT], env=env,
                              capture_output=True, text=True, timeout=600)
        wall = (time.time() - t0) * 1000.0
        after = disk.snapshot()
        text = (proc.stdout + proc.stderr).strip().splitlines()
        line = text[-1] if text else ""
        tps = None
        verdict = None
        match = re.search(r"prefill_tps=([0-9.]+)", line)
        if match:
            tps = float(match.group(1))
        match = re.search(r": (FAST|SLOW|WARMUP)\b", line)
        if match:
            verdict = match.group(1)
        emit(out, {
            "arm": arm, "replicate": replicate, "section": "canary",
            "id": label, "ts": time.strftime("%FT%T%z"),
            "rc": proc.returncode, "line": line, "verdict": verdict,
            "prefill_tps": tps, "gate_tps": CANARY_TPS,
            "wall_ms": round(wall, 3),
            "disk_before": before, "disk_after": after,
        })
        lines.append(line)
        print(f"[{time.strftime('%T')}] canary/{label}: {line}", flush=True)
        if proc.returncode not in (0, 1):
            print(f"canary {label} rc={proc.returncode} (ERROR path)",
                  file=sys.stderr, flush=True)
    return lines


def run_c32(out, port, arm, replicate, disk) -> None:
    bodies = []
    rng = _Rng(20261018)
    for i in range(32):
        tmpl = C32_PROMPTS[i % len(C32_PROMPTS)]
        text = tmpl
        for key, vals in C32_FILL.items():
            text = text.replace(f"{{{key}}}", str(rng.choice(vals)), 1)
        text = f"[client {i:02d}] {text}"
        bodies.append((f"c32-{i:02d}", chat_body(text, 256)))
    before = disk.snapshot()
    rows = [None] * len(bodies)
    starts = [None] * len(bodies)
    ends = [None] * len(bodies)
    lock = threading.Lock()

    def worker(idx: int, body: dict) -> None:
        # Staggered starts keep the accept queue (backlog 16) from dropping
        # connections; the server runs --max-connections 64 in this window.
        time.sleep(0.025 * idx)
        t0 = time.time()
        resp, wall, err = post(port, body)
        t1 = time.time()
        row = base_row(arm, replicate, "c32", bodies[idx][0], body, None)
        finish_row(row, resp, wall, err, None)
        with lock:
            rows[idx] = row
            starts[idx] = t0
            ends[idx] = t1

    threads = [threading.Thread(target=worker, args=(i, b[1]))
               for i, b in enumerate(bodies)]
    t_start = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    after = disk.snapshot()
    total_tokens = sum(
        (r["usage"] or {}).get("completion_tokens") or 0
        for r in rows if r)
    makespan = (max(e for e in ends if e) - t_start) if any(ends) else 0.0
    emit(out, {
        "arm": arm, "replicate": replicate, "section": "c32",
        "id": "aggregate", "ts": time.strftime("%FT%T%z"),
        "requests": len(rows), "responses": sum(1 for r in rows if r),
        "errors": sum(1 for r in rows if r and r.get("error")),
        "total_completion_tokens": total_tokens,
        "makespan_s": round(makespan, 3),
        "aggregate_tps": round(total_tokens / makespan, 3) if makespan else None,
        "first_submit_epoch": t_start,
        "submit_epochs": starts, "end_epochs": ends,
        "disk_before": before, "disk_after": after,
    })
    for r in rows:
        if r:
            emit(out, r)
    print(f"[{time.strftime('%T')}] c32: {total_tokens} tokens / "
          f"{makespan:.1f}s = {total_tokens / makespan if makespan else 0:.1f}"
          f" tok/s aggregate, errors="
          f"{sum(1 for r in rows if r and r.get('error'))}", flush=True)


def build_items(arm: str, replicate: int, section: str):
    if section == "cold":
        nonce = hashlib.sha256(f"cold-{replicate}".encode()).hexdigest()[:8]
        soup_a = soup_prompt(1000 + replicate, 1024) + f" Nonce {nonce}-a."
        soup_b = soup_prompt(2000 + replicate, 1024) + f" Nonce {nonce}-b."
        soup_c = soup_prompt(3000 + replicate, 96) + f" Nonce {nonce}-c."
        return [
            ("p1k-a", chat_body(soup_a, 1)),
            ("p1k-b", chat_body(soup_b, 1)),
            ("d64-c", chat_body(soup_c, 64)),
            ("d64-c-r", chat_body(soup_c, 64)),
        ]
    if section == "d1":
        return [(f"d1-{i:02d}", chat_body(p, 256))
                for i, p in enumerate(D1_PROMPTS)]
    if section == "p1":
        nonce = hashlib.sha256(f"p1-{replicate}".encode()).hexdigest()[:8]
        return [
            (f"p32k-{i}", chat_body(soup_prompt(4000 + 10 * i + replicate,
                                                32000) + f" Nonce {nonce}-{i}.", 1))
            for i in range(2)
        ]
    if section == "r1":
        return [(f"r1-{i}", chat_body(p, 768))
                for i, p in enumerate(R1_PROMPTS)]
    if section == "r2":
        block = r2_block(5000 + replicate, 130)  # ~3k tokens, ~50k rows
        instruction = ("\n\nThe list above is repeated three times. Output "
                       "the list exactly once more, starting with Item 1. "
                       "Output nothing else.")
        prompt = block + "\n\n" + block + "\n\n" + block + instruction
        return [(f"r2-{i}", chat_body(prompt, 512)) for i in range(1)]
    raise ValueError(section)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=("IQ4", "BF16"))
    ap.add_argument("--replicate", type=int, default=1)
    ap.add_argument("--port", type=int, default=15005)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rank0-pid-file",
                    default="/tmp/opencode/ple-p3-pair/rank0.pid")
    ap.add_argument("--rank1-pid-file",
                    default="/tmp/opencode/ple-p3-pair/rank1.pid")
    ap.add_argument("--host-b", default="strix2")
    ap.add_argument("--sections",
                    default="cold,canary,d1,p1,c32,r1,r2")
    args = ap.parse_args()

    disk = DiskCounters(args.rank0_pid_file, args.rank1_pid_file,
                        args.host_b)
    manifest = {
        "arm": args.arm, "replicate": args.replicate, "port": args.port,
        "sections": args.sections.split(","),
        "canary_gate_tps": CANARY_TPS,
        "canary_tokens": CANARY_TOKENS,
        "started": time.strftime("%FT%T%z"),
    }
    with open(args.out + ".manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")

    with open(args.out, "a") as out:
        for section in args.sections.split(","):
            section = section.strip()
            print(f"[{time.strftime('%T')}] === section {section} ===",
                  flush=True)
            if section == "canary":
                run_canary(out, args.port, args.arm, args.replicate, disk)
            elif section == "c32":
                run_c32(out, args.port, args.arm, args.replicate, disk)
            else:
                items = build_items(args.arm, args.replicate, section)
                run_serial(out, args.port, args.arm, args.replicate, section,
                           items, disk, None)
    manifest["finished"] = time.strftime("%FT%T%z")
    with open(args.out + ".manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print("done ->", args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
