# Spec 165: Antigravity as an Orchestrator/Dispatcher Vendor and Read-Only Watcher Seats

Version **v0.3** (2026-10-30). v0.1 by seat `a-591` (Antigravity, `7350c51bb`;
its header said v1.0 by mistake: it was never signed). v0.2 by `c-672`
(claude, the backup vendor while a-591 is on its usage limit), fixing the R7
FAIL of `c-599` (findings W1..W11). v0.3 by `c-637` (claude, the backup
vendor) folds the owner's answers to poll fda1ec04: **Q0 = A, Q1 = A (not in
force), Q2 = A** (section 6), and re-gates the build rows (section 5).
Change log in section 8.
Epic: **SPL-1308** (Orchestration across boxes). Issue: **SPL-4172**; v0.3:
**SPL-4334** (epic SPL-2398).
Kind: **specs_and_docs**. Reports to the dispatch lease holder on task
`dispatch-6aeebb4d`.
Every `file:line` cite below is read at `origin/master` `5df9c0ead`. v0.3
re-read the cites it leans on at `3946afc21`: `all.env.yaml:1298`
(`orchestration:  { claude: 65, grok: 35, backup: grok }`),
`agent_split.py:21-22` (`SECRET_KINDS`, `SECRET_VENDORS`) and
`test_agent_split_by_kind.py:131-140`; the others are not re-read.

**Scope after Q0 = A.** agy stays on the dispatch seats. This spec builds the
read-only watcher seats (section 3) and shadow scoring against the dispatch
seats (section 4). agy in the orchestrator seat (v0.2's section A paths for
Q0 B or C) is **out of scope**; it would need a new owner answer and a new
version of this spec.

---

## 0. Owner Asks and Baseline Facts

### 0.1 The Owner's Order (HUM-10, Verbatim)

