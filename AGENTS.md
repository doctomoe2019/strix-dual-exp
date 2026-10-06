# AGENTS.md — git and publication policy for this repository

Read this before committing or pushing anything in any repository on these
hosts. It binds every agent session working on the strix-dual-exp /
gufo / kernel trees.

## Ownership and visibility

All of this work is **private**. It lives in doctomoe's own repositories
only. The gufo upstream (github.com/neuhaus/gufo) and the Linux kernel
sources are **read-only upstreams** we build on; we never publish to them.

## Repositories and remotes

| Tree | Remote(s) | Role |
| --- | --- | --- |
| `/root/strix-dual-exp` (this repo) | `origin` fetch: `git@github.com:doctomoe2019/strix-dual-exp.git` (upstream, private server); `origin` push URLs: the private server **and** `git@github.com:doctomoe2019/strix-dual-exp.git` (GitHub mirror) | Experiment repo: docs, evidence index, kernel patches, gufo WIP patch. A single `git push` updates both destinations; the private server is the upstream of record, GitHub is the mirror. |
| `/root/gufo` (branch `feat/tp2-tbstream`) | `origin` = `https://github.com/neuhaus/gufo` — **NEVER PUSH. No credentials exist by design.** | Gufo work stays on the local branch. It is shared only as the sanitized patch `gufo/0001-feat-tp2-tbstream-wip.patch` in this repo (diff vs the `feat/tp2-rdma` base `2833856`), regenerated after every gufo commit. |
| Kernel trees (`kernel/build-tree`, `/root/kernel-src-7.3rc3`) | none | Local build trees only; their divergence is expressed as patches under `kernel/patches/`. Never push to any Linux upstream. |

## Push policy

1. **Never push to the upstream gufo or kernel repositories** (or any
   remote other than the two strix-dual-exp destinations above) **unless
   the user explicitly asks for that exact push in that session.**
   If the user asks to "push", that means this repo's dual-push origin.
2. `git push` in this repo must update both the private server and the
   GitHub mirror. If one side rejects, fix or report it — never leave the
   two destinations diverging silently.
3. **Secret scan before every push:** tracked content must contain no
   hostnames, LAN/VPN/tbnet IPs (`192.168.`, `10.8.0.`, `10.55.`),
   link-local IPv6, UUIDs or MAC addresses. `evidence/` and
   `scripts/env.sh` are gitignored precisely to keep raw logs local; scan
   the gufo WIP patch after regenerating it (generic doc placeholders like
   `boltctl authorize <uuid>` are fine).

## Commit policy

- Conventional Commits, single-line messages; match the existing log style
  of the repository being committed to.
- Commit identity in both repos: `doctomoe <doctomoe@localhost>`
  (set repo-locally; do not touch global config).
- Commit only when the user asks (gufo) or to close out a completed
  experiment phase with its records (this repo). Never commit secrets,
  raw evidence logs, or probe binaries.
- After any gufo commit: regenerate `gufo/0001-feat-tp2-tbstream-wip.patch`
  (`git -C /root/gufo diff 2833856874ee75bde8252b6a7f6b9ae0b00a3012..HEAD`),
  secret-scan it, commit the regenerated patch here, then push.
- The deployed serve binaries (`/root/newbin/gufo`) and the frozen kernel
  are operational state, not git content; their hashes are recorded in
  `/root/HANDOVER-TBSTREAM.md`.
