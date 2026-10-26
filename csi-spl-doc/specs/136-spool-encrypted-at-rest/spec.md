# 136: Spool messages encrypted at rest (phase 2 of the private workspace)

Status: **v1.1, owner answers Q1-Q7 folded (msg 165607d4); build lanes reshaped**. Editor s136-claude (c-399, v1.0); v1.1 fold by a-264 (SPL-3640). Q1-Q3, Q5-Q6 confirmed recommendation A; Q4 B (fleet agents keep today's sudo/docker; only workspace user has none) and Q7 B (unattended unlock from key file) adopted with explicit R1 exception and lane updates. Build lanes L0, L1, L2, L5a, L6a, L8, L11 landed (section 11). Issue: SPL-3640 (v1.0 was SPL-1658). This spec changes no code; the build lanes of section 11 do.

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/`, `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`. `<root>` is a spool root
(`SPOOL_ROOT`, default `/var/spool-hub`). `<seat>` is a desk seat,
`<box user home>/.local/share/csi-spl/cloud/<env>/desk/<workspace>/<box>`, or
for the local hub `<home>/.local/share/csi-spl/local-hub/desk/<workspace>/lh-<agent>`
(`orc/run/spl-local-hub-agent-join.func.sh:50,63,71`). `<state>` is the
workspace OS user's state dir (section 6.1). "The private workspace" is the
one the owner runs on the local hub (phase 1, SPL-1620). Its name appears
nowhere in this public repository.

## 0. The owner's words (verbatim, binding)

Phase 2, placed after the local hub (owner chose "B", msg 7586281d; trigger:
c-374's end-to-end PASS, msg 4f2b496f).

> msg 3cfe43ce: "the agents should ask for the passphrase only on the terminal"

> msg 0f7b0d3d: "announce" encrypted messages so non-participating agents do
> not waste resources on them

> msg 9a0a1732: "aka put those in \"encrypted\" dir(s)"

> msg 7559efa5: "if this pans out to work well it should be probably the
> standard way how the workspaces operate as shared resources on a single box"

> msg e6cdd9f3: "aka each workspace gets agents which are solely dedicated for it"

> msg 165607d4 (2026-10-26, HUM-10 Q1-Q7 answers): "Answer 1: A — age, inside the spool binary / Answer 2: A — one per workspace: one unlock opens all its agents / Answer 3: A — one per workspace / Answer 4: B — keep today's sudo / Answer 5: A — clear text in the workspace user's 0700 home now; encrypted home later / Answer 6: A — yes: you can read everything and recover a lost agent key / Answer 7: B — unattended, from a key file on the box"

What they bind, one line each:

- **R1 (3cfe43ce, exception 165607d4)** every passphrase (spool keys included) is
  read ONLY from the owner's terminal: a tty, no echo. Never from a chat post,
  the WUI, a spool message, an env var, argv, or a pipe. **Explicit exception
  (owner answer Q7 B, msg 165607d4):** unattended unlock at box boot reads the
  workspace key from a local key file on the box (mode 0400, owned by the
  workspace user; sections 4, 5).
- **R2 (0f7b0d3d)** the envelope stays plaintext and minimal; only the body
  and files are ciphertext. Agents that are not recipients spend nothing on
  an encrypted message; sweeps and classifiers skip it by the header.
- **R3 (9a0a1732)** encrypted messages live in their own directories,
  `<root>/<agent>/encrypted/{inbox,outbox,archive}/` (desk spools the same),
  never in the plain ones. A plain `spool recv` never lists them; the
  recipient reads them with an explicit flag (`spool recv --encrypted`).
  With dedicated directories, the "encrypted for X, skipped" stub of msg
  0f7b0d3d is no longer needed: the plain directories hold only plaintext
  messages.
- **R4 (7559efa5)** everything is workspace-generic: one workspace turns it
  on now, every workspace on a shared box later, by a flag and not a rewrite.
- **R5 (e6cdd9f3)** agents are dedicated to ONE workspace: a
  workspace-scoped agent, its own key pair, its own encrypted dirs, ideally
  its own OS user. Routers see envelopes only.

## 1. Today, measured: where a message body lands in clear text

Every row was found by the command in its section header, then read; the
seats re-checked D3, D5 and S1 (section 13). Nothing in the spool encrypts
today: `grep -rnE 'filippo|ReadPassword|x/term' --include=*.go api` -> no
match; `go.mod` carries `golang.org/x/crypto` for `argon2` only
(`api/internal/auth/password.go:11`), and `golang.org/x/sys` only as an
indirect require (`grep -n golang.org/x/sys api/go.mod` -> line 84,
`// indirect`).

### 1.1 The message files themselves (Go)

`grep -nE '^func |WriteFile|CreateTemp|Rename|ReadFile|ReadDir' api/internal/spool/spool.go`

| # | path:line | what lands in clear |
|---|---|---|
| D1 | `api/internal/spool/spool.go:327-338` | `writeBoxRing`: the one inbox/outbox write, `msg.Marshal` then `writeFileAtomic(..., 0o664)` |
| D2 | `api/internal/spool/spool.go:203-207,234` | `write` = recipient inbox + sender outbox: two copies of every message |
| D3 | `api/internal/spool/spool.go:286-310` | `bridgeFleet`: a third copy into `<fleet root>/<id>/inbox`, 0664, on the hub deliver path (below) |
| D4 | `api/internal/spool/spool.go:373-427,565-578` | `Recv --ack` moves the file to `archive/` (rename, or copy across filesystems) |
| D5 | `api/internal/msg/msg.go:287-307` | **the file NAME carries the body**: `<ts>--<from>--<slug of the body, cut at 32>.json` |
| D6 | `api/internal/hubclient/flush.go:283-298,323-333` | `.hub/pending/<stamp>--<msg_id>.json`: the signed wire envelope with the message, moved to `.hub/rejected/` when refused |
| D7 | `api/internal/files/files.go:252-272`, `api/internal/hubclient/hubclient.go:1120` | attachments: content-addressed blobs `<root>/files/<sha256>` |
| D8 | `api/internal/spool/retired.go:75-82` | `BounceRetired`: a reject written to the sender's inbox |

`grep -rnE '\.Deliver(To|Quiet)?\(|WriteOutbox\(' --include=*.go api` finds
the callers: the desk sidecar (`hubclient.go:920`), backfill
(`backfill.go:59`), fallback (`fallback.go:55`), the send flush
(`flush.go:63-72,125,148`).

**D3 is a third clear copy on the hub deliver path only.** `bridgeFleet`
(`spool.go:286-310`) runs from `deliverTo` (`spool.go:268,275`), not from
`write` (`spool.go:203-207`). It writes nothing when `FleetRoot` is empty,
when `id != m.To`, when the sender is not an agent, when `FleetRoot` and
`SpoolRoot` are the same path (`spool.go:288-290`), or when
`<FleetRoot>/<id>/inbox` is not already a directory (`spool.go:292-294`). A
local-hub seat reaches `do_spl_desk_up` from
`spl-local-hub-agent-join.func.sh:88` with no `SPOOL_FLEET_ROOT` in that file
(`grep -n FLEET_ROOT` -> none), so `spl-desk-up.func.sh:348` defaults the
fleet root to `SPL_WS_SPOOL_ROOT` or `/var/spool-hub`, which is not the seat
spool set at line 356. A hub-delivered DM between two agents of the private
workspace is then copied into the shared fleet spool whenever that agent's
fleet inbox exists, which it does for every harness agent.

**Who can read `<root>`.** `stat -c '%A %U:%G' /var/spool-hub /var/spool-hub/<agent>/inbox`
-> `drwxrws--- <owner user>:spool-agents`, `drwxrwsr-x <agent user>:spool-agents`;
a message file is `664`. Every agent of every workspace is in that group and
runs as one of two OS users, so **any agent can read any agent's inbox,
outbox and archive**. Volume on one box:
`find /var/spool-hub -path '*/archive/*.json' -newermt <24 h ago> | wc -l`
-> 1924 messages in 24 h; sizes p50 515 B, p99 3631 B, max 7231 B (n = 1924).

### 1.2 Envelope and parser facts that shape the format

`grep -nE '^type (Message|Attachment)|json:"' api/internal/msg/msg.go`

- `Message` keys (`msg.go:92-117`): `v, msg_id, task_id, ts, from, to,
  kind, body, files[]`, optional `ref_task_id, accepts, sig`. No workspace
  field: the workspace is the `<workspace>` path segment of a seat and
  `SPOOL_TENANT` / `X-Spool-Tenant` on the wire (`api/internal/config/config.go:52`).
- Because `Parse` sets `DisallowUnknownFields` (`msg.go:168-172`), a reader
  of today rejects any file with a new key such as `enc`. Under R3 (separate
  directories) that is a safeguard: an old binary never meets such a file.
- `Validate` caps the clear body at `MaxBodyBytes` 64 KiB (`msg.go:181,203`).
- Versions: writers emit `v:1`, readers accept 1 and 2 (`msg.go:21-37`,
  `config.go:141`).
- The local spool is unsigned (every agent seed: "UNSIGNED locally";
  `Canonical`, `msg.go:118-132`, is used for hub signatures only): nothing
  binds a header to a body today.

### 1.3 Copies made by the side channels (bash, Go notify)

`grep -n -E '> *"\$|>> *"|mv |cp |tee |send-keys|load-buffer|paste-buffer' <file>` per file:

| # | path:line | what lands in clear |
|---|---|---|
| S1 | `sa/lib/spool-notify.inc.sh:290-295` | the poke line typed into the pane carries up to 600 chars of the body (`SPOOL_NOTIFY_BODY_MAX`) |
| S2 | `sa/lib/spool-notify.inc.sh:593-594` | a human's body is pasted whole through a tmux buffer |
| S3 | `sa/lib/spool-notify.inc.sh:519,572` | `<root>/<to>/.mirror/typed/*`, `.mirror/trigger/*` |
| S4 | `sa/lib/spool-poke-queue.inc.sh:40,476,518` | `<root>/<id>/.pokes/*.poke` (the poke line) and `.pokes/notices.log` (body cut to 4000 chars), sender and recipient |
| S5 | `sa/lib/spool-asks.inc.sh:72-74,98-101` | ask journal `<asks dir>/<msg_id>.json`, `summary` = the first body line, 200 chars |
| S6 | `api/internal/notify/notify.go:95` | `SPOOL_NOTIFY_CMD` gets the body plus attachment notes on stdin |
| S7 | `sa/scripts/spool-agent-hook.sh:202,255-269,423-425` | the agent hook (spec 093) reads `<root>/<id>/inbox/*.json` and injects the body (4 KB) as `additionalContext` |
| S8 | `sa/scripts/spool-send.sh:176-180` | the hub-down path builds the JSON with jq into `<root>/peers/inbox/` and copies it to the sender's outbox |
| S9 | `sa/scripts/spool-mirror.py:106-107` | `<seat>/spool/<agent>/.mirror/mirror.log` |

### 1.4 Pane captures, handoffs, briefs, retired copies, argv

`grep -rn capture-pane orc --include=*.sh | grep -E '>|tee'`,
`grep -rnE '(retired|archive)/' orc | grep -E 'mv |cp '`,
`grep -rnE 'dispatch/' orc --include=*.sh`, `grep -n -- '--body' <file>`:

| # | path:line | what |
|---|---|---|
| P1 | `orc/run/spl-lane-restart.func.sh:109` | 300 screen lines to `<hold dir>/<task>/<id>.pane.txt` |
| P2 | `orc/run/spl-rotate-lib.func.sh:455,474`, `orc/run/spl-lane-rotate.func.sh:624`, `orc/run/spl-wd-takeover.func.sh:274`, `orc/run/spl-peer-restart.func.sh:207`, `orc/run/spl-orch-rotate.func.sh:246` | 60 screen lines into a handoff file |
| P3 | `orc/run/spl-watchdog.func.sh:828` | screen to `<tick dir>/pane` (`:1381` is a temp file, removed at `:1383`) |
| P4 | `orc/run/spl-lane-handover.func.sh:115-117,295-297` | handover brief with the last message's body verbatim (and `handoff.md`, P10), then `<root>/handover/<to>-from-<from>.md` |
| P5 | `sa/scripts/spawn-remote.sh:210-211` | remote spawn brief `<state dir>/briefs/<msg>.md`, **chmod 644** |
| P6 | `sa/scripts/agent-id-retire.sh:118-124` | the whole `<root>/<ID>` moved to `<root>/.retired/<ID>.<utc>/`, dir 2775 |
| P7 | `sa/scripts/desk-seat-drop.sh:93`, `orc/run/spl-desk-rebox.func.sh:204` | seat spools moved to `.retired/` and `rebox-retired/` |
| P8 | `/var/spool-hub/dispatch/` (no writer in code: `grep -rnE 'c002\|briefs/' orc` finds none) | hand-written post drafts and briefs (`ls /var/spool-hub/dispatch \| wc -l` -> 4779), read by `orc/lib/bash/funcs/spl-desk-body-file.func.sh:27` (`DESK_BODY_FILE`) |
| P9 | `sa/scripts/spool-send.sh:305,324,337,354`, `orc/run/spl-desk-post.func.sh:43-44,81`, `sa/scripts/spool-fleet-relay.sh:119,125` | the body as `--body` argv (the normal send, the peers relay, the cross-machine relay, desk post): visible in `/proc/<pid>/cmdline` while it runs |
| P10 | `orc/run/spl-agent-handoff.func.sh:59-66,202-218,241-245` | `<root>/<id>/handoff.md` and `handoff.prev.md`: a pane capture plus the first 120 chars of each unanswered message. `find /var/spool-hub -maxdepth 2 -name handoff.md -printf '%m\n' \| sort \| uniq -c` -> 20 files, mode 660 (s136-grok) |
| P11 | `orc/run/spl-watchdog.func.sh:132,824,843,887-888`; `orc/run/spl-dispatch-lease.func.sh:98,1390-1416` | up to 400 lines of the CLI transcript to `<root>/dispatch/wd/ctx/<id>/transcript`, and the pane's input box to `$ctx/input`. `find /var/spool-hub/dispatch/wd -name transcript -printf '%m %s\n'` -> n=1857, mode 660, 1213 non-empty, 978699721 bytes, dirs `drwxrws---` group `spool-agents` (s136-grok, s136-agy; measured 2026-10-13T09:52:47Z) |
| P12 | the box's sudo log (journald) | every `sudo -u <user> … --body "<text>"` (P9 run under sudo) is logged with its full command line until journal rotation: `sudo journalctl _COMM=sudo --since -6h \| grep -c -- '--body'` -> 156 entries in 6 h; `/var/log/journal` is readable by group `adm` (s136-claude2) |
| P13 | the fleet's tmux server | any body on an agent's screen is readable by whoever reaches the server socket (`tmux capture-pane -p -t <pane>`), with no code of ours involved. `ls -ld /tmp/tmux-1000` -> `drwx------ <owner user>`; the agent OS users can become that user (section 9). P1-P3, P10, P11 are our own captures; this is the general case (s136-claude2) |

### 1.5 Sweeps and readers that would touch a body

| # | path:line | what |
|---|---|---|
| W1 | `orc/run/spl-lane-rotate.func.sh:261,263` | classifier: `grep '"body": "ACCEPTED…'` over `inbox/*.json archive/*.json` |
| W2 | `orc/run/spl-peer-poll.func.sh:369-370,388,449` | jq over inboxes, rewrites archive copies |
| W3 | `sa/lib/spool-notify.inc.sh:157,535` | reads inbox / `archive/*-<msgid8>.json` |
| W4 | `orc/scripts/spl-desk-reply.sh:148` | reads `<seat>/spool/<agent>/inbox` |
| W5 | `orc/run/spl-unanswered-sweep.func.sh:280,291,454`, `orc/run/spl-msg-dedup.func.sh:111,125`, `spl-search-*`, `spl-public-dataset-load`, `spl-topic-copy-cross` | hub-side bodies (DB) cached to files or printed: `left(l.body,400)` into `$LEASE_DIR/unanswered.rows`, 60 chars in the DUP line |
| W6 | `sa/scripts/spool-mirror.py:56,490`, `sa/scripts/agent-mirror-check.py:139` | glob every seat spool |
| W7 | `sa/scripts/agent-inbox.sh:66`, `orc/run/spl-desk-reply.func.sh:387,430`, `sa/scripts/kill-your-self-report.sh:150-151` | stdout excerpts of 120, 80 and 60 chars; the exit gate's jq of `.body[0:120]` looks for ACCEPTED. A `v:3` file has no `body`, so a sealed ACCEPTED would not satisfy that gate (s136-agy, s136-grok) |

### 1.6 Outside the spool: the model's own record

Not in this repo, and the largest copy: every body an agent reads (recv
output, hook context, a pasted poke) is in its CLI session transcript, e.g.
`~/.claude/projects/<slug>/<session>.jsonl`, in clear, owned by the agent's
OS user. The per-project dirs are `0700`, but every agent of the fleet runs
as the same one or two OS users, so they can read each other's transcripts;
P11 also copies them into the shared spool.
`sa/scripts/spool-session-export.py:97-102,130` exports them. And the body
leaves the box: the model vendor's API receives it in clear on every turn
(section 9).

## 2. The rules

1. **Workspace flag.** A workspace is `enc` or plain. A plain workspace
   behaves exactly as today, byte for byte. Everything below applies to an
   `enc` workspace only (R4).
2. **One workspace per agent.** An agent of an `enc` workspace serves only
   that workspace (R5); the join refuses a second one (already true for the
   local hub: `spl-local-hub-agent-join.func.sh:72-76`).
3. **Ciphertext on disk, always.** A message of an `enc` workspace is
   written only under `encrypted/`, sealed (section 3). No code path writes
   its body, a slug of it, or a capture of a screen showing it, to any file
   in clear (rows D1..D8, S1..S9, P1..P13), and no code path passes an `enc`
   body as argv (P9, P12): a body goes on stdin or in a 0600 file of the
   workspace user, removed after use.
4. **Header only outside `encrypted/`.** The plain envelope (3.1) may
   appear in pokes, logs and journals; the body may not.
5. **Decrypt in memory, for a caller of the workspace OS user who names an
   identity in `for`.** Only `spool recv --encrypted`, `spool tail
   --encrypted` and their MCP equivalents decrypt; they print to stdout and
   write nothing back to disk. On the one-OS-user-per-workspace shape (Q3 A)
   keyd sees one uid for every agent of that workspace, so `--as <id>` is a
   name the caller picks: a sibling agent of that user can ask keyd to open
   any message whose `for` holds an identity of the workspace. Section 9
   states it. This spec does not claim per-agent secrecy under Q3 A.
6. **Passphrases on the owner's terminal only** (R1, section 5; unattended boot key file exception 165607d4).
7. **Sweeps never open `encrypted/`.** A gate test enforces it (L8).
8. **No hard-coded workspace** anywhere: the flag, recipients and dirs are
   per workspace, looked up, never named in code or cnf (R4; the name is
   private).

## 3. Data: the envelope and the "encrypted" dirs

### 3.1 The sealed message (`v:3`)

```json
{"v":3,"msg_id":"…","task_id":"…","ts":"…","from":"c-101","to":"c-102","kind":"note",
 "enc":"age","for":["c-102","HUM-1"],"ct":"<base64 age ciphertext>","files":[]}
```

- `v:3` is new; `body` is absent (not empty), so no reader can take it for
  a message with an empty body. `Parse` of today refuses the file (unknown
  keys), which is safe: only `encrypted/` holds it.
- `enc`: the scheme, `"age"` (section 4). `for`: every identity that can
  open this copy: the agent it is written for and the workspace owner
  (recovery, Q6). The plaintext header exposes sender, recipient, task and
  time; that metadata exposure is a design trade-off accepted in section 9.
- `ct`: the age ciphertext of the inner JSON
  `{"msg_id":"…","task_id":"…","ts":"…","from":"…","to":"…","kind":"…","body":"…","files":[…]}`.
  On open, `spool` compares the six header fields with the inner copy and
  refuses the message (exit 6, `HEADER MISMATCH <msg_id>`) on any
  difference; it prints the inner values, never the outer ones. Attachment
  metadata goes inside; the outer `files` stays empty. This binds the header
  to the body although the local spool is unsigned (1.2): a rewritten `from`
  or a `ct` replayed under another `msg_id` is refused (FR13).
- `MaxBodyBytes` stays on the clear body, checked before sealing; the file
  is about 1.37x (base64) plus about 200 B per recipient.
- **File name** `<ts>--<from>--<msg_id first 8>.age.json`: no body slug
  (fixes D5 for `enc`).
- **Attachments**: a sealed blob `<root>/encrypted/files/<sha256 of the
  ciphertext>`, same recipients. A plain-workspace blob is unchanged.

### 3.2 The directories (R3)

```
<root>/<agent>/encrypted/{inbox,outbox,archive}/   0700, owner = the workspace OS user
<root>/<agent>/encrypted/.hub/{pending,rejected}/  0700 (D6: sealed to the sender + owner)
<root>/encrypted/files/                            0700 (D7)
<seat>/spool/<agent>/encrypted/…                   the same, on a desk seat
```

- The plain `inbox|outbox|archive` of an `enc` agent hold only clear
  messages from outside its workspace, which rule 2 makes none; they stay
  empty in practice.
- `bridgeFleet` (D3) for an `enc` workspace writes the sealed file to
  `<fleet root>/<id>/encrypted/inbox/`, and only when that fleet root is the
  workspace's own (6.2); never to the shared fleet root.
- `Recv` and `Tail` without `--encrypted` never `ReadDir` an `encrypted/`
  path; with it they read only the caller's own `encrypted/` (Tail: only
  messages whose `for` holds the caller).