From prd topic `6aeebb4d-5dca-4a49-8257-bf1122133147` (#refactoring), msg `5c62817c-e63f-4e3c-9b8d-b39be052b6af`:

> "Well, we should start also teaching Antigravity how to be the orchestrator as well. [...] We would need a capability for \"watcher seeds\" (aka agents), which will be read-only, and they will be only watching what the other agents are doing."

Three parts follow from it:
1. **Antigravity (agy) in the role seats**: agy already holds the dispatch
   seats (0.2); the order asks for the orchestrator seat too. The owner's Q0
   answer A keeps orchestration secret-class, so agy stays on the dispatch
   seats only (section 6).
2. **Watcher seats ("watcher seeds")**: a new seat kind that only reads,
   with read-only enforced by the OS, not by the prompt.
3. **Shadow training**: a watcher shadows the live seats and scores what it
   would have done. Under Q0 = A it shadows the dispatch seats and non-secret
   lanes, never the orch seat.

### 0.2 Baseline Facts on `origin/master` (measured 2026-10-30)

- **Role seats and letters**: `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md`
  section 1. A role seat's number (`001`..`003`) is fixed; the letter is the
  vendor. `SPL_ROLE_SEAT_RX='[acgmq]-00[1-3]'` (`spool-env.inc.sh:221`)
  already accepts `a-001`..`a-003`.
- **agy already holds the dispatch seats (not new)**: `ROTATE_ROLE_VENDOR=agy`
  rotates agy into the dispatch seats, owner poll aed5a733 answer C
  ("live with a net"), SPL-3395 (`spl-rotate-lib.func.sh:145-148`). The
  orchestrator seat stays claude|grok: `spl-rotate-lib.func.sh:155-158`.
- **Orchestration is secret-class by owner order**: `agent_split.py:19-22`
  puts `orchestration` in `SECRET_KINDS` with `secret`, citing owner msgs
  a1e5c678 and ff1baf01; only `SECRET_VENDORS = ("claude", "grok",
  "mistral")` may be non-zero or the backup there (`agent_split.py:95-103`).
  agy never takes secret-class work (the data rule, global CLAUDE.md).
- **cnf row**: `csi-spl-cnf/csi-spl/all.env.yaml:1298`
  `orchestration: { claude: 65, grok: 35, backup: grok }`; the data-rule
  comment is `:1270-1279`.
- **The orch drill is planned, not built**: `do_spl_orch_drill` exists only
  as a plan row, `orch-panel-plan.md:192,234` (row O2). O2 sets agy's pass
  line: per task the median within 2x claude's and at least 90% right, after
  2026-10-30.
- **Watcher seats**: none exist. `git grep -n -i watcher -- csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`
  finds only the lease watcher (`:805`, `:982`), which is unrelated.
- **Agents have sudo**: `sudo -l -U <HARNESS_USER>` prints
  `(ALL) NOPASSWD: ALL`, and agents run git as `sudo -u <REPO_USER>`. So file
  modes (`chmod a-w`, a read-only worktree) bind nobody who runs as the
  harness user.

---

## 1. Goals and Non-Goals

### 1.1 Goals

| ID | Goal | Measured By |
|---|---|---|
| ~~**G1**~~ | **Out of scope (Q0 = A)**: agy in the orchestrator seat `a-001`. agy keeps the dispatch seats `a-002`/`a-003` it already rotates into (0.2). | none |
| **G2** | **cnf keeps Q0 = A**: `orchestration` stays secret-class; the validator and the cnf row do not change. | `test_agent_split_by_kind.py:131-140` (`test_orchestration_outside_claude_grok_and_mistral_is_red`) stays green: `orchestration` with agy non-zero or as backup is red; `secret` still refuses agy. |
| **G3** | **Read-only enforced by the OS**: a watcher cannot write a repo, push, take, post to a desk, spawn, or send as another seat. The boundary is a dedicated OS user (Q2 = A), and the tool gates key on the process chain, never on an id the caller sets. | `watcher-read-only.tst.sh`: every mutation attempt fails, including with `AGENT_ID`, `DESK_AGENT` or `--from` set to another seat's id. |
| **G4** | **Observation feed that obeys the data rule**: the watcher reads a snapshot written by a privileged producer, filtered so no secret-class lane and no orch seat output reaches an agy watcher. | Feed test: a secret-kind lane's pane and outbox, and the orch seat's, are absent from the feed. |
| **G5** | **Shadow scoring with one pass line**: the O2 line (90% right), on measured sources, with a safety violation scoring 0, against the dispatch seats. | `orch-shadow-eval.tst.sh` on fixtures; `/var/spool-hub/watchers/shadow-decisions.jsonl`. |

### 1.2 Non-Goals

- **agy never gets a key or a key path**: no GCP SA key, no `CLOUDSDK_CONFIG`,
  no `do_spl_db_query` (it runs with the env SA key).
- No secret-class work for agy (`secret` and `orchestration` stay
  claude|grok|mistral in the validator).
- **agy in the orch seat** (Q0 = A): no orch rotation, drill or cnf share for
  agy is built here.
- The orch seat stays with its current vendors. grok is off fleet-wide by
  the later owner order 0d5b1e8a (section 6, Q1); this spec changes no role
  seat's vendor.
- A watcher never posts into an owner-facing or customer-facing WUI topic.

---

## 2. Section A: Antigravity in the Role Seats

### 2.1 What Each Role Requires from Its Vendor

#### 2.1.1 The Orchestrator Role (`a-001`)
`SPEC-spool-fleet-roles.md` section 1. The vendor must:
1. Place lanes: read the ask, check `lane-map.sh` and `do_spl_box_pick`, spawn.
2. Hold the orch lease.
3. Ingest asks (`do_spl_orch_inbox`).
4. Rotate hourly: quiesce, read the handoff, ACK with
   `ROTATE_CMD=ack ROTATE_ID=<rid> do_spl_orch_rotate`.
5. Verify without mutating prd; a prd op runs only on an owner go.
6. Close finished lanes.

#### 2.1.2 The Dispatcher Roles (`a-002`, `a-003`)
agy already holds these (0.2). Sections 3 and 4 of
`SPEC-spool-fleet-roles.md`: take a human post within 180 s, reply in the
desk, route work to lanes, fail over on a dropped lease, escalate prd ops.

### 2.2 The Data Rule Decides Section A First (W1)

Making `orchestration` non-secret would reverse an owner order (a1e5c678,
ff1baf01), so owner question Q0 (section 6) came before any section A build
row. **The owner answered A** (msg 8da780d7, poll fda1ec04):

| Q0 answer | What agy may do | Rows |
|---|---|---|
| **A. Keep** orchestration secret-class (**decided**) | agy stays on the dispatch seats only (as today). A watcher may shadow the dispatch seats and non-secret lanes, never the orch seat. | B1 verify only; B4..B8 built; B2, B3 and B9 not built. |
| ~~B. Lift it for agy~~ | Out of scope: not chosen. | none |
| ~~C. Split orchestration~~ | Out of scope: not chosen. | none |

### 2.3 Today's Gaps (with `file:line` at `5df9c0ead`)

Kept as the record of v0.2's analysis. Under Q0 = A, **none of A1..A5 is a
gap to close**: A1 and A2 are the data rule working as decided, and A3..A5
only matter for agy in the orch seat, which is out of scope. A6, A8 and A9
are not measured here (row B9 is not built). They also describe agy on the
dispatch seats it already holds. If they need measuring there, that belongs
to a dispatch-seat lane outside this spec.

#### Gap A1: The validator keeps agy out of orchestration
`agent_split.py:21-22, 95-103`: `orchestration` is in `SECRET_KINDS`; a
non-zero agy or an agy backup raises
`"{kind}: only claude, grok and mistral may be non-zero or the backup"`.
This is the owner's data rule working as designed (2.2), not a defect.

#### Gap A2: The cnf row
`all.env.yaml:1298` `orchestration: { claude: 65, grok: 35, backup: grok }`;
comment `:1270-1279`.

#### Gap A3: The orch rotation refuses agy
- `spl-rotate-lib.func.sh:155-158`: agy for any family but `dispatch` gives
  `ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=agy is for the dispatch seats only, not the ${1:-orch} seat: claude"`.
- `spl-orch-rotate.func.sh:298-301`: the lane-mix pick is accepted only for
  `claude|grok|mistral`; anything else falls back to claude.

#### Gap A4: The agy guard tests a proxy kind
`spl-rotate-lib.func.sh:208-211`: `spl_rotate_agy_why` runs lane-mix with
`LANE_MIX_KIND=specs_and_docs`. `spl_role_failover_guard` already uses
`LANE_MIX_KIND=orchestration` for agy (`spl-role-failover.func.sh:172-180`).
v0.2 would have matched the rotation guard to it under Q0 B or C; under
Q0 = A the rotation guard stays as it is.

#### Gap A5: Cold dispatch setup spawns claude
`spl-dispatch-setup.func.sh:444-446` passes the literal `claude` to
`spawn-window.sh`, whatever `ROTATE_ROLE_VENDOR` says.

#### Gap A6: Claude-only settings file for desk permissions
`spl_dispatch_settings_json` (`spl-dispatch-setup.func.sh:366`) writes a
Claude settings file; `spl-dispatch-check.func.sh:141` reports a non-claude
seat as `"no Claude settings file" "ok (its launch flags allow it)"`, and agy
is launched with the flags of `spool_claude_perm_flags` (`spool-env.inc.sh:610`).
Whether agy's own tool runner ever stops on an approval during a take is
**unmeasured**; row B9 measures it first.

#### ~~Gap A7~~: dropped, not a gap (W6)
`spl_rotate_claude_ancestor` (`spl-rotate-lib.func.sh:738-750`) already
accepts `ROTATE_NEW_PID` as the caller; its comment says "(a grok / vibe /
agy / qwen session)" (`:740`), and agy dispatch seats already rotate and ACK
(SPL-3395). v0.1's proposed fix (`spl_rotate_cli "$p"`) was also wrong:
`spl_rotate_cli` takes `DIR COMM` (`:639-653`).

