signed against dd6796e7b3e87bde1a798dda913cccc07d493d86

# s136-grok — spec 136 v0.1

Read the spec at `1cd100d91` (2026-10-13T09:52:47Z). That commit contains `2e21b62db` and the spec's measurement `4b1f43b4b`. `git diff --stat 4b1f43b4b..1cd100d91` on the code files cited below printed nothing. `git diff --stat 1cd100d91..dd6796e7b -- csi-spl-doc/specs/136-spool-encrypted-at-rest/spec.md` also printed nothing, so this sign is current origin/master and the spec bytes are the ones read. The two commits after the read (`f8a5bd91e`, `dd6796e7b`) do not touch those code files. Votes in section 12 are votes. The owner decides.

## 0. The owner's words — AGREE

The five quotes in the file and the R1-R5 lines match each other. I did not re-fetch the topic.

## 1. Measured today — CHANGE

D5 and S1 are right. D3 is a real third copy, and the sentence that says every DM is copied is wider than the code. Two clear-text landings are missing from the tables.

**D5, right.** `sed -n '287,307p' csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go` shows `Filename` building the slug from `strings.ToLower(m.Body)` and cutting it at 32 (`msg.go:295-298`). The spec's range `286-295` stops before the cut. Cite `287-307`.

**S1, right.** `sed -n '290,295p' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh` cuts the body to `${SPOOL_NOTIFY_BODY_MAX:-600}` (line 291) and puts it in the poke line (line 294).

**D3, the copy is real and conditional.** `bridgeFleet` (`spool.go:286-310`) marshals the message and `writeFileAtomic`s it mode `0o664`. It is called from `deliverTo` (`spool.go:268,275`), not from `write` (`spool.go:203-207`). It returns without writing when `FleetRoot` is empty, when `id != m.To`, when the sender is not an agent, when `FleetRoot` and `SpoolRoot` are the same path (`spool.go:288-290`), or when `<FleetRoot>/<id>/inbox` is not already a directory (`spool.go:292-294`). `grep -n FLEET_ROOT csi-spl-orc/src/bash/run/spl-local-hub-agent-join.func.sh` prints nothing. The join calls `do_spl_desk_up` at line 88. `spl-desk-up.func.sh:348` defaults the fleet root to `SPL_WS_SPOOL_ROOT` or `/var/spool-hub`, and line 356 sets `SPOOL_ROOT` to the seat spool, a different directory. The third copy happens for a hub delivery when that agent's fleet inbox already exists. It is not every DM, and a same-spool `Send` never calls it.

Replace the bold paragraph under the D-table with:

> **D3 is a third clear copy on the hub deliver path only.** `bridgeFleet` (`spool.go:286-310`) runs from `deliverTo` (`spool.go:268,275`), not from `write` (`spool.go:203-207`). It writes nothing when `FleetRoot` is empty, when `id != m.To`, when the sender is not an agent, when `FleetRoot` and `SpoolRoot` are the same path (`spool.go:288-290`), or when `<FleetRoot>/<id>/inbox` is not already a directory (`spool.go:292-294`). A local-hub seat reaches `do_spl_desk_up` from `spl-local-hub-agent-join.func.sh:88` with no `SPOOL_FLEET_ROOT` in that file, so `spl-desk-up.func.sh:348` defaults the fleet root to `SPL_WS_SPOOL_ROOT` or `/var/spool-hub`, which is not the seat spool set at line 356. The copy then happens only if that agent's fleet inbox directory already exists.

Add these rows. P10 and P11 are files on disk. P12 is argv, the same class as P9.

