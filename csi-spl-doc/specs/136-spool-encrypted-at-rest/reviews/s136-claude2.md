signed against 1cd100d91358c351abb4ab4e1864985d5e1c8466

# 136 review, seat s136-claude2 (c-402)

Read: `spec.md` v0.1 (2e21b62db lineage) as it stands at the sha above, and
the owner's words it quotes (3cfe43ce, 0f7b0d3d, 9a0a1732, 7559efa5,
e6cdd9f3). Every claim about a file below carries the command that showed
it. Paths use the spec's abbreviations (`api/`, `orc/`, `sa/`).

Verdict: **AGREE with the design, with 6 CHANGEs**; two of them (C2 the
shared tmux server, C3 the header not bound to the ciphertext) are holes in
the wall the spec promises, and I would not sign v1.0 without them.

## Section 0 (owner's words, R1-R5): AGREE

R1-R5 follow the quotes. R3 ("encrypted" dirs) correctly retires the stub of
0f7b0d3d.

## Section 1 (measured today): CHANGE (two rows added)

Checked rows, each AGREE:

- **D3** holds. `sed -n 286,310p api/internal/spool/spool.go` -> `bridgeFleet`
  writes `msg.Marshal(m)` into `<FleetRoot>/<id>/inbox` with
  `writeFileAtomic(..., 0o664)`, skipped only when the fleet root equals the
  spool root. And `grep -n FLEET_ROOT orc/run/spl-local-hub-agent-join.func.sh`
  -> no match, so the default of `spl-desk-up.func.sh:348` applies. D3 is the
  first leak to close for the private workspace, as the spec says.
- **D5** holds. `sed -n 286,300p api/internal/msg/msg.go` ->
  `slug := slugRe.ReplaceAllString(strings.ToLower(m.Body), "-")`, cut to 32.
- **S1** holds. `sed -n 284,298p sa/lib/spool-notify.inc.sh` ->
  `body="$(spool_notify_cut "$body" "${SPOOL_NOTIFY_BODY_MAX:-600}")"` inside
  the poke line.
- Desk sidecar log: no body. `grep -rnE 'log\.Printf|Logf' --include=*.go
  api/internal/hubclient | grep -v _test | grep -iE 'body|excerpt|snippet'`
  -> no match. Section 1 is right to leave it out.

Missed, add to 1.4:

| # | path:line | what |
|---|---|---|
| P10 | the box's sudo log (journald) | every `sudo -u <user> ... --body "<text>"` is logged with its full command line, persistently. Measured: `sudo journalctl _COMM=sudo --since -6h \| grep -c -- '--body'` -> 156 entries in 6 h, the first an agent running `spool-fleet-relay.sh` with its body; `ls -ld /var/log/journal` -> `drwxr-sr-x+ root systemd-journal`, ACL `group:adm:r-x`. P9 is the same argv, but P9 lasts while the process runs; P10 lasts until journal rotation. |
| P11 | the fleet's tmux server | a body on an agent's screen is readable by anyone who can reach the tmux server socket the pane lives on: `tmux capture-pane -p -t <pane>`, with no code of ours involved. `ls -ld /tmp/tmux-1000` -> `drwx------ <owner user>`: today every agent that can become that user reads every pane. P1-P3 list only our own captures; this is the general case. |

## Section 2 (rules): CHANGE rule 3, exact new text

> 3. **Ciphertext on disk, always.** A message of an `enc` workspace is
>    written only under `encrypted/`, sealed (section 3). No code path writes
>    its body, a slug of it, or a capture of a screen showing it, to any file
>    in clear (rows D1..D8, S1..S9, P1..P11), and no code path passes an
>    `enc` body as argv (P9, P10): a body goes on stdin or in a 0600 file of
>    the workspace user, removed after use.

Rules 1, 2, 4-8: AGREE.

## Section 3 (data): CHANGE (C3, C4)

**C3, the header is not bound to the ciphertext.** age authenticates `ct`
but knows nothing of the clear header. `Canonical`
(`sed -n 118,132p api/internal/msg/msg.go`) signs the whole object, but the
local spool is unsigned (every seed: "UNSIGNED locally"), so a file whose
`from`, `to`, `task_id` or `msg_id` was rewritten next to a valid `ct` opens
cleanly and is shown under the wrong header, and a `ct` copied under another
`msg_id` replays. New text for the `ct` bullet of 3.1:

> - `ct`: the age ciphertext of the inner JSON
>   `{"msg_id":"…","task_id":"…","ts":"…","from":"…","to":"…","kind":"…","body":"…","files":[…]}`.
>   On open, `spool` compares the six header fields with the inner copy and
>   refuses the message (exit 6, `HEADER MISMATCH <msg_id>`) on any
>   difference; it prints the inner values, never the outer ones. Attachment
>   metadata goes inside; the outer `files` stays empty.

