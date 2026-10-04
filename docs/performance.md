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

For scale: the raw link is 40 Gbit/s dual-lane Gen4 class (5 GB/s line rate).

### tbnet head-to-head (measured 2026-10-04, same link)

tbnet (thunderbolt-net, kernel IP over the same XDomain link), MTU
9000, on the serving pair while idle:

| Metric | tbnet | tbstream | Note |
| --- | ---: | ---: | --- |
| Latency | 67–80 µs RTT (`ping -i 0.02 -c 50`) | p50 22–23 µs round-trip 10 KiB exchange | the stream's full 10 KiB round-trip beats tbnet's bare ICMP RTT |
| Bulk bandwidth | 3.6 GB/s rx / 4.0 GB/s tx (iperf3 TCP, 4 s; 28.5 / 31.7 Gbit/s) | 1.0–1.1 GB/s serving config; 5.0 GB/s @ 32 MiB frames | tbnet's TCP bulk is strong, but its latency and per-packet IP-stack cost is what serving cannot afford |
| Serving path | sockets, kernel IP stack, copies | zero-copy char device; GPU writes partials into ring buffers | the decode loop is latency-bound at 10 KiB exchanges |

All bandwidth figures in GB/s (1 GB/s = 8 Gbit/s). For scale: the raw
link is 40 Gbit/s (= 5 GB/s line rate) dual-lane Gen4 class.

## Dual-host TP2 serving (Qwen3.8-Flash-Next Q4)

**Methodology caveat first:** the dual-host requests recorded so far
come from the TP2 *qualification* harness (width-1, short decode
windows of 32–512 tokens, synthetic prompts), not from gufo's
benchmark corpora with timed tg128 decode windows. Prefill numbers
are compute-bound and depth-comparable; decode numbers are
indicative until the bench harness runs on the pair.

Recorded requests (phase-3 logs, `evidence/` + pre-saga archive):

| Request | Prompt tokens | pp (tok/s) | tg (tok/s) | Window / MTP acceptance | Source |
| --- | ---: | ---: | ---: | --- | --- |
| r4-class long prefill | 61 010 | **2104.6** | 62.6 | 32 tok, 76.7 % | `baseline-r0.log` (Q4 confirmed by loader line) |
| long prefill (same depth) | 61 010 | **2195.5** | 62.3 | 32 tok | `serve-q8b-r0.log` (target model is Q4_K_XL; filename refers to the draft variant) |
| long prefill | 24 900 | 2169.0 | 48.2 | 32 tok, 60.7 % | `baseline-r0.log` |
| short chat | 69 | 178.8 | **63.3** | 64 tok, 71.4 % | `serve-r0-m3.log` |
| short chat | 70 | 144.5 | 61.6 | 461 tok, 86.6 % | `baseline-r0.log` |

Depth-matched comparison against gufo's single-host benchmark tables
(same model, benchmark corpora, tg128):

| Depth | Single-host pp | Dual pp | pp gain | Single-host tg (mixed/rep) | Dual tg | tg note |
| ---: | ---: | ---: | ---: | --- | ---: | --- |
| ~0 | 1628.5 | — | — | 32.1 / 59.2 | — | — |
| ~61–65k | 1316.7 | 2104.6–2195.5 | **+60–67 %** | 32.6 / 46.1 | 62.6 | indicative only (¹) |
| ~131k | 1335.9 | — | — | 34.2 / 45.0 | — | — |

¹ Qualification prompt vs benchmark corpus; 32-token decode window.
Pending: run gufo's bench harness on the pair (both corpora, tg128,
multi-user batching) for benchmark-grade decode numbers.

## Context: single-host reference (same model, same gufo)

Single-host figures throughout this file are from gufo's
`BENCHMARKS.md` (single Strix host, no TP2, benchmark corpora with
timed tg128 windows). The dual-host pair also unlocks context/quant sizes that do not fit a
single 122 GB host: Q8 at 262 144-token context loads as TP2 shards in
~36 s (loader line, `baseline-r0.log`; that run's short-prompt decode
samples were 41.8–48.2 tok/s at width 1).