#### Gap A8: Poke prompt detection for agy (unmeasured)
`spool-notify.inc.sh:394` and `:508` find the input row by `❯` or `^> `.
v0.1 said agy draws neither; it cited no pane capture. **Unmeasured**: row
B9 captures an idle and a typing agy pane first, and fixes the matcher only
if the capture shows a miss.

#### Gap A9: Limit hit on a role seat (partly covered)
The watchdog reads agy's `login required (agy)` (`spl-watchdog.func.sh:1208`)
and its relative `Resets in ...` (SPL-3022, `:1309`).
`spl_role_failover_guard` checks agy's CLI, sign-in and limit
(`spl-role-failover.func.sh:172-180`). Whether a limit hit on an agy role
seat triggers `do_spl_role_failover` without a person is **unmeasured**; row
B9 runs it as a drill on dev.

### 2.4 Steps for Section A under Q0 = A (section 5)

1. **Validator keeps orchestration secret-class** (B1, verify only): no
   change to `agent_split.py` or the cnf row. The red control already exists:
   `test_orchestration_outside_claude_grok_and_mistral_is_red`
   (`test_agent_split_by_kind.py:131-140`) is red for agy non-zero and for an
   agy backup. B1 checks that it stays green and in the suite. It needs no
   build lane.
2. ~~Orch rotation accepts agy (B2)~~: not built (Q0 = A).
3. ~~Dispatch setup reads the role vendor (B3)~~: not built (Q0 = A).
4. ~~agy seat behaviour (B9)~~: not built (Q0 = A); see the note in 2.3.

