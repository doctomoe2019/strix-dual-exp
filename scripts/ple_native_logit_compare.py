#!/usr/bin/env python3
"""Compare two gpu_probe logit dumps (F32 rows, vocab width).

Used two ways in phase 3:
  * treatment effect:  IQ4-TP2 dump vs BF16-TP2 dump on the same
    prompt+continuation (only the PLE table differs);
  * TP2 tolerance regime: BF16-TP2 dump vs BF16-single-host dump (reduction
    order differs), against the precedent recorded in
    docs/models/qwen3.8-flash-next/EXPERIMENTS.md ("TP2 against one host"):
    216 tokens RMSE 0.134, top-1 63/64, mean KL 0.0055.

Reports per-row and aggregate: RMSE, max|diff|, KL both directions, top-1
agreement, argmax-token sequence divergence, NaN/Inf counts.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

VOCAB = 248320


def softmax_np(x: np.ndarray) -> np.ndarray:
    x = x - x.max()
    e = np.exp(x)
    return e / e.sum()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="reference dump (rows x vocab f32)")
    ap.add_argument("--b", required=True, help="candidate dump")
    ap.add_argument("--vocab", type=int, default=VOCAB)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    a = np.fromfile(args.a, dtype="<f4")
    b = np.fromfile(args.b, dtype="<f4")
    if a.size != b.size:
        raise SystemExit(f"size mismatch: {a.size} vs {b.size} floats")
    if a.size % args.vocab:
        raise SystemExit(f"size {a.size} not a multiple of vocab {args.vocab}")
    rows = a.size // args.vocab
    a = a.reshape(rows, args.vocab).astype(np.float64)
    b = b.reshape(rows, args.vocab).astype(np.float64)

    nan_a = int(np.isnan(a).sum() + np.isinf(a).sum())
    nan_b = int(np.isnan(b).sum() + np.isinf(b).sum())
    per_row = []
    top_a = a.argmax(axis=1)
    top_b = b.argmax(axis=1)
    for i in range(rows):
        d = b[i] - a[i]
        pa = softmax_np(a[i])
        pb = softmax_np(b[i])
        mask = pa > 1e-12
        kl_ab = float(np.sum(pa[mask] * (np.log(pa[mask]) - np.log(np.maximum(pb[mask], 1e-300)))))
        mask = pb > 1e-12
        kl_ba = float(np.sum(pb[mask] * (np.log(pb[mask]) - np.log(np.maximum(pa[mask], 1e-300)))))
        per_row.append({
            "row": i, "argmax_a": int(top_a[i]), "argmax_b": int(top_b[i]),
            "same_top": bool(top_a[i] == top_b[i]),
            "rmse": float(math.sqrt(float(np.mean(d * d)))),
            "max_abs": float(np.max(np.abs(d))),
            "kl_ab": kl_ab, "kl_ba": kl_ba,
        })

    same = sum(r["same_top"] for r in per_row)
    first_div = next((r["row"] for r in per_row if not r["same_top"]), None)
    out = {
        "label": args.label, "a": str(args.a), "b": str(args.b),
        "rows": rows, "vocab": args.vocab,
        "nan_inf_counts": {"a": nan_a, "b": nan_b},
        "finite": nan_a == 0 and nan_b == 0,
        "rmse_all": float(np.sqrt(np.mean((b - a) ** 2))),
        "max_abs_all": float(np.max(np.abs(b - a))),
        "mean_kl_ab": float(np.mean([r["kl_ab"] for r in per_row])),
        "mean_kl_ba": float(np.mean([r["kl_ba"] for r in per_row])),
        "top1_agree": same / rows if rows else float("nan"),
        "top1_same_count": same,
        "first_top1_divergence_row": first_div,
        "per_row": per_row,
    }
    args.out.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    print(f"[{args.label}] rows={rows} finite={'YES' if out['finite'] else 'NO'} "
          f"RMSE={out['rmse_all']:.4f} max|d|={out['max_abs_all']:.4f} "
          f"KL(a||b)={out['mean_kl_ab']:.5f} KL(b||a)={out['mean_kl_ba']:.5f} "
          f"top1 {same}/{rows} ({out['top1_agree']*100:.2f}%) "
          f"first_div_row={first_div}")
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