**C4, who seals.** Section 9 says the hub handles bodies in clear, and 3.2
puts D6 (`.hub/pending`) under `encrypted/`, so the body reaches the hub in
clear and is sealed on the seat. Section 4 then publishes every recipient to
the hub "so every seat can seal to every member", which implies the SENDER
seals the delivered copy. Both cannot be the design. New paragraph at the
end of 3.3:

> **Where sealing happens.** The sending seat seals its outbox copy (for the
> sender and the owner) and its pending wire copy (D6). The hub carries the
> clear body to the receiving seat (section 9), whose sidecar seals the
> delivered copy for the addressed agent and the owner before the first
> write. A seat therefore needs only its own agents' recipients and the
> owner's; publishing every member's recipient on the hub is for an end to
> end follow-up, not for this spec.

(If the editor prefers sender-side sealing of the delivery, the hub stores
`ct` and section 9's hub bullet changes instead; either works, one must be
chosen.)

## Section 4 (key model): CHANGE (C1, C5)

Against the owner's rules it holds: age in Go keeps R1 (no gpg-agent
pinentry on some other tty), keyd keeps R1 (agents never type), the owner
key in every `for` answers recovery, one OS user per workspace is R5's
"ideally its own OS user". Two corrections:

**C5, the migration check cannot use the owner key.** Section 4 moves the
owner's secret OFF the box; section 8.3 then "checks that each opens with
the owner key" on the box. It cannot. New text for 8.3:

> 3. **Existing clear mail**: `do_spl_ws_enc_migrate` seals every clear file
>    of that workspace's seats and of `/var/spool-hub/<its agents>/` into
>    `encrypted/`, opens each sealed file through keyd with the addressed
>    agent's identity and compares it byte for byte with the clear file,
>    checks that the owner's recipient is among the file's age stanzas,
>    deletes the clear file, and lists for the owner the side copies of
>    1.3/1.4 it found. Deletion on ext4 is not erasure (journal, free
>    blocks): stated in section 9, not hidden.

**C1, keyd does not separate agents of one workspace.** keyd checks
`SO_PEERCRED` uid = the workspace user, and every agent of the workspace is
that user (6.1, Q3 A). `--as <id>` is self-declared, so any agent of the
workspace can ask keyd to open any other member's mail. With Q2 A and Q3 A
the per-agent identities buy rotation and revocation, not a wall. That is
acceptable (R5 walls workspaces, not agents), but it must be written. Add to
section 9:

> - **Inside one workspace** every agent runs as the same OS user, so keyd
>   cannot tell them apart: any agent of the workspace can open any other
>   member's mail. Per-agent identities give rotation and revocation, not
>   isolation; isolation between agents needs per-agent OS users (Q3 B).

### What root / sudo still reads: CHANGE section 9's first bullet (C6)

Section 9 is honest but understates who is root today. Measured:
`id <agent user>` -> groups include the owner user's group, `docker` and
`spool-agents`; `sudo grep -rhvE '^\s*(#|$)' /etc/sudoers.d` -> both agent
OS users carry `ALL=(ALL) NOPASSWD: ALL`. So every agent of the fleet is
root without a password, and `docker` membership is root by itself
(`docker run -v /:/h`). New first bullet:

> - **Root and every sudoer on the box**, which today is every agent of the
>   fleet (both agent OS users have `NOPASSWD: ALL`, and both are in the
>   `docker` group, which is root by itself), can become the workspace user
>   and read keyd's memory (`/proc/<pid>/mem`, ptrace) while it is unlocked,
>   the agent's process memory, its tmux server and scrollback, its
>   transcript and the journal (P10). `mlock` and `PR_SET_DUMPABLE=0` stop
>   swap and core dumps, not root. Against the agents of OTHER workspaces
>   this spec therefore protects only once those agents lose sudo and
>   `docker` too: Q4 is a box-wide change, not a per-workspace one.

## Section 5 (passphrase): AGREE

Measured nothing encrypts today: `grep -rnE 'filippo|ReadPassword|x/term'
--include=*.go api` -> none, as the spec says. One note for L2: the unlock
runs as the workspace user, so the owner types it through
`sudo -u spw-<id8>` on a tty; the journal then records the command (P10),
never the passphrase. FR5's controls should include "under sudo with no
tty -> refused".

## Section 6 (agents dedicated to a workspace): CHANGE (C2)

**C2, the workspace's own tmux server.** 6.2 says the launcher starts a lane
"in a tmux window the owner still reaches with tmux". If that window is on
the fleet's tmux server (the one the global count command reads), the pane's
process runs as `spw-…`, but the screen sits in the fleet server, and every
fleet agent can `capture-pane` a decrypted body off it (P11). New text for
the first bullet of 6.2:

