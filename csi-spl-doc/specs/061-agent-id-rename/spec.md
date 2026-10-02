# 061: agent id rename: `CLE-`/`AGY-`/`GRK-`/`QWN-` become `c-`/`a-`/`g-`/`q-` with 3-digit rolling numbers

Plan: [plan.md](plan.md). Tasks: [tasks.md](tasks.md).
Status: wave A in progress (L1 `internal/agentid` landed). Q3 answered and
the cutoff moved by the owner, 2026-10-02 ~06:50Z (section 7, lane L1b).

## 0. The marker: the old form ends 2026-10-03

> **LEGACY AGENT IDS END AT `2026-10-03T20:59:59Z`** (23:59:59 box local
> time, EEST). After that instant, nothing accepts `CLE-`/`AGY-`/`GRK-`/`QWN-`
> as an agent id on a write path. One dated constant holds this instant, and
> the alias path reads it:
>
> | module | constant | file |
> |---|---|---|
> | Go (hub, `spool` CLI, MCP) | `agentid.LegacyUntil` | `csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go` (new) |
> | bash / python (orc) | `SPOOL_LEGACY_ID_UNTIL` | `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` |
> | WUI | `LEGACY_ID_UNTIL` | `csi-spl-wui/src/utils/agent-id.mjs` (new) |
>
> The Go constant is the source. A gate test (FR-005) fails when the bash or
> WUI copy differs from it. Lane L9 deletes the alias path once the deadline
> has passed.

Owner, 2026-10-02 ~05:58Z: "and leave a mark the old naming convention to be
disgarded at the end of today". Moved back one day by the owner, 2026-10-02
~06:52Z (option "1": "Do it properly."): the hub first keys agents on
`c-NNN@<box>` (section 3.3.1, lane L1b), and only then does per-box numbering
start. The satellite keeps its current ids until the hub keys on `@box`.

## 1. Owner decisions (binding, 2026-10-02 ~05:55Z)

| # | decision |
|---|---|
| D1 | "the CLE-<<n>> should become c-<<n>> with small leter and AGY-<<n>> should become a-<<n>> also with small letter and GRK-<<n>> should become g-<<n>> also with small leter". `QWN-<n>` becomes `q-<n>`, same rule |
| D2 | Rename ALL existing agents: live agents, the registry, the hub roster and the WUI. Old ids keep resolving as aliases, so history and in-flight messages do not break |
| D3 | "lets start all over with no more than 3 digits - aka start from 001 with 0 padding, but 001, 002 and 003 are special so start from 004 etc. when it reaches 999 than roll-over 004" |
| D4 | The aliases are TEMPORARY. They stop being accepted at the end of 2026-10-03 (section 0; moved from 2026-10-02 by the owner at ~06:52Z) |

## 2. The new grammar

| what | regex | example |
|---|---|---|
| agent id | `^[acgq]-[0-9]{3}$` | `c-004` |
| agent at box (spec 058) | `^[acgq]-[0-9]{3}@[a-z0-9][a-z0-9-]{0,31}$` | `c-004@box-desk` |
| legacy agent id (until section 0) | `^(CLE\|AGY\|GRK\|QWN)-[0-9]+$` | `CLE-77952` |
| non-agent participants, UNCHANGED | `^(HUM\|GST\|BOX)-[0-9]+$` | `HUM-17` |

- Letter to kind: `a` agy, `c` claude, `g` grok, `q` qwen. One map, in each
  module's `agentid` file, replaces the 7 prefix-to-kind maps (section 4).
- Numbers are always 3 digits, zero-padded: `c-004`, never `c-4`.
- `000` is never an id. `001`, `002` and `003` are role ids (section 3).
- **Case**: agent ids are lower case and compared case-exactly everywhere.
  Input is normalised ONCE, at the edge (the `spool` CLI flags, the hub API
  decoder, the WUI mention parser, `./run` env vars): `C-004` becomes `c-004`,
  and a legacy id becomes its new id through the alias table (section 5).
  Nothing past the edge lower-cases or upper-cases an id again.
