#!/usr/bin/env python3
"""Phase-2 verification battery item (c): ROW-ORDER ALIGNMENT between the
production IQ4_NL PLE table and the native BF16 table.

Rows of per_layer_token_embd.weight are hash-indexed at serving time
((hash % head_vocab) + head_offset), so the GGUF row order MUST match the
upstream tensor row order or every lookup lands on the wrong embedding. This
script dequantizes K randomly-chosen row indices from the ORIGINAL IQ4 shard 3
and compares them, element-wise in row order, against the same indices read
from the rebuilt BF16 shard 3 (or straight from the staged safetensors with
--bf16-source staging). Per-row Pearson correlation over the 160 elements is
recorded as a distribution.

Two IQ4_NL nibble conventions are reported:
  - gufo (llama.cpp): elements 0..15 = low nibbles of qs[0..15],
    elements 16..31 = high nibbles (src/core/quant/ggml_dequant.cpp:544).
  - legacy: the 2026-10-14 requant-ple.py writer packed q[2j] low / q[2j+1]
    high, i.e. even elements low / odd elements high (a different permutation).
If only the legacy convention correlates, the production table is
intra-block element-permuted — a quality finding in itself; the ROW order
proof is unaffected (rows still align; the permutation is within a row).

Also prints a shifted-row control (row i of IQ4 vs row i+1 of BF16) to show
the metric discriminates, and a per-row relative-error distribution.

Usage:
  ple-native-align.py --iq4 ORIG-shard3.gguf --bf16 NEW-shard3.gguf \
      [--rows 1500] [--seed 20261017] [--control 200]
      [--bf16-source staging-dir]   # read BF16 rows from safetensors instead
"""
import argparse
import json
import os
import re
import struct
import sys

import numpy as np

PLE = "per_layer_token_embd.weight"
COLS = 160
ROWS = 320_001_536
CHUNK_RE = re.compile(
    r"^model\.language_model\.layers\.1\.ple\.ple_embedding\.ngram_embedding\.shard_(\d+)\.weight$")
CHUNK_ROWS = 2_500_012
KV = np.array([-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113],
              dtype=np.float32)
IQ4_DATA_START = 192          # verified by ple-native-splice.py / header parse
IQ4_ROW_BYTES = COLS // 32 * 18   # 90


def gguf_data_start(path):
    with open(path, "rb") as f:
        assert f.read(4) == b"GGUF"
        struct.unpack("<I", f.read(4))
        n_t, n_kv = struct.unpack("<QQ", f.read(16))
        sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1,
                 10: 8, 11: 8, 12: 8, 13: 8}

        def skip_value(t):
            if t == 8:
                n = struct.unpack("<Q", f.read(8))[0]
                f.read(n)
            elif t == 9:
                et, n = struct.unpack("<IQ", f.read(12))
                if et == 8:
                    for _ in range(n):
                        ln2 = struct.unpack("<Q", f.read(8))[0]
                        f.read(ln2)
                else:
                    f.read(sizes[et] * n)
            else:
                f.read(sizes[t])

        alignment = 32
        for _ in range(n_kv):
            ln = struct.unpack("<Q", f.read(8))[0]
            key = f.read(ln).decode()
            t = struct.unpack("<I", f.read(4))[0]
            before = f.tell()
            if key == "general.alignment":
                alignment = struct.unpack("<I", f.read(4))[0]
                f.seek(before)
            skip_value(t)
        for _ in range(n_t):
            ln = struct.unpack("<Q", f.read(8))[0]
            f.read(ln)
            nd = struct.unpack("<I", f.read(4))[0]
            for _ in range(nd):
                struct.unpack("<Q", f.read(8))
            struct.unpack("<I", f.read(4))
            struct.unpack("<Q", f.read(8))
        infos_end = f.tell()
    return (infos_end + alignment - 1) // alignment * alignment, alignment