### 3.3 Fan-out, and where sealing happens

A sealed message is delivered only to the inbox of its addressed agent on
the box; the sender keeps the outbox copy. A channel post of an `enc`
workspace is sealed once per member delivery, to that member plus the owner,
so one member's copy names no other member. OD seats and dispatchers of
other workspaces get nothing, not even a stub (R3). The poke (S1) for a
sealed message is one header-only line:
`: 'SPOOL c-102: note from c-101 task <id> msg <id> :: encrypted :: run: spool recv --encrypted --as c-102'`.

**Where sealing happens.** The sending seat seals its outbox copy (for the
sender and the owner) and, when the hub is down, its pending wire copy (D6);
flushing a sealed pending copy needs keyd unlocked, and while it is locked
the copy waits. The hub carries the clear body to the receiving seat
(section 9), whose sidecar seals the delivered copy for the addressed agent
and the owner before its first write. A seat therefore needs only its own
agents' recipients and the owner's. Sealing on the sender for the receiver
(end to end, the hub storing only `ct`) is a follow-up, not this spec.

## 4. The key model

- **Scheme: age** (X25519 recipients; `filippo.io/age` inside the Go
  binary: no external `age` or `gpg` process, no keyring, no gpg-agent).
  The local hub already uses age for its backups
  (`orc/run/spl-local-hub-backup-keygen.func.sh:3-31`, inside the backup
  image). gpg is owner question Q1.
