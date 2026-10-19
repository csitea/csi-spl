# Lane issue and docs: how the rule is enforced

> Generated from qto doc `eda81f36-f08f-436c-b370-48eecdc55aec`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The rule's one home is the fleet fragment
`csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/27-lane-issue-and-docs.md`,
rendered into every seat's global `CLAUDE.md` (and `AGENTS.md` for vibe).
This page says what code enforces it, and how to use it. It homes no rule
([fleet rules index](fleet-rules-index.md)).

Owner, HUM-10, t1 topic 5ea2e615 (2026-10-12), in order: msg 5b6f2aa7 (the
agents "have been implementing the features without actually going through the
whole process of any certain issues, changing the statuses of the issues,
keeping track"), msg 5c4c410e ("too cowboy a way to work"), msg 346238a8 ("the
concrete decision on what needs to be done and the tracking of the statuses
must be reflected in the issues ... making sure that the documentation is kept
up to date as well"). And: orchestration is code, not intelligence.
Then spec 135 section 9 (`csi-spl-doc/specs/135-work-process/spec.md`): Q1 A
(msg 2ec08981, every discussion an agent takes gets an issue from the first
answer), Q2 (msg f2c24a7b, an issue holds condensed state and links the
discussion; it does not become one), Q3 A (msg e2a3f127, `done` when the
closing commit lands), Q4 A (msg 910b14c9, the source link and the restart
card at the top of the description, the key posted back in the topic, no
migration; the source link is an enforced link since SPL-1593, section 0.2).

<a id="ws-doc-d435f230-282c-4ef0-a51c-601fb1aa6381"></a>
## 0. A discussion's issue, at the first answer

Whoever takes a discussion files its issue with the first answer (no lane
needed): status `eval`, the taker assigned, the topic linked, the card (0.1)
on top, the key printed and posted back in the topic. An evaluation or an answer to the owner is an
`answer` issue (`LANE_ISSUE_ANSWER=1`, label `answer`). Acks, chatter and
announcements file none (no `LANE_ISSUE_TITLE`: refused).

```bash
cd csi-spl-orc && AGENT_ID=<taker> LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=<topic uuid> LANE_ISSUE_TITLE='<the work>' LANE_ISSUE_ANSWER=1 DRY_RUN=0 ./run -a do_spl_lane_issue
```

<a id="ws-doc-fa5a0388-7fa7-451f-a746-4b5a794e8fb8"></a>
### 0.1 The card and the key in the topic

Every issue this code files (0, and 1.1 with no key) starts its description
with the spec 135 section 7.1 card, the owner's words below it:

    ## Source
    /t/<topic uuid>

    ## Restart
    - key: SPL-n
    - spec: <the brief's Spec: folder, else the first csi-spl-doc/specs/NNN-slug it names>
    - scope: the brief of lane <id>
    - must not touch: <the brief's first "not touch" line, or see the brief>
    - test: see the brief
    - last citing sha: none
    - next: <one line>
    - open question: none
    - docs: none yet

The key is unknown until the create, so a second `update` writes it into the
card. Then the filing desk posts `Tracked as **SPL-n**: <title> (lane <id>).`
in the topic (`do_spl_desk_reply DESK_TASK=<topic>`); `LANE_ISSUE_POST=0`
skips the post. A failed card update or post warns and the issue stands. An
issue that is linked, not filed, is not rewritten (no migration). The lane
keeps its card current with
`do_spl_issue_update ISSUE_DESCRIPTION_FILE=<file>`.

A lane placed later from that discussion carries the key in its brief
(`Issue: <KEY>`), so it links that issue instead of filing a second one.

<a id="ws-doc-072a8acd-990f-4887-970d-02abf5618e3b"></a>
### 0.2 The issue links its discussion (SPL-1593, rdb 0194)

Every issue links to one or more discussions, enforced by the database
(issues-v1 §2.2; owner HUM-10, t1 fcf09921, msgs 3e75e13e, 62f96f94). The
card's `Source` line is what links it: the hub reads the `/t/` links of a
create's description when the create names no `discussions` (every `spool`
binary sends the card). `do_spl_lane_issue` takes the topic from
`LANE_ISSUE_TOPIC`, else the brief's first full topic id after "topic", else
its first 8-hex short id after "topic" or "dispatch-"; the hub resolves a
short id inside the issue's own workspace and links it only when exactly one
topic matches. With no topic, or one the hub does not resolve (no such topic,
an ambiguous short id), the issue links the workspace's default discussion
(t1: topic fcf09921; any other workspace: its "Issue backlog" topic) and one
`WARN brief <path> ...` line names the brief so it can be fixed. A placement
never fails on the link (c-002, dispatch-fcf09921 msg c5c7d032). Once filed,
the card's `Source` line carries the full id the hub linked, and the key is
posted back only in a named topic, never in the default one.

