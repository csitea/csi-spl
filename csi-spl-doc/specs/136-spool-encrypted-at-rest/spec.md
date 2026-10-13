# 136: Spool messages encrypted at rest (phase 2 of the private workspace)

Status: **v0.1, editor draft** for the panel (section 13). Editor s136-claude
(c-399). Issue: SPL-1658. Measured against origin/master 4b1f43b4b on
2026-10-13. This spec changes no code; the build lanes of section 11 do,
after v1.0.

Paths: `api/` = `csi-spl-api/src/go/spool-hub-api/`, `orc/` =
`csi-spl-orc/src/bash/`, `sa/` = `orc/features/spawn-agents/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`. `<root>` is a spool root
(`SPOOL_ROOT`, default `/var/spool-hub`). `<seat>` is a desk seat,
`<box user home>/.local/share/csi-spl/cloud/<env>/desk/<workspace>/<box>`, or
for the local hub `<home>/.local/share/csi-spl/local-hub/desk/<workspace>/lh-<agent>`
(`orc/run/spl-local-hub-agent-join.func.sh:50,63,71`). `<state>` is the
workspace OS user's state dir (section 6.1). "The private workspace" is the
one the owner runs on the local hub (phase 1, SPL-1620); its name appears
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
  With the separate dir the "encrypted for X, skipped" stub of 0f7b0d3d is
  no longer needed: the plain dirs only ever hold clear-text messages.
- **R4 (7559efa5)** everything is workspace-generic: one workspace turns it
  on now, every workspace on a shared box later, by a flag and not a rewrite.
- **R5 (e6cdd9f3)** agents are dedicated to ONE workspace: a
  workspace-scoped agent, its own key pair, its own encrypted dirs, ideally
  its own OS user. Routers see envelopes only.

## 1. Today, measured: where a message body lands in clear text

Every row was found by the command in its section header, then read.
Nothing in the spool encrypts today:
`grep -rnE 'filippo|ReadPassword|x/term' --include=*.go api` -> no match;
`go.mod` carries `golang.org/x/crypto` for `argon2` only
(`api/internal/auth/password.go:11`); `grep -n x/term api/go.mod` -> none.

### 1.1 The message files themselves (Go)

`grep -nE '^func |WriteFile|CreateTemp|Rename|ReadFile|ReadDir' api/internal/spool/spool.go`

| # | path:line | what lands in clear |
|---|---|---|
| D1 | `api/internal/spool/spool.go:327-338` | `writeBoxRing`: the one inbox/outbox write, `msg.Marshal` then `writeFileAtomic(..., 0o664)` |
| D2 | `api/internal/spool/spool.go:203,234` | `write` = recipient inbox + sender outbox: two copies of every message |
| D3 | `api/internal/spool/spool.go:286-310` | `bridgeFleet`: a THIRD copy into `<fleet root>/<id>/inbox`, 0664, for every agent-to-agent DM a desk receives |
| D4 | `api/internal/spool/spool.go:373-427,565-578` | `Recv --ack` moves the file to `archive/` (rename, or copy across filesystems) |
| D5 | `api/internal/msg/msg.go:286-295` | **the file NAME carries the body**: `<ts>--<from>--<slug of the body, 32 chars>.json` |
| D6 | `api/internal/hubclient/flush.go:283-298,323-333` | `.hub/pending/<stamp>--<msg_id>.json`: the signed wire envelope with the message, moved to `.hub/rejected/` when refused |
| D7 | `api/internal/files/files.go:252-272`, `api/internal/hubclient/hubclient.go:1120` | attachments: content-addressed blobs `<root>/files/<sha256>` |
| D8 | `api/internal/spool/retired.go:75-82` | `BounceRetired`: a reject written to the sender's inbox |

`grep -rnE '\.Deliver(To|Quiet)?\(|WriteOutbox\(' --include=*.go api` finds
the callers: the desk sidecar (`hubclient.go:920`), backfill
(`backfill.go:59`), fallback (`fallback.go:55`), the send flush
(`flush.go:63-72,125,148`).