def read_iq4_rows(path, rows, data_start):
    """Dequantize IQ4_NL rows under BOTH nibble conventions; return (gufo, legacy)."""
    out_g = np.empty((len(rows), COLS), dtype=np.float32)
    out_l = np.empty((len(rows), COLS), dtype=np.float32)
    with open(path, "rb") as f:
        for k, r in enumerate(rows):
            f.seek(data_start + r * IQ4_ROW_BYTES)
            raw = f.read(IQ4_ROW_BYTES)
            if len(raw) != IQ4_ROW_BYTES:
                raise SystemExit(f"short IQ4 read at row {r}")
            b = np.frombuffer(raw, dtype=np.uint8).reshape(5, 18)
            d = b[:, :2].copy().view(np.float16).astype(np.float32).repeat(32, axis=1)
            qs = b[:, 2:]                                   # 5 x 16
            lo = KV[qs & 0x0F].astype(np.float32)           # 5 x 16
            hi = KV[qs >> 4].astype(np.float32)             # 5 x 16
            # gufo/llama.cpp: elements 0..15 low, 16..31 high (per 32-block)
            gufo = np.empty((5, 32), dtype=np.float32)
            gufo[:, :16] = lo
            gufo[:, 16:] = hi
            out_g[k] = (d * gufo).reshape(-1)
            # legacy requant-ple.py packing: q[2j] low nibble of byte j, q[2j+1] high
            legacy = np.empty((5, 32), dtype=np.float32)
            legacy[:, 0::2] = lo
            legacy[:, 1::2] = hi
            out_l[k] = (d * legacy).reshape(-1)
    return out_g, out_l


def bf16_reader_shard(path, data_start):
    def get(rows):
        out = np.empty((len(rows), COLS), dtype=np.float32)
        with open(path, "rb") as f:
            for k, r in enumerate(rows):
                f.seek(data_start + r * COLS * 2)
                raw = f.read(COLS * 2)
                if len(raw) != COLS * 2:
                    raise SystemExit(f"short BF16 read at row {r}")
                out[k] = (np.frombuffer(raw, dtype="<u2").astype(np.uint32) << 16).view(np.float32)
        return out
    return get


