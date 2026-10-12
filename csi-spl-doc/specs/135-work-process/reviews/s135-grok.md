signed against ada13012eaeb56388fd9ef555253860c4e0e7d24

# Spec 135 — seat s135-grok

Read of `origin/master` at the sha above. This file is the only change. Each recommendation is this seat's. The owner decides.

Build lanes after v1.0 make the code and the doc-page edits. This seat does not.

## 1. Objects

Six objects. Two of them are hub rows (discussion, issue). Four are git or fleet records (lane, spec, doc page, release).

### 1.1 Discussion (a topic)

A discussion is a spool thread. `task_id` is the thread key. There is no separate task row (`csi-spl-doc/doc/md/SPEC-spool-task-lifecycle.md:12-20`). A channel post has `parent_task_id` null. A reply sets `parent_task_id` to the root (`SPEC-spool-task-lifecycle.md:22-26`).

| | |
|---|---|
| Who creates it | Whoever posts. A web post arrives as a desk delivery to the dispatcher seated on that workspace (`SPEC-spool-fleet-roles.md:81-84`). The seat that takes the post owns the topic (`SPEC-spool-fleet-roles.md:126-129`). |
| States | Open. On hold when the opening message carries the pause reaction (`SPEC-spool-fleet-roles.md:60-61`). Closed or archived by a human (`SPEC-spool-fleet-roles.md:51-58`). |
| Who moves them | A human closes or archives. The dispatcher tells `c-001`, and `c-001` closes the lane. An agent does not reopen a closed discussion (`SPEC-spool-fleet-roles.md:51-58`). |
| Links | No column points from a channel topic at an issue. An issue's own discussion is a second `task_id`, minted at create (`csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go:304-310`, `internal/store/issues.go:17-20`, `csi-spl-rdb/src/sql/postgres/spool-hub/0047_issues.sql:62,72`). A blocker issue reuses one derived topic id so the pair cannot be filed twice (`internal/hub/blocker_issue.go:38-42`). |
| When it ends | The human closes or archives it, or says it is done. Empty talk ends the same way, with no issue. |

Proposal, no new column: when the dispatch holder files an issue, the description starts with the source topic URL, and the holder posts the new key back into that topic. Question Q4.

### 1.2 Issue

One row in `issues`. The key is `<prefix>-<number>` (`SPL-12`). Numbers are never reused (`0047_issues.sql:12-13,27-31`). The discussion of the issue is the topic on `issues.task_id` (`0047_issues.sql:15-18`). Comments are messages on that topic. The history table does not copy them (`0181_issue_events.sql:18-20`).

Stored fields that matter here:

| field | today |
|---|---|
| `title` | 1..255 (`internal/store/issues.go:70`) |
| `description` | markdown, at most 20000 characters (`internal/store/issues.go:71`) |
| `status` | one of eight, below. Any of them is accepted from any previous value (`internal/store/issues.go:335-342,370-371`). There is no transition table. |
| `priority` | 1 highest .. 5 lowest, default 5 (`internal/store/issues.go:58-64`, `0055_issue_prio_status.sql:4-8`) |
| `level` | derived: 1 epic or feature, 2 issue, 3 subtask (`internal/store/issues.go:65-69`, `0056_issue_level_tree.sql:8-14`). Input is checked, not trusted. |
| `kind` | `epic`, `feature` or `issue` (`0053_issue_kinds.sql:8-11`, `internal/store/issues.go:87-94`). A subtask is `kind=issue` at level 3. |
| `assignee` | a member id or an agent id, or empty (`internal/store/issues.go:376-377`). The hub checks the id is on the roster (`internal/hub/issues.go:283-291`). |
| `labels` | up to 20 catalogue ids (`internal/store/issues.go:72`) |
| `deadline` | timestamptz or null (`0047_issues.sql:61`) |
| `parent` | a level-1 row, or a level-2 issue for a subtask. A level-2 issue may stand alone (`internal/store/issues.go:101-104`, `spl-issue-create.func.sh:12`). |
| `task_id` | the issue's own discussion |
| audit | `created_by`, `updated_by`, `completed_at` (set on `done`), `canceled_at` (set on `diss`) (`internal/store/issues.go:483-493`) |
| hide flags | `deleted_at` (`0071_issue_soft_delete.sql:6-8`), `archived_at` (`0085_issue_archive.sql:8-13`). While either is set, list and get skip the row. |