**D3 matters first for the private workspace.** A local-hub seat is started
by `do_spl_desk_up` (`orc/run/spl-local-hub-agent-join.func.sh:88`) with no
`SPOOL_FLEET_ROOT` (`grep -n FLEET_ROOT` on that file -> none), so the
default applies:
`fleet="${SPOOL_FLEET_ROOT-${SPL_WS_SPOOL_ROOT:-/var/spool-hub}}"`
(`orc/run/spl-desk-up.func.sh:348`). Every DM between two agents of the
private workspace is therefore copied into the shared fleet spool.

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
- `Parse` sets `DisallowUnknownFields` (`msg.go:168-172`): a reader of
  today refuses a file with a new key such as `enc`. With R3 (separate dirs)
  that is a feature: an old binary never meets such a file.
- `Validate` caps the clear body at `MaxBodyBytes` 64 KiB (`msg.go:181,203`).
- Versions: writers emit `v:1`, readers accept 1 and 2 (`msg.go:21-37`,
  `config.go:141`).

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

### 1.4 Pane captures, handoffs, briefs, retired copies

`grep -rn capture-pane orc --include=*.sh | grep -E '>|tee'`,
`grep -rnE '(retired|archive)/' orc | grep -E 'mv |cp '`,
`grep -rnE 'dispatch/' orc --include=*.sh`:

| # | path:line | what |
|---|---|---|
| P1 | `orc/run/spl-lane-restart.func.sh:109` | 300 screen lines to `<hold dir>/<task>/<id>.pane.txt` |
| P2 | `orc/run/spl-rotate-lib.func.sh:455,474`, `orc/run/spl-lane-rotate.func.sh:624`, `orc/run/spl-wd-takeover.func.sh:274`, `orc/run/spl-peer-restart.func.sh:207`, `orc/run/spl-orch-rotate.func.sh:246` | 60 screen lines into a handoff file |
| P3 | `orc/run/spl-watchdog.func.sh:828` | screen to `<tick dir>/pane` (`:1381` is a temp file, removed at `:1383`) |
| P4 | `orc/run/spl-lane-handover.func.sh:115-117,295` | handover brief with the last message's body verbatim, then `<root>/handover/<to>-from-<from>.md` |
| P5 | `sa/scripts/spawn-remote.sh:210-211` | remote spawn brief `<state dir>/briefs/<msg>.md`, **chmod 644** |
| P6 | `sa/scripts/agent-id-retire.sh:118-124` | the whole `<root>/<ID>` moved to `<root>/.retired/<ID>.<utc>/`, dir 2775 |
| P7 | `sa/scripts/desk-seat-drop.sh:93`, `orc/run/spl-desk-rebox.func.sh:204` | seat spools moved to `.retired/` and `rebox-retired/` |
| P8 | `/var/spool-hub/dispatch/` (no writer in code: `grep -rnE 'c002\|briefs/' orc` finds none) | hand-written post drafts and briefs (`ls /var/spool-hub/dispatch \| wc -l` -> 4779), read by `orc/lib/bash/funcs/spl-desk-body-file.func.sh:27` (`DESK_BODY_FILE`) |
| P9 | `orc/run/spl-desk-post.func.sh:43-44,81`, `sa/scripts/spool-fleet-relay.sh:119,125` | the body as `--body` argv: visible in `/proc/<pid>/cmdline` while it runs |

### 1.5 Sweeps and readers that would touch a body