- **Per agent**: one age identity per agent of an `enc` workspace, made by
  `spool key init --as <id>`. The workspace's agent identities are stored
  together in `<state>/keys/agents.age`, sealed with age's scrypt
  passphrase mode under the workspace passphrase (section 5), mode 0600,
  owned by the workspace OS user. Each recipient (public key)
  `<state>/keys/<id>.pub` sits beside it, readable by the seats of that
  workspace (3.3).
- **Owner key**: one age identity per workspace for the owner, made on his
  terminal under his own passphrase, its secret part moved OFF the box like
  the backup identity (`csi-spl-doc/doc/md/guides/local-hub.md` 7.1). Only
  its recipient remains on the box. Because every sealed message names it in
  `for`, the owner keeps full read and recovery access after an agent has
  retired and its identity has been dropped.
- **The key holder, `spool keyd`**: an agent never types a passphrase and
  has no terminal (its tool shell has no tty). Under the owner's answer Q7 B
  (msg 165607d4), unlock at boot is unattended: keyd reads the unlock key
  from a dedicated key file on the box (below). On boot/startup, keyd starts
  unattended (`spool keyd --key-file <state>/keys/unlock.key --workspace <ws id>`),
  reads the key from `<state>/keys/unlock.key`, zeroes the read buffer in
  memory, locks its process memory (`mlock`, `PR_SET_DUMPABLE=0` / `PT_DENY_ATTACH`,
  `RLIMIT_CORE=0`, no core dump) and serves open requests on unix socket
  `<state>/keyd.sock` (0600, `SO_PEERCRED` / `LOCAL_PEERCRED` uid = the
  workspace OS user). `spool recv --encrypted --as <id>` asks keyd to open the
  messages whose `for` holds `<id>`. The identities never touch disk in clear.
  Interactive terminal unlock (`spool key unlock --workspace <ws id>` on `/dev/tty`)
  remains supported as fallback when no key file is present or after an explicit
  `spool key lock`.
