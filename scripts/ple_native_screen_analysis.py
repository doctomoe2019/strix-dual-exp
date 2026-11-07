#!/usr/bin/env python3
"""Phase-3 paired analysis of the quality screen.

Compares one IQ4 run and one BF16 run of ple_native_screen.py (same replicate,
identical fixture order) item by item:

  needle     per-depth exact-code accuracy, paired McNemar + bootstrap CI
  knowledge  exact-answer accuracy, paired McNemar + bootstrap CI
  knowthink  same, thinking enabled subset
  tools      exact tool-call protocol accuracy, paired McNemar + bootstrap CI
  mtp        per-request draft acceptance, paired deltas + bootstrap CI
  det        greedy determinism within arm and the cross-arm treatment effect
  timings    per-request wall/prefill/decode/ttft deltas against the 5% and
             3 ms discipline -- one verdict per request, never averaged

Scoring rules are fixed and identical for both arms; nothing is tuned on
outputs. Outputs a JSON summary plus a human-readable report.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from pathlib import Path

SLOWDOWN = 0.05
NOISE_MS = 3.0


# ---------------------------------------------------------------- stats ----
def binom_cdf(k: int, n: int, p: float = 0.5) -> float:
    return sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k + 1))


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value on discordant counts b, c."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    return min(1.0, 2.0 * binom_cdf(k, n))


def bootstrap_ci(pairs, rounds: int = 20000, seed: int = 20261017):
    """Percentile bootstrap CI of the mean of per-item deltas (0/1 or float)."""
    if not pairs:
        return None
    import random
    rng = random.Random(seed)
    n = len(pairs)
    means = []
    for _ in range(rounds):
        s = 0.0
        for _ in range(n):
            s += pairs[rng.randrange(n)]
        means.append(s / n)
    means.sort()
    lo = means[int(0.025 * rounds)]
    hi = means[min(rounds - 1, int(0.975 * rounds))]
    return lo, hi


def paired_means(pairs):
    if not pairs:
        return None
    a = statistics.mean(p[0] for p in pairs)
    b = statistics.mean(p[1] for p in pairs)
    sd = statistics.stdev([p[1] - p[0] for p in pairs]) if len(pairs) > 1 else 0.0
    t = ((b - a) / (sd / math.sqrt(len(pairs)))) if sd > 0 and len(pairs) > 1 else 0.0
    return {"n": len(pairs), "iq4": a, "bf16": b, "delta": b - a,
            "delta_sd": sd, "t_stat": t}


# ------------------------------------------------------------- scoring ----
_WORD = re.compile(r"[a-z0-9.]+")


def normalize(text: str) -> str:
    return " ".join(_WORD.findall((text or "").lower().replace(",", " ")))


def score_needle(row) -> tuple[bool, dict]:
    code = str(row["code"])
    content = row.get("content") or ""
    digits = re.sub(r"[^0-9]", "", content)
    passed = code in digits and code in content.replace(" ", "")
    return passed, {"content_head": content[:120].replace("\n", " "),
                    "code": code}


def score_knowledge(row) -> tuple[bool, dict]:
    answer = row["answer"]
    hay = normalize(row.get("content") or "")
    needle = normalize(answer)
    ok = bool(needle) and needle in hay
    if not ok:
        stripped = hay.replace(".", "").replace(",", "")
        ok = needle.replace(".", "").replace(",", "") in stripped
    return ok, {"answer": answer,
                "content_head": (row.get("content") or "")[:100].replace("\n", " ")}


def score_tool(row) -> tuple[bool, dict]:
    expect = row["expect_calls"]
    mode = row.get("mode", "single")
    calls = row.get("tool_calls") or []
    detail = {
        "finish": row.get("finish_reason"),
        "got": [(c.get("name"), c.get("arguments")) for c in calls],
        "want": expect,
    }
    if row.get("error"):
        return False, detail
    if mode == "loose_sql":
        if row.get("finish_reason") != "tool_calls" or len(calls) != 1:
            return False, detail
        args = json.loads(calls[0].get("arguments") or "{}")
        joined = json.dumps(args).lower()
        ok = ("count(*)" in joined.replace("count (*)", "count(*)")
              and "users" in joined and "created_at" in joined)
        return ok, detail
    names_ok = sorted((c.get("name") or "") for c in calls) == \
        sorted(name for name, _ in expect)
    if not names_ok:
        return False, detail
    for call, (_, want_args) in zip(sorted(calls, key=lambda c: c.get("name") or ""),
                                    sorted(expect, key=lambda e: e[0])):
        try:
            got_args = json.loads(call.get("arguments") or "{}")
        except json.JSONDecodeError:
            return False, detail
        if not args_equal(got_args, want_args):
            detail["mismatch"] = {"got": got_args, "want": want_args}
            return False, detail
    return True, detail


def args_equal(got, want) -> bool:
    if not isinstance(got, dict) or not isinstance(want, dict):
        return False
    for key, value in want.items():
        if key not in got:
            return False
        have = got[key]
        if isinstance(value, dict):
            if not args_equal(have, value):
                return False
        elif isinstance(value, bool) or isinstance(have, bool):
            if have != value:
                return False
        elif isinstance(value, (int, float)) and isinstance(have, (int, float)):
            if abs(float(have) - float(value)) > 1e-9:
                return False
        elif normalize(str(have)) != normalize(str(value)):
            return False
    return True


# ------------------------------------------------------------- pipeline ----
def load(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return rows


def by_id(rows: list[dict]) -> dict:
    out = {}
    for row in rows:
        out[row["id"]] = row
    return out


def paired_section(iq4: dict, bf16: dict, ids: list[str], scorer):
    disc = {"both_right": 0, "both_wrong": 0, "iq4_only": 0, "bf16_only": 0}
    pairs = []
    details = []
    for rid in ids:
        a, b = iq4.get(rid), bf16.get(rid)
        if not a or not b:
            continue
        ra, da = scorer(a)
        rb, db = scorer(b)
        sa, sb = bool(ra), bool(rb)
        if isinstance(da, bool) or not isinstance(da, dict):
            da = {"pass": sa}
        if isinstance(db, bool) or not isinstance(db, dict):
            db = {"pass": sb}
        pairs.append((1.0 if sa else 0.0, 1.0 if sb else 0.0))
        if sa and sb:
            disc["both_right"] += 1
        elif not sa and not sb:
            disc["both_wrong"] += 1
        elif sb:
            disc["bf16_only"] += 1
        else:
            disc["iq4_only"] += 1
        details.append({"id": rid, "iq4": da, "bf16": db})
    n = len(pairs)
    acc_a = sum(p[0] for p in pairs) / n if n else float("nan")
    acc_b = sum(p[1] for p in pairs) / n if n else float("nan")
    deltas = [p[1] - p[0] for p in pairs]
    ci = bootstrap_ci(deltas)
    return {
        "n": n, "iq4_acc": acc_a, "bf16_acc": acc_b, "delta": acc_b - acc_a,
        "discordant": disc,
        "mcnemar_p": mcnemar_exact(disc["iq4_only"], disc["bf16_only"]),
        "delta_ci95": ci, "details": details,
    }


def timing_pairs(iq4: dict, bf16: dict, ids: list[str], field_path):
    out = []
    for rid in ids:
        a, b = iq4.get(rid), bf16.get(rid)
        if not a or not b:
            continue
        va, vb = dig(a, field_path), dig(b, field_path)
        if va is None or vb is None:
            continue
        margin = max(NOISE_MS, min(va, vb) * SLOWDOWN)
        out.append({
            "id": rid, "iq4": va, "bf16": vb, "delta": vb - va,
            "delta_pct": (vb - va) / va * 100.0 if va else float("nan"),
            "exceeds_margin": (vb - va) > margin, "margin": margin,
        })
    return out


def dig(row, path):
    cur = row
    for key in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur if isinstance(cur, (int, float)) else None


def acceptance(row):
    u = row.get("usage") or {}
    draft, accepted = u.get("draft_tokens"), u.get("draft_tokens_accepted")
    if not draft:
        return None
    return 100.0 * accepted / draft


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True, type=Path)
    ap.add_argument("--bf16", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    rows_a = load(args.iq4)
    rows_b = load(args.bf16)
    a, b = by_id(rows_a), by_id(rows_b)
    ids = lambda sec: [r["id"] for r in rows_a if r["section"] == sec]  # noqa: E731
    report: dict = {"iq4_run": str(args.iq4), "bf16_run": str(args.bf16),
                    "tolerance": {"slowdown": SLOWDOWN, "noise_ms": NOISE_MS}}

    report["nan_screen"] = {
        "iq4_suspect": [r["id"] for r in rows_a if r.get("suspect_nan")],
        "bf16_suspect": [r["id"] for r in rows_b if r.get("suspect_nan")],
        "iq4_errors": [r["id"] for r in rows_a if r.get("error")],
        "bf16_errors": [r["id"] for r in rows_b if r.get("error")],
    }

    if ids("needle"):
        needle = {}
        depths = sorted({r["depth"] for r in rows_a if r["section"] == "needle"})
        for depth in depths:
            dids = [r["id"] for r in rows_a
                    if r["section"] == "needle" and r["depth"] == depth]
            needle[f"d{depth}"] = paired_section(a, b, dids, score_needle)
        needle["overall"] = paired_section(a, b, ids("needle"), score_needle)
        report["needle"] = needle
        # per-depth token cost (actual prompt depth reached)
        report["needle_depth_actual"] = {
            f"d{d}": {
                "iq4_prompt_tokens": [ (a.get(r['id']) or {}).get('usage', {}).get('prompt_tokens') for r in rows_a if r['section']=='needle' and r['depth']==d ],
            } for d in depths}

    if ids("knowledge"):
        report["knowledge"] = paired_section(a, b, ids("knowledge"), score_knowledge)
    if ids("knowthink"):
        report["knowthink"] = paired_section(a, b, ids("knowthink"), score_knowledge)
    if ids("tools"):
        report["tools"] = paired_section(a, b, ids("tools"), score_tool)

    if ids("mtp"):
        mtp_ids = ids("mtp")
        acc_pairs = []
        for rid in mtp_ids:
            ra, rb = acceptance(a.get(rid) or {}), acceptance(b.get(rid) or {})
            if ra is not None and rb is not None:
                acc_pairs.append((ra, rb))
        pm = paired_means(acc_pairs)
        ci = bootstrap_ci([p[1] - p[0] for p in acc_pairs])
        report["mtp_acceptance"] = {
            "per_request": [
                {"id": rid, "iq4": acceptance(a.get(rid) or {}),
                 "bf16": acceptance(b.get(rid) or {})} for rid in mtp_ids],
            "summary": pm, "delta_ci95": ci,
            "unit": "percent of draft tokens accepted",
        }

    if ids("det"):
        det = {}
        for arm, rows in (("iq4", rows_a), ("bf16", rows_b)):
            pairs = by_id([r for r in rows if r["section"] == "det"])
            within = []
            for rid in {r.get("pair") for r in rows if r["section"] == "det"}:
                pa, pb = pairs.get(f"{rid}-a"), pairs.get(f"{rid}-b")
                if pa and pb:
                    within.append({"id": rid,
                                   "identical": pa["content_sha256"] == pb["content_sha256"]})
            det[arm] = {"within_session": within,
                        "all_identical": all(x["identical"] for x in within)}
        # cross-arm treatment effect on the same deterministic prompts
        cross = []
        for rid in ids("det"):
            ra, rb = a.get(rid), b.get(rid)
            if ra and rb:
                cross.append({"id": rid,
                              "identical": ra["content_sha256"] == rb["content_sha256"],
                              "iq4_head": (ra.get("content") or "")[:80],
                              "bf16_head": (rb.get("content") or "")[:80]})
        det["cross_arm"] = cross
        report["determinism"] = det

    # Per-request timings for every shared request (never averaged; medians
    # are descriptive only).
    timings = {}
    for field in ("wall_ms", "usage.gufo.ttft_ms", "usage.gufo.prefill_ms",
                  "usage.gufo.decode_ms"):
        rows = timing_pairs(a, b, [r["id"] for r in rows_a], field)
        if rows:
            med_iq4 = statistics.median([r["iq4"] for r in rows])
            med_bf16 = statistics.median([r["bf16"] for r in rows])
            timings[field] = {
                "per_request": rows, "n": len(rows),
                "median_iq4": med_iq4, "median_bf16": med_bf16,
                "exceeds_margin_count": sum(r["exceeds_margin"] for r in rows),
            }
    report["timings"] = timings

    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    # Human summary
    print(f"== paired screen {args.iq4} vs {args.bf16}")
    for name in ("needle", "knowledge", "knowthink", "tools"):
        if name in report:
            if name == "needle":
                for depth, block in report["needle"].items():
                    if depth == "overall":
                        continue
                    show(f"needle/{depth}", block)
                show("needle/overall", report["needle"]["overall"])
            else:
                show(name, report[name])
    if "mtp_acceptance" in report:
        s = report["mtp_acceptance"]["summary"]
        print(f"mtp acceptance: IQ4 {s['iq4']:.2f}% BF16 {s['bf16']:.2f}% "
              f"delta {s['delta']:+.3f} CI95 {fmt_ci(report['mtp_acceptance']['delta_ci95'])}")
    print(f"nan/errors: {report['nan_screen']}")
    if "determinism" in report:
        for arm in ("iq4", "bf16"):
            print(f"determinism {arm}: all_identical={report['determinism'][arm]['all_identical']}")
        n_same = sum(x["identical"] for x in report["determinism"]["cross_arm"])
        print(f"determinism cross-arm identical outputs: {n_same}/{len(report['determinism']['cross_arm'])}")
    for field, block in timings.items():
        print(f"timing {field}: n={block['n']} median {block['median_iq4']:.1f} -> "
              f"{block['median_bf16']:.1f} ms; exceeds-margin requests: "
              f"{block['exceeds_margin_count']}/{block['n']}")
    print("wrote", args.out)
    return 0


def show(name: str, block: dict) -> None:
    d = block["discordant"]
    ci = block["delta_ci95"]
    print(f"{name}: n={block['n']} IQ4 {block['iq4_acc']*100:.1f}% "
          f"BF16 {block['bf16_acc']*100:.1f}% delta {block['delta']*100:+.2f}pp "
          f"CI95 [{ci[0]*100:+.2f}, {ci[1]*100:+.2f}]pp "
          f"mcnemar p={block['mcnemar_p']:.4f} "
          f"(iq4_only={d['iq4_only']} bf16_only={d['bf16_only']} "
          f"both_right={d['both_right']} both_wrong={d['both_wrong']})")


def fmt_ci(ci):
    if not ci:
        return "n/a"
    return f"[{ci[0]:+.3f}, {ci[1]:+.3f}]"


if __name__ == "__main__":
    raise SystemExit(main())