Statuses, in the order the WUI shows (`csi-spl-wui/src/utils/issues-view.mjs:14-15`, hints `csi-spl-wui/i18n/locales/en.json:1337-1346`, store constants `internal/store/issues.go:25-44`):

| stored | label | meaning on the page | who sets it in the process below | tool |
|---|---|---|---|---|
| `eval` | 01-eval | evaluation | create, when the entity of work is still being named | `do_spl_issue_create` (default, `spl-issue-create.func.sh:16`) |
| `todo` | 02-todo | to do | the dispatch holder, once the owner has agreed the entity of work | `do_spl_issue_update` `ISSUE_STATUS=todo` |
| `wip` | 03-wip | work in progress | the spawn path, when the lane exists | `do_spl_issue_update` `ISSUE_STATUS=wip` and `ISSUE_ASSIGNEE=<lane>` |
| `diss` | 03-diss | discard | the stale-discard action, or a lane that ends with no land and a reason | `do_spl_issue_discard_stale`, or `do_spl_issue_update` |
| `blocked` | 05-blocked | waiting; the hint says to name what, in a comment | the lane | update, plus `do_spl_issue_comment` |
| `onhold` | 06-onhold | paused on purpose | the dispatch holder, when the owner pauses the work | `do_spl_issue_update` |
| `qas` | 07-qas | quality assurance | only when a human asks for a review | `do_spl_issue_update` |
| `done` | 09-done | done | `do_spl_issue_close_landed`, hourly, for a commit that cites the key | that action: comment, then `--status done` (`spl-issue-close-landed.func.sh:138-149`) |

Who may write, today:

- A browser member needs `notes.send` and `topics.manage` (`internal/hub/issues.go:751-762`).
- An announced agent on a paying tenant writes over its box socket (`internal/hub/issues_agent.go:20-24,52-78`) or `spool issue` (`csi-spl-api/src/go/spool-hub-api/cmd/spool/issue.go:17`).
- The desk actions are `do_spl_issue_create`, `do_spl_issue_update`, `do_spl_issue_comment`, `do_spl_issue_list`, plus archive, unarchive, delete, discard-stale, close-landed, close-check. Create prints the new key (`spl-issue-create.func.sh:4-6`).
- The blocker sweep files one `todo` issue per tagged assignee after `blocker.issue_after_minutes` (default 3), label `blocker` (`internal/hub/blocker_issue.go:31-42`). The tagged id may be a person or an agent. An owner is not excluded.

History of field changes is `issue_events`, written by a trigger: created, changed, deleted, restored, archived, unarchived (`0181_issue_events.sql:6-8,30-37`).

When it ends:

- Workflow end is `done` or `diss`. `done` stamps `completed_at`. `diss` stamps `canceled_at` (`internal/store/issues.go:483-493`).
- Archive and soft-delete hide the row and keep it. They are not statuses.
- An epic or a feature is not closed by one commit (`issue-close-landed.py:134-140`). The discard action discards a parent only when every child is done or discarded (`spl-issue-discard-stale.func.sh:10-11`).

The update action's header still says "in_review / done when it lands" (`spl-issue-update.func.sh:6-7`). The create header lists the eight current ids (`spl-issue-create.func.sh:16`). A later lane should fix that header. This seat does not.

### 1.3 Lane (agent + worktree + branch)