| # | path:line | what lands in clear |
|---|---|---|
| P10 | `orc/run/spl-agent-handoff.func.sh:59-66,202-218,241-245` | `<root>/<id>/handoff.md` and `handoff.prev.md`. Section 4 is a pane capture. Section 6 is the first line of each unanswered blocker or msg, 120 characters. Live: `find /var/spool-hub -maxdepth 2 -name handoff.md -printf '%m\n' \| sort \| uniq -c` -> 20 files, mode 660. P4's handover brief cats this file (`spl-lane-handover.func.sh:297`). The standing file is its own copy. |
| P11 | `orc/run/spl-watchdog.func.sh:132,824,843,887-888`; `orc/run/spl-dispatch-lease.func.sh:98,1390-1416` | Up to 400 lines of `~/.claude/projects/<slug>/*.jsonl` written to `<root>/dispatch/wd/ctx/<id>/transcript`. Line 843 also writes the pane input box to `$ctx/input`. Live: `find /var/spool-hub/dispatch/wd -name transcript -printf '%m %s\n'` -> n=1857, mode 660, 1213 non-empty, 978699721 bytes. `stat` of `dispatch/wd` and `dispatch/wd/ctx` -> `drwxrws---` group `spool-agents`. P3 names only the pane file at line 828. |
| P12 | `sa/scripts/spool-send.sh:305,324,337` | The normal send, the peers relay args and the cross-machine relay args pass `--body "$BODY"` on argv. S8 (lines 176-180) is the hub-down file write, a different path: `sed -n '176,180p'` shows jq writing the body into `peers/inbox`. |

Add a reader row. These print an excerpt and do not write a body file:

| # | path:line | what |
|---|---|---|
| W7 | `sa/scripts/agent-inbox.sh:66`; `orc/run/spl-desk-reply.func.sh:387,430`; `sa/scripts/kill-your-self-report.sh:150-151` | stdout excerpts of 120, 80 and 60 characters, and the exit gate's jq of `.body[0:120]`. The gate does not store the excerpt. A `v:3` file has no `body`, so an ACCEPTED that lives only in `ct` does not satisfy it. |

`grep -rnE 'filippo\|ReadPassword\|x/term' --include='*.go' csi-spl-api/src/go/spool-hub-api` prints nothing. `go.mod` line 21 is `golang.org/x/crypto`; `password.go:11` imports `argon2`. That part of the header is right. I did not re-count the 24 h message volume.

## 2. The rules — CHANGE

Rules 1-4 and 6-8 match R1-R5. Rule 5 does not hold on the one-OS-user shape.

Replace rule 5 with:

> 5. **Decrypt in memory, for a caller of the workspace OS user who names an identity in `for`.** Only `spool recv --encrypted`, `spool tail --encrypted` and their MCP equivalents decrypt; they print to stdout and write nothing back to disk. On the one-OS-user-per-workspace shape (Q3 A), keyd sees one uid for every agent of that workspace, so `--as <id>` is a name the caller picks. A sibling agent of that user can ask keyd to open any message whose `for` holds an identity of the workspace. Section 9 states that. This spec does not claim per-agent secrecy under Q3 A.

## 3. Data — AGREE

`v:3` with `body` absent, `Parse`'s `DisallowUnknownFields` (`msg.go:172`), the file name without a slug, and the `encrypted/` dirs match section 1 and R3. The channel fan-out (one seal per member, that member plus the owner) does not contradict the DM example in 3.1, which is one ciphertext with sender, recipient and owner. Q6 B is the same object with the owner left out of `for` (section 4).

## 4. The key model — CHANGE

Age inside the Go binary, no gpg-agent, keyd, unlock on `/dev/tty`, and sealing from recipients only, match R1. The backup keygen already refuses a non-tty and wraps an age identity (`orc/run/spl-local-hub-backup-keygen.func.sh:3-31`). Two sentences are missing.

Add at the end of section 4:

> **Same uid.** The socket check is the workspace OS user's uid. It cannot tell two agents of that user apart. keyd opens for the `<id>` the caller names. Per-agent secrecy is Q3 B.
>
> **The owner in `for` is Q6 A.** Q6 B is the same `v:3` object with the owner omitted from `for`. The format does not grow a second version for that answer.