| # | path:line | what |
|---|---|---|
| W1 | `orc/run/spl-lane-rotate.func.sh:261,263` | classifier: `grep '"body": "ACCEPTED…'` over `inbox/*.json archive/*.json` |
| W2 | `orc/run/spl-peer-poll.func.sh:369-370,388,449` | jq over inboxes, rewrites archive copies |
| W3 | `sa/lib/spool-notify.inc.sh:157,535` | reads inbox / `archive/*-<msgid8>.json` |
| W4 | `orc/scripts/spl-desk-reply.sh:148` | reads `<seat>/spool/<agent>/inbox` |
| W5 | `orc/run/spl-unanswered-sweep.func.sh:280,291,454`, `spl-msg-dedup`, `spl-search-*`, `spl-public-dataset-load`, `spl-topic-copy-cross` | hub-side bodies (DB), cached to files; the local hub's DB is already encrypted at rest (phase 1); these are file caches of it |
| W6 | `sa/scripts/spool-mirror.py:56,490`, `sa/scripts/agent-mirror-check.py:139` | glob every seat spool |

### 1.6 Outside the spool: the model's own record

Not in this repo, and the largest copy: every body an agent reads (recv
output, hook context, a pasted poke) is in its CLI session transcript, e.g.
`~/.claude/projects/<slug>/<session>.jsonl`, in clear, owned by the agent's
OS user. Measured: the per-project dirs are `0700`, but every agent of the
fleet runs as the same one or two OS users, so they can read each other's
transcripts. `sa/scripts/spool-session-export.py:97-102,130` exports them.
And the body leaves the box: the model vendor's API receives it in clear on
every turn (section 9).

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
   in clear (rows D1..D8, S1..S9, P1..P9).
4. **Header only outside `encrypted/`.** The plain envelope (3.1) may
   appear in pokes, logs and journals; the body may not.
5. **Decrypt in memory, for the addressed agent.** Only `spool recv
   --encrypted`, `spool tail --encrypted` and their MCP equivalents decrypt;
   they print to stdout and write nothing back to disk.
6. **Passphrases on the owner's terminal only** (R1, section 5).
7. **Sweeps never open `encrypted/`.** A gate test enforces it (L8).
8. **No hard-coded workspace** anywhere: the flag, recipients and dirs are
   per workspace, looked up, never named in code or cnf (R4; the name is
   private).

## 3. Data: the envelope and the "encrypted" dirs

### 3.1 The sealed message (`v:3`)

```json
{"v":3,"msg_id":"…","task_id":"…","ts":"…","from":"c-101","to":"c-102","kind":"note",
 "enc":"age","for":["c-102","c-101","HUM-1"],"ct":"<base64 age ciphertext>","files":[]}
```

- `v:3` is new; `body` is absent (not empty), so no reader can take it for
  a message with an empty body. `Parse` of today refuses the file (unknown
  keys), which is safe: only `encrypted/` holds it.
- `enc`: the scheme, `"age"` (section 4). `for`: every identity that can
  open it: the addressed agent, the sender (its outbox copy) and the
  workspace owner (recovery, Q6). The header shows who talks to whom, the
  task and the time: accepted (section 9).
- `ct`: the age ciphertext of the inner JSON `{"body":"…","files":[…]}`.
  Attachment metadata goes inside; the outer `files` stays empty.
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

### 3.3 Fan-out

A sealed message is delivered only to the inbox of its addressed agent on
the box; the sender keeps the outbox copy. A channel post of an `enc`
workspace is sealed once per member delivery, to that member plus the owner,
so one member's copy names no other member. OD seats and dispatchers of
other workspaces get nothing, not even a stub (R3). The poke (S1) for a
sealed message is one header-only line:
`: 'SPOOL c-102: note from c-101 task <id> msg <id> :: encrypted :: run: spool recv --encrypted --as c-102'`.

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
  `<state>/keys/<id>.pub` is pinned on the seat and published to the hub
  with the seat, beside today's Ed25519 box key
  (`api/internal/sign/sign.go:1-27`), so every seat can seal to every member.
- **Owner key**: one age identity per workspace for the owner, made on his
  terminal under his own passphrase, its secret part moved OFF the box like
  the backup identity (`csi-spl-doc/doc/md/guides/local-hub.md` 7.1). Only
  its recipient stays on the box. Every sealed message names it in `for`:
  the owner can read everything, also after an agent and its key are gone.