- The old grammar `^[A-Z]{2,4}-[0-9]+$` meant "any participant" (agents, HUM,
  GST, BOX). Every site that uses it calls ONE helper per module instead:
  `agentid.IsAgent`, `agentid.IsParticipant` (Go), `spl_is_agent_id`,
  `spl_is_participant_id` (bash), `isAgentId`, `isParticipantId` (WUI).
- Test-only ids such as `ORC-1` (the dev 3-box proof) are legacy too. They
  move to `c-9NN` fixtures in L9.

## 3. Numbers, roles and rollover

### 3.1 Roles

`c-001` orchestrator, `c-002` master dispatcher, `c-003` failover dispatcher,
exactly as `CLE-001`..`003` today (`SPEC-spool-fleet-roles.md`). They are
claimed (`--claim`), never allocated.

**Decided by the owner (Q1, 2026-10-02 ~10:00Z):** `001`..`003` are reserved for EVERY kind:
`a-001`, `g-001`, `q-001` are never handed out either. One rule for every
kind, and no `a-001` reads like the orchestrator.

### 3.2 Counter

**Decided by the owner (Q2, 2026-10-02 ~10:00Z):** ONE counter per machine,
shared by all kinds. The number alone names one agent on a machine (`c-004` and `a-004`
never coexist), so "004" in a sentence is unambiguous. A per-kind counter
gives each kind its own 996 numbers, but then "004" names up to four agents.

### 3.3 Machines (spec 058): per-box numbering, unique as `c-NNN@<box>`

Owner, 2026-10-02 ~06:50Z (Q3): "the first real work started with the wrong
id the ids should be 00n till 999 with c aka his first number should have
been c-004". There are NO per-machine bands. EVERY machine numbers
`004-999` on its own, starting at `004`, and holds the role ids `001`-`003`
itself. The unique name of an agent is `c-NNN@<box>` (box = the machine's
desk box id, `SPOOL_DESK_BOX`). `c-004@box-desk` and `c-004@<sat box>` are two
different agents. The `SPOOL_AGENT_ID_RANGE` bands of 058 section 3.3
(`1-99999`, `100000-199999`) end with the legacy ids.

Rollover is per machine: `999 -> 004`.

### 3.3.1 The hub keys agents on (id, box), before per-box numbering starts

Owner, 2026-10-02 ~06:52Z: "Do it properly." Lane L1b lands this first.
Until then two machines must not hand out the same number, so per-box
numbering (L4) waits for L1b, and the satellite keeps its current ids.

**Choice: the box is a COLUMN in the key, not a stored `id@box` string.**
The roster (`box_id`), the messages (`to_box`, `from_box`) and the lanes
(`agent_box`) already carry the box as a column, so only the lanes' primary
key widens, and every lookup stays an index equality on two plain columns.
The single-text actor fields that already accept `<ID>@<box>` (the lease
`holder`, 0095; the ask `from_agent`/`acked_by`/`closed_by`, 0097) keep that
form and are written with the box filled in.

Resolve rule for a bare id (no `@box`): the ONE box that holds it in the
roster (or, for lanes, the one lane row). Zero boxes: unknown, as today. Two
or more: refused as ambiguous, naming the candidates
(`c-004 is ambiguous: c-004@box-desk, c-004@<sat box>; add @<box>`).
The migration back-fills every existing row's box from what the hub already
knows (the roster row, the lane's `agent_box`, the writer's hello box).

### 3.4 Rollover is routine, not an edge case

Spawns per day, from the registry
(`cut -f5 /var/spool-hub/registry.tsv | cut -c1-8 | sort | uniq -c`):
48 on 2026-09-30, 142 on 2026-10-01. At 142 a day a machine's line of 996
wraps about every 7 days. So the retire path below is load-bearing from
week one.

