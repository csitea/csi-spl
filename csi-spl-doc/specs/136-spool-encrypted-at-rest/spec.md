# 136: Spool messages encrypted at rest (phase 2 of the private workspace)

Status: **v1.0**, the editor's fold of the three seat reviews in `reviews/`
(section 13). Every CHANGE that a seat set as its condition to sign is in.
The owner's answers to Q1-Q7 are pending (section 12); all four seats vote
A on each. Editor s136-claude (c-399). Issue: SPL-1658. v0.1 was 2e21b62db,
measured against 4b1f43b4b on 2026-10-13. This spec changes no code; the
build lanes of section 11 do.

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

What they bind, one line each:

- **R1 (3cfe43ce)** every passphrase (spool keys included) is read ONLY from
  the owner's terminal: a tty, no echo. Never from a chat post, the WUI, a
  spool message, an env var, argv, a file or a pipe.
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
6. **Passphrases on the owner's terminal only** (R1, section 5).
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
  has no terminal (its tool shell has no tty). So the owner unlocks once
  per box start, on his terminal: `spool key unlock --workspace <ws id>`
  (run as the workspace user, `sudo -u spw-<id8>` on his tty; the journal
  then records the command, never the passphrase). It reads the passphrase
  from `/dev/tty` with no echo and hands the opened identities to one
  process, `spool keyd`, running as the workspace OS user. keyd holds them
  in locked memory (`mlock`, `PR_SET_DUMPABLE=0`, no core dump) and answers
  open requests on a unix socket `<state>/keyd.sock` (0600, `SO_PEERCRED`
  uid = the workspace OS user). `spool recv --encrypted --as <id>` asks keyd
  to open the messages whose `for` holds `<id>`. The identities never touch
  disk in clear.
- **Same uid.** The socket check is the workspace OS user's uid. It cannot
  tell two agents of that user apart; keyd opens for the `<id>` the caller
  names. Per-agent secrecy is Q3 B (rule 5, section 9).
- **Lock**: `spool key lock`, a reboot, or a cnf idle timeout (default:
  none) drops them. Until the next unlock `spool recv --encrypted` prints
  `LOCKED: the owner runs 'spool key unlock --workspace <ws id>' on his terminal`
  and exits 5. A spool command never prompts unless stdin and stdout are a
  tty.
- **Sealing needs no unlock**: encryption uses public recipients only. The
  desk sidecar keeps delivering while keyd is locked; incoming mail waits,
  sealed.
- **Rotation**: `spool key rotate --as <id>` makes a new identity; old
  messages stay readable by the old identity (kept in `agents.age`) and by
  the owner. Revoking a leaked agent key = rotate + drop the old identity;
  what that agent already read is in its transcript anyway (section 9).
- **The owner in `for` is Q6 A.** Q6 B is the same `v:3` object with the
  owner left out of `for`; the format does not grow a version for it.

## 5. The passphrase rule (R1)

- Read with `golang.org/x/term` `ReadPassword` on `/dev/tty` only. Refused,
  with an exit code and before any read, when stdin or stdout is not a
  terminal (also under `sudo` with no tty), when `SPOOL_KEY_PASSPHRASE`,
  `PASSPHRASE` or `AGE_PASSPHRASE` is set (those names, not every variable
  whose name contains `PASSPHRASE`), or when argv carries a passphrase flag.
  Asked twice on creation, at least 16 characters, as the local hub DB
  (`guides/local-hub.md` 1.3).
- Never logged, never in a spool message, the WUI, a post, a file or a pipe;
  never in an agent brief. An agent that needs an unlock sends the owner the
  command to run (a blocker), never a request for the passphrase.
- One passphrase per workspace for its agent identities (Q2); the owner
  key has its own.

## 6. Agents dedicated to a workspace (R5)

### 6.1 One OS user per workspace

Unix permissions are the only boundary between processes on the box.
Because all agents run today as one of two shared OS users (1.1), a 0700
directory or a unix socket keeps no other agent out. An `enc` workspace
therefore gets **its own OS user** `spw-<first 8 hex of the workspace id>`
(never its name):

- home 0700, alone in its own group; not in `spool-agents`, `docker` or
  the owner user's group; no sudo (Q4);
- in its home: its spool root (the workspace's fleet root,
  `SPL_WS_SPOOL_ROOT`, already honoured at `spl-desk-up.func.sh:348`), its
  seats, `<state>` with keyd and keys, its own tmux server (6.2) and **its
  agents' CLI transcripts** (1.6);
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

- Seal: one X25519 + ChaCha20-Poly1305 per recipient; expected well under
  1 ms for a 515 B body (p50, 1.1). At 1924 messages a day the added CPU is
  negligible. Proof in L1: a Go benchmark at the p99 size (3631 B) with 3
  recipients, n >= 1000, ns/op reported. Not measured yet.
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