- **The unattended key file (Q7 B)**:
  - **Where it lives**: `<state>/keys/unlock.key` (path pattern:
    `/home/spw-<id8>/.local/state/csi-spl/keys/unlock.key`), owned by the
    workspace OS user (`spw-<id8>:<spw-id8>`), mode `0400` (read-only by
    the workspace user).
  - **Who can read it**: only the workspace OS user (`spw-<id8>`), and root
    (which bypasses unix file permissions; section 9). Group and other have no
    access (`mode 0400`).
  - **How keyd reads it at boot**: at system boot or service start (managed
    by systemd or `spl-ws-enc-setup`), keyd is invoked with
    `--key-file <state>/keys/unlock.key --workspace <ws id>`. keyd opens the
    file, parses the passphrase/key into locked memory, wipes the file buffer,
    and initializes the age identities without requesting a tty.
  - **How it is rotated**: `spool key rotate-unlock-key --workspace <ws id>`
    generates a new random key string, re-encrypts `agents.age` with age
    under the new key, writes `<state>/keys/unlock.key.tmp` (mode 0400),
    atomically replaces `unlock.key`, unlinks the previous key file, and
    reloads keyd's in-memory keystore.
  - **What a stolen disk reveals (plainly stated)**: because the unlock key
    lives in plaintext on the box (`unlock.key`), anyone who steals the
    physical disk or acquires an unencrypted disk image can read `unlock.key`
    and decrypt `agents.age` and all ciphertext messages in `encrypted/`.
    Encryption-at-rest against physical disk theft therefore relies entirely
    on the host's underlying full-disk encryption (LUKS / dm-crypt); this spec
    protects against unprivileged multi-tenant runtime access and accidental
    cleartext disk leakage, not offline theft of an unencrypted filesystem.
- **Same uid.** The socket check is the workspace OS user's uid. It cannot
  tell two agents of that user apart; keyd opens for the `<id>` the caller
  names. Per-agent secrecy is Q3 B (rule 5, section 9).
- **Lock**: `spool key lock` drops held identities from memory; keyd closes the
  socket and exits or enters locked state. Until the next unlock (via key file
  service restart or manual `spool key unlock`) `spool recv --encrypted` prints
  `LOCKED: keyd is locked; start keyd with --key-file or run 'spool key unlock --workspace <ws id>' on terminal`
  and exits 5. A spool command never prompts unless stdin and stdout are a tty.
- **Sealing needs no unlock**: encryption uses public recipients only. The
  desk sidecar keeps delivering while keyd is locked; incoming mail waits,
  sealed.
- **Rotation**: `spool key rotate --as <id>` makes a new identity; old
  messages stay readable by the old identity (kept in `agents.age`) and by
  the owner. Revoking a leaked agent key = rotate + drop the old identity;
  what that agent already read is in its transcript anyway (section 9).
- **The owner in `for` is confirmed (Q6 A, msg 165607d4)**: the owner key is
  included in every sealed message's `for` list, ensuring the owner can read
  all messages and recover data after agent retirement.

## 5. The passphrase rule (R1)

- Read with `golang.org/x/term` `ReadPassword` on `/dev/tty` only. Refused,
  with an exit code and before any read, when stdin or stdout is not a
  terminal (also under `sudo` with no tty), when `SPOOL_KEY_PASSPHRASE`,
  `PASSPHRASE` or `AGE_PASSPHRASE` is set (those names, not every variable
  whose name contains `PASSPHRASE`), or when argv carries a passphrase flag.
  Asked twice on creation, at least 16 characters, as the local hub DB
  (`guides/local-hub.md` 1.3).
  **Exception (owner msg 165607d4, Q7 B):** unattended unlock at boot reads
  the workspace unlock key directly from `<state>/keys/unlock.key` (mode 0400,
  owned by `spw-<id8>`), bypassing the `/dev/tty` requirement for the keyd
  daemon process. Interactive unlock commands still require `/dev/tty`.
- Never logged, never in a spool message, the WUI, a post, or a pipe; never
  in an agent brief. (Under Q7 B exception 165607d4, the unattended key file
  lives in mode 0400 at `<state>/keys/unlock.key`). An agent that needs an
  unlock sends the owner the command to run (a blocker), never a request for
  the passphrase.
- One passphrase/key per workspace for its agent identities (Q2 A, msg 165607d4);
  the owner key has its own.

## 6. Agents dedicated to a workspace (R5)

### 6.1 One OS user per workspace

Unix permissions are the only boundary between processes on the box.
Because all agents run today as one of two shared OS users (1.1), a 0700
directory or a unix socket keeps no other agent out. An `enc` workspace
therefore gets **its own OS user** `spw-<first 8 hex of the workspace id>`
(never its name):

- home 0700, alone in its own group; not in `spool-agents`, `docker` or
  the owner user's group; no sudo (Q4 B: only the workspace user has none;
  fleet agents keep their existing sudo and docker);
- in its home: its spool root (the workspace's fleet root,
  `SPL_WS_SPOOL_ROOT`, already honoured at `spl-desk-up.func.sh:348`), its
  seats, `<state>` with keyd, keys, and `<state>/keys/unlock.key` (mode 0400),
  its own tmux server (6.2) and **its agents' CLI transcripts** (1.6);
- its own vendor CLI logins (one login shared by two users splits on token
  refresh); the owner logs each vendor in once, on his terminal.

Per-agent OS users (Q3 B) also wall agents of one workspace from each
other, and cost one vendor login per agent.

### 6.2 Routing and placement

- The workspace's dispatcher and its lanes are agents of that workspace,
  running as its OS user, **in the workspace user's own tmux server**
  (socket under its 0700 home). The fleet orchestrator places a lane with
  `SPAWN_WORKSPACE=<ws id>` (never the name); the owner reaches the
  workspace's windows with `sudo -u spw-<id8> tmux -S <socket> attach`. No
  pane of an `enc` workspace runs on the fleet's tmux server (P13), and the
  fleet's watchdogs, rotations and handoffs (P1-P3, P10, P11) never reach it.