- **The key holder, `spool keyd`**: an agent never types a passphrase and
  has no terminal (its tool shell has no tty). So the owner unlocks once
  per box start, on his terminal: `spool key unlock --workspace <ws id>`. It
  reads the passphrase from `/dev/tty` with no echo and hands the opened
  identities to one process, `spool keyd`, running as the workspace OS user.
  keyd holds them in locked memory (`mlock`, `PR_SET_DUMPABLE=0`, no core
  dump) and answers open requests on a unix socket `<state>/keyd.sock`
  (0600, `SO_PEERCRED` uid = the workspace OS user). `spool recv
  --encrypted --as <id>` asks keyd to open the messages whose `for` holds
  `<id>`. The identities never touch disk in clear.
- **Lock**: `spool key lock`, a reboot, or a cnf idle timeout (default:
  none) drops them. Until the next unlock `spool recv --encrypted` prints
  `LOCKED: the owner runs 'spool key unlock --workspace <ws id>' on his terminal`
  and exits 5. A spool command never prompts unless stdin and stdout are a
  tty.
- **Sealing needs no unlock**: writing a message uses recipients only. A
  desk sidecar keeps delivering while keyd is locked; mail waits sealed.
- **Rotation**: `spool key rotate --as <id>` makes a new identity; old
  messages stay readable by the old identity (kept in `agents.age`) and by
  the owner. Revoking a leaked agent key = rotate + drop the old identity;
  what that agent already read is in its transcript anyway (section 9).

## 5. The passphrase rule (R1)

- Read with `golang.org/x/term` `ReadPassword` on `/dev/tty` only. Refused,
  with an exit code and before any read, when stdin or stdout is not a
  terminal, when an env var `SPOOL_KEY_*` or `*PASSPHRASE*` is set, or when
  argv carries a passphrase flag. Asked twice on creation, at least 16
  characters, as the local hub DB (`guides/local-hub.md` 1.3).
- Never logged, never in a spool message, the WUI, a post, a file or a pipe;
  never in an agent brief. An agent that needs an unlock sends the owner the
  command to run (a blocker), never a request for the passphrase.
- One passphrase per workspace for its agent identities (Q2); the owner
  key has its own.

## 6. Agents dedicated to a workspace (R5)

### 6.1 One OS user per workspace

Unix permissions are the only wall between two processes of the same user.
Today every agent runs as one of two OS users (1.1), so a 0700 dir or a
keyd socket keeps no other agent out. An `enc` workspace therefore gets
**its own OS user** `spw-<first 8 hex of the workspace id>` (never its
name):

- home 0700, alone in its own group, not in `spool-agents`, no sudo (Q4);
- in its home: its spool root (the workspace's fleet root,
  `SPL_WS_SPOOL_ROOT`, already honoured at `spl-desk-up.func.sh:348`), its
  seats, `<state>` with keyd and keys, and **its agents' CLI transcripts**
  (1.6);
- its own vendor CLI logins (one login shared by two users splits on token
  refresh); the owner logs each vendor in once, on his terminal.

Per-agent OS users (Q3) are stronger, and cost one vendor login per agent.

### 6.2 Routing and placement

- The workspace's dispatcher and its lanes are agents of that workspace,
  running as its OS user. The fleet orchestrator places a lane with
  `SPAWN_WORKSPACE=<ws id>` (never the name); the launcher starts it as the
  workspace user, in a tmux window the owner still reaches with tmux.
- A cross-workspace router, if kept, sees envelopes only: it reads the
  sealed file's header, never `ct`, and holds no identity.
- `SPOOL_FLEET_ROOT` of an `enc` seat is the workspace's own spool root;
  `do_spl_local_hub_agent_join` passes it (fixes D3).

### 6.3 How many agents a box hosts