`mlock` and `PR_SET_DUMPABLE` need `golang.org/x/sys/unix`. `grep -n 'golang.org/x/sys' csi-spl-api/src/go/spool-hub-api/go.mod` -> line 84, `// indirect`. `grep -rn 'golang.org/x/sys' --include='*.go'` in that module prints nothing. Promoting it edits `go.mod` and `go.sum` (section 11).

## 5. The passphrase rule — CHANGE

R1 is tty, no echo, never from a post, the WUI, a message, an env var, argv, a file or a pipe. Refusing the process when a passphrase env is set is the right control. The glob is wider than R1.

Replace "when an env var `SPOOL_KEY_*` or `*PASSPHRASE*` is set" with:

> when `SPOOL_KEY_PASSPHRASE`, `PASSPHRASE` or `AGE_PASSPHRASE` is set (those names, not every variable whose name contains `PASSPHRASE`)

## 6. Dedicated agents — AGREE

One OS user `spw-<first 8 hex>`, never the workspace name, not in `spool-agents`, home 0700, is the wall between workspaces. The fleet ceiling stays 40. `WS_AGENT_MAX` default 4 is a cap. The sibling-agent hole is section 9, not a reason to rewrite section 6.

## 7. Performance — AGREE

The bar is a benchmark at the stated sizes with n >= 1000, and a recv measurement with n >= 100. I did not run one. The section does not claim a measured ns/op yet.

## 8. Migration and rollback — AGREE

Flag default false, seal-then-delete, no code path that writes cleartext back into the plain dirs, and the ext4 remnant stated in section 9. The side copies are listed for the owner, not silently deleted. That matches what section 1 can actually find.

## 9. Honest limits — CHANGE

Root and sudo are stated correctly, and they are not theoretical. `sudo -n -l` for each of the two OS users agents run as includes `(ALL) NOPASSWD: ALL` (n=2). `mlock` and `PR_SET_DUMPABLE=0` do not stop that. The vendor, the clear envelope, the hub process, the ext4 remnant and the off-box owner identity are the right limits.

Add:

> **A sibling agent of the workspace OS user** can open any sealed message of that workspace. It is the uid keyd trusts, and it can pass `--as`. This is the Q3 A tradeoff. It is not a root-only limit.
>
> **The watchdog copy (P11)** puts up to 400 lines of the CLI transcript under `<root>/dispatch/wd/ctx/<id>/transcript`, mode 660, group `spool-agents`. Measured 2026-10-13T09:52:47Z at `1cd100d91`: n=1857 files, 1213 non-empty, 978699721 bytes. A 0700 home does not cover that copy. **handoff.md (P10)** is the same class: 20 files, mode 660, group-readable, holding a pane capture and 120 characters of body.

## 10. Functional requirements — CHANGE

Add to FR7: "no `--body` argv (P9, P12) and no `handoff.md` / `handoff.prev.md` excerpt (P10)".

Add to FR8: "no `$ctx/transcript` and no `$ctx/input` (P11)".

Add:

> FR13 | the exit gate accepts an ACCEPTED that is sealed in `ct`, and does not require a clear `body` | bash test (L5)

## 11. Build split — CHANGE

The paths named in the table do not overlap. A count of the `` `path` `` mentions in section 11: 33 mentions, 33 unique, 0 duplicates. The holes are files the table does not name, and `go.mod`.

**L1 / L2 share `go.mod`.** L1 lists `api/go.mod` and `api/go.sum` for `filippo.io/age` and `golang.org/x/term`. L2's `mlock` promotes `golang.org/x/sys` (section 4). One lane edits those two files.

Replace the L1 files cell with:

> new `api/internal/enc/`; `api/internal/msg/msg.go`; `api/go.mod` and `api/go.sum` (`filippo.io/age`, `golang.org/x/term`, and `golang.org/x/sys` promoted to a direct require). L2 does not edit `go.mod` or `go.sum`.

**L7 is too big for one small task.** It names 12 files, mixing pane captures with retire and rebox. Split:

