#!/usr/bin/env python3
"""Phase-3 paired quality-screen client: run the pinned fixture battery
against one arm's server and record one JSON line per request.

Both arms run the identical battery (same fixtures, same order, same request
bodies); the only difference is the model pack behind the server. Per-request
timings and draft counters are captured from the response body (and joined
with the server's event=completed log lines afterwards).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ple_native_fixtures as fx  # noqa: E402

MODEL = "Qwen3.8-Flash-Next"


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


def emit(out, row: dict) -> None:
    out.write(json.dumps(row, sort_keys=True) + "\n")
    out.flush()


def summarize_choice(resp: dict) -> dict:
    choice = (resp.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = message.get("content")
    calls = []
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        calls.append({"name": fn.get("name"), "arguments": fn.get("arguments"),
                      "id": call.get("id")})
    return {
        "finish_reason": choice.get("finish_reason"),
        "content": content,
        "content_sha256": hashlib.sha256(
            (content or "").encode()).hexdigest() if content is not None else None,
        "tool_calls": calls,
        "reasoning_sha256": hashlib.sha256(
            (message.get("reasoning_content") or "").encode()).hexdigest()
        if message.get("reasoning_content") is not None else None,
        "reasoning_chars": len(message.get("reasoning_content") or ""),
    }


def run_section(out, port, arm, replicate, section, rows_meta) -> None:
    for meta in rows_meta:
        body = meta["body"]
        resp, wall_ms, err = post(port, body)
        row = {
            "arm": arm, "replicate": replicate, "section": section,
            "id": meta["id"], "ts": time.strftime("%FT%T%z"),
            "request_sha256": hashlib.sha256(
                json.dumps(body, sort_keys=True).encode()).hexdigest(),
            "body": {k: v for k, v in body.items() if k != "messages"} | {
                "messages_digest": hashlib.sha256(
                    json.dumps(body.get("messages", []), sort_keys=True).encode()
                ).hexdigest()},
            "prompt_chars": sum(len(m.get("content") or "") for m in body.get("messages", [])),
            "wall_ms": round(wall_ms, 3),
            "error": err,
            "usage": resp.get("usage"),
            "timings": resp.get("timings"),
            **summarize_choice(resp),
            **meta.get("expect", {}),
        }
        content = row.get("content") or ""
        row["suspect_nan"] = any(t in content.lower() for t in ("nan", "infinity", "undefined"))
        emit(out, row)


def build_bodies(arm: str, replicate: int, sections: list[str]) -> dict:
    """Assemble request bodies in fixed order for the requested sections."""
    ordered: dict[str, list] = {}

    if "needle" in sections:
        rows = []
        for item in fx.needle_fixtures(replicate):
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content": item["prompt"]}],
                "max_tokens": 64, "temperature": 0,
                "thinking": {"type": "disabled"},
            }
            rows.append({"id": item["id"], "body": body,
                         "expect": {"code": item["code"], "depth": item["depth"],
                                    "nonce": item["nonce"]}})
        ordered["needle"] = rows

    if "knowledge" in sections:
        rows = []
        for item in fx.knowledge_fixtures():
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content":
                              f"{item['question']} Answer in as few words as possible."}],
                "max_tokens": 96, "temperature": 0,
                "thinking": {"type": "disabled"},
            }
            rows.append({"id": item["id"], "body": body,
                         "expect": {"answer": item["answer"]}})
        ordered["knowledge"] = rows

    if "knowthink" in sections:
        rows = []
        for item in fx.knowledge_think_fixtures():
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content": item["question"]}],
                "max_tokens": 768, "temperature": 0,
            }
            rows.append({"id": item["id"], "body": body,
                         "expect": {"answer": item["answer"]}})
        ordered["knowthink"] = rows

    if "tools" in sections:
        rows = []
        for item in fx.tool_fixtures():
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content": item["user"]}],
                "tools": item["tools"], "tool_choice": "auto",
                "max_tokens": 256, "temperature": 0,
                "thinking": {"type": "disabled"},
            }
            rows.append({"id": item["id"], "body": body,
                         "expect": {"expect_calls": item["expect"],
                                    "mode": item["mode"]}})
        ordered["tools"] = rows

    if "mtp" in sections:
        rows = []
        for item in fx.mtp_fixtures():
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content": item["prompt"]}],
                "max_tokens": 256, "temperature": 0,
                "thinking": {"type": "disabled"},
            }
            rows.append({"id": item["id"], "body": body})
        ordered["mtp"] = rows

    if "det" in sections:
        rows = []
        for item in fx.determinism_fixtures():
            body = {
                "model": MODEL,
                "messages": [{"role": "user", "content": item["prompt"]}],
                "max_tokens": 128, "temperature": 0,
                "thinking": {"type": "disabled"},
            }
            for suffix in ("a", "b"):
                rows.append({"id": f"{item['id']}-{suffix}", "body": body,
                             "expect": {"pair": item["id"]}})
        ordered["det"] = rows

    return ordered


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, choices=("IQ4", "BF16"))
    ap.add_argument("--replicate", type=int, default=1)
    ap.add_argument("--port", type=int, default=15003)
    ap.add_argument("--out", required=True, help="output JSONL path")
    ap.add_argument("--sections", default="det,needle,knowledge,tools,knowthink,mtp",
                    help="comma list; order defines run order")
    args = ap.parse_args()

    sections = [s.strip() for s in args.sections.split(",") if s.strip()]
    ordered = build_bodies(args.arm, args.replicate, sections)

    manifest = {
        "arm": args.arm, "replicate": args.replicate, "port": args.port,
        "sections": sections, "fixture_sha256": hashlib.sha256(
            open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "ple_native_fixtures.py"), "rb").read()).hexdigest(),
        "started": time.strftime("%FT%T%z"),
        "counts": {k: len(v) for k, v in ordered.items()},
    }
    with open(args.out + ".manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")

    with open(args.out, "a") as out:
        for section in sections:
            rows = ordered[section]
            print(f"[{time.strftime('%T')}] section {section}: {len(rows)} requests",
                  flush=True)
            run_section(out, args.port, args.arm, args.replicate, section, rows)
    manifest["finished"] = time.strftime("%FT%T%z")
    with open(args.out + ".manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print("done ->", args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
