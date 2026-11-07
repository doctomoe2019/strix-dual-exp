#!/usr/bin/env python3
"""Paired WikiText-2 KLD analysis from two gpu_probe --kld-save files.

Reads two llama.cpp-format '_logits_' files produced by gpu_probe on the two
arms (identical token section) and reports, per chunk and overall:

  ppl_q  perplexity implied by each file's own quantized log-probs
         (minimum + scale * code) over the scored positions
  d_nll  per-chunk paired NLL delta (BF16 minus IQ4) and its mean/CI --
         negative means BF16 assigns higher likelihood to the true tokens
  top1   fraction of scored positions whose argmax token agrees
  kl     mean KL(IQ4 || BF16) in nats over non-floor tokens

The files store log-probs already normalized by the log-sum (gpu_probe writes
mine_min = lowest - top - log_sum), so exp(logprob) is a probability. The
aggregate exact perplexities printed by gpu_probe itself are the primary
numbers; this script adds the per-chunk pairing needed for a CI.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys

import numpy as np

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ple_native_screen_analysis import bootstrap_ci  # noqa: E402


class KldFile:
    def __init__(self, path: str):
        self.f = np.memmap(path, dtype=np.uint8, mode="r")
        if self.f[:8].tobytes() != b"_logits_":
            raise SystemExit(f"{path}: not a _logits_ file")
        self.n_ctx, self.n_vocab, self.n_chunk = struct.unpack(
            "<3i", self.f[8:20].tobytes())
        self.codes = 2 * ((self.n_vocab + 1) // 2) + 4
        self.record = self.codes * 2
        self.scored = self.n_ctx // 2 - 1
        tok_end = 20 + 4 * self.n_ctx * self.n_chunk
        self.tokens = np.frombuffer(
            self.f[20:tok_end].tobytes(), dtype="<i4").reshape(
            self.n_chunk, self.n_ctx).copy()
        self.data_off = tok_end

    def record_at(self, chunk: int, pos_idx: int) -> np.ndarray:
        off = self.data_off + (chunk * self.scored + pos_idx) * self.record
        return np.frombuffer(self.f[off:off + self.record].tobytes(),
                             dtype="<u2")

    def logprobs(self, rec: np.ndarray) -> np.ndarray:
        # rec is uint16 units: [0:2] f32 scale, [2:4] f32 minimum, [4:] codes
        scale = np.frombuffer(rec[0:2].tobytes(), dtype="<f4")[0].astype(np.float64)
        minimum = np.frombuffer(rec[2:4].tobytes(), dtype="<f4")[0].astype(np.float64)
        codes = rec[4:].astype(np.float64)
        lp = minimum + scale * codes
        lp[codes == 0] = -np.inf  # floor: only an upper bound (llama.cpp rule)
        return lp


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True, help="gpu_probe --kld-save from the IQ4 arm")
    ap.add_argument("--bf16", required=True, help="gpu_probe --kld-save from the BF16 arm")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    a = KldFile(args.iq4)
    b = KldFile(args.bf16)
    if (a.n_ctx, a.n_vocab, a.n_chunk) != (b.n_ctx, b.n_vocab, b.n_chunk):
        raise SystemExit("file geometry mismatch")
    if not np.array_equal(a.tokens, b.tokens):
        raise SystemExit("token sections differ")

    first = a.n_ctx // 2
    rows = []
    for chunk in range(a.n_chunk):
        nll_a: list[float] = []
        nll_b: list[float] = []
        kl_ab = kl_ba = 0.0
        top1 = 0
        count = 0
        tok = a.tokens[chunk]
        for pos_idx in range(a.scored):
            pos = first + pos_idx  # predicts tokens[pos + 1]
            nxt = int(tok[pos + 1])
            la = a.logprobs(a.record_at(chunk, pos_idx))
            lb = b.logprobs(b.record_at(chunk, pos_idx))
            if np.isfinite(la[nxt]) and np.isfinite(lb[nxt]):
                nll_a.append(-float(la[nxt]))
                nll_b.append(-float(lb[nxt]))
            top_a = int(np.argmax(np.where(np.isfinite(la), la, -np.inf)))
            top_b = int(np.argmax(np.where(np.isfinite(lb), lb, -np.inf)))
            top1 += top_a == top_b
            # KL over non-floor tokens (both files above the floor)
            mask = np.isfinite(la) & np.isfinite(lb)
            pa = np.exp(la[mask])
            pb = np.exp(lb[mask])
            pa /= pa.sum()
            pb /= pb.sum()
            kl_ab += float(np.sum(pa * (np.log(pa + 1e-300) - np.log(pb + 1e-300))))
            kl_ba += float(np.sum(pb * (np.log(pb + 1e-300) - np.log(pa + 1e-300))))
            count += 1
        scored_nll = len(nll_a)
        rows.append({
            "chunk": chunk, "positions": count, "scored_nll_positions": scored_nll,
            "ppl_iq4_q": math.exp(sum(nll_a) / scored_nll) if scored_nll else float("nan"),
            "ppl_bf16_q": math.exp(sum(nll_b) / scored_nll) if scored_nll else float("nan"),
            "delta_nll_sum": (sum(nll_b) - sum(nll_a)) if scored_nll else float("nan"),
            "top1_agree": top1 / count if count else float("nan"),
            "kl_iq4_bf16": kl_ab / count if count else float("nan"),
            "kl_bf16_iq4": kl_ba / count if count else float("nan"),
        })
        print(f"chunk {chunk:2d}: ppl_iq4 {rows[-1]['ppl_iq4_q']:.4f} "
              f"ppl_bf16 {rows[-1]['ppl_bf16_q']:.4f} "
              f"top1 {rows[-1]['top1_agree']*100:5.1f}% "
              f"KL(a||b) {rows[-1]['kl_iq4_bf16']:.6f}", flush=True)

    n_pos = sum(r["positions"] for r in rows)
    n_nll = sum(r["scored_nll_positions"] for r in rows)
    # aggregate per-chunk sums; positions weighted equally
    total_delta = sum(r["delta_nll_sum"] for r in rows)
    mean_top1 = sum(r["top1_agree"] * r["positions"] for r in rows) / n_pos
    mean_kl = sum(r["kl_iq4_bf16"] * r["positions"] for r in rows) / n_pos
    mean_kl_rev = sum(r["kl_bf16_iq4"] * r["positions"] for r in rows) / n_pos

    # Per-chunk paired delta NLL mean position for the CI
    deltas = [r["delta_nll_sum"] / r["scored_nll_positions"] for r in rows]
    ci = bootstrap_ci(deltas)

    out = {
        "n_ctx": a.n_ctx, "n_vocab": a.n_vocab, "n_chunk": a.n_chunk,
        "scored_positions_total": n_pos, "nll_positions_total": n_nll,
        "per_chunk": rows,
        "aggregate": {
            "sum_delta_nll": total_delta,
            "mean_delta_nll_per_position": total_delta / n_nll,
            "mean_delta_nll_per_chunk": sum(deltas) / len(deltas),
            "delta_nll_ci95": ci,
            "top1_agree": mean_top1,
            "kl_iq4_bf16": mean_kl,
            "kl_bf16_iq4": mean_kl_rev,
            "note": "negative delta_nll = BF16 assigns higher likelihood to "
                    "the true WikiText-2 tokens",
        },
        "files": {"iq4": str(args.iq4), "bf16": str(args.bf16)},
    }
    args.out.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    print(f"AGGREGATE nll_positions={n_nll} sum_delta_nll={total_delta:+.2f} "
          f"mean/pos={total_delta/n_nll:+.6f} CI95 "
          f"[{ci[0]:+.6f}, {ci[1]:+.6f}] top1 {mean_top1*100:.2f}% "
          f"KL(iq4||bf16) {mean_kl:.6f}")
    print("wrote", args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