- L7a, captures: `spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh` (P11's transcript and input, not only the pane). Test FR8. Needs L6b.
- L7b, copies: `spl-lane-handover.func.sh`, `spl-desk-rebox.func.sh`, `spawn-remote.sh`, `agent-id-retire.sh`, `desk-seat-drop.sh`, and `orc/run/spl-agent-handoff.func.sh` (P10). Test FR8 for the handoff file. Needs L6b. The mode-644 brief fix (P5) stays here and can still land on its own.

**Files in section 1 with no lane:**

| file | why it is in the spec | put it on |
|---|---|---|
| `orc/run/spl-desk-post.func.sh` | P9 argv | L5 |
| `sa/scripts/spool-fleet-relay.sh` | P9 argv (`:125`) | L5 |
| `sa/scripts/kill-your-self-report.sh` | W7, FR13 | L5 |
| `orc/run/spl-peer-poll.func.sh` | W2 | L8's file list, or the gate never sees it |
| `orc/scripts/spl-desk-reply.sh`, `orc/run/spl-desk-reply.func.sh` | W4, W7 | L5 |
| `sa/scripts/agent-mirror-check.py` | W6 (the sibling of `spool-mirror.py`, which L5 already has) | L5 |
| `orc/run/spl-unanswered-sweep.func.sh:454` | W5 writes `left(l.body, 400)` for a human or guest sender into `$LEASE_DIR/unanswered.rows` | a new L11, cache writers |
| `orc/run/spl-msg-dedup.func.sh:111,125` | the DUP line prints 60 characters of `body` | L11 |

L8 as written is a gate that readers skip `encrypted/`. It does not stop W5 from copying a body out of the hub DB into a clear file. That is rule 3.

**L5's live proof needs L3.** The order runs L5 after L1, and the live grep is "the L3 proof also greps". Unit tests need L1. The live proof needs L3. Set L5's needs to `L1` for the tests and say the live grep runs after L3.

**L6a must name files.** The settings store is `api/internal/store/tenant_kv.go` (line 18, `tenants.settings`) and `api/internal/hub/tenant_settings.go`, plus the next free `rdb/` migration. Pin and roster are not one file. Name them in v1.0 before that lane starts, and do not reuse a file L1-L5 lists.

**L6b must name the launcher.** `grep -rn SPAWN_WORKSPACE csi-spl-orc --include='*.sh'` prints nothing: the flag is new. The starter to edit is `sa/scripts/spawn-window.sh`. Restore scripts that exec an agent are not in the table; name them or the proof `ps -o user=` misses a restore.

## 12. Owner questions — votes, not decisions

| Q | vote | why |
|---|---|---|
| Q1 | A | Age in the Go binary matches the backup keygen and adds no agent socket. gpg-agent would be a second place a passphrase sits. |
| Q2 | A | Under Q3 A the agents share a uid, so N passphrases are typing, not a wall. If the owner picks Q3 B, this vote flips. |
| Q3 | A | R5's must is one workspace per agent. "Ideally its own OS user" is Q3 B and costs one vendor login per agent. A walls workspaces. It does not wall sibling agents; section 9 has to say so. |
| Q4 | A | Both agent OS users have `(ALL) NOPASSWD: ALL` (section 9). With sudo, keyd's uid check is not a wall. |
| Q5 | A | The vendor still receives the body, and P11 already copies the transcript into the shared spool. An encrypted home covers neither. B is a later spec. |
| Q6 | A | Dropping a rotated agent identity loses that agent's mail if the owner is not in `for`. The envelope already shows from and to (R2). |
| Q7 | A | An unattended key file is a passphrase that did not come from the owner's tty. That is R1. |

## 13. Panel — AGREE

This file is the grok seat. v1.0 still needs the editor and one more claude, and the owner's answers to Q1-Q7. Section 11's lanes should not start on the Q3 A shape while section 9 still reads as if only root can open another agent's mail.

## Close

The line `Closes: SPL-1662` in `841f2bb28` is above a blank line, so git reads only the two release-note lines as trailers. This commit puts that line in the trailer block.