| | |
|---|---|
| Who creates it | The spawner. `git worktree add -b <branch> <dir> origin/master` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:171-175`). |
| Record | `lane-map.sh put` writes agent, repo, branch, scope, files, topic, state `live` (`lane-map.sh:17-18`). `lane-map.sh done` keeps the row and sets state `done` (`lane-map.sh:19-22`). Role seats `c-001`..`c-003` are not ended: the next person in the seat keeps the id. |
| States | `live`, then `done`. One small task, then exit (`SPEC-spool-fleet-roles.md:26-41`). A different task is refused; `c-001` spawns a new lane (`SPEC-spool-fleet-roles.md:41`). |
| Links | The issue assignee is the lane id while the lane is live. The seed carries the issue key (proposed; the spawn scripts on this sha do not read an issue key: `git grep` of `ISSUE_` under `spawn-agents` returned no hits). |
| When it ends | The task is verified, the lane reports, `/exit-clean` runs, the worktree and the branch are removed. A human ending the discussion ends the lane too (`SPEC-spool-fleet-roles.md:51-54`). |

### 1.4 Spec

A file `csi-spl-doc/specs/<NNN>-<slug>/spec.md` on `master`. The hub has no spec row. This panel's editor writes `specs/135-work-process/spec.md` after the seats sign. The version line is the state: draft, then rc, then v1.0. It ends when a later spec says it is superseded. This seat does not write that file.

### 1.5 Doc page

A file under `csi-spl-doc/doc/md/`. The developer guide, the fleet-roles page and the lane-integration page are the pages this process leans on. A behaviour change updates the one home of the rule; other pages point at it. `do_check_fleet_rules_drift` fails when two copies disagree (`CLAUDE.md:146-149`).

User-facing text in several languages gets the language reviewer last (`CLAUDE.md:139-141`). English rule text does not wait.

No status column. The page is current when the citing commit is on `master`, or the commit message says `Docs: none (<why>)`. That refusal is not in the tree yet (section 6, c-880).

### 1.6 Release (a v-tag)

A `v<X.Y.Z>` tag minted by `do_release_version` inside the hub deploy and the WUI deploy. One step past the highest tag. The remote is the lock. Nobody edits the number by hand (`csi-spl-orc/src/bash/run/release-version.func.sh:1-13`, `csi-spl-doc/doc/md/developer-guide.md:40-46`, `CLAUDE.md:129-136`).

Both deploys target `dev` and `prd` (` .github/workflows/20_hub-build-deploy.yml:157`, `.github/workflows/30_wui-build-deploy.yml:135`). They run only when the push touches their path lists (`20_hub-build-deploy.yml:48-64`, `30_wui-build-deploy.yml:37-45`). A docs-only push matches neither, so it gets no tag. The quality gate has no path filter and starts on every push to `master` (`10_ci-quality.yml:40-47`).

The close action writes a release URL per sha at the moment it sets `done` (`spl-issue-close-landed.func.sh:141-149`). That can be earlier than the deploy that publishes the note. Question Q2.

## 2. Roles

| role | does | never does |
|---|---|---|
| Owner | Says what the work is, in a discussion. Agrees the entity of work (eval becomes todo). Decides an owner question becomes an issue. Reopens a `done` issue. Pauses work (the issue goes `onhold`). | Is not filed an issue by the blocker sweep. Does not push, and does not sit in `qas` for a normal land. |
| Orchestrator `c-001` | Decides, spawns, re-seats, closes lanes. Verifies a "live" claim. Runs the production operations a lane harness refuses (`SPEC-spool-fleet-roles.md:16`). | Takes a post the dispatch holder has taken. Routes routine traffic. Files an issue for a question addressed to the owner. |
| Dispatchers `c-002` / `c-003` | The lease holder takes the post, answers, and owns the topic (`SPEC-spool-fleet-roles.md:17-18`). Files the issue or the feature in `eval`. Moves it to `todo` when the entity is agreed. Spawns the lane. Tells the owner in the source topic when the issue is `done`. | Builds a lane's code. Files an issue for a question addressed to the owner. Sets `done` on a claim the close rule did not check. Dispatches while on standby (`c-003`, `SPEC-spool-fleet-roles.md:18`). |
| Lane agent | One brief. Sets `wip` if the spawn did not. Cites the issue key in the landing commit. Updates the restart card. Comments progress with `do_spl_issue_comment`. Sets `blocked` and names what it waits on. Sets `diss` with a reason when it ends with no land. Reports to the dispatch holder and to `c-001`. | A second task. A post in the owner's topic (the holder posts there). A new status. A force-push. |
| Panel seats | One review file each, against the sha they read. Sign the editor's rc, or object. | Another seat's file. `spec.md`. Code, cnf, or a doc page. |
| Editor | Own seat file first. Then `spec.md`: the agreed objects, roles, flow, the state table, the tally, the owner questions. Asks each seat to sign. Reports v1.0 to the dispatch holder. | Folding a seat commit that is not that seat's one file. Posting to the owner (the holder does). |
| Language reviewer | Last word on user-facing text in several languages (`CLAUDE.md:139-141`). | English rule text. A code review that is not language. |
| CI | On every push to `master`, the quality gate (`10_ci-quality.yml:40-47`). When the path list matches, the hub deploy and the WUI deploy, each to `dev` and `prd`, each minting the version. | Choosing a status. Reviewing a design. Deploying a docs-only commit (the path lists do not include it). |

Refactoring rounds need no owner go (`SPEC-spool-fleet-roles.md:63-77`). A prd mutation, a terraform apply or a key still needs his go for that one call (`CLAUDE.md:66-70`).

## 3. The flow

End to end. Each status write names the tool. The store will accept a skip (`internal/store/issues.go:370-371`); the gates in section 6 are what make this the path.

1. The owner posts in a channel. The desk delivers it to the dispatch holder (`SPEC-spool-fleet-roles.md:81-84`). The holder that takes it owns the topic (`SPEC-spool-fleet-roles.md:126-129`).
2. The holder answers in the discussion. Talk that names no work stops here. No issue.
3. A question addressed to the owner stays in the discussion until he decides it is an issue (Q1). If a live issue is waiting on that answer, the lane runs `do_spl_issue_needs_owner` with `OWNER_STEP` set to the question and the reply he is asked for. That moves an open issue to `blocked` and adds the label (`spl-issue-needs-owner.func.sh:8-12`).
4. The first concrete answer, including "evaluate and answer this", is one issue per lane the holder is about to spawn. Several lanes that share one decision sit under one `feature`. Tool: `do_spl_issue_create` with `ISSUE_STATUS=eval`, `ISSUE_KIND=feature` for the parent, `ISSUE_EPIC` on each child. The description is the owner's words, the source topic URL, and the restart card (section 5) with the sha and the test still empty.
5. The holder and the owner name the entity of work in the discussion (and on the issue, which is the record). When it is agreed, the holder sets `todo`. Tool: `do_spl_issue_update`.
6. Spawn. The seed carries the key. The spawn sets `wip` and `ISSUE_ASSIGNEE` to the lane id, and `lane-map.sh put` records branch, files and topic. No key: the lane does not start (not built; section 6).
7. The lane works on its branch, rebases onto `origin/master`, runs `do_check_pre_push`, and pushes `HEAD:master` (`developer-guide.md:60-68`). The commit cites the key the way section 4 says.
8. The quality gate runs (`10_ci-quality.yml`). A commit that touches the hub path list deploys the hub to `dev` and `prd` (`20_hub-build-deploy.yml:48-64,157`) and mints a tag. A commit that touches the WUI path list does the same for the WUI (`30_wui-build-deploy.yml:37-45,135`).
9. Once an hour, on the one box that holds the cursor, `do_spl_issue_close_landed` comments the sha and the release URL and sets `done` (`issue-close-landed-cron.sh:1-11`, `spl-issue-close-landed.func.sh:138-149`). `done` and `diss` are no-ops. An epic or a feature is skipped. A reopened issue is not closed again by the same sha (`spl-issue-close-landed.func.sh:13-16`, `issue-close-landed.py:115-126`).
10. Before exit the lane runs `do_spl_issue_close_check` on its shas. Exit 3 means a named issue is still open: wait for the hour, or move it by hand (`spl-issue-close-check.func.sh:6-13,57`). That call is not wired into exit-clean yet: `git grep -l do_spl_issue_close_check` on this sha returns the action and its test only (n=2).
11. A lane that ends with no citing commit sets `diss`, or `blocked` when it is handing the same issue on, and the comment says why. Exit refuses a `wip` issue that has neither a landed citing sha nor that reason (not built; c-880).
12. A behaviour change under `csi-spl-api`, `csi-spl-orc`, `csi-spl-iac` or `csi-spl-wui` lands with a `csi-spl-doc/` change in the same commits, or with `Docs: none (<why>)` (not built). User-facing text in several languages is a subtask for the language reviewer and does not block the code commit.
13. The holder tells the owner in the source topic, with the key and the sha. The lane's report goes to the holder and to `c-001`, kind `result`. The lane posts nothing in the owner topic.
14. `lane-map.sh done`. The worktree and the branch are removed.

`qas` is not on steps 7-9. A human who wants a review sets it by hand, and sets `done` or sends it back to `wip` by hand. The hourly closer will also set `done` if a later commit cites the key, so a review that must stay open has to avoid a citing commit until the review is finished, or the reviewer reopens and the ledger then ignores that sha.

## 4. Branching and deployment

What is on this sha, and where it sits in the flow:

| piece | where | when it runs |
|---|---|---|
| One `master`. A lane branch is scratch and is removed after the land. | `developer-guide.md:15-22` | every change |
| Fetch, rebase onto `origin/master`, re-test, `git push origin HEAD:master`. A refused push is a rebase, never a force-push. | `developer-guide.md:60-73,92-100` | every push |
| `do_check_pre_push` before the push. Store or migration: `PRE_PUSH_TIER=full`. | `developer-guide.md:76-79` | every push |
| Quality gate, no path filter. | `10_ci-quality.yml:40-47` | every push to `master` |
| Hub deploy, `dev` and `prd`, path-filtered. | `20_hub-build-deploy.yml:48-64,157` | a hub-path push |
| WUI deploy, `dev` and `prd`, path-filtered. | `30_wui-build-deploy.yml:37-45,135` | a WUI-path push |
| Version tag, minted, not edited. | `release-version.func.sh:1-13` | inside those deploys |
| Deploy is current. | `do_check_deploy_lag` (`check-deploy-lag.func.sh:51-54`) | the lane's proof for a commit those deploys built |
| Release URL. | `do_release_note_link` (`release-note-link.func.sh:20-22`); the closer also writes one (`spl-issue-close-landed.func.sh:141`) | the closer at `done`; the lane again when the note exists |
| Citing commit closes the issue. | `issue-close-landed.py:75-84`, hourly cron | after the commit is on `master` |

Which commit cites the key (`issue-close-landed.py:75-84`, types at line 44):

- A `fix`, `feat`, `perf` or `refactor` subject whose scope contains the key (`fix(orc, SPL-12): ...`).
- Any subject that carries a `Closes: SPL-12` trailer. The function adds those keys with no type check (lines 81-82).
- A bare mention in the body does not. A `Refs:` trailer does not (the parser reads the `Closes` trailer only, lines 90-91).
- The file's header says a `docs`, `test` or `chore` subject and a revert never close (`issue-close-landed.py:28-29`). `commit_keys` does not implement that sentence. On this sha a `docs` commit with `Closes: SPL-12` does close. A later lane should make the header and the function the same. Until then, an answer-only or docs-only issue uses a `Closes:` trailer, and a `docs` subject must not use that trailer unless the author wants `done`.

### Option A — keep the trunk

No change to branches, the pre-push gate, CI, the two deploys or the tag. Issues and docs ride on this path. The lane branch stays scratch. `qas` stays a human status. `done` stays the hourly closer's move.

### Option B — a gate in front of master

The lane pushes its branch. CI runs there. The holder fast-forwards to `master` only after the issue is `qas`. Still no pull request. `dev` and `prd` still deploy from `master`.

### Recommendation

A. The developer guide records this trunk as the strategy that has carried the repository (`developer-guide.md:13-28`). The owner asked for issues, statuses and docs. He did not ask for a second branch step. Option B would put a human `qas` in front of the deploy, which is the opposite of the sentence the closer already implements ("done is the automatic target", `spl-issue-close-landed.func.sh:2-4`).

## 5. Context and restart

Today an issue can restart a lane only as prose. The fields that exist are title, description (20000), status, assignee, parent, labels, the issue's own topic, and the history trigger. Nothing stores a branch, a sha, a file list or a test command (`0047_issues.sql:44-75` plus the later columns in section 1.2).

The lane map stores branch, files, scope and topic for a live lane, for about two hours of "live" (`lane-map.sh:10-18`). `agent-watch.sh` prints `DIALOG` and nudges `MAIL` (`agent-watch.sh:1-10`). It does not read an issue and it does not spawn. A lane that waits about an hour is parked in a hold directory and respawned from that directory (`SPEC-spool-fleet-roles.md:43`). That directory dies with the box. The issue does not.

### The card

The description starts with these headings. The lane rewrites them when a fact changes, with `do_spl_issue_update` `ISSUE_DESCRIPTION` (or `ISSUE_DESCRIPTION_FILE`). 20000 characters is the budget (`internal/store/issues.go:71`).

```text
## Source
<topic url>

