# Performance record

All numbers below are recorded artifacts, with their sources. Hosts: the
dual-Strix pair; model: Qwen3.8-Flash-Next UD Q4_K_XL; TP2 with the
tbstream transport unless noted.

## Link transport (tbstream)

Qualification gates, as recorded in gufo's
`tools/tbstream/README.md` link-gate table:

| Metric | Value | Reference |
| --- | ---: | --- |
| Exchange latency, 10 KiB, decode shape | p50 22–23 µs, p99 34–42 µs | RDMA (verbs) baseline: 24 µs |
| One-way bandwidth, 1 MiB frames | 1.01–1.03 GB/s | serving config (default throttling) |
| One-way bandwidth, 5 MiB frames | 1.04–1.05 GB/s | serving config |
| One-way bandwidth, 32 MiB frames | 1.13–1.14 GB/s | serving config |
| Bulk one-way, 32 MiB frames | 5.0 GB/s | `evidence/bw-final-r0.log` |

For scale: the raw link is 40 Gb/s dual-lane Gen4 class.

### tbnet head-to-head (measured 2026-10-04, same link)

tbnet (thunderbolt-net, kernel IP over the same XDomain link), MTU
9000, on the serving pair while idle:

| Metric | tbnet | tbstream | Note |
| --- | ---: | ---: | --- |
| Latency | 67–80 µs RTT (`ping -i 0.02 -c 50`) | p50 22–23 µs round-trip 10 KiB exchange | the stream's full 10 KiB round-trip beats tbnet's bare ICMP RTT |
| Bulk bandwidth | 28.5 Gbit/s rx / 31.7 Gbit/s tx (iperf3 TCP, 4 s) | 1.0–1.1 GB/s serving config; 5.0 GB/s @ 32 MiB frames | tbnet's TCP bulk is strong, but its latency and per-packet IP-stack cost is what serving cannot afford |
| Serving path | sockets, kernel IP stack, copies | zero-copy char device; GPU writes partials into ring buffers | the decode loop is latency-bound at 10 KiB exchanges |

## Dual-host TP2 serving (Qwen3.8-Flash-Next Q4)

From the phase-3 serving logs on the pair (39 completed requests,
single-width batches; archived under `evidence/` and the pre-saga
archive — key requests shown):

| Metric | Value | Source |
| --- | ---: | --- |
| Prefill (pp), maximum recorded | **2195.5 tok/s** | phase-3 logs |
| Prefill @ 24 900-token prompt | 2169.0 tok/s, TTFT 11.5 s | `baseline-r0.log` |
| Prefill @ 61 010-token prompt | 2104.6 tok/s, TTFT 29.1 s | `baseline-r0.log` |
| Decode (tg), maximum recorded | **63.3 tok/s** | phase-3 logs |
| Queue overhead | ≤ 87 ms (typically < 10 ms) | phase-3 logs |

Notes:

- These are width-1 requests; multi-user/batched decode has not been
  re-benchmarked end-to-end on the pair yet (the single-host gufo
  multi-user MTP table reaches 75.9 tok/s at 4 users, 106.5 at 8 —
  the dual-host equivalents are pending measurement).
- All requests above ran MTP speculative decoding (draft acceptance
  60–87 % in the samples shown).

## Context: single-host reference (same model, same gufo)

From gufo's `BENCHMARKS.md` (single Strix host, no TP2):

| Metric | Single host | Dual-host TP2 (this project) |
| --- | ---: | ---: |
| Prefill pp (depth 0) | 1628.5 tok/s | up to 2195.5 tok/s (+35 %) |
| Prefill pp (depth 131 072) | 1335.9 tok/s | 2104.6 tok/s @ 61 k (+58 %) |
| Decode tg, single user | 25.9 (AR) / 59.2 (MTP repetitive) | 63.3 (MTP) |

The dual-host pair also unlocks context/quant sizes that do not fit a
single 122 GB host (Q8 at 262 144-token context is loaded as TP2
shards in ~36 s).