### 3.5 Allocation (replaces the max-floor rule of `next-agent-id.sh`)

- A cursor file `$SPOOL_ROOT/agent-id.cursor` (flock) holds the last number
  handed out on THIS machine. The next candidate is `cursor+1`, wrapping from
  `999` to `004`.
- A candidate is skipped while ANY of these hold. This keeps the rule of
  memory note `spawn-id-reuse-trap`: never trust live windows alone, take every
  persisted record.
  1. `$SPOOL_ROOT/<id>` exists (not yet retired);
  2. a `registry.tsv` row for it exists;
  3. `$SPOOL_ROOT/agents/<id>.json` exists (`SPEC-agent-identity-map.md`);
  4. a tmux window carries it;
  5. its retirement is younger than the **quarantine** of 24 h (`SPOOL_ID_QUARANTINE_H`, default 24).
- The claim is still `mkdir` without `-p` (atomic, races lose).
- A full line (every number `004-999` skipped) is exit 1, as today.

### 3.6 Retire: what happens to the previous holder

`do_spl_agent_id_retire <id>` (new action) runs from `/exit-clean`, and from
the reaper for an agent dead for more than `SPOOL_ID_REAP_H` (default 6):

| record | goes to |
|---|---|
| spool dir `$SPOOL_ROOT/<id>/{inbox,outbox,archive}` | `$SPOOL_ROOT/.retired/<id>.<spawned-utc>/`, moved whole. Unread inbox mail is kept there and never handed to the next holder |
| `registry.tsv` row | appended to `registry.retired.tsv` with `retired-utc`, then removed from `registry.tsv` |
| identity record `agents/<id>.json` | `agents/retired/<id>.<spawned-utc>.json`; `index.json` re-hashed |
| hub lane row (0096) | closed by `do_spl_lane_put` state `done` |
| hub DM and channel history | stays. Rows keep `from = c-004`. The generation is the spawned-utc. The hub's agent seat row records `seated_at`, and the WUI shows a divider "new holder since <ts>" in a DM with a reused id (lane L10, after today) |
| tmux window | already closed by `/exit-clean`. A window still open blocks reuse (3.5 rule 4) |

A message that arrives for a retired id inside the quarantine bounces to the
sender as a `reject` ("c-004 retired at <ts>"). It does NOT queue.

### 3.7 One name everywhere (L6, owner 2026-10-02, topic 07af027a)

> "I want to have exactly the same names in the web interface and in the
> terminal." ... "Okay then just do it and if needed restart all of the tmux
> sessions and all of the agents on both of the boxes."

An agent has ONE name, `<id>@<tag>`, e.g. `c-036@abc`: the id, then the
machine's 3-letter box tag (`SPOOL_BOX_TAG` in `<spool root>/box.env`).

| where | what it shows | made by |
|---|---|---|
| `claude --name` | `c-036@abc` | `spool_decorate` (spawn core, restore core, rotation spawn, `@reboot` identity restore, `agent-name-resume.sh`) |
| tmux window | `c-036@abc` first, then an optional badge and title | the same helper (`an_decorate` for renames) |
| the process env | `SPOOL_AGENT_ID=c-036` | the spool harness; a resume goes through `restore-*.sh`, never a bare `claude --resume` |
| `lease.conf`, rotations | `c-001` / `c-002` / `c-003` | `do_spl_role_id_switch` (one role at a time) |
| the web app | `c-036@<hub box id>` | the hub roster |

The old `<tag>: <id>` window shape is no longer written (parsers still read
it). `tests/test-agent-name-shape.sh` fails when a launcher writes another
shape or drops `SPOOL_AGENT_ID`. `do_spl_agent_name_resume` (dry run by
default) lists every live claude whose name or env id differs and resumes it
in its pane, same session.