def bf16_reader_staging(staging):
    chunks = {}
    for name in sorted(os.listdir(staging)):
        if not name.endswith(".safetensors"):
            continue
        with open(os.path.join(staging, name), "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            header = json.loads(f.read(n))
        base = 8 + n
        for tname, meta in header.items():
            m = CHUNK_RE.match(tname)
            if m:
                chunks[int(m.group(1))] = (os.path.join(staging, name),
                                           base + meta["data_offsets"][0])
    assert len(chunks) == ROWS // CHUNK_ROWS, len(chunks)
    handles = {}

    def get(rows):
        out = np.empty((len(rows), COLS), dtype=np.float32)
        for k, r in enumerate(rows):
            c, off = chunks[r // CHUNK_ROWS]
            fh = handles.get(c)
            if fh is None:
                fh = handles[c] = open(c, "rb")
            fh.seek(off + (r % CHUNK_ROWS) * COLS * 2)
            raw = fh.read(COLS * 2)
            if len(raw) != COLS * 2:
                raise SystemExit(f"short staged BF16 read at row {r}")
            out[k] = (np.frombuffer(raw, dtype="<u2").astype(np.uint32) << 16).view(np.float32)
        return out
    return get


def corr_rows(a, b):
    a = a - a.mean(axis=1, keepdims=True)
    b = b - b.mean(axis=1, keepdims=True)
    num = (a * b).sum(axis=1)
    den = np.sqrt((a * a).sum(axis=1) * (b * b).sum(axis=1))
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(den > 0, num / den, np.nan)


def relerr_rows(a, b):
    den = np.linalg.norm(b, axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(den > 0, np.linalg.norm(a - b, axis=1) / den, np.nan)


def dist(name, v):
    v = v[np.isfinite(v)]
    print(f"  {name}: n={len(v)} min={v.min():.6f} p5={np.percentile(v, 5):.6f} "
          f"median={np.median(v):.6f} mean={v.mean():.6f} p95={np.percentile(v, 95):.6f} "
          f"max={v.max():.6f}")
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iq4", required=True)
    ap.add_argument("--bf16")
    ap.add_argument("--bf16-source")
    ap.add_argument("--rows", type=int, default=1500)
    ap.add_argument("--control", type=int, default=200)
    ap.add_argument("--seed", type=int, default=20261017)
    args = ap.parse_args()
    assert args.bf16 or args.bf16_source, "need --bf16 or --bf16-source"

    iq4_start, _ = gguf_data_start(args.iq4)
    print(f"[iq4 ] {args.iq4} data_start={iq4_start} row_bytes={IQ4_ROW_BYTES}")
    if args.bf16:
        bf16_start, al = gguf_data_start(args.bf16)
        print(f"[bf16] {args.bf16} data_start={bf16_start} alignment={al}")
        get_bf16 = bf16_reader_shard(args.bf16, bf16_start)
    else:
        print(f"[bf16] staged safetensors under {args.bf16_source}")
        get_bf16 = bf16_reader_staging(args.bf16_source)

    rng = np.random.default_rng(args.seed)
    rows = np.unique(rng.integers(0, ROWS, size=args.rows))
    print(f"[sample] {len(rows)} distinct row indices, seed {args.seed}, "
          f"range [{rows.min()}, {rows.max()}] of {ROWS}")

    g, l = read_iq4_rows(args.iq4, rows, iq4_start)
    b = get_bf16(rows)

    # pad rows (beyond the hashed range 320,001,446) and all-zero rows carry no
    # signal; report them separately instead of letting them drag the median.
    nz = (np.abs(b).max(axis=1) > 0) & (np.abs(g).max(axis=1) > 0)
    print(f"[sample] non-degenerate rows: {nz.sum()} of {len(rows)} "
          f"(zero-in-BF16: {int((np.abs(b).max(axis=1) == 0).sum())}, "
          f"zero-in-IQ4: {int((np.abs(g).max(axis=1) == 0).sum())})")

    print("[align] per-row Pearson r (160 elems) IQ4 vs native BF16, gufo nibble convention:")
    rg = dist("gufo   ", corr_rows(g[nz], b[nz]))
    print("[align] same rows, legacy (requant-ple.py) nibble convention:")
    rl = dist("legacy ", corr_rows(l[nz], b[nz]))
    print("[align] per-row relative L2 error, gufo convention:")
    dist("relerr ", relerr_rows(g[nz], b[nz]))

    thresh = 0.9
    frac_g = float((rg >= thresh).mean())
    frac_l = float((rl >= thresh).mean()) if len(rl) else 0.0
    print(f"[align] rows with r >= {thresh}: gufo {frac_g * 100:.2f}%  legacy {frac_l * 100:.2f}%")

    # shifted control: same rows, but BF16 taken from row+1 — must NOT correlate
    if args.control > 0:
        crows = rows[:args.control]
        crows_shift = np.minimum(crows + 1, ROWS - 1)
        gc, _ = read_iq4_rows(args.iq4, crows, iq4_start)
        bc = get_bf16(crows_shift)
        nzc = (np.abs(bc).max(axis=1) > 0) & (np.abs(gc).max(axis=1) > 0)
        rc = corr_rows(gc[nzc], bc[nzc])
        print(f"[control] {int(nzc.sum())} shifted (i vs i+1) row pairs, gufo convention:")
        dist("shift+1", rc)

    ok = frac_g >= 0.99 or frac_l >= 0.99
    print(f"RESULT: {'PASS' if ok else 'FAIL'} — row order "
          f"{'aligned' if ok else 'NOT aligned'} "
          f"(gufo convention {'carries' if frac_g >= frac_l else 'does not carry'} the correlation; "
          f"see legacy line for the intra-block element-permutation diagnosis)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