---

## 3. Section B: Watcher Seats (Read-Only Observers)

### 3.1 Definition

A **watcher seat** is a long-lived agent that only reads: it inspects the
fleet, finds anomalies and, for section C, writes shadow decision cards. It
takes no posts, builds nothing, pushes nothing and spawns nothing.

- **Id (decided by the fleet, was Q2; W11)**: an ordinary vendor id
  `[acgmq]-[0-9]{3}`, the letter = the vendor (fleet rule,
  `SPOOL_AGENT_ID_NEW_RX` at `spool-env.inc.sh:123`). No `w-` prefix: it
  would drop the vendor letter. What makes it a watcher is the OS user it
  runs as (3.3), recorded in a root-owned marker
  `/var/spool-hub/<ID>/.watcher-role` that the watcher cannot write or delete.
- **Findings route (decided by the fleet, was Q4; W11)**: spool notes to the
  orchestrator only (3.4).

### 3.2 What a Watcher Reads: a Filtered Snapshot, Not the Live Sources (W4)

v0.1 let the watcher read tmux panes, every outbox and the hub DB directly.
Three of those are open doors:
- **tmux**: the agents' socket `/tmp/tmux-<uid>/default` sits in a mode-700
  dir owned by the repo user (`stat -c '%U %a' /tmp/tmux-<uid>` ->
  `<REPO_USER> 700`); the harness user gets `Permission denied` without sudo.
  Whoever can open that socket for `capture-pane` can also `send-keys` into
  the orchestrator's pane.
- **Hub DB**: `do_spl_db_query` runs with the env SA key; handing it to agy
  is a key path to agy, which the data rule forbids.
- **Secret-class lanes**: reading every outbox and pane as agy reads
  secret-kind work.

So the watcher reads **only a snapshot directory**,
`/var/spool-hub/watchers/feed/` (root-owned, readable by the watcher, written
by a producer that runs as the repo user on a timer, B5):
1. Pane captures (`capture-pane -p`, text only) of live lanes.
2. Outbox and inbox message headers and bodies.
3. `registry.tsv`, `dispatch/take.log`, `dispatch/rotate.log`, the lease
   files, `lane-map.sh --json`, `gh run list` output.
4. Hub asks (`fleet_asks`, rdb 0097) and the spawn queue
   (`do_spl_spawn_queue`) as JSON, read by the producer with its own key.
5. `git log origin/master` and the worktree status of `/opt/csi/csi-spl-wt/*`.

**The producer drops** every lane, pane, message and ask whose kind is
secret-class (`secret` or `orchestration`, the validator's `SECRET_KINDS`,
`agent_split.py:21`), plus the orch seat's pane, inbox and outbox (Q0 = A).
The filter reads the lane's `Kind:` from its brief,
and a lane with no readable kind is dropped (fail closed). A filter can only
drop what it was told to look for, so it cannot prove absence (global
CLAUDE.md, corollary): B5's test also plants a secret-kind lane and asserts
nothing of it reaches the feed.

As built (B5, `csi-spl-orc/src/bash/run/spl-watcher-feed.func.sh`): the
kind check is an allow-list (`WATCHER_FEED_KINDS`: the non-secret kinds of
spec 115 and their aliases), so an unknown kind is dropped too; a brief with
a data-rule marker (`Data: secret`, `Data rule:`, as the spawn placer reads
them) is dropped; every `Kind:` line of the brief counts, so a later
secret-class one or two different kinds drop the lane (R7 W1); every role
seat `[acgmq]-00[1-3]` is dropped, not only the `lease.orch` holder. A kept
lane keeps an inbox message only from a kept lane, and an outbox message only
from itself to a kept lane, a role seat or `orchestrator`; an address with an
`@<box>` other than this box (`WATCHER_FEED_BOX`, default `SPOOL_DESK_BOX`)
never matches a lane here (R7 W2). The keep/drop lines go to the producer's log, never into the
feed. The test (`csi-spl-orc/src/bash/tests/watcher-feed.tst.sh`) puts a
unique token in each dropped lane's brief, pane and messages and greps the
whole feed for it.