**The web app gap.** The hub keys a machine on its desk box id
(`SPOOL_DESK_BOX`, section 3.3.1). On the satellite the box id and the tag
are the same (`sat`); on the first machine the box id is `box-desk` and the
tag is another 3-letter word, so the web app reads `c-036@box-desk` there. Closing that
needs one of two changes, and both are the owner's call (spec 058 box ids
are keys in the roster, lanes, asks and leases):
(a) rename that machine's hub box id to its tag, as a migration plus a
desk re-seat, or (b) have the box hello carry the tag and the WUI show it.
Recommended: (a), so one string is both the key and the name.

## 4. Inventory

Every count names the command that produced it, run on origin/master
`7f03bd7a`. Plain `grep` is a shim that skips gitignored files; these use
`command grep`. Shorthand used below:
`G='\[A-Z\]\{2,4\}-|\[A-Z\]\+-\[0-9\]|CLE\|GRK|GRK\|CLE|\(\?:CLE'` and
`X='--exclude-dir=node_modules --exclude-dir=.nuxt --exclude-dir=.output'`.

| area | count | command |
|---|---|---|
| Go regex sites (non-test): `msg.go:60`, `channel_members.go:55`, `fleet_ask.go:77`, `fleet_lease.go:26`, `fleet_lane.go:35`, `issues.go:116` | 6 | `command grep -rnE "$G" csi-spl-api --include=*.go \| grep -v _test.go \| wc -l` |
| Go test files with legacy id literals | 157 | `command grep -rlE '(CLE\|GRK\|AGY\|QWN)-[0-9]+' csi-spl-api --include=*_test.go \| wc -l` |
| rdb CHECK constraints: `0001:50`, `0005:8`, `0047:57`, `0096:18`, `0097:45,50,51` | 5 | `command grep -rnE "~ '\^\[A-Z\]\{2,4\}" csi-spl-rdb \| wc -l` |
| WUI src regex sites (`agent-kind.mjs`, `avatar.mjs`, `channel-feed.mjs`, `channel-members.mjs`, `code-blocks.mjs` x3, `connect-agent.mjs`, `live-ws.mjs`, `mention-autocomplete.mjs`, `mention-poke.mjs`, `notify.mjs`, `tenant-settings.mjs`, `typed-by.mjs`) | 15 | `command grep -rnE "$G" csi-spl-wui/src $X \| wc -l` |
| WUI test files with legacy id literals | 242 | `command grep -rlE '(CLE\|GRK\|AGY\|QWN)-[0-9]+' csi-spl-wui/tests $X \| wc -l` |
| orc bash / python / md regex sites (non-test): `spool-env.inc.sh`, `agent-state.inc.sh`, `agent-identity.inc.sh`, `agent-identity.py`, `spool-mirror.py`, `pane-scan.sh`, `agent-top.sh`, `tmux-close-window.sh`, `kill-your-self-report.sh`, `spool-mcp.sh`, `spool-fleet-relay.sh`, `spool-agent.sh`, `lane-map.sh`, `spawn-core.inc.sh`, `next-agent-id.sh`, about 40 `run/spl-*.func.sh` validators | 87 | `command grep -rnE "$G" csi-spl-orc --include=*.sh --include=*.py --include=*.md \| grep -vE '/tests?/\|\.tst\.sh' \| wc -l` |
| orc test files with legacy id literals | 103 | `command grep -rlE '(CLE\|GRK\|AGY\|QWN)-[0-9]+' csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features/spawn-agents/tests \| wc -l` |
| iac: one hit, a false positive (`AVD-` scanner ids in `sec-scan.func.sh`) | 1 | `command grep -rnE "$G" csi-spl-iac \| wc -l` |
| skills with ids or the count regex (`claude-spawn.md`, `agy-spawn.md`, `grok-spawn.md`, `qwen-spawn.md`) | 4 | `command grep -rlE '(CLE\|GRK\|AGY\|QWN)-[0-9]+\|CLE\|GRK' csi-spl-orc/src/bash/features/spawn-agents/assets \| wc -l` |
| doc/md files with legacy ids (`SPEC-spool-identity-routing.md` section 2 grammar, `SPEC-spool-fleet-roles.md`, `SPEC-agent-identity-map.md`, `claude-agent-setup.ISG.md`, ...) | 27 | `command grep -rlE '(CLE\|GRK\|AGY\|QWN)-[0-9]+' csi-spl-doc/doc \| wc -l` |
| `CLE-001`/`002`/`003` literal sites outside specs | 594 | `command grep -rnE 'CLE-00[123]' . $X --exclude-dir=specs \| wc -l` |
| prefix-to-kind maps | 7 | `command grep -rnE 'CLE\)\|"CLE"\|'"'"'CLE'"'"'\|CLE:' . $X --exclude-dir=specs --include=*.sh --include=*.go --include=*.mjs --include=*.ts --include=*.vue --include=*.py \| wc -l` |
| live box state: `registry.tsv` rows / spool root entries | 245 / 227 | `wc -l /var/spool-hub/registry.tsv`; `ls /var/spool-hub \| wc -l` |
| agent ids used as ticket keys in commit subjects since 2026-10-01 | 104 | `git log --since=2026-10-01T00:00 --format=%s origin/master \| grep -oE '\b(CLE\|AGY\|GRK\|QWN)-[0-9]+' \| sort -u \| wc -l` |

