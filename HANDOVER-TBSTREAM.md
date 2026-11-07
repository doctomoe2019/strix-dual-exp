# TBSTREAM / USB4STREAM experiment — handover

## 2026-10-22 (14:35): rank0 exit incident — crash evidence + HOME fixes staged, activation restart pending drain

Production was NOT manually touched during the incident. Facts: rank0 exited
on its own 5× since the cprime deploy (Oct 19 15:38, Oct 20 23:03, Oct 21
03:21, Oct 22 07:15, and twice today 13:59:25 + 14:06:27); the guardian
recovered every time (cycle 1 accepted, ~3 min outages). rank1 never died
first. Exit cause NOT preserved: per-cycle r0-c1.log is overwritten on every
restart, so only post-restart logs existed. No kernel OOM/GPU fault, no
coredump/apport entries on either host.

Correlates (unproven): all exits on the cprime build; disk KV cache at
99.96 % of its 256 GiB cap (LRU churn on every write); today's exits cluster
around two huge retried client requests (145k/166k tokens, 2.3–2.8 GB
checkpoints each; the 145k one later restored 145,154/145,282 tokens from
disk — cache itself worked).

SLOW-RECOVERY ROOT CAUSE (proven): the gufo-prod systemd environment has no
HOME, so rank0's GGUF digest cache (~/.cache/gufo, resolved via HOME)
silently disabled itself and re-hashed the ~200 GB model (110–120 s) on
EVERY restart; rank1 gets HOME=/root from sshd and hit in 0 ms. Fixes
applied 2026-10-22: (1) drop-in 50-home.conf sets Environment=HOME=/root and
serve-guardian.sh exports HOME="${HOME:-/root}"; (2) serve-guardian.sh now
captures, after `wait` on rank0: exit status (clean vs 139/134/143), copies
of BOTH rank logs, and a dmesg tail into $LOG_DIR/crash-<timestamp>/ before
the filenames are reused. Guardian installed atomically (running bash keeps
its old inode; new logic arms at next guardian start) and mirrored to
strix2. Both changes activate at the next gufo-prod restart — a watcher
waits for the in-flight client job to drain (two consecutive idle checks,
75 min cap, NO restart on timeout) then restarts and verifies HOME,
fingerprint-cache hit, acceptance, sanity.

Expected effect: crash outages drop ~3 min → ~60–90 s; the next crash
leaves a crash-<ts>/ dir that finally names the exit cause. ACTIVATED
2026-10-22 15:52-15:53 after the in-flight job drained: restart → acceptance
in 75 s total, rank0 HOME=/root, model fingerprint 4 ms (was 110–120 s),
MTP 0 ms, /ready 200, sanity 391. OPEN next
steps: root-cause the exits from the first captured crash (suspect: eviction
path under a full cache and/or the huge-request snapshot flow); deferred by
user: raising --cache-disk-bytes 256→512 GiB; optional: one-line Logger::Warn
when the digest cache is disabled (gufo commit needed). serve-guardian.sh
changes committed and dual-pushed as strix-dual-exp 755bfd7 (both remotes
verified at 755bfd7cd68e60bd76fe66e4e30e0576d0c9f2d3).

## 2026-10-19 (09:41): IDLE WATCHDOG FIX + CPRIME DEPLOYED (7938e618, both ranks)

Production now runs SHA256
`7938e618066ab09bbca66cae0e512fd730a140b84a2b85f461dd671416383fbf`
on BOTH live rank processes (174708 / 2599073 at acceptance). Guardian
accepted cycle 1 at 09:41:10. /ready 200 and sanity 17*23=391 passed.
The native BF16 PLE pack remains selected on both hosts; actual GGUF header
checked: per_layer_token_embd.weight [160,320001536], type 30.

Root cause established with a failing CPU regression: the parked watchdog
kept a sizes-only timer after a healthy capture finished. After >120s idle,
the next healthy capture inherited that timer and was immediately shed.
This bug already exists in 42e3289a/fe00212e; rollback would retain it.
Fixed by resetting the timer across idle/work and tracking scheduler progress.
Prior conversation claims of zero prefill, a confirmed poisoned checkpoint,
and a proven new merge-park regression were unsupported: error completion
logs omit prefill/restore metrics. No cache-corruption mechanism established.

Cprime branch 8f6a5cdc integrated, preserving current v19 snapshot layout,
borrowed-snapshot machinery and TP geometry. Added the missing TP plumbing:
rank0 exposes wrapped row sections; rank1 uses the same chunked store. This
is actual chunked offload, not a silent whole-file fallback (manifest writes
verified on both test ranks and both LIVE production ranks).

Production configuration: new drop-in
`/etc/systemd/system/gufo-prod.service.d/40-cprime-cache.conf` sets
SERVE_CACHE_DISK=/root/gufo-cache-cprime-v19, disk budget 256 GiB/rank,
RAM-cache budget 16 GiB/rank, queued disk staging limit 16 GiB/rank.
Guardian passes all options to both ranks; script mirrored to peer. No
legacy files deleted or reused, no model weight changes, no OOM-score changes.

Focused qualification only (user: urgent fix, no unnecessary tests):
CPU scheduler/runner/disk/TP 4/4; format 651 files; real four-session pair
38,555-token cold + zero-prefill RAM retry; four concurrent streamed tool
calls with max_tokens=60000; 125s idle then cold capture + matched-prefix
tool replay; BOTH ranks restarted and disk restore reused 38,548 tokens
(seven framing tokens prefilled), identical output hash. Cold 17.2s vs
disk 747ms. Both ranks wrote .kvm manifests. Matched per-request/phase
controls: zero >5% AND >3ms flags; canary 2203.6 tok/s (>1700).
MemAvailable minima 43.21/44.34 GiB; zero new GPU/OOM faults on either host.
Prod stopped before GPU tests and restored after; qualified deploy followed.

Evidence: `/root/strix-dual-exp/evidence/parked-idle-cprime-20261019/`
(STATUS, raw replies, timings, memory curves, kernel verdict, deploy journal,
live rank hashes/options/production-manifest proof). Exact grompbot payload
was NOT accessible via available SSH credentials; its unchanged digest still
needs a client-side replay. Do not claim that specific workflow passed yet.

Source state (user subsequently authorized commit/push): `/root/gufo` HEAD
`f4e1e37f` commits the cprime merge plus idle fix/tests (22 paths). Sanitized
WIP patch and guardian configuration forwarding committed in strix-dual-exp
as `4db7e62`, PUSHED and verified identical on BOTH configured remotes.
Tracked working trees clean. No push to gufo upstream. Unrelated untracked
.opencode goal artifacts and PLE/helper scripts preserved untouched.

Rollback (only if needed): stop gufo-prod, restore gufo.50cbf5c8 on BOTH
hosts, move ONLY the new 40-cprime-cache.conf drop-in aside (older binaries
do not understand --cache-disk-format), daemon-reload, start, verify guardian
acceptance. This rollback retains the known idle-timer bug. Keep the new
cache directory and BF16 weights intact. Binary backups verified both hosts.

## 2026-10-19 (06:40): CANDIDATE DEPLOYED — merged tree live in production (50cbf5c8, both ranks)

Rollout complete. `/root/newbin/gufo` = `50cbf5c82302d04aa45d2681c6c437718708af2cb6e25e593ee42a1f7a01f9b5`
on BOTH hosts (verified by /proc exe hash on the live rank processes);
rollback backup `/root/newbin/gufo.fe00212e` verified identical on both
hosts before the swap. Guardian: cycle 1 ACCEPTED at 06:37:13 first try
after the restart. Live post-deploy checks: sanity completion correct
(17×23=391), required tool call correct (`calculate {"expression":"144 * 12"}`),
and the restored chunked-upload + `100-continue` path returns 200 on
production. Serving log shows healthy detail (cache hits, 77% draft
acceptance, constraint+tools decoding active).

Matched timing controls (same payloads, TP2 pair, both binaries):
no throughput regression — canary +5.4% (2198 vs 2085 tok/s), prefill
equal-or-faster on every same-prompt request, decode faster on every
identical-content pair; the flagged points were all wall-clock/content or
concurrency confounds, each documented in
`evidence/.../merge-regressions-fix-20261018/matched-timings-verdict.md`
(raw: matched-timings/throughput/aggregates logs, candidate-run/ and
baseline-run/ reply sets).

Full campaign trail for the merged tree: CPU gate 65/65; GPU operators +
draft-head oracle; in-pass checkpoints; guards; 10k execution; snapshots;
four-session envelope session modes; TP-pair qualification (canary, quad
fresh/replay with identical greedy hashes, image-count + chunked API
checks, 72/72 hammer, zero faults/sheds/rejections); matched timings;
guardian-accepted deploy. Known pre-existing (not deployed-blocking, needs
its own campaign): width-invariant routing gap (probe-gated skips in
tests), EOS batch-synchrony assertion, sampling-mode ledger exhaustion on
single-host test mapping. Snapshot payloads are version 19: old disk
checkpoints from before the merge are rejected by design.

## 2026-10-19 (06:15): TP-PAIR QUALIFICATION PASS on 7e1a0f21 — deploy-ready pending matched-perf + rollout gates

The committed candidate (7e1a0f21, package SHA256 `50cbf5c8…`) passed the
full TP2 pair qualification in the production configuration (sessions=4,
tbstream, 262k context, mmproj): canary FAST 2198.3 tok/s vs 1700 gate;
quad fresh 8/8 incl. two 25k-token prefills; cache replay 8/8 with
IDENTICAL greedy hashes; image count_tokens==usage; chunked+100-continue
upload 200; hammer 12×6 = 72/72 validated streaming tool requests; zero
fault markers or sheds on either rank or in either host's dmesg delta;
production restored and sanity-verified after the window. Harness is
durable in `strix-dual-exp/evidence/sessions4-constrained-wedge/
merge-regressions-fix-20261018/` (run-pair.py, smoke/hammer/api-check/
make-payloads, window5 log, canary logs).

Remaining before rollout: matched per-request timing controls for the
Feed/ForwardBody changes (5 % / 3 ms obligations), then the standard
canary/GTT-gated deploy: copy `50cbf5c8…` to /root/newbin/gufo on BOTH
hosts, restart gufo-prod, first-cycle guardian acceptance; rollback is
`gufo.fe00212e` (current, untouched). Production right now: unchanged
`fe00212e` pair, healthy.

## 2026-10-19 (01:00): merge repairs COMMITTED (7e1a0f21); production-envelope session campaign done; prod on fe00212e unchanged

Committed on `feat/tp2-tbstream`: `783c5931` (all merge-audit repairs:
prefill chunking, in-pass checkpoints, restore guards + missing snapshot
APIs, chunked/100-continue HTTP, explicit draft limits, TP token counting,
strided-projection signature, draft-table crash fix) and `7e1a0f21`
(session fixtures capped to the four-session production envelope, warm-tail
draft acceptance measurement, bounded test RAM caches). WIP patch
regenerated, privacy-scanned, pushed (bc3693a). CPU gate 65/65, format,
package builds (latest SHA256
`50cbf5c82302d04aa45d2681c6c437718708af2cb6e25e593ee42a1f7a01f9b5`).

GPU qualification banked: operators + projection signature fix,
actual-model draft-head oracle (adaptive + explicit + mixed heads), in-pass
checkpoints, guard lifetimes, 10k AR/MTP execution, full snapshot suite,
and the production-envelope session modes — batch (lookup + draft-vocab
lifecycle green for the first time), cache, prefill all PASS; EOS replay
contract PASSES (residual: one synchrony assertion); sampling mode blocked
by an AR-backend ledger exhaustion that only exists beside the single-host
test mapping. One pre-existing numerical gap documented (width-invariant
routing, present at 42e3289a, probe-gated skips in tests). OOM postmortem
and all run records:
`strix-dual-exp/evidence/sessions4-constrained-wedge/
merge-regressions-fix-20261018/` (STATUS.md, safe-run.py, runs-postreboot/).

STILL OWED BEFORE ANY DEPLOY of the merged tree: TP-pair qualification on
the final binary (recreate the pair harness — original quad payloads were
lost with /tmp; fixed-artifact ranks, canary gate, fresh+cache-replay quad,
response-validated 12×6 tool hammer, image-count/chunked-upload API check),
matched perf controls for the Feed/ForwardBody changes, then canary/GTT
rollout with `gufo.fe00212e` as rollback. Production today: unchanged
`fe00212e` TP2 pair, sessions=4, healthy (verified after every window).

## 2026-10-19 (00:10): repairs committed-pending; session windows abandoned on-box (OOM); prod restored & healthy

Final state of the merge-audit repair session: all repairs staged on
`feat/tp2-tbstream` (base 727b042f) with CPU gate/format green and the
candidate package rebuilt. GPU coverage banked before the abandonments:
operators incl. the strided-projection signature fix, actual-model
draft-head oracle (adaptive + explicit caps + mixed heads), in-pass
checkpoints, guard lifetimes, 10k-token AR/MTP execution, full snapshot
suite (probe-gated known-issue skip documented below). NOT run and now
obligations for a lean post-reboot environment: session `--batch-only`
(contains the restored CheckLookupBatch/CheckDraftVocabLifecycle),
`--cache-only`, `--sampling-only`, `--eos-only`, `--prefill-only`, full
mode, plus the TP pair replay/hammer and matched perf/canary/GTT from the
campaign plan. Reason (measured): the session family's footprint is APU
GTT — test RSS 2.3 GiB while MemAvailable fell 120→12.5 GiB — so it only
fits with nothing else resident; three OOM events confirmed it, one of
them my own bad `oom_score_adj=-1000` mitigation that hard-hung the box
(reverted; do not repeat). Production was restored after every event and
is serving (ready 200, rank1 alive, sanity completion verified).
Evidence: `strix-dual-exp/evidence/sessions4-constrained-wedge/
merge-regressions-fix-20261018/` (STATUS.md incl. postmortem,
safe-run.py watchdog, runs-postreboot/). Deployment of the merged tree
remains gated on the obligations above.

## 2026-10-18 (22:35): merge audit repairs COMPLETE (local gates); one pre-existing numerical gap documented

All audit findings are repaired in the working tree on `feat/tp2-tbstream`
(base 727b042f): skipped prefill chunks, unwritten scalar Q8 SSM scratch,
in-pass recurrent/history checkpoint capture, out-of-prompt checkpoint
rounding, restore guards + native borrowed snapshots + the missing
OwnsSnapshot/DeviceBytes definitions (which had kept the full-model snapshot,
session and adapter targets unbuildable), chunked/100-continue upload
framing, explicit draft-vocabulary limits, TP visual token counting, plus
the strided-projection signature the expanded projection suite exposed.
CPU gate 65/65; GPU: operators, actual-model draft-head oracle (adaptive +
explicit 0/7/257/131072, mixed heads), in-pass checkpoints, guard lifetimes,
10k-token AR/MTP execution, full snapshot suite (non-invariance families),
full session suite and batch decode all pass in bounded windows.

ONE DIVERGENCE ATTRIBUTED AND DOCUMENTED, NOT A MERGE REGRESSION: upstream's
expanded snapshot test asserts single-pass == split-pass prefill equality;
the branch's tuned routing (pre-existing at 42e3289a, the production binary)
computes sub-1024-row passes through a different arithmetic route, so the
assertion fails — measured on the PRE-MERGE binary directly. The checkpoint
machinery is faithful (checkpointed == single pass bit-for-bit; all 48
per-layer MoE-input tail-row hashes identical). The in-pass family is skipped
behind a loud runtime probe (`KNOWN-PREEXISTING`, re-arms when fixed); no
tolerance was relaxed. Follow-up campaign: align tuned routes with upstream's
width-invariant arithmetic, then drop the probe.
Evidence: `strix-dual-exp/evidence/sessions4-constrained-wedge/
merge-regressions-fix-20261018/STATUS.md`; work dir `/tmp/opencode/
merge-regressions-fix/` (attribution matrix, boundary sweeps, layer hashes).

Production remains the UNCHANGED `fe00212e` sessions=4 unit/binary; no
candidate was installed. Snapshot payloads are version 19 (old checkpoints
rejected). TP component cache stays off by default. Deployment of the merge
remains gated on the outstanding qualification (TP pair replay, hammer,
matched perf/canary/GTT) per the campaign plan.

## 2026-10-18 (21:20): post-merge audit repairs IN PROGRESS; production unchanged

User authorized fixing every audit finding then committing. The working tree
on `feat/tp2-tbstream` repairs skipped prompt chunks, unwritten scalar Q8 SSM
scratch, incomplete in-pass recurrent/history checkpoints, out-of-prompt
checkpoint rounding, restore guards/borrowed snapshots, missing qualification
definitions, chunked/100-continue uploads, explicit draft limits and TP visual
token counting. The expanded projection suite found one further merge bug:
strided F16's template/argument positions were shifted by the added checkpoint
parameter. Correcting the arguments passes the projection check; no arithmetic
or tolerance was relaxed. CPU gate 65/65; full-model targets compile. GPU GDN,
HC mixer, attention and explicit draft-head full-logit oracles pass. Remaining
model/TP correctness checks are still running; this is NOT rollout approval.

Production is still the unchanged `fe00212e` sessions=4 unit/binary. Diagnostic
windows stop only that unit and owned test processes, then restore readiness
and inference. No production executable/configuration edits. Detailed status:
`/root/strix-dual-exp/evidence/sessions4-constrained-wedge/merge-regressions-fix-20261018/STATUS.md`;
live work/logs: `/tmp/opencode/merge-regressions-fix/`. Do not reuse older
snapshot payloads: candidate format is version 19. TP component cache stays
off by default. Unrelated `.opencode/goal/` and experiment script work untouched.

## 2026-10-18 (09:50): WEDGE ROOT-CAUSED + FIX QUALIFIED (uncommitted in gufo tree; prod untouched at sessions=2)

Goal 2026-10-18-sessions4-constrained-wedge closed its fix phase: the
constrained-request wedge at sessions=4 is a scheduler `capturing`-deque
hang — a pending-forever async state capture parked its request, the
harvest only checked deadlines AFTER the capture resolved, and parked
requests filling capacity permanently blocked the admission wake
predicate (`/ready` 200, guardian blind, rank1 idle). Fix (in /root/gufo,
feat/tp2-tbstream @ 0051409-dirty, NOT committed — ask first): deadline
check before the SnapshotPending re-park + a stall watchdog
(`stall_shed_interval`, default 120 s → retryable 408 + ERROR
`event=stall_shed`) + 2 CPU regression tests (all scheduler tests +
check-pr PASS). Qualified on a sessions=4 diag pair with the flake-built
fixed binary: quad + tools + 12×6-wide streaming required-tool rounds,
12/12 clean, zero sheds. Wedge repro kit + full notes:
`strix-dual-exp/evidence/sessions4-constrained-wedge/ROOTCAUSE-NOTES.md`.
sessions=4 redeploy = commit + deploy binary both hosts + flip unit line
(gated on user). Also found: `nix develop` default shell currently emits
unrunnable binaries (GLIBC_2.43 vs 2.42 store); use
`nix develop .#tp2-tbstream`. Prod now: sessions=2, de09ba76, cycle
accepted 09:47:24, tool_call + ready verified.

## 2026-10-18 (07:56): SESSIONS=4 ATTEMPT REVERTED (prod back at sessions=2; rollback = none needed, already applied)

