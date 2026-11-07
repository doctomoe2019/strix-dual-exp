#!/usr/bin/env python3
"""Phase-4 pooled quality analysis across replicates.

Reads the phase-3 screen runs (r1, r2) and the phase-4 full-battery runs
(r3, r4) and pools every paired item: needle, knowledge, knowthink and
tools panels with pooled McNemar exact tests and bootstrap CIs; MTP
acceptance pooled over paired requests; det determinism within and
across arms; per-request timing verdicts counted per direction. Scoring is
imported from ple_native_screen_analysis so the rules stay the ones fixed
before the first phase-3 arm ran.

Determinism discipline (fix round 1): sections whose request bodies are
identical across replicates (knowledge, knowthink, tools, mtp) reproduce
the same greedy outcome every replicate -- verified per item at run time --
so their inference units are deduplicated to unique items. Pooling all
(replicate, id) observations for those sections would shrink CIs by
~sqrt(n_replicates) from pseudo-replication. Needle keeps every
(replicate, id) observation because its nonces differ per replicate: each
is a fresh, genuinely independent sample of the same task. Both the
deduplicated and the pooled-observation counts are reported.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ple_native_screen_analysis as sa  # noqa: E402


def load(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()
            if line.strip()]


def pooled_panel(rows_a, rows_b, section, scorer, dedup=False):
    """Pair every (replicate, id); needle/knowledge/tools/knowthink.

    dedup=True collapses observations that are deterministic copies of the
    same item: sections whose request bodies are identical across replicates
    (knowledge, knowthink, tools) reproduce the same greedy outcome every
    replicate, so pooling all (replicate, id) pairs is pseudo-replication
    that shrinks CIs by ~sqrt(n_replicates) without adding information. The
    honest unit is the unique item id; if any item ever disagrees across
    replicates the item is kept once per distinct outcome and the report
    flags it."""
    def idx(rows):
        return {(r["replicate"], r["id"]): r for r in rows
                if r["section"] == section}
    a, b = idx(rows_a), idx(rows_b)
    keys = sorted(set(a) & set(b))

    def score(keys):
        disc = {"both_right": 0, "both_wrong": 0, "iq4_only": 0,
                "bf16_only": 0}
        pairs, details = [], []
        for k in keys:
            ra, rb = a[k], b[k]
            va, da = scorer(ra)
            vb, db = scorer(rb)
            sa_flag, sb_flag = bool(va), bool(vb)
            pairs.append((1.0 if sa_flag else 0.0, 1.0 if sb_flag else 0.0))
            if sa_flag and sb_flag:
                disc["both_right"] += 1
            elif not sa_flag and not sb_flag:
                disc["both_wrong"] += 1
            elif sb_flag:
                disc["bf16_only"] += 1
            else:
                disc["iq4_only"] += 1
            details.append({
                "replicate": k[0], "id": k[1],
                "iq4": {"pass": sa_flag,
                        **(da if isinstance(da, dict) else {})},
                "bf16": {"pass": sb_flag,
                         **(db if isinstance(db, dict) else {})}})
        return pairs, disc, details

    full_pairs, _, _ = score(keys)
    if dedup:
        # Verify the deterministic-copy assumption per item id.
        disagreements = []
        for table, name in ((a, "iq4"), (b, "bf16")):
            by_id = {}
            for k in keys:
                by_id.setdefault(k[1], []).append(table[k])
            for item_id, group in by_id.items():
                outs = {bool(scorer(r)[0]) for r in group}
                if len(outs) > 1:
                    disagreements.append(f"{name}:{item_id}")
        dedup_keys = sorted(
            (min(k[0] for k in keys if k[1] == item_id), item_id)
            for item_id in {k[1] for k in keys})
        pairs, disc, details = score(dedup_keys)
        dedup_note = {
            "unit": "unique item id (deterministic replicates collapsed)",
            "n_observations_pooled": len(keys),
            "cross_replicate_disagreements": disagreements,
        }
    else:
        pairs, disc, details = score(keys)
        dedup_note = {"unit": "(replicate, id) observation",
                      "n_observations_pooled": len(keys)}
    n = len(pairs)
    out = {
        "n": n,
        "sampling": dedup_note,
        "iq4_acc": sum(p[0] for p in pairs) / n if n else None,
        "bf16_acc": sum(p[1] for p in pairs) / n if n else None,
        "discordant": disc,
        "mcnemar_p": sa.mcnemar_exact(disc["iq4_only"], disc["bf16_only"]),
        "per_replicate": {},
        "details": details,
    }
    if n:
        out["delta"] = out["bf16_acc"] - out["iq4_acc"]
        out["delta_ci95"] = sa.bootstrap_ci([p[1] - p[0] for p in pairs])
    for rep in sorted({k[0] for k in keys}):
        sub = [p for k, p in zip(keys, full_pairs) if k[0] == rep]
        out["per_replicate"][rep] = {
            "n": len(sub),
            "iq4_acc": sum(p[0] for p in sub) / len(sub) if sub else None,
            "bf16_acc": sum(p[1] for p in sub) / len(sub) if sub else None,
        }
    return out


def timing_counts(rows_a, rows_b, path, kind):
    def idx(rows):
        return {(r["replicate"], r["section"], r["id"]): r for r in rows}
    a, b = idx(rows_a), idx(rows_b)
    verdicts = {}
    worst = None
    for k in sorted(set(a) & set(b)):
        va, vb = sa.dig(a[k], path), sa.dig(b[k], path)
        if va is None or vb is None:
            continue
        # reuse the exact margin rule from the phase-3 analysis
        margin = max(sa.NOISE_MS, min(va, vb) * sa.SLOWDOWN)
        delta = vb - va
        if kind == "ms":
            label = ("BF16_SLOWER" if delta > margin
                     else "BF16_FASTER" if delta < -margin else "WITHIN")
        else:
            margin = va * sa.SLOWDOWN
            label = ("BF16_SLOWER" if delta < -margin
                     else "BF16_FASTER" if delta > margin else "WITHIN")
        verdicts[label] = verdicts.get(label, 0) + 1
        pct = (vb - va) / va * 100.0 if va else 0.0
        if worst is None or abs(pct) > abs(worst["delta_pct"]):
            worst = {"key": list(k), "iq4": va, "bf16": vb,
                     "delta_pct": pct}
    return {"verdicts": verdicts, "worst": worst}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True, type=Path, nargs="+")
    ap.add_argument("--bf16", required=True, type=Path, nargs="+")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--report", required=True, type=Path)
    args = ap.parse_args()

    rows_a, rows_b = [], []
    for p in args.iq4:
        rows_a.extend(load(p))
    for p in args.bf16:
        rows_b.extend(load(p))

    # Pairing integrity per replicate: identical request digests.
    bad = []
    ia = {(r["replicate"], r["section"], r["id"]): r for r in rows_a}
    ib = {(r["replicate"], r["section"], r["id"]): r for r in rows_b}
    for k in sorted(set(ia) & set(ib)):
        if ia[k].get("request_sha256") != ib[k].get("request_sha256"):
            bad.append(list(k))

    report = {
        "runs": {"iq4": [str(p) for p in args.iq4],
                 "bf16": [str(p) for p in args.bf16]},
        "requests": {"iq4": len(rows_a), "bf16": len(rows_b)},
        "pairing_mismatches": bad,
        "nan_screen": {
            "iq4_suspect": [r["id"] for r in rows_a if r.get("suspect_nan")],
            "bf16_suspect": [r["id"] for r in rows_b if r.get("suspect_nan")],
            "iq4_errors": [r["id"] for r in rows_a if r.get("error")],
            "bf16_errors": [r["id"] for r in rows_b if r.get("error")],
        },
    }

    text = [f"pooled quality battery: IQ4 {len(rows_a)} requests, "
            f"BF16 {len(rows_b)} requests, pairing mismatches {len(bad)}"]

    needle_depths = sorted({r["depth"] for r in rows_a
                            if r["section"] == "needle"})
    needle = {}
    for depth in needle_depths:
        def rows_at_depth(rows):
            return [r for r in rows if r["section"] == "needle"
                    and r["depth"] == depth]
        needle[f"d{depth}"] = pooled_panel(rows_at_depth(rows_a),
                                           rows_at_depth(rows_b), "needle",
                                           sa.score_needle)
    needle["overall"] = pooled_panel(
        [r for r in rows_a if r["section"] == "needle"],
        [r for r in rows_b if r["section"] == "needle"], "needle",
        sa.score_needle)
    report["needle"] = needle

    for section in ("knowledge", "knowthink", "tools"):
        # Identical request bodies across replicates -> deterministic copies:
        # dedup to unique items so CIs/McNemar are not pseudo-replicated.
        report[section] = pooled_panel(rows_a, rows_b, section,
                                       {"knowledge": sa.score_knowledge,
                                        "knowthink": sa.score_knowledge,
                                        "tools": sa.score_tool}[section],
                                       dedup=True)

    # MTP acceptance pooled over paired requests. The 8 prompts are sent
    # with identical bodies every replicate, and greedy decoding reproduces
    # the same acceptance bit-for-bit (verified below), so the honest sample
    # is one observation per prompt id: pooling all (replicate, id) pairs
    # would shrink the CI by ~sqrt(n_replicates) from pseudo-replication.
    acc_all, acc_by_id = [], {}
    for k in sorted(set(ia) & set(ib)):
        if not k[1] == "mtp":
            continue
        ra, rb = sa.acceptance(ia[k]), sa.acceptance(ib[k])
        if ra is not None and rb is not None:
            acc_all.append((ra, rb))
            acc_by_id.setdefault(k[2], []).append((ra, rb))
    acc = [v[0] for v in acc_by_id.values()]
    disagreements = [
        i for i, v in acc_by_id.items()
        if len({(round(a, 9), round(b, 9)) for a, b in v}) > 1]
    report["mtp_acceptance"] = {
        "n": len(acc),
        "sampling": {
            "unit": "unique prompt id (deterministic replicates collapsed)",
            "n_observations_pooled": len(acc_all),
            "cross_replicate_disagreements": disagreements,
        },
        "summary": sa.paired_means(acc),
        "delta_ci95": sa.bootstrap_ci([p[1] - p[0] for p in acc]),
        "pseudoreplicated_ci95_for_reference_only":
            sa.bootstrap_ci([p[1] - p[0] for p in acc_all]),
    }

    # Determinism: within arm across (replicate, pair) and across arms.
    det = {"iq4_within": [], "bf16_within": [], "cross_arm_identical": 0,
           "cross_arm_total": 0}
    for rows, arm in ((rows_a, "iq4"), (rows_b, "bf16")):
        by_pair = {}
        for r in rows:
            if r["section"] == "det":
                by_pair.setdefault((r["replicate"], r["pair"]), {})[r["id"]] = r
        for (rep, pair), items in sorted(by_pair.items()):
            if f"{pair}-a" in items and f"{pair}-b" in items:
                det[f"{arm}_within"].append({
                    "replicate": rep, "pair": pair,
                    "identical": items[f"{pair}-a"]["content_sha256"] ==
                    items[f"{pair}-b"]["content_sha256"]})
    for k in sorted(set(ia) & set(ib)):
        if k[1] == "det" and k[2].endswith("-a"):
            rb_key = (k[0], k[1], k[2][:-2] + "-b")
            if rb_key in ib and ia[k].get("content_sha256") and \
                    ia[k]["content_sha256"] == ib[k].get("content_sha256"):
                det["cross_arm_identical"] += 1
            if k in ia and k in ib:
                det["cross_arm_total"] += 1
    report["det"] = det

    # Timings: pooled per-request verdicts (counts only; never averaged).
    report["timings"] = {
        "wall_ms": timing_counts(rows_a, rows_b, "wall_ms", "ms"),
        "ttft_ms": timing_counts(rows_a, rows_b, "usage.gufo.ttft_ms", "ms"),
        "prefill_prompt_per_second": timing_counts(
            rows_a, rows_b, "timings.prompt_per_second", "rate"),
        "decode_predicted_per_second": timing_counts(
            rows_a, rows_b, "timings.predicted_per_second", "rate"),
    }

    # ------------------------------------------------------------- text ----
    text.append("\n== pooled panels (IQ4 vs BF16, paired within replicate; "
                "deterministic-replicate sections deduplicated to unique "
                "items — see the sampling field in the JSON) ==")
    for name in ("needle", "knowledge", "knowthink", "tools"):
        if name == "needle":
            text.append(f"  needle overall: n={needle['overall']['n']} "
                        f"(fresh nonces per replicate: independent samples) "
                        f"IQ4 {needle['overall']['iq4_acc'] * 100:.1f}% "
                        f"BF16 {needle['overall']['bf16_acc'] * 100:.1f}%")
            for d, tab in needle.items():
                if d == "overall" or tab.get("n") is None:
                    continue
                text.append(f"    {d}: n={tab['n']} IQ4 "
                            f"{tab['iq4_acc'] * 100:.1f}% BF16 "
                            f"{tab['bf16_acc'] * 100:.1f}% "
                            f"discordant {tab['discordant']}")
            continue
        tab = report[name]
        ci = tab.get("delta_ci95")
        text.append(
            f"  {name}: n={tab['n']} unique items "
            f"({tab['sampling']['n_observations_pooled']} pooled obs) "
            f"IQ4 {tab['iq4_acc'] * 100:.1f}% vs BF16 "
            f"{tab['bf16_acc'] * 100:.1f}% (delta "
            f"{(tab['delta'] or 0) * 100:+.2f} pp, CI95 "
            f"[{ci[0] * 100:+.2f}, {ci[1] * 100:+.2f}], McNemar p="
            f"{tab['mcnemar_p']:.3g}, discordant {tab['discordant']})")
    mtp = report["mtp_acceptance"]
    s = mtp["summary"]
    ci = mtp["delta_ci95"]
    pci = mtp["pseudoreplicated_ci95_for_reference_only"]
    text.append(f"  mtp acceptance: n={mtp['n']} unique prompts "
                f"({mtp['sampling']['n_observations_pooled']} pooled obs) "
                f"IQ4 {s['iq4']:.2f}% vs BF16 {s['bf16']:.2f}% "
                f"(delta {s['delta']:+.2f} pp, CI95 "
                f"[{ci[0]:+.2f}, {ci[1]:+.2f}]; pseudo-replicated all-obs CI "
                f"[{pci[0]:+.2f}, {pci[1]:+.2f}] shown for reference only -- "
                f"acceptance is deterministic per prompt, verified "
                f"{mtp['sampling']['cross_replicate_disagreements'] == []})")
    text.append(f"  det within-arm identical: IQ4 "
                f"{sum(1 for x in det['iq4_within'] if x['identical'])}"
                f"/{len(det['iq4_within'])}, BF16 "
                f"{sum(1 for x in det['bf16_within'] if x['identical'])}"
                f"/{len(det['bf16_within'])}; cross-arm identical "
                f"{det['cross_arm_identical']}/{det['cross_arm_total']}")
    text.append("\n== pooled timing verdicts (counts per direction) ==")
    for name, tab in report["timings"].items():
        text.append(f"  {name}: {tab['verdicts']} worst "
                    f"{tab['worst']}")

    args.out.write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    args.report.write_text("\n".join(text) + "\n")
    print("\n".join(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
