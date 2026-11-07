#!/usr/bin/env python3
"""Phase-4 paired analysis of the performance battery.

Reads one IQ4 and one BF16 run of ple_native_perf.py per replicate (same
replicate number = identical request bodies, verified by request_sha256) and
emits per-criterion tables and verdicts:

  canary   the production gate protocol (8192-token uncached prefill) against
           the SERVE_CANARY_TPS=1700 adoption gate
  prefill  canary cycles + deep 32k prompts, per-request 5% band
  decode1  concurrency-1 decode: per-request rate + TTFT verdicts (5%/3ms)
  decode32 concurrency-32 aggregate and per-request verdicts
  cold     cold first-gather cost (first requests after start) and disk bytes
  repet    repetitive decode (r1 small working set, r2 cache-pressure echo):
           decode rate, inter-token latencies, measured disk traffic
  disk     measured bytes/token per section (never assumed)

Verdicts follow the repo discipline: one verdict per request/phase at 5% and
3 ms, never averaged across requests.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path

SLOWDOWN = 0.05
NOISE_MS = 3.0
GATE_TPS = 1700


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()
            if line.strip()]


def key(row) -> tuple:
    return (row.get("replicate"), row.get("section"), row.get("id"))


def index(rows: list[dict]) -> dict:
    return {key(r): r for r in rows}


def dig(row, path):
    cur = row
    for part in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur if isinstance(cur, (int, float)) and not isinstance(cur, bool) \
        else None


def fmt(v, nd=1):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def rate_verdict(iq4, bf16):
    """Per-request verdict on a higher-is-better rate."""
    if iq4 is None or bf16 is None or iq4 <= 0:
        return None
    margin = iq4 * SLOWDOWN
    delta = bf16 - iq4
    if delta < -margin:
        return "BF16_SLOWER_THAN_5PCT"
    if delta > margin:
        return "BF16_FASTER_THAN_5PCT"
    return "WITHIN_5PCT"


def ms_verdict(iq4, bf16):
    """Per-request verdict on a lower-is-better latency (3 ms / 5%)."""
    if iq4 is None or bf16 is None:
        return None
    margin = max(NOISE_MS, min(iq4, bf16) * SLOWDOWN)
    delta = bf16 - iq4
    if delta > margin:
        return "BF16_SLOWER_THAN_MARGIN"
    if delta < -margin:
        return "BF16_FASTER_THAN_MARGIN"
    return "WITHIN_MARGIN"


def pair_sections(rows_a, rows_b, section):
    a = {key(r): r for r in rows_a if r.get("section") == section}
    b = {key(r): r for r in rows_b if r.get("section") == section}
    ids = sorted(set(a) & set(b))
    return a, b, ids


def disk_delta(row) -> int | None:
    before, after = row.get("disk_before") or {}, row.get("disk_after") or {}
    total = 0
    seen = False
    for rank in ("r0", "r1"):
        rb, ra = before.get(rank), after.get(rank)
        if rb and ra and "read_bytes" in rb and "read_bytes" in ra:
            total += ra["read_bytes"] - rb["read_bytes"]
            seen = True
    return total if seen else None


def section_disk_bytes(rows, section) -> int | None:
    """Sum of request-level deltas, or the section-aggregate row's delta."""
    reqs = [r for r in rows if r.get("section") == section
            and r.get("id") != "aggregate"]
    deltas = [d for d in (disk_delta(r) for r in reqs) if d is not None]
    if deltas:
        return sum(deltas)
    agg = next((r for r in rows if r.get("section") == section
                and r.get("id") == "aggregate"), None)
    if agg:
        d = disk_delta(agg)
        if d is not None:
            return d
    return None if not deltas else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True, type=Path, nargs="+",
                    help="IQ4 JSONL runs (one per replicate)")
    ap.add_argument("--bf16", required=True, type=Path, nargs="+",
                    help="BF16 JSONL runs, same replicate order")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--report", required=True, type=Path)
    args = ap.parse_args()

    rows_a: list[dict] = []
    rows_b: list[dict] = []
    for pa, pb in zip(args.iq4, args.bf16):
        rows_a.extend(load(pa))
        rows_b.extend(load(pb))
    a, b = index(rows_a), index(rows_b)

    # Pairing integrity: identical request bodies within a replicate.
    mismatches = []
    for k in sorted(set(a) & set(b)):
        if a[k].get("request_sha256") and a[k]["request_sha256"] != \
                b[k].get("request_sha256"):
            mismatches.append(k)

    report: dict = {
        "tolerance": {"slowdown": SLOWDOWN, "noise_ms": NOISE_MS,
                      "gate_tps": GATE_TPS},
        "runs": {"iq4": [str(p) for p in args.iq4],
                 "bf16": [str(p) for p in args.bf16]},
        "pairing": {"paired_keys": len(set(a) & set(b)),
                    "request_sha256_mismatches": mismatches},
        "errors": {
            "iq4": [k for k in sorted(a) if a[k].get("error")],
            "bf16": [k for k in sorted(b) if b[k].get("error")],
        },
    }
    text: list[str] = []
    text.append("Phase-4 performance A/B, paired per request "
                f"(5% / {NOISE_MS:.0f} ms discipline)")
    text.append(f"paired keys: {len(set(a) & set(b))}; "
                f"request-sha mismatches: {len(mismatches)}")

    # ------------------------------------------------------------- canary --
    canary = {"cycles": [], "gate": GATE_TPS}
    for k in sorted(set(a) & set(b)):
        if a[k].get("section") != "canary":
            continue
        ra, rb = a[k], b[k]
        canary["cycles"].append({
            "replicate": k[0], "cycle": k[2],
            "iq4_tps": ra.get("prefill_tps"), "bf16_tps": rb.get("prefill_tps"),
            "iq4_verdict": ra.get("verdict"), "bf16_verdict": rb.get("verdict"),
            "bf16_rc": rb.get("rc"),
        })
    measured = [c for c in canary["cycles"] if c["cycle"] != "warmup"]
    canary["iq4_measured_min"] = min((c["iq4_tps"] for c in measured
                                      if c["iq4_tps"] is not None), default=None)
    canary["bf16_measured_min"] = min((c["bf16_tps"] for c in measured
                                       if c["bf16_tps"] is not None), default=None)
    canary["bf16_gate_holds"] = all(
        c["bf16_tps"] is not None and c["bf16_tps"] >= GATE_TPS
        for c in measured) if measured else None
    canary["bf16_worst_margin_pct"] = (
        (canary["bf16_measured_min"] / GATE_TPS - 1) * 100.0
        if canary["bf16_measured_min"] is not None else None)
    report["canary"] = canary
    text.append("\n== canary (production gate protocol, 8192-token uncached "
                f"prefill, gate {GATE_TPS} tok/s) ==")
    for c in canary["cycles"]:
        text.append(
            f"  r{c['replicate']} {c['cycle']:<6} IQ4 {fmt(c['iq4_tps'])} "
            f"tok/s ({c['iq4_verdict']}) | BF16 {fmt(c['bf16_tps'])} tok/s "
            f"({c['bf16_verdict']}, rc={c['bf16_rc']})")
    text.append(f"  BF16 measured-cycle min {fmt(canary['bf16_measured_min'])}"
                f" tok/s -> gate holds: {canary['bf16_gate_holds']} "
                f"(worst margin {fmt(canary['bf16_worst_margin_pct'])}%)")

    # ------------------------------------------------- rate/ms pair tables --
    def pair_table(section, fields):
        ia, ib, ids = pair_sections(rows_a, rows_b, section)
        out = {}
        for label, path, kind in fields:
            verdicts = {}
            pairs = []
            for k in ids:
                va, vb = dig(ia.get(k) or {}, path), dig(ib.get(k) or {}, path)
                if va is None or vb is None:
                    continue
                verdict = (ms_verdict(va, vb) if kind == "ms"
                           else rate_verdict(va, vb))
                verdicts[verdict] = verdicts.get(verdict, 0) + 1
                pairs.append({"replicate": k[0], "id": k[2], "iq4": va,
                              "bf16": vb, "delta": vb - va,
                              "delta_pct": (vb - va) / va * 100.0 if va else None,
                              "verdict": verdict})
            out[label] = {
                "n": len(pairs), "verdicts": verdicts, "pairs": pairs,
                "iq4_median": statistics.median(p["iq4"] for p in pairs)
                if pairs else None,
                "bf16_median": statistics.median(p["bf16"] for p in pairs)
                if pairs else None,
            }
        return out

    # ------------------------------------------------------------- prefill --
    p1 = pair_table("p1", [("prompt_tokens_per_second",
                            "usage.prompt_tokens_per_second", "rate")])
    for c in canary["cycles"]:
        if c["cycle"] == "warmup" or c["iq4_tps"] is None:
            continue
        verdict = rate_verdict(c["iq4_tps"], c["bf16_tps"])
        p1["canary_verdicts"] = p1.get("canary_verdicts", {})
        p1["canary_verdicts"][verdict] = \
            p1["canary_verdicts"].get(verdict, 0) + 1
    report["prefill"] = p1
    text.append("\n== prefill ==")
    if "canary_verdicts" in p1:
        text.append(f"  canary measured cycles (paired vs gate-protocol runs):"
                    f" {p1['canary_verdicts']}")
    for label, t in p1.items():
        if label == "canary_verdicts":
            continue
        text.append(
            f"  p1 {label}: n={t['n']} "
            f"IQ4 median {fmt(t['iq4_median'])} BF16 median "
            f"{fmt(t['bf16_median'])} | verdicts {t['verdicts']}")

    # -------------------------------------------------------------- decode --
    d1 = pair_table("d1", [
        ("decode_tps", "usage.completion_tokens_per_second", "rate"),
        ("ttft_ms", "usage.gufo.ttft_ms", "ms"),
        ("mean_inter_token_ms", "usage.gufo.mean_inter_token_ms", "ms"),
        ("max_inter_token_ms", "usage.gufo.max_inter_token_ms", "ms"),
    ])
    report["decode_c1"] = d1

    # ------------------------------------------------------------- decode32 --
    c32 = {"aggregate": [], "per_request": pair_table("c32", [
        ("decode_tps", "usage.completion_tokens_per_second", "rate"),
        ("ttft_ms", "usage.gufo.ttft_ms", "ms"),
        ("queue_ms", "usage.gufo.queue_ms", "ms"),
    ])}
    for rows, arm in ((rows_a, "iq4"), (rows_b, "bf16")):
        for r in rows:
            if r.get("section") == "c32" and r.get("id") == "aggregate":
                c32["aggregate"].append({
                    "arm": arm, "replicate": r.get("replicate"),
                    "tokens": r.get("total_completion_tokens"),
                    "makespan_s": r.get("makespan_s"),
                    "aggregate_tps": r.get("aggregate_tps"),
                    "errors": r.get("errors"),
                })
    report["decode_c32"] = c32

    # ---------------------------------------------------------------- cold --
    cold = {"requests": []}
    for k in sorted(set(a) & set(b)):
        if a[k].get("section") != "cold":
            continue
        ra, rb = a[k], b[k]
        cold["requests"].append({
            "replicate": k[0], "id": k[2],
            "iq4_ttft_ms": dig(ra, "usage.gufo.ttft_ms"),
            "bf16_ttft_ms": dig(rb, "usage.gufo.ttft_ms"),
            "iq4_prompt_tps": dig(ra, "usage.prompt_tokens_per_second"),
            "bf16_prompt_tps": dig(rb, "usage.prompt_tokens_per_second"),
            "iq4_mean_inter_ms": dig(ra, "usage.gufo.mean_inter_token_ms"),
            "bf16_mean_inter_ms": dig(rb, "usage.gufo.mean_inter_token_ms"),
            "iq4_max_inter_ms": dig(ra, "usage.gufo.max_inter_token_ms"),
            "bf16_max_inter_ms": dig(rb, "usage.gufo.max_inter_token_ms"),
            "iq4_disk_bytes": disk_delta(ra),
            "bf16_disk_bytes": disk_delta(rb),
            "iq4_cached": dig(ra, "usage.cached_tokens"),
            "bf16_cached": dig(rb, "usage.cached_tokens"),
        })
    report["cold"] = cold

    # --------------------------------------------------------------- repet --
    repet = {}
    for section in ("r1", "r2"):
        tab = pair_table(section, [
            ("decode_tps", "usage.completion_tokens_per_second", "rate"),
            ("mean_inter_token_ms", "usage.gufo.mean_inter_token_ms", "ms"),
            ("max_inter_token_ms", "usage.gufo.max_inter_token_ms", "ms"),
        ])
        disk = {}
        for rows, arm in ((rows_a, "iq4"), (rows_b, "bf16")):
            total = section_disk_bytes(rows, section)
            tokens = sum(dig(r, "usage.completion_tokens") or 0 for r in rows
                         if r.get("section") == section
                         and r.get("id") != "aggregate")
            disk[arm] = {"bytes": total, "completion_tokens": tokens,
                         "bytes_per_token": total / tokens if total and tokens
                         else None}
        tab["disk"] = disk
        repet[section] = tab
    report["repetitive"] = repet

    # ---------------------------------------------------------------- disk --
    disk_tbl = {}
    for section in ("cold", "d1", "c32", "r1", "r2"):
        entry = {}
        for rows, arm in ((rows_a, "iq4"), (rows_b, "bf16")):
            total = section_disk_bytes(rows, section)
            tokens = sum(dig(r, "usage.completion_tokens") or 0 for r in rows
                         if r.get("section") == section
                         and r.get("id") != "aggregate")
            ptokens = sum(dig(r, "usage.prompt_tokens") or 0 for r in rows
                          if r.get("section") == section
                          and r.get("id") != "aggregate")
            entry[arm] = {
                "bytes": total,
                "completion_tokens": tokens,
                "prompt_tokens": ptokens,
                "bytes_per_completion_token":
                    total / tokens if total and tokens else None,
            }
        disk_tbl[section] = entry
    report["disk_traffic"] = disk_tbl

    # --------------------------------------------------------- text digest --
    text.append("\n== decode concurrency 1 (d1, 8x256 tokens) ==")
    for label, t in d1.items():
        text.append(f"  {label}: n={t['n']} IQ4 median {fmt(t['iq4_median'], 2)}"
                    f" BF16 median {fmt(t['bf16_median'], 2)} | {t['verdicts']}")
    text.append("\n== decode concurrency 32 (32x256 tokens) ==")
    for entry in c32["aggregate"]:
        text.append(f"  r{entry['replicate']} {entry['arm']}: "
                    f"{entry['tokens']} tok / {fmt(entry['makespan_s'])} s = "
                    f"{fmt(entry['aggregate_tps'])} tok/s aggregate "
                    f"(errors={entry['errors']})")
    for label, t in c32["per_request"].items():
        text.append(f"  per-request {label}: n={t['n']} IQ4 median "
                    f"{fmt(t['iq4_median'], 2)} BF16 median "
                    f"{fmt(t['bf16_median'], 2)} | {t['verdicts']}")
    text.append("\n== cold first requests ==")
    for r in cold["requests"]:
        text.append(
            f"  r{r['replicate']} {r['id']}: ttft IQ4 {fmt(r['iq4_ttft_ms'], 0)}"
            f" / BF16 {fmt(r['bf16_ttft_ms'], 0)} ms | prompt tps IQ4 "
            f"{fmt(r['iq4_prompt_tps'])} / BF16 {fmt(r['bf16_prompt_tps'])}"
            f" | disk IQ4 {r['iq4_disk_bytes']} / BF16 {r['bf16_disk_bytes']}"
            f" B | cached IQ4 {r['iq4_cached']} / BF16 {r['bf16_cached']}"
            + (f" | inter-token mean IQ4 {fmt(r['iq4_mean_inter_ms'], 2)} /"
               f" BF16 {fmt(r['bf16_mean_inter_ms'], 2)} ms, max IQ4"
               f" {fmt(r['iq4_max_inter_ms'], 1)} / BF16"
               f" {fmt(r['bf16_max_inter_ms'], 1)} ms"
               if r["iq4_mean_inter_ms"] is not None else ""))
    text.append("\n== repetitive decode ==")
    for section in ("r1", "r2"):
        t = repet[section]
        d = t["disk"]
        text.append(f"  {section}: " + " | ".join(
            f"{label}: n={t[label]['n']} IQ4 med {fmt(t[label]['iq4_median'], 2)}"
            f" BF16 med {fmt(t[label]['bf16_median'], 2)} {t[label]['verdicts']}"
            for label in ("decode_tps", "mean_inter_token_ms",
                          "max_inter_token_ms")))
        text.append(
            f"    disk: IQ4 {d['iq4']['bytes']} B "
            f"({fmt(d['iq4']['bytes_per_token'], 1)} B/tok), BF16 "
            f"{d['bf16']['bytes']} B ({fmt(d['bf16']['bytes_per_token'], 1)}"
            f" B/tok) over {d['bf16']['completion_tokens']} tokens")
    text.append("\n== measured disk traffic (rank0+rank1 read_bytes) ==")
    for section, entry in disk_tbl.items():
        text.append(
            f"  {section}: IQ4 {entry['iq4']['bytes']} B "
            f"({fmt(entry['iq4']['bytes_per_completion_token'], 1)} B/tok) | "
            f"BF16 {entry['bf16']['bytes']} B "
            f"({fmt(entry['bf16']['bytes_per_completion_token'], 1)} B/tok)")

    args.out.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    args.report.write_text("\n".join(text) + "\n")
    print("\n".join(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
