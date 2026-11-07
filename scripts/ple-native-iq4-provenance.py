#!/usr/bin/env python3
"""Provenance probe for the production IQ4_NL PLE table (phase-2, diagnostic).

Re-quantizes sampled native BF16 rows to IQ4_NL with BOTH nibble conventions
(the gufo/llama.cpp reader convention: elements 0..15 low nibble, 16..31 high
nibble; and the 2026-10-14 requant-ple.py writer convention: q[2j] low,
q[2j+1] high) and reports which one reproduces the bytes actually stored in
the production shard. A ~100% nibble match under one convention and ~1/16
under the other pins the file's encoding unambiguously.

Usage: iq4-provenance.py --iq4 ORIG.gguf --bf16 NEW.gguf [--rows 64] [--seed S]
"""
import argparse
import struct
import sys

import numpy as np

COLS = 160
DATA_START = 192
ROW_BYTES = COLS // 32 * 18
KV = np.array([-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113],
              dtype=np.float32)
KV_SORT = np.sort(KV)
KV_SORT_IDX = np.argsort(KV, kind="stable")


def quantize_blocks(w):          # w: (n_rows, 32) f32 -> (n_rows, 18) uint8 payload
    amax = np.abs(w).max(axis=1)
    d = (amax / 127.0).astype(np.float16).astype(np.float32)
    d[amax == 0] = 0.0
    inv = np.where(d != 0, 1.0 / np.where(d != 0, d, 1.0), 0.0)
    x = w * inv[:, None]
    pos = np.searchsorted(KV_SORT, x)
    lo = np.clip(pos - 1, 0, 15)
    hi = np.clip(pos, 0, 15)
    idx = np.where(np.abs(x - KV_SORT[lo]) <= np.abs(x - KV_SORT[hi]), lo, hi)
    q = KV_SORT_IDX[idx].astype(np.uint8)          # per-element code, true order
    a = q[:, 0:16]                                 # gufo: elem i (i<16) low nibble
    b = q[:, 16:32]                                # gufo: elem i-16 high nibble
    gufo = (a | (b << 4)).astype(np.uint8)
    ev, od = q[:, 0::2], q[:, 1::2]                # legacy: q[2j] low, q[2j+1] high
    legacy = (ev | (od << 4)).astype(np.uint8)
    d16 = d.astype(np.float16).view(np.uint8).reshape(-1, 2)
    return d16, gufo, legacy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True)
    ap.add_argument("--bf16", required=True)
    ap.add_argument("--rows", type=int, default=64)
    ap.add_argument("--seed", type=int, default=20261017)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    rows = np.unique(rng.integers(0, 320_001_536, size=args.rows))

    match_g = match_l = nib_total = 0
    scale_g = 0
    with open(args.iq4, "rb") as fq, open(args.bf16, "rb") as fb:
        for r in rows:
            fq.seek(DATA_START + r * ROW_BYTES)
            raw = fq.read(ROW_BYTES)
            fb.seek(DATA_START + r * COLS * 2)
            b16 = (np.frombuffer(fb.read(COLS * 2), dtype="<u2").astype(np.uint32) << 16).view(np.float32)
            stored = np.frombuffer(raw, dtype=np.uint8).reshape(5, 18)
            w = b16.reshape(5, 32)
            d16, g, l = quantize_blocks(w)
            scale_g += int((stored[:, :2] == d16).all(axis=1).sum())
            m_g = (stored[:, 2:] == g)
            m_l = (stored[:, 2:] == l)
            match_g += int(m_g.sum())
            match_l += int(m_l.sum())
            nib_total += m_g.size
    nblk = len(rows) * 5
    print(f"rows={len(rows)} blocks={nblk} nibbles={nib_total}")
    print(f"scale-bytes blocks identical : {scale_g}/{nblk} ({100.0 * scale_g / nblk:.2f}%)")
    print(f"code bytes identical  gufo   : {match_g}/{nib_total} ({100.0 * match_g / nib_total:.2f}%)")
    print(f"code bytes identical  legacy : {match_l}/{nib_total} ({100.0 * match_l / nib_total:.2f}%)")
    print("(residual mismatches under the winning convention come from the "
          "2026-10-14 requant starting from Q8_0, not BF16)")


if __name__ == "__main__":
    main()