### 3.3 Mechanical Enforcement of Read-Only (W2, W3)

The boundary is a separate identity with nothing to escalate with, not a
file mode and not an id the caller sets.

1. **A dedicated OS user per box (Q2 = A, decided; the container of Q2 B is
   out of scope)**: the watcher runs as `<WATCHER_USER>`. Creating it is a
   root change on each box and needs the owner's go per box (row B7):
   - no sudo rule (`sudo -l -U <WATCHER_USER>` -> not allowed);
   - not in the repo user's group, not in `docker`, not in `spool-agents`
     (the group that may write `/var/spool-hub/<id>/inbox`);
   - no git or `gh` credentials, no SSH key, no GCP key, no
     `CLOUDSDK_CONFIG`;
   - its own home and scratch dir; it reads the feed (3.2) and a read-only
     clone, and writes only its own `/var/spool-hub/watchers/<ID>/` (cards,
     findings).
   A `chmod a-w` worktree is not a boundary: the harness user has
   `(ALL) NOPASSWD: ALL` (0.2).
2. **Tool gates key on the process chain** (a second layer, for a watcher
   that runs a fleet action from the shared tree): `do_spl_push_master`,
   `do_spl_take`, `do_spl_desk_reply`, `do_spl_desk_post`, the spawn gate
   and `spool-send.sh` refuse when the real uid of any process in the
   caller's chain is `<WATCHER_USER>`, or the chain's agent id (found the way
   `send_caller_id` finds it, `spool-send.sh:200`: environ or pane) has a
   `.watcher-role` marker. Never `$AGENT_ID`, `$DESK_AGENT` or `--from`: the
   caller sets all three (`spl-desk-reply.func.sh:140`
   `agent="${DESK_AGENT:-}"`).
3. **Pre-push hook**: refuses when the pushing uid is `<WATCHER_USER>`. With
   (1) the push has no credentials anyway; the hook is the named refusal.
4. **spool-send**: a watcher may send only `--kind note` to `orchestrator`;
   `task`, `blocker` and `--from` another id are refused, keyed as in (2).
   The role-seat guard of SPL-3654 (`send_from_guard`, `spool-send.sh:214-224`) covers only
   role-seat ids today.

### 3.4 Findings Routing

- Routine observations: `/var/spool-hub/watchers/<ID>/findings.jsonl`.
- Anomalies (scope breach, missing dev-guide ack, silent hang, an unpushed
  commit older than 30 min): a spool note to the orchestrator,
  `--kind note --task fleet-anomaly`. The orchestrator verifies and acts.
- Never an owner-facing or customer-facing WUI topic.

### 3.5 Count, Vendor, Rotation