Outside the repo, owned by the orchestrator: the 40-window count regex in the
global `~/.claude/CLAUDE.md`, and the seed prompts of live agents.

## 5. The mapping (written once)

- `do_spl_agent_id_map` (new action, `DRY_RUN=1` by default) writes ONE table,
  `$SPOOL_ROOT/agent-id-aliases.tsv` (`old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc`),
  and the same rows into the hub table `agent_id_aliases` (new rdb migration).
  Every component reads that table and nothing else: the hub, the `spool` CLI,
  the orc scripts, and the WUI through the hub's `GET /api/v1/agent-aliases`.
- Rows: `CLE-001 -> c-001`, `CLE-002 -> c-002`, `CLE-003 -> c-003`. Then
  every LIVE agent on the machine, in `spawned-utc` order, gets the next number
  of its machine's line (`CLE-77922 -> c-004`, ...); the `box` column of the
  row names the machine, so `c-004` on two machines is two rows. Live means a live tmux window AND a
  live identity record. Dead ids get no row. Their history keeps the old id as
  stored text.
- The table is written once and never edited. A second run is a no-op that
  prints the existing rows.

## 6. Functional requirements

| FR | requirement |
|---|---|
| FR-001 | One `agentid` unit per module (Go, bash, WUI) holds the grammar, the letter-to-kind map, the legacy grammar and the `LegacyUntil` constant. Every validation site calls it. No other file carries an id regex. |
| FR-002 | Before `LegacyUntil`, every write path accepts BOTH forms. A legacy id is resolved to its new id through the alias table at the edge, and a legacy id with no alias row is accepted as itself. |
| FR-003 | After `LegacyUntil`, a legacy id on a write path is refused with an error that names the new id when one exists: `CLE-77952 is retired as an id; use c-0NN`. |
| FR-004 | The comparison against `LegacyUntil` reads an injectable clock (`agentid.Now`, `SPOOL_NOW`, a `now` parameter). Every test fixture that still carries a legacy literal pins that clock before the deadline. Without this, CI turns red at 21:00Z on a tree nobody touched. |
| FR-005 | Gate test: the bash `SPOOL_LEGACY_ID_UNTIL` and the WUI `LEGACY_ID_UNTIL` equal the Go `agentid.LegacyUntil` (the same pinning pattern as the emoji list, SPL-1002). |
| FR-006 | Stored rows stay valid. The rdb CHECKs are widened to accept both grammars permanently, because history keeps legacy ids. Only the hub's write path refuses legacy ids after the deadline. |
| FR-007 | Nothing EMITS the new form (allocator, mapping, rename) until FR-001..FR-006 are deployed on dev AND prd and on every machine of the fleet, with the `spool` binary rebuilt. |
| FR-008 | Allocation follows section 3.5 and retirement section 3.6, with tests for rollover (`999 -> 004`), the quarantine skip, every one of the 5 skip rules, and a full band. |
| FR-009 | `<ID>@<box>` keeps working: `c-004@box-desk` in the WUI, the lanes, the asks, the leases, and `inbox-send` / `spool-send`. |
| FR-010 | tmux window names become `c-004 <title>`, with the box tag kept: `<tag>: c-004 <title>`. Until L9 the 40-window count regex is `^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgq]-[0-9]{3}\|(CLE\|GRK\|AGY\|QWN)-[0-9]+)`, then the new form only. Auto-sort orders by spawned-utc, not by number, because numbers wrap. |
| FR-011 | Renaming a live agent moves its spool dir to the new name and leaves `old -> new` as a symlink until L9. It renames the tmux window, rewrites the registry row and the identity record, re-seats its desk on the hub, and sends the agent ONE spool note: "your id is now c-0NN; use --from c-0NN". |
| FR-012 | Role ids move last. `c-001` is taken at the next orchestrator rotation (spec 060: rotation claims `c-001` instead of `CLE-001`). `c-002`/`c-003` are taken at the next dispatch rotation, on the satellite. |
| FR-013 | `do_spl_agent_id_legacy_report` counts legacy ids: hub sends in the last 24 h, live spool dirs, windows, registry rows, lane rows. Lane L8 runs it at the deadline and expects 0. |
| FR-014 | No literal host or domain anywhere, per the distribution-hygiene gate. |
| FR-015 | The hub keys agents on (id, box) (section 3.3.1): roster, lanes, asks and leases hold `c-004@box-desk` and `c-004@<sat box>` side by side, and each one's mail reaches only that agent. A bare id resolves to its single box and is refused when ambiguous. `spool` and the HTTP API accept `<ID>@<box>`. Lands (L1b) before any machine emits per-box numbers (L4). |

