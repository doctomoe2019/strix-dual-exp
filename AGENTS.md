# AGENTS.md — git and publication policy for this repository

Read this before committing or pushing anything in any repository on these
hosts. It binds every agent session working on the strix-dual-exp /
gufo / kernel trees.

## Ownership and visibility

The **GitHub repository is public** (`doctomoe2019/strix-dual-exp`);
everything else about this work stays private: the private-server origin
(recorded in each host's local git config), the machines, the evidence
trees and the operational handover. The gufo upstream
(github.com/neuhaus/gufo) and the Linux kernel sources are **read-only
upstreams** we build on; we never publish to them.

## Repositories and remotes

| Tree | Remote(s) | Role |
| --- | --- | --- |
| `/root/strix-dual-exp` (this repo) | `origin`: the private git server (upstream of record, endpoint in local git config only — never write it into tracked files) **and** the public GitHub mirror `git@github.com:doctomoe2019/strix-dual-exp.git` | Experiment repo: docs, kernel patches, gufo WIP patch. A single `git push` updates both destinations. |
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
   hostnames, private-infrastructure addresses (VPN/LAN/tbnet IPs of OUR
   deployment — RFC1918 example values in documentation are fine), real
   machine identifiers (UUIDs/MACs), credentials or private keys. Real
   per-site values (hostnames, tbnet subnet) live in `scripts/env.sh`
   (gitignored; tracked scripts read them with neutral defaults — see
   `scripts/env.sh.example`). `evidence/` and `scripts/env.sh` are
   gitignored precisely to keep raw logs and site config local; scan the
   gufo WIP patch after regenerating it (generic doc placeholders like
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
  `/root/HANDOVER-TBSTREAM.md` (a local file — never publish it).