<a id="ws-doc-95b49ee8-d0f1-44d4-9ece-f6d87fa89181"></a>
### 0.3 No issue without an epic and a git spec (SPL-2355)

Owner HUM-10, t1 topic 7a98c2d1 (2026-10-17), msg ef77b762 ("you shouldn't
create issues without an epic and without a git spec. They should go hand in
hand") and msg 5863d0d6. Measured on prd by the dispatcher c-002 before the guard: of t1's SPL-2300..2353,
54 of 54 had no epic and 35 named no spec. So every level-2 issue this code
files names both, or nothing is filed:

- **The spec**: a folder `csi-spl-doc/specs/<NNN-slug>` that is a tree on
  `origin/master` (a miss fetches once). `do_spl_lane_issue` reads the
  brief's `Spec:` line, else the first such path in the brief
  (`LANE_ISSUE_SPEC` overrides; required for `LANE_ISSUE_OP=discussion`);
  `do_spl_issue_create` reads it from the description
  (`ISSUE_DESCRIPTION` or `ISSUE_DESCRIPTION_FILE`).
- **The epic** (the level-1 parent, sent as `--epic`): the brief's
  `Epic: SPL-<n>` line (`LANE_ISSUE_EPIC`, `ISSUE_EPIC`), else the spec's pin
  (`Epic SPL-74` in the first 40 lines of its `spec.md`), else the tenant's
  one epic titled `Spec NNN - ...`: the mapping of the spec import
  (`do_spl_spec_import_issues`), read with one `spool issue list --kind epic`.
  None or two: refused. `do_spl_issue_create` takes only `ISSUE_EPIC`.
- An epic or feature (level 1) and a child of `ISSUE_PARENT` need neither; a
  linked key (`Issue: <KEY>`) files nothing and is not checked.
- **At enqueue**: `do_spl_spawn_enqueue` with `SPAWN_PLACE=<vendor>:<slug>`
  checks the slug's brief file the same way before it queues, so the
  dispatcher fixes the brief first: `FATAL ask not queued: ...`, the ask stays
  open. There the epic must be on the brief or pinned in the spec (no hub
  read). A brief placed without that check (an ask queued before the rule, a
  hand spawn) is refused at placement: `do_spl_lane_issue` fails, so
  `spawn-window.sh` exits 12 and releases the id (1.2); the lane never starts.
- **The epic must be open** (SPL-2508). The hub refuses an issue under an
  epic that is archived or deleted (`unknown_parent`), and an epic closes and
  is archived by itself when its last open issue closes (SPL-1729). On
  2026-10-18 at 00:25Z the landed-fix closer moved SPL-2461 to done, which
  closed and archived its epic SPL-2372 while queued briefs still named it;
  each of them then failed at launch with exit 12, retried every 10 min, and
  the queue stalled behind them. Three checks now:
  - `do_spl_spawn_enqueue` reads the brief's epic on the hub
    (`do_spl_issue_status`): done, diss or not a live issue refuses the ask,
    `FATAL ask not queued: brief <file> names epic SPL-<n>, but ...: point its
    'Epic:' line at an open epic, or reopen SPL-<n>`.
  - `do_spl_spawn_place` checks the head row's brief the same way before it
    launches: a closed epic hands the ask to the orchestrator in ONE blocker with
    that line (the hand-off of a brief that needs judgement), nothing is
    launched, and the queue moves on.
  - `do_spl_issue_close_landed`: a move whose answer says it closed the
    issue's epic (`epic_closed`) while a queued spawn ask's brief ON THIS BOX
    names that epic reopens it (unarchive, `wip`, a comment naming the asks).
    The closer runs on one box; a brief on another box is caught by that
    box's placer (above).
  A hub that does not answer refuses nothing; the launch still reports it.

The one FATAL line names the order and what to add, for example:

    FATAL refused, nothing filed: no issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6): no spec folder named. Add a 'Spec: csi-spl-doc/specs/<NNN-slug>' line (a folder on origin/master) and an 'Epic: SPL-<n>' line

