# Performance record

All numbers below are recorded artifacts, with their sources. Hosts: the
dual-Strix pair; model: Qwen3.8-Flash-Next UD Q4_K_XL; TP2 with the
tbstream transport unless noted.

## Link transport (tbstream)

Qualification gates, as recorded in gufo's
`tools/tbstream/README.md` link-gate table:

| Metric | Value | Source / note |
| --- | --- | --- |
| Exchange latency, 10 KiB (decode shape) | p50 22–23 µs · p99 34–42 µs | RDMA (verbs) baseline: 24 µs |
| One-way bandwidth, serving config | 1 MiB **1.01–1.03** · 5 MiB **1.04–1.05** · 32 MiB **1.13–1.14** GB/s | default throttling |
| Bulk one-way, 32 MiB frames | **5.0 GB/s** | `evidence/bw-final-r0.log` |

For scale: the raw link is 40 Gbit/s dual-lane Gen4 class (5 GB/s line
rate).

### tbnet head-to-head (measured 2026-10-04, same link)

tbnet (thunderbolt-net, kernel IP over the same XDomain link), MTU
9000, measured on the idle serving pair:

| Transport | Latency | Bulk bandwidth |
| --- | --- | --- |
| tbnet | 67–80 µs RTT (`ping -i 0.02 -c 50`) | 3.6 GB/s rx · 4.0 GB/s tx (iperf3 TCP, 4 s; 28.5 / 31.7 Gbit/s) |
| tbstream | p50 22–23 µs (round-trip 10 KiB exchange) | 1.0–1.1 GB/s serving config · 5.0 GB/s @ 32 MiB |

- The stream's full 10 KiB round-trip is faster than tbnet's bare
  ICMP RTT.
- tbnet's TCP bulk is strong, but its latency and per-packet IP-stack
  cost are what serving cannot afford: the decode loop is
  latency-bound at 10 KiB exchanges.
- Serving path: tbnet goes through sockets, the kernel IP stack and
  copies; tbstream is a zero-copy character device with the GPU
  writing partials straight into ring buffers.

All bandwidth figures in GB/s (1 GB/s = 8 Gbit/s).

## Dual-host TP2 serving (Qwen3.8-Flash-Next Q4)

**Methodology caveat first:** the dual-host requests recorded so far
come from the TP2 *qualification* harness (width-1, short decode
windows of 32–512 tokens, synthetic prompts), not from gufo's
benchmark corpora with timed tg128 decode windows. Prefill numbers
are compute-bound and depth-comparable; decode numbers are
indicative until the bench harness runs on the pair.

Recorded requests (phase-3 logs, `evidence/` + pre-saga archive):

| Request | Prompt tok | pp (tok/s) | tg (tok/s) | Window · MTP acc. | Source |
| --- | ---: | ---: | ---: | --- | --- |
| Long prefill | 61 010 | **2104.6** | 62.6 | 32 tok · 76.7 % | `baseline-r0.log` ² |
| Long prefill | 61 010 | **2195.5** | 62.3 | 32 tok | `serve-q8b-r0.log` ³ |
| Long prefill | 24 900 | 2169.0 | 48.2 | 32 tok · 60.7 % | `baseline-r0.log` |
| Short chat | 69 | 178.8 | **63.3** | 64 tok · 71.4 % | `serve-r0-m3.log` |
| Short chat | 70 | 144.5 | 61.6 | 461 tok · 86.6 % | `baseline-r0.log` |

² Q4 confirmed by the loader line.
³ Target model is Q4_K_XL — the filename refers to the draft variant.

Depth-matched comparison against gufo's single-host benchmark tables
(same model, benchmark corpora, tg128):

| Depth | Metric | Single host | Dual TP2 | Gain / note |
| ---: | --- | ---: | ---: | --- |
| 0 | pp | 1628.5 | — | single-host best (reference) |
| 0 | tg mixed / repetitive | 32.1 / 59.2 | — | single-host best (reference) |
| ~61–65k | pp | 1316.7 | **2104.6 – 2195.5** | **+60 – 67 %** |
| ~61–65k | tg mixed | 32.6 | 62.6 | ~+92 %, indicative ¹ |
| ~61–65k | tg repetitive | 46.1 | 62.6 | ~+36 %, indicative ¹ |
| ~131k | pp | 1335.9 | — | not yet recorded |

¹ Qualification prompt vs benchmark corpus; 32-token decode window.
Pending: run gufo's bench harness on the pair (both corpora, tg128,
multi-user batching) for benchmark-grade decode numbers.

## Capacity unlock

Single-host figures throughout this file are from gufo's
`BENCHMARKS.md` (single Strix host, no TP2, benchmark corpora, timed
tg128 windows). Beyond throughput, the pair unlocks configurations
that do not fit one 122 GB host at all:

| Configuration | Single host | Dual-host TP2 |
| --- | --- | --- |
| Q4 @ 262 144-token context | 87 GB, fits | fits with headroom |
| **Q8 @ 262 144-token context** | does not fit | **loads as TP2 shards in ~36 s** (loader line, `baseline-r0.log`; short-prompt decode samples 41.8–48.2 tok/s at width 1) |