## 7. Open owner questions

| Q | question | recommendation |
|---|---|---|
| Q1 | ANSWERED 2026-10-02 ~10:00Z (owner, via CLE-001): `001`-`003` are reserved for every kind. Built as `ID_ROLE_LETTERS=acgq` in `next-agent-id.sh` (L4) | (decided) |
| Q2 | ANSWERED 2026-10-02 ~10:00Z (owner, via CLE-001): one counter per machine, shared by all kinds. Built as `ID_COUNTER=machine` in `next-agent-id.sh` (L4) | (decided) |
| Q3 | ANSWERED 2026-10-02 ~06:50Z: "the first real work started with the wrong id the ids should be 00n till 999 with c aka his first number should have been c-004". Full `004-999` on every machine, unique as `c-NNN@<box>` (section 3.3). ~06:52Z, option "1": "Do it properly." The hub keys on `@box` first (L1b, section 3.3.1); cutoff moved to `2026-10-03T20:59:59Z` | (decided) |
| Q4 | Agent ids are also the ticket key in commit subjects and branch names (104 distinct since yesterday). With rollover, `c-004` names a different lane every few days. What is the commit key now? | branch `c-004-<topic>`; commit scope `(<module>, <topic>)`, for example `(api, agent-id-rename)` |
| Q5 | `@CLE-001` mentions inside OLD message bodies: render them as plain text after the deadline, or rewrite them through the alias table at render time, forever? | plain text; the stored body is history |
| Q6 | Is a 24 h quarantine before an id is reused (section 3.5 rule 5) acceptable? | yes; at 142 spawns a day it holds about 142 of each machine's 996 ids |
| Q7 | The alias CUTOFF is automatic at `2026-10-03T20:59:59Z` (the constant). Deleting the alias code and converting about 500 test files (L9) lands on 2026-10-04, with the clock pinned so CI stays green meanwhile. Accept? | yes |