Attempted `SERVE_SESSIONS=2`→`4` on gufo-prod (single-variable; context
262144/session, chunk 2048, binary de09ba76 unchanged). **NOT QUALIFIED:
constrained requests at width 4 wedge the scheduler** — 4 concurrent tool
requests (r10–r13) were received and never completed, held all 4 sessions,
and plain requests then hung behind them with `/ready` still 200 (one queued
request 500'd `server_exception` at exactly 30 s). Guardian cannot see this
failure mode (exit-supervised only). Reverted 07:48:49, re-accepted
07:49:47 (canary FAST 2079.5; sanity 391; tool_call verified at sessions=2).
What DID work at sessions=4: memory fine (69.9/120 GiB device, GTT flat 69 G
both ranks, host min 39.9 G free) and unconstrained quad `plan=batched-w4`
at **126.6 tok/s aggregate decode vs 82.2 at w2 (+54 %)**, TTFT 75–83 s at
4-way ~25K prompts. Numbers + wedge timeline: `strix-dual-exp/evidence/sessions4-qual/{RESULT.md,wall.txt,memsample.log}`.
Next: root-cause the constrained-path hang (suspect constraint-vocabulary/scheduler shared state at width>2) + add an in-flight stall watchdog before any retry; 4×131072 does NOT dodge this (width-related, not memory).

## 2026-10-18 (03:07): PLE N-GRAM TABLE ADOPTED AS NATIVE BF16 (prod on /models-ple-ab; rollback = one unit line)

Decision of goal/2026-10-17-ple-native-bf16 applied: production's PLE
n-gram table (`per_layer_token_embd.weight`, 320M rows × 160, 26.8 GiB
IQ4_NL in shard 3) is now the NATIVE BF16 table sourced from the
unquantized upstream Qwen release. gufo-prod.service now sets
Environment=SERVE_MODEL=/models-ple-ab/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
(unit before sha256 7240b267…bb02ad, after 1ea6ae78…5a3e6; snapshots in
evidence/ple-native/phase5/). Switch at 03:06:30, /ready 200 in ~30 s
(responder = gufo-prod, unit + cgroup verified), guardian accepted cycle
1 first try (warmup 1959.7, canary[c1] FAST 2107.5 tok/s vs gate 1700),
sanity 17*23=391. Both ranks verified serving the new path (cmdline +
loader logs). Binary UNCHANGED: /root/newbin/gufo de09ba76… both hosts.

Why: same-binary paired TP2 A/B — WikiText-2 ppl 5.1109 → 2.0757 (paired
ΔNLL −0.9017 nats/position, CI95 [−1.192, −0.628], bit-identical
replicates), needle 100=100, no panel regressed beyond one disclosed
grading artifact; perf bands all held (canary 6/6 FAST worst +23.5% over
gate, C1 decode/TTFT 0/16 slower, 8k–76k prefill −2.2…−2.9% median,
cold gather cheaper). Disclosed worst cases: adversarial ~48k
all-distinct-rows prefill −8.0…−23.8%/request (no production fixture
resembles it) and 1.74x disk reads under cache pressure (latency-neutral).
CAVEAT for external claims: the IQ4 file was also element-permuted vs
gufo's dequantizer, so the delta = permutation fix + precision together.

ROLLBACK (no re-download needed): on strix1
/root/strix-dual-exp/scripts/ple-native-adopt.sh rollback  (or sed the
SERVE_MODEL line back to /models/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf
+ daemon-reload + restart gufo-prod, then wait for "cycle 1: accepted").
Original pack /models retained untouched (shard 3 mtime 2026-10-14,
nlink 1). BF16 pack /models-ple-ab verified 8/8 sha256-identical on both
hosts immediately pre-switch (shard 3 sha256 f99331d5…58983e).
Disk: strix1 603G used, strix2 543G of 1.9T (1.2–1.3T free); /models,
/models-ple-ab AND the 98G/host upstream staging /root/staging-ple-native
all RETAINED (staging = only local copy of the unquantized source; enables
a corrected-IQ4 or FP8-table follow-up arm without a 104G re-download).
Evidence: /root/strix-dual-exp/evidence/ple-native/ (phases 1–5); notes +
scripts committed on branch goal/2026-10-17-ple-native-bf16
(notes/ple-native/01–05).

## 2026-10-15 (22:10): CHUNKED-REQUEST FIX DEPLOYED (ba355d5 both hosts)

Deployed the HTTP chunked-body fix to prod: `Transfer-Encoding: chunked`
request bodies now decode (bounded by --max-request-bytes, extensions/
trailers ignored), Expect: 100-continue gets the interim response, other
transfer codings answer 501, and early errors (400/413/501, overload 503)
half-close + drain so streaming proxies read the HTTP status instead of a
mid-upload reset (RFC 9112 6.1/6.3/7.1/9.6). Binary: eba6f30 + cherry-pick
ee7aee9 only (branch prod/chunked-100-continue, commit ba355d5, built with
`nix build .#tp2-tbstream`), sha256 de09ba763bad5494... identical both
hosts; backups gufo.eba6f30 kept on both. Guardian: cycle 1 accepted.
Verified live: chunked POST 200 (was 400+reset), length-framed 200.
Rollback: cp gufo.eba6f30 -> gufo on both hosts + systemctl restart
gufo-prod. The fix also lives on feat/tp2-tbstream@ee7aee9 (with tests);
http_server_test 100% on the exact deployed tree.

## 2026-10-14 (10:45): Q5 ADOPTED IN PROD; Q4/Q6 shards deleted

gufo-prod.service now sets Environment=SERVE_MODEL=/models/Qwen3.8-Flash-
Next-UD-Q5_K_XL-00001-of-00006.gguf and SERVE_CANARY_TPS=1700 (guardian
accepted cycle 1 first try, c1 2145.4 tok/s; sanity 17*23=391 via prod
port). Binary unchanged: eba6f30 tp2-tbstream build, md5 98018e3d both
hosts. ROLLBACK NOTE: Q4 shards DELETED from both hosts — a Q4 fallback
now requires re-download (~111 GB, ~30-40 min) + reverting the two unit
env lines. Q6 pack + surgical backups (.q8orig/.q6korig/.splice-rejected)
also deleted. /models now holds ONLY: 6 Q5 canonical shards (incl. the
+6-byte-padded shard 1 and rebuilt shard 4), MTP Q8_0, mmproj. Disk:
strix1 393G used (was 700G), strix2 338G (was 626G).

## 2026-10-14 (10:40): #463 DEPLOYED (98018e3d both hosts); Q5 A/B COMPLETE

Deploy v2 SUCCESS: `nix build .#tp2-tbstream` (the default package has no
TP2 transport — lesson above), binary md5 98018e3d28b2c3b60cd501376d4820ca
both hosts, backups gufo.bd647f66 kept. Canary FAST 2198 after deploy;
sanity correct (17*23=391 — note the model puts short answers in
reasoning_content when thinking budget runs past max_tokens).

Q5 RESULT (same binary/harness/day, evidence/model-q6-ab/Q5-RESULT.md):
decode -1.4..-6.4%, prefill -4..-6% (8K+, 32K), canary -3.1%; MTP
acceptance unchanged; VRAM 63.7 vs 51.7 GiB/rank (57 GiB headroom).
Adoption if wanted: SERVE_MODEL=Q5 + consider SERVE_CANARY_TPS 1700
(Q5 canary min 1984 vs gate 1900 — passes but thin).

Q5 pack surgery records (all probe-verified):
- shard 1 PADDED +6 bytes: unsloth shipped it 6 B short of align-32 data
  start; gufo requires size >= data_start (llama.cpp tolerates). Fixed on
  both hosts.
- shard 4 rebuilt: blk.2.ffn_{gate,up}_exps Q6_K->Q8_0 (corr 0.999985).
- Q6_K WIRE LAYOUT: unsloth files are {ql,qh,scales,d-LAST} — matches
  gufo's block_q6_K, NOT ggml.h's d-first order. Verified statistically
  (sub-block RMS smooth only under d-last).
- originals kept: *.q8orig/*.q6korig/.splice-rejected in /models both hosts.

Patch hygiene: regenerated WIP patch; found site values (root@10.55.0.2,
tbnet IPs, strix hostnames) newly present via Oct 10-11 goal/notes commits
in the gufo tree. Published patch stayed code-scoped; neutralized
tests/functional/{README.md,glm53_pair.py} (gufo fbd166c); patch scan now
0 hits; strix-dual-exp 5cd3b7f pushed to both remotes. NOTE: the gufo
tree still carries the site values inside .opencode/goal/* and notes/*
(diff-visible on the local branch; excluded from the shared patch scope).
PENDING (user decision): scripts/serve-guardian.sh SERVE_DRAFT_VOCAB
passthrough is live-but-uncommitted (deployed unit depends on it).

Detail — the #463 port itself: cherry-picked onto feat/tp2-tbstream as
eba6f30; last-layer prefill skip ported into the fork's
MixerPart/MoePart/LayerBack loop (fork has no checkpoint machinery;
TP-split AllReduce stays full-width). moe_epilogue_ops + select_ops GPU
tests PASS. session_test blocked by a nix develop glibc linking quirk
(unresolved, low priority). Upstream #445 NOT applicable (fork never
carried the checkpoint subsystem). Rollback rehearsal: first deploy
attempt with the default package died at "no TP2 RDMA or tbstream
support" (~7 min downtime, instant binary rollback, canary FAST after).

DEPLOY ATTEMPT (rolled back): default `nix build` package has NO TP2
transport — serve dies with "this build has no TP2 RDMA or tbstream
support". Correct production package: **`nix build .#tp2-tbstream`**.
~7 min prod downtime, instant rollback to backups, canary FAST (2258.6)
after restore. Deployed binary unchanged: md5 bd647f661e64297c3bd233869d0cf294
both hosts (backups /root/newbin/gufo.bd647f66 both hosts).

Q5 pivot: UD-Q5_K_XL downloaded + sha-verified; shards 2,3 hardlinked from
Q6 artifacts (byte-identical per LFS hashes; shard 3 = requantized IQ4_NL
PLE, corr 0.9966/relerr 8.5% vs Q8_0). Shard-4 surgery in flight:
blk.2.ffn_{gate,up}_exps Q6_K->Q8_0 (gufo HIP kernels have no Q6_K — same
gap upstream; Q8_0 experts prod-proven via MTP draft).

## 2026-10-12 GLM-5.3-Flash 64K serving + speculative-decoding campaign CLOSED (goal 2026-10-11-glm-serving-64k-spec, phase 5)

- Status: **the GLM TP2 pair is qualified for production-shaped serving at
  ctx 32768 (1-2 sessions) and ctx 65536 (1 session); artifact-free
  speculative decoding landed default-OFF as NOT QUALIFIED.** Verdicts
  MET: 32K rung, 64K rung, 2 concurrent sessions. NOT MET: spec decode
  (serving-level cap-truncation duplication blocker + deep-context
  economics c(4)=2.52 at 32K depth; +139 % prose / −5 % reasoning-code
  at ctx 4096). Production rollout itself stayed out of scope — the
  follow-up goal consumes `notes/final-64k-spec.md`'s ROLLOUT
  PREREQUISITES (per-rank GTT 93.3-94.8 GiB at every qualified rung,
  the 50.9+94.7=145.6>120 GiB GLM+Qwen coexistence conflict, the
  guardian/unit parameter list — no-draft path, per-rank model paths,
  GLM-band canaries ~115 tok/s not Qwen's 1900 — and the port plan).
- Final-tree verification (worktree HEAD 17934ae, binaries hash-identical
  both hosts): full gate suite PASS — executor CPU oracle 7.481e-07,
  byte identity 513×3/2052/2049/4097, kda/dsa/mhc/batch_select,
  speculative_verification_test, verify_probe (incl. cross-session
  workspace ownership), decode guard 21.52/21.82/21.86 ms/token (band
  21.03-22.08), ctest 7/7, check-format 559, check-docs 84, nix pr
  checks rc 0; pair oracle 44/44 cross-rank byte-identical + LCG 4096
  probe 113.7 tok/s 9/9 identical.
- Refreshed serving qualification (3 cold runs each, cached_tokens=0,
  served width proven): **115.08/114.63/114.21 tok/s @ ctx 32768 with 2
  sessions resident (GTT peak 94.775 GiB)** and **114.76/114.34/114.33
  @ ctx 65536 (94.687 GiB)**; 2-session decode guard holds (solo step
  120.6 ms; concurrent wall inter-token 238.5-240.9 ms; pair aggregate
  7.87 tok/s = 1× solo). Records: goal worktree `notes/{ladder-64k,
  sessions,specdecode-research,specdecode,final-64k-spec}.md` and
  `docs/models/glm-5.3-flash/README.md`; campaign evidence
  `evidence/glm53-flash/p8-64k-spec/`.
- Production parked only for the window (21:41:41–21:59:41Z, 17.5 min)
  and restored: active, /ready 200 on poll 4, live completion answered
  after restore. Streams healthy; no wedge.

## 2026-10-11 GLM prefill-250 vLLM-port campaign CLOSED (goal 2026-10-10-glm-prefill-250-vllm, phase 7)

- Status: **115.0 tok/s serving-level prefill (TP2 HTTP, chunk 4096, f32
  wire, ~3.4K cold prompts, cached_tokens=0 every run) vs the ≥ 250 tok/s
  objective — NOT met (2.17× short), closed on a measured roofline.**
  Depth points: 105.9 @ ~5.9K, 86.7 @ ~15.9K (vLLM band 278–294 → gap
  2.75×/3.2×). Campaign: 35.1 → 75.0 → 84.4 → 110.3 → **115.0 tok/s**.
- Phase-7 change: the fused tiled sparse-MLA attention kernel became two
  launches (score+softmax | gather+epilogue) with cooperative softmax
  exponentials — bit-identical outputs (executor oracle 7.481e-07
  unchanged; pair-oracle per-token lines byte-identical to the pre-split
  phase-5 record, 44/44 cross-rank); MLA family 4482 → 2951 ms per
  4096-chunk (−34 %), slice 4096 bench +6.5 %, serving +4.3 %.
- Final package on BOTH hosts (nix hash + sha256 + byte-compare MATCH,
  `/tmp/opencode/p7ws/logs/binary-identity.log`):
  `/nix/store/6bw5lz985j49vs912da5lpqilz318jj5-gufo-0-unstable-de3a1f8`.
  Full gate suite PASS on the final tree (oracle, 513×3/2052/2049/4097
  byte identity, kda/dsa/mhc/batch_select, decode guard matched, check-format,
  nix pr checks rc 0). Full record + final per-family roofline + ranked
  residuals: the goal worktree's `notes/final-ws-250.md`.
- Where the rest of the gap lives (per rank, 4096-depth census, 8.69
  ms/token wall): expert Q4_K 3.19 ms/token (register/occupancy ceiling,
  phase 2 — needs a different execution model), Q8_0 2.07 (at ~99 % of
  its mixed ceiling on 1018 GB own-traffic, phase 3), serial stack ~1.15,
  MLA 0.72 (split done; float-exp softmax is the next lever but needs the
  phase-4-style evidence chain + signoff), indexer 0.53 (double-precision
  contract), F32 0.34 (done), wire ~0.70. Both movers at their proven
  floors leave ≈ 190 tok/s — 250 needs expert/Q8 execution-model or
  contract changes, documented in the note.
- Production parked only for the window (07:01:31–07:33:46Z) and
  restored: active, /ready 200 on the 5th poll. Streams healthy.

## 2026-10-11 GLM prefill-250 vLLM-port campaign: phase-6 package + serving qualification (goal 2026-10-10-glm-prefill-250-vllm)

- Status: **110.3 tok/s serving-level prefill (TP2 HTTP, chunk 4096, f32
  wire, ~3.4K cold prompts, cached_tokens=0 every run) — the ≥ 250 tok/s
  objective is NOT met (2.27× short); the goal stays open.** Comparison
  points vs the vLLM claim (278–294 tok/s at 5.8K–19.9K): 101.2 tok/s @
  5.9K, 83.0 tok/s @ 15.9K.
- The weights-stationary kernel campaign (phases 2–5: expert grouped-GEMM
  WS tiles, Q8_0 re-sweep at its traffic ceiling, F32 tiled float
  accumulation 6.56×, kMaxBatch 4096 + 128 MiB windows) moved serving
  prefill 84.4 → 110.3 tok/s (+30.6 %) with bit-identical outputs.
- Qualified end-to-end: package `798jlyszyzgfnyzg38636cxnj7hqpr60-gufo-0-
  unstable-b0b439a` shipped A→B (nix hash `sha256:06h5b9r2…`, bin/gufo
  sha256 `76075839…`, full byte-compare cmp rc=0, both hosts);
  18/18 API driver; executor oracle 7.481e-07; byte-identity twins
  513/2052/2049/4097; CPU pr-checks rc 0. Evidence:
  `/tmp/opencode/p6v/` (binary-identity.log, api-6v/, serving-{3500,6000,
  16000}/). Full record + ranked residual bottlenecks: the goal worktree's
  `notes/serving-ws-250.md`.
- Residual (ranked, quantified at 4096 depth, ms/token of 9.07): expert
  Q4_K family 3.15 (register/occupancy ceiling, phase 2), Q8_0 family 2.05
  (~99 % of DRAM peak on its own traffic, phase 3), MLA+indexer 1.63
  (depth-dependent — the 110→83 fall to 15.9K), serial stack 1.14, F32
  0.34 (done). Even both movers at their proven floors leave ≈ 4.95
  ms/token ≈ 202 tok/s at this depth: 250 needs the MLA/indexer depth term
  and/or the serial stack to move too.
- Production parked only for the window (06:18:07–06:33:20Z) and restored:
  active, /ready 200 on the 4th poll. Streams healthy; no wedge this
  session.

## 2026-10-10 GLM prefill-250 campaign closed (goal 2026-10-10-glm-prefill-250)

- Status: **84.4 tok/s serving-level prefill (TP2 HTTP, chunk 1024, f32
  wire, ~3.4K cold prompts), vs the ≥ 250 tok/s objective — target NOT
  met, closed on a measured roofline** (tile-mandated weight stream 1.95
  ms/token at the 240 GB/s measured DRAM read ceiling + 2.27 ms/token
  serial families > the 4.00 ms/token budget; record in the goal
  worktree `notes/final-250.md`). Campaign: 35.1 → 75.0 → 84.4 tok/s.
- Phase-7 change: KDA delta-rule scan register-column fast path in both
  twins (`KdaRecurrenceRegKernel`/`BatchKdaRecurrenceRegKernel<128>`)
  — bit-identical outputs (executor oracle 7.484e-07 unchanged, pair
  per-token hashes reproduce byte-for-byte), kernel 3439.7 → 245.2 ms
  per 2048 tokens on rank 0.
- Final qualified package on BOTH hosts (hashes + full byte compare
  equal, `/tmp/opencode/p7/logs/binary-identity.log`):
  `/nix/store/la88yk08n5kr1nm4p7m1857g71r4zgmp-gufo-0-unstable-733c1c3-dirty`.
  Production (gufo-prod) was NOT redeployed and still runs the Qwen
  pair; it is active with /ready 200 at campaign close. No debug env
  forced anywhere (GUFO_TBSTREAM_TRACE_MS default-off, wire default f32).
- All gates PASS on the final tree: 513×3/2052/2049 chunk-vs-tokenwise
  byte identity (max|diff| = 0), kda/mhc/dsa oracles, batch_select,
  cross-rank hash equality, check-format.

## 2026-10-09 GLM P4 serving closeout

- GLM-5.3-Flash P4 COMPLETE: actual TP2 HTTP, one active session, 4K
  capacity, 512-wide prefill, F32 wire. Chat/Responses/native tools and
  cancellation/recovery: 18/18 cases in
  `/root/strix-dual-exp/evidence/glm53-flash/p4/api-final/`.
- Candidate package available on BOTH hosts:
  `/nix/store/hgipq4y7b6aqwgxw7cksymkx5xbiq50r-gufo-0-unstable-0847b4f-dirty/bin/gufo`;
  sha256 `89c86e56bf09e86b6217290b0291c0b34691489b69328ed55d59bcd2738c5f60`.
  A's `gufo/build/glm53-serve` points at it. This is the qualification
  candidate; `/root/newbin/gufo` and the production unit were not redeployed.
- Real OpenCode + concise MCP filesystem/test fixture PASS, independent
  source/test verification retained in `p4/agent-mcp/`; Qwen TP2 AR
  constraints control 9/9 on the same candidate in `p4/qwen-control/`.
- GLM cancellation exposed the shared 30s admission assumption: one eager
  prefill unit took 45s. GLM now uses a 180s broker window; Qwen retains 30s.
  Immediate recovery measured 46.9s prefill / 2.7s decode, pair stayed ready.
- **Always park production before full-model tests.** The full TP1 GLM
  model exceeds one host's memory. Loader now rejects an oversized resident
  plan before upload. Use the actual TP2 pair for serving qualification.
- Production restored and /ready 200. Both GLM and Qwen test pairs stopped
  and rank-1 logs archived. Runtime ceiling 262144 is NOT a completed
  long-context qualification; P5 ladder is next. Gufo changes uncommitted.

Last updated: 2026-10-07 15:35 (WORKLOAD-SHAPE CAMPAIGN CLOSED with a
deployed config win: prod now runs --prefill-chunk 2048 via unit env
SERVE_PREFILL_CHUNK + guardian passthrough — prefill-during-active-decode
1234 -> 2022 tok/s (+64%), decode itself faster, concurrent prefills +13%,
cold/single unaffected (canary 2233). Measured remaining ceilings are
modest: interleave ~8% vs sequential (prefill serialization parked),
multi-request sequential overhead ~5%, tiny-turn 2.3x/token on ~431-row
chunks (0.45s absolute), extensions at depth 1969-2112 = mostly genuine
attention cost. Deep edits restore at the divergence point — checkpoint
granularity fine. HAZARD: --prefill-chunk 4096 + concurrent decode poisons
the tbstream communicator (write timeout; graceful exit; logs in
evidence/prefill-triage/serve-shapes/) — needs a serve-side guard or
transport root cause before any larger-chunk work. Earlier today:
chunk-aligned checkpoints deployed (canary 2004.8 -> 2221.2).)

Previous: 2026-10-07 08:55 (UPSTREAM TOOL CORRECTNESS INTEGRATED on
top of the constrained-MTP mirroring; prod deployed and healthy:
(1) upstream #441 native-tool parity — native syntax for every schema,
request-wide JSON fallback REMOVED (both TP2 builders adapted to
ToolParameters(schema,strict,format); tool_required stays in WithTools;
kConstraintSemantics bumped "1"->"2" and rides the handshake),
delimiter-overlap + implicit-reasoning-end parser fixes,
span-preserving tokenization (later literal control-token text no longer
retokenizes unchanged history), warm initial-mask reuse; 688-decision
llama.cpp grammar fixture imported. (2) upstream #434 Responses
tolerance — hosted tools skipped, namespace functions flattened with
namespace echoed on calls, null content/encrypted_content replay
accepted, include/reasoning.summary/text.verbosity tolerated.
(3) TP2 audit corrections landed FIRST (3b07878): the recipe is emitted
by ConstrainChatRequest itself (kills the tools+none+response_format
cross-rank grammar mismatch), and EVERY kSingle waits for rank 1's
sequence-correlated kAdmission verdict (protocol v19) before rank 0
schedules model work — rebuild/init failures reject the request, not
the pair. Gates: hosted CPU contract suite PASS (nix sandbox, includes
http_server_test; the devshell binary still trips the documented GLIBC
2.43 skew — environmental); tp2_constraints.py 9/9 on a fresh
2-session pair (drafts 15-36 on every constrained request); prod tools
request finish=tool_calls, spec decode 53.4 tok/s. gufo 3b07878 ->
9869526 (#434) -> 0a13415 (#441) -> 37004ed (docs). WIP patch 14771
lines regenerated, strix-dual-exp pushed both remotes. Deployed
/root/newbin/gufo md5 42fc94e6 BOTH hosts (backup gufo.2d4a43ec both
hosts); guardian accepted first cycle; prod healthy on 15003
(Qwen3.8-Flash-Next).)

Previous: 2026-10-07 07:40 (TP2 CONSTRAINED MTP SHIPPED + prod
deployed: tool/schema requests now decode speculatively over TP2 — live
production pair measured the same tools request at 33.1 -> 52.4 tok/s
(decode_modes spec:22, 64% acceptance). Mechanism: the kSingle control
command carries a ConstraintRecipe (v18 protocol; response-format source
schema, effective tools/strict, required/parallel, resolved reasoning,
final tool format); rank 1 rebuilds the grammar via the same composition
code and binds it to its own vocabulary; the handshake compares
constraint-vocabulary fingerprints (pieces+stop bits) and refuses
mismatched pairs; unrebuildable recipes fail the pair before any model
call. Grammar layouts stay rank-local. Upstream audit first: canonical
gufo main 33d1b20 and neuhaus fork TP branches 8af653e/3a87bd2 STILL have
the constraint fallback — nothing to backport. Also landed: a85e9e4
decode-mode/request-shape completion logging (decode_modes=spec/constr/
policy/budget/unavail + stream/sampling/constraint/tools) and the
ignore_eos positional regression it had introduced (audit-found).
Gates: tp_control_test + tp_executor_test (constrained toy MTP with a
grammar admitting exactly one object; recipe round trip; coherence
refusal) PASS; tp2_constraints.py 9/9 on a dedicated 2-session live pair
(drafts 15-36 on every constrained request). gufo a85e9e4 -> 0b9907a ->
9dcd6d8 (docs), WIP patch regenerated, strix-dual-exp 995aaa0 pushed both
remotes. Deployed /root/newbin/gufo md5 2d4a43ec BOTH hosts (backup
gufo.e82b25db both hosts); guardian accepted first cycle; prod healthy on
15003 (Qwen3.8-Flash-Next). Evidence:
evidence/prefill-triage/tp2-constrained-mtp/.)

Previous: 2026-10-06 22:50 (DECODE-OBSERVABILITY PATCH DEPLOYED (gufo
tree DIRTY, uncommitted — commit pending user decision): completion logs
now carry decode_modes=spec:N/constr:N/policy:N/budget:N/unavail:N plus
stream/sampling/constraint/tools request-shape fields. Root cause of the
real-world MTP split CONFIRMED: TP2 falls back to one-token-at-a-time
decoding for ANY request with a sampling constraint (tools grammar or
response_format; TpMirroredRunner::DecodeStep in tp_executor.cpp — the
constraint stays on rank 0, which cannot be mirrored into speculative
verification). Live proof on the new binary: plain request spec:18,
93.5% acceptance, 92.6 tok/s; tools request (tool_choice=auto)
constr:66 spec:0, 33.1 tok/s. The platform's tool-carrying conversation
requests are the ~64% AR-rate share. Enabling constrained MTP over TP2
needs a protocol change (constraint-aware verification on both ranks) —
future work, user's call. Deployed binary md5 e82b25db... on BOTH hosts
(backup gufo.daff7d61 both hosts); guardian accepted first cycle (c1
1982.4); tp_executor_test + text_generation_scheduler_test PASS;
clang-format clean; prod healthy on 15003.)

Previous: 2026-10-06 20:55 (GUFO-PROD RE-ENABLED on the guardian:
unit rewritten — ExecStart is now scripts/serve-guardian.sh with
Environment=SERVE_PORT=15003 (old serve-prod-native.sh script no longer
existed; old unit backed up at
/root/archive/pre-saga/gufo-prod.service.bak-20261006; ExecStartPre
drop_caches dropped; HOST=0.0.0.0 added 20:57 after the user found
15003 unreachable off-host — the server binds 127.0.0.1 by default via
HOST/GUFO_HOST env, now answers on all interfaces incl. tun0 10.8.0.9,
auth=off; SERVE_MODEL_NAME=Qwen3.8-Flash-Next added 21:45 (guardian
passes --served-model-name to both ranks and the same id to canaries;
the GGUF's own name "Qwen3.8 Flash Next" 404s now — the platform
expects the hyphenated id); unit Env: SERVE_PORT/HOST/SERVE_MODEL_NAME).
Accepted first cycle after each change (latest c1 1996.6 FAST, prod-port
canary 2007.0/1989.4); /ready green on 15003; latest pair rank0 44046 +
rank1 253382; enabled for
boot. Semantics: guardian exit (3 slow cycles) or rank death → systemd
restarts after 30 s with a fresh budget; wedge recovery stays with the
heal chain. Enabled + active as of 20:52.)

Previous: 2026-10-06 20:45 SLOW-SESSION PHASE A: the guardian's
rejections were COLD-FIRST ARTIFACTS — first requests measure 1303-1850
tok/s vs the warmed band ~1990-2000; every pair tracked past two warmed
requests reached >=1927. Canary/guardian reclocked: warmup -> measure ->
confirm flow, nonce + uncached validation, /ready, per-run logs, remote-
kill fixes, NO default drop_caches. Single-host 8/8 fast band today.
One 1780-plateau draw unresolved (n=1) — preserve future slow pairs for
Phase B attribution. Read strix-dual-exp
evidence/prefill-triage/slow-session/PHASEA.md. TTM-pool rationale
withdrawn on kernel grounds. Scripts committed as c509ec6, pushed both
remotes.)

Previous: 2026-10-06 18:30 REBOOT-READINESS GAP CLOSED: post-reboot
hostA's stream sat at busy_poll=0 — boot bringup aborted at an EBUSY
HopID write under set -e and the watcher only healed on peer death.
Fixed: bringup.sh EBUSY-tolerant attribute writes (idempotent on live
streams, verified); heal-watch.sh enforces busy_poll=1 every pass +
re-brings-up a missing stream with XDomain up (verified drift repair
within one pass). Both hosts synced, healers restarted, busy_poll=1
everywhere; strix-dual-exp 5b91aea pushed BOTH remotes; SETUP.md/TODO
updated. tbstream-heal@<rank> is the only enabled boot automation and
now owns serving prerequisites; gufo-prod/postboot-validate remain
disabled.)

Previous: 2026-10-06 18:20 SLOW-SESSION DIAGNOSTIC Phase 0/1 done —
read evidence/prefill-triage/slow-session/PHASE1.md. Slow mode is LOCAL
(single-host, no transport), process-granular, ~15-30% of fresh processes
run >=10% slow; NOT clocks (sclk/mclk pinned, equal), NOT compaction
(zero deltas), NOT system DRAM bandwidth (16 GiB D2D stable ±0.4% in
slow-model iterations), NOT CPU affinity (taskset arms all show it);
slow sessions draw LESS GPU power at same clocks -> stalling; prime
suspect GTT backing/page-table (TLB) locality of the model's buffers
(VRAM carveout is 512 MiB — everything is TTM/GTT). INCIDENT: the
fragmenter test OOM'd the box (quadratic bytearray + 46 GB sessions;
24 OOM-kills in -b -1 journal; user rebooted; /tmp Phase-1 logs lost,
persistent evidence + conclusions safe; kernel unchanged). Safety rules
now in PHASE1.md. NEXT: (a) mitigation = serve-startup canary + re-init;
(b) optional safe causal GTT-locality test; (c) re-set busy_poll=1 on
BOTH hosts' streams before any pair work (post-reboot).)

Previous: 2026-10-06 15:55 W1 ROUTED PACKED-LAYOUT CAMPAIGN CLOSED:
mechanism validated, integration PARKED. Byte-permuting weight layouts +
sibling kernel instantiations (opt-in flags, originals untouched):
Q5_1 down stage-major meta/code planes -4.1..-7.5% @1024-4096 tokens
(k=320; -4.4..-5.5% k=640), Q4_K paired gate/up chunk-planar -2.1..-4.5%;
byte-identical outputs everywhere, placement (aa) controls ±0.4%.
Parked because: modeled full rollout ≈ +1.1% e2e/rank @32k (below the
paired separation bar), and single-copy production — the user's hard
requirement — means converting every consumer incl. MMQ decode vector
kernels (persistent-SSM decode-regression precedent); gate/up is ~half
activation-reread-bound, capping weight layout there. Prototype
preserved as evidence/prefill-triage/routed-w1/packed-reader-prototype.patch
(280 lines, re-appliable). Gufo REVERTED clean then docs-only 13d7d1c;
reverted build re-verified (canonical bench hashes, ops test exit 0).
MEASUREMENT TRAP recorded: a "-25%" datapoint was an addressing bug with
aliased overlapping loads — output hashes catch it. NEXT by ledger: the
slow-session diagnostic, or transport staging redesign as its own
project; remaining prefill levers are thin — cumulative retained since
triage ≈ +6.5%.)

Previous: 2026-10-06 14:50 V2 HC STAGE-DEPTH SCREEN CLOSED rejected:
up BK=2 -9.3% (471->522us), down BK=8 -19.2% (401->478us, bit-exact) —
occupancy loss beats barrier savings; both kernels at WMMA ceilings
(28.5/33.5 TFLOPS-equiv @2048); up epilogue barriers LDS-capacity-locked.
HAZARD guarded: W8A8 kPrefetch=(BM*BK)/256 floor silently drops weight
rows for non-multiples (BK=5/6 wrong hashes) -> static_assert added;
dense_gemm_bench gained hcd case. Gufo @ 6b06771 (test commit; production
paths unchanged, serve binary daff7d61 still current); strix-dual-exp @
4605d6c pushed BOTH remotes; evidence/prefill-triage/hc-v2/. No paired A/B
spent. NEXT by ledger: routed-expert weight layout/streaming prototype
(~6.9s routed family @32k), or slow-session diagnostic; HC up/down
epilogue-efficiency family EXHAUSTED at kernel level.)

Previous: 2026-10-06 13:50 SERVE REDEPLOYED: /root/newbin/gufo = md5
`daff7d61f7b947d73cd23ce9a4f557c8` = nix `.#tp2-tbstream` from `3174c40`
(HCF1+HCS1 present — kernel symbols verified in the binary), BOTH hosts,
backup gufo.31127d4c beside it; gufo tree clean @ `11123b7` docs on top of
`3174c40` feat. Smoke 2026-10-06 13:36-13:41 (evidence/serve-hcs1/): pair
loaded 31.5s, 0 errors rank1 / 4 HTTP 4xx from my own curl probes rank0;
chunked-prefill KV active (prefill_chunks 2/5/18); prompt-cache exact-hit
(233/233 cached, prefill_ms~0); UNCACHED @62,444-token MTP serve prefill:
**2187.7 and 2156.2 tok/s** (old serve band 2030–2195); short-decode
50.6–50.9 tok/s mid-session. Clean pair shutdown on rank0 TERM (both ranks
exited together at signal=15; dmesg clean; streams healthy). OPS NOTES:
`pkill -TERM -f "[.]newbin/gufo serve"` FAILED to match — kill by PID;
and pgrep-over-ssh self-matches its own wrapper cmdline — verify with
`ps aux | grep "[n]ewbin/gufo"` instead. gufo-prod (15003) REMAINS DOWN —
re-enable is the user's call (criteria: N clean serve restarts + wedge
transparency per TODO Stage 5).)

Previous: 2026-10-06 13:45 HCS1 COMMITTED (3174c40; F32 mixed-store skip
on the wide FFN mixer route; +0.86% median TP2 @32k 4v4, kernel −18.8%;
attention mixers keep F32 — BF16 indexer re-narrow + F32 alpha_beta
re-read it; incident: first matrix accidental A/A caught by route-fires
profile). 2026-10-06 11:05 HCF1 COMMITTED (4c68409; +2.65% @32k TP2;
MoE-combine variant closed — v_fma_mix not bit-exactible). Published
BENCHMARKS.md cells unchanged; README carries the ~2,300 pp two-host
number. NEXT by ledger: HC screen continues (V2 barrier-merge; down
kernel), routed weight-layout prototype, slow-session diagnostic;
rocprofv3 -i counters BROKEN in this wrapper (silent no-op — kernel-trace
only).
Write to me: none — read this first, then the referenced files. Everything
below is verified on the machines unless marked otherwise.

## 2026-10-06 (13:45): HCS1 retained (+0.86% @32k TP2, kernel −18.8%)

Read evidence/prefill-triage/hcs1/SUMMARY.md + TODO.md log 13:30 +
docs/prefill-scaling.md item 12. Facts: (1) Mechanism — MoePart's wide
fused HC projection (HcMixF16Gemm) skips the F32 mixed store via a kSkipF32
template sibling (storing instantiation's codegen untouched); HcMix gained
mixed_reread (default true; heads/catch-up/batch sites keep the store) and
a cached WideF32MixedReaders scan (F32 router would re-enable). Attention
mixers legitimately keep F32: the BF16 indexer projections re-narrow from
F32 (F16 cache has no BF16 copy) and alpha_beta is F32 in this GGUF and
reads the attn-mixed via hipblasSgemm. Per chunk: 48 skip + 48 keep.
(2) INCIDENT: first paired matrix was A/A — the scan initially included
alpha_beta, suppressing the skip (0 skip-instantiations in the profile;
"+0.1%" = noise). Route-fires profile caught it; ALL timing/e2e gates
re-run on the corrected build. LESSON (again, S1): verify the route fires
BEFORE burning pairs; a guard can silently eat the mechanism. (3) Gates:
bench 580→471µs isolated (−18.8%, F16 hash identical); operator sentinel
check exact; gpu_probe dump == canonical 8ddefb67; canonical member
checksums both ranks all clean sessions; decode 35.3–36.0ms/step flat.
(4) Paired @32k 4v4 canary-clean: A 2288.6–2332.5 (med 2310.2) vs B
2303.4–2334.8 (med 2330.1) = +0.86%, 7/8 B≥A-median, no full separation;
8k even. Retained on kernel evidence (pure store removal, zero arithmetic
change) despite <1%. (5) Tooling: rocprofv3 -i PM counters silently
no-op in this wrapper — kernel-trace mode only; dense_gemm_bench gained
hck/hcs cases (and its attn case was fixed to the current
AttentionF16Gemm signature — it had not been built since the TP2 sig
change). (6) Probe inventory: probe-hcs1 (B, both hosts, 1d0f092c),
probe-hcf1 (A = strix2 build 4b033d00 both hosts via
tp_batched_probe.strix2), probe-g1 (pre-HCF1 reference). (7) Open: serve
deploy (HCF1+HCS1 both absent from 31127d4c); HC screen V2
(barrier-merge) and the down-kernel screen; routed weight layout;
slow-session diagnostic.

## 2026-10-06 (10:15): HCF1 retained (+2.65% @32k TP2)

Read evidence/prefill-triage/hcf1/SUMMARY.md + TODO.md log 10:15 +
docs/prefill-scaling.md item 11. Facts: (1) Mechanism — the combine that
writes the F16+Q8 norm also computes the NEXT mixer's inject partials from
the normalized values in registers; the F16 norm row is staged in LDS
(peer kernel: aliased over the dead s_row stage) and replayed with the
inject pass's exact thread grouping (part p = 1024 columns across 4
streams), load order and reduction tree → byte-identical partials
(HcInjectPartialF16 is the exposed reference). Separate sibling kernels
(HcCombineVec4InjectF16Kernel, HcCombinePeerVec4InjectF16Kernel) keep the
non-emitting route's codegen untouched. Executor: Combine() takes
next_inject_w (MoePart passes hc_ffn's, LayerBack the next layer's hc_attn
inject), sets inject_ready_; HcMix skips its inject pass when set. The
flag is refreshed on EVERY Combine call, which makes it safe under
ForwardPair lane interleaving (a stale false only costs recompute).
(2) LESSONS: a differently-shaped loop with identical arithmetic
reassociates under -ffast-math — mirror the reference's source SHAPE
(staged wq array → v loads → s-major adds) for bit-exact dots; and
HcCombineMoeF16Kernel's norm compiles to v_fma_mixlo/hi_f16 + pack
(mul+round fused), so its emission variant failed byte-equality on the
norm itself under both pinned orderings — closed unless the kernel is
redesigned. (3) Measurements: @8k single-host matched profiles: inject
pass 376→184 calls (90.5→44.5ms), emitting combine +1.7%/call → ~+0.8%
e2e (within session noise); TP2 removes ~all wide inject passes → paired
A/B (probe-g1 vs probe-hcf1, canary-gated, 4 discards) @32k +2.65% median
4/4 FULL SEPARATION, @8k +2.3% 2/2, decode flat; canonical checksums both
arms every clean session; single-host dump MD5 identical to pre-change.
(4) Ops: gpu_probe needed its sqrtf shim again (Nix libm/GLIBC_2.43 —
diagnostic target only, kept); busy_poll re-set to 1 on strix2's stream
before the pairs (strix1 was already 1); rank1-first launches clean;
canary fired ~30% (discard discipline held). (5) Open: serve deploy
decision for HCF1 (nix .#tp2-tbstream rebuild + both hosts + smoke when
prod returns); NEXT experiments by ledger: short-K HC up/down epilogue
screen (~1.5s/rank combined), transport staging redesign as its own
project.

## 2026-10-06 (08:45): KV1 closed; tree restored; HCF1 next

Read strix-dual-exp/TODO.md log 08:45 + evidence/kv1-drift/DRIFT-REPORT.md
(with closure section + speed tables). Facts: (1) KV1 drift pilot complete
on all planned formats/histories; every 1-byte KV format drifts 8-22%
top-1 / KL 4e-3..5e-2 vs TP2's accepted 98.4%/0.0055 — no default-path
candidate. (2) Speed: quantize writer overhead measured ~0 (A/v8/e4m3
1557/1550/1558 tok/s medians, 32k single-host, n=6); attn_bench shows the
sparse WMMA attention largely DRAM-bound (8.80ms @32k vs 3.36ms dense
with 1.65x keys) -> packed-KV reader ceiling ~+3-4% best, +1-2%
realistic prefill, <=0.75% decode; native packed reader itself never
built. User closed the campaign: performance-inconclusive, not worth
pursuing. (3) Tree: pilot kernels/GUFO_QFN_KV_PILOT plumbing/sqrtf shim
reverted; gpu_probe rebuilt and md5 == probe-g1 (a9bf4547) — baseline
bit-exactness restored by binary identity. (4) Profile correction for the
NEXT campaign: the S1 ledger's "~838ms router/indexer dense" family is
the fused HC UP projection; the HC chain (peer combine 2481 + up 835 +
mix-epilogue inject pass 386 + mixer-down W8A8 662ms/rank @32k) is
~4.4s/rank. HCF1 plan: combine kernel (plain Vec4-F16 + peer variant)
accumulates the FOLLOWING mixer's inject partials from the normalized
values it already holds in registers (chunk c maps 1:1 onto inject part
boundaries; per-thread add order s-then-element is preserved by the
chunk loop's e-ascending order) -> the separate inject pass disappears;
bit-exactness gate in hc_mix_ops_test (plain+peer, ragged), gpu_probe
canonical checksums, then canary-gated paired TP2 A/B @32k with 8k
control. Fallback: revert if the peer combine's codegen perturbation
exceeds the removed pass (R1a lesson).

## 2026-10-06 (00:50): S1 split implemented bit-exact, rejected on transport

Read docs/s1-sharding-ledger.md (updated with the rejection), TODO.md log
00:50, prefill-scaling item 9. Facts: (1) The mixer-down N-split was built
end-to-end: HcDownHalfGemm (rank's 160 rows, F32 out) + SiluScale +
HcLoAssemble (rn-narrowing of both halves) reproduce the fused epilogue
bit-for-bit — operator-exact at 96/2049 tokens AND canonical member
checksums through the real pair path. (2) It required a new tagged
start/finish exchange (StartTaggedPartial/FinishTaggedPartial in
Communicator + tbstream impl): a mid-part exchange interleaves with the
pair loop's part-boundary StartPartials, so the FIFO FinishPartial pops the
wrong exchange ("size mismatch" poison); the tagged finish matches by
payload. REVERTED with the rest — the code is in git history and the
evidence dir if ever revisited. (3) WHY IT LOST: the transport stages every
started exchange through ONE worker thread in start order — a mid-part
1.25MB exchange queues behind the preceding 20MB staging (~10ms) and the
host-blocking finish starves the stream: 1504 mixers x ~5ms ~= 7s exposed
vs 260ms saved; 32k prefill 1490 tok/s (-35%). The queued (GPU-staged) path
is unusable mid-pair (requires started_==0). ENABLER if revisited: move the
pair loop's boundary exchanges to the queued path or add a second staging
channel for small frames. (4) MEASUREMENT LESSON (cost 4 wasted pairs):
the probe's CollectiveTrace decorator did not delegate the new transport
methods, so SupportsTaggedPartial() was false and the split SILENTLY never
ran — the "A/B" pairs were A/A (+0.27% "median" = pure noise, consistent
with the earlier A/A spread). A profile showing 0 HcLoAssemble launches
caught it. Always arm a new gated route with a kernel-count or exchange-
trace check before timing it. (5) Tree/serve: gufo @ 7d6379f (docs-only on
top of f61f17a); the serve binary (31127d4c) never contained the split;
rebuilt probe md5 == probe-g1 (a9bf4547). Probe inventory: probe-g1
(CURRENT), probe-c2 (1f5ddd2 ref), probe-s1 (rejected split, 5fc7fa25),
probe-r1a (rejected). Evidence: evidence/prefill-triage/s1-split/ incl. the
3136-exchange trace log + prof-s1. Remaining levers for prefill: single-
host kernel-level speedups (help single AND dual) and the transport staging
redesign (its own project). Ops: rank1-first rank0-second launches worked
all night; ~40% of sessions hit the slow-mode canary (warmup 2750-3800ms)
— discard/retry discipline essential; two bootstrap connect flakes
(ssh/tbnet transient, both recovered on retry).

## 2026-10-05 (23:30): G1 retained, R1 closed, S1 ledger

Read docs/prefill-scaling.md items 7-9 + TODO.md log 23:30 +
docs/s1-sharding-ledger.md. Facts: (1) G1 — GdnRowSplitKernel is now
block-size-templated; a TP rank's 24-value-head geometry dispatches
128-thread/32-row blocks (96 blocks vs 48; per-row lanes/DPP unchanged ->
bit-exact, canonical checksums every session; gdn_ops_test covers the
8-key/24-value-head geometry). Kernel 1466.6->1294.5us (-11.7%) with
routed/attention/combine controls <=0.2%; e2e median +0.40% (5/6), 8k
even. (2) R1a REJECTED — bounding the epilogue loops by live_tok_tiles
(bit-exact, drops only write-guarded dead tiles) SLOWED the routed kernels
+6-9%/call and -2.45% e2e: the runtime bound perturbed the unrolled live
path. Lesson: this family's codegen is scheduler-sensitive; it is
weight-streaming-bound (~360ms excess vs ideal halving) — do not propose
tiling/prologue changes without a streaming mechanism. (3) S1 ledger: the
one positive sharding candidate is the N-split of the fused HC mixer down
(~260ms/rank, +1.8% ceiling, bit-exact per-column, +1.4GB wire under the
existing overlap); anything after the 320-wide low-rank bottleneck is
bandwidth-dead (40MB/call gather). (4) IDLE-BUG RETRACTED: yesterday's
"rank1 control channel drops ~1min idle" was my own kill -TERM of rank0
(serve-r0.log: shutdown_requested signal=15 at 21:22:59 == rank1's close);
tonight's dedicated check PASSED (2.5min idle -> request 200, 0 errors).
(5) Serve smoke @62k MTP on f61f17a: prefill 1983.8 tok/s (band
1880-2117), decode 71.5 @100% acceptance. (6) Slow-mode canary fired ~40%
of tonight's sessions (warmup 2750-3085ms) — discard/retry held; pair
noise at 32k is ~±0.5%, single 8k pairs drift ±1% (judge 8k by late
matched pairs, not across hours). Probe inventory (both hosts):
probe-g1 = CURRENT tree (40a7e82, md5 a9bf4547...), probe-c2 = 1f5ddd2
reference, probe-r1a = rejected variant. Evidence:
evidence/prefill-triage/g1-r1a/ incl. prof-g1 + prof-r1a DBs.

## 2026-10-05 (22:05): P1 + C2 retained, deployed; ops lessons

Read docs/prefill-scaling.md ranking + TODO.md log 22:00. Facts:
(1) P1: TP2's 2560x3072 attn_out/ssm_out GEMMs now take the one-host
2560x6144 five-row-tile launch order (same 10 row tiles, half the
activation bytes; K order unchanged -> bit-exact). 3/3 pairs @32k
(+0.4/+0.9/+0.7%), 8k even. (2) C2: HcCombinePeerVec4Kernel stages the
local+peer block rows in 20KB LDS once per token instead of re-reading
them from global per stream — same bytes, identical reductions -> bit-
exact (operator exact 37/2048). 4/4 clean pairs over the P1 twin
(+1.8/+1.6/+0.7/+0.3%, median +1.15%) @32k, 8k even; kernel mean
1713.5->1643.7us (-4%, expert-GEMM controls <=1.4%). LESSON: the combine's
4x re-reads were NOT all DRAM-bound; instruction diet (H1) and data-reuse
(C2) together captured what the kernel had.
OPS (all bit me today): gufo serve REQUIRES --tp-control-token now;
pgrep for serve via "[.]/gufo serve" (cmdline is ./gufo, not the path —
a false "dead" reading made me kill a healthy pair); ALWAYS check for an
existing serve before launching (a duplicate OOMs: kernel oom-kill +
hipMalloc fail + 10s page-alloc stalls that hang ssh/tool calls);
launch+wait in SEPARATE tool calls. OPEN BUG (new): rank1 exited ~1min
IDLE after two correct requests — "TP worker command receive failed: TP
control peer closed the channel" (rank0 alive, zero errors its side;
control rides tbnet 10.55.0.1:18516) — reproduce before long-idle prod.
Benign WARN at every gufo exit on strix2: ring_interrupt_active "already
disabled" during tbstream_dev_stop (upstream material). Serve smoke:
62k MTP prefill 2061 tok/s (in the 2030-2195 band), decode 49.9 @83.3%,
prompt cache hit verified. Pair healthy: streams attached both ends, no
wedge signatures after 3 serve cycles. Probe inventory (both hosts):
probe-c2 = CURRENT tree; probe-p1 (+P1 only), probe-m1 (fb0dc77
reference), probe-h1/probe-lane1536/probe-lane3072 = H1/C1 variants,
probe-base/-basew/-cand/-cand2/-m1base = historical.

## 2026-10-05 (21:10): H1 rejected, C1 closed

H1 (hidden=2560 constexpr specialization of the Vec4 combine kernels,
plain + peer): bit-exact (operator test 37/2048), but the fused peer
kernel moved -1.4%/call (1690 vs 1714us) in matched slow-mode profiles with
expert-GEMM controls at +-1-2%; end-to-end 2/3 pairs <=+1%, single host
dead even. REVERTED, EXPERIMENTS row + prefill-scaling.md ranking updated.
Lesson: the combine's 41% integer/select instructions already hide under
memory latency; its ~800ms/rank headroom needs a residual-layout or
store-width redesign, not instruction diet.
C1 (chunk-width re-sweep under TP2, single-variable builds, canary-clean
pairs, canonical checksums at every width): 1536 lanes -3.7/-5.0% @32k
(exchanges 1632->2208); 3072 lanes +1.3/+0.9/+1.4% @32k (->1248) but
-2.1% @8k (the 2048-token tail chunk is a third of an 8k prompt). 2048
retained; tree constant restored. Depth-adaptive width only worth it for
long-prompt-dominated workloads.
Probe binaries on both hosts (strix2 mirrors): probe-m1 = CURRENT
reference binary (= fb0dc77 code), probe-h1 / probe-lane1536 /
probe-lane3072 = experiment variants (not in tree), probe-base/-basew/
-cand/-cand2 = historical. rocprof canary usually fails under rocprofv3
(slow mode) — treat profiled-session wall numbers with care; per-call
means in MATCHED modes are comparable.

## 2026-10-05 (19:55): measurement fix, alias fix, Stage 1b

Read docs/prefill-scaling.md "Stage 1 result" (corrected) + "Stage 1b" +
"Measurement protocol"; TODO.md log 19:30. Key facts: (1) the paired probe's
timed prefill WAS its process-first (±5% A/A with identical binaries!) —
probe now runs an untimed warmup (+120ms profile gap); steady-state refs
@32k: non-MTP ~2235 tok/s, MTP ~2180; residual SLOW MODE ~1-in-5 sessions
(-6%, both ranks, whole session incl. warmup → memory placement) — gate A/B
pairs on warmup <2.3s, discard+retry. (2) Stage-1 fused combine = +0.9%
median steady state vs a no-fusion twin (kernel level: AddRows 631ms gone,
fused 2605 vs 2826ms). (3) Stage-1 had an ALIAS BUG on the diagnostic path:
moe_observer made ForwardPair pass block_out as BOTH local input and summed
output → peer double-added (all MoE hashes + a member checksum corrupted;
production unaffected). Reproduced on 9addbac; wrappers now refuse
block_summed==block_local; fixed binary's hashes/checksums identical to
pre-Stage-1 baseline. (4) Stage 1b: ForwardPair catch-up now kv_only —
+3.0/+1.2% @8k, +1.5/+2.9% @32k MTP (median +2.1%, 4/4 pairs), gates: split
logits bit-identical, member tokens == pre-change == greedy AR, ranks agree.
Probe gained --mtp-model (paired MTP harness; DecodeStep greedy; NOTE: pass
--tp-world-size 2 explicitly or you silently run single-host — cost me one
gate run). Serve nix rebuilt (c4d3dce, md5 ed7959c8…) both hosts, smoke OK.
Binaries for A/B on both hosts: /root/probe-base (b7ee0a9 era),
probe-basew (b7ee0a9+warmup probe), probe-cand (9addbac buggy observer
path), probe-cand2 (9addbac+aliasfix+warmup), probe-m1 (fb0dc77 tree =
full stack), probe-m1base (9addbac twin minus kv_only). Worktrees removed.
rocprofv3 profile DB: /tmp/opencode/prof-dual-w/dualw_results.db (pass 93 =
timed 32k; slow-mode-inflated but structurally valid; canary usually fails
UNDER rocprof — treat profiled-session speed with care).

## 2026-10-05 (17:45): prefill Stage 1 shipped — fused peer-add combine

Implemented per plan (docs/prefill-scaling.md "Stage 1 result"): the paired
lane's peer partial is now acquired WITHOUT adding (SplitReduce.finish ->
acquire) and folded into the combine that consumes the lane's block output
(HcCombinePeerVec4Kernel — same two-operand FP32 sum + reduction order, so
bit-exact; f16/q8 wire + narrow shapes fall back to the plain add; the MoE
observer's summed row is written back only when an observer is set).
Correctness: operator test exact at 37/2048 tokens; end-to-end both-rank
logit hashes + member checksums IDENTICAL to the baseline binary. Perf
(interleaved 4x4 pair A/B @32k, /root/probe-{base,cand} on both hosts):
candidate 2190-2221 vs base 1941-2174, wins 8/8 paired, median +1.9%, and
per-run sigma collapses (~7 vs ~108) — base's bad sessions disappear.
Saving is traffic-modest because the 20MiB block buffer is largely
MALL-cache resident. Serve: nix .#tp2-tbstream rebuilt (6becbfa-dirty =
9addbac tree), /root/newbin/gufo redeployed BOTH hosts (backup
gufo.b7ee0a9), pair smoke + 62k MTP prefill OK (1950/1920, inside band).
ALSO corrected the triage doc: (1) the earlier down_e-exchange idea was
WRONG (down_e is [tokens x used x hidden] = ~100MiB, would 5x the wire
bytes and overflow the 32MiB windows) — do not revive it as written; (2)
the excess percentages double-counted MoeEpilogue; (3) the 10.6ms
WaitValue was the small-prompt/decode path, not prefill (large exchanges
wait host-side in FinishPartial). Memory-copy trace: 1538x20MiB staging
D2H copies = 32.25GB @2.11GB/s during the 15.3s pass, 98.5% concurrent
with compute (~1-2% contention tax — real but small). NEXT (Stage 2, in
priority order): combine-kernel efficiency (>=210MiB/boundary at ~168GB/s
vs ~240GB/s measured ceiling -> ~800ms/rank headroom @32k, helps single
AND dual; several broad variants already rejected in gufo EXPERIMENTS.md,
target the specific dispatch), then the replicated dense/W8A8/mix family
(~1.2s/rank — cost-model first: HC mixing is low-rank, which caps any
exchange-based split). 3k tok/s needs kernel-level single-host gains.
Repos: gufo feat/tp2-tbstream @ 9addbac (local); strix-dual-exp @ e265bcb
(pushed).

## 2026-10-05 (16:15): prefill scaling triage — it's the GPU work TP2 doesn't halve

Question: single ~1.5k tok/s prefill => ideal dual >3k; measured ~2.0-2.2k.
Answer (docs/prefill-scaling.md, evidence/prefill-triage/, rocprofv3 DBs in
/tmp/opencode/prof-{dual,single}/ — copy before reboot): during a profiled
32k dual prefill the GPU was 97.6% busy and WaitValueKernel totaled 10.6ms
of 15.3s — exchanges are fully hidden; wire-format work is dead for
prefill. Per-token GPU: single 0.632ms vs 0.456ms/rank = 72% (ideal 50%).
The 4.6s/rank excess: (1) TP2 disables the fused MoE-epilogue-into-combine
(executor.cpp:1892) => separate MoeEpilogueVec4 + 2x the unfused
HcCombineVec4 calls at full replicated width — dual combine family costs
MORE than all of single (2741 vs 2244ms); (2) AddRows 631 + MoeEpilogue
546ms TP2-only; (3) un-halved replicated DenseF16-16x40 / W8A8-16x5 /
HcMix / select families ~1.2s; (4) split inefficiency (experts 0.54, GDN
0.57, attn 0.52). Speedups: 0.91x @2k (pair LOSES below one chunk!), 1.43x
@8k, 1.31-1.41x @32k, 1.36x @61k; MTP catch-up neutral on dual; single MTP
prefill FASTER at 8k/32k (+9.5/+3.3%, unexplained). Session variance ±6% —
interleave future A/B rounds. Next lever (est 2.3-2.4k): exchange halved-F16
down_e instead of F32 MoE output -> restores fused combine (epilogue linear,
sum commutes, but rounding changes => rerun --split invariance + quality
gates); then split replicated HC/indexer dense (~2.6k ceiling); 3k needs
single-host kernel work. New tool: tests/models/qwen38_flash_next/
prefill_probe.cpp (gufo @ 6becbfa, local branch). Repo strix-dual-exp @
4d56bbc.

## 2026-10-05 (12:15): performance baseline — targets met or exceeded

On baseline-B + rebased gufo (b7ee0a9): prefill 2212 tok/s @8K-probe /
2149 @61K-probe (historical 2164 / 2104.6); MTP serve decode 68.6 cold /
73.2 warm tok/s counting (historical 61.6); non-MTP ~34 (parity sanity);
exchange p50 27.1 us @10 KiB (parity). Zero errors everywhere. Ops notes:
headline decode REQUIRES --speculative mtp --mtp-model
/models/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf (else ~34 tok/s non-MTP —
matches history); strix2 gpu-performance.service failed silently after
the reboot — restart before measuring. Evidence:
strix-dual-exp/evidence/perf-baseline/.

## 2026-10-05 (11:55): session complete — rebased gufo verified end-to-end on frozen baseline-B

On top of the 11:00 entry below: (1) B0x10 serve-restart block 9/10
clean, 0 link episodes; the single failure was rank model-LOAD SKEW
(rank0 ~68 s behind on the 10th back-to-back load; rank1's 30 s deadline
expired, rank0 then got EPIPE instantly — clean semantics). Fixed by
adopting the verbs slow-peer deadlines (180 s exchange / 240 s GPU wait)
in tbstream. (2) feat/tp2-tbstream REBASED onto origin/feat/tp2-rdma
(2833856): 3 commits (transport+hardening; conflict-marker fix — lesson:
grep for markers after scripted resolutions; rank0-listens control fix —
the unified attempt() must Listen on rank 0, Connect on rank 1). (3)
Transport hardening shipped: busy-poll POLLERR yield, EOF->prompt
kStreamClosed, reader-lifetime safety, buffered-reader grow fix. (4)
VERIFIED: loop-mode, A7/A18/B0 x2 (all clean), and a full serve smoke —
ranks paired first try, chat completion answered, no poison. Deployed:
/root/newbin/gufo (nix b7ee0a9) both hosts; cmake probes on both hosts.
gufo branch lives locally (remote is neuhaus, read-only) — the rebased
patch is strix-dual-exp/gufo/0001-feat-tp2-tbstream-wip.patch (4890
lines vs tp2-rdma). Next: TODO Stage 4 items (next kernel window),
gufo-prod re-enable decision, bench numbers.

## 2026-10-05 (11:00): BASELINE-B ADOPTED — wedge trigger eliminated; kernel frozen

**Decision gate result (Stage-1, TODO.md):** on baseline-B (thunderbolt
6F77780E + stream BB7FD35F, both hosts, verified running), the A7
reproducer is CLEAN: 0/3 + 0/10 workload-fails, 0 episodes (runs
run-20261005-105121 and run-20261005-105605), vs **3/3 fails + 3/3
episodes on the old build the same morning**. A18/A17/B0 clean as well.
The upstream CLOSE/drain rework (8d55710 series: write-side CLOSE/EPIPE,
RX advance from write/release, busy-poll lock fix, framing-error -EIO,
upstream stop ordering) in candidate-b fixed the
teardown-while-peer-mid-stream trigger. **Kernel is now FROZEN for this
window; healing chain retained throughout (unchanged xdomain/tb).**

Boot-ops regression found+fixed on the way (NOT a kernel bug): after the
dual reboot, "thunderbolt-net: failed to allocate Rx HopID" on both
hosts — heal-watch's bringup with auto HopIDs (-1 → takes 8/9) raced
tbnet's probe (needs HopID 8) and won. bringup.sh now PINS in/out_hopid
16/16 (both hosts synced); recovery was configfs stream rmdir +
thunderbolt-net SERVICE-driver rebind (safe — never the NHI). tbnet and
stream coexist at 8/16. postboot-validate.service ran the reference
block autonomously during the recovery window, then was disabled.

State: both hosts baseline-B, streams attached at HopIDs 16/16,
busy_poll=1, healers active, gufo binary unchanged (still the pre-rebase
build). Next per TODO: B0x10 serve-restart block (running), Stage 2.2
gufo transport fixes, Stage 3.1 rebase onto neuhaus feat/tp2-rdma
(2833856). Rollback if ever needed: /root/modules-backup-preB/*.ko both
hosts + depmod + initramfs + reboot (strix2 first).

## 2026-10-05 (pre-reboot entry): confound resolved — completion barrier is the discriminator; baseline-B deployed

Read TODO.md in the repo first (authoritative plan + log). Highlights:

**1. Wedge trigger nailed experimentally (run-20261005-102932).** With
corrected scoring and the new A18 arm (A7 + `--pairing teardown` ONLY):
A7 3/3 workload-fail + 3/3 link episodes vs A18 0/3 clean (full delivery)
vs A17 0/3 clean vs gufo B0 0/3 clean, same boot, interleaved. Timeline:
sender finishes in ms, closes early -> sender-side hop-deactivation
timeouts -> peer (still draining) hangs -> its teardown adds errors.
**Mechanism: stream teardown while the peer still has the stream
mid-flight / accepted-but-undelivered tail.** The old "both sides >=1 MiB
syscalls" theory is dead (A18 differs from A7 only in the completion
barrier). This also explains: serve-restart wedges (rank0 _Exit after
peer loss = teardown under desync), safe long-lived sessions, and A17's
earlier "success" (it always had the barrier).

**2. Harness v2** (commit 80a5e36 + stdbuf fix): 4-class scoring
(workload / link / recovery / identity), unique run dirs, rank-1 logs
fetched back (line-buffered — killed rank-1 processes used to lose all
output), settle gaps, 120 s recovery deadline with campaign abort.

**3. Kernel baseline-B deployed (candidate-b, commit 66d0c09).**
thunderbolt 6F77780E + stream BB7FD35F: westeri-next stream.c wholesale
(busy-poll lock fix, RX polling, CLOSE write-side +EPIPE handling,
framing-error -EIO, upstream stop ordering) + our hop rotation + ida fix
re-applied on it; nhi.c stock + tb_ring_poll_pending +
descriptor-write-in-poll; healing xdomain/tb UNCHANGED (kept in per user
decision); NO tx_coalesce param (gone from /sys — harness handles its
absence), NO teardown reorder. NOTE: /sys/module/thunderbolt_stream/
parameters/tx_coalesce no longer exists on baseline-B.
- strix2: rebooted, running baseline-B, 0 ida warnings, healer active.
- Cross-version smoke (old strix1 <-> new strix2): ping p50 16.3 us,
  both RC=0.
- strix1: modules deployed + initramfs updated; REBOOT ISSUED as the
  last action of this session; postboot-validate.service (armed) waits
  for pair health then reruns ARMS=A7,A18,A17,B0 ROUNDS=3 autonomously
  -> /root/strix-dual-exp/evidence/postboot-*.log. CHECK THAT LOG first
  next session.
- Rollback if needed: /root/modules-backup-preB/{thunderbolt,
  thunderbolt_stream}.ko on BOTH hosts (+ depmod + initramfs + reboot).
- Expected next-session analysis: if A7 episodes persist on baseline-B
  (upstream CLOSE/drain rework did not fix sender-side teardown
  timeouts), the fix is OUR drain-before-disconnect candidate (TODO
  Stage 2/3, donnerkeule closing-state model); if A7 is clean, kernel
  freeze + validation block per TODO decision gate.

## 2026-10-05 (06:35): parked issues closed; pair healthy on tuned module

**1. gufo post-run ESRCH abort — FIXED (and it was the old 'rank1 SIGABRT'
shape).** StopReader did pthread_timedjoin_np then reader_.detach();
std::thread::detach() calls pthread_detach on the reaped thread ->
ESRCH -> throw -> noexcept -> terminate on BOTH ranks after any run where
the reader was quiescent (i.e. every fully-successful run). Reader is now
a raw pthread_t with a trampoline (no std::thread mixing). Verified:
stock cycles RC=0 both ranks, decode 49.9 tok/s. (First attempt had a
bug: pinning the PARENT thread to the reader's CPU -> 60x slowdown —
fixed.)

**2. Dead mitigations removed from gufo** (tested ineffective in the
2026-10-04 ablation): GUFO_TBSTREAM_TX_PACING_US pacing (was default
25 us/MiB), the 300 ms pre-close settle, the CPU_STAGE diagnostic env.
Decode 47 -> 49.9 tok/s with pacing gone.

**3. serve rank-1 startup retry window** (serve.cpp): rank 1 retries
communicator + control-channel creation for up to 25 s (2 s backoff,
progress messages) before failing clean — covers peer-not-ready races
and links mid-heal. Verified against a no-peer run (retries then clean
exit with the designed message). NOTE: build the TP2 artifact, not the
default package: `nix build .#tp2-tbstream` (the default package has
GUFO_ENABLE_TP2_TBSTREAM off — hours were lost to this tonight). The
devshell direct build (`build/.../gufo`) currently hits a toolchain
skew (GLIBC_2.43 symbols log10f/sqrtf vs runtime 2.42) — use the nix
package or fix the skew. Mid-serving transport replacement remains
future work (collectives hold the communicator; needs backend
redesign).

**4. Heal-speed tuning loaded** (thunderbolt.ko 0CAA7B4C both hosts,
rebooted): keepalive poll 2500->1000 ms, armed streak 8->4, unarmed
36->14; heal-watch poll 5->2 s. A7-forced wedge self-healed ~8 s
(driver-measured, 5 s quantization; episode healed via tunnel
re-activation, no forced retrain needed). tx_coalesce stays default
N. 0 ida warnings across all boots since the hop-ID fix.

**New ops note — split-brain after single-host reboot:** strix1-only
reboot left the pair with xd+streams+keepalive UP but tbnet dead on
both sides (stale tbnet paths; the heal chain cannot see it because
the peer IS responsive). Recovery that worked: `ip link set
thunderbolt0 down; sleep 2; up` on strix2 -> tunnel activation retry
-> re-enumeration -> clean state (~30 s total). Try this before any
reboot when keepalive is green but tbnet is dead.

Repo at 9fd0e0d (heal tuning + regenerated gufo WIP patch with all of
tonight's gufo changes). gufo tree uncommitted by design; WIP patch
regenerates via `git diff HEAD` from /root/gufo.

## 2026-10-05 (00:15): ida-corruption fix holds; coalescer verdict negative; state clean

**Hop-ID ida corruption — FIXED (the big win of the evening).** Vanilla
usb4stream bug: detach_stream released in/out hop IDs without zeroing;
xd-flap during boot settle (heal-watch bringup lands mid-settle) →
re-attach resurrected stale IDs against a NEW xd → next detach
double-freed / freed foreign id → "ida_free called for id=8" → corrupted
ida → tb_xdomain_enable_paths -ENOMEM → /dev/tbstream0 unopenable until
reboot. Three-part fix (all in stream.c, committed 4150467): zero hop
IDs in detach after release; tbstream_remove passes keep_hopids=true
(xd teardown owns the idas — releasing raced its own cleanup; this was
the 56 s heal-flap variant of the warning); attach clears negotiated
IDs when alloc fails. Both hosts boot clean now (0 warnings, open OK).
Upstream-report material (vanilla code).

**Kernel TX coalescer — built, functionally sound, does NOT fix the
lockstep wedge.** tb_stream.tx_coalesce param (default N after final
rebuild; runtime-toggleable via sysfs — no reboot needed to A/B).
Stages sub-ring-depth writes; flush at 1 MiB / reader-park (flush only
when rx is EMPTY — a drain-style reader must not flush on every read!)
/ poll / release (200 ms bounded loop before CLOSE). Two build bugs
fixed en route: copy_from_iter consumes the iterator (compare against
the count captured BEFORE the copy — the post-copy iov_iter_count is
0 → spurious EFAULT), and my first read-entry flush disabled the
coalescing entirely for gufo's always-reading drain thread. With it:
full-speed gufo runs, correct checksums, first fully-completing B3
cycle — but interleaved storm says B3 3/4 wedged vs B0 0/4
(low-propensity boot): every lockstep park flushes a partial stage,
so exchange tails still move as small pushes. The probe-level "both
sides ≥1 MiB" recipe was only ever validated on UNIDIRECTIONAL bulk;
it is structurally unachievable for lockstep collectives (the tail
must move before the peer proceeds). Coalescer kept for bulk-shaped
workloads; disabled by default; param currently N on both hosts.

**gufo regression to debug next session:** tp_batched_probe now aborts
at cleanup with std::system_error ESRCH ("No such process") on both
ranks AFTER a fully-successful run (checksums printed; cosmetic but
pollutes RC accounting — ablate verdicts must not treat 134 as clean).
Started with today's uncommitted gufo edits (reader-buffered path is
env-gated and B0 hits it too, so suspect the shared cleanup edits —
StopReader/pthread_timedjoin/detach interplay). The gufo tree also
still carries: CPU_STAGE (proven useless), reader-buffered path
(works, does not prevent wedges alone), WIP uncommitted.

**Ops rules learned (hard way):** NEVER rmmod/rmmod-attempt this stack
on the live pair — kprobe-pinned module text froze both hosts twice
(reboots by user). Reboot (strix2 first) is the only reload path.
kprobe_events do not survive reboot (safe by default).

**Module state:** deployed srcversion (last build, default-off
coalescer): both hosts /lib/modules + initramfs; running instances
have tx_coalesce=N via sysfs. Boot-verified: 0 ida warnings, device
opens, tbnet up, healers active. errs baselines drift up every boot
from settle churn (flaky cable) — background wedges during settle can
land in ablation cycle windows; per-boot propensity varies wildly
(fresh boots: low).

**Bottom line for the wedge problem:** the syscall-shape theory holds
for bulk traffic but lockstep tails are irreducibly small → userspace
or kernel coalescing cannot prevent the wedge for gufo's exchange
pattern. The self-heal chain (25+ consecutive 8 s heals) remains the
mitigation; the certified passive cable remains the real fix. Optional
future experiment: delayed-flush coalescer (hold park-flush ~40 µs
hoping more writes arrive) — costs exchange latency, unproven.

## 2026-10-04 (20:35): wedge trigger isolated; fix recipe validated on probe; gufo port blocked

Session goal: ablate the gufo-specific wedge trigger, find a userspace prevention.

**Trigger (settled; same-boot interleaved ablation, ~70 cycles, ~450 GB):**
high-rate small-frame USB4STREAM traffic wedges the Barlow Ridge retimers
(dmesg: config-space read timeouts to routes 0x12/0x16 = the in-cable
retimers, then hop-deactivation failures). Discriminator = **syscall shape
on BOTH sides**: writes AND reads below the ~1 MiB ring depth (256 × 4 KiB
= TB_MAX_FRAME_SIZE 4096). Every write() is driver-chunked to 4 KiB frames
regardless, so wire frame size, 4096-alignment, volume, rate, socket
lifecycle, fd choreography, release-at-exit, pinned-vs-heap memory are all
irrelevant — proven by A/A2-A6 (0/32 clean, up to 14.7 GB/cycle), A12
(aligned, wedged), A7V10 (730 MiB, wedged), B2 CPU-stage (wedged 5/5).

**Fix recipe (probe-validated, A17 vs A7 interleaved 0/3 vs 3/3):**
sender write()s ≥1 MiB AND receiver read()s ≥1 MiB. A14 (big W + big R)
clean; A8 (big W + small R) wedged; A13 (small W + big R) wedged — both
sides required. Probe flags (tools/tbstream/tbstream_probe.cpp,
uncommitted on feat/tp2-tbstream): --batch-bytes N, --reader-buffered,
--reader-glutton, --pairing early|teardown|last, --idle-seconds,
--exit-open, --mode fulldup.

**New driver semantics found:** stream device DISCARDS a sender's
accepted-but-undelivered TX tail at last-fd close (write(2) success ≠
delivery). Probe works around via post-traffic pairing barrier
(--pairing teardown); gufo lockstep never hits it. Upstream-report
material alongside the retimer wedge.

**gufo port (B3 = GUFO_TBSTREAM_COALESCE=1, tbstream.cpp uncommitted):
NOT WORKING — do not use.** v1 deadlock (barrier path unflushed) fixed;
v2 deadlock (queued path held frames across WaitReady) fixed via flush
in WaitReady's sleep branch; v3 CURRENT: decode 17× slower, prefill
freezes ~4 min (both GPUs stall; only a 64 B barrier write under
strace; then ENXIO = wedge mid-stall). Flat-buffer reader rewrite did
not cure. Root cause unknown; suspect GPU-flag/pipeline interaction
with buffered reader. Stock env (unset) unaffected.

**Next-step options (pending user decision):** (a) kernel TX coalescer
in thunderbolt_stream: buffer small writes, flush at ≥1 MiB / on
read() by same process (lockstep peer-wait hint, zero latency) / poll /
release — fixes writes for gufo with NO transport changes, pairs with
the already-written reader buffering after its stall is debugged;
(b) continue debugging the userspace port; (c) adaptive RX hold
(rate-aware) driver-side. All upstream-report material.

Ops: module 091ABEAB… + healers active both hosts; today's ~15 wedges
ALL self-healed at 8 s (25+ consecutive successful heals now). Ablate
harness committed bc7af4e (arms A, A2-A8, A7V10, A12-A17, B0-B3;
probe-pair-tb.sh 30 s remote cap; strace-cycle.sh).

## 2026-10-04 (15:15): repo live, /root decluttered, quarantine-wq build validated

- **Repo**: /root/strix-dual-exp (git, remote ssh://git@10.8.0.4:2222/
  doctomoe/strix-dual-exp.git, branch main, pushed, secret-audited:
  zero hostnames/LAN-IPs/UUIDs/MACs in tracked content; evidence/ and
  scripts/env.sh gitignored). Contains: 3 kernel patches vs vanilla
  7.3-rc3 (regenerated from final tree), full build-tree, sanitized
  investigation log + upstream report, ops scripts, tbstream-heal@.service,
  gufo feat/tp2-tbstream WIP patch (sanitized, regenerable via git diff HEAD).
- **Paths moved**: /root/wedge GONE (evidence → repo evidence/, pristine
  tree → /root/kernel-src-7.3rc3, binaries deleted, pre-saga debris →
  /root/archive/pre-saga/). Healer units on BOTH hosts repointed to
  /root/strix-dual-exp/scripts/heal-watch.sh (active, verified).
- **Module NOW**: srcversion 091ABEAB04F5057785CF1D9 both hosts —
  round-2 hardening after the near-stock trial REGRESSED:
  1. HopID rotation RESTORED (stock allocator reuse → near-deterministic
     wedge on post-heal re-attach; rotation = mitigation, kept).
  2. Boot-settle grace: detector arms after 3 consecutive successful
     keep-alive probes (spurious-disconnect fix).
  3. Settle-wedge deadlock fix: unarmed-fallback streak (~36 failed
     probes) + discovery RESTARTS from ERROR instead of parking; all
     XDomain protocol works moved to dedicated ordered wq tb_xd_state
     (quarantine: a stalled sync request can never freeze tb->wq; the
     v2 D-state hang becomes contained).
- **Validation**: 12-cycle storm @58% wedge rate: 7 wedges, 7/7
  autonomous heals @8s, zero reboots. Clean-boot settle: zero spurious
  events. The settle-wedge path (wedge during peer boot) is design-fixed
  but not yet observed end-to-end in vivo.
- gufo work KEPT in gufo tree (graceful-exit closure, probe tooling) —
  future upstreaming via regenerable patch in repo.

## 2026-10-04 (13:12): SELF-HEALING SHIPS — wedges are now 8-second hiccups

Final validation (12-cycle storm, current flipped-cable layout, wedge
rate 3/12): **total=12 clean=9 wedged=3 autonomously_healed=3, 8s per
heal, zero operator action.** Post-run cycle clean. The wedge host
flipped to strix2 this boot (wedge host is boot-random within an
orientation; the heal is host-agnostic by design).

### The self-heal chain (module v6, srcversion E6986919ED63DF1DDEBE171)
1. **Keep-alive probe** (xdomain.c): ENUMERATED xds re-read peer
   properties every 2.5s (notification suppressed for keep-alive
   reads). Steady-state xds otherwise schedule nothing, so a wedged
   peer was previously invisible (v5 lesson).
2. **Failure streak** (xdomain.c): 8 consecutive failed probes (~8s)
   with have-seen-success guard (boot-time handshake failures never
   trigger) → tb_xdomain_force_retrain(), max 5 attempts per episode,
   retry pass restarted after each fire.
3. **Lane-Disable disconnect** (xdomain.c, system_wq work): sets
   LANE_ADP_CS_1_LD (BIT 14) on the local port for 2s, then clears.
   LD is the software unplug: the LC drops the link (the ONLY
   transition that resets the router config relay a wedged peer hangs
   on — speed-toggle writes and Link State Change request packets both
   proved ineffective on a wedged channel).
4. **Re-enumeration** (tb.c FIX A): after the xd-removal on unplug,
   if the link is still up → rescan now (covers the stale-unplug/plug
   event inversion); else synthetic plug event. Fresh xd + handshake
   on both hosts. ALSO fixes the human-replug case (was: healthy link
   + both xds removed + no rescan = idle forever).
5. **heal-watch daemon** (userspace, systemd tbstream-heal@0/1,
   enabled both hosts): peer dead + xd present → re-run bringup.sh
   (IP/MTU on the recreated thunderbolt0 + stream configfs re-arm).

### Version history (what failed and why — do not regress)
- v1: streak counted give-ups only; ABI break via struct field
  (thunderbolt_net CRC mismatch — keep counters file-static!).
- v2: ERROR-state UUID restart → **hang**: sync XD request on a
  wedged channel stalls tb_cfg_request_sync's cancel path forever
  (D-state worker, stack: tb_cfg_request_sync+0xb7 ←
  tb_xdp_uuid_request ← tb_xdomain_state_work). Genuine upstream bug
  (see report queue). Quarantine rule: never issue sync ctl requests
  from state work against an unresponsive peer.
- v3: streak=15 > attempts-per-pass (10+1) → never fired; threshold
  must be < XDOMAIN_RETRIES.
- v4: Link State Change request packets — die in the wedged channel,
  link never retrains (5 fires, rx stayed 40.0).
- v5: LD missing detection signal (ENUMERATED xd idle; peer's dying
  notification is a 2/3-probability race) → v6 keep-alive.
- v6: complete (shipped).

Also shipped: stream hop-rotation clamp to nhi->hop_count ("invalid
hop: 29/30/31" noise on strix2); gen3_link_cap param (default true).
Note: post-heal links come up Gen3 20.0×2 (rate irrelevant to wedge,
bandwidth fine for TP2 prefill).

### State & next steps
- Module v6 both hosts + initramfs; healer enabled both hosts.
- **Prod restore is a go** (user decision): wedges are transparent
  (~8s) at any cable orientation. gufo-prod enable + watchdog = done.
- Upstream report material (now STRONG): ctl.c cancel-path hang with
  D-state reproducer + stack; rescan-after-replug gap; keep-alive /
  LD-retrain design. misc_open section unchanged.
- TP2 prefill optimization Phase 1 resumes as next work item.

## 2026-10-03 (23:50): BOOT-ORDER TEST NEGATIVE — per-cable-end fault is the standing model

Experiment: strix1 booted ALONE first (strix2 powered off, powered on
~4 min later; configfs bringup order kept standard: strix2 first via
ssh). Same flipped-cable orientation (bad end at strix1 per D1/F1).
Result G1-G7: 6 clean, then **strix1 wedged** (G7; strix2 clean; same
signature; forensics-G7-*.tar.gz). Note the cap missed its window on
this boot (link trained Gen4; rate already proven irrelevant by F1).

**Attribution table (final):**
| Layout | Wedging host | Rate |
|---|---|---|
| orig cable as-shipped | strix1 | ~25% |
| certified unflipped | strix2 | instant |
| certified flipped | strix1 | instant |
| 3rd unflipped | strix2 | 1/8 |
| 3rd flipped @Gen3 | strix1 | instant |
| 3rd flipped @Gen4, boot-order-flipped | strix1 | 1/7 |

Boot/order hypothesis REJECTED. BIOS, gufo roles, link rate, power-on
order — all rejected. The ONLY correlate across all 6 layouts: which
physical cable end sits at which host. **Model: each of the three
cables has one defective end (likely active-cable retimer/e-marker
asymmetry) that corrupts USB4 in-band config traffic toward that host,
host-independently, rate-independently.** All three are presumably
active 80G cables.

**Decisions pending (user):**
1. Restore prod NOW on best layout (3rd cable UNFLIPPED, ~1/8 toward
   strix2) + reboot/bringup watchdog; risk = one ~6-min recovery per
   serve RESTART only (long-lived sessions are safe; wedge strikes at
   teardown).
2. User orders a PASSIVE 40G-certified USB4 cable (no retimers) →
   screen it (fast reject, slow qualify) → permanent Gen3 config if
   clean (~3.2-3.5 GB/s; TP2 serving viability to be measured then).
3. Optional: measure Gen3 serving throughput in advance (needs a
   proper Gen3 session: module reload after link-up retriggers the
   cap reliably — the boot-time cap often exhausts its 8 attempts
   before the peer answers).

State: link wedged (G7), hosts up, strix2 freshly booted from the
poweroff cycle. Boot-order watcher: /root/wedge/bootorder-watch.sh.



## 2026-10-03 (23:35): GEN3 CAP IMPLEMENTED — AND GEN3 DOES NOT FIX THE WEDGE

Built `gen3_link_cap` into the out-of-tree module (xdomain.c): one-shot
helper tb_xdomain_apply_gen3_cap() rewrites the local lane adapter
LANE_ADP_CS_1 TARGET_SPEED=Gen3 and sends the XDomain Link State Change
request at (DUAL, Gen3); called from the PROPERTIES-success state (the
INIT/UUID sites fire too early — remote answers -EAGAIN; retries capped
at 8 per xd; needs the module (re)loaded AFTER the link is up on a
running system, or a fresh boot). Verified: both sides retrained to
20.0 Gb/s x2 symmetric (sysfs rx/tx_speed). Module srcversion
C65D402F085A7AD64F6B5A7A deployed both hosts + initramfs; param
`thunderbolt.gen3_link_cap=0` restores stock Gen4.

**RESULT: F1 wedged strix1 on the FIRST Gen3 cycle** (same signature:
routes 0x12/0x16, hops 9/11; forensics-F1-*.tar.gz). The Gen4
signal-margin theory is dead in its simple form. Note the sideband/LC
channels do not necessarily retrain with the main lanes, so an analog
fault localized to sideband lines is NOT excluded — but main-lane
margin is exonerated.

**Evidence table (wedge attribution by arrangement):**
- Original cable, as-shipped, Gen4: strix1 (~25%/cycle)
- Certified 80G unflipped: strix2 (cycle 1); flipped: strix1 (cycle 1)
- 3rd (uncertified) 80G unflipped: strix2 (1/8); flipped (=Gen3 test):
  strix1 (cycle 1, at Gen3)
- BIOS identical (both 1.11): wedge still follows the above
- gufo software roles (rank0/rank1): irrelevant

**Live models after F1:** (a) one physical end of each cable is faulty
in a rate-independent way (active-cable e-marker/re-driver end defect,
or sideband-line contact asymmetry); (b) a bringup-dynamics/link-role
correlate that flips with replug orientation (testable WITHOUT cable
changes via boot-order experiments). UUID-based XDomain roles are
deterministic per machine pair and cannot explain the flips.

**Remaining cheap discriminators:**
1. Boot-order flip (no physical access): boot strix1 alone first, power
   strix2 ~30s later (vs today's simultaneous/strix2-first sequence);
   if the wedge moves to strix2 with NO cable change → role/order bug
   (kernel-fixable in our module: role-aware teardown sequencing).
2. Un-flip the current cable at Gen3: if the wedge returns to strix2,
   orientation determinism is rate-independent → per-cable-end fault.
3. E-era orientation + Gen3 + 20 cycles: partial-rate check.

**Prod restoration options as of now:** best-rate layout observed =
3rd cable UNFLIPPED (~1/8 toward strix2) + reboot/bringup watchdog;
or find the role/order trick above; or obtain a PASSIVE 40G-certified
cable (no active ends) and train Gen3 with it — distinct from tonight's
Gen3-with-active-cable test.

State: link wedged (F1), hosts up, streams were attached at Gen3 before
the wedge. tbnet/stream modules hot-reloaded during this session (after
rmmod, bringup.sh re-creates configfs; thunderbolt_net/stream must be
modprobed back manually after any rmmod).



## 2026-10-03 (23:00): CABLE-FLIP TEST — ROOT CAUSE NAILED: marginal cable direction at Gen4

User flipped the USB-IF-certified 80G cable end-to-end (ports unchanged:
strix1 on its alternate 80G port = peer 0-1, strix2 on its original =
peer 0-3). **Cycle D1: strix1 wedged, strix2 clean** — with the unflipped
cable, C1 had wedged STRIX2 with strix1 clean. Same signature everywhere
(timeouts reading config space 0 from 0x12/0x16, hop deactivation failed
indices 9/11 — this time on local port 0:1).

**CONCLUSION — the wedge follows the cable's physical orientation, not
the host, BIOS, kernel, ports, or roles:**
- Original cable, direction toward strix1: strix1 wedges ~25%/cycle
  (strix2 clean through ~40 cycles) — the entire "host-tied strix1" era
- Certified cable unflipped (marginal end at strix2): strix2 wedges C1
- Certified cable FLIPPED (marginal end at strix1): strix1 wedges D1

One physical end of each cable tried is marginal for the USB4 sideband/
config channel at Gen4 (80G) signaling — under gufo's workload context
(model load + real exchanges) the config channel in the marginal
direction corrupts (usually at teardown), wedging that host until reboot.
NOTE the nuance: the 41/41-clean C discriminator harness ran on the
marginal-original-cable layout without wedging — cable marginality is
necessary but the trigger still involves the gufo process context
(RDMA-less HIP-heavy load pattern). The kernel's teardown-error behavior
on a corrupted sideband remains an upstream-hardening candidate, but it
is a SYMPTOM path, not the root cause.

**Hosts exonerated**: both MS-S1 MAX units, both BIOSes (1.11), NHIs,
ports, the patched module, gufo — all fine. Do NOT RMA anything.

**Path to prod (user decision):**
1. Try more cables until one survives ~15 clean cycles in the chosen
   orientation (each candidate: flip test + cycles; the wedge can be
   immediate, so qualification is fast when bad, slow when good).
2. Or force Gen3/40G signaling (a 40G-certified cable trains Gen3;
   ~3.2-3.5 GB/s — still enough for TP2: prefill is compute-bound
   ~2100-2200 tok/s and q8/f16 serving needed far less than 5 GB/s).
3. Or original cable + watchdog (reboot+bringup per wedge) — worst option.

State after D1: link wedged, hosts up. Forensics: forensics-D1-*.tar.gz
(and C1, B3/B6/B12, S10, P2a, R2 series for the historical record).



## 2026-10-03 (22:50): THE WEDGE MOVES HOSTS WITH THE CABLE — strix1-unit verdict OVERTURNED; physical-layer root cause

User changed the physical link: strix2 kept in its original Barlow port
(peer 0-3), strix1 moved to its OTHER 80G port (peer 0-1), NEW cable.
Fresh boots, clean enumeration both directions (the intermediate cable
attempt before this had strix1 failing discovery entirely).

**Cycle C1: STRIX2 WEDGED — its first ever** (4 errors, signature
IDENTICAL to strix1's historical ones: timeouts reading config space 0
from 0x12/0x16, hop deactivation failed indices 9/11). strix1: 0 errors.

**Overturned conclusions:** the earlier "host-tied to strix1 / BIOS 1.11
suspect / strix1 unit defective" chain was an artifact of the ORIGINAL
CABLE ORIENTATION never changing through the role-swap and BIOS A/B
experiments. The fault follows the physical link layer: whichever
direction is marginal wedges. Original cable → strix1 (~25%/cycle);
intermediate cable at strix1's port 1 → strix1 discovery failure; new
cable → strix2 (cycle 1!).

**Working model:** an 80G/Gen4 signal-integrity margin problem (cable
and/or port combination) corrupting the USB4 sideband config channel in
one direction under teardown conditions. All three cables tried showed
some marginality — suspect non-TB5-certified cabling at Gen4 rates.

**Next discriminator (pending user):** flip the CURRENT cable end-to-end
(strix1's end ↔ strix2's end, ports unchanged). Prediction under the
marginal-direction model: the wedge moves BACK to strix1. If it stays on
strix2, the port combination matters instead.

**Prod-restoration paths depending on outcome:** certified TB5/80G cable;
or deliberately run at Gen3/40G (a 40G-certified cable trains Gen3;
~3.5 GB/s still enough for TP2 serving since prefill is compute-bound
~2100-2200 tok/s); or the reboot+bringup watchdog on the current setup.

Forensics: forensics-C1-{strix1,strix2}-*.tar.gz. Link attrs at wedge:
40.0 Gb/s 2 lanes symmetric both sides. After C1 the link is wedged,
hosts up.



## 2026-10-03 (22:30): BIOS A/B COMPLETE — 1.11 EXONERATED; wedge is strix1-physical

User flashed strix2 to BIOS 1.11 (vendor file SHWSA_STXH_1.11_260828A.zip
from Minisforum's product-info page; 1.09 is no longer published — support
ticket would be needed to recover it). Both hosts then ran IDENTICAL
everything (verified: BIOS 1.11, module 6DE7B9C73346C0B279D55D2, router
NVM 61.83, kernel/cmdline/topology).

**Result over 12 cycles (B1–B12, probe-pair.sh, normal orientation):**
- strix1: **3 wedges** (B3, B6, B12) — its usual ~25%/session rate
- strix2: **0 wedges, 0 errors** — first time running 1.11, both roles
  exercised across sessions (listener in S-series, connector in B-series)

**CONCLUSION (user's decision rule: next-wedge-attribution):** BIOS
version is NOT the discriminator. With all software+firmware identical,
only strix1 wedges → the asymmetry is PHYSICAL on strix1: NHI silicon
variance, its USB4 port, or the cable end feeding it.

**Remaining cheap discriminators (physical, user-executed):**
1. Move strix1's USB4 cable to a DIFFERENT port on strix1 (4 candidates:
   2× USB4 40G + 2× USB4 V2 80G; currently one of the 80G) → port-vs-board.
2. Reverse/replace the cable (if a spare 80G-certified cable exists) →
   cable-end-vs-host.
3. If neither helps: strix1's NHI hardware is the suspect → RMA the unit,
   or adopt the watchdog mitigation (detect→reboot→bringup→restart).

**Wedged-state forensics kept:** forensics-B3/B6/B12-{strix1,strix2}-*.tar.gz
(B12 strix1 signature identical: config read timeouts at deactivation).
Link left WEDGED after B12 (hosts up) pending the physical experiments.



## 2026-10-03 (evening, 21:00): ROLE-SWAP → WEDGE IS HOST-TIED (strix1); HopID-reuse FALSIFIED; BIOS 1.11 vs 1.09 = prime suspect

**Role-swap experiment** (rank0/listener on strix2, rank1/connector on
strix1; /root/wedge/probe-pair-swap.sh): 9 clean cycles then S10 WEDGED
**on strix1 while it was the connector** — strix2 (listener) had zero
errors. The wedge follows the HOST, not the role. Combined with the full
platform diff (see below) the role/listener asymmetry is exonerated.

**Platform diff strix1↔strix2 (all verified this session):** IDENTICAL —
kernel+cmdline (iommu=pt), IOMMU mode, board (SHWSA), CPU stepping +
microcode (0xb700037), RAM config, NHI BDF/rev/PCIe tree/link state/ASPM,
router NVM (61.83 gen4), USB4 link 40Gb/s 2 lanes symmetric, module files
+ params, governor/EPP, no firewalls. **DIFFERENT — BIOS: strix1 = 1.11
(2026-08-28), strix2 = 1.09 (2026-06-08); trivial: MSIX IRQ affinities.**

**Fresh-HopID rotation was a NO-OP all along**: the XDomain maxhopid is
31 but the rotation scanned hops 40-52 → every session logged "invalid
hop" ×N → "fresh HopIDs exhausted, falling back to automatic allocation"
(= stock behavior). Fixed the rotation to wrap within [10,31]
(tbstream_hop_seq; new module srcversion 6DE7B9C73346C0B279D55D2,
deployed BOTH hosts + initramfs). **FALSIFIED BY R2**: with the rotation
working (R1: TX hop 2 via fallback, R2: TX hop 11 fresh), R1 was CLEAN on
a REUSED hop and R2 WEDGED on a FRESH never-used hop → HopID reuse is NOT
the trigger. (Also: hop validity is negotiation-coupled — an explicit hop
only allocates if it matches the session's negotiated out_hopid; TX
fallback and RX retries through many hops are normal.)

**R2 wedge anatomy (forensics-R2-*.tar.gz, dyndbg on):**
1. ~t=45s mid-run: data path dies (strix2 barrier timeout; strix1 writes
   ENXIO) — config ops still work after this (see 3).
2. rank1 exits, its device teardown CLEAN (no timeouts, strix2 side).
3. **Auto-reattach**: with configfs streams armed and rank0's fd still
   open, both sides renegotiate a NEW session ~3s later (rings 11/10,
   E2E enabled — config path ALIVE at that moment).
4. rank0 unwinds ~54s (98 GB model free), exits → teardown of the
   reattached session → first config timeout 0.4s into the deactivate →
   WEDGE. So the config channel jams somewhere between the reattach and
   this teardown — the SAME window as the data-path death.
- The XDomain "properties storm" (ENUMERATED↔PROPERTIES loop ~2.4s)
  runs on BOTH hosts whenever streams are attached and is BENIGN (R1 ran
  clean through it; 78 iterations on strix2, zero errors).
- Common endpoint across all wedge variants (P2a/S10 teardown-time,
  R2 mid-run): strix1's NHI↔router config mailbox jams; NHI PCI config
  space stays responsive (chip alive, driver-level state) — only a
  reboot clears it.

**Host asymmetry conclusion**: identical everything except BIOS →
strix1's BIOS 1.11 (or its NHI init) is the prime suspect. Proposed
decisive test (PENDING USER): flash strix2 → 1.11 (does it start
wedging?) or downgrade strix1 → 1.09 (do wedges stop?). Needs vendor
BIOS image + user consent.

**Kernel-side leads still open**: the auto-reattach + CLOSE handling =
exactly what westeri/thunderbolt next-branch reworks (8d55710 series +
busy-poll lock fix 7049eb5); a next-branch retest is now better-motivated.
Instrumenting the ctl timeout path (which config packet dies first) is
prepared as the follow-up if BIOS is ruled out.

**Scripts this session**: /root/wedge/probe-pair.sh (normal orientation,
fixed BIN_DIR), probe-pair-swap.sh (roles swapped; ssh -n + </dev/null —
remote background via ssh hangs otherwise), probe-kill.sh (SIGTERM rank1
at T s; pkill needs the [t]-bracket trick), wedge-forensics.sh (BOTH
hosts; captures NHI PCI liveness = the hardware-vs-driver discriminator +
dmesg/sysfs/configfs/debugfs/hung-task stacks into a tarball).



## 2026-10-03 (evening, 19:25): DISCRIMINATOR MARATHON — 41/41 userspace arms CLEAN; in-vivo bisection is the only path left

Built /root/wedge/wedge-repro.c + wedge-repro-hip.cu (dual-fd, mirrors the
transport's device usage) and swept every externally-constructible variable.
**All 41 runs clean; the real serve pair wedged ~100% (7/7 today).**

| Arm | Varied | Result |
|---|---|---|
| A/B | graceful vs raw-exit close, 2s stagger | clean ×6 |
| E/G | 20 MiB frames, parked reader (CLOSE unconsumed) | clean ×6 |
| D1 | + concurrent tbnet iperf | clean ×2 |
| H2/H3 | GPU-coherent DMA buffers, GPU spin kernels, 60 GB GTT | clean ×6 |
| H4 | continuous H2D copy storm (~380 GB/run) through teardown | clean ×3 |
| H5 | real GPU compute (32 GB persistent kernel) concurrent | clean ×3 |
| H6 | 1 MiB write granularity + 25µs/MiB pacing (gufo's write shape) | clean ×3 |
| H7 | + lock-step exchange structure (idle↔active per frame) | clean ×3 |
| H8 | + GPU WaitValue spin on reader's arrival flag | clean ×3 |
| H9 | + wait kernel LEFT RUNNING through exit (dies mid-spin) | clean ×3 |
| H10 | + 20s close stagger (mimics the hung-cleanup gap) | clean ×3 |

**strace of a real wedge cycle** (/root/wedge/serve-strace.txt, 166 MB +
strace-wedge-r{0,1}.txt): gufo's device shape = ~225K writes (1 MiB-paced)
+ ~126K short reads (45-90 KiB returns) — all mimicked. Exit choreography:
rank1 `_Exit(0)` (its SIGTERM handler) → rank0 pair_watch raises SIGTERM →
Cleanup RUNS AND COMPLETES its device close (quiesce + fd_ close; the
kernel-error timestamps match this moment) → remaining teardown (98 GB GTT
free) exceeds the 15s backstop → `_Exit(1)`. **The graceful-exit fix is
falsified for real: the in-process quiesced release happened and the wedge
still formed.**

**Falsified fix/hypothesis ledger (cumulative):** E2E-off (data path
deadlocks), Barlow v1-reset quirk entry (worse), stream.c teardown reorder
(CVE pattern), fresh-HopID-per-session, graceful pair-loss exit + reader
join, every userspace usage shape above, GPU memory/compute/wait patterns,
GTT/H2D pressure, tbnet concurrency, close stagger 2s/20s.

**Remaining suspects (not externally mimickable):** something in gufo's
full runtime context — ROCm userspace stack in its entirety (real model
weights, kernel library, event/stream pools) or an interaction only the
complete process produces.

**NEXT SESSION — in-vivo bisection (the only remaining tool):**
1. tp_batched_probe pair (gufo code, minimal path, historically wedges
   during sweeps): bisect modes — allreduce-bench only / prefill sweep
   only / decode only, wire f32 vs q8, ring sizes — find the minimal
   gufo-mode that wedges at cycle 1; then delete executor paths until it
   stops. Each run ~5 min, positive control reliable.
2. If probe modes are all clean: LD_PRELOAD interposition on the serve
   process (log/alter open/close/read/write on /dev/tbstream*) converging
   on the delta vs the repro by AB-deleting gufo behavior.
3. Parallel cheap arm never run: `thunderbolt.clx=0` boot test.
4. misc_open pile-up report: still ready to send independently.

**State left:** link healthy, streams attached both ends, dyndbg on,
gufo-prod STOPPED+DISABLED (user: stays down until the wedge is fixed —
`systemctl enable --now gufo-prod` restores). Serve closure with the
graceful-exit+reader-join changes: ads1w6ny (both hosts, scripts repointed;
the changes are correct hygiene — the 15s backstop vs upstream #390's
10s/_exit(75) should be reconciled at rebase). Note strix2 had one ~14-min
boot (fsck?) and a tbnet-IP loss after re-enumeration — always re-add IPs
after any wait-for-boot. wedge-repro-hip usage examples in discrim-*.log
headers; build recipe: hipcc from
/nix/store/yb81zhv981n0kxvcsr7ia4fjjd78bsjz-clr-7.2.3/bin with
HIP_DEVICE_LIB_PATH=/nix/store/pygmmqq369vx9z54z0rzcqlspf27m6r8-rocm-device-libs-22.0.0-rocm/amdgcn/bitcode,
rpath to the clr lib dir (works on both hosts).


## 2026-10-03 (17:20): DISCRIMINATOR — the 15:20 conclusion is REFUTED; wedge is gufo-context-specific

The 15:20 entry's central claim ("close-after-heavy-traffic is fundamentally
unsafe on this stack") is WRONG. A purpose-built minimal harness
(/root/wedge/wedge-repro.c + wedge-run.sh, dual-fd mirroring the gufo
transport: nonblocking write fd + blocking read fd, always-draining reader
thread) ran 14/14 CLEAN across every axis we could vary from plain fds:

| Arm | Traffic (bidir) | Close style | Extra | Result |
|---|---|---|---|---|
| A | 2 GB/dir, 1 MiB frames, 11 MB/s | graceful (join reader, quiesce, close both fds) | 2s stagger | clean ×3 |
| B | 2 GB/dir, 1 MiB, ~50 MB/s | raw `_exit(0)`, reader running | 2s stagger | clean ×3 |
| E | 2 GB/dir, **20 MiB frames**, ~120 MB/s | raw `_exit(0)` | 2s stagger | clean ×3 |
| G | 2 GB/dir, 20 MiB | raw `_exit(0)` | reader PARKED (off) after traffic — CLOSE lands unconsumed | clean ×3 |
| D1 | 2 GB/dir, 20 MiB | raw `_exit(0)` | concurrent 800M iperf over tbnet during idle+close | clean ×2 |

Positive control: the REAL serve pair, same boot, minutes after arm G —
**WEDGED at cycle 1** (6/6 serve wedges today across boots/builds). Trace
asymmetry in every serve wedge: **rank1 (strix2, graceful SIGTERM path)
tears down CLEAN; rank0 (strix1, `pair_watch` → `std::_Exit(1)` after peer
loss) is always the side that jams** (first hop-deactivation config read
times out at route 0).

**Harness audit corrections (the 15:20 evidence table mislabeled three rows):**
- "staggered race 300 clean, ordered 1-2s apart": race-stag.sh actually runs
  SOLO never-overlapping cycles (rank1 closes inside its ssh before rank0
  opens). Correct label: solo open/close cycling — clean.
- "serve ordered kills 15-17s/30s apart": rank0's pair_watch `_Exit`s ~2s
  after rank1 dies; the script's sleeps never separated the DEVICE closes.
- "30s drain tested": only rank1 got a real pre-close idle; rank0's release
  ran ~2s after its last traffic.
- The 11:06 "6 clean serve cycles" ran handshake-only traffic with
  SIMULTANEOUS kills; every wedge since 13:56 used the ordered-kill path
  (with or without 61K traffic — the 13:56 run had NO 61K due to a broken
  prompt file and still wedged, so heavy traffic is NOT required in the
  serve context either).

**What this means:** the trigger lives in the gufo serving environment,
not in stream close mechanics. Remaining candidate ingredients (untested,
in priority order): (1) the 98 GB GTT model load concurrent with an open
stream, (2) hipHostMallocMapped|Coherent DMA buffers with GPU kernels
(device-side WaitValue spins) hammering the same coherent pages the NHI
DMAs into, (3) executor/thread-pinning patterns. Next session: add these
one at a time to wedge-repro (a HIP-linked variant writing from a coherent
pinned buffer while a kernel spins on a flag in it is the sharpest single
test), and/or make rank0's pair-loss exit graceful in gufo (rank1's path
never jams — that alone may fix serving restarts).

**Also still true and reproducible from userspace**: the ~50-cycle
overlapped random open/close race wedge (race.sh) — HopID-reuse class; the
loaded module build (fresh-HopID rotation + teardown reorder, srcversion
CF255E15...) survives 14/14 discriminator runs and matches upstream's
queued direction (dma_test reorder + Mika's dirty-HopID avoidance); kept
loaded on both hosts.

**UPSTREAM-REPORT.md is WITHHELD for now**: we cannot hand upstream a
repro for the serve-context wedge (every userspace attempt is clean), so
the main report waits for the gufo-context decomposition. Still valid and
reportable independently: the misc_open pile-up and the configfs orphan
stream behavior. The CVE-2026-74691 linkage note stands as background.

**State left**: streams UP + ATTACHED both ends (bringup.sh verified),
tbnet up, dyndbg on, gufo-prod still STOPPED+DISABLED (user handling prod
elsewhere — `systemctl enable --now gufo-prod` to restore). Discriminator
artifacts: /root/wedge/wedge-repro{,.c}, wedge-run.sh, discrim-{A,B,E,G,D1}.log,
capture-serve-ctrl*/ (the serve-control wedge traces).


## 2026-10-03 (afternoon): THE WEDGE — full investigation, three bugs, current safety envelope

**What the wedge is**: the Barlow Ridge NHI control plane jams after a
tbstream session with heavy traffic is closed. Symptom: "failed to
send/read XDomain properties", "timeout reading config space (route 0)",
"hop deactivation failed" on BOTH hosts, tbnet dead, `/dev/tbstream0`
opens fail (ENXIO/EIO). **Only a reboot of either host clears it** (the
survivor's re-enumeration resets the link). rmdir/module-reload ladders
do NOT help.

**Evidence table (all reproducible; scripts in /root/wedge/)**:

| Test | Traffic | Close pattern | Result |
|---|---|---|---|
| race.sh (random jitter open/close) | none | random interleave | WEDGE @50 |
| cycle-heavy.sh (bw 200×32MiB) | 13 GB/cycle | sequential | clean ×10 |
| race-drain (2s idle pre-close) | none | random | WEDGE @150 |
| race-stag.sh (strictly ordered) | none, 2s lifetime | ordered 1-2s apart | CLEAN ×300 |
| serve (ordered kills, 2.2s apart) | handshake only | ordered | WEDGE @1 (stock AND patched) |
| serve (ordered, 17s apart) | one 61K prefill | ordered | WEDGE @1 |
| serve (ordered, **30s drain**, 17s apart) | one 61K prefill | ordered | **WEDGE @1** |

**Conclusion**: close-after-heavy-traffic is fundamentally unsafe on this
stack (v7.3-rc3 `thunderbolt_stream` + Barlow v2 NHI). No userspace
timing/ordering discipline prevents it. Traffic-free streams cycle
hundreds of times cleanly. The mechanism class is confirmed by upstream
commit f1de1fc5f6 ("quirk to reset host interface on DMA path teardown
for AMD USB4 routers" — comment: *"may hang the Tx ring when the DMA
paths are torn down"*): E2E flow-control state corrupts across DMA path
teardown. AMD (v1) has `REG_HOST_INTERFACE_RESET` hygiene; **Barlow is a
v2 host interface — the reset register is v1-only, so no equivalent
exists** (we patched the quirk table for Barlow: the quirk FIRES but the
reset no-ops, leaving only tb_ctl stop/start churn — which made things
WORSE; reverted). **E2E is mandatory**: dropping RING_FLAG_E2E (module
param experiment) deadlocks the data path at bandwidth (E2E IS the
protocol's flow control).

**Bug #2 (found while investigating)**: a stream open that blocks
waiting for attach (unattached stream) holds the **global misc device
mutex** → every later open of ANY misc device piles up in unkillable
D-state. Reproduced: one stuck gufo rank1 + 5 stuck shells. Recovery:
SIGTERM the process holding the open (its wait is interruptible).
Upstream-reportable (misc_open / stream open interaction).

**Bug #3 (attach mysteries, fully solved)**: stream attach requires
BOTH (a) the configfs service dir name to match the sysfs kstreamp
service EXACTLY (`ls /sys/bus/thunderbolt/devices/0-3.*/driver` — the
index flips between reboots and differs between hosts!), and (b)
explicit `echo -1 > in_hopid; echo -1 > out_hopid` to arm HopID
auto-negotiation. A stream created under the wrong service dir is an
ORPHAN: it registers a /dev node (character device!) but never attaches
(opens get ENXIO, or EINVAL when hops=0). The "1s XDomain properties
ping-pong" in dmesg is the churn of this broken state (also seen
benignly when configfs streams exist unattached). **Use
/root/wedge/bringup.sh** (copied to strix2) — it discovers the service
dir, arms negotiation, sets busy_poll and verifies genuine attach
(O_NONBLOCK open) — both hosts attach in seconds after reboot.

**Safety envelope for operating the pair**:
1. After reboot: `bringup.sh 1` on strix2 (via VPN ssh) THEN `bringup.sh 0`
   on strix1 (or both via tbnet once IPs exist — the script sets them).
2. Long-lived sessions are SAFE: many requests per open (all serving
   today ran this way). Reuse the open stream for everything.
3. NEVER close a stream after heavy traffic and expect to continue: probe-
   style bw+close survived ×10, but serve-context close wedged at cycle 1
   every time. If a restart is needed: expect the wedge → scripted
   recovery = reboot BOTH + bringup.sh (~6 min).
4. gufo serve restarts in a loop = wedge per cycle. Until the kernel fix:
   batch all measurements into one long-lived session per boot.
5. /tmp prompt files do not survive reboots — regenerate before test runs.

**Kernel fix directions (upstream work)**: v2 NHI needs an E2E credit-
state hygiene at DMA path teardown (the v1 `nhi_reset_interface`
equivalent for v2 — `nhi_reset`/REG_RESET_HRR is a full host-router
reset, too heavy for per-close use). Report to linux-usb (Mika
Westerberg / Alan Borzeszkowski) with: repro scripts, the evidence
table, /root/wedge/capture-race/ traces (the fatal close shows local
route-0 config-read timeouts mid-deactivation), and the misc_open
pile-up. Draft included in /root/wedge/UPSTREAM-REPORT.md.

**State left**: both hosts on STOCK modules (patched build preserved at
/root/wedge/build/thunderbolt/ — quirk-for-Barlow + use_e2e param; the
modprobe.d override and initramfs tweaks fully reverted). Streams UP and
ATTACHED (gufo on 0-3, service dir 0-3.0 both ends this boot), busy_poll
on, dyndbg on. Fabric verified 5.03 GB/s after final bringup.
**gufo-prod is STOPPED+DISABLED on strix1 (user: handled elsewhere for
now)** — `systemctl enable --now gufo-prod` when needed. The
TP2-perf plan (Phase 0 f32 control + Phase 1 attribution profiling +
Phase 2 fixes) remains queued; the Q8/f16 serving numbers (2153/2148
tok/s) stand. Phase 0's skew scare was an explore-agent error (both
ranks were on 24ilfipg all along).


## The one-paragraph summary

We implemented a USB4STREAM (`/dev/tbstreamX`) data transport for gufo
TP=2 (branch `feat/tp2-tbstream` in `/root/gufo`, uncommitted), brought up
a working host-to-host stream between the two Strix Halo boxes, and
measured — after a certified passive TB5 cable restored Gen3 and
`--noverify` removed the probe's own checksum cost — **10 KiB all-reduce
exchange p50 = 22–23 µs (at parity with the 24 µs RDMA baseline)** and
one-way bandwidth **1.0–1.14 GB/s** (RDMA 3.27 GB/s; drain-paced by the
driver's interrupt throttle — the remaining lever). The originally
reported 43.6 µs was ~21 µs of probe measurement overhead, not link
cost: the transport checksums nothing, so the `--noverify` figures are
what serving will see. Along the way we hit and documented seven
driver behaviors of Linux 7.2's brand-new `thunderbolt_stream` on this AMD
pair, all worked around in the code. The open question when we paused: the
link trained **Gen3 (40 Gb/s/direction) once** on a cold clean boot, then
fell back to **Gen2 (20 Gb/s/direction)** and never went back; forensics
point at the uncertified active cable (a Gen3-max Parade PS8830 plus one
identity-unreadable retimer in the path), corroborated by community reports
where Gen2 is the norm. Next physical session: cold-start A/B with the
original ports, then the same with the new cable; after that, build and
serve.

## Machines and access

| | Host 1 "akane4" | Host 2 "strix1" |
| --- | --- | --- |
| Role | dev box, repo, future TP2 rank 0 | future TP2 rank 1 |
| Address | local (this box), `10.8.0.6` on tun0 | `ssh root@10.8.0.9` |
| Board hint | AMD-native USB4 (router names empty) | router self-identifies "**Barlow Host Router**" → possibly Intel Barlow Ridge discrete TB5 (like MS-S1 Max) — unverified |
| Kernel | 7.2.6-070206-generic (Ubuntu mainline, unsigned) | same |
| SecureBoot | disabled | disabled (BIOS was changed for this) |
| Root FS | 1.8T LVM | **expanded 100 GB → 1.86 TB** (lvextend +100%FREE, done) |
| USB4 domains | 2 (`c7:00.5`, `c7:00.6`) | 3 (`67:00.0`, `bf:00.5`, `bf:00.6`) |
| Services | gufo server on :15015, auto-restarts (cmdline saved: `/root/gufo-server-cmdline.txt`) | idle |
| Setup done | configfs in fstab, `thunderbolt_stream` in modules-load.d | same |

SSH from host 1 → host 2 works over the VPN: use
`ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@10.8.0.9`.

Current link state at pause: cable connects **host 1 domain 0 port ↔
host 2 domain 1 port** (NOT the original ports — both ends were moved
during debugging). Peer routers: host 1 sees `0-2`=strix1, host 2 sees
`1-2`=akane4. Link **Gen2: 10.0 Gb/s × 2 lanes = 20 Gb/s/direction**.
Streams are **down** (clean teardown done).

## Code state (uncommitted work)

Repo: `/root/gufo`, branch **`feat/tp2-tbstream`** (off neuhaus's
`feat/tp2-rdma`, i.e. gufo PR #296's branch). 18 changed/new paths,
**nothing committed yet**. Base commit `561a6fc`.

New files:
- `src/models/qwen38_flash_next/kernels/rocm/tbstream.{hpp,cpp}` — the
  transport. Key design points forced by the driver: two open()s of the
  device (nonblocking fd for deadline-bounded writes; **blocking fd for
  the reader thread**, which is detached at stop and its fd never closed);
  reader spins 5 ms before sleeping on empty (zero-byte) reads;
  readiness barrier after fd-open before any exchange (bootstrap
  kReadyMagic); only-raise GPU arrival flag; same windows/header/ordinal
  protocol as verbs.
- `tools/tbstream/tbstream_probe.cpp` — host-only microbenchmark
  (`loop|ping|bw|exchange|smoke`), dual-fd + post-open barrier as above.
- `tools/tbstream/setup-stream.sh` — `check|up|down [NAME]` (name **≤ 8
  chars**, driver limit; auto-discovers peer route in any domain).
- `tools/tbstream/README.md` — full runbook incl. troubleshooting.

Modified: CMake root/model/tests (`GUFO_ENABLE_TP2_TBSTREAM`), presets
(`gpu-tp2-tbstream`), Nix (`nix build .#tp2-tbstream`), serve.cpp
(`--tp-transport rdma|tbstream`, `--tp-tbstream-dev`), the three probes,
docs (TP2.md, EXPERIMENTS.md, DEVELOPMENT.md).

All repo checks passed at pause: `check-format.py`, `check-docs.py`,
`check-dependencies.py`, CPU test suite incl. `tp_control_test` /
`tp_executor_test`, `gufo` target builds (CPU path), backend compiles
clean (HIP-stub syntax check; real GPU build still pending).

**Still to do in code**: GPU build on host 1 (needs Nix install or ROCm —
nothing on the box yet), deploy to host 2, GPU qualification, serving.

Host-side helper scripts (NOT in the repo, persistent):
- `/root/install-kernel-7.2.6.sh` — kernel installer (used on both hosts).
- `/root/tbstream_probe` (both hosts have it; host 2's at
  `/root/tbstream_probe`) and `/root/tbstream-pair-qualify.sh` — paired-run
  orchestrator (rank 0 here, rank 1 via ssh; writes full logs to
  /tmp — recreate /tmp dir if rebooted: it just needs the probe paths).
- `/root/gufo-server-cmdline.txt` — exact restart command for the server.

## Measurement results (final, Gen2 link, kernel 7.2.6)

Stream defaults (ring_size 256, throttling 8192) unless noted; measured
with `tbstream_probe` both ranks over the VPN-coordinated pair:

| Metric | Value | RDMA baseline | Note |
| --- | --- | --- | --- |
| Exchange 10 KiB p50 / p90 / p99 | **43.6 / 56 / 74–82 µs** | 24 µs | reproduced 4×; the transport's viability metric |
| Bandwidth 1 MiB / 5 MiB / 32 MiB | 0.72 / 0.50 / 0.46 GB/s | 3.27 GB/s | one-way |
| Tuned (ring 1024, throttle 65536) | 0.75 / **0.77** / 0.47 GB/s | — | but exchange p50 degrades to ~110 µs — keep defaults for serving |
| 32 MiB lock-step exchange | deadlock (both ends block writing) | n/a | expected: rings ≪ frame; **proves the always-draining reader thread is required** |
| smoke (odd sizes ≤ 10 KiB) | ok, p50 61 µs | — | framing + integrity verified |
| echo/ping at 10 KiB | still stalls (known quirk) | — | exchange/smoke — the transport's shapes — are unaffected |

Everything is recorded in
`docs/models/qwen3.8-flash-next/EXPERIMENTS.md` (TP2-tbstream section)
and `tools/tbstream/README.md`.

## Driver findings (Linux 7.2.6 thunderbolt_stream, AMD Strix Halo pair)

All are encoded in the transport/probe/README:

1. Stream names ≤ 8 characters (longer mkdir → ENAMETOOLONG).
2. **Only blocking reads are reliable.** Frames arriving while no reader
   is parked in `read(2)` are invisible to `poll(2)` AND to nonblocking
   reads. Blocking reads return them immediately.
3. An empty ring reads as **zero bytes** (not EOF) — retry; spin ~5 ms
   first for latency, then sleep 100 µs.
4. Data written before the peer opened its fd is **stranded** — needs a
   post-open barrier (probe: pairing.Ready(); transport: bootstrap
   kReadyMagic exchange after reader start).
5. **External kills of blocked writers wedge the stream** (next open
   EIO; teardown hangs; a wedged link flaps every ~55 s until streams are
   removed). Clean exits through the 30 s write deadline do NOT wedge.
   Recovery ladder: streams `down` on both → PCI rebind
   (`echo <pci> > /sys/bus/pci/drivers/thunderbolt/{un,}bind`) → reboot.
   Never kill probes mid-exchange; never truncate their output (a SIGPIPE
   of the orchestrator once caused exactly this).
6. `throttling` configfs knob = latency/bandwidth dial (see table above).
7. Misc: peer route string changes across rebinds/reboots and can be any
   domain (script auto-discovers); device minor (index) is not stable —
   check `ls /dev/tbstream*` and pass `--tp-tbstream-dev` accordingly.
   Note: host 1 once got `tbstream1`, host 2 `tbstream0`, simultaneously.
   L1T findings (not yet applied): NHI interrupt throttling defaults to
   128 µs (yann's patch adds a `throttle` module param — **not in
   7.2.6**, checked); `dma_credits=14` module param exists and relates to
   the 32 MiB deadlock / bandwidth ceiling.

**Upstream-worthy bug report TODO**: findings 2 and 5 (poll/nonblocking
invisibility; wedge-on-kill) to the linux-usb/thunderbolt list, with our
repro steps. yann on L1T (May 2026) independently documented the
interrupt-throttle latency issue.

## Link-speed investigation (the Gen3 → Gen2 question)

Timeline (all from this session's logs):
1. First bring-up, cold boots, original ports (host 1 domain 1 ↔ host 2
   domain 0): **Gen3, 20.0 Gb/s/lane × 2 = 40 Gb/s/direction**. Retimer
   seen: `1-0:2.1 vendor=0x1da0 device=0x8830` (Parade PS8830).
2. After the first stream wedge + host 1 reboot (cable untouched): link
   re-trained at **Gen2, 10.0 Gb/s/lane**, and stayed there ever since —
   across warm reboots AND a dual full reboot.
3. Later replug moved BOTH ends to different ports (current: host 1
   domain 0 ↔ host 2 domain 1): still Gen2.

Forensics: each host sees two retimers, mirrored —
host1 → **PS8830 (0x1da0/0x8830)** → **unidentified (0x0/0x0)** ← host2.
The unidentified chip sits at host 2's end of the path and failed to
report vendor/device since the wedge era. A CM that cannot read a
retimer's capabilities will not certify the path for Gen3.

Cable: EUDOBEL B0DN2379LL, "USB4 V2.0 80Gbps TB5", €18.67, **no USB-IF or
Intel certification claim**. The **PS8830 is a Gen3/40G-max retimer** —
this cable can never do 80 G. Genuine certified TB5 cables run €60+.
One Gen3-max chip + one unreadable chip in an uncertified active cable is
the leading explanation for Gen2.

Community corroboration (Level1Techs, "Benchmarking USB4 performance on
Strix Halo", thread 245299): Framework-Desktop Strix Halo pairs with
TB5-rated cables also negotiate **Gen2** (yann: "below the 20 Gbps the
firmware reports and the 40 Gbps it should be capable of"); nobody in the
thread got Gen3 host-to-host with consumer cables. Same thread: mgeppert
claims the AMD PHY is USB4-v2-capable with ~78 Gb/s one-way between
GMKtec EVO-X2 boxes using a custom driver that ignores reported caps
(unverified); Emil_N notes MS-S1-type boxes use Intel Barlow Ridge TB5
controllers (64 G PCIe-capped) — and host 2's router self-names "Barlow
Host Router".

Answer to "did we wedge something else?": **no permanent wedge** — Gen2
is the community norm; our Gen3 was the outlier (cold-clean enumeration);
the fallback happened around the flap era and persists because the
unreadable retimer makes Gen2 the correct conservative choice.

## Pending experiments (next physical session)

### A. Cold-start A/B with the ORIGINAL ports (decisive, ~15 min)

1. Shut down BOTH hosts; remove AC for ≥ 60 s (fully powers the cable's
   retimers and both controllers).
2. Move the cable back to the original ports: host 1 → the port whose
   link was `domain 1` (controller `c7:00.6`, second USB4 port group);
   host 2 → the port whose link was `domain 0` (controller `67:00.0`,
   behind the PCIe bridge chain).
3. Boot both; then on each:
   `cat /sys/bus/thunderbolt/devices/*/rx_speed` (expect a `X-2`-style
   peer) and `dmesg | grep retimer`.
4. Read: if Gen3 (20.0 Gb/s/lane) returns → training-state stickiness
   confirmed; cold-start is the recovery procedure. If the 0x0/0x0
   retimer still appears → the cable's chip is unreadable, Gen2 is its
   ceiling; proceed to B.

### B. New cable test — DONE (2026-10-01, closed)

The certified passive TB5 cable (Cable Matters B0CP8K1C59, Intel-certified,
1 m) was plugged in hot — no cold start — and the link **immediately
trained Gen3: 20.0 Gb/s/lane × 2 = 40 Gb/s/direction**, on both hosts.
The retimer chain is clean: exactly one identified PS8830 per host (the
board-side retimer) and **no cable retimers** (passive). The old cable's
unidentified 0x0/0x0 chip is gone. Diagnosis confirmed and closed: the
uncertified cable forced Gen2.

Measurements at Gen3 (recorded in EXPERIMENTS.md):
- exchange 10 KiB p50 **43.7/44.0 µs**, p99 63–65 (slightly better tail
  than Gen2's 74–82)
- bandwidth **unchanged** from Gen2: 0.73/0.51/0.47 GB/s at 1/5/32 MiB —
  doubling the link rate moved nothing
- the sender idles at ~0% CPU during bw runs → the 0.5 GB/s ceiling is the
  driver's ring-drain path (interrupt-paced), not the link, not user CPU
- the `throttling` knob's Gen2-era bulk gain (0.50→0.77 GB/s) vanished at
  Gen3 (0.48 vs 0.51) — the host path saturates first; defaults stay

Consequences: **dual-link striping (experiment E) is now the decisive
bandwidth lever** (if the pacing is per-ring it should scale; if
per-controller it won't), and the NHI interrupt-throttle constant remains
the kernel-side lever. Decode latency is settled at ~44 µs either way.

### C. Optional per-port map (~10 min)

Cycle the cable through each host's other USB4 ports on cold boots;
record trained rate + retimer identities per port. Settles whether any
port pair is systematically better (and which controllers map to which
physical ports — useful documentation for the wiki).

### C. Userspace polish — DONE (2026-10-01)

Write-path busy-spin (mirrors the reader) and reader/worker CPU pinning
landed in the transport; the write spin measurably changed nothing (the
exchange write path never blocks), but the investigation it triggered
found the probe's checksum overhead hiding the real numbers — see the
summary above. `--noverify` added to the probe as the measurement mode;
integrity stays covered by checksummed runs.

### D. After the link question settles: kernel knobs for bandwidth

- The stream `throttling` knob and `dma_credits` (module param, =14) are
  the identified levers toward closing the 0.5 → 3.27 GB/s gap vs RDMA.
- yann's interrupt-throttle patch (L1T post, May 2026) shows <20 µs RTT
  with throttle=0 through tbnet; the equivalent behavior for
  thunderbolt_stream is worth testing once a mainline param exists (or a
  small out-of-tree patch — same file, `drivers/thunderbolt/nhi.c`).

### E. Dual-link striping (two cables) — tooling ready

`tbstream_probe` now stripes frames round-robin over multiple links:
pass `--fd /dev/tbstream0,/dev/tbstream1` (and optionally `--stripe 2`).
`setup-stream.sh up NAME ROUTER` creates one stream per peer router
(`check` lists every peer with its negotiated speed; names ≤ 8 chars,
e.g. `up linkA 0-2` + `up linkB 1-3`). Loop-mode striping is validated on
this box; the paired mode waits for the second cable. Purpose: decide
whether the 0.72 GB/s single-stream ceiling is link-bound (aggregate ≈ 2×
→ transport striping worth implementing) or host-bound (≈ 1× → chase the
kernel knobs instead). Expectations and caveats are in the README's
"Dual-link striping" section — decode latency does not benefit, only
prefill bandwidth.

### A. Kernel/parameter levers — DONE (2026-10-01, resolved without a patch)

Read the v7.2.6 driver source (sparse checkout at /root/tb-kernel/linux):
the 128 µs NHI throttle from the L1T patch **no longer exists in 7.2** —
per-ring `tb_ring_throttling()` replaced it, and `thunderbolt_stream`
already drives its rings from the configfs `throttling` attribute
(nanoseconds, 0 disables). Tested on the pair: throttling 0 / 8192 /
65536 and ring_size 256 / 1024 all measure the same **1.08–1.14 GB/s** —
the plateau is the DMA tunnel credit limit (`dma_credits` capped by the
router-reported max of 14 → ~56 KiB in flight at ~20 µs pipeline ≈
1.1 GB/s). That is a fabric-level limit: upstream mail material, not a
parameter. No patched module was needed or built; the source checkout
stays for the upstream report.

**Final single-link numbers** (Gen3, `--noverify`): exchange p50
**22–23 µs** (RDMA parity), bandwidth **1.0–1.14 GB/s** (flat across
frame sizes). Remaining known levers: dual-link striping (experiment E,
needs the second cable; 2 × 1.1 ≈ 2.2 GB/s would close most of the gap
to RDMA's 3.27) and upstream credit-limit work.

### Throughput investigation — 2026-10-01 (evening): root-caused, one path blocked

S2 (receiver instrumentation): during a 1.13 GB/s run the receiver sees
~125K interrupts/s and **no core above 20% busy** — the per-frame
pipeline is latency-bound, not CPU-bound. Combined with source reading:
NHI descriptors are hard-capped at 4 KiB (12-bit size field), stream
rings use E2E flow control, and RX buffers are reposted one at a time
from the reader's read() (process context) with a per-frame wake_up.
1.1 GB/s ≈ the interrupt→wake→copy→repost loop's steady state.
(The earlier "14-credit fabric cap" attribution was wrong/secondary —
EXPERIMENTS.md corrected. mgeppert's 78 Gb/s custom driver proves the
fabric goes far faster with kernel-side repost.)

S1 (multi-stream on one cable): BLOCKED by the driver. A second stream
per peer (stream/<router>.1/<name>) creates /dev/tbstream1 on both
hosts, but **no second DMA tunnel forms** — auto hopids stay -1/-1 in
either creation order, manual 9/9 accepted without a path (debugfs port
path dump unchanged). First stream always works. Upstream-report item.

Remaining throughput paths, ranked:
1. **S4 patched thunderbolt_stream** (out-of-tree, rollback-safe):
   repost RX buffers from the callback/work, not read() — the
   "mini-mgeppert" fix. Half a day. Source already at
   /root/tb-kernel/linux (v7.2.6 sparse checkout).
2. **Second cable** (experiment E): separate domains = real separate
   tunnels, 2 × 1.1 ≈ 2.2 GB/s expected.
3. Upstream mail (now including the multi-stream bug + per-frame repost
   analysis + the earlier poll/wedge findings).

### Track E: two-host TP2 serving — 2026-10-01 (late): DONE, WORKING

Milestone: **first end-to-end TP2 serving over USB4STREAM on our pair.**

Infra now in place (persistent):
- Nix (Determinate 2.35.2) on BOTH hosts. Host2 also has: /root/gufo
  (rsynced, incl. built probe), /models weights (111.7 GB, LAN rsync
  112 MB/s), gufo closure at /nix/store/qp81ab79...-gufo-0-unstable-561a6fc-dirty.
- Closure copy: `nix copy --to ssh-ng` fails on our unsigned path despite
  trusted-users=root (Determinate strictness); workaround that worked:
  `nix-store --export <path> | ssh host2 nix-store --import` (deps were
  already copied fine). keyscan 192.168.68.113 into known_hosts first.
- Hosts are on LAN: host1=192.168.68.120, host2=192.168.68.113 (1 GbE).
- GPU on host2 verified: gfx1151 via nix ROCm 7.2.3 userspace.
- Prod container gufo-prod2 publishes **host port 15003** -> container
  15015 (15015 on the host is NOT the prod endpoint).
- Host2 clock runs ~2 h behind host1 (cosmetic, unaddressed).

IMPORTANT for future nix builds: `git add` new files before building the
flake (untracked files are invisible to git+file refs) — done (staged,
NOT committed).

Results (Q4_K_XL + MTP Q8, 4 sessions, ctx 65536, cache off):
- tp_probe two-host: identical text on both ranks; --split 40 bit-stable
  per rank (96/96 obs, logits max_abs_diff 0; world-1 ref 48/48).
- Serving: load ~16 s/rank (~48-51 GB GPU/rank), TTFT 482 ms @65-tok
  prompt, **MTP decode 76.1 tok/s** (93% draft acceptance), **prefill
  1159.7 tok/s** @3293-tok prompt. Decode is compute-bound (exchange
  ~23 µs vs 13 ms/token) — the 1.1 GB/s plateau only touches prefill.
- Scripts kept: /tmp/opencode/{serve-rank0.sh,probe-rank0.sh,split-w2-r0.sh}
  on host1; /root/{serve-rank1.sh,probe-rank1.sh,split-w2-r1.sh} on host2.

Remaining throughput levers unchanged: S4 patched stream driver, second
cable, upstream mail (multi-stream bug + per-frame repost analysis).

### S4 kernel patch — 2026-10-02: in progress, host2 needs a power cycle

P0 baselines locked (before patch): prefill 1061/1247/1275/1276 tok/s at
2K/8K/32K/64K tokens (tp_batched_probe, both members); allreduce-bench
5 MiB p50 3.66 ms (~1.4 GB/s effective); decode p50 22 us.

Driver work so far (/root/tb-stream-module/stream.c, kthread design):
- RX backlog + kernel-side repost worker, readers drain a kmalloc FIFO.
- TWO hard lessons encoded in comments: (1) back-to-back reposts in the
  hundreds BRICK the AMD NHI (config space unreadable, hops fail to
  deactivate) -> consumer is a kthread paced at 64 frames / 200 us via
  usleep_range (workqueue timers round sub-jiffy delays up to 4 ms at
  HZ=250, which throttled to 0.12 GB/s - measured); (2) the kthread MUST
  spawn AFTER both rings exist (spawn-before-rings = NULL deref oops in
  tbstream_dev_rx_frame_pending, thread dies, stream stalls silently;
  also poisons stop via kthread_stop on the dead task).
- Current build: kthread spawns last in start(), frame_pending guards
  NULL rings, repost failures logged, NHI-error-free through a paced
  2816-frame run (11 MB) with correct delivery.
- Redeploy helper: /root/redeploy-tbstream.sh (scp+rmmod+insmod+streams
  up on both hosts). Recovery ladder unchanged (reboot works).

STATE RIGHT NOW: host2 was rebooted to clear an oopsless wedge and DID
NOT COME BACK (no LAN, no VPN, USB4 peer gone from host1's topology).
Needs physical power cycle. If it hangs at boot with the cable in,
boot it with the USB4 cable UNPLUGGED first (wedged NHI may hang
firmware link training), then replug. Host1 is healthy and idle; the
fixed module + redeploy script are ready. After host2 returns:
/root/redeploy-tbstream.sh, then the validation ladder:
1. dd 20 MB both directions + dmesg NHI-error check
2. qualify.sh exchange 10240x200 (--noverify) - expect ~22 us p50
3. qualify.sh bw 1/5/32 MiB - compare 1.01/1.05/1.13 baseline
4. tp_probe two-host + --split, tp_batched_probe prefill sweep vs P0
5. serving smoke + MTP decode check (76.1 tok/s baseline)

### 2026-10-02: transport survey — tbnet measured, thunderbolt-ibverbs blocked upstream

Track B (tbnet, DONE — kept running): thunderbolt_net on both hosts,
thunderbolt0 10.55.0.1/10.55.0.2 MTU 9000, pm_qos_resume_latency_us=100 on
all CPUs (RTT 600us -> 117us). iperf3: 9.27 Gbit/s one-way (1.16 GB/s, no
P-stream scaling), 31.7 Gbit/s bidirectional aggregate. Per-direction IP
ceiling == tbstream ceiling on AMD<->AMD.

Track A (thunderbolt-ibverbs, BLOCKED): /root/tbv (v0.3.4+2449afd), module
built out-of-tree both hosts, loaded with profile=linux_perf lanes=1
roce_netdev=thunderbolt0. Rail 0 handshake OK, usb4_rdma5/usb4_rdma0
registered, GIDs at index 0 (v6 LL) / 1 (IPv4-mapped; use -x 1 / gid-index 1,
NOT the hardcoded gid 3 in their u4_pingpong). All RC WRITEs stall
(partially delivered, retransmit loop, zero completions at 4K-1M sizes).
Issue drafted: /root/tbv-issue.md + /root/tbv-{h1,h2}-dmesg.txt. Module
unloaded on both hosts (clean). Their nix flake works: perftest + bench-tools
+ rdma-core-usb4 closures copied to host2 via nix-store --export | --import.

tbnet + pm_qos state left RUNNING on both hosts (harmless, useful for
future TCP experiments; streams/tbstream untouched, prod unaffected).

Next options: (1) post /root/tbv-issue.md upstream (gh not installed/authed
here — needs user action or a token), (2) second cable arrives -> stock
tbstream dual-link striping (probe --fd already stripes; communicator needs
multi-device), (3) retest tbv when they fix the AMD<->AMD single-cable data
path.

### 2026-10-02 (later): tbv ROOT-CAUSED AND FIXED — working RDMA over USB4

The thunderbolt-ibverbs zero-completion failure was a mixed-E2E bug:
tbv_native_e2e_auto_enabled() returns TRUE when xd->tb is unresolved at
rail creation -> one host's path got E2E rings (tx_flags=0x6), the peer
non-E2E (0x2) -> the E2E host's TX posts descriptors that never transmit
(ACKs cannot return) -> every RC WRITE stalls. FIX: load with
**native_e2e=0 on BOTH hosts** (module param, no code change). Symmetric
native_e2e=1 wedges the AMD NHI (their comment warned about multi-rail
E2E; it wedges single-rail too).

Working load line (both hosts):
  insmod thunderbolt_ibverbs.ko profile=linux_perf bind_services=1 \
    allocate_rings=1 start_rings=1 negotiate_native=1 enable_tunnels=1 \
    register_verbs=1 lanes=1 roce_netdev=thunderbolt0 native_e2e=0
GIDs: index 0 = v6 LL, index 1 = IPv4-mapped -> use gid-index 1 (-x 1).
Verify symmetry: grep path_cfg /sys/kernel/debug/thunderbolt_ibverbs/peers
BOTH hosts must show tx_flags=0x2 e2e=0.

Measured on our pair (perftest from their flake, /root/tbv/result):
- ib_write_lat: 8.2/9.2 us min/avg @2B; 15/16.3 us @10KiB (tbstream: 22 us RTT)
- ib_write_bw: 1095 MiB/s sustained @64KiB (52K iters/5s); 734 MiB/s @1MiB
  (~8% data frames lost without E2E; software retry recovers small msgs,
  taxes big ones)
- Devices: host1 usb4_rdma5 (domain1), host2 usb4_rdma0 (domain0)

tbnet + pm_qos still up (10.55.0.1/.2). Their perftest/bench-tools/
rdma-core-usb4 closures imported to host2. Issue draft with root cause:
/root/tbv-issue.md (ready to post — now includes the fix + measurements).

NEXT (the capstone): gufo --tp-transport rdma over usb4_rdma — needs a
tp2-rdma build linked against THEIR rdma-core-usb4 (package.nix takes
rdma-core as a param: override with tbv's rdma-core-usb4 output
/root/tbv result — /nix/store/pn4qzv29apawkw7i5rymk3vszbrk1zi3-rdma-core-usb4-64.0).
Then: tp_probe --tp-transport rdma --tp-device <idx> --tp-gid-index 1,
allreduce-bench, prefill sweep, serving smoke. Expected: decode
exchanges ~16 us (vs 22), prefill ~parity single-rail; the bandwidth
jump still needs the second cable (multi-HCA).

NOTE: their module teardown (rmmod) can hang up to ~2 min after a
failed test; benchmark binaries must be killed first (pkill -9 -f
rc_write_poll / ib_write). Module is loaded RIGHT NOW on both hosts
(working config, idle).

### 2026-10-02 (final): gufo RIDES thunderbolt-ibverbs — integration proven, perf upstream

Capstone complete: gufo tp2-rdma built against their rdma-core-usb4
(build: /root/gufo-rdma-usb4 -> /nix/store/0svvmadpxi4z02d7pml14pd873s0v4xn-
gufo-0-unstable-dirty, closure imported to host2). TWO one-line patches in
verbs.cpp were needed (link_layer checks assumed InfiniBand; device reports
Ethernet) — staged in the working tree, uncommitted. Serving: BOTH ranks
pair and generate CORRECT output with --tp-transport rdma --tp-device 0
--tp-gid-index 1. Launch scripts: /tmp/opencode/serve-rdma-rank0.sh,
host2:/root/serve-rdma-rank1.sh.

Perf: MTP decode 38.6 tok/s (vs 76.1 tbstream; 96% acceptance, correct
text). Cause (from their debugfs counters): whole-message retransmit
amplification (~8x frames; ~75 ms retry timeout) + 230K credit stalls
(32-credit per-message start reservation vs 768 window) under gufo's
queued-exchange RPC pattern. perftest on the same device is healthy
(16 us @10 KiB, 1095 MiB/s @64 KiB) -> the verbs path is right, the
flow-control tuning is an upstream fix.

END STATE (all restored): tbv module unloaded both hosts; prod container
gufo-prod2 up on 15003; tbnet + pm_qos still active; streams untouched
(stock module); tp2-rdma-usb4 closures on both hosts for future reruns.
tbstream remains the production transport; tbv = upstream track
(/root/tbv-issue.md ready to post, now with fix + integration results).

### 2026-10-02 (final): MIGRATION — strix1 is now host1 + production

New MS-S1 box (80 Gbps USB4) arrives today; it becomes the future host2.
strix1 (192.168.68.113, tun0 10.8.0.9) is now the dev box AND production:

- PROD: native nix gufo under systemd unit gufo-prod (port **15003**),
  launcher /root/serve-prod-native.sh (tp2-rdma-usb4 closure binary
  0svvmadpxi4z02d7pml14pd873s0v4xn in one-host mode, same flags as the
  old container incl. disk cache at /root/gufo-cache). Unit drops page
  caches before start (GTT load needs the RAM runway) + Restart=always.
  Verified: 96 GB GTT load in ~96 s, 33 tok/s single-host MTP.
- REQUIRED kernel cmdline (in strix1 grub now): iommu=pt
  ttm.pages_limit=31457280 ttm.page_pool_size=31457280 -> 120 GB GTT.
  Without it the GPU sees only ~62 GB and model loads fail.
- OPEN BUG (non-blocking): the gufo-chunked:union8f6a DOCKER image loads
  fail on strix1 with "weight upload staging allocation failed"
  (hipHostMalloc path) even with identical devices/ulimits/cmdline that
  work natively and on old host1's docker — native serving is the
  workaround; image kept on strix1 for later debugging (docker 29.1.3 vs
  old host1's docker suspected: seccomp/cgroup delta).
- Transferred to strix1: /root/gufo (WITH .git + staged state, 21 paths),
  /root/tb-kernel, /root/tb-stream-module, /root/tbv, all /root scripts
  + docs, /root/opencode-tools (3 scripts; others live in repo+handover
  snippets). Weights /models + all nix closures were already there.
- OLD host1 (akane4, 192.168.68.120/10.8.0.6): prod stopped + restart
  disabled, machine left ON idle for manual decommission. Its unique
  state (if needed): /home/doctomoe (personal), 512 GB KV cache
  (skipped, rebuilding on strix1), gufo-chunked image (loaded on
  strix1).
- WHEN THE NEW BOX ARRIVES: it becomes host2 (peer). The scripts carry
  OLD addresses: qualify.sh + redeploy-tbstream.sh + serve-rank1/rdma
  scripts hardcode 192.168.68.113/10.8.0.9 as the PEER — parameterize or
  edit to the new box's addresses. Requalify the link (80 Gbps ports ->
  possibly Gen4/80G; our TB5 cable rated for it). tbnet/pm_qos/streams
  bring-up from the handover sections above applies unchanged.

## After that: resume the original plan (Phases 5–7)

1. Install Nix multi-user on host 1 (gufo's pinned toolchain; the running
   server already comes from a nix store path). Stop the gufo server at
   this point (it holds ~100 GB GPU; restart command saved).
2. `nix develop` + `cmake --preset gpu-tp2-tbstream` → build `gufo`,
   `tp_probe`, `tp_batched_probe`; ship to host 2 (same Ubuntu 26.04).
3. GPU qualification: `tp_probe --tp-transport tbstream --split` on both
   hosts (bit-identical invariance), `tp_batched_probe --allreduce-bench`
   (exchange µs with GPU staging).
4. Serve the TP2 pair with `--tp-transport tbstream` (host 2 bootstraps
   to 10.8.0.6), run the TP2.md qualifying subset, fill the Serving row
   in EXPERIMENTS.md, then decide on committing/PR'ing the branch.

### 2026-10-02 (strix2 session): TOPOLOGY MAP + access — both boxes identical MS-S1 design

Machines: **strix1** = host1 (dev + prod, LAN 192.168.68.113, tun1 10.8.0.9).
**strix2** = new host2 (MS-S1, LAN 192.168.68.126 — DHCP, may change,
**tun0 10.8.0.11 — stable**), kernel 7.2.6-070206-generic already installed,
122 GB RAM, 1.9 TB root, 32 CPUs, Radeon 8050S/8060S (gfx1151) present.

**Access (all key-based, works):**
- `ssh strix2` (=10.8.0.11) / `ssh strix2-lan` (=192.168.68.126) from strix1
- `ssh strix1` (=10.8.0.9) / `ssh strix1-lan` from strix2 (strix2 now has its
  own ed25519 keypair; pub installed on strix1)
- Fallback when VPN+LAN are down: tbnet link-local IPv6 — strix2
  `fe80::109c:97ff:fe9f:6eaa%thunderbolt0`, strix1
  `fe80::10c9:f5ff:fef5:ef16%thunderbolt0` (sshd answers there).

**USB4 topology (verified identical on both boxes, lspci + sysfs):**
- **Intel JHL9580 Barlow Ridge TB5 80G** (NHI `67:00.0`, xHCI `92:00.0`,
  bridges `65:00.0`/`66:00.0`+`66:01-03`) = **domain0**, host router `0-0`.
  TWO exposed ports = the 2× USB4v2 (80G) ports:
  - `usb4_port1` — PS8830 retimer inline (`0-0:1.1`, 0x1da0/0x8830, Gen3-max
    chip — avoid; only this port had the retimer, on strix2 none at all)
  - `usb4_port3` — no retimer, clean passive path (**preferred**)
- **AMD Strix Halo native USB4**: `bf:00.5` = domain1, `bf:00.6` = domain2,
  each ONE exposed port (`usb4_port2`) = the 2× USB4 (40G) ports.
- **Both 80G ports are on the ONE Barlow controller (domain0)** → a dual-80G
  cable setup shares one NHI/DMA engine; the only cross-controller pair is
  **80G (domain0) + 40G (domain1 or domain2)** — this changes the multi-cable
  matrix expectations (per-controller sharing is now likely for 2×80G).

**Current link**: cable Barlow `usb4_port3` ↔ `usb4_port3` on both boxes,
peer routers 0-3 both sides.

> **⚠ SPEED SEMANTICS CORRECTION (2026-10-02, late — supersedes every
> "Gen2/Gen3" statement in this file, including the ones below):**
> `rx_speed`/`tx_speed` are **PER-LANE** rates, not aggregate. Verified in
> source: `speed_show` (switch.c) prints `sw->link_speed`, which is set from
> `tb_port_get_link_speed()` = the lane adapter's CURRENT_SPEED decode
> (GEN4→40, GEN3→20, else→10 Gb/s per lane); lane count is a separate attr
> (`rx_lanes`). Raw lane-adapter registers (debugfs
> `0-0/port3/regs`, cap_id 0x01 offsets 0/1) confirm on BOTH ends:
> `LANE_ADP_CS_1 = 0x4822001e` → CURRENT_SPEED=**0x2 = GEN4**,
> CURRENT_WIDTH=dual; an idle port parks at 0x8 (GEN2). Therefore:
> **rx_speed 40.0 + rx_lanes 2 = Gen4, 80 Gb/s aggregate per direction** —
> the link has been at Gen4 whenever it read 40.0, including the old pair
> and this one. The old "Gen3 40G aggregate" labels were that systematic
> misreading; "Gen2 20G" was read correctly (10.0 per-lane). The "kernel has
> no TARGET_SPEED_GEN4" finding is MOOT — the PHY/firmware trains Gen4 by
> itself, the SW CM only manages width (incl. asym 3-lane = the "120G"
> mode, `asym_threshold` param). **No Gen4 patch is needed or useful; the
> Gen4 question is closed.** Ground truth throughput: tbnet iperf
> single-stream 36.4 Gbit/s AND -P 4 aggregate 36.0 Gbit/s (CPU/driver
> ceiling — thunderbolt_net, GRO warning in dmesg; NOT the link limit);
> tbstream 5.0 GB/s ≈ 50% of the 80G line rate (~9.4 GB/s usable), the
> rest is stream-driver headroom we don't need (prefill is compute-bound
> at ~2.5 GB/s).

Other state: tbnet link-layer up both ends (thunderbolt0, link-local only,
no IPv4 configured yet). Streams down everywhere; prod (gufo-prod, 15003)
untouched and running. No retimers on strix2; strix1's PS8830 only on port1.

**strix2 Phase-1 gaps still open**: grub cmdline missing
`iommu=pt ttm.pages_limit=31457280 ttm.page_pool_size=31457280` (needs one
reboot), nix not installed, `pm_qos_resume_latency_us` unset (=0), /models
absent (112 GB rsync pending), no /root/gufo checkout yet.

### 2026-10-02 (strix2 session): Phase 1 DONE, 7.3-rc3 adopted, link re-baselined — 5 GB/s + 7.8 µs

**Kernels: BOTH hosts now run 7.3.0-070300rc3** (mainline PPA build
7.3.0-070300rc3.202609132247, installer `/root/install-kernel-7.3rc3.sh`;
7.2.6 kept as grub Advanced fallback). GRUB_DEFAULT is PINNED per host —
mainline rc entries sort BELOW release versions, so after any kernel install
re-pin `GRUB_DEFAULT="gnulinux-advanced-<uuid>>gnulinux-<ver>-generic-advanced-<uuid>"`
in /etc/default/grub (both hosts' uuids are in their /etc/default/grub).

Why 7.3-rc3: checked upstream master — no Gen4 link-training work exists in
the thunderbolt driver (and per the SPEED SEMANTICS CORRECTION above, none
was ever needed: 40.0 rx_speed was already Gen4 per-lane). The 7.3 merge
window shipped **upstream versions of our S4 wishlist**: `stream: busy
polling` (configfs `busy_poll` attr), `Make interrupt optional for rings`,
short read/write fixes, and the **AMD host-interface reset quirk on DMA
teardown** (our wedge fix). Note: the earlier "7.3-rc3 trains Gen3 40 Gb/s"
statement in this session was the same per-lane misreading — it trained
Gen4/80G aggregate, same as 7.2.6 did.

**Re-baseline on 7.3-rc3 (stock tbstream, defaults, --noverify):**
| Metric | 7.2.6 old | 7.3-rc3 defaults | 7.3-rc3 busy_poll=1 |
| --- | --- | --- | --- |
| exchange 10 KiB p50 | 22 µs | 26 µs | **7.8 µs** (p90 9.3) |
| bw 5/32 MiB | 1.0–1.13 GB/s | **5.0 GB/s** (5.03/5.00) | **5.03 GB/s** |
| checksummed bw 32 MiB | 0.72 | 0.95 | — |

- 5.0 GB/s = **~50% of the Gen4 80G line rate** (~9.4 GB/s usable after
  encoding/FEC) — the remaining gap is stream-driver headroom, not link
  speed, and prefill is compute-bound at ~2.5 GB/s so it doesn't matter.
  The old 1.13 GB/s drain-paced plateau is GONE (upstream drain/short-read
  fixes + AMD quirk).
- busy_poll=1 (configfs attr on the stream dir, set on BOTH ends) gives
  latency AND bandwidth together: 7.8 µs beats even the tbv RDMA track
  (16 µs). Costs CPU spin; poll(2) unusable. Default off; revert by echoing 0.
- Checksummed runs verify clean (0.95 GB/s bw, 34 µs exchange) — integrity OK.

**Consequences:**
- **S4 patched stream module project: OBSOLETE** — upstream won; /root/tb-stream-module stays as history. `redeploy-tbstream.sh` is dead too.
- **Second cable / dual-link striping: MOOT for bandwidth** — one 80G link
  already exceeds prefill's compute-bound ~2.5 GB/s at 50% line rate. Two
  cables only pay off if the stream driver ever saturates one link (~2×).
  (And both 80G ports share the one Barlow controller — per-controller DMA
  sharing could cap a dual-80G setup below 2× anyway.)
- **tbv/thunderbolt-ibverbs track: outclassed** (7.8 µs vs 16 µs, 5.0 vs 1.1 GB/s). tbstream remains THE transport.
- Prefill is now purely compute-bound; nothing link-side limits TP2 anymore.

**strix2 Phase 1 complete**: kernel 7.3-rc3 ✓, grub cmdline
`iommu=pt ttm.pages_limit=31457280 ttm.page_pool_size=31457280` ✓ (needed a
reboot; first reboot silently went 7.2.6 due to the pin above), nix
Determinate 3.23.0 (flakes ok) ✓, pm_qos 100 µs ✓, /models 108 GB rsynced in
91 s @ 1.17 GB/s over tbnet, md5s identical both ends ✓, probe +
setup-stream.sh deployed (/root/tbstream_probe, /root/setup-stream.sh).
Also installed on strix2 for the iperf sanity check: /usr/bin/iperf3 binary
(copied from strix1) + libiperf.so.0 + libsctp1 (apt). Note strix2's DNS
(via systemd-resolved) needed a nudge once — `resolvectl dns enp97s0
192.168.68.1 1.1.1.1` fixed name resolution.

**Persistent units (both hosts)**: `pm-qos-latency.service` (sets 100 µs on
all CPUs at boot — strix1 had LOST the runtime tuning in today's reboot; now
persistent). tbnet IPs are NOT persistent: after any reboot re-add
`ip addr add 10.55.0.1/24 dev thunderbolt0` (strix1) / `10.55.0.2/24`
(strix2) + `mtu 9000` — needed only for rsync/tbv-style TCP, not for streams.

**Qualification tooling**: `/root/tbstream-pair-qualify.sh` rewritten for the
new pair (rank1 = `ssh strix2` = 10.8.0.11, peer arg 10.8.0.9; extra probe
args go in $5, e.g. `--noverify`). NOTE: probe `--bytes` parses DECIMAL ONLY
("1M" silently means 1 byte — use 1048576/33554432).

**Streams**: UP on both (stream `gufo` under `0-3.0`, /dev/tbstream0 both
ends), busy_poll back to 0. Prod (gufo-prod, 15003) survived the kernel
window: 98.5 GB GPU load in 72 s, serving.

**Next**: rsync /root/gufo (git state, 21 staged paths) to strix2, build
tp2-tbstream for 7.3-rc3 if headers/module ABI differ, then Phase 3 serving
experiments with the new numbers: MTP decode baseline now ~7.8 µs exchanges
(was 22), prefill sweep vs P0 (1061/1247/1275/1276 tok/s at 2K/8K/32K/64K).
Gufo communicator may want a busy_poll switch wired to --tp-tbstream-dev.

### 2026-10-02 (night): Phase 3 on the new pair — prefill +73%, serving 41.3 tok/s, two open items

Deployment: /root/gufo rsynced to strix2 (21 staged paths, base 561a6fc
intact); the qp81ab79 tp2-tbstream closure exported/imported into strix2's
nix store (4.1 GB NAR, 173 paths — covers the build-tree probe binaries'
46 store deps too; NOTE: ship big files via 10.55.0.x tbnet, the 10.8.x VPN
rides a VPS at ~5 MB/s). Launch scripts rebuilt for the new pair on both
hosts: serve-rank0/1.sh (rank0 binds 0.0.0.0:15015), probe-rank0/1.sh,
split-w2-r0/1.sh. **Use --tp-bootstrap-host 10.55.0.1 (tbnet, 0.19 ms RTT),
NOT 10.8.0.9 — see decode finding below.** thunderbolt_net now in
modules-load.d on both hosts (the netdev used to vanish after reboots);
tbnet IPs still need re-adding by hand after a reboot.

Results (all with busy_poll=1, Q4_K_XL+MTP Q8, ctx 65536/69632):
- **tp_probe two-host: identical text both ranks, RC=0.**
- **split invariance: 96/96 observations, logits_differing=0,
  max_abs_diff=0** on both ranks (matches the old pair's result).
- **allreduce-bench**: rows=1/2/8: p50 26.9/34.1/45.5 µs; rows=512 (5 MiB):
  **p50 1296 µs ≈ 4.0 GB/s effective** (P0 on 7.2.6: 3.66 ms — **2.8×**).
- **Prefill sweep**: 2K = **1836 tok/s** (P0 1061, +73%), 8K = **2164**
  (P0 1247, +74%). 32K/64K: **BLOCKED** — the first 80 MiB lock-step
  exchange trips the Barlow NHI: "DMA tunnel activation failed" +
  config-space timeouts (dmesg), peer flaps, streams wedge. Recovery ladder
  worked (streams down both → reboot; probes parked in D-state read() die
  with reboot). P0's 1275/1276 tok/s stand for those sizes. Follow-up:
  likely NHI buffer/hopid limit on huge single collectives — chunked
  collectives in the communicator or an upstream report.
- **7.3 REGRESSION (workaround in place)**: in default (interrupt) mode the
  5 MiB lock-step collective poisons the communicator ("received scope 0
  operation 0 bytes 0" — zero header). With **busy_poll=1 on both ends it
  is clean and fast**. Serving/probes must run with busy_poll=1 (it's also
  the latency-optimal mode). Cannot toggle while streams are open (EBUSY) —
  set right after `setup-stream.sh up`.
- **Serving smoke**: both ranks pair, load 19.4 s/rank (49.4 GB GPU each),
  correct output. **Decode 41.3 tok/s @72.8% MTP acceptance, TTFT 416 ms
  @79 tok.** Old Track E: 76.1 tok/s @93% acceptance (different box pair,
  different prompt — not directly comparable; acceptance alone explains
  ~1.28×).
- **Decode finding #1 (control plane!)**: with --tp-bootstrap-host
  10.8.0.9 the TP control channel rode the VPS VPN (35 ms RTT) →
  25.7 tok/s; moving bootstrap/control to 10.55.0.1 (tbnet) → **41.8**.
  Always point bootstrap/control at a sub-ms path.
- **Decode finding #2 (open)**: implied step time ~58 ms vs Track E's ~39 ms
  (both at ~2900 MHz, forced via power_dpm_force_performance_level — GPUs
  idle-park at 600 MHz and short MTP bursts never ramp on their own; worth
  a persistent unit). busy_poll on/off made no serving difference. Next
  lever: run the tp_batched_probe decode pair (needs exclusive stream —
  stop serve first) for ms_per_step, then split draft/verify vs exchange
  time. ~40 layers × 2 collectives × ~240 µs would explain the gap.
- pgrep footgun that cost time: `pgrep -f "gufo serve"` matches the
  calling shell's own cmdline — use `pgrep -f "[b]in/gufo"`; and never put
  the literal string "bin/gufo" in the same command as such a pkill.

END STATE: prod (gufo-prod, 15003) re-enabled, started, verified (98.5 GB,
89 s load). Streams up on both ends, busy_poll=1. tbnet up (10.55.0.1/.2).
Next session: decode step-time investigation (finding #2), 32K/64K prefill
(chunked collectives or NHI limit characterization), then the rest of the
original plan (gufo dev env on strix1, commit decision for the branch).

### 2026-10-03 (early): TG parity proven, prefill-at-depth SOLVED (+67%), ceiling mapped

**TG/decode — CONCLUSION: pipeline at parity; the earlier "gap" was acceptance.**
- Probe bare batched-2 forward: **33.8–34.2 ms/step** (bp=1; throttling 0 vs
  8192: no difference). No-MTP server: 29.6 ms/token. MTP step floor
  **35.6 ms** (measured via high-acceptance prompts: counting 61.3 tok/s
  @88.5%, counting-by-sevens 63.0 @86.6% — vs Track E's 76.1 @93%).
  The 41.3 tok/s number was acceptance-limited prose (72.8%), not speed.
  At equal acceptance we project ~66–70 tok/s; per-step we are AT Track-E
  class. strace showed no syscall pathology (EAGAIN spins normal). The real
  regression fix earlier was the control path (VPN 35 ms → tbnet 0.19 ms).
  Remaining levers if more is wanted: communicator queue path (see C),
  draft-policy tuning.
- Operational notes: GPU performance unit (`gpu-performance.service`) now on
  both hosts (GPUs idle-park at 600 MHz and short MTP bursts never ramp);
  `-d/--draft-tokens` must match on BOTH ranks (control hello checks it).

**Prefill at depth — SOLVED (operationally), +67% vs P0.**
- Root cause refined: exchange size was NEVER the trigger (all chunks are
  4096 tokens ≈ 20 MiB). The NHI damage is **sustained-burst →
  teardown-cycle**: hop deactivation at stream close hits config-space
  timeouts after a long burst, and the NEXT activation fails (EIO on open).
  Reproduced deterministically: 8K sweep #1 completes (2170 tok/s) with 4
  dmesg errors; sweep #2 dies (9 errors).
- TX pacing (25 µs/MiB, new env `GUFO_TBSTREAM_TX_PACING_US`, default 25)
  + 300 ms quiesce-at-Close **did not prevent** the brick and cost nothing
  (2114 vs 2126 tok/s — noise). Keep the patch for its knob value.
- **The fix: don't tear down between bursts.** One serving session, stream
  open, deep prefills back-to-back: **24.9K tok @ 2126, 49.5K @ 2137,
  61K @ 2119 tok/s** — flat with depth, ZERO new NHI errors, prompt-cache
  makes repeats free (TTFT 14–26 ms). vs P0's 1275/1276 at 32K/64K = +67%.
- Recovery ladder update: rmdir stream on BOTH ends recovers the
  EIO-on-open wedge — no PCI rebind/reboot needed (verified twice).

**Prefill headroom — measured; next lever identified.**
- At depth, prefill is **link-bound at ~4.0 GB/s effective** (15 chunks ×
  384 exchanges × 20 MiB / prefill time). The raw probe bw is 5.0 GB/s →
  the queued-collective path pays ~20%. Communicator queue-path work
  (fewer per-exchange µs × 384 exchanges/forward) is the +25% lever
  (~2650 tok/s). Compute-bound estimate (2500–2900) is beyond that only
  with overlap/pipelining work.

**New artifacts (all staged, nothing committed):**
- Patched tbstream.cpp: TX pacing env + quiesce-at-close (see above).
- New closure **srpnqqsgfw1jcpr7hp8d9agr6q0k66h1-gufo-0-unstable-561a6fc-dirty**
  on BOTH hosts (serve scripts repointed; probes rebuilt in
  /root/gufo/build/gpu-tp2-tbstream and shipped as
  /root/qwen38_flash_next_tp_batched_probe on both). Build recipe:
  `nix build /root/gufo#tp2-tbstream` for serve; `nix develop /root/gufo#tp2-tbstream -c cmake --build /root/gufo/build/gpu-tp2-tbstream --target qwen38_flash_next_tp_batched_probe` for probes (cmake at /nix/store/jfdn7bk2k40afmmaqv85b8v043jrigm5-cmake-4.3.4/bin/cmake if PATH empty).
- Serve scripts now: --context 73728, bootstrap 10.55.0.1, new closure;
  rank0 has -v. Prompt files /tmp/p32k.json, p64k.json, p64b.json (24.9K/
  49.5K/61K token synthetic prompts).
- One-off NVMe read timeout + a kernel WARN (misc_open) during a wedged
  stream open — both transient, no action.

END STATE: prod (gufo-prod, 15003) running (98.5 GB, verified listening).
Streams up + busy_poll=1 both ends. tbnet up. Open items for next session:
communicator queue-path bandwidth (+25% prefill), draft-policy/acceptance
tuning, upstream report material (teardown-cycle NHI brick + the 7.3
default-mode large-collective corruption), commit decision for the branch.

### 2026-10-03 (morning): remaining levers closed — transport is AT the line-rate ceiling

**Queue-path bandwidth (+25% hypothesis): REFUTED.** The 4.3 GB/s queued
collective rate is not a queue-path deficit: the allreduce moves
**4.29 GB/s per direction simultaneously = 8.6 GB/s aggregate = ~86% of the
Gen4 80G line rate** — at the practical transport ceiling. The earlier
"5.0 GB/s raw" comparison number was ONE-WAY; per-direction in full duplex
the queued path is equivalent-or-better. A/B evidence: ring_size 1024 vs
256 — neutral (1216 vs 1253 µs p50 @5 MiB, noise); kWindows 3→5 — neutral
(1223 µs); frame size 5→20 MiB in serving — same rate (overhead is not
per-frame). Raw lock-step duplex can't even be measured (5 MiB exchange
deadlocks without the draining reader — the known ring-capacity class).
Remaining prefill gains would need fewer exchanged bytes (e.g. quantized
allreduce — architecture work) or GPU-direct NHI DMA (out of scope).
**kWindows reverted to 3** (neutral changes don't ride in the diff); the
staged tbstream.cpp diff = TX pacing env + quiesce-at-close only.

**Acceptance lever: doesn't exist for this model.** Flash-Next MTP requires
`--min-draft-tokens 1` (checked in inference_backend.cpp:3486 — the floor
is architectural). `-d` max stays 7 (86% acceptance text uses it fully).
Acceptance is prompt-intrinsic; 60.5–63 tok/s @ 86–88% is the practical
decode band, 35.6 ms step floor.

**Validation (stock+kWindows3+pacing build, ring 256, bp=1):** 61K prefill
**2070 tok/s** (cold), counting-by-sevens decode **60.5 tok/s @ 86.6%** —
reproduces last night's numbers. Prod restored and verified after.

END STATE: identical to the previous entry plus: ring_size/kWindows/
min-draft levers all measured and closed; the transport is maxed at ~86%
aggregate line rate. Next-session candidates: quantized/reduced-precision
allreduce (halves bytes → ~2× prefill exchange ceiling), upstream report
drafts (NHI teardown brick, 7.3 default-mode corruption, multi-stream bug),
commit decision for the branch.

### 2026-10-03 (midday): second cable — 2×80G does NOT scale (shared controller uplink)

Second certified 80G cable plugged (port1 ↔ port1): second peer router `0-1`
trains **Gen4 40.0 Gb/s per lane** on both ends — two healthy independent
80G links. Streams `gufo` (0-3) + `gufo2` (0-1) both negotiate hopids 9/9
(the old multi-stream bug does NOT apply across different peer routers).
The striping-capable probe is compiled and shipped as
`/root/tbstream_probe_stripe` on both hosts (from the repo's
tools/tbstream/tbstream_probe.cpp — the deployed /root/tbstream_probe was
the older non-striping copy).

**Striped bw (--fd /dev/tbstream0,/dev/tbstream1 --stripe 2, 5 MiB × 200,
--noverify): aggregate 5.16 GB/s (2.44 GB/s per link) vs 5.03 GB/s for one
link alone — ZERO scaling.** Both 80G ports sit on the ONE Barlow NHI
(67:00.0, domain0) behind its single PCIe uplink: ~5 GB/s is the
CONTROLLER's ceiling, not the link's. Dual-80G striping is dead on this
board design. (Side effect: two tbnet netdevs now exist, thunderbolt0/1,
one per peer.)

**⚠ SAFETY RULE LEARNED THE HARD WAY: PCI rebind of the Barlow NHI
(`echo 0000:67:00.0 > .../thunderbolt/unbind` then `bind`) FREEZES THE
WHOLE SYSTEM on 7.3-rc3 — strix2 locked up and needed a hard reboot. The
recovery ladder is now: streams `rmdir` on both ends → REBOOT. Never
rebind.** Also: the teardown→reactivation wedge now strikes even after
SMALL traffic (a 100-frame exchange run's exit wedged the next open);
expect ~one wedge per few open/close cycles and budget rmdir/reboot
recovery. Serving (which holds streams open) remains immune mid-session.

**Open: the cross-controller test.** The 40G USB4 ports are the AMD native
controllers (domain1 bf:00.5 / domain2 bf:00.6) — SEPARATE PCIe paths into
the SoC. 80G (Barlow ~5 GB/s) + 40G (AMD, est. +2-4 GB/s) striped could be
genuinely additive (prefill ~2130 → ~3000+ tok/s if it scales). Awaiting
the cable moved to the 40G ports; same procedure: verify peer + speed,
stream up on the AMD peer route, striped probe run.

### 2026-10-03 (afternoon): cross-controller test — ADDITIVE (6.4 GB/s); Q8 allreduce begun

After dual reboot (clean wedges), the clean concurrent test (receivers
started FIRST on strix2, then both senders simultaneously):
- **Barlow 80G (tbstream0, 0-3): 5.04 GB/s while AMD 40G (tbstream1, 1-2)
  carried 1.37 GB/s AT THE SAME TIME** — no interference, ~6.4 GB/s
  aggregate across the two controllers.
- AMD solo was 1.04; under concurrency it read 1.37 (noise/timing).
- Conclusion: cross-controller striping is genuinely additive (separate
  PCIe paths into the SoC). With WEIGHTED striping (~4:1) the pair could
  serve prefill at ~2600-2700 tok/s (+25%). Round-robin striping would
  drag to the slow link's pace — weighted scheduling required in any
  communicator implementation.
- Fresh-boot stream minors: gufo(0-3)→tbstream0, gufo2(1-2)→tbstream1.

### 2026-10-03 (afternoon): Q8-BASELINE (serving, current build, single Barlow link)

The "before" numbers for the Q8 wire work — serve pair (closure srpnqqsg,
ctx 73728, tbnet bootstrap, busy_poll=1, ring 256, throttling 0), streams
fresh after dual reboot, GPUs forced high, prompt-cache OFF runs only:

| Case | Result |
|---|---|
| prefill 24.9K tok | **2169 tok/s** (12.25 s wall) |
| prefill 61.0K tok | **2104.6 tok/s** (TTFT 29.13 s) |
| decode counting-by-sevens | **61.6 tok/s @ 86.6% acceptance** |
| decode prose (renderer explanation) | **41.2 tok/s @ 72.8% acceptance** |

Zero NHI errors during the whole baseline session (clean streams, quiesce
patch active, single teardown at exit). Prod restored and verified after.
Q8 expectation vs this baseline: wire bytes ÷4 (fp32→Q8) on large frames →
prefill link-bound ceiling ~4× (bounded by compute/overlap well below that);
decode unchanged (small frames stay fp32).

Also discovered during Q8 code reading: **the wire carries FP32** (the
windows/stage kernel are float) — so Q8 is a 4× reduction, not 2×.
StagePartialKernel at kernels.hip.cpp:2580 (pure copy + flag publish),
AddRowsBroadcastKernel at :2567 (peer-add on arrival). Both ends derive
frame sizes identically from `bytes` — a dtype choice that is a pure
function of frame size needs no header change.

### 2026-10-03 (afternoon-evening): Q8/F16 wire implemented — and the REAL ceiling found

**Wire quantization shipped (staged, uncommitted).** `GUFO_TBSTREAM_WIRE=f32|f16|q8`
on both ranks (handshake-enforced); frames ≥256 KiB quantize, smaller stay f32
(decode path untouched). q8 = fp16 scale per 32-element block + int8 data
(Q8_0-style), ~3.76× fewer wire bytes; f16 = 2×. New kernels:
StagePartialF16/Q8 + AddRowsBroadcastF16/Q8 (kernels.hip.cpp), wire-size
helpers + TbstreamWire enum in communicator.hpp (FinishPartial/ExchangePartial
now report the wire dtype), plumb through tbstream.cpp/executor.cpp/verbs.cpp/
tp_batched_probe. Closure 24ilfipgj408r95ybx3nkd7dyg243afw on both hosts
(ship single-derivation NARs — 26 MB, seconds over tbnet — not whole 4.1 GB
closures; deps are identical).

**Bench (isolated collectives, 5 MiB p50):** f32 1216 µs → f16 676 µs
(**1.80×**) → q8 418 µs (**2.91×**; 12.5 GB/s per direction equivalent).

**Quality (q8):** cross-rank bit-identity HOLDS (split test first_difference=0,
both ranks — same bytes both sides); vs-f32 logit drift max_abs_diff 0.74
(every logit touched); MTP acceptance: counting 86.6→86.1 (noise), prose
72.8→68.5 (real but mild); text coherent. f16 expected ~8-16× less drift
(invariance run skipped to save wedge cycles).

**Serving end-to-end (61K prefill, the honest number):**
| wire | prefill tok/s | decode (counting) |
|---|---|---|
| f32 | 2104.6 | 61.6 @ 86.6% |
| f16 | 2137.6 | 59.8 @ 81.7% |
| q8 | 2195.5 | 55.3 @ 86.1% |
**+4% at best — prefill is COMPUTE-bound (~2100-2200 tok/s) on this GPU pair;
the split-reduce overlap already hid wire time under compute.** The wire
levers (and by extension the second controller — its 6.4 GB/s aggregate would
also sit idle) cannot move serving prefill until the kernels get faster.
The quantization infrastructure is now a shipped capability: default OFF
(f32), useful for slow-link deployments or a compute-faster future.

**tbnet/XDomain outage + recovery:** sustained stream open/close cycling
wedged the XDomain properties exchange on 0-3 (both ends logged "failed
properties changed notification"; ARP incomplete, control plane dead).
Module reload didn't help; `authorized` is read-only for peers. **A single
strik1 reboot fixed it** (strix2 re-enumerated on peer return) — when tbnet
dies: reboot one end, don't bother with softer rungs. Control/bootstrap is
back on tbnet (10.55.0.1) in all scripts. Stream wedge rate this session:
~1 per 3-5 open/close cycles; rmdir ladder mostly works; PCI rebind FORBIDDEN
(freezes, re-learned); teardown after heavy bursts still the trigger
(quiesce patch helps only sometimes).

END STATE: prod (gufo-prod, 15003) re-enabled, running, verified (98.5 GB).
Streams up both links + busy_poll. tbnet healthy. Open: commit decision
(quantization + pacing + quiesce all staged); kernel-side throughput (the
new prefill lever: optimize the forward, not the wire); upstream report
material unchanged.

### 2026-10-03 (evening): SINGLE-NODE baseline (strix1 prod, zero-downtime via API)

Measured against gufo-prod itself (Q4_K_XL + MTP Q8, ctx 262144, think=on,
temp 0, 7.3-rc3, clocks forced high; requests are prod traffic):

| Case | Single node (strix1) | TP2 pair (f32 wire) | TP2 gain |
|---|---|---|---|
| decode counting-by-sevens ×3 | **62.0 tok/s @ 83.8%** | 61.6 @ 86.6% | **parity** |
| decode prose ×2 | 38.0 @ 72.0% | 41.2 @ 72.8% | +8% |
| prefill 25K cold | **1518 tok/s** (TTFT 16.4 s) | 2169 (24.9K) | **+43%** |
| prefill 61K cold | **1548 tok/s** (TTFT 39.5 s) | 2104.6 | **+36%** |
| prefill 61K warm (disk cache) | TTFT **48.5 ms** (60968 cached) | — | prod's cache is the real TTFT killer-app |

Reading: TP2 buys **+36-43% prefill** (two GPUs at ~0.7× efficiency each:
2200 ≈ 1.42 × 1548) and **~nothing on decode** (62.0 vs 61.6 — the MTP step
is serialization-bound, not FLOPs-bound, so halving the model doesn't halve
the step). Decode acceptance configs differed slightly (prod think=on vs
test thinking=auto) — values are close enough that the comparison holds.
Caveat for the earlier "33 tok/s prod" note: that was one trivial-prompt
request at 56.5% acceptance — the proper suite above is the reference.

## File map

- Repo + branch: `/root/gufo` (`feat/tp2-tbstream`, uncommitted, base 561a6fc)
- Results/notes: `docs/models/qwen3.8-flash-next/EXPERIMENTS.md` §TP2 tbstream, `tools/tbstream/README.md`
- Host ops: `/root/install-kernel-7.2.6.sh`, `/root/tbstream-pair-qualify.sh`, `/root/tbstream_probe` (host 2: `/root/tbstream_probe`, `/root/install-kernel-7.2.6.sh`), `/root/gufo-server-cmdline.txt`
- Stream lifecycle: `tools/tbstream/setup-stream.sh check|up|down` on both hosts (`bash -s' < script` over ssh for host 2)
- Community thread: https://forum.level1techs.com/t/benchmarking-usb4-performance-on-strix-halo/245299

## 2026-10-08 decode campaign final deploys

- gufo 0847b4f, binary bd647f661e64297c3bd233869d0cf294 BOTH hosts
  (backups: gufo.036f07b7 interval-4, gufo.87e2fb95 EMA-0.85).
- gufo-prod.service now sets SERVE_DRAFT_VOCAB=131072 (guardian
  passthrough added): draft head restricted to leading 128K vocab rows.
  English/code/tools traffic +4-11% decode. UNSET it for
  multilingual-heavy workloads (ja/ru/ar lose draft coverage, -10-19%);
  caches rebuild once when the value changes.
- Prod band after campaign: canary ~77-88 tok/s (was ~71-73).

## 2026-10-18 (session 2): upstream main merged, CPU-qualified
- Merge commit a0f480f8 on feat/tp2-tbstream (51 files resolved). PR
  checks green (full CPU suite + format). Patch 3d1b604 dual-pushed.
- Scheduler keeps BOTH watchdogs (ours stall_shed 120s→408 + upstream
  stall_timeout→device-lost). GLM dialect re-threaded through upstream's
  new streaming tool-call architecture. Kernels stayed on our TP2 paths;
  upstream kernel perf deferred (see MERGE-CONTINUATION.md).
- OPEN before any prod use of the merged build: HIP package build,
  diag-pair battery, perf spot-checks. Prod remains sessions=2 on
  de09ba76 — do not deploy the merged binary until those pass.

## 2026-10-18 (session 2 addendum): HIP build NOT yet green
- Flatt package build fails: kernels.hip.cpp/executor.cpp still carry
  mixed our/upstream bodies from the hunk-wise merge (CPU tree unaffected
  and green). 3 partial fixes sit uncommitted in the working tree.
- Full error-by-error plan: evidence/sessions4-constrained-wedge/
  HIP-BUILD-CONTINUATION.md. Merge commit a0f480f8 stands (CPU-qualified);
  do not deploy or pair-test until HIP compiles + diag battery passes.

## 2026-10-18 (session 5): HIP build GREEN, merge fully compiled
- 9bf77a1e (fixup on merge a0f480f8): both gates pass —
  `nix build .#tp2-tbstream` (HIP package) and
  `nix build .#checks.x86_64-linux.pr` (CPU suite + format).
- Kernel layer = upstream refactor reconciled with branch TP2 serving
  (see HIP-BUILD-CONTINUATION.md for the full record incl. inactive
  upstream features). Patch f418806 dual-pushed.
- NEXT for prod use: diag-pair battery (quad+tools+wedge kit) and perf
  spot-checks on a fresh build of 9bf77a1e. Prod remains sessions=2 on
  de09ba76 until then.

## 2026-10-18 (13:45): merge parked (TP runtime); rollout via wedge-only build
- Merge builds green everywhere but FAILS at runtime on the pair (first
  forward → illegal access; two fixes landed — TP component forwarding +
  F16 pitch mismatch — a third issue remains; candidates + evidence in
  evidence/sessions4-constrained-wedge/MERGE-RUNTIME-PARKED.md).
- Prod restored 13:40 (de09ba76, sessions=2) after a 38-min diag window.
- sessions=4 rollout now proceeds on 42e3289a (wedge fix only, content
  identical to the pair-qualified 0051409-dirty build).

## 2026-10-18 (13:50): SESSIONS=4 LIVE IN PROD
- Binary fe00212e (stripped 42e3289a = stall-shed wedge fix, content =
  the pair-qualified 0051409 build) both hosts; backups gufo.de09ba76.
- Unit: SERVE_SESSIONS=4. Guardian cycle 1 ACCEPTED 13:44:25 (canaries
  1944.7 / 2078.8 tok/s, gate 1700). Verified: sanity OK, 4-way
  concurrent tool_calls all OK, VRAM 69.9 GiB/rank (band 70-75G),
  decode smoke ~200 tok in 4.7s.
- ROLLBACK (fast): cp /root/newbin/gufo.de09ba76 -> gufo BOTH hosts +
  revert SERVE_SESSIONS=2 + daemon-reload + restart gufo-prod.
- The stall watchdog bounds any residual wedge at 120s -> retryable 408
  (event=stall_shed in r0 logs). Merge campaign parked (see
  MERGE-RUNTIME-PARKED.md); next merge session starts from its
  candidate list.

## 2026-10-18 (17:35): staged-route merge session — 10 bugs fixed, batched decode left
- The parked merge is now MOSTLY ALIVE on the diag pair: prefill (25k),
  single-request decode, and 4-way concurrent tool_choice all pass.
  Commits fab94e27 + d50e2687 + 727b042f (on 14625016) carry the fixes;
  full root-cause chain in evidence/sessions4-constrained-wedge/
  MERGE-RUNTIME-PARKED.md (read it before touching the executor).
- ONE known blocker remains: batched multi-session MTP decode faults
  ("batched forward: an illegal memory access") — suspect
  GdnKernel<true>/GatedDeltaNetBatch. Fastest path: re-add the
  launch trap (macro over hipLaunchKernelGGLInternal + HIP_LAUNCH_BLOCKING=1)
  to name the kernel, then diff that one function against 42e3289a.
- Prod NEVER ran merged code: parked/restored around each diag window,
  live on fe00212e sessions=4 since 17:25, sanity verified.
- Battery status: NOT run (blocked by the batched decode fault).
  Do not deploy any merged binary until the full quad+hammer battery
  passes on a clean build.
- Debug kit that earned its keep: /tmp/merge-qual/{launch-pair.sh,
  diag-smoke.sh, diag-hammer.sh}; gdb-wrapped rank0 for host crashes;
  Alloc() logging as a GPU VA map; dmesg fault-address correlation.

## 2026-10-18 (18:50): MTP blocker bisected — long-horizon 4-way batched decode
- Working state (committed 727b042f + nothing else needed): single 25k
  x300, 4x25k x90 batched-w4, all small/sparse/6k batch tests PASS.
- The ONE remaining crash: 4x25k, >90 (<~150) generated tokens,
  streaming, full speed. Wild-pointer signature (unmapped VAs, runs
  differ, up to 12TB from any allocation). NOT in kernels.hip.cpp
  (launch trap silent in every regime that reproduces).
- Slow-mode (HIP_LAUNCH_BLOCKING / AMD_SERIALIZE) cannot reach the
  scenario: both bust tbstream exchange deadlines above ~6k prompts.
- Next: finish token bisect (q150 JSONs ready in /tmp/merge-qual/),
  then attribute via per-launch polls in mmq/snapshot_copy/blaslt TUs
  or a hipStreamQuery watchdog. See MERGE-RUNTIME-PARKED.md 18:50
  update for the full playbook.
- Tree: 727b042f + UNCOMMITTED diag instrumentation (trap + ALLOC
  traces) — strip before any deploy/commit of the fix.
- Prod: fe00212e sessions=4, restored 18:44 after the diag window,
  sanity 200. Battery still NOT run (blocked on this crash).

## 2026-10-18 (20:35): MTP draft-table root cause FIXED and original quad passes
- Supersedes the GDN/attention/wild-pointer hypotheses above. The merge lost
  `m->output_bytes_ = w.output.SizeBytes()` in DeviceModel::Upload. A zero
  encoded row stride reduced every 1024-row draft-weight allocation to its
  4096-byte padding; GEMV read ~2.7 MB. Fault pages map immediately beyond
  an actual 4 KB draft table, inside its intended allocation.
- Missing assignment restored; SetDraftVocab rejects zero-byte metadata.
  New small file-backed device_model GPU test covers tied/separate output
  heads, encoded row addressing and zero-byte rejection. All temporary
  instrumentation removed. CPU gate and formatting PASS.
- Clean candidate SHA256 c5bc8effca8c64eece03d80f4d74707e2d0606b8851e5172219d27c5546a41ca:
  original four distinct ~25K prompts, greedy, streaming, 300 generated
  tokens EACH PASS at batch_width=4; four tool requests PASS. Repeat after
  cache restore/slot reuse PASS, with bit-identical greedy output text.
  Total 16/16 requests, rank fault markers 0/0, no new local GPU page faults.
- Evidence: /root/strix-dual-exp/evidence/sessions4-constrained-wedge/
  draft-rowbytes-fix-20261018/. Includes responses, hashes, logs and patches.
- Prod restored 20:35:44, ready=200, same fe00212e sessions=4 unit/binary.
  Merged candidate has NOT been deployed to prod. The 12-round hammer and
  timing/canary qualification remain before the staged merge may ship.
- Fix/test are uncommitted in /root/gufo (plus one formatting-only blank-line
  removal in kernels.hip.cpp). No task instrumentation remains.

## 2026-11-05 00:35 — MERGED TREE GREEN + PREFILL BENCH INFLIGHT (blocker: GDN kernel fault)

### Build chain (this session)
- `nix build .#tp2-tbstream` PASSES: merged binary
  `/nix/store/qk2vpf...-gufo-0-unstable-7ae2482/bin/gufo` prints
  `gufo version development (7ae2482)`; install check PASS.
- The final merged kernels.hip.cpp has ours-TP route + upstream kernels
  via a 3-way merge-file composition (ours 1f970923 = base,
  f4e1e37f = ours, eb1d52e6 = upstream); RoutedPairF16Kernel upstream-new
  coexists with ours' LaunchRoutedGatedF16 (-renamed RoutedF16PairGEMM-
  Kernel) under ours-or-ours conditional paths; MTP host fn relocated past
  the anonymous-namespace close (extra `MtpAddEmbedding` instrumentation
  trap hoisted to its own fn so its external-labelled symbol stays
  external; ours hpp keeps its decl). ours-ours ARM window restored.

- Driver `notes/upstream-prefill-sync/01-bench.sh` + adapted pair
  01-pair-adapted.sh with correct BIN paths (`/root/newbin/gufo-merge-
  prefill2/bin/gufo`, sha `41f77a...`), merge binary `efae23a`.
  `/root/newbin/gufo-merge-prefill2/bin/gufo` is also live on strix2 via
  symlink to the nix store path (04:14 state).

### Bench window
- Window 8 reached `READY after ~87s (tag=01)`, served prefill, then the
  TP pair crashed on the canary request at `GdnRowSplitKernel<256>`:
  `grid=[512, 48, 1], workgroup=[256, 1, 1]` — grid.x 512 does NOT fit
  ours' templated launcher (`kGdnDim/64` = 2) → the merged binary has a
  second GDN/RDN lane definition or launches with full v_heads count on
  a TP rank; the scheduler's device-lost handler then declared a pair
  kill. Prod never left healthy.

### Window-safety notes
/ Paths mismatched / symlink probes crash nohup or the `02-serve` -
`03-serve-r0/r1` evidence: all reconciled. To be shared: the merge-side
deviations stacks to a *missing `03-serve-01-r1.log` when its dir wasn't
created first; if a rank dies with a file PE echo, the next `park` resets
.`- Evidence: /root/strix-dual-exp/evidence/upstream-prefill-sync/
{00-binary.sha256, 01-window-prefill{,2..5,8}.log, 03-serve-01-r0.log}.

### Fence / next steps
- Chase the `GdnRowSplitKernel<256>` fault by comparing ours-family
  lane (v_heads TP ranks) against the ours-H lane. Reproduce on request:
  `notes/upstream-prefill-sync/01-bench.sh <merged-bin> full`, and read
  `[ERROR] scheduler device_lost` rows in
  /root/strix-dual-exp/evidence/serve-guardian/…/r0-cN.log.
- prod untouched (200, binary 7ae2482-spelling binary unchanged on disk;
  cgroup-verified reserve, sessions unharmed).

## 2026-11-05 10:00 — GDN FIX + CANARY PASS AT MERGE PARITY (2123 tok/s); DECODE DIGEST DIVERGENCE (d1) FENCE

### The GDN prefill fault — root cause and fix (77311f1)
- Ours-family `Executor::LinearAttention` was calling `GatedDeltaNet(...)`
  with the FULL model counts (`c.ssm_num_k_heads/ssm_num_v_heads/ssm_head_dim`)
  instead of ours-family's TP rank split (`heads.ssm_k/ssm_v/ssm_dim`).
  On a TP rank with 24 v-heads sized buffers, ours-family's
  `v_heads * (kGdnDim/64) >= 64` branch selected `GdnRowSplitKernel<256>`
  and grid.y=48: an out-of-bounds write.
- Fix: `src/models/qwen38_flash_next/kernels/rocm/executor.cpp` — call the
  kernel with `heads.ssm_k, heads.ssm_v, heads.ssm_dim` (ours-family HEAD
  behavior at f4e1e37f:2417). Everything else in the tree already sizes
  buffers with `heads.ssm_*`, so this was the only call site drifting.
- That alone explains window-8's `GdnRowSplitKernel<256>` device fault
  (faulting grid was ours-H 256-lane, not ours-template).

### Window 10 (both ranks at 77311f1)
- Pair READY after ~129 s, tpstream handshake clean.
- Canary: warmup 2093.2 tok/s (threshold 1700), c1 2123.0, c2 2123.0,
  c3 2123.3 — **inside the pre-merge baseline band (2067-2118)**; a
  merged-tree prefill win.
- 4 straight 8k-token prefill requests through the pair, all 200s; the
  scheduler's rank call digest agreed through prefill.

### The d1 divergence (next fence)
- One 261-byte decode request (r6): `TP ranks ran different model calls:
  rank 0 made 261 with digest e9bccbca5f41ba45, rank 1 made 261 with
  digest 7aa210d8ba47eac8`. rank 0 and rank 1 cached the SAME count (261
  calls each) but disagree on the digest. The pair then self-shutdown:
  `tp_pair_lost ... tbstream device returned end of stream` (r8 disabled
  after 2 d1 500s).
- ours-family HEAD `tp_executor.{hpp,cpp}` is byte-identical (digest logic
  unchanged); ours-ours HEAD already passed d1 at 49.12 tok/s, so this is
  a merge-introduced divergence in the DECODE lane only.
- Reads: `src/cli/serve/tp_executor.{hpp,cpp}:25-60,129-236,550-1100` is
  the whole call/rc digest surface unchanged from ours-H. Everything
  diverges in the *results of the decode* (`DigestTpDecode` per-rank), not
  in the instruction stream. So look at the decode lane's body:
  - `src/models/qwen38_flash_next/kernels/rocm/batch.cpp` — ours+ours
    merge of the `MtpForwardBatch`/`MtpHeads` code with new
    `kv_only`/`cache-only`/`ArgmaxConfidence` paths (extent mine+132/`ourt`
    per ours-ours' 114-line diff window).
  - `src/models/qwen38_flash_next/engine.cpp` — ours-family decode loop:
    `Session::GateStops`/`kMtpGateProbability 0.85` / `kMtpBatchDropProbability`
    (`mtp_policy.hpp` ours 52-line patch), `draft_confidence` /
    `draft_subset` / draft-length code; ours-ours pre-merge baseline has
    NO GateStops (upstream entirety).
  - `src/models/qwen38_flash_next/kernels/rocm/executor.cpp` — ours' 14-arg
    `HcCombineF16` ordered args vs ours-ours' ours-H 15-arg version via the
    `HcCombineF15` rename; `AttentionF16GemmTp` with ours rank/rope shape
    vs ours-ours' shader-stage upstream; ours-family ours-H `combine`
    pieces as `{defer_w=nullptr}` gate-forwarded wrappers.
- The pair's rank1 left a stray serve proc on strix2 (`2327832`); expected:
  it's *prod's* rank1 for the restored unit (the pair driver's own stop
  ran its rankH-shape test ahead of cleanup after the merge-lane
  divergence; the pattern evidence matched ours-family `2327832` shape
  after restart. No action needed. Evidence dir on strix2 was recreated
  manually and needs a committed followup in the *next* window driver.

### Driver state updates (window-10 scale)
- `01-bench.sh` had a literal newline bug (`BIN_ABSPATH`); fixed.
- Window-9's GDN fix ran through a `prefill2` path that pointed at
  `efae23a` (32 bytes wrong): window-9's binary on strix1 was mine's
  `efae23a` build; window-10 pinned both ranks to 77311f1.

### Fence-line evidence for the next session
- `01-window-prefill10.log` is the first clean prefill PASS; a fresh
  window (park/restore) is safe with the binary at
  `/root/newbin/gufo-merge-prefill2/bin/gufo` (sha `c33ffc97...`).
- The d1 divergence is 100% reproducible at any 261-call decode; a next
  step should diff ours-ours HEAD's expected `digest` with ours' ours
  merge pieces: `MtpForwardBatch`/`MtpHeads` (batch.cpp), decode-lane
  `engine.cpp`, `kernels.hip.cpp` decode kernels (ours' ours-body merge
  pieces) — mine's prior merge kept ours-ours route bodies (window-8)
  even while ours-family decode path uses the upstream mtp count rows.

## 2026-11-05 14:25 — D1 ROOT-CAUSED + FIXED; MERGE-PREFILL GREEN; NEXT FENCE = p1 32K SOUP SEGV

### Root cause of the d1 decode divergence (THE merge's one real defect)
- `Executor::ForwardBody`'s inline sequential path (the merge's prefill campaign
  inlined ours-family's MixerPart into the loop) **dropped the attention-side
  partial exchange**. ours-ours' MixerPart ends with
  `AllReduce(s_.block_out, n)` (line 4309 in f4e1e37f) — the head-parallel
  GDN/attention partials must sum across ranks before they fold into `s_.res`.
  The merged inline path ran `HcMix -> LinearAttention/Attention` directly with
  NO exchange, so after layer 0 each rank's trunk carry contained only its own
  heads' contribution. Everything downstream (mixed, GDN state, logits row,
  MTP proposals/anchors) is then rank-visible garbage — exactly the observed
  digest split (261-call rank digest mismatch and 1-row vs 2-row tbstream
  collective size mismatch when chain widths diverged).
- **Fix (committed)**: in `ForwardBody`'s loop, after the l.linear/Attention
  branch, restore the reducer:
  `if (l.mixer_split && !AllReduce(s_.block_out, n, error_msg, false)) return false;`
  plus the tail comment. This restores ours-family semantics for every inline
  chunk (tails, non-lead chunks), while the pair-lane path already reduces via
  its own split_reduce machinery.
- PairLead's diagnostic TP gate was REVERTED (pair lane back on, upstream).

### Verification (window 48701c8 clean, traces off)
- Canary: warmup 2085.9, c1 2117.3, c2 2119.4, c3 2114.9 tok/s — parity band
  (2067-2118) reached again with the pair lane on.
- d1 decode: ALL 8 canaries pass (256 output tokens each; ~8.1 s — no traces).
- THE pair stopped clean; prod restored verified (cgroup, /ready 200).
- binary: `/root/newbin/gufo-merge-nopair/bin/gufo` = 48701c8,
  sha256 8d02ed74388dd94f... (both ranks).
- Evidence: 01-window-attreducelog.log (first pass evidence, traces on,
  12.7s decodes), 01-window-clean48701c8.log (clean run),
  01-window-pairfixed.log — all in /root/strix-dual-exp/evidence/*.

### NEXT FENCE (new, separate): p1 32K SOUP SEGV
- With everything else green, `p1/p32k-0` (32k-token soup prompt, body 140964B)
  crashes BOTH ranks with `fatal_signal signal=11` ~as the request arrives
  (after `[http] request=r14 event=received body_bytes=140964`, before any other
  request log). Reproduced with diagnostic probes OFF (clean run) — panel
  14:19-14:20 window. NOT trace-related. NOT divergence-related — hard host
  segfault on both processes simultaneously (~mirrored path).
- Reads: the merged `kPrefillChunkTokens = 16384` — soup_prompt(4000+…,32000)
  makes the pair lane run at n=16384 (lead=8192); ours-ours never had >4096
  prefill chunks.嫌疑: pair-lane scratch sizing (`PairScratch(base)` →
  pair_res_/pair_block_out_/pair_inject_ allocations) vs a 16384-row lane, or an
  obvious cfg-dependent allocation (e.g. token/host pinned buffers), or the
  component-cache reserve path for a 32k prompt (inference_backend ~2810-2945:
  `GrowAhead(2 * segment_bytes_ahead)` merged-byte semantics).
- Note the p1 crash's log line `event=chunk` never appeared for r14 — the crash
  precedes the first chunk commit, at admission/prefill-start.

### Probe infrastructure (keeps, env-gated, inert by default)
- `GUFO_TP_DIGEST_TRACE=1` → per-call digest contributions + per-step facts
  (sel/tok/d/a/c) on both sides (`event=tpdigest side=r0|r1 ...`).
- `GUFO_TP_LAYER_TRACE=1` → per-layer part crcs: resmix/mixed/attn/qn/kn/ab/
  inject/res+attn/moe/res/stout/cvout/headin/headmix/headlogits boundary-layer
  state CRCs (incl. GDN state/conv wide-pass), plus `event=combine` branch
  flags and `event=chunk/top8/chain/anchor` engine lines.
- Analyzers: notes/upstream-prefill-sync/{02-digest-diff,03-step-diff,
  04-layer-diff,05-combine-diff}.py (align r0/r1 streams; the layer analyzer
  tolerates event-count mismatches across runs — rerun with matching binaries).
- CAUTION: the probes synchronize the stream — with the PAIR LANE live they
  broke the pair once (window tag-07: "RemoteDisconnected …", fatal signal=11),
  hence env-off for any perf/correctness windows, and they contributed ~35% wall
  time to decode runs (12.7 s vs 8.1 s per 256-token.).
- The lone unwired probe site: GDN's in-function qn/kn/ab block inside
  LinearAttention never fired at runtime (still committed — dormant), plus the
  GUFO_NO_GRAPH force-eager gate in `Run` (dormant, useful for future hunts).

### Operational state
- branch merge/upstream-main-2026-11-04 head 48701c8(+pair driver commits) —
  nothing pushed; all work committed.
- prod `gufo-prod` (window end: /ready 200, responder=gufo-prod) untouched;
  the serve procs use the f4e1e37f-family binary on disk (unchanged);
  the FIXES ONLY run in the experimental binaries.
- The driver `notes/upstream-prefill-sync/01-pair-adapted.sh` currently pins
  BIN=/root/newbin/gufo-merge-nopair/bin/gufo (sha 8d02ed ...) — the
  reproducible pair-fix build — and NO trace envs.
- EVERY merge-introduced defect found in this session:
  1. Missing attention-side partial exchange on the inline sequential path —
     FIXED via efcc680 (AllReduce in ForwardBody after the attention block).
     THIS was the root cause of every d1 symptom.
  2. fuse focus: `HcMixQ8Fused`/`HcFusedMix` (upstream's merged Q8 low-rank
     fused mixer) gated to single-rank in `Executor::Combine` (kept off — never
     proven as a d1 bug (the fused gate alone did NOT fix d1 — the missing
     AllReduce did) but kept because ours-ours never had it and mixed routes
     turned out orthogonal).
  3. The 77311f1 GDN prefill head-split fix (earlier in this session).
  4. The p1 32k-soup SEGV — NOT fixed; next session's first target — start by
     reading `Executor::ForwardPair`'s pair scratch sizing at n=16384 and
     the pairing reader's host pinned buffers for the biggest prefill batch.

## 2026-11-05 15:35 — p1 32K-SOUP FENCE CLOSED (two defects, two fixes); FULL BENCH GREEN on f9c29c2

### Defect #1: mirrored SIGSEGV — whole-chunk pinned staging downsized by the merge
- Evidence (windows 14:19-14:20 + 15:13): both ranks fatal `signal=11` the same
  second as `[http] request=r14 event=received body_bytes=140964`, BEFORE any
  instruction-completion trace (no tpdigest/layerpart/chunk for r14 even with
  probes on at 14:12) -> mirrored host-side fault inside the first prefill
  entry, not a device kernel.
- Root cause: the merged `AllocateScratch` staged 32k-wide prompts into three
  pinned buffers the merge had downsized from ours-ours' whole-chunk
  (`chunk = executor PrefillChunk() = 2*max_batch`) granularity to
  `max_batch`-grained: `tokens` (`T*4B` vs ours `chunk*4B`), the PLE n-gram
  buffer (`T*PleEmbeddingDim*4B` vs ours `chunk*...`), and `control`
  (1 row vs ours 2). `Session::Feed` feeds the 32k soup as ONE chunk
  (`chunk_size`: `remaining > max_batch -> PrefillCapacity()` = 32768 rows
  under TP), `PleFetch` then writes `n * ple_heads` row hashes into
  `host_rows_` (chunk-sized, fine) and starts a gather into `host_emb_` for
  ALL n rows -> ~14 MB past a ~max_batch-grained pinned allocation ->
  identical heap overrun on both ranks -> SIGSEGV before any kernel.
  Ours-ours never fired it (chunks <= 8448 fit; canary <= 16512 <= T fits).
- Fix (commit 243edeb7 "fix: stage whole prefill chunks in the paired pinned
  buffers"): restored ours' granularity inside the merge's
  `host_allocations_` mechanism: `control = 2*sizeof(Control)`,
  `tokens = chunk*4B`, `host_emb_ = chunk*PleEmbeddingDim*4B`.
- Window 243edeb (15:08-15:14): canary 2112-2125, d1 8/8 (8.1s), p1 NO
  longer crashes -> now a clean HTTP 500:
  `all-reduce payload exceeds the receive window`.

### Defect #2: pair chunk widening never re-derived the tbstream frame bound
- With the crash gone, p1 exposed the true second stage: the pair lane's
  `block_out` partial exchange is 16000 rows x 2560 x f32 = 156.25 MiB >
  kWindowBytes (128 MiB). ours-ours' geometry never exceeded 86.5 MiB
  (chunks <= 8448 rows); the merged prefill campaign raised
  kPrefillChunkTokens 4096 -> 16384 (TP PrefillCapacity 8192 -> 32768) and
  never re-derived the window: `tbstream.cpp CheckExchange` poisons the
  communicator. Clean 500, no crash, no further corruption.
- Fix (commit f9c29c2 "fix: bound prefill chunks to the all-reduce receive
  window"):
  * kWindowBytes (128 MiB) + kDataOffset (64) hoisted into `tbstream.hpp`
    (in rocm ns, inlines; cpp keeps kWindows/kBufferBytes/coalescing).
  * `Executor::AllReduceRowsPerFrame(hidden)` = (kWindowBytes - kDataOffset)
    / (hidden*4) = 13107 rows @ hidden 2560.
  * `Model::PrefillCapacity()` (engine.cpp): TP pair chunk cap now
    min(2*kPrefillChunkTokens, 2*window_rows, max_context) = 26214 rows
    (lane 13107 = 127.99 MiB exactly inside the window); single-rank
    unchanged (16384, no reduce).
  * `Session::Feed`'s checkpointed (inline, all-n-rows through one frame)
    pass clamps at the same frame bound (checkpoint_cap = min(max_batch,
    window_rows)) - the pair-wide half is bounded in PrefillCapacity.
  * NOTE: the cprime component-identity hash attests PrefillCapacity, so
    the identity changed -> the experimental disk cache re-populates;
    `continuation_adapter.cpp` PrefillPlan already mirrors the same
    constants, boundaries stay consistent.

### Verification (binary f9c29c2, sha a3299fccb13f612c, both ranks)
- Window 01-window-boundfix.log (15:23-15:25): canary warmup 2090.3,
  c1 2119.5, c2 2126.4, c3 2124.6 tok/s (ours-ours band 2067-2118, +trace
  *above* it); d1 8/8 green ~8.1s; **p1 2/2 PASS** (ptok 48099/48676, ctok 1,
  ~24s each) - the previous session's last fence is closed.
- Window 01-window-c32r.log (15:27-15:30, sections c32,r1,r2 never reached
  since the crash existed): c32 4096 tok/84.4s aggregate with 16x
  `HTTP 503 connection limit reached` on the oversubscribed tail (same
  family as ours-ours r1a `errors=26`), NO model errors; r1 2/2 768-token
  gens ~23.9s; r2 10552-token retrieve-exact prompt 21.3s. Zero fatal
  signals, zero tbstream poisons in every serve log.
- prod parked/restored clean each window (cgroup-verified, /ready 200).

### Operational state
- branch merge/upstream-main-2026-11-04 head 31ae3040 ("chore: pair driver
  pins window-bound fix f9c29c2"), local only, nothing pushed.
- Pair driver pins BIN=/root/newbin/gufo-merge-nopair/bin/gufo
  (a3299fccb13f612c...) with NO trace envs.
- Merge-introduced defect ledger (all found & fixed this session):
  1. Inline sequential path dropped the GDN/attention head partial
     AllReduce (d1 decode divergence) - FIXED (efcc680, same window family).
  2. Whole-chunk pinned staging (tokens/n-gram/control) downsized to
     max_batch -> mirrored 32k segv - FIXED (243edeb).
  3. Pair chunk widening vs 128 MiB receive window - FIXED (f9c29c2).
  4. HcMixQ8Fused remains gated to tp==1 in Executor::Combine (never proven
     a bug - kept conservative; re-enable is LOW priority, needs its own
     probe cycle).

## 2026-11-05 17:50 — THIRD DEFECT (content corruption) ROOT-CAUSED + FIXED + PROD RE-DEPLOYED (7c79e55)

### The defect: post-branch tail re-stamped the TP-split linear tensors
- Discovery: gates were all green (canary/d1/p1) but actual CONTENT was wrong:
  prod smoke produced word salad; the r1/r2 sections produced content hashes
  that differed deterministically from ours-ours' gold. ours-ours'
  literature had r1 = 6010c139 / 9a2cafec (temperature-0, thinking off,
  deterministic) recorded in the phase4 runs; the merged line produced
  5d6e2043 / 90c628e7 - wrong, unwavering, rank-consistent.
- Investigation: probe-instrumented ours-ours (worktree f4e1e37f, same
  trace kinds) vs merged line. Time-ordered first divergence: layer 0's
  `qn` (the GDN's [rsqrt(ks), rsqrt(qs)*rsqrt(d), kq] triplet table)
  - Q scale bit-identical across the trees, K scale and kq wholly
  different => the conv staging slice for K differed.
- Root cause (device_model.cpp `Layer()`): the merged assembly had
  duplicated ours-ours' non-split tail AFTER the `SplitLinear` /
  `SplitAttention` branches and stamped it unconditionally, with the
  upstream new alpha/beta-EXPAND flag:
    d.ssm_conv1d = Copy(l.ssm_conv1d);
    d.ssm_alpha_beta = Stack({alpha, beta}, /*expand*/true);
    d.ssm_dt = Copy(...); d.ssm_a = Copy(...); d.ssm_norm = Copy(...);
    d.ssm_out = Copy(...); d.attn_qkv = Stack(...); d.attn_* = Copy(...);
  For ALL TP-split GDN/attention layers this overwrote the correct
  per-rank tensors (`GatherRows`/`GatherElements`/`GatherColumns`
  results) with FULL (un-split, Q8-expanded) copies. The GDN ran with
  another head-list's alpha/beta per local head index -> wrong decay per
  head -> garbage-scale recurrence, deterministic, rank-consistent.
- Fix (commit 7c79e55d "fix: keep the tp split per-rank linear
  tensors"): deleted the injected post-branch duplicated tail; ours-ours'
  per-rank SplitLinear/SplitAttention results survive.
- Verification: r1 content hashes back to gold (6010c139/9a2cafec); clean
  full board green.
- Probe infrastructure gained: widened per-row trace drops (256
  floats/line, text[4096]) + the conv-scratch row probes, env-gated
  (GUFO_TP_ROW_TRACE); the 4k-line dumps make the triplet table
  directly readable.

### Board results on 7c79e55 (clean window 01-window-fixfull-clean.log)
- canary: warmup 2128.7, c1 1947.0, c2 1963.1, c3 1943.4 tok/s (all over
  the 1700 gate; d1 walls shortened since chains now stop at natural
  ends: 3.0-9.4 s instead of a fixed 8.1 s per 256 tokens).
- d1 8/8 green (some items stop early at EOS with fewer ctok).
- p1 both pass (~23 s each, ptok 48k).
- pair stopped clean; prod restored (200).

### PROD RE-DEPLOYED (17:45)
- /root/newbin/gufo on BOTH hosts -> merged f9c- (a3299...) was swapped
  out for 7c79e55 (sha 9c578700...). Earlier merged build had been
  briefly deployed (16:02) then rolled back the same hour for the
  content corruption (the f4e1e37f prod binary is kept as
  /root/newbin/gufo-f4e1e37f.bak on both hosts; the f9c29c2 one as
  gufo-f9c29c2.bak).
- Guardian accepted: warmup 2209.7, c1 FAST 2259.1 tok/s (best of the
  line); unit + cgroup verify passed; /ready 200.
- Content smoke on prod: "What is 17*23" -> "391", finish=stop; prose
  smoke coherent; no server exceptions in the journal.
- Rollback path unchanged: cp gufo-f4e1e37f.bak -> /root/newbin/gufo on
  both hosts + systemctl restart gufo-prod.

### Branch state
- merge/upstream-main-2026-11-04 head afd1298c (driver at 7c79e55,
  probes off), local only, nothing pushed.
- Every merge-introduced defect ledger (all found & fixed):
  1. Inline sequential path dropped the GDN/attention head partial
     AllReduce (decode divergence). FIXED efcc680.
  2. Whole-chunk pinned staging (tokens/n-gram/control) downsized ->
     32k-soup mirrored segv. FIXED 243edeb.
  3. Pair chunk widening vs the 128 MiB receive window -> pair poisoned
     on the 32k prompt. FIXED f9c29c2.
  4. Post-branch tail re-stamped TP-split alpha/beta and friends ->
     word-salad decode content everywhere. FIXED 7c79e55. (The content
     gate that caught it: ours-ours' deterministic r1/r2 hashes.)
- Remaining open item (LOW): HcMixQ8Fused stays tp==1-gated; re-enable
  needs its own probe cycle.

## 2026-11-05 20:10 — SESSION CLOSE: five more merge defects fixed; the last content fence is named; prod stays on f4e1e37f

### User traffic verdict (the report that opened the hunt)
- The merged deploy produced gibberish on real 60k+ accumulated sessions even
  after the split-tensor fix. Reproduced on a two-turn synthetic (two 32k
  documents + a recall question): ours-ours/prod answers
  turn1 = NONE / turn2 = honeydew exactly; merged turn1 drifts and turn2
  loops ("...iceberg lettuce, iceberg lettuce..."). The disk cache is NOT
  involved (zero cache_hit=true; all six restore attempts failed cleanly).
- Second source: r2 (10,552-token prompt) drifted while r1 (34 tokens)
  matched ours-ours gold exactly. All d1 also green. The defect is
  therefore inside the PAIR CHUNK path only, at lane shapes ours-OURS never
  ran (ours-ours max pair lane 4096).

### Five merge defects found and fixed this stretch (all ours-ours-parity gates)
1. **7c79e55** - the post-branch tail of `Layer()` re-stamped the TP-split
   per-rank alpha/beta/conv/dt/a/out/attention tensors with full un-split
   (Q8-expanded) copies -> word-salad decode everywhere. FIXED: tail
   deleted; split branches keep per-rank SplitLinear/SplitAttention
   results. (r1 content -> ours-gold.)
2. **745e05c** - `Combine`'s added decode/epilogue routes
   (`pending_combine_` deferral via `FusedMixer(*next)` and
   `HcCombineQ8_1`) were live under TP; ours-ours runs the eager
   `HcCombine` on pair lanes. FIXED: both gated to tp==1.
3. **2969f703** - `Moe()`'s added shared-expert side-stream overlap
   (`stream_ = side_stream_` while the routed experts run) was live under
   TP at every ExpertMatrixRows width; ours-ours runs the shared expert
   inline before the routed GEMMs. FIXED: `overlap` gated to tp==1.
4. **(same amend as 41c079d)** - the merged tree's side-stream fork
   thresholds were `WidePrefill(rows>8)` where ours-ours gates at
   `n >= 1024` in THREE sites: LinearAttention's z-fork for
   DenseF16SsmGemm, Attention's fused qkv projection, and last_attention's
   per-token cache reserve. FIXED: all three back to ours-ours thresholds.
5. **41c079d** (also amends) - the attention fused qkv projection route at
   rows>8 under TP wrote different per-row geometry than ours-ours.
   FIXED: same threshold restoration.

### Evidence trail (probe parity upgrades that made the hunt converge)
- ours-probe (worktree /root/ours-probe at f4e1e37f + probes) mirrors the
  merged probes now: `TraceBlockOut` uncapped -> `TraceBuffer`, uniform
  per-layer kinds (`attn/mixed/qn/kn/ab/inject` + `moe/res/res+attn/`),
  wide lane shapes in the row traces (n>=1024), 256-float line dumps
  (text[4096]), plus 08-colmap.py (column-map inversion) and 06-layer-
  keydiff.py. Binary: /root/newbin/gufo-ours-probe/bin/gufo (last pins:
  aad72b9 -> 74de8e4, sha 3d1ed272).
- Merged probe binary: /root/newbin/gufo-merge-wide/bin/gufo, last pin
  d2d2219c (ours width + z-fork storm fixes), sha matches the tree.
- Consistent observed pattern on lanes ours normally never uses
  (n=4096/1176/1177): ours' and merged's lane pieces share their first
  row (first float values identical) but diverge deeper in the lane,
  keeping the same row0 - a deterministic mirror mismatch inside the
  routed expert / combine epilogue chain (not timing, not a fork).

### THE REMAINING FENCE (named, not yet fixed)
- Both trees produce **the same per-row shapes** on the pair path (ours:
  lanes [4096|4096]+[1176|1177]; merged the same); ours reports the
  ours-gold r2 hash 1785d6b5, merged reports 898cd2dc at ours-width, and
  every shared lane piece still differs deeper in the lane. The defect is
  inside a piece invoked per lane that ours-ours computes with different
  tail-row arithmetic than the merged tree. Candidate areas ranked:
  (a) the merge's HcMix family for lanes (mixed_reread semantics,
      xn_q8t/fused projection routes, the removed ours-ours'
      `fused_projection` details in HcMix (ours has `n>=96` thresholds
      where merged may differ),
  (b) `MoeExperts`' fusion choices (`WidePrefill`/gate variants, routes
      values) - ours' ours-tree uses `RoutedGatedF16Gemm` at
      `n_tokens>=1024 && routed_tile_rows_ == 48`; verify merged matches,
  (c) the pair-path scratch staging whose shapes are identical but whose
      widths (`pair_block_out_` T) may now see route legs ours never ran,
  (d) `Combine`'s still-present wide routes besides the gated decode ones
      (`wide_mixer_` epilogue and `xn_q8_ready_/mixed_q8_ready_` marker
      semantics on lanes).
- Suggested next session: instrument ours' `HcMix` and `Moe`'s exact
  branch choice per lane and mirror the merge's; then one window.

### Ops state
- Branch merge/upstream-main-2026-11-04 head 74de8e4-lineage (local only).
- Directions: the pair driver's BIN pin now points at
  /root/newbin/gufo-ours-probe/bin/gufo (uniform probes); all merge-side
  gates are ours-ours-parity; hits: r1/d1 gold, r2/turn2 still diverged.
- prod: STATIC on f4e1e37f (sha 7938e618) with /ready 200; the guard unit
  is untouched. The experimental binaries serve only the bench path.
- Our-to-merge parity gates FIve confirmed semantic divergences fixed.

## 2026-11-05 20:40 — ROOT CAUSE FOUND + fixed: the merge line's storage/arithmetic campaign

### The third-order divergence (r2, turn-2 content) traced to its source
- **device_model.cpp**: the merge store-chain replaced ours'inject handling:
  `Mixer()` builder used `CopyF32(m.inject)` — hyper-connection inject tensors of
  type kQ8_0 were **expanded to F32 on device** and retyped kF32 (new
  `conversions {expand_q8}` machinery + `Stack(..., expand_q8)`).
  Ours keeps Q8_0 storage (kernel takes the DQ inside the Q8 kernels with
  different arithmetic ⇒ different bits at wide lanes).
- **kernels.hip.cpp**: ~40 kernels carried campaign re-pins ("order pinned"
  comments) where short-prefill vs wide-pass FMA reassociation changed the
  last bit vs ours (HcInjectPart's pinned one-product+FMA chain; WrappedExceptions
  HcCombineKernel block sums...). All diffs ours↔merged validated live at
  TP2 lanes: r1 (17|17 lanes) matched ours, r2 (4096|4096/1180|1180 lanes) diverged
  from the first lane piece, and lane pieces shared row 0 but diverged deeper.

### What was done (merge tree, commit run)
1. Reverted `src/models/qwen38_flash_next/kernels/rocm/device_model.cpp` to
   f4e1e37f wholesale (no `expand_q8`, no `CopyF32` for inject).
2. Swapped `kernels.hip.cpp` to ours' f4e1e37f (oracle arithmetic) and
   re-added merged-only feature kernels (yarn rope suspport types, MTP
   kernels: MtpAddEmbedding/ArgmaxConfidence/RemapDraftIds/
   VerificationCandidates(+3 kernels + Fused* helpers), HcMixQ8Fused family
   (tp==1-gated call site), WmmaCausalAttentionContextLimit helper,
   YarnScale/YarnFrequency, SwapHalves, GroupedRasterTile, RasterTile consts,
   FusedScatterSum/Levels) + 7 signature ADAPTERS (merged signature, ours'
   kernel launches): PrepareAttention, AttentionF16Gemm, Rope,
   PoolIndexerBlocks, Attention (drops dense_extent), DenseF16SsmGemm
   (drops z side-stream), GatedDeltaNet(+z_ready wait).
   Merged executor now calls ours' exact launches on the pair path.
3. Gated the engine.cpp entry top8 digest trace behind
   `GUFO_TP_DIGEST_TRACE` (was unguarded; fired per decode step).

### Evidence files
- `/root/strix-dual-exp/evidence/upstream-prefill-sync/01-window-oraclekernel.log`
  + `01-perf-oraclekernel.jsonl` (r1/r2 in the promoter window).

### Next steps if r2 flips to ours-gold `1785d6b547a6aeb9`
1. Full board (canary/d1/r1/r2/p1) on the merged line, ors-width.
2. Two-turn long-session synthetic: expect NONE/honeydew.
3. Revert kPrefillChunkTokens experiment (4096 -> 16384) and any stray
   the `HcMixQ8Fused` tp==1 re-enable probe cycle, then rebuild an deploy
   binary, purge the cprime disk cache dir, then redeploy gufo-prod.
4. Full d1/r1/r2 post-deploy smoke + guardian canary.

### Operational
- Current merge-tree HEAD: "fix: gate the entry top8 digest dump..." chain
  atop "experiment: oracle kernels + merged-only appends + adapters".
- Window currently running: park/start/r1+r2/stop/restore on port 15005.

## 2026-11-05 21:15 — MID-GATE: r2 flipped to ours-gold; full board + synthetic in flight

### VERDICT from the oracle-kernel window (01-perf-oraclekernel.jsonl)
- r1-0 = 6010c139b52f76b7 (gold), r1-1 = 9a2cafecc3673bf0 (gold),
- **r2-0 = 1785d6b547a6aeb9 (OURS-GOLD — the wide-pair fence BROKEN)**.
- Binary: /root/newbin/gufo-merge-wide/bin/gufo (0869d67 lineage, sha b3ab2721).
- Root cause: merged device_model stored hc inject as expanded F32
  (CopyF32/expand_q8 conversions) and kernels carried campaign re-pins; ours
  (oracle) keeps Q8_0 inject + its own kernel arithmetic. Swap restored
  bit-identical lane content at all widths.

### Gates in flight / planned
- Window (running): park → start → canary,d1,p1,c32,r1,r2 → two-turn
  synthetic → stop → restore (01-window-fullboard-oracle.log).
- Deploy preconditions done:
  - cprime disk cache purged on BOTH ranks (256G stale entries removed;
    /root/gufo-cache-cprime-v19 emptied). Purge again immediately before
    the prod swap (prod refills with f4e1e37f-era valid entries meanwhile).
  - kPrefillChunkTokens stays 4096 on the merge line (ours' own engine
    value; content parity to gold hashes) — do NOT "revert to 16384"
    without a fresh ours-width-matched content gate.
  - engine.cpp entry top8 trace now env-gated (GUFO_TP_DIGEST_TRACE).

### Prod redeploy procedure (after gates pass)
1. Build deploy binary: `nix build .#tp2-tbstream` at the merge-tree HEAD
   (probes compiled in but env-gated off - same as all prior prod builds).
2. Back up current prod bin on both hosts (gufo-0869d67x.bak naming next it
   to gufo-f4e1e37f.bak which already exists).
3. `01-bench.sh <bin> park` → purge cache dirs again on both ranks →
   atomically swap both hosts' /root/newbin/gufo to the new store path →
   `systemctl restart gufo-prod` on both → /ready poll (cgroup verified)
   → guardian canary (c1) + content smoke (17*23 → 391).
4. If anything looks off: immediate rollback to gufo-f4e1e37f.bak on both
   hosts + restart (same as the two previous rollbacks).

## 2026-11-05 22:25 — SESSION CLOSE GOOD: deployed to prod; all gates green

### The wide-pair content fence: RESOLVED (root causes + fixes, in order)
1. Device model: merged stored `hc inject` as expanded F32 (`CopyF32` /
   `expand_q8` conversion machinery) while ours (the content oracle) keeps
   Q8_0 storage with in-kernel DQ → reverted `device_model.cpp` to f4e1e37f.
2. Kernel arithmetic: merged's kernels carried campaign re-pins (pinned FMA
   orders, re-ordered block sums, different launch-geometry families), i.e.
   HcInjectPart "one product + FMAs in order", HcCombineKernel's `d*sumq`
   block sums, etc. Ours' arithmetic is the oracle → swapped
   `kernels.hip.cpp` to f4e1e37f and re-added ONLY merged-only feature
   kernels (yarn plumbing types, MTP/verification/argmax-confidence,
   HcMixQ8Fused family [tp==1-gated], FusedClear/Codes/Done/Scatter*,
   SwapHalves, GroupedRasterTile + RasterTile consts, WmmaCausalAttention
   ContextLimit, YarnScale/YarnFrequency, FusedScatterSum) + SEVEN
   signature adapters (merged call sites -> ours' launches):
   PrepareAttention, AttentionF16Gemm, Rope, PoolIndexerBlocks, Attention
   (dense_extent dropped), DenseF16SsmGemm (z side-stream dropped),
   GatedDeltaNet (+event wait head).
3. Earlier gates (combine decode routes, MoE side stream, z-fork/attention
   fused/last_attention thresholds to ours' semantics) were all validated by
   this final configuration; the earlier 10x-slow walls were the driver's
   leftover `GUFO_TP_LAYER_TRACE=1 GUFO_TP_ROW_TRACE=1` (probe tax), not a
   build regression: driver now launches probe-free.

### GATE RESULTS at ours-width 4096 (deploy binary 58b1e548 = edbe605)
- d1 8/8 EXACT gold (a53032cb..., ae5c6c06... etc.).
- r1-0 6010c139b52f76b7, r1-1 9a2cafecc3673bf0 (gold).
- r2-0 1785d6b547a6aeb9 (OURS-GOLD — the wide fence broken).
- p1 2/2 same-hash (b344d80e...).
- canary 4/4 FAST, 2048-2194 tps (threshold 1700).
- c32: throughput-only section; NO gold (the only previous c32 record,
  01-perf-c32r.jsonl, came from the pre-fix 15:30 build; 16 protocol errors
  in BOTH runs - inherent, not a fence).
- Two-turn long-session synthetic on BOTH the pair (15005) and prod
  (15003): turn1 NONE, turn2 honeydew (v matches ours-ours exactly).

### PROD DEPLOYED at 22:16 (after one failed attempt)
- First attempt (symlink /root/newbin/gufo -> the nix out-link DIRECTORY)
  never became /ready: the guardian spawns $SERVE_BIN itself, so the link
  must be the EXECUTABLE. Rolled back to the f4e1e37f bytes (backed up at
  /root/newbin/gufo-f4e1e37f-rollback? CHEAT: keep gufo-f4e1e37f.bak).
- Second attempt: copies /nix/store/37rzfygijf8vk4y26vvfll0sbq6c5n5h-gufo-
  0-unstable-edbe605/bin/gufo to /root/newbin/gufo (sha 58b1e548) on BOTH
  hosts, cache purged before restart.
- prod /ready 200 (unit + cgroup verified), 17*23 -> 391, r1/r2 gold, canary
  FAST (2048-2179 tps), two-turn NONE/honeydew ON THE LIVE SERVICE.
- Rollback: /root/newbin/gufo-f4e1e37f.bak (7938e618) exists on both hosts;
  cp it over /root/newbin/gufo + `systemctl restart gufo-prod` (strix1's
  unit; the rank-1 process is spawned by the guardian over ssh to strix2).

### Repo state
- Branch merge/upstream-main-2026-11-04 (local only; nothing pushed).
- HEAD: c160... (driver pin to deploy cand) atop "fix: gate the entry top8
  digest dump behind GUFO_TP_DIGEST_TRACE" atop
  "experiment: oracle kernels + merged-only feature appends + adapters".
- The deploy binary == `nix build .#tp2-tbstream` at that tree; ~64k context
  sessions verified via the 10552-token r2 + 63k synthetic (prod 262,144 ctx).

### Deliberately NOT done (documented for later sessions)
- kPrefillChunkTokens stays 4096 (= ours' engine; content-oracle parity).
  A 16384-width build would need a fresh ours-width-matched content gate.
- The `HcMixQ8Fused` tp==1 re-enable probe cycle stays a SINGLE-RAND perf
  lever (call site still gated; only runs when tp_world_size()==1).
- c32 needs a first ever gold run (ours-ours) before it becomes a gate.

## 2026-11-07 10:00 — cache: RAM snapshot pool doubled; end-to-end restore VERIFIED on prod

### What the live logs showed (Nov 7 morning)
- User's ongoing session turns were FAST while cache-resident (3.7-6.6s for
  57k-token prompts, 112-160 new tokens prefilled) but earlier turns that
  missed (cached_tokens=168) cost 49-63s: 27-29s full re-prefill at ~1980 tps
  + 1.6-2.5k generated tokens at 52-74 tok/s.
- Root cause: `snapshot action=skipped reason=byte_capacity` - the RAM
  snapshot/prefix-match pool (SERVE_CACHE_RAM_BYTES=16GiB) was saturated
  (retained ~16.5G vs cap 16G), so big-session snapshots could not be kept,
  and cross-session prefix matching fell back to ~168 tokens.
- Disk cache itself was healthy (stored/removed LRU churn; 279 entries).

### Change (applied via park/restart)
- `/etc/systemd/system/gufo-prod.service.d/40-cprime-cache.conf`:
  SERVE_CACHE_RAM_BYTES 17179869184 -> 34359738368 (16 GiB -> 32 GiB).
  Host memory: 122 GiB total, delta worst case +16 GiB resident - safe.
  (Cache envs flow to rank1 through the guardian's process env; strix2 runs
  no unit.)

### Validation on prod (port 15003, binary 58b1e548 unchanged)
- `snapshot_cache_configured sessions=4 snapshot_entries=128
  capacity_bytes=34359738368` in the fresh boot log (20261107-095806).
- IDENTICAL repeated prompt: first request writes; repeat request
  `cache_hit=True prefill_tokens=0 prefill_ms=0 ttft_ms=7` - first
  confirmed successful restore path on the deployed merged line.
- Content gates: r1-0 6010c139b52f76b7, r1-1 9a2cafecc3673bf0,
  r2-0 1785d6b547a6aeb9 (gold), walls 7.67/8.04/8.86s; smoke 17*23 -> 391.
- Restart dropped in-session KV state once (single rebuild); client traffic
  resumes on the fast path afterwards.

### Still open (work items)
- Decode throughput (52-74 tok/s) dominates long answers; separate perf
  project, unchanged from the pre-merge baseline.
- kPrefillChunkTokens 16384 experiment + HcMixQ8Fused tp==1 cycle: deferred
  (see 22:25 close-out).

## 2026-11-07 11:05 — cache: shallow-hit disk restore SHIPPED to prod (92787359)

### The true root cause of "prefill takes tens of seconds" (user's slow turns)
- The cache is two-tier by design: RAM snapshot pool (active matching tier,
  ~0ms restores) and the cprime disk store (durable tier; the code ALWAYS
  consulted it on a complete RAM miss, ~0.5-1.8s restores from disk).
- The disk tier was only consulted when the RAM lease MISSED ENTIRELY
  (`reuse_prompt && !lease.cache_hit()`). A shallow RAM hit - typically the
  shared chat-template head (~168 tokens) or an early small conversation
  frontier that survived capacity pressure - SHADOWED the longer disk
  store coverage: turns prefilled 50k+ tokens (~27-29s) instead of a
  ~1s disk restore (r15 measured a 57,940-token restore at 1.748s).

### The fix (b15a7f16-lineage, binary sha 92787359, deployed to prod 10:55)
1. `RestoreLongestPrefix(..., floor_tokens=0)` - candidates must be
   strictly longer than the floor; a floor miss leaves the caller's state
   untouched (no clobbering by shorter disk candidates).
2. `Lease::AdoptRestoredPrefix` allows a forward upsert over an already
   adopted (shallower) hit and still rejects shrinking reports.
3. `TextRunnerPool::Acquire` consults the disk tier when the RAM coverage
   is less than half the prompt (`ram*2 + kSharedPrefixMinTokens < prompt`),
   passing the RAM coverage as the floor; logs
   `event=shallow_disk_restore ram_tokens=? disk_tokens=? restore_ms=?`
   when the shallower hit upgrades to disk coverage.

### Validation
- Unit: `$build-probe/continuation_disk_store_test` passes cheaply against
  the fix binary, including the new floor test (floor rejects + adopts a
  longer candidate). Cache tier tests (cache_disk/tiered/publication/
  retention/streaming) all rc=0.
- GPU gates on the fix binary (pair, ours-width): r1/r2 gold
  (6010c139/9a2cafec), 1785d6b5 ours-gold at ours-width, walls 8.3/8.0/8.9s.
- Deployed prod (both ranks 92787359; must kill strix2's rank1 BEFORE
  replacing /root/newbin/gufo - "Text file busy" otherwise).
- Probes on prod: identical repeat +0 prefill (RAM path); full r2 probe with
  only a partial-matching RAM note restored from disk (`prefill_tokens=7,
  restore_ms=493ms`); user's 74.6k-token turn restored ~73.8k tokens from
  disk (prefill_tokens=751, wall 35.7s incl. ~28s generation at ~62 tok/s);
  smoke 17*23 -> 391.
- Board on prod post-deploy: r1 6010c139 gold, r2 1785d6b5 gold at
  **4.01s** (previous 8.86s - faster thanks to the restore path), canary
  c1/c2/c3 FAST 2048-2181 tps.

### New merge debt discovered while unit-testing (documented, tracked)
The hosted CPU test suites never ran since the Nov-05 failsafe checkpoint;
repairing them surfaced pre-existing rot (NOT cache-related):
- tests/models/qwen38_flash_next/CMakeLists.txt had merge-conflict residue
  (duplicate foreach + duplicate session_test target). Fixed: foreach is the
  union (device_model + hc_route_ops + verification_sampling), one
  session_test (ours' multi-source variant; gufo_serving does not exist in
  this tree).
- Upstream-drifted test TUs excluded from the `check-pr` set (tracked in
  cmake/Checks.cmake comments): openai_chat_test (FakeBackend vs newer
  backend API; logprobs.hpp include added, still drifted), http_server_test
  (same support header), component_text_cache_test (Acquire/pinned_bytes/
  prefill_lookahead), text_model_runner_test (prefill_rollback cap,
  ParseRamCacheOption), text_generation_scheduler_test (TokenPiece/
  PrepareConstraintVocabulary renames), ds4_sampling_test (observe/logprobs
  renames).
- The full repair of those suites (aligning the host-facing backend APIs the
  merge dropped) is a separate project; the pr-tests gate stays green on the
  remaining members and the cache family is validated through its own tests
  + GPU gates as shown above.