- A cross-workspace router, if kept, sees envelopes only: it reads the
  sealed file's header, never `ct`, and holds no identity.
- `SPOOL_FLEET_ROOT` of an `enc` seat is the workspace's own spool root;
  `do_spl_local_hub_agent_join` passes it (fixes D3).

### 6.3 How many agents a box hosts

The fleet ceiling stays **40 concurrent agent windows per box**, counted
across all workspaces (global CLAUDE.md, "Spawn an agent"). The count adds
each workspace server's `list-windows -a`; L6b extends the count command.
Each workspace also has a cap in its private config, `WS_AGENT_MAX`
(default 4: one dispatcher, up to three lanes); a spawn past either cap is
refused. Fixed cost per workspace: one OS user, one keyd (a few MB), one
tmux server, its vendor logins. At 4 per workspace one box hosts up to 10
workspaces; vendor quota and CPU bind first, as today.

## 7. Performance

- Seal: one X25519 + ChaCha20-Poly1305 per recipient. The earlier draft expected
  "well under 1 ms", which assumed the 515 B p50 body on an idle box. Measured
  in L1 by c-406 (msg 5ff49231, commit 9ff3e5bc3): Seal of a 3631 B body (p99) to
  3 recipients is **1.16 ms/op**, Open **0.71 ms/op** (n=1000, load avg 16 on 16
  CPUs; not re-measured idle). At 1924 messages a day the added CPU is
  negligible.
