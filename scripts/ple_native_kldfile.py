#!/usr/bin/env python3
"""Build a llama.cpp-format '_logits_' file for gufo's gpu_probe --kld modes.

`gpu_probe --kld-base FILE --kld-save FILE` (tests/models/qwen38_flash_next/
gpu_probe.cpp, EvaluateKld) reads token ids and per-position quantized
log-prob records from such a file and writes the same format back. This
script assembles the token section from gufo's own tokenizer output
(ple-native-tokenize) and pads the record section with zeros, producing a
base whose derived numbers are meaningless -- exactly what an arm needs when
it is run first with --kld-save to capture its own log-probs for the other
arm's --kld-base pass.

Layout (little endian):
  char[8]   "_logits_"
  int32[3]  n_ctx, n_vocab, n_chunk
  int32[n_ctx*n_chunk] tokens
  per chunk, per scored position (n_ctx/2 .. n_ctx-2):
    uint16[2*((n_vocab+1)/2)+4]  {f32 scale, f32 min, codes...}
"""
import argparse
import struct


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", required=True, help="int32 LE token ids from ple-native-tokenize")
    ap.add_argument("--out", required=True)
    ap.add_argument("--n-ctx", type=int, default=1024)
    ap.add_argument("--n-chunk", type=int, default=16)
    ap.add_argument("--vocab", type=int, default=248320)
    args = ap.parse_args()

    raw = open(args.ids, "rb").read()
    if len(raw) % 4:
        raise SystemExit("token id file is not int32 aligned")
    ids = struct.unpack("<%di" % (len(raw) // 4), raw)
    need = args.n_ctx * args.n_chunk
    if len(ids) < need:
        raise SystemExit(f"need {need} tokens, file has {len(ids)}")
    ids = ids[:need]

    codes = 2 * ((args.vocab + 1) // 2) + 4
    scored = args.n_ctx // 2 - 1  # positions n_ctx/2 .. n_ctx-2
    record_bytes = codes * 2
    with open(args.out, "wb") as f:
        f.write(b"_logits_")
        f.write(struct.pack("<3i", args.n_ctx, args.vocab, args.n_chunk))
        f.write(struct.pack("<%di" % len(ids), *ids))
        f.truncate(f.tell() + args.n_chunk * scored * record_bytes)
    print(f"wrote {args.out}: n_ctx={args.n_ctx} n_vocab={args.vocab} "
          f"n_chunk={args.n_chunk} tokens={len(ids)} "
          f"records={args.n_chunk * scored}x{record_bytes}B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