Plainly: **this protects messages at rest from agents of other workspaces,
sweeps and copies of the disk, and only once those agents are not root
(Q4). It does not protect them from root, from the model vendor, from a
sibling agent of the same workspace, or from the agent that reads them.**

- **Root and every sudoer on the box**, which today is every agent of the
  fleet (both agent OS users have `(ALL) NOPASSWD: ALL`, `sudo -n -l`, n=2;
  and both are in the `docker` group, which is root by itself), can become
  the workspace user and read keyd's memory (`/proc/<pid>/mem`, ptrace)
  while it is unlocked, the agent's process memory, its tmux server and
  scrollback, its transcript and the journal (P12). `mlock` and
  `PR_SET_DUMPABLE=0` stop swap and core dumps, not root. Against the agents
  of OTHER workspaces this spec therefore protects only once those agents
  lose sudo and `docker` too: Q4 is a box-wide change, not a per-workspace
  one.
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
| FR5 | a passphrase is read only from a tty; env, argv, pipe, file, sudo without a tty -> refused before any read | pty test + 5 controls (L2) |
| FR6 | keyd: socket 0600, another uid refused (`SO_PEERCRED`), identities never on disk in clear, lock drops them | test with two uids in the CI container (L2) |
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

| lane | files (only these) | test | live proof | needs |
|---|---|---|---|---|
| L0 brief mode | `sa/scripts/spawn-remote.sh` (P5: brief 644 -> 600 only) | a brief file is 600 | one remote spawn, `stat -c %a` -> 600 | - |
| L1 seal format | new `api/internal/enc/` (age seal/open, the inner JSON, header check); `api/internal/msg/msg.go` (`v:3`, `enc`, `for`, `ct`, the name without slug); `api/go.mod`, `api/go.sum` (`filippo.io/age`, `golang.org/x/term`, and `golang.org/x/sys` promoted to direct). No other lane edits `go.mod` or `go.sum`. | FR1, FR3, FR13, the 7 benchmark | - | - |
| L2 keys + keyd | new `api/cmd/spool/key.go`, new `api/internal/keyd/` | FR5, FR6 | the owner unlocks a throwaway workspace on the proof hub; `spool key status` -> unlocked, after `lock` -> locked | L1 |
| L3a store + flags | `api/internal/spool/spool.go`, `api/internal/spool/retired.go`, `api/cmd/spool/main.go` (`--encrypted` on recv/tail) | FR2, FR4, the recv p50 of 7 | two agents of the throwaway workspace exchange 10 sealed DMs; `grep -r <marker>` over every spool root -> 0 | L1, L2 |
| L3b pending + files | `api/internal/hubclient/flush.go`, `api/internal/files/files.go` | sealed pending flushes after unlock; sealed blob round trip | a DM with an attachment while the hub is down, then up | L3a |
| L4 MCP | `api/internal/mcp/mcp.go` and its tool goldens; `api/cmd/spool/main.go` (the MCP server's keyd wiring only, after L3a landed) | FR4 (MCP) | an MCP recv of a sealed DM through keyd | L3a |
| L5a notify + side files | `api/internal/notify/notify.go`, `sa/lib/spool-notify.inc.sh`, `sa/lib/spool-poke-queue.inc.sh`, `sa/lib/spool-asks.inc.sh`, `sa/scripts/spool-agent-hook.sh`, `sa/scripts/spool-mirror.py`, `sa/scripts/agent-mirror-check.py` | FR7 | after L3a: the L3a proof also greps `.pokes`, `.mirror` and the asks dir -> 0 | L1 (tests), L3a (proof) |
| L5b argv + readers | `sa/scripts/spool-send.sh` (stdin body; the hub-down path refuses `enc`), `orc/run/spl-desk-post.func.sh`, `sa/scripts/spool-fleet-relay.sh`, `sa/scripts/kill-your-self-report.sh`, `sa/scripts/agent-inbox.sh`, `orc/scripts/spl-desk-reply.sh`, `orc/run/spl-desk-reply.func.sh` | FR15, FR16, the spool-send fallback refusal | a sealed ACCEPTED ends a proof lane through `/exit-clean` | L3a |
| L6a flag (hub) | the next free `rdb/` migration; `api/internal/store/tenant_kv.go`; `api/internal/hub/tenant_settings.go`; the pin and roster answers (the lane names their files in its first commit, none listed by L1-L5) | the flag round trip, Memory + Postgres | flag on for the throwaway workspace only | - |
| L6b workspace user + seats | new `orc/run/spl-ws-enc-setup.func.sh`; `orc/run/spl-local-hub-agent-join.func.sh`; `orc/run/spl-desk-up.func.sh` (the fleet root of an `enc` seat); `sa/scripts/spawn-window.sh` (`SPAWN_WORKSPACE`, the workspace tmux server); `sa/scripts/restore-core.inc.sh` (a restore keeps the user and server); the 40-window count command | FR10, FR14 + refusal tests | two agents seated as the workspace user; `ps -o user=` shows it; `id spw-<id8>` without `sudo`, `docker`, `spool-agents`; it cannot read `/var/spool-hub/<other agent>` | L6a |
| L7a captures | `orc/run/spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh` (P11 transcript and input included), `spl-dispatch-lease.func.sh` (P11 only) | FR8: each refuses to capture an `enc` pane | rotate one proof agent; nothing of it under `dispatch/wd/ctx` | L6b |
| L7b copies | `orc/run/spl-lane-handover.func.sh`, `orc/run/spl-desk-rebox.func.sh`, `orc/run/spl-agent-handoff.func.sh` (P10), `sa/scripts/agent-id-retire.sh`, `sa/scripts/desk-seat-drop.sh` | FR7 (handoff), FR8 | retire one proof agent; its `.retired/` copy holds only `encrypted/` | L6b |
| L8 sweep gate | new `orc/tests/enc-dirs-untouched.tst.sh`, scanning `orc/`, `sa/` and `.py` (W1-W7, `spl-peer-poll.func.sh` included) | FR9, plus a planted control on a throwaway branch | - | - |
| L9 migrate + rollback | new `orc/run/spl-ws-enc-migrate.func.sh`, new `orc/run/spl-ws-enc-export.func.sh` | FR11 | migrate the proof workspace's clear mail, roll back, read again | L3b, L6b |
| L10 guide | `csi-spl-doc/doc/md/guides/local-hub.md` (a new section) and the agents' help page | `do_check_dist_hygiene` | - | L9 |
| L11 cache writers | `orc/run/spl-unanswered-sweep.func.sh`, `orc/run/spl-msg-dedup.func.sh` | FR9 (W5): no body of an `enc` workspace in a cache file or printed line | - | L6a |

Order: L0, L1, L6a and L8 at once; L2 and L5a after L1; L3a after L2; L3b,
L4 and L5b after L3a; L6b and L11 after L6a; L7a and L7b after L6b; then
L9, then L10. L6b's shape depends on the owner's Q3 and Q4 answers (section
12); the other lanes do not. The owner switches the private workspace
himself, on his terminal, after L10.

## 12. Owner questions

Posted to the owner by the dispatch holder as a poll (c-002, msg 3d302551).
The panel's votes are votes; the owner decides. Lanes start on the
recommendation, and an owner answer that differs reshapes the lanes it names.

| Q | question | A | B | panel | recommendation | owner |
|---|---|---|---|---|---|---|
| Q1 | Cipher | age inside the Go binary (`filippo.io/age`) | gpg (keyrings, gpg-agent) | A: all 4 | **A**: no external process or agent socket, one small dependency, already the local hub's backup format | pending |
| Q2 | Passphrases for agent keys | one per workspace: one unlock opens all its agents | one per agent: the owner types N at each box start | A: all 4 (grok: flips to B if Q3 is B) | **A**: a workspace's agents share its OS user (6.1), so N passphrases add typing, not a wall | pending |
| Q3 | OS users | one per workspace | one per agent | A: all 4 | **A**: walls workspaces apart (R5); per agent costs one vendor login per agent and is the later step if agents of one workspace must not read each other (section 9) | pending |
| Q4 | sudo and `docker` | box-wide: the workspace user AND the fleet's agent users lose `NOPASSWD: ALL` and `docker` | only the workspace user has none; fleet agents keep both | A: all 4 | **A**, with its cost stated: the fleet runs every git and `./run` through `sudo -u <owner user>` today (global CLAUDE.md), so A needs narrow sudoers rules in its place, a separate spec. Until then the wall against other agents is not real (section 9); L1-L11 do not wait for it | pending |
| Q5 | CLI transcripts | in the workspace user's 0700 home, clear (this spec) | also on an encrypted home (gocryptfs, unlocked with keyd) | A: all 4 | **A** now, B as its own spec: B needs the vendor CLIs to start after the unlock | pending |
| Q6 | The owner key in every `for` | yes: the owner reads everything, and recovers | no: only the agents | A: all 4 | **A**: without it a lost or rotated agent key loses its mail | pending |
| Q7 | Unlock after a reboot | the owner on his terminal, every boot; agents wait locked | unattended, from a key file | A: all 4 | **A**: B breaks R1 | pending |

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
are in. Each seat confirms SIGN on `dispatch-6fec05cc` against this sha.

<!-- version: 1.0.0 · updated: 2026-10-13 · last-edit: 2026-10-13T11:00:00Z -->