- Unlock: one scrypt (age's default work factor, about 1 s) per unlock,
  because one `agents.age` holds all of a workspace's identities.
- `recv --encrypted`: one socket round trip to keyd per message; target p50
  < 5 ms per message, measured in L3a (n >= 100).
- Size: about 1.4x per file plus 200 B per recipient; at 1924 messages x 3
  copies x about 1 KB a day, disk is no limit.

## 8. Migration and rollback

1. **Flag**: a workspace setting `spool_enc` (bool, default false) on the
   hub, one migration. The private workspace's row exists only in the local
   hub's DB, so its name never reaches the public repo. The seat learns the
   flag at pin time and from the roster; a seat of an `enc` workspace
   refuses to start without its recipients and its workspace OS user.
2. **Turning on**: workspace user + keys (`do_spl_ws_enc_setup`, owner's
   terminal) -> seats re-joined as the workspace user, in its tmux server ->
   flag on -> new mail is sealed.
3. **Existing clear mail**: `do_spl_ws_enc_migrate` seals every clear file
   of that workspace's seats and of `/var/spool-hub/<its agents>/` into
   `encrypted/`, opens each sealed file through keyd with the addressed
   agent's identity and compares it byte for byte with the clear file,
   checks that the owner's recipient is among the file's age stanzas,
   deletes the clear file, and lists for the owner the side copies of
   1.3/1.4 it found (P10, P11 included). Deletion on ext4 is not erasure
   (journal, free blocks): stated in section 9, not hidden.
4. **Rollback**: flag off -> new mail is clear again, in the plain dirs.
   Sealed files stay sealed and readable with `--encrypted` while keyd is
   unlocked. `do_spl_ws_enc_export` (owner's terminal) writes a decrypted
   copy only where the owner names it. No code decrypts back into the plain
   dirs on its own.
5. **The generic switch later (R4)**: `enc` as the default for every
   workspace on a shared box = the flag's default plus one OS user per
   workspace. Nothing in sections 3-6 names a workspace.

## 9. Honest limits (c-374's trust note, extended)

Plainly: **this protects messages at rest from agents of other workspaces running without root,
sweeps and copies of the disk, and unattended reboot with the key file. It does not protect them from root/sudoers (which fleet agents remain under Q4 B), from offline theft of an unencrypted disk (Q7 B), from the model vendor, from a sibling agent of the same workspace, or from the agent that reads them.**

Residual risk (Q4 B): any fleet agent retains `sudo` and `docker`, so a compromised or rogue fleet agent can become the workspace user (`sudo -u spw-<id8>`) or read keyd's memory and files as root.

- **Root and fleet agents with sudo (Q4 B)**: under the owner's answer Q4 B
  ("keep today's sudo"), fleet agents retain `(ALL) NOPASSWD: ALL` and
  `docker`; only the workspace user has none. Any fleet agent can become the
  workspace user or root (`sudo -u spw-<id8>` or `sudo -i`), inspecting keyd's
  memory (`/proc/<pid>/mem`, ptrace) while it is unlocked, the agent's process
  memory, its tmux server and scrollback, its transcript, the journal (P12),
  and `<state>/keys/unlock.key`. `mlock` and `PR_SET_DUMPABLE=0` stop swap and
  core dumps, not root.
- **Physical disk theft (Q7 B)**: because the unattended unlock key file lives
  on the box in `<state>/keys/unlock.key` (mode 0400), anyone who steals the
  physical drive or an offline disk image can read the key and decrypt
  `agents.age` and all ciphertext messages in `encrypted/`. Protection against
  offline disk theft relies entirely on host-level full-disk encryption
  (LUKS / dm-crypt).
- **A sibling agent of the workspace OS user** can open any sealed message
  of that workspace: it is the uid keyd trusts, and it picks `--as`. This is
  the Q3 A trade-off, not a root-only limit. Per-agent identities give
  rotation and revocation, not isolation.
- **The model vendor** receives every body an agent reads, in clear, on
  every turn; the transcript keeps it on disk under the workspace user
  (1.6). Encrypting transcripts is outside this spec (Q5).
- **The envelope** (from, to, task, kind, time, recipients) is clear by
  design (R2): who talks to whom, and when, stays visible.
- **The hub** handles bodies in clear in its process and its DB (3.3); the
  local hub keeps that DB encrypted at rest (phase 1). A cloud hub is out of
  scope.
- **Copies made before the switch**: the watchdog transcripts (P11, n=1857,
  978699721 bytes, mode 660) and `handoff.md` files (P10, n=20, mode 660)
  already on disk are listed by the migration (8.3); deleted clear copies
  may remain in ext4 free blocks and the journal.
- **The owner's identity** is as safe as the place he keeps it off the box.

## 10. Functional requirements

| FR | requirement | proof (lane) |
|---|---|---|
| FR1 | a plain workspace writes byte-identical files to today | golden test of `Marshal` and the file name (L1) |
| FR2 | an `enc` message is written only under `encrypted/`, as `v:3` with no `body`, its file name free of body text | Go test: grep the whole spool tree for a marker body -> 0 hits (L3a) |
| FR3 | only the `for` identities open it; any other identity fails | Go test (L1) |
| FR4 | plain `spool recv` / `tail` / MCP never list `encrypted/`; `--encrypted` shows only the caller's messages | Go tests (L3a, L4) |
| FR5 | a passphrase is read only from a tty; env, argv, pipe, file, sudo without a tty -> refused before any read (unattended boot key file exception under Q7 B, owner msg 165607d4) | pty test + 5 controls (L2); key-file test (L2b) |
| FR6 | keyd: socket 0600, another uid refused (`SO_PEERCRED`), identities never on disk in clear, lock drops them; unattended unlock reads mode 0400 key file (Q7 B) | test with two uids in the CI container (L2, L2b) |
| FR7 | no poke, notices log, mirror, ask summary, hook context, notify stdin, `--body` argv (P9) or `handoff.md` / `handoff.prev.md` excerpt (P10) carries an `enc` body | bash tests with a marker body (L5a, L5b, L7b) |
| FR8 | no capture, handoff, `$ctx/transcript`, `$ctx/input` (P11), handover brief, retire or rebox copies an `enc` agent's screen or body in clear | bash tests (L7a, L7b) |
| FR9 | no sweep, classifier or cache writer reads under `encrypted/` or copies an `enc` body out of the hub | gate test over every reader in `orc/`, `sa/` and `.py` (L8); W5 writers (L11) |
| FR10 | an `enc` seat's fleet root is its workspace's; the shared fleet root gets nothing | orc test (L6b) |
| FR11 | migrate seals all clear files of the workspace, verifies through keyd and the owner stanza, deletes; after rollback the sealed files still open | orc test + live proof (L9) |
| FR12 | no workspace name in code, cnf, test or doc | `do_check_dist_hygiene` (every lane) |
| FR13 | a sealed file whose clear header differs from its sealed copy is refused, not shown | Go test: swap `from`, then `msg_id`, on a valid file -> both refused (L1) |
| FR14 | no fleet tmux server holds a pane of an `enc` workspace; the owner attaches through the workspace's socket | orc test: spawn with `SPAWN_WORKSPACE` -> the fleet `list-panes -a` lacks it (L6b) |
| FR15 | no `enc` body is passed as argv | bash test: a marker body through spool-send, desk-post, fleet-relay; `/proc/*/cmdline` sampled during the run and the journal -> 0 hits (L5b) |
| FR16 | the exit gate accepts an ACCEPTED sealed in `ct` (through keyd) and needs no clear `body` | bash test (L5b) |

## 11. Build split

Small lanes, disjoint files. Routing kind `secret` (claude, grok or mistral;
never qwen or agy), because the lanes handle key code. No brief names a key
path or the name of the private workspace. Every live proof runs on the
throwaway proof hub with a throwaway workspace, never the private one.

### 11.1 Landed build lanes (status against v1.0)

Seven build lanes and documentation benchmark corrections have landed on master:

- **L0 brief mode**: LANDED in `626ac5529` (SPL-1668) — `sa/scripts/spawn-remote.sh` (brief 600, or 640 with ACL mask).
- **L1 seal format**: LANDED in `9ff3e5bc3` (SPL-1669) — `api/internal/enc/`, `api/internal/msg/msg.go`, `api/go.mod`, `api/go.sum` (`v:3`, age seal/open, inner JSON, header check, benchmark).
- **L2 keys + keyd (interactive)**: LANDED in `a05ea1f24` (SPL-1676); peer-uid and cross-platform fixes `48848e14e`, `93731a030`, `1dcde76a3`, `f2aef210a` (SPL-1676), `4dc86e58c` (SPL-2694) — `api/cmd/spool/key.go`, `api/internal/keyd/`.
- **L5a notify + side files**: LANDED in `8b146fa3b` (SPL-1675); test toolchain fixes `74acb4b48`, `4148567ac` — `api/internal/notify/notify.go`, `sa/lib/spool-notify.inc.sh`, `sa/lib/spool-poke-queue.inc.sh`, `sa/lib/spool-asks.inc.sh`, `sa/scripts/spool-agent-hook.sh`, `sa/scripts/spool-mirror.py`.
- **L6a flag (hub)**: LANDED in `58b7a660f` (SPL-1670) — `rdb/` migration, `api/internal/store/tenant_kv.go`, `api/internal/hub/tenant_settings.go` (`spool_enc` flag).
- **L8 sweep gate**: LANDED in `f541cafda` (SPL-1671) — `orc/tests/enc-dirs-untouched.tst.sh` (gate test verifying sweeps never open `encrypted/`).
- **L11 cache writers**: LANDED in `44c8e21c3` (SPL-1679) — `orc/run/spl-unanswered-sweep.func.sh`, `orc/run/spl-msg-dedup.func.sh` (omit enc bodies from cache files and dedup lines).
- Doc corrections: `7b7469cc5` (SPL-1678) — L0 ACL mode and L1 benchmark measurements folded.

### 11.2 Delta from the owner's answers (Q1-Q7, msg 165607d4)

The owner's binding answers reshape the build plan:

1. **Lanes changed**:
   - **L6b workspace user + seats**: reshaped by Q4 B and Q7 B. Fleet agents keep today's sudo and docker; only the workspace user `spw-<id8>` has no sudo, no docker, and no `spool-agents` group. Sets up `<state>/keys/unlock.key` (mode 0400, owned by `spw-<id8>`) during `spl-ws-enc-setup`, and wires unattended keyd startup at boot.
   - **L9 migrate + rollback**: reshaped by Q7 B. Migrates clear mail, creates/verifies `<state>/keys/unlock.key`, tests unattended unlock, and cleans up key file on rollback.
   - **L10 guide**: reshaped by Q4 B and Q7 B. Documents unattended key file management (`unlock.key`, permissions, boot unlock, rotation) and states honest limits plainly (residual risk of fleet agents retaining sudo, physical disk theft risk).
2. **New lane**:
   - **L2b unattended key file**: new lane required by Q7 B (owner msg 165607d4). Files: `api/cmd/spool/key.go`, `api/internal/keyd/store.go`, `api/internal/keyd/pass.go`. Adds `--key-file` flag to `spool keyd` / `spool key unlock`, unattended boot unlock from `<state>/keys/unlock.key` (mode 0400), key file rotation helper, R1 exception. Needs: L2 (`a05ea1f24`).
3. **Dropped lanes / tasks**:
   - **Dropped**: box-wide removal of `NOPASSWD: ALL` and `docker` from fleet agents (planned separate spec under Q4 A recommendation; dropped under owner answer Q4 B).
   - **Dropped**: interactive owner terminal unlock on `/dev/tty` at every reboot (replaced by Q7 B unattended key file).
4. **Pending lanes (unchanged)**:
   - **L3a store + flags**: `api/internal/spool/spool.go`, `api/internal/spool/retired.go`, `api/cmd/spool/main.go` (`--encrypted` on recv/tail). Needs L1, L2.
   - **L3b pending + files**: `api/internal/hubclient/flush.go`, `api/internal/files/files.go`. Needs L3a.
   - **L4 MCP**: `api/internal/mcp/mcp.go`, `api/cmd/spool/main.go`. Needs L3a.
   - **L5b argv + readers**: `sa/scripts/spool-send.sh`, `orc/run/spl-desk-post.func.sh`, `sa/scripts/spool-fleet-relay.sh`, `sa/scripts/kill-your-self-report.sh`, `sa/scripts/agent-inbox.sh`, `orc/scripts/spl-desk-reply.sh`, `orc/run/spl-desk-reply.func.sh`. Needs L3a.
   - **L7a captures**: `orc/run/spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh`, `spl-dispatch-lease.func.sh`. Needs L6b.
   - **L7b copies**: `orc/run/spl-lane-handover.func.sh`, `orc/run/spl-desk-rebox.func.sh`, `orc/run/spl-agent-handoff.func.sh`, `sa/scripts/agent-id-retire.sh`, `sa/scripts/desk-seat-drop.sh`. Needs L6b.

### 11.3 Lane table

| lane | status | files (only these) | test | live proof | needs |
|---|---|---|---|---|---|
| L0 brief mode | LANDED (`626ac5529`) | `sa/scripts/spawn-remote.sh` (P5: brief 644 -> 600, or 640 with ACL) | a brief file is 600 where the box user is the agent user; 640 (`stat -c %a`, ACL mask; `getfacl` shows `group::---`) where the agent CLI runs as another user | PENDING: `stat -c %a` and `getfacl` of the next remote spawn's brief on each box shape (no remote spawn reached the box since the land) | - |
| L1 seal format | LANDED (`9ff3e5bc3`) | new `api/internal/enc/` (age seal/open, the inner JSON, header check); `api/internal/msg/msg.go` (`v:3`, `enc`, `for`, `ct`, the name without slug); `api/go.mod`, `api/go.sum` (`filippo.io/age`, `golang.org/x/term`, and `golang.org/x/sys` promoted to direct). No other lane edits `go.mod` or `go.sum`. | FR1, FR3, FR13, the 7 benchmark | - | - |
| L2 keys + keyd (interactive) | LANDED (`a05ea1f24`, `4dc86e58c`) | new `api/cmd/spool/key.go`, new `api/internal/keyd/` | FR5, FR6 | the owner unlocks a throwaway workspace on the proof hub; `spool key status` -> unlocked, after `lock` -> locked | L1 |
| L2b unattended key file | **NEW** (Q7 B) | `api/cmd/spool/key.go`, `api/internal/keyd/store.go`, `api/internal/keyd/pass.go` | FR5 exception, FR6; unlock from mode 0400 file without tty, invalid/missing key file rejected, rotation helper | keyd starts unattended from `<state>/keys/unlock.key`, serves open requests, lock drops keys | L2 |
| L3a store + flags | PENDING | `api/internal/spool/spool.go`, `api/internal/spool/retired.go`, `api/cmd/spool/main.go` (`--encrypted` on recv/tail) | FR2, FR4, the recv p50 of 7 | two agents of the throwaway workspace exchange 10 sealed DMs; `grep -r <marker>` over every spool root -> 0 | L1, L2 |
| L3b pending + files | PENDING | `api/internal/hubclient/flush.go`, `api/internal/files/files.go` | sealed pending flushes after unlock; sealed blob round trip | a DM with an attachment while the hub is down, then up | L3a |
| L4 MCP | PENDING | `api/internal/mcp/mcp.go` and its tool goldens; `api/cmd/spool/main.go` (the MCP server's keyd wiring only, after L3a landed) | FR4 (MCP) | an MCP recv of a sealed DM through keyd | L3a |
| L5a notify + side files | LANDED (`8b146fa3b`) | `api/internal/notify/notify.go`, `sa/lib/spool-notify.inc.sh`, `sa/lib/spool-poke-queue.inc.sh`, `sa/lib/spool-asks.inc.sh`, `sa/scripts/spool-agent-hook.sh`, `sa/scripts/spool-mirror.py`, `sa/scripts/agent-mirror-check.py` | FR7 | after L3a: the L3a proof also greps `.pokes`, `.mirror` and the asks dir -> 0 | L1 (tests), L3a (proof) |
| L5b argv + readers | PENDING | `sa/scripts/spool-send.sh` (stdin body; the hub-down path refuses `enc`), `orc/run/spl-desk-post.func.sh`, `sa/scripts/spool-fleet-relay.sh`, `sa/scripts/kill-your-self-report.sh`, `sa/scripts/agent-inbox.sh`, `orc/scripts/spl-desk-reply.sh`, `orc/run/spl-desk-reply.func.sh` | FR15, FR16, the spool-send fallback refusal | a sealed ACCEPTED ends a proof lane through `/exit-clean` | L3a |
| L6a flag (hub) | LANDED (`58b7a660f`) | the next free `rdb/` migration; `api/internal/store/tenant_kv.go`; `api/internal/hub/tenant_settings.go`; the pin and roster answers (the lane names their files in its first commit, none listed by L1-L5) | the flag round trip, Memory + Postgres | flag on for the throwaway workspace only | - |
| L6b workspace user + seats | **CHANGED** (Q4 B, Q7 B) | new `orc/run/spl-ws-enc-setup.func.sh`; `orc/run/spl-local-hub-agent-join.func.sh`; `orc/run/spl-desk-up.func.sh` (the fleet root of an `enc` seat); `sa/scripts/spawn-window.sh` (`SPAWN_WORKSPACE`, the workspace tmux server); `sa/scripts/restore-core.inc.sh` (a restore keeps the user and server); the 40-window count command | FR10, FR14 + refusal tests; `<state>/keys/unlock.key` 0400; unattended keyd boot service | two agents seated as the workspace user; `ps -o user=` shows it; `id spw-<id8>` without `sudo`, `docker`, `spool-agents`; fleet agents retain today's sudo/docker | L6a, L2b |
| L7a captures | PENDING | `orc/run/spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh` (P11 transcript and input included), `spl-dispatch-lease.func.sh` (P11 only) | FR8: each refuses to capture an `enc` pane | rotate one proof agent; nothing of it under `dispatch/wd/ctx` | L6b |
| L7b copies | PENDING | `orc/run/spl-lane-handover.func.sh`, `orc/run/spl-desk-rebox.func.sh`, `orc/run/spl-agent-handoff.func.sh` (P10), `sa/scripts/agent-id-retire.sh`, `sa/scripts/desk-seat-drop.sh` | FR7 (handoff), FR8 | retire one proof agent; its `.retired/` copy holds only `encrypted/` | L6b |
| L8 sweep gate | LANDED (`f541cafda`) | new `orc/tests/enc-dirs-untouched.tst.sh`, scanning `orc/`, `sa/` and `.py` (W1-W7, `spl-peer-poll.func.sh` included) | FR9, plus a planted control on a throwaway branch | - | - |
| L9 migrate + rollback | **CHANGED** (Q7 B) | new `orc/run/spl-ws-enc-migrate.func.sh`, new `orc/run/spl-ws-enc-export.func.sh` | FR11; unattended key file generation, verify through keyd, rollback unlinks key file | migrate the proof workspace's clear mail, roll back, read again | L3b, L6b |
| L10 guide | **CHANGED** (Q4 B, Q7 B) | `csi-spl-doc/doc/md/guides/local-hub.md` (a new section) and the agents' help page | `do_check_dist_hygiene`; documents unattended unlock key file management and honest limits | - | L9 |
| L11 cache writers | LANDED (`44c8e21c3`) | `orc/run/spl-unanswered-sweep.func.sh`, `orc/run/spl-msg-dedup.func.sh` | FR9 (W5): no body of an `enc` workspace in a cache file or printed line | - | L6a |

Order: L0, L1, L2, L5a, L6a, L8, L11 landed. Next: L2b (unattended key file);
L3a after L2; L3b, L4 and L5b after L3a; L6b after L6a and L2b; L7a and L7b
after L6b; then L9, then L10. The owner switches the private workspace
himself, on his terminal, after L10.

## 12. Owner questions

The owner's binding answers were received in HUM-10 (csitea topic
`6fec05cc-6b83-4976-b7de-7d9f796dde24`, form `f7eb45ae`, final msg `165607d4`,
2026-10-26 14:5xZ, verbatim):
"Answer 1: A — age, inside the spool binary / Answer 2: A — one per workspace: one unlock opens all its agents / Answer 3: A — one per workspace / Answer 4: B — keep today's sudo / Answer 5: A — clear text in the workspace user's 0700 home now; encrypted home later / Answer 6: A — yes: you can read everything and recover a lost agent key / Answer 7: B — unattended, from a key file on the box"

Q4 B and Q7 B differ from the panel's recommendation (all 4 seats voted A).
Section 12 rule: "an owner answer that differs reshapes the lanes it names".
Q7 B conflicts with rule R1 (owner msg 3cfe43ce: passphrases only from the owner's terminal, never from a file); the owner's newer answer wins, so R1 gets an explicit exception for the unattended unlock key file (sections 0, 4, 5).

| Q | question | A | B | panel | recommendation | owner (msg 165607d4) |
|---|---|---|---|---|---|---|
| Q1 | Cipher | age inside the Go binary (`filippo.io/age`) | gpg (keyrings, gpg-agent) | A: all 4 | **A**: no external process or agent socket, one small dependency, already the local hub's backup format | **A** (age inside the spool binary) |
| Q2 | Passphrases for agent keys | one per workspace: one unlock opens all its agents | one per agent: the owner types N at each box start | A: all 4 (grok: flips to B if Q3 is B) | **A**: a workspace's agents share its OS user (6.1), so N passphrases add typing, not a wall | **A** (one per workspace: one unlock opens all its agents) |
| Q3 | OS users | one per workspace | one per agent | A: all 4 | **A**: walls workspaces apart (R5); per agent costs one vendor login per agent and is the later step if agents of one workspace must not read each other (section 9) | **A** (one per workspace) |
| Q4 | sudo and `docker` | box-wide: the workspace user AND the fleet's agent users lose `NOPASSWD: ALL` and `docker` | only the workspace user has none; fleet agents keep both | A: all 4 | **A**, with its cost stated: the fleet runs every git and `./run` through `sudo -u <owner user>` today (global CLAUDE.md), so A needs narrow sudoers rules in its place, a separate spec. Until then the wall against other agents is not real (section 9); L1-L11 do not wait for it | **B** (keep today's sudo; only the workspace user has none) |
| Q5 | CLI transcripts | in the workspace user's 0700 home, clear (this spec) | also on an encrypted home (gocryptfs, unlocked with keyd) | A: all 4 | **A** now, B as its own spec: B needs the vendor CLIs to start after the unlock | **A** (clear text in the workspace user's 0700 home now; encrypted home later) |
| Q6 | The owner key in every `for` | yes: the owner reads everything, and recovers | no: only the agents | A: all 4 | **A**: without it a lost or rotated agent key loses its mail | **A** (yes: you can read everything and recover a lost agent key) |
| Q7 | Unlock after a reboot | the owner on his terminal, every boot; agents wait locked | unattended, from a key file | A: all 4 | **A**: B breaks R1 | **B** (unattended, from a key file on the box; R1 exception) |

### 12.1 Reshaping from Q4 B and Q7 B

- **Q4 B (keep today's sudo)**: fleet agents keep `(ALL) NOPASSWD: ALL` and `docker`. The planned separate spec and future lane to strip sudo/docker from fleet agents is dropped. Only the workspace user `spw-<id8>` is created without sudo, without docker, and without `spool-agents`. Section 9 explicitly records the residual risk: any fleet agent has root access and can become the workspace user via sudo or inspect keyd's process memory.
- **Q7 B (unattended unlock from key file)**: overrides the strict terminal `/dev/tty` requirement of R1 for the unattended boot path (owner msg 165607d4). Key file `<state>/keys/unlock.key` (mode 0400, owned by `spw-<id8>`) is read by keyd at startup. Adds build lane L2b (`--key-file` support) and reshapes L6b, L9, L10. Section 9 plainly records that physical disk theft reveals the key file and all ciphertext.

## 13. Panel and consensus

Seat files, each its own commit: `reviews/s136-agy.md` (a-929@sat,
1cd100d91, signed against f33d909e0), `reviews/s136-claude2.md` (c-402,
f8a5bd91e, signed against 1cd100d91), `reviews/s136-grok.md` (g-401,
841f2bb28, signed against dd6796e7b). The editor is s136-claude (c-399).

| decision | agy | claude2 | grok | in v1.0 |
|---|---|---|---|---|
| design (v:3, `encrypted/`, age, keyd, one OS user per workspace) | agree | agree | agree | yes |
| D3 wording "every DM" | agree | agree | change: hub deliver path only, conditional | grok's text (1.1) |
| D5 cite | agree | agree | `287-307` | `287-307` |
| missing clear copies | watchdog transcript/input, agent-inbox, exit gate, desk-reply, argv | sudo journal, tmux server | handoff.md, watchdog transcript/input, argv, readers | P9 widened; P10-P13, W5, W7 added |
| exit gate reads `body` | listed | - | sealed ACCEPTED fails it | FR16, L5b |
| rule 3 also bans argv | - | change | (FR7 addition) | rule 3, FR15 |
| rule 5 per-agent secrecy | - | (C1) | change | rule 5 rewritten; section 4 "Same uid"; section 9 |
| header bound to `ct` | - | **C3, condition to sign** | - | 3.1, FR13 |
| who seals | - | C4 | - | receiving seat seals (3.3); sender seals outbox and pending |
| own tmux server per workspace | - | **C2, condition to sign** | - | 6.2, 6.3, P13, FR14 |
| migration check with the owner key | - | C5: impossible, key off box | - | 8.3 via keyd + owner stanza |
| root today = every agent (`NOPASSWD`, `docker`) | stated | C6 | measured n=2 | section 9 first bullet; Q4 box-wide |
| passphrase env glob | - | sudo-without-tty control | narrow to 3 names | section 5, FR5 |
| `go.mod` shared by L1 and L2 | - | - | L1 owns it, `x/sys` promoted | L1 |
| L7 too big | split a/b | split a/b | split a/b | L7a, L7b |
| L3 too big | - | split a/b | - | L3a, L3b |
| L4 needs `main.go` | - | named | - | named, after L3a |
| files with no lane | agent-inbox, exit gate | - | desk-post, fleet-relay, exit gate, desk-reply, mirror-check, peer-poll, unanswered, dedup | L5b, L5a, L8, L11 |
| L6a, L6b must name files | - | - | tenant_kv, tenant_settings, spawn-window, restore | named |
| L8 scans `sa/` and `.py` | - | yes | peer-poll | yes |
| P5 fix lands at once | in L7b | own lane | in L7b | own lane L0 |
| keyd socket test, spool-send fallback test, OS-user isolation proof | added | `id` without sudo/docker | - | FR6, L5b, L6b |
| language rewrites (8) | given | - | - | taken in sections 0, 1.2, 3.1, 4, 6.1, 11 |
| Q1-Q7 | A x7 | A x7 (Q4: drop docker too) | A x7 | recommendation A x7; owner pending |

Not folded, with the reason:

- s136-agy rewrite 2 ("D3 is of primary concern"): superseded by grok's
  wider D3 text.
- s136-claude2 C4's alternative (sender seals, hub stores `ct`): one
  must be chosen; the receiving seat is chosen because section 9 already
  states the hub sees bodies, and end to end is a follow-up.

Signatures: s136-claude (editor, c-399) signs this text. The three seat
reviews all AGREE with the design; the two conditions to sign (claude2 C2
and C3) and grok's precondition (section 9 names the sibling agent, rule 5)
are in. Each seat confirmed SIGN on `dispatch-6fec05cc` against 15889029a:

| seat | agent | vendor | verdict | spool msg |
|---|---|---|---|---|
| s136-claude (editor) | c-399 | claude | SIGN | this text |
| s136-claude2 | c-402 | claude | SIGN | 8c44e34a |
| s136-agy | a-929@sat | agy | SIGN | 8671bfc7 |
| s136-grok | g-401 | grok | SIGN | 9098bb3b |

Consensus is met (1 agy + 1 grok + 2 claude): the build lanes of section 11
start with no further owner go. The owner's answers to Q1-Q7 (section 12)
still steer each lane where a question touches it.

Doc corrections from build lanes: L0 brief mode and live proof (c-405, msg 7e44f3cf, commit 626ac5529) and section 7 benchmark (c-406, msg 5ff49231, commit 9ff3e5bc3), folded in 7b7469cc5.

v1.1 update (2026-10-26, SPL-3640, a-264): folded the owner's binding answers Q1-Q7 from msg 165607d4. Q4 B reshaped L6b and Section 9 (fleet agents keep sudo/docker; residual risk stated). Q7 B added R1 exception (msg 165607d4) and reshaped Section 4, 5, 11 (unattended key file `<state>/keys/unlock.key`, mode 0400, new lane L2b, boot unlock, stolen disk limit stated). Recorded build lanes landed: L0 (`626ac5529`), L1 (`9ff3e5bc3`), L2 (`a05ea1f24`), L5a (`8b146fa3b`), L6a (`58b7a660f`), L8 (`f541cafda`), L11 (`44c8e21c3`).

<!-- version: 1.1.0 · updated: 2026-10-26 · last-edit: 2026-10-26T22:30:00Z -->
