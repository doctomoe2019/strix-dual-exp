#!/usr/bin/env python3
"""GGUF surgery: rebuild Qwen3.8-Flash-Next shard 3 with the PLE n-gram table
replaced by the NATIVE BF16 table sourced from upstream safetensors (phase 1
staging), encoded as GGML type 30 (BF16, 2 bytes/element, block 1).

Pattern: the proven Q6_K->Q8_0 / Q8_0->IQ4_NL shard-3 splices (2026-10-14,
evidence/model-q6-ab/splice-ple.py + requant-ple.py). Shard 3 carries exactly
ONE tensor, per_layer_token_embd.weight [160, 320001536] at data offset 0, so
the rebuild is: copy the 192-byte header, patch the 4-byte type field
(20 = IQ4_NL -> 30 = BF16), then stream the 128 staged BF16 chunks in chunk
order. No tensor follows the table, so nothing is rebased. Every invariant is
asserted before any byte is written; the script is idempotent (an existing
output with the right size and sha256 is kept unless --force).

Usage:
  ple-native-splice.py --staging DIR --shard3 ORIG.gguf --out NEW.gguf \
      [--expect-sha256 HEX] [--force] [--keep-temp]

Verification performed here (phase-2 battery items a, b, d):
  a) header parse of the rebuilt shard: 1 tensor, dims (160, 320001536), type 30
  b) table bytes bit-exact: sha256 of the streamed payload == --expect-sha256
     (phase-1 golden digest of the 128 concatenated chunks)
  d) every OTHER byte identical to the original: the only non-tensor bytes are
     the 192-byte header, compared byte-for-byte except the 4 type bytes

Safety (this script is retained for reuse against production files):
  - refuses to run when --out is the same file as --shard3, or when --out is
    inside the directory holding --shard3, unless --allow-production-output
    is passed explicitly
  - never deletes a pre-existing --out that does not verify; it refuses and
    asks for --force (replacement itself is atomic: write to <out>.tmp, then
    os.replace)
  - snapshots the input header + (dev, ino, size, mtime) and re-checks both at
    the end, so a clobbered --shard3 aborts loudly instead of passing
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys
import time

PLE = "per_layer_token_embd.weight"
CHUNK_RE = re.compile(
    r"^model\.language_model\.layers\.1\.ple\.ple_embedding\.ngram_embedding\.shard_(\d+)\.weight$")
ROWS = 320_001_536
COLS = 160
CHUNK_ROWS = 2_500_012
CHUNK_BYTES = CHUNK_ROWS * COLS * 2
NCHUNKS = ROWS // CHUNK_ROWS
BLOCK = 64 * 1024 * 1024
GOLDEN_SHA = "f90a8563ba5939e5c0b0f6a57bd3a5f94c39126932f4f10eae98c3585e81434d"


def parse_gguf_header(path):
    """Return (n_kv, kv, infos, infos_end, data_start, alignment)."""
    with open(path, "rb") as f:
        magic, ver = f.read(4), struct.unpack("<I", f.read(4))[0]
        assert magic == b"GGUF" and ver in (2, 3), (magic, ver)
        n_t, n_kv = struct.unpack("<QQ", f.read(16))
        sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1,
                 10: 8, 11: 8, 12: 8, 13: 8}

        def skip(t):
            if t == 8:
                n = struct.unpack("<Q", f.read(8))[0]
                f.read(n)
            elif t == 9:
                et, n = struct.unpack("<IQ", f.read(12))
                if et == 8:
                    for _ in range(n):
                        ln = struct.unpack("<Q", f.read(8))[0]
                        f.read(ln)
                else:
                    f.read(sizes[et] * n)
            else:
                f.read(sizes[t])

        alignment = 32
        kv = {}
        for _ in range(n_kv):
            ln = struct.unpack("<Q", f.read(8))[0]
            key = f.read(ln).decode()
            t = struct.unpack("<I", f.read(4))[0]
            before = f.tell()
            skip(t)
            if key == "general.alignment":
                f.seek(before)
                alignment = struct.unpack("<I", f.read(4))[0]
                f.seek(before)
                skip(t)
            kv[key] = t
        infos = []
        for _ in range(n_t):
            ln = struct.unpack("<Q", f.read(8))[0]
            name = f.read(ln).decode()
            nd = struct.unpack("<I", f.read(4))[0]
            dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nd)]
            tpos = f.tell()
            ttype = struct.unpack("<I", f.read(4))[0]
            off = struct.unpack("<Q", f.read(8))[0]
            infos.append(dict(name=name, dims=dims, tpos=tpos, type=ttype, off=off))
        infos_end = f.tell()
    data_start = (infos_end + alignment - 1) // alignment * alignment
    return n_kv, kv, infos, infos_end, data_start, alignment


def index_chunks(staging):
    """Map chunk index -> (safetensors path, absolute payload offset)."""
    chunks = {}
    for name in sorted(os.listdir(staging)):
        if not name.endswith(".safetensors"):
            continue
        path = os.path.join(staging, name)
        with open(path, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            header = json.loads(f.read(n))
        base = 8 + n
        for tname, meta in header.items():
            m = CHUNK_RE.match(tname)
            if not m:
                continue
            idx = int(m.group(1))
            begin, end = meta["data_offsets"]
            assert meta["dtype"] == "BF16", (tname, meta["dtype"])
            assert meta["shape"] == [CHUNK_ROWS, COLS], (tname, meta["shape"])
            assert end - begin == CHUNK_BYTES, (tname, end - begin)
            assert idx not in chunks, f"chunk {idx} twice ({chunks[idx][0]}, {path})"
            chunks[idx] = (path, base + begin)
    missing = [i for i in range(NCHUNKS) if i not in chunks]
    assert not missing, f"missing chunks {missing[:5]}... ({len(missing)} of {NCHUNKS})"
    return [chunks[i] for i in range(NCHUNKS)]


def sha256_file(path, begin=0, length=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        f.seek(begin)
        left = length if length is not None else os.path.getsize(path) - begin
        while left > 0:
            buf = f.read(min(BLOCK, left))
            if not buf:
                break
            h.update(buf)
            left -= len(buf)
    return h.hexdigest()


def file_identity(path):
    """(dev, ino, size, mtime_ns) — used to prove --shard3 was never written."""
    st = os.stat(path)
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def refuse_destructive_paths(args):
    """Guards against the one irreversible mistake this script could make:
    pointing --out at (or inside the directory of) the production original.

    --shard3 is read-only throughout, and the original IQ4 shard 3 has nlink 1
    with no backup, so an --out that aliases it — or a re-run with a mistyped
    --out inside /models — would delete/overwrite production weights. Refuse
    unless the operator passes --allow-production-output explicitly.
    """
    out_real = os.path.realpath(args.out)
    src_real = os.path.realpath(args.shard3)
    if out_real == src_real:
        raise SystemExit(
            f"REFUSED: --out and --shard3 are the same file ({out_real}); the splice "
            f"would destroy its own input (the production original)")
    src_dir = os.path.dirname(src_real)
    try:
        inside_source_dir = os.path.commonpath([out_real, src_dir]) == src_dir
    except ValueError:
        inside_source_dir = False          # different drives; not a prefix anyway
    if inside_source_dir and not args.allow_production_output:
        raise SystemExit(
            f"REFUSED: --out {out_real} is inside {src_dir}, the directory holding "
            f"--shard3 (production weights). Write the rebuilt shard somewhere else, "
            f"or pass --allow-production-output to override deliberately.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--staging", required=True, help="phase-1 staging dir with the 33 safetensors shards")
    ap.add_argument("--shard3", required=True, help="original IQ4_NL shard 3 GGUF (read-only)")
    ap.add_argument("--out", required=True, help="rebuilt shard 3 GGUF path")
    ap.add_argument("--expect-sha256", default=GOLDEN_SHA,
                    help="expected sha256 of the concatenated BF16 table payload")
    ap.add_argument("--force", action="store_true",
                    help="rebuild even if output already verifies, and replace an "
                         "existing --out that does NOT verify (without --force such "
                         "an --out is left untouched and the run refuses)")
    ap.add_argument("--allow-production-output", action="store_true",
                    help="escape hatch: permit --out inside the directory of --shard3 "
                         "(never needed for the candidate pack; /models-ple-ab is a "
                         "separate directory)")
    args = ap.parse_args()

    t0 = time.time()
    # ---- 0. destructive-path guards, before ANY write or unlink ----
    refuse_destructive_paths(args)
    # ---- 1. original shard analysis (all read-only) ----
    src_identity = file_identity(args.shard3)
    n_kv, kv, infos, infos_end, data_start, alignment = parse_gguf_header(args.shard3)
    print(f"[orig] {args.shard3}")
    print(f"[orig] n_kv={n_kv} kv={kv} alignment={alignment} infos_end={infos_end} data_start={data_start}")
    assert len(infos) == 1, f"expected exactly 1 tensor in shard 3, got {len(infos)}"
    info = infos[0]
    assert info["name"] == PLE, info["name"]
    assert info["dims"] == [COLS, ROWS], info["dims"]
    assert info["type"] == 20, f"original PLE type {info['type']} != 20 (IQ4_NL)"
    assert info["off"] == 0, info["off"]
    orig_size = os.path.getsize(args.shard3)
    iq4_bytes = ROWS * COLS // 32 * 18
    assert orig_size == data_start + iq4_bytes, (orig_size, data_start, iq4_bytes)
    print(f"[orig] tensor {PLE} dims={info['dims']} type=20(IQ4_NL) off=0 "
          f"bytes={iq4_bytes} file={orig_size} type_field_at={info['tpos']}")
    # snapshot of the input header, re-checked at the end: if anything (including
    # this script) ever writes through --shard3, the run aborts loudly instead of
    # comparing the rebuilt file against a clobbered "original".
    with open(args.shard3, "rb") as f:
        src_head = f.read(data_start)
    assert len(src_head) == data_start
    print(f"[orig] header snapshot: {data_start} bytes, sha256="
          f"{hashlib.sha256(src_head).hexdigest()}")

    # ---- 2. chunk source map ----
    chunks = index_chunks(args.staging)
    files = sorted({p for p, _ in chunks})
    print(f"[src ] {len(chunks)} chunks x {CHUNK_BYTES} B across {len(files)} safetensors files "
          f"-> {NCHUNKS * CHUNK_BYTES} B ({NCHUNKS * CHUNK_BYTES / 2**30:.3f} GiB)")

    # ---- 4. rebuild (skipped when an existing output already verifies) ----
    # A pre-existing --out that does NOT verify is never deleted silently: the
    # wrong file may be someone else's data (or a mistyped production path), so
    # without --force the run refuses and leaves it in place.
    bf16_bytes = NCHUNKS * CHUNK_BYTES
    needs_rebuild = True
    digest = None
    if os.path.exists(args.out):
        if os.path.getsize(args.out) == data_start + bf16_bytes:
            got = sha256_file(args.out, data_start, bf16_bytes)
            if got == args.expect_sha256:
                print(f"[skip] {args.out} already exists with the expected payload "
                      f"sha256; verifying only (use --force to rebuild)")
                needs_rebuild = False
                digest = got
                with open(args.out, "rb") as f:
                    head = bytearray(f.read(data_start))
            elif not args.force:
                raise SystemExit(
                    f"REFUSED: existing --out {args.out} has payload sha256 {got} != "
                    f"{args.expect_sha256}; pass --force to replace it")
            else:
                print(f"[warn] existing output payload sha256 {got} != expected; "
                      f"--force given -> replacing atomically")
        elif not args.force:
            raise SystemExit(
                f"REFUSED: existing --out {args.out} has size "
                f"{os.path.getsize(args.out)} (expected {data_start + bf16_bytes}); "
                f"pass --force to replace it")
        else:
            print(f"[warn] existing output has size {os.path.getsize(args.out)} != "
                  f"{data_start + bf16_bytes}; --force given -> replacing atomically")

    if needs_rebuild:
        tmp = args.out + ".tmp"
        head = bytearray(src_head)
        assert struct.unpack_from("<I", head, info["tpos"])[0] == 20
        struct.pack_into("<I", head, info["tpos"], 30)  # BF16
        h = hashlib.sha256()
        written = 0
        with open(tmp, "wb") as out:
            out.write(head)
            for path, off in chunks:
                left = CHUNK_BYTES
                with open(path, "rb") as src:
                    src.seek(off)
                    while left > 0:
                        buf = src.read(min(BLOCK, left))
                        if not buf:
                            raise SystemExit(f"short read in {path} at {off + (CHUNK_BYTES - left)}")
                        out.write(buf)
                        h.update(buf)
                        written += len(buf)
                        left -= len(buf)
            out.flush()
            os.fsync(out.fileno())
        assert written == bf16_bytes, (written, bf16_bytes)
        digest = h.hexdigest()
        os.replace(tmp, args.out)
        wtime = time.time() - t0
        print(f"[write] payload {written} B in {wtime:.1f}s ({written / wtime / 2**20:.0f} MiB/s)")
        print(f"[write] payload sha256={digest} (expect {args.expect_sha256})")
        if digest != args.expect_sha256:
            os.unlink(args.out)
            raise SystemExit("FATAL: payload digest mismatch — output removed")

    # ---- 5. verify rebuilt file: header parse + size (battery a) ----
    n_kv2, kv2, infos2, infos_end2, data_start2, alignment2 = parse_gguf_header(args.out)
    assert n_kv2 == n_kv and kv2 == kv, "kv section changed"
    assert data_start2 == data_start and alignment2 == alignment, (data_start2, alignment2)
    assert len(infos2) == 1, infos2
    i2 = infos2[0]
    assert i2["name"] == PLE and i2["dims"] == [COLS, ROWS] and i2["type"] == 30 and i2["off"] == 0, i2
    assert i2["tpos"] == info["tpos"], (i2["tpos"], info["tpos"])
    new_size = os.path.getsize(args.out)
    assert new_size == data_start + bf16_bytes, (new_size, data_start + bf16_bytes)
    print(f"[verify-a] rebuilt header: n_kv={n_kv2} tensors={len(infos2)} "
          f"{PLE} dims={i2['dims']} type=30(BF16) off=0 data_start={data_start2} file={new_size}")

    # ---- 6. header byte-identity outside the type field (battery d) ----
    # First prove the input is still the file we analysed (identity + header
    # bytes); only then compare the rebuilt header against that snapshot.
    assert file_identity(args.shard3) == src_identity, \
        "FATAL: --shard3 was replaced or written during the run"
    with open(args.shard3, "rb") as f:
        now_head = f.read(data_start)
    assert now_head == src_head, "FATAL: --shard3 header changed during the run"
    diff = [i for i in range(data_start) if src_head[i] != head[i]]
    # only the 4-byte GGML type field may differ; bytes that happen to be equal
    # (20 = 0x14 vs 30 = 0x1E share the upper three bytes) do not appear in diff
    assert set(diff) <= set(range(info["tpos"], info["tpos"] + 4)), \
        f"header differs outside the type field: {diff}"
    print(f"[verify-d] header byte-diff offsets {diff} (subset of the 4-byte GGML type "
          f"field at {info['tpos']}-{info['tpos'] + 3}; 20=0x14 -> 30=0x1E differs only in "
          f"the low byte); every other header byte identical, no other tensors exist in "
          f"this shard")

    # ---- 7. independent re-read of the payload (battery b) ----
    reread = sha256_file(args.out, data_start, bf16_bytes)
    assert reread == digest == args.expect_sha256, (reread, digest)
    print(f"[verify-b] independent re-read of [{data_start}, {data_start + bf16_bytes}) "
          f"sha256={reread} == phase-1 golden digest: table bytes are a bit-exact copy "
          f"of the staged native BF16 source (no F32->BF16 rounding involved)")
    # ---- 8. final proof that the production input was never touched ----
    assert file_identity(args.shard3) == src_identity, \
        "FATAL: --shard3 identity changed (dev/ino/size/mtime)"
    print(f"[verify-input] --shard3 untouched: dev/ino/size/mtime identical to run start, "
          f"header bytes still the analysed snapshot")
    print("RESULT: PASS")


if __name__ == "__main__":
    sys.exit(main())