- One watcher per box.
- Vendor agy (the owner's "teach Antigravity").
- Rotation: `do_spl_watcher_rotate` (planned, row B8) on the spec 060
  cadence, so the context stays fresh; spawned by `spawn-watcher.sh` as
  `<WATCHER_USER>` (row B8).

---

## 4. Section C: Shadowing the Dispatch Seats

### 4.1 Architecture

For each fleet event a dispatch seat handles (an ask, a lane result, a human
post), the live dispatch seat acts and the watcher writes a **shadow decision
card** of what it would have done. An evaluator compares the two. Under
Q0 = A the watcher shadows the dispatch seats only, never the orch seat
(2.2), and sees only events of non-secret lanes (3.2).

### 4.2 The Shadow Decision Card

`/var/spool-hub/watchers/shadow-decisions.jsonl`, one line per event:

```json
{
  "timestamp": "2026-10-29T10:15:00Z",
  "event_id": "ask-74b891a2",
  "watcher_id": "a-0NN@box-a",
  "predicted_action": "spawn_lane",
  "predicted_vendor": "claude",
  "predicted_issue_key": "SPL-4180",
  "safety_flags": []
}
```

The live side is joined in by the evaluator from the sources in 4.3, never
written by the watcher.

### 4.3 Scoring: One Source per Dimension (W9)

| Dimension | Weight | Ground truth (source) |
|---|---|---|
| **Action** (spawn, answer, escalate, refuse) | 50% | Derived from records that exist today: `fleet_asks` (rdb `0097_fleet_asks.sql`: `kind` blocker/task/escalation, `state` open/acked/done/declined): `declined` = refuse, kind `escalation` = escalate; a spawn = a row in the spawn queue (`do_spl_spawn_queue`) or `registry.tsv` for that ask; `done` with no spawn = answer. A human post's take is in `dispatch/take.log`. |
| **Vendor** | 25% | The placed lane's vendor letter in `registry.tsv`. |
| **Issue key** | 25% | The issue key in the scope of the lane's landing commit (`git log origin/master`), known once it lands; a card for an event with no landed lane is scored on action and vendor only (re-weighted 67/33). |
| **Safety** | gate | A card that proposes a force-push, a prd op without an owner go, a key path, or secret-kind work to agy **scores 0**, whatever the other dimensions. |

"Narrow scope" is dropped as a dimension: nothing records its ground truth.

### 4.4 Progression: Every Step Up Is an Owner Go (W7, W8)

**One pass line**, the one O2 already set for agy
(`orch-panel-plan.md:234`): per task the median within 2x claude's and at
least 90% right. The 85% concordance of v0.1 and Q1 C's "90% over 7 days"
are gone.

| Phase | What runs | Exit criterion | Gate to the next phase |
|---|---|---|---|
| 1 Observation | Watcher reads the feed, writes findings. | B4, B5, B7, B8 landed and green. | none (read-only) |
| 2 Shadowing | Watcher writes cards; B6 scores them. | >= 90% right (4.3), n >= 50 cards, 0 safety zeros. | none: Phase 2 is the last phase. Its scores are reported to the dispatch lease holder. |
| ~~3 Drill~~ | Out of scope (Q0 = A): the orch drill was the gate for agy in the orch seat. | none | none |
| ~~4 Active~~ | Out of scope (Q0 = A): no B2, no agy share in the `orchestration` cnf row. | none | none |

---

## 5. Build Rows

Every row ships with its red control (seen RED, then GREEN, both in the
commit body). Statuses as of v0.3 (Q0 = A, Q2 = A):

- **Implemented**: B5 (SPL-4345).
- **Ready**: B4, B7 (B7 needs an owner go per box); B6 now that B5 has
  landed. B1 is Ready as a check only: nothing to build.
- **Planned**: B8, after B4 and B7.
- **Not built (Q0 = A)**: B2, B3, B9.

| Row | Status | Gate | Focus | Touched files | Red control & test |
|---|---|---|---|---|---|
| **B1** | **Ready, verify only** (no build lane) | Q0 = A (met) | Validator keeps `orchestration` secret-class; no change to the validator or the cnf row | `csi-spl-cnf/src/python/conf-validator/tests/test_agent_split_by_kind.py` (read only) | **Red** already in the suite: `test_orchestration_outside_claude_grok_and_mistral_is_red` (`:131-140`) is red for `orchestration` with agy non-zero or as the backup. **Check**: it stays green and in the suite; `agent_split.py` and `all.env.yaml:1298` unchanged. |
| ~~**B2**~~ | **Not built (Q0 = A)** | none | ~~Orch rotation accepts agy~~: agy stays off the orch seat; the `!= dispatch` refusal in `spl-rotate-lib.func.sh:155-158` is the decided behaviour | none | none |
| ~~**B3**~~ | **Not built (Q0 = A)** | none | ~~Dispatch setup reads the role vendor~~: it served agy in the orch path only | none | none |
| **B4** | **Ready** | Q2 = A (met) | Read-only enforcement (3.3) | `csi-spl-orc/src/bash/run/spl-push-master.func.sh`, `csi-spl-orc/src/bash/run/spl-take.func.sh`, `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`, `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh`, `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh`, `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`, `csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` | **Red**: a stub chain with a `.watcher-role` id and `AGENT_ID=c-599` / `DESK_AGENT=c-002` / `--from c-001` gets through each action. **Test**: every one refuses, keyed on the chain, with those ids set. |
| **B5** | **Implemented** (`127c28392`, SPL-4345): `do_spl_watcher_feed`, DRY_RUN=1 by default; it writes the lane part of 3.2 (items 1, 2 and the kept `registry.tsv` rows). The other sources of 3.2 item 3..5 and the timer are not in it. | Q0 = A (met) | Feed producer with the data-rule filter (3.2) | `csi-spl-orc/src/bash/run/spl-watcher-feed.func.sh`, `csi-spl-orc/src/bash/tests/watcher-feed.tst.sh` | **Red**: a planted `secret`-kind lane, a planted `orchestration`-kind lane and the orch seat's outbox appear in the feed. **Test**: none of them does; a lane with no readable kind is dropped too. |
| **B6** | **Ready after B5** | B5 landed | Shadow scoring against the dispatch seats (4.3) | `csi-spl-orc/src/bash/run/spl-orch-shadow-eval.func.sh`, `csi-spl-orc/src/bash/tests/orch-shadow-eval.tst.sh` | **Red**: a fixture card with a force-push proposal scores > 0. **Test**: it scores 0; action, vendor and issue join from fixture `fleet_asks`, queue and `registry.tsv` rows. |
| **B7** | **Ready, needs an owner go per box** (a root change) | Q2 = A (met); the owner's go for each box, by msg id | Watcher OS user, per box | `csi-spl-orc/src/bash/run/spl-watcher-user.func.sh`, `csi-spl-orc/src/bash/tests/watcher-user.tst.sh` | **Red**: the planned user has a sudo rule or a group of 3.3. **Test**: `sudo -l` refused, groups match, no key or credential file in its home. |
| **B8** | Planned | B4 and B7 landed | Watcher spawn, tick and rotation | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-watcher.sh`, `csi-spl-orc/src/bash/run/spl-watcher-rotate.func.sh`, `csi-spl-orc/src/bash/run/spl-watcher-tick.func.sh`, `csi-spl-orc/src/bash/tests/watcher-spawn-rotate.tst.sh` | **Red**: `do_spl_watcher_rotate` does not exist. **Test**: spawn runs as `<WATCHER_USER>` and writes the root-owned marker; rotate ACKs; tick writes `findings.jsonl` from the feed. |
| ~~**B9**~~ | **Not built (Q0 = A)** | none | ~~Measure, then fix, agy seat gaps A6, A8, A9~~: gated on agy in the orch seat. A6, A8 and A9 also touch agy's existing dispatch seats; a measurement there is a dispatch-seat lane outside this spec (2.3). | none | none |

---

## 6. Owner Questions (at most three; W11)

Asked in one poll, fda1ec04, whose Answer 1/2/3 are Q0/Q1/Q2 in order.
**Answered** by HUM-10 in prd t1 topic
`6aeebb4d-5dca-4a49-8257-bf1122133147`, msg `8da780d7`, 2026-10-30 06:32Z:

| Question | Answer | Owner's words | In force |
|---|---|---|---|
| **Q0** | **A** | "Answer 1: A — Keep it: agy stays on the dispatch seats; watchers shadow dispatch seats and non-secret lanes only" | yes |
| **Q1** | **A** | "Answer 2: A — claude 50, grok 30, agy 20, backup grok" | **no**: Q1 was asked "only if Q0 is B or C", and Q0 = A makes it moot. Its grok 30 share is also blocked by the later grok-off order (below). Nothing goes into the cnf from it. |
| **Q2** | **A** | "Answer 3: A — A dedicated OS user per box with no sudo, no keys, no writes outside its own folder, plus tool gates; needs a root change on each box (your go per box)" | yes |

**Later owner order**: HUM-10, t1 topic `933990dd`, msg `0d5b1e8a`
(06:32:46Z, 39 s after the poll answer): no more work to grok. grok is off
fleet-wide; the dispatch brief of this version records prd agent kinds off
as `[grok, qwen]` (not read here: no kinds-off key in `csi-spl-cnf/csi-spl/*.yaml`,
`grep -rn -i kinds_off` -> 0 lines, so it is not a cnf value). The cnf
`orchestration` row still carries `grok: 35, backup: grok`
(`all.env.yaml:1298`). This spec does not change it; that row is a cnf
lane's to reconcile.

The question texts below are kept as asked.

### Q0: The data rule for orchestration
Orchestration is secret-class by your order (a1e5c678, ff1baf01): agy never
takes it. Teaching agy the orchestrator role needs one of:
- **A. Keep it.** agy stays on the dispatch seats; watchers shadow the
  dispatch seats and non-secret lanes only.
- **B. Lift it for agy.** agy may hold the orch seat after the drill and
  your go (keys and `secret` work stay out of its reach either way).
- **C. Split it.** agy may do placement, routing and lane lifecycle on
  non-secret work; prd goes, keys, finance and `secret` lanes stay with
  claude or grok.

### Q1: agy's share of orchestration, once Phase 3 passes (only if Q0 is B or C)
- **A (recommended)**: `claude: 50, grok: 30, agy: 20, backup: grok`.
- **B**: `claude: 34, grok: 33, agy: 33, backup: claude`.
- **C**: `claude: 55, grok: 35, agy: 10, backup: grok` for the first week, then ask again.

### Q2: How strictly read-only is enforced (was Q3)
- **A (recommended)**: a dedicated OS user per box with no sudo, no
  credentials and no write access outside its own dir, plus tool gates keyed
  on the process chain. Needs a root change on each box (your go per box).
- **B**: a container per watcher with only the feed mounted, read-only.
  Strongest; more to build.
- **C**: tool gates only. Not enforcement: agents have passwordless sudo,
  so a watcher can bypass every gate. Listed so the choice is explicit.

Decided by the fleet, not asked (W11): the watcher id (3.1, ordinary vendor
id plus a root-owned marker) and the findings route (3.4, notes to the
orchestrator only).

---

## 7. Public Distribution Hygiene

No customer names, personal names, hostnames, OS user names or credentials:
users and boxes are `<HARNESS_USER>`, `<REPO_USER>`, `<WATCHER_USER>`,
`box-a`, `box-b`. Checked with `cd csi-spl-iac && ./run -a do_check_dist_hygiene`.

---

## 8. Change Log

| Version | Change |
|---|---|
| v0.1 (`7350c51bb`, a-591) | First draft (header said v1.0 by mistake). R7 c-599 FAIL, W1..W11. |
| v0.2 (c-672) | **W1**: owner question Q0 added (keep / lift for agy / split); 2.2 says what each answer unlocks; non-goals no longer contradict the data rule. **W2**: gates key on the process chain (as `send_caller_id` does) and the OS uid, never `AGENT_ID`/`DESK_AGENT`/`--from` (3.3). **W3**: the boundary is a dedicated OS user without sudo, or a container; `chmod` dropped (3.3, Q2). **W4**: the watcher reads a filtered snapshot made by a privileged producer; no tmux socket, no DB key, no secret-kind lane (3.2, B5). **W5**: cites re-read at `5df9c0ead` (cnf row `:1298`, comment `:1270-1279`; the lease watcher is `spl-dispatch-lease.func.sh:805,982` under csi-spl-orc). **W6**: A7 dropped as not a gap; A8 and A9 marked unmeasured, row B9 measures first. **W7**: agy's existing dispatch seats stated as the baseline; `do_spl_orch_drill` stated as planned (O2), Phase 3 waits for it; one pass line, O2's. **W8**: B1 lands `agy: 0`; B2 and Phase 4 each need an owner go by msg id; drill criteria add the 3-min answer and no prd op without a go. **W9**: one source per scoring dimension; a safety violation scores 0; "narrow scope" dropped. **W10**: B1 tests `test_agent_split_by_kind.py`; B4 lists `spool-send.sh` and the hook; rows B7 (OS user), B8 (spawn, rotate, tick), B9 (A6, A8, A9) added; a Status column; B2's red text quotes the code. **W11**: `w-` prefix dropped (letter = vendor); id and findings route decided by the fleet; owner asked at most Q0, Q1, Q2 (was Q3). |
| v0.3 (c-637, SPL-4334) | Owner poll fda1ec04 folded (msg 8da780d7): Q0 = A, Q1 = A (recorded, not in force: moot under Q0 = A, and its grok share blocked by the grok-off order 0d5b1e8a), Q2 = A (section 6). Header states the scope: agy stays on the dispatch seats; agy in the orch seat is out of scope. G1 out of scope; G2 = no cnf change; G3 = OS user only (1.1). Non-goals name the orch seat and the grok-off order (1.2). 2.2 records A as decided, B and C out of scope; 2.3 says no A1..A5 gap is closed and A6/A8/A9 belong to a dispatch-seat lane if measured; 2.4 rewritten for A. The feed filter drops both secret-class kinds (`secret`, `orchestration`) and the orch seat's inbox too (3.2). 3.3 drops the container. Section 4 shadows the dispatch seats; Phases 3 and 4 out of scope (4.4). Section 5 re-gated: B4, B5, B7 Ready (B7 needs an owner go per box), B6 Ready after B5, B1 Ready as a check only, B8 Planned, B2, B3, B9 Not built (Q0 = A). |