## Restart
- key: SPL-n
- spec: csi-spl-doc/specs/NNN-slug/spec.md
- scope: <paths>
- must not touch: <paths>
- test: <one command>
- last citing sha: <sha or none>
- open question: <one line, or none>
- docs: <path, or none: why>
```

A fresh agent is spawned with a brief that is `spool issue get` of that key and nothing else. Its branch is new, off `origin/master`, at `last citing sha` when the work has landed, or off the tip with the card's scope when it has not. The dead branch is not reused after a land, because the trunk rule deletes it (`developer-guide.md:20-21`). The hold directory is a cache of the card. It is not the source.

The assignee is the live lane id. On an exit that hands the work on, the lane sets `blocked`, clears nothing else, and the holder sets the assignee to the next lane at the next spawn. Role seats are not assignees of build work: they are not ended (`lane-map.sh:20-22`), so an issue assigned to `c-001` would look live forever.

### Option A — the card in the description

No migration. Works with `do_spl_issue_create` and `do_spl_issue_update` as they are. The lane map remains the live index of files and branches.

### Option B — columns

Add `source_task_id`, `spec_path`, `scope`, `test_cmd`, `head_sha`. Queryable. A migration, a store change, a WUI change, and a full pre-push tier.

### Recommendation

A. The restart reads one issue. The queries people already run (open by status, by assignee, by label) do not need the card's lines. Add a column only when a gate has to refuse on one of those lines without parsing the description. The first such gate, the exit check, already parses commits (`do_spl_issue_close_check`), not the description.

## 6. What today's lanes keep or change

One line each. "On master" means this sha. Briefs live under the dispatch briefs directory; they are input, not a decision.

| lane | keep or change |
|---|---|
| c-880 (brief `c002-lane-issue-and-docs.md`) | Keep the rule: the spawn files or links the issue, the seed carries the key, a lane with no key does not start, exit refuses `wip` with no landed citing sha and no reason, a behaviour change needs a doc edit or `Docs: none (<why>)`. Not on master (`git grep` of `ISSUE_` under `spawn-agents` was empty). Change: call `do_spl_issue_close_check` for the land half. Do not write a second parser. |
| c-350 (brief `c002-owner-question-not-issue.md`) | Keep. A question to the owner is not an issue until he says so. The hub still files one for every tagged assignee, owner included (`blocker_issue.go:31-42`). That exclusion is the change to build. The sweep's rule for agents and other members stays. |
| c-340 (brief `c001tnk-issue-discard-stale.md`) | Keep as landed. `do_spl_issue_discard_stale` (`a21286f20`) sets `diss`, comments the reason, never deletes. `needs-owner` and `keep` protect (`spl-issue-discard-stale.func.sh:24-26`). An epic with an open child is kept (lines 10-11). |
| c-339 (brief `c002-needs-owner-digest.md`) | Keep as landed (`ada13012e`). `do_spl_issue_needs_owner` adds the label, moves `eval` / `todo` / `wip` / `onhold` to `blocked`, leaves `blocked` and `qas`, refuses `done` and `diss`, and writes one Needs-owner line (`spl-issue-needs-owner.func.sh:1-16`). `do_spl_owner_digest_post` posts at most once a day, only from the dispatch holder's box, and posts nothing when the list is empty (`spl-owner-digest-post.func.sh:1-10`). The cron row is hourly (`box-crons.manifest:27`); the hour is `env.owner_digest` (`prd.env.yaml:416-419`). The discard action already keeps the label (`spl-issue-discard-stale.func.sh:25`). |
| c-341 (brief `c002-landed-fix-closes-issue.md`) | Keep as landed at this sha: `do_spl_issue_close_landed`, `do_spl_issue_close_check`, `issue-close-landed.py`, the hourly cron. `done` is the automatic target, not `qas`. Change to finish: wire the check into exit-clean (section 3 step 10), and make `issue-close-landed.py:28-29` match `commit_keys` (section 4). |
| slice checks (briefs `c001tnk-issue-check-s1.md` through `s8.md`; the c-880 brief names seats from g-342 on) | Keep read-only. One verdict per key, a TSV, no status write (`c001tnk-issue-check-s1.md:6-19`). Applying stays with the discard action and the closer. |

## 7. Owner questions

| | question | A | B | C | this seat |
|---|---|---|---|---|---|
| Q1 | When does a discussion become an issue? | At the first concrete answer, including "evaluate and answer". Pure talk stays a discussion with no issue. A question to the owner waits until he decides. One issue per lane. Several lanes that share a decision sit under one feature. | Every discussion gets one issue, including pure talk and questions to the owner. | Only the owner files an issue, from the page. | **A** |
| Q2 | When does the issue become `done`? | Keep the landed rule. A citing commit on `master` is set to `done` by the hourly `do_spl_issue_close_landed`, with the comment at `spl-issue-close-landed.func.sh:142-147`. `qas` is not on that path. A release URL that is early is a later comment, not a later status. | Stay `wip` until `do_check_deploy_lag` is 0 on `dev` and on `prd` for every deploy whose path list the commit touches. A commit that matches neither path list is `done` when the quality gate for that sha is green. | | **A** |
| Q3 | Who files the issue? | The dispatch holder, in the spawn path, before the lane starts. No key, no start. | The lane, in its first minutes. | The owner only. | **A** |
| Q4 | Where do the source link and the restart card live? | The top of the description. The holder posts the key back into the source topic. No migration. | New columns: `source_task_id`, `spec_path`, `scope`, `test_cmd`, `head_sha`. | | **A** |
| Q5 | Does the branch model change? | No. Trunk, rebase, push to `master`, pre-push gate, CI, both deploys, minted tags. The lane branch is scratch. | CI on the lane branch. The holder fast-forwards to `master` only after `qas`. Still no pull request. | | **A** |
| Q6 | When are docs updated? | In the same commits as a behaviour change under api, orc, iac or wui, or the message says `Docs: none (<why>)`. Multilingual user-facing text is a subtask and does not block the code commit. | Docs are always a follow-up subtask, and `done` waits for it. | | **A** |
| Q7 | What happens to `qas`? | It stays in the set for a review a human asked for. Nothing automatic enters it. | Remove it. That is a migration and a WUI change. | | **A** |

Q2 A matches the sentence the closer already codes (`spl-issue-close-landed.func.sh:2-4`) and matches a land being the automatic target rather than `qas`. Q2 B matches the developer guide's "a change is done when it is deployed in both environments" (`developer-guide.md:36-38`) more closely. This seat recommends A because that sentence is already code on this sha, and because a docs-only commit never deploys (section 1.6), so B would need a second definition of `done` for it anyway.

## Build after v1.0

Not this file. In the order the gates depend on each other:

1. c-350: the blocker sweep does not file an issue when the assignee's role is owner (`blocker_issue.go:31-42` is the rule to narrow).
2. c-880: spawn files the issue, the seed carries the key, a wait on the owner calls `do_spl_issue_needs_owner`, exit calls `do_spl_issue_close_check`, the doc-or-`Docs: none` refusal, one home for the rule text.
3. The closer's author: make `issue-close-landed.py:28-29` and `commit_keys` (`75-84`) agree, and point exit-clean at `do_spl_issue_close_check`.
4. A one-line header fix: `spl-issue-update.func.sh:6-7` still says `in_review`.
5. No branch-model change (Q5 A). No new issue column (Q4 A). No new status. c-339's label and digest are already on this sha.