Existing issues are not touched here (their epics are linked by a separate
lane, owner msg 52da8fbb). Code: `li_epic_spec`, `li_brief_epic_spec`,
`li_epic_closed`, `li_brief_epic_closed` in
`spawn-agents/lib/lane-issue.inc.sh`; `spl_lane_issue_guard`;
`spl_issue_create_epic_spec`.

<a id="ws-doc-33e2dfe3-ac34-4c97-a628-cbcb87906328"></a>
## 1. The life of a lane's issue

| step | what happens | code |
|---|---|---|
| 1.1 placement | `spawn-window.sh` (the front door of every spawn, the remote serve's included), after the id claim and before the window: a git lane with a brief gets its issue from `do_spl_lane_issue`. The key in `SPAWN_ISSUE` or the brief's `Issue: <KEY>` line is linked (status `wip`, assignee the lane, a comment with the topic link); no key: one is filed under the brief's epic and spec (0.3), title = the brief's heading, description = the brief's text up to its first `## ` (the owner's words, at most 1500 bytes) + the lane id + the topic link, under the card (0.1), and the key is posted back in the topic; a brief line `Kind: answer` labels it `answer`. The key lands in `<spool root>/<id>/lifetime/issue`. | `spawn-agents/scripts/spawn-window.sh` `sw_issue`; `csi-spl-orc/src/bash/run/spl-lane-issue.func.sh` |
| 1.2 refusal | No issue placed (the hub refused, no seated desk, a brief with no spec or epic (0.3), or `SPAWN_ISSUE_CREATE=0` with no key): exit 12, the claimed id released, one line with the command that makes one. | `sw_issue`, `sw_release_claim` |
| 1.3 the seed | The seed's `YOUR ISSUE` block names the key, the commit-subject form, the docs rule and the end command; the recorded brief (`lifetime/brief.md`) gets the `Issue:` line. | `spawn-core.inc.sh` `_spawn_issue_block` |
| 1.4 landing | Every commit cites the key in its subject scope (`feat(orc, SPL-123): ...`). Only two forms close it: a `fix`, `feat`, `perf` or `refactor` subject with the key in its scope, or a `Closes: SPL-123` trailer; `docs`/`test`/`chore`/`ci` subjects, reverts, `Fixes:`, `Refs:` and bare mentions never close. The exit gate's "landed" and the docs check both read it from the one parser. | `csi-spl-orc/src/bash/scripts/issue-close-landed.py --keys` (`commit_keys`) |
| 1.5 ending without landing | `cd csi-spl-orc && AGENT_ID=<id> LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON='<why>' DRY_RUN=0 ./run -a do_spl_lane_issue`: the status (`diss`, `onhold` or `blocked`), a comment with the reason, and `lifetime/issue-end`. | `spl_lane_issue_end` |
| 1.5b landed in another repo | The lane's work landed in another repo (its brief barred any csi-spl change), so no csi-spl commit can close the key (SPL-2229): `cd csi-spl-orc && AGENT_ID=<id> LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_LANDED_REPO=<name> LANE_LANDED_SHA=<sha> DRY_RUN=0 ./run -a do_spl_lane_issue`. It sets the issue `done` and writes `lifetime/issue-end` only after it checked the sha on that repo's fetched `origin/<trunk>`; landed is not live (the dispatcher's ACCEPTED still checks served). The repos it knows are the cnf list `env.box.landed_repos` (`name`, `src_dir`, `trunk`, optional `box`; today csi-rel, its clone on one box) plus each hosted site's `src_dir`, resolved by the one `spl_landed_repo` that the **Live** proof (`LIVE_REPO=<name>`) and the done-claim check use too (SPL-2420). How the repo is resolved and checked: the `do_spl_lane_issue` header, its one home. | `spl_lane_issue_landed`, `spl_landed_repo`, `spl_lane_issue_on_trunk` |
| 1.6 exit | `/exit-clean`'s gate (`kill-your-self-report.sh --gate`), after the ACCEPTED, refuses while no commit on `origin/<trunk>` closes the key (1.4) and there is no end reason (1.5; a 1.5b `done` record passes with `issue gate: <KEY> landed in another repo: <repo> <sha>`, one with no repo + sha is refused), unless the key is already `done` on the hub: an apply-only lane (no code commit) whose issue the orchestrator set done (`do_spl_issue_update ISSUE_STATUS=done`) exits with `issue gate: <KEY> done on the hub (no landed commit)` and never needs an end reason that would overwrite `done`. That read is last and best effort (`do_spl_issue_status`, as the box user, `LI_HUB_TIMEOUT` seconds, default 20): any other status or no answer is refused as before (SPL-1813). | `lib/lane-issue.inc.sh` `li_gate`, `li_hub_status`; `csi-spl-orc/src/bash/run/spl-issue-status.func.sh` |

The issue is filed by a seated desk of the fleet lease (`LEASE_MASTER`, then
`LEASE_ORCH`, then `LEASE_FAILOVER` in `<spool root>/dispatch/lease.conf`,
in its `LEASE_ENV` / `LEASE_TENANT`), the first of them that the box's desk
sidecar announces; failing all three, any other agent of that desk it
announces (SPL-1707). The sidecar leaves out an agent its fresh run report
(`dispatch/agent-run.tsv`) has said "stop" for an hour, unless a lease mirror
seats that role on this box or a rotation holds it, and the hub refuses an
issue call as an unannounced agent (`from_not_announced`). On 2026-10-13 every
role seat on a satellite box was on a usage-limit screen while the lease was on another box, and
every spawn there was refused at this step. The hub takes as assignee only an agent
its roster announces; a lane it does not know is named in the description and
the placement comment, and the placing desk is the assignee.

A respawn of an id (`SPAWN_REUSE_ID=1`: the rotation, a restart) keeps the key
it has. A lane placed before this rule has no key; its exit is not checked.

<a id="ws-doc-edd9e6f3-8469-4103-aaa2-519b185699e4"></a>
## 2. Docs kept current

At the same exit gate (1.6): the lane's commits on trunk (those naming its key in the subject scope, any type, or in a `Closes:` trailer)
that change behaviour, meaning a path under `csi-spl-api/`, `csi-spl-orc/`,
`csi-spl-iac/` or `csi-spl-wui/` that is not a test, a fixture or markdown,
need either

- a change under `csi-spl-doc/` in one of those commits, or
- a line `Docs: none (<why>)` in one of their messages.

Neither: the exit is refused, naming the first code path.

The pre-push gate does not check it: a lane pushes each commit as it is green
(seed INTEGRATION (2)), so the doc change often lands in a later push than the
code. The exit is the first point where the lane's whole change is known.

<a id="ws-doc-c5ae354f-5463-4a6d-b48d-d5a6e9760a43"></a>
## 3. Tests

`csi-spl-orc/src/bash/features/spawn-agents/tests/test-lane-issue.sh`: every
refusal (no key at placement, a wip issue with no landed commit, a behaviour
change with no docs) and each way through, with a control per refusal that
runs the same case with the gate removed.
`csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh`: the hub calls of
placement, discussion and end, the card (0.1) and the key posted back.
`csi-spl-orc/src/bash/tests/spl-issue-key-rate.tst.sh`: what the key rate (4)
counts.

<a id="ws-doc-94dc154f-5e0c-4ce2-a8ec-fe039d404563"></a>
## 4. The key rate, weekly

Owner Q6 A (msg 910b14c9): the key is enforced at the lane's exit (1.6), not
by the pre-push hook, and the fleet's key rate is measured weekly. If the rate
stays low after two weeks, the hook is the next step (spec 135 section 9, Q6
B), and that is the owner's call.

```bash
cd csi-spl-orc && ./run -a do_spl_issue_key_rate
```

Of the non-merge commits on `origin/master` in the last 7 days
(`KEY_RATE_SINCE`, `KEY_RATE_REF`): `cite` = the key in the subject scope (any
type) or a `Closes:` trailer; `close` = the commits the landed-fix rule closes
an issue with (1.4, the same parser). It prints one JSON line (with the
uncited commits per subject type) and one OK line. The box cron
`issue-key-rate` (Mondays 06:53, `cnf/box-crons/box-crons.manifest`) fetches
trunk and appends the week's row to
`/var/csi/csi-spl/issue-key-rate/history.tsv`:
`<utc> <since> <commits> <cite> <close> <cite %> <close %>`.

Baseline, 2026-10-12, the day the rule landed: 1978 commits in 7 days, 17
cite a key (0.9%), 13 close one (0.7%).