> - The workspace's dispatcher and its lanes are agents of that workspace,
>   running as its OS user, **in the workspace user's own tmux server**
>   (socket under its 0700 home). The fleet orchestrator places a lane with
>   `SPAWN_WORKSPACE=<ws id>` (never the name); the owner reaches the
>   workspace's windows with `sudo -u spw-<id8> tmux -S <socket> attach`.
>   No pane of an `enc` workspace runs on the fleet's tmux server, and the
>   fleet's watchdogs and rotations (P1-P3) never reach it.

And in 6.3, add: "the 40-window count adds each workspace server's
`list-windows -a`; L6b extends the count command."

## Section 7 (performance): AGREE

The 1.1 volume (1924/day, p99 3631 B) makes the cost negligible; the L1
benchmark and the L3 p50 target are the right proofs.

## Section 8 (migration and rollback): CHANGE 8.3 (C5 above); the rest AGREE

## Section 9 (limits): CHANGE (C1, C6 above)

## Section 10 (FRs): CHANGE, add three rows

> | FR13 | a sealed file whose clear header differs from its sealed copy is refused, not shown | Go test: swap `from`, then `msg_id`, on a valid file -> both refused (L1) |
> | FR14 | no fleet tmux server holds a pane of an `enc` workspace; the owner attaches through the workspace's socket | orc test: spawn with `SPAWN_WORKSPACE` -> the fleet `list-panes -a` lacks it (L6b) |
> | FR15 | no `enc` body is passed as argv | bash test: a marker body through spool-send, desk-post, fleet-relay; `/proc/*/cmdline` sampled during the run and the journal -> 0 hits (L5) |

## Section 11 (lane split): CHANGE

Disjointness, by reading the file column: no file is named by two lanes. One
hidden overlap: L4 (MCP) will need `api/cmd/spool/main.go`, which L3 owns.
`grep -rln 'internal/mcp' api/cmd` -> only `cmd/spool/main.go`, and
`grep -ci mcp api/cmd/spool/main.go` -> 14. L4 runs after L3, so it is a
sequence, not a collision, but L4's file list should name `main.go` (the MCP
server's keyd wiring) so the lane map sees it.

Too big for one small task:

- **L7** names 12 files across restart, rotate, watchdog, handover, retire
  and rebox. Split **L7a** captures (`spl-lane-restart`, `spl-rotate-lib`,
  `spl-lane-rotate`, `spl-wd-takeover`, `spl-peer-restart`,
  `spl-orch-rotate`, `spl-watchdog`) and **L7b** copies
  (`spl-lane-handover`, `spl-desk-rebox`, `spawn-remote.sh`,
  `agent-id-retire.sh`, `desk-seat-drop.sh`). With C2 most of L7a becomes
  "refuse to capture an `enc` pane", a small change.
- **L3** carries the store, retired, flush, files and the CLI flags. Split
  **L3a** store + flags (`spool.go`, `retired.go`, `main.go`) and **L3b**
  pending + attachments (`flush.go`, `files.go`), L3b after L3a.

Missing tests and proofs:

- FR13 (C3), FR14 (C2), FR15 (P9, P10), above.
- L6b's live proof should also show `id spw-<id8>` without `sudo`, `docker`
  and `spool-agents` (Q4), not only `ps -o user=`.
- L8's gate is a new `orc/tests/` file, but W1 and W6 readers sit in `sa/`
  and include Python (`sa/scripts/spool-mirror.py`,
  `sa/scripts/agent-mirror-check.py`): the gate must scan `sa/` and `.py`
  as well as `orc/` bash.
- The P5 quick fix (`spawn-remote.sh` brief 644 -> 600) should be its own
  lane now, not wait inside L7.

## Section 12 (owner questions): votes, not decisions

| Q | vote | why |
|---|---|---|
| Q1 cipher | **A** age | in-process, no gpg-agent prompting on another tty (R1), already the backup format on the box |
| Q2 passphrase | **A** one per workspace | same OS user (C1), so N passphrases add typing, not a wall |
| Q3 OS users | **A** per workspace, now | walls workspaces apart (R5); per agent is the later step if agents of one workspace must not read each other (C1) |
| Q4 sudo | **A**, and drop `docker` too | with `NOPASSWD: ALL` or `docker` any agent anywhere reads every keyd (C6); it is box-wide |
| Q5 transcripts | **A** now, B as its own spec | B needs the vendor CLIs to start after the unlock; out of scope for spool mail at rest |
| Q6 owner key in `for` | **A** | the only recovery once an agent key is lost or rotated away |
| Q7 unlock after reboot | **A** | B is a key file, which R1 forbids by name |

## Lane-map note

`lane-map.sh --check csi-spl-doc/specs/136-spool-encrypted-at-rest/reviews/s136-claude2.md --agent c-402`
-> exit 4: no lane lists this file; 11 lanes on another box record no files
(the agy seat among them, which owns `s136-agy.md`, not this file). This
file is named for this seat by its brief.