The fleet ceiling stays **40 concurrent agent windows per box**, counted
across all workspaces with the existing count (global CLAUDE.md, "Spawn an
agent"). Each workspace also has a cap in its private config,
`WS_AGENT_MAX` (default 4: one dispatcher, up to three lanes); a spawn past
either cap is refused. Fixed cost per workspace: one OS user, one keyd (a
few MB), one tmux session, its vendor logins. At 4 per workspace one box
hosts up to 10 workspaces; vendor quota and CPU bind first, as today.

## 7. Performance

- Seal: one X25519 + ChaCha20-Poly1305 per recipient; expected well under
  1 ms for a 515 B body (p50, 1.1). At 1924 messages a day the added CPU is
  negligible. Proof in L1: a Go benchmark at the p99 size (3631 B) with 3
  recipients, n >= 1000, ns/op reported.
- Unlock: one scrypt (age's default work factor, about 1 s) per unlock,
  because one `agents.age` holds all of a workspace's identities.
- `recv --encrypted`: one socket round trip to keyd per message; target p50
  < 5 ms per message, measured in L3 (n >= 100).
- Size: about 1.4x per file plus 200 B per recipient; at 1924 messages x 3
  copies x about 1 KB a day, disk is no limit.

## 8. Migration and rollback

1. **Flag**: a workspace setting `spool_enc` (bool, default false) on the
   hub, one migration. The private workspace's row exists only in the local
   hub's DB, so its name never reaches the public repo. The seat learns the
   flag at pin time and from the roster; a seat of an `enc` workspace
   refuses to start without its recipients and its workspace OS user.
2. **Turning on**: workspace user + keys (`do_spl_ws_enc_setup`, owner's
   terminal) -> seats re-joined as the workspace user -> flag on -> new mail
   is sealed.
3. **Existing clear mail**: `do_spl_ws_enc_migrate` seals every clear file of
   that workspace's seats and of `/var/spool-hub/<its agents>/` into
   `encrypted/`, checks that each opens with the owner key, deletes the clear
   file, and lists for the owner the side copies of 1.3/1.4 it found.
   Deletion on ext4 is not erasure (journal, free blocks): stated in
   section 9, not hidden.
4. **Rollback**: flag off -> new mail is clear again, in the plain dirs.
   Sealed files stay sealed and readable with `--encrypted` while keyd is
   unlocked. `do_spl_ws_enc_export` (owner's terminal) writes a decrypted
   copy only where the owner names it. No code decrypts back into the plain
   dirs on its own.
5. **The generic switch later (R4)**: `enc` as the default for every
   workspace on a shared box = the flag's default plus one OS user per
   workspace. Nothing in sections 3-6 names a workspace.

## 9. Honest limits (c-374's trust note, extended)

Plainly: **this protects messages at rest from other agents, other
workspaces, sweeps and copies of the disk. It does not protect them from
root, from the model vendor, or from the agent that reads them.**

- **Root and every sudoer on the box**, which today includes every agent OS
  user, can become the workspace user and read keyd's memory
  (`/proc/<pid>/mem`, ptrace) while it is unlocked, the agent's process
  memory, its tmux pane and scrollback, and its transcript. `mlock` and
  `PR_SET_DUMPABLE=0` stop swap and core dumps, not root. For data root must
  not see: a box only the owner administers, and agents without sudo (Q4).
- **The model vendor** receives every body an agent reads, in clear, on
  every turn; the transcript keeps it on disk under the workspace user
  (1.6). Encrypting transcripts is outside this spec (Q5).
- **The envelope** (from, to, task, kind, time, recipients) is clear by
  design (R2): who talks to whom, and when, stays visible.
- **The hub** handles bodies in clear in its process and its DB; the local
  hub keeps that DB encrypted at rest (phase 1). A cloud hub is out of scope.
- **Clear copies deleted at migration** may remain in ext4 free blocks and
  the journal.
- **The owner's identity** is as safe as the place he keeps it off the box.

## 10. Functional requirements

| FR | requirement | proof (lane) |
|---|---|---|
| FR1 | a plain workspace writes byte-identical files to today | golden test of `Marshal` and the file name (L1) |
| FR2 | an `enc` message is written only under `encrypted/`, as `v:3` with no `body`, its file name free of body text | Go test: grep the whole spool tree for a marker body -> 0 hits (L3) |
| FR3 | only the `for` identities and the owner key open it; any other identity fails | Go test (L1) |
| FR4 | plain `spool recv` / `tail` / MCP never list `encrypted/`; `--encrypted` shows only the caller's messages | Go tests (L3, L4) |
| FR5 | a passphrase is read only from a tty; env, argv, pipe, file -> refused before any read | pty test + 4 controls (L2) |
| FR6 | keyd: socket 0600, another uid refused, identities never on disk in clear, lock drops them | test with two uids in the CI container (L2) |
| FR7 | no poke, notices log, mirror, ask summary, hook context or notify stdin carries an `enc` body | bash tests with a marker body (L5) |
| FR8 | no capture, handoff, handover brief, retire or rebox copies an `enc` agent's screen or body in clear | bash tests (L7) |
| FR9 | no sweep or classifier reads under `encrypted/` | gate test over every reader in orc/ (L8) |
| FR10 | an `enc` seat's fleet root is its workspace's; the shared fleet root gets nothing | orc test (L6b) |
| FR11 | migrate seals all clear files of the workspace, verifies, deletes; after rollback the sealed files still open | orc test + live proof (L9) |
| FR12 | no workspace name in code, cnf, test or doc | `do_check_dist_hygiene` (every lane) |

## 11. Build split (after v1.0)

Small lanes, disjoint files. Routing kind `secret` (claude, grok or mistral;
never qwen or agy), because the lanes handle key code. No brief names a key
path or the name of the private workspace.

| lane | files (only these) | test | live proof | needs |
|---|---|---|---|---|
| L1 seal format | new `api/internal/enc/` (age seal/open, the inner JSON); `api/internal/msg/msg.go` (`v:3`, `enc`, `for`, `ct`, the name without slug); `api/go.mod`, `api/go.sum` (`filippo.io/age`, `golang.org/x/term`) | FR1, FR3, the 7 benchmark | - | - |
| L2 keys + keyd | new `api/cmd/spool/key.go`, new `api/internal/keyd/` | FR5, FR6 | the owner unlocks a throwaway workspace on the proof hub; `spool key status` -> unlocked, after `lock` -> locked | L1 |
| L3 store | `api/internal/spool/spool.go`, `api/internal/spool/retired.go`, `api/internal/hubclient/flush.go` (pending), `api/internal/files/files.go`, `api/cmd/spool/main.go` (`--encrypted` on recv/tail) | FR2, FR4, the recv p50 of 7 | two agents of the throwaway workspace exchange 10 sealed DMs; `grep -r <marker>` over every spool root -> 0 | L1, L2 |
| L4 MCP | `api/internal/mcp/mcp.go` and its tool goldens | FR4 (MCP) | an MCP recv of a sealed DM through keyd | L3 |
| L5 side channels | `api/internal/notify/notify.go`, `sa/lib/spool-notify.inc.sh`, `sa/lib/spool-poke-queue.inc.sh`, `sa/lib/spool-asks.inc.sh`, `sa/scripts/spool-agent-hook.sh`, `sa/scripts/spool-mirror.py`, `sa/scripts/spool-send.sh` (the hub-down path refuses `enc`) | FR7 | the L3 proof also greps `.pokes`, `.mirror` and the asks dir -> 0 | L1 |
| L6a flag (hub) | the next free `rdb/` migration; the workspace settings store; the pin and roster answers | the flag round trip, Memory + Postgres | flag on for the throwaway workspace only | - |
| L6b workspace user + seats | new `orc/run/spl-ws-enc-setup.func.sh`; `orc/run/spl-local-hub-agent-join.func.sh`; `orc/run/spl-desk-up.func.sh` (the fleet root of an `enc` seat); the launcher's `SPAWN_WORKSPACE` | FR10 + refusal tests | two agents seated as the workspace user; `ps -o user=` shows it | L6a |
| L7 captures + copies | `orc/run/spl-lane-restart.func.sh`, `spl-rotate-lib.func.sh`, `spl-lane-rotate.func.sh`, `spl-wd-takeover.func.sh`, `spl-peer-restart.func.sh`, `spl-orch-rotate.func.sh`, `spl-watchdog.func.sh`, `spl-lane-handover.func.sh`, `spl-desk-rebox.func.sh`; `sa/scripts/spawn-remote.sh`, `sa/scripts/agent-id-retire.sh`, `sa/scripts/desk-seat-drop.sh` | FR8 | rotate one proof agent; its handoff carries no screen | L6b |
| L8 sweep gate | new `orc/tests/enc-dirs-untouched.tst.sh` | FR9, plus a planted control on a throwaway branch | - | - |
| L9 migrate + rollback | new `orc/run/spl-ws-enc-migrate.func.sh`, new `orc/run/spl-ws-enc-export.func.sh` | FR11 | migrate the proof workspace's clear mail, roll back, read again | L3, L6b |
| L10 guide | `csi-spl-doc/doc/md/guides/local-hub.md` (a new section) and the agents' help page | `do_check_dist_hygiene` | - | L9 |

One plain-workspace fix can land at once, with no format change: P5,
`spawn-remote.sh` brief mode 644 -> 600 (inside L7's files).

Order: L1, L6a and L8 in parallel; L2 and L5 after L1; L3 after L2; L4 and
L6b after L3 and L6a; L7 after L6b; then L9, then L10. Every live proof
runs on the throwaway proof hub with a throwaway workspace, never the
private one. The owner switches the private workspace himself, on his
terminal, after L10.

## 12. Owner questions

| Q | question | A | B | recommendation |
|---|---|---|---|---|
| Q1 | Cipher | age inside the Go binary (`filippo.io/age`) | gpg (keyrings, gpg-agent) | **A**: no external process or agent socket, one small dependency, already the local hub's backup format |
| Q2 | Passphrases for agent keys | one per workspace: one unlock opens all its agents | one per agent: the owner types N at each box start | **A**: a workspace's agents share its OS user (6.1), so N passphrases add typing, not a wall |
| Q3 | OS users | one per workspace | one per agent | **A**: per agent costs one vendor login per agent; per workspace already walls workspaces apart, which is the ask (R5) |
| Q4 | sudo for a workspace's agents | none: the workspace user has no sudo | keep today's sudo | **A** for an `enc` workspace: with sudo any of its agents reads every other workspace's keyd (section 9) |
| Q5 | CLI transcripts | in the workspace user's 0700 home, clear (this spec) | also on an encrypted home (gocryptfs, unlocked with keyd) | **A** now, B as a follow-up spec: B needs the vendor CLIs to start after the unlock |
| Q6 | The owner key in every `for` | yes: the owner reads everything, and recovers | no: only the agents | **A**: without it a lost agent key loses its mail |
| Q7 | Unlock after a reboot | the owner on his terminal, every boot; agents wait locked | unattended, from a key file | **A**: B breaks R1 |

## 13. Panel

Seats (c-001 places them once this draft is on master): 1 agy, 1 grok, 1
more claude, plus this editor. Each writes `reviews/s136-<seat>.md`: AGREE,
CHANGE with the exact new text, or DISAGREE per section, evidence cited. The
editor folds them into v1.0 once at least 1 agy + 1 grok + 2 claude agree;
the build lanes of section 11 then start with no further owner go.

<!-- version: 0.1.0 · updated: 2026-10-13 · last-edit: 2026-10-13T12:30:00Z -->
