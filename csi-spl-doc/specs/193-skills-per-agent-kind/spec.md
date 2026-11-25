# Spec 193: the three most essential skills per agent kind

Status: **v1.0** (2026-11-25; editor c-774, claude). Panel: **same-vendor panel, waiver**: one claude seat, c-343 (agy is out of quota until 12-01, grok and mistral are off). It FAILed v0.1 (`99cc31e3c`) with W1-W8 and N1-N7; Appendix C maps each one to its change. Doc only: no skill, code, cnf or workflow changes here. The build is a later lane, after the owner picks (section 6).
Epic: **SPL-2402**. Issue: **SPL-6375** (label `answer`). Class: `feature`. Kind: `specs_and_docs`.
Discussion: t1 topic `b1ec7ce2`, task `dispatch-b1ec7ce2`.
Related: [115 vendor split by task kind](../115-vendor-split-by-task-kind/spec.md), [lane issue and docs](../../doc/md/lane-issue-and-docs.md), [developer guide](../../doc/md/developer-guide.md) section 2.

Baseline tree: the git counts ran on `origin/master` `7e31ade12fd86797b337cab9f55a3f654e5a0c4c`. v1.0 re-ran every count with [`join.py`](join.py) on raw files pinned to the window end (Appendix A).
Window: **2026-09-24T00:00Z .. 2026-11-24T11:25Z** (the last 2 months) for commits, issues and messages. **Lanes cover only 2026-10-03T03:06Z .. 2026-11-24T11:25Z**: the spawn log's first line is 2026-10-03T03:05Z and there is no rotated copy (section 7).
Numbering: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c /193` -> 0 (2026-11-25). 194 is taken by `194-workspace-google-drive-upload`, so 193 fills a gap.

## Owner's words (HUM-10, t1 `b1ec7ce2`, 2026-11-24)

> "Create a panel discussion to create the three most essential skills per agent kind, based on the vendor split settings for each of the agent kinds (based on the last 2 months of discussions and the type of work which has been done). By analyzing the database, the discussions, and the actual results, make how fast the feature has arrived." (msg `75bace2f`)

> "Note: the skills must be short, descriptive, and not overly generic. Create the topmost skills which give the most back for the buck." (msg `16f273e3`)

## 0. Answer in five lines

1. The time from the owner's ask to the result is spent **before the lane starts**, not in it: owner's last message -> lane placed has a median of 4.5 h (complex_coding) to 26.8 h (i18n), p90 34 h to 222 h. Lane placed -> landed has a median of 0.5 h to 1.8 h. Landed -> next release tag has a median of 0.3 h or less (section 3.4).
2. Inside the lane, the review rounds are the likely main cost (an inference: placed -> landed is not split into review time). 27 of the 82 complex_coding issues that got an R7 FAIL failed again on a second head (section 3.2).
3. The most common blocking findings in a hand-labelled sample of 45 are: **a failure path that fails open or is swallowed** (7), **a doc or claim that does not match the tree** (6), **a secret or authorisation leak** (6), and **a test that cannot go red** (5) (section 3.3).
4. Section 4 gives 21 skill slots (3 per kind), which come to **18 distinct skills** because 3 of them serve two kinds (section 5). None of them is a skill that already exists; S2 leaves migration numbers to the existing `do_rdb_migration_next` (section 4.0).
5. The owner picks in section 6: which kinds first, where the skills live, and whether the orchestration skills become code instead.

## 1. The kinds, as the vendor split defines them today

Source: `csi-spl-cnf/csi-spl/all.env.yaml` key `env.box.agent_split_by_kind` (`grep -n -A8 'agent_split_by_kind:' csi-spl-cnf/csi-spl/all.env.yaml`; no env file overrides it, `grep -l agent_split_by_kind csi-spl-cnf/csi-spl/*.env.yaml` -> only `all.env.yaml`). The main vendor is the one with the biggest share.

| kind | split (cnf) | main | backup |
|---|---|---|---|
| specs_and_docs | agy 80, mistral 15, claude 5 | agy | claude |
| tests | claude 70, agy 15, codex 15 | claude | agy |
| simple_coding | claude 44, agy 41, codex 15 | claude | agy |
| complex_coding | claude 90, agy 10 | claude | agy |
| i18n | agy 100 | agy | claude |
| secret | claude 100 | claude | grok |
| orchestration | claude 100 | claude | grok |

The skills must work for the main vendor and the backup. For simple_coding that means agy as well as claude (41 against 44). codex holds 15 in tests and in simple_coding but is neither main nor backup; it took 3 lanes in the window (3.1), and `do_spl_skills_refresh` renders no codex skill dir. In scope: the 6 vendors that render skills; codex gets them only if the build lane adds its dir (Q2).

## 2. How it was measured

All counts are for **this box's** spawns. The spawn log on the other machine was not read, so "n" here is a lower bound on the fleet's.

- **Lanes**: `SPAWNED` rows of `/var/spool-hub/spawn-remote/serve.log` before the window end (the first is 2026-10-03T03:06Z): n = **3293** (agent id, vendor, slug, brief id). The kind is the brief's `Kind:` line: the 7 kinds of section 1 hold 3237 lanes, 622 have no `Kind:` line, and 56 carry another value (`review` 37, `stability` 8, `clean` 3, `fleet` 3, `reviews` 3, `spec` 2). The issue is the brief's `Issue:` line (1000 lanes). For another 1727 lanes it is the hub issue whose title equals the brief's first line, because the spawn files the issue from the brief's title (65 of those titles were ambiguous: the lowest number was taken). That gives **2727 of 3293** lanes with an issue. **The kind of an issue** is the kind of the first lane (in log order) that carries it; an issue that lanes of two kinds worked counts under the first one only.
- **Landed work**: `git log origin/master --since=2026-09-24` -> **10532** commits. A commit belongs to an issue when its subject or a `Closes:` trailer names the key. **3133** distinct commits cite an issue that some lane carries. Counted per kind they make 3150 (commit, kind) pairs: 2968 in the 7 kinds, 158 for no-`Kind:` lanes, 24 for `review` and other values; 17 commits cite issues of two kinds and count under both.
- **Deploys**: the first release tag (`v<X.Y.Z>` or `v<X.Y.Z>-c<N>`, `git for-each-ref refs/tags/v*`) at or after the commit on the linear trunk. A push to master deploys dev and prd (developer guide 1.2) and each deploy mints its commit's version as a tag; that one tag time stands for both environments is **inferred** from this, not stated in the guide. Docs-only commits are left out (they do not deploy).
- **Owner ask**: the owner's (HUM-10) **last** t1 message in the issue's source topic (`## Source /t/<uuid>` in the description) before the issue was created. This is a **lower bound**: in a long topic the actual ask may be older.
- **Review failures**: t1 hub messages (`do_spl_db_query`, read-only) with an R7 `FAIL <sha>` verdict or a `SEND-BACK`, n = **1091** messages (v0.1 read 1101 with no end bound on the query). Reviews that stayed on one box and never reached the hub are missing, so these counts are lower bounds.
- **CI**: `gh run list --workflow 10_ci-quality.yml --branch master --limit 1000` (2026-11-15T19Z .. 2026-11-24T11Z, 748 finished runs) and `CI_GATE_RUNS=100 do_report_ci_gate`.
- Only t1 (the operator workspace) was read. No customer workspace, person or secret is quoted.

The commands are in Appendix A. The join of these sources is [`join.py`](join.py) (read-only); its rules are in its docstrings, and its output reproduces every table in section 3.

## 3. Evidence per kind

### 3.1 The work done

| kind | spawns (vendor) | issues | commits on master | author issues done / diss / open |
|---|---|---|---|---|
| specs_and_docs | 924 (claude 390, agy 205, grok 194, mistral 132, codex 3) | 642 | 932 | 137 / 19 / 9 |
| complex_coding | 715 (claude 693, grok 21, agy 1) | 599 | 1124 | 480 / 16 / 8 |
| simple_coding | 438 (claude 402, grok 22, mistral 11, agy 3) | 394 | 523 | 325 / 8 / 2 |
| tests | 217 (claude 213, grok 4) | 142 | 195 | 95 / 3 / 0 |
| secret | 205 (claude 184, grok 15, mistral 5, agy 1) | 159 | 128 | 85 / 17 / 8 |
| i18n | 116 (agy 99, claude 12, grok 5) | 64 | 66 | 8 / 8 / 1 |
| orchestration | 0 lanes (the role seats do it) | - | - | - |
| (no `Kind:` line; 620 in October, 2 in November) | 622 | 116 | 158 | - |
| (`Kind:` review 37, or another value 19) | 56 | 13 | 24 | - |
| **sum** | **3293** | | **3150 pairs = 3133 commits + 17 counted twice** | |

Spawns, issues and commits come from `join.py`. The last column was counted in v0.1's scratch join and is not in `join.py`. "Author issues" excludes the review, panel and seat lanes (slug matches `review|reviewer|r7|seat|panel|verif|audit`), because a seat's issue is closed `diss` by design. Two numbers need care:
- 6 of the 8 i18n "diss" lanes are agy or claude **language reviews** whose slug does not say "review"; the other 2 are LinkedIn post drafts. This is not failed work.
- 14 of the 17 secret "diss" lanes, judged by their titles, could not land a csi-spl commit by their nature: ops, analysis, or documents in other repos.

The spawn mix on this box is not the cnf split: specs_and_docs went to claude 390 times and to agy 205 times. The likely reason is the data rule (a brief that reads hub data is secret-class), but that was not checked per lane.

### 3.2 What went wrong

| kind | issues with any FAIL message | issues with >= 1 FAILed head | of them FAILed again on a 2nd head | max FAILed heads | CI red heads (last 748 runs) |
|---|---|---|---|---|---|
| complex_coding | 118 | 82 of 599 | 27 | 5 | 11 of 76 |
| specs_and_docs | 57 | 36 of 642 | 14 | 11 | 17 of 206 |
| simple_coding | 44 | 25 of 394 | 7 | 4 | 23 of 174 |
| tests | 18 | 15 of 142 | 4 | 2 | 1 of 14 |
| secret | 19 | 15 of 159 | 4 | 3 | 4 of 21 |
| i18n | 6 | 1 of 64 | 0 | 1 | 0 of 6 |

- A "FAILed head" is a distinct `FAIL <sha>` per issue, from a verdict that names the head (`FAIL` then a sha in the first 400 characters), so two reviewers failing the same head count once. "Any FAIL message" also counts relays and send-backs that name no head. That is why i18n has 6 issues with a FAIL message but 1 with a FAILed head. specs_and_docs was 37 in v0.1 (no end bound on the message query).
- The CI column was counted in v0.1's scratch join from the `gh run list` output of Appendix A and is not in `join.py`.
- A CI red is a red `10_ci-quality` run whose head commit cites an issue of that kind. The head is the pusher, not always the cause.
- CI is not the main cost: 7 of the last 100 runs failed (2026-11-23T13Z .. 2026-11-24T11Z). By the job that broke each run first: orc hermetic 4/4 broke 2, iac tfvars parity broke 2, hub go test broke 2 and orc hermetic 2/4 broke 1. One of the 7 (run `45223415636`, job orc hermetic 4/4) went red because an orc test printed a SKIP line: the gate fails a skipped check, because a skip proves nothing (`do_report_ci_gate` signature "an orc check skipped in CI").
- **Rework** (a second author lane on the same issue; v0.1 scratch, not in `join.py`): 3 specs_and_docs, 3 simple_coding, 2 complex_coding and 5 secret issues. This is rare. The cost is in the review rounds, not in respawns.

### 3.3 Why reviews fail: a hand-labelled sample

Keyword counts did not work. On a sample of 24, "red control" mostly matched a reviewer *reporting* that it ran the controls, which made only about 1 hit in 3 correct. So the blocking finding (`W1` / `B1`) of FAIL messages was read and labelled by hand.

The pool is the first `W1` / `B1` line of each FAIL message whose issues all map to one kind (`join.py`, `sample`). From it, a random draw (seed 11) took 14 complex_coding, 14 specs_and_docs, 10 tests and 6 secret messages. For simple_coding (pool 16) and i18n (pool 11) every message in the pool was taken. That makes 71 messages. 27 were dropped: 17 relays ("W1 fixed", "W1-W3 folded", a fold list), 5 verdict lines with no finding text ("W1 W2 W3 | log"), and 5 repeats of a finding already labelled on the same issue. The other 44 messages give **n = 45** findings (`fc46d63c` holds two). One labeller (this editor) did the labelling; Appendix B lists all 71 with their labels, and the panel may re-label.

**Which kind's lanes a finding came from.** The pool was split by the kind of the lane whose `Issue:` line names the issue (the sample map). Section 3.2 uses the kind of the issue's first lane, title matches included. The two disagree for 13 of the 45 findings. In 11 of them a complex_coding lane opened the issue and a later i18n, simple_coding, tests or specs_and_docs lane carried its `Issue:` line (SPL-5372 x3, SPL-5698 x2, SPL-4810, SPL-4895, SPL-4824, SPL-5349, SPL-5000, SPL-4654). In the other 2 a simple_coding lane opened it (SPL-5536 under specs_and_docs) or an i18n lane did (SPL-5480 under simple_coding). Appendix B gives both kinds and every lane kind on the issue. Each skill in section 4 says which kinds its evidence came from.

| class | n | examples (msg id prefix or issue) |
|---|---|---|
| failure path fails open, is swallowed or does not fail fast | 7 | `a7ebbac7`, `ebadef55`, `0c77b97f`, `5b1e8b4b`, `21a21369`, `a93e795a` (SPL-5698), `fc46d63c` W1 (SPL-5555) |
| doc, spec or claim does not match the tree | 6 | `53b09832`, `e25577a1`, `ece509e7` (coverage numbers wrong), `6ed5c1a1`, `a5e1921c`, `c5183570` (SPL-5740, "Docs: none" was false) |
| secret or authorisation leak | 6 | `ab83fbd3` (token on argv), `e5bd3a3f` (SPL-5495, alias env var stays exported), `3de9da82` (SPL-4881, token left on disk when turned off), `daa93e52` (SPL-4810, masked value leaks on wrap), `15040649` and `dd8af748` (SPL-4895) (another workspace or a locked box) |
| a test that cannot go red (mock, swallowed wait, runs on after an error) | 5 | `a4433661`, `b53cd5c6`, `b8d356f9`, `4ed63dca` and `72b35ee8` (SPL-5372) |
| regex or parse edge case | 4 | `66fea976`, `a70feab4`, `0ddab07c` (SPL-5555, unanchored), `fc46d63c` W2 (SPL-5555) |
| race or two writers | 3 | `c3fcfe47`, `388e3d15`, `15e33699` (SPL-4629) |
| numbered id collides with trunk or another branch | 3 | `198445a6` (migration + spec section), `5980f95c` (spec 3.17 / C71), `5ef4a572` (SPL-5372, 0276 on 3 branches) |
| spec leaves a case undefined or contradicts itself | 2 | `c3ff1e57`, `0a43b9dc` |
| issue-closing or trailer rule | 2 | `2e7df79c`, `9648cf2c` |
| a sibling of the fixed bug left in place | 1 | `5577c422` ("six more caller knobs, same bug class") |
| other (logic, layout at 360 px, word order, config precedence, literal fallback) | 6 | `56b6185f` (SPL-5698), `cddd2a68` (SPL-4824), `b3ab8726` (SPL-5349), `5f6ad82f` (SPL-5480), `8e0f1262` (SPL-1910), `aeef6c0e` |

The issue-closing and trailer findings (2) are left out of section 4 because `/exit-clean` (`kill-your-self-report.sh --gate`) and the closer already enforce them.

### 3.4 How fast the feature arrived

Hours, median / p90 (n), from `join.py`. Each segment is measured on the issues that have both ends, so the rows do not add up. v0.1 had complex_coding 4.0 / 34.3 (152) and 14.5 / 60.1 (140), simple_coding 12.4 (82) and specs_and_docs 8.6 (133) for owner ask -> placed; the v1.0 query of owner messages ends at the window end, and v0.1's did not.

| kind | owner ask -> placed | placed -> first commit | placed -> landed | landed -> release tag | owner ask -> deployed |
|---|---|---|---|---|---|
| complex_coding | 4.5 / 34.3 (147) | 0.2 / 1.3 (502) | 1.8 / 10.3 (543) | 0.0 / 0.9 (538) | 14.9 / 87.1 (135) |
| simple_coding | 12.2 / 128.8 (83) | 0.1 / 0.6 (348) | 0.9 / 3.7 (367) | 0.2 / 1.4 (364) | 13.8 / 137.9 (78) |
| specs_and_docs | 8.8 / 119.2 (130) | 0.2 / 0.8 (176) | 0.5 / 3.9 (295) | 0.2 / 1.2 (145) | 11.3 / 139.6 (59) |
| tests | 23.5 / 59.6 (41) | 0.2 / 1.6 (103) | 1.5 / 8.6 (135) | 0.3 / 2.1 (63) | 18.0 / 60.6 (21) |
| secret | 15.5 / 221.9 (27) | 0.2 / 3.9 (48) | 1.1 / 5.8 (52) | 0.1 / 0.8 (48) | 20.3 / 152.7 (13) |
| i18n | 26.8 / 85.0 (8) | 0.3 / 0.5 (12) | 0.7 / 9.5 (21) | 0.0 / 0.0 (21) | 37.7 / 87.3 (8) |

- "Placed" is the spawn time. Issue -> placed is a median of 0.0 h for every kind, because the spawn files the issue. So **owner ask -> issue** is the wait before the lane: a median of 2.6 h (complex_coding) to 22.4 h (tests), p90 33 h to 217 h.
- The hub's queue is not that wait. `fleet_asks` (rows from 2026-11-16) goes from created to done in a median of 0.1 h to 0.5 h per `work_kind`, p90 0.3 h to 10.1 h. The time goes into the step before the ask is queued: the dispatcher's draft, panel and spec rounds, plan signing, and the owner's answers.
- "First commit" is the earliest author date of a citing commit. It stands in for the first review head, because review branches are deleted after landing.
- **The biggest waits** (owner ask -> landed, `join.py` `longest_ask_to_landed`): SPL-5027 370 h (a spec 158 row); SPL-4835 293 h; SPL-6225 256 h; SPL-6204, SPL-6207, SPL-6208, SPL-6203 and SPL-6201 249 h to 252 h; SPL-6141 239 h; SPL-6133 236 h. SPL-6201, -6203 and -6207 are rows L4, L6 and L5 of spec 123 section 16.6. Each landed 0.4 h to 1.6 h after placement, so each was placed about 10 days after the owner's last message in that topic: **build-plan rows placed one after another**. Whether a real dependency held them was **not checked**.

## 4. The skills: three per kind

### 4.0 Not already a skill or an enforced rule

Checked on this box on 2026-11-24, and in the repo on 2026-11-25:
- `ls ~/.claude/skills` -> agent-msg, exit-clean, graft, kill-your-self, paste-html-into-chrome, scrum-file-update, spec-kit-tasks, synced, tmux-color.
- `ls .claude/skills` in the repo -> none. But the repo has a skill home: `git ls-tree -r --name-only origin/master | grep -E '/SKILL\.md$'` -> 7 files: `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{agent-msg,exit-clean,kill-your-self,paste-html-into-chrome,spec-kit-tasks,tmux-color}/SKILL.md` and `csi-spl-orc/src/bash/features/graft/assets/skills/graft/SKILL.md`. `do_spl_skills_refresh` (`csi-spl-orc/src/bash/run/spl-skills-refresh.func.sh`) renders `spawn-agents/assets` into `~/.claude` and, where the dirs exist, `~/.qwen/skills`, `~/.gemini/config/skills`, `~/.vibe/skills` and `~/.grok/skills`. None of the 18 skill names below is taken.
- `csi-spl-orc/src/bash/features/spool-install/assets/` -> claude (settings, claude-md), agy/rules (`30-exit-after-accepted.md`, `40-git-no-pager.md`), kill-guard, rm-guard, vibe-output-cap, vibe-push-guard.

These existing gates leave a gap that each pick below fills:
- Migration numbers are already covered: `do_rdb_migration_next` claims the next number on the remote (`refs/rdb-claims/NNNN`) before the file is written (`csi-spl-orc/src/bash/run/rdb-migration-next.func.sh`, SPL-5515, landed 2026-11-14; developer guide 2.8.3), and `lint-migration` refuses a taken number at push time. Nothing claims spec folders, spec sections, case ids or plan row ids. S2 is cut to those.
- `do_spl_review_line_check` proves that the reviewer ran the named tests (developer guide 2.12.1, which names review as the only enforcement). Nothing proves on the author's side that a new test went red on the planted defect.
- `kill-your-self-report.sh --gate` checks that a `Docs: none (...)` line is **present**, not that it is true.
- `TestRLSCoversEveryTenantTable` works at the table level, not per route.
- `lint-gitleaks` and `lint-trufflehog` find secrets in files, not on argv or in a child's environment.
- `do_spl_spec_rows_unqueued` (daily digest) finds rows that are unqueued, not rows queued one at a time.
- `do_spl_unanswered_sweep` finds owner posts with no answer, not answered asks that were never enqueued.

Each skill below gives: name, trigger, what it does (5 lines or fewer), the evidence, **the kinds its evidence came from** (the issue's first-lane kind, Appendix B), and the expected gain (a target the build lane re-measures with Appendix A).

### 4.1 specs_and_docs (main agy, backup claude)

**S1 `claim-reruns-before-push`**
- Trigger: a doc or spec diff that contains a number, count, path or "command -> result" claim.
- Does: (1) finds every claim line in the diff that carries a command (backticked command, then `->`, then a result). (2) Re-runs each one read-only on the tree it names. (3) Prints MATCH or DIFF per line. (4) Refuses the push on a DIFF. (5) Flags a bare number with no command as "unchecked".
- Evidence: "doc or claim does not match the tree" is 6 of 45 sampled findings (3.3), including wrong coverage numbers (`ece509e7`) and a false sentence about what deploys (`a5e1921c`).
- Evidence kinds: specs_and_docs 4 of the 6 (`53b09832` is complex_coding, `c5183570` simple_coding).
- Gain: specs_and_docs issues that FAIL again on a 2nd head, 14 of 36 -> under 7.

**S2 `numbered-id-claim`** (shared with complex_coding)
- Trigger: a new spec folder, spec section number, case id (`C71`) or plan row id. Migration numbers are out: `do_rdb_migration_next` claims them (4.0).
- Does: (1) lists the ids already taken on `origin/master`, every `review/*` and `wip/*` branch and every live worktree. (2) Prints the next free id. (3) Before each review head, runs `git merge-tree --write-tree origin/master HEAD` and flags an id this diff adds that another ref also adds.
- Evidence: numbered-id collisions are 3 of 45 (3.3). Two remain in scope after the cut: spec section 3.17 / cases C71-C72 (`5980f95c`) and the spec section half of `198445a6`. The third, migration 0276 on 3 branches (`5ef4a572`, SPL-5372, 2026-11-12/13), predates `do_rdb_migration_next` (2026-11-14). In this spec's own v0.1, the specs README row collided with spec 194 (c-343 W2).
- Evidence kinds: complex_coding 2 of 2. From specs_and_docs lanes: none in the sample; only this lane (n = 1). The specs_and_docs slot is therefore thin; the complex_coding slot (X1) carries the evidence.
- Gain: spec-section and case-id collision FAILs, 2 in the sample -> 0.

**S3 `fold-ledger-delta`**
- Trigger: the editor or author receives a FAIL or SEND-BACK with W/N lines.
- Does: (1) writes one table, `W/N id | file:line changed | commit | check command -> result`. (2) Requires a check per W (e.g. `grep -c '25 posts' spec.md -> 0`). (3) Pushes ONE new head and sends the table, so the reviewer reviews a delta.
- Evidence: of the specs_and_docs issues with a FAILed head, 14 of 36 failed again on a later head, and one went to 11 FAILed heads (3.2). In the sample, the same issues come back with W-lines on the same code (SPL-5698, SPL-4629, SPL-4881).
- Evidence kinds: the 14 of 36 are specs_and_docs; the three sample issues are complex_coding, simple_coding and secret.
- Gain: maximum FAILed heads per specs_and_docs issue 11 -> 3 or fewer; repeat-FAIL share 14 of 36 (39 %) -> under 20 %.

### 4.2 tests (main claude, backup agy)

**T1 `red-control-in-commit`**
- Trigger: a commit that adds or changes a test.
- Does: (1) reverts the fix, or plants the bug, in a throwaway copy. (2) Runs only the new cases and records `rc` and the failing count. (3) Re-applies the fix and records the green run. (4) Writes both lines into the commit body. (5) Refuses when the new case did not run (it was skipped or 0 cases matched).
- Evidence: "a test that cannot go red" is 5 of 45 (3.3): a test that checks the mock instead of the contract (`a4433661`), controls that stay green (`b53cd5c6`), e2e that runs on after an error (`b8d356f9`). One of 7 recent CI reds was an orc test that printed SKIP (3.2).
- Evidence kinds: tests 2 of 3 (`b53cd5c6`, `b8d356f9`); `a4433661` is complex_coding.
- Gain: vacuous-test findings, 5 in 45 -> 1 or fewer; tests issues with an R7 FAIL, 15 of 142 -> under 8.

**T2 `failure-path-cases`** (shared with simple_coding)
- Trigger: a diff that calls something that can be missing or fail: a binary, file, OS user, hub read, network or child process.
- Does: (1) lists each such call site. (2) For each one, writes the case where it is missing or fails. (3) Asserts the documented outcome: fail fast (`rc != 0`, FATAL on stderr) or a **named** fail-open. (4) Refuses `|| true`, `.catch(() => null)` or `2>/dev/null` without a comment that names the decision.
- Evidence: the largest class, 7 of 45 (3.3): a FATAL text captured as a unit name (SPL-5698), a match that fails open (SPL-4343), a source status discarded (`5b1e8b4b`), a failed hub read that goes on (`ebadef55`), an uncaught missing tool (`fc46d63c`).
- Evidence kinds: complex_coding 4 (`a7ebbac7`, `ebadef55`, `0c77b97f`, `a93e795a`), simple_coding 1 (`21a21369`), specs_and_docs 1, secret 1. **From tests lanes: 0 of 7.** It sits under tests because each failure path becomes a test case; the simple_coding slot (C1) has its own items (`21a21369`; `a93e795a`, SPL-5698, also had a simple_coding lane).
- Gain: failure-path findings, 7 in 45 -> 2 or fewer.

**T3 `e2e-no-swallowed-waits`** (shared with i18n)
- Trigger: a WUI e2e test is added or changed.
- Does: (1) refuses `.catch(() => null)` on `waitFor*`. (2) Stops the case at the first navigation error. (3) Runs against the generated bundle (`nuxt generate` + mock serve), never `nuxi dev`. (4) Repeats a new case 3 times (n = 3) before it is called green.
- Evidence: SPL-5372 (FAIL W1 twice: a swallowed 8 s wait, then a pick that fails on `nuxi dev`), SPL-5441 (`b8d356f9`: the test runs on after `nav()` fails). The WUI e2e shards are 8 of the gate's jobs (`do_report_ci_gate`).
- Evidence kinds: tests 1 (`b8d356f9`); SPL-5372 2 (`4ed63dca`, `72b35ee8`), whose first lane is complex_coding and which an i18n lane also carried.
- Gain: e2e findings of this shape, 3 in 45 -> 0. These 3 are inside the 5 of "a test that cannot go red" (3.3), not a class of their own.

### 4.3 simple_coding (main claude, backup agy)

**C1 `failure-path-cases`**: see T2. It is counted once. simple_coding evidence: `21a21369` (a match that fails open, SPL-1910 lane) and `a93e795a` (SPL-5698, which a simple_coding lane carried).

**C2 `sweep-bug-class`**
- Trigger: a reviewer W names a bug, or the lane fixes one.
- Does: (1) turns the bug into a search pattern (the bad call, the unanchored regex, the unset env knob). (2) Greps the whole repo for siblings. (3) Fixes them in the same head, or lists them with a reason. (4) Adds one test per sibling fixed.
- Evidence: `5577c422` ("six more caller knobs still reach the hook, same bug class as your knob fix"); SPL-5698 and SPL-4629, which each came back with several FAIL messages on the same function. 7 of the 25 simple_coding issues with a FAILed head failed again on a 2nd head (3.2).
- Evidence kinds: complex_coding (`5577c422`, SPL-5698) and simple_coding (SPL-4629).
- Gain: simple_coding repeat FAILs, 7 of 25 -> 3 or fewer.

**C3 `docs-none-proof`**
- Trigger: a commit message with `Docs: none (...)`, or a behaviour change with no `csi-spl-doc/` path.
- Does: (1) takes the changed identifiers (action names, env vars, function names, event kinds, file names) from the diff. (2) Greps `csi-spl-doc/` and the root `*.md` for each one. (3) Prints every hit with `file:line`. (4) A hit means a doc to update, or a written reason why it still holds.
- Evidence: SPL-5740, where the W1 was "the Docs: none reason is wrong, two docs go false with this commit". `6ed5c1a1` (fleet-rules-index row stale after the code moved). "Doc does not match tree" is 6 of 45.
- Evidence kinds: simple_coding 1 (`c5183570`), complex_coding 1 (`53b09832`), specs_and_docs 1 (`6ed5c1a1`).
- Gain: doc-drift findings on coding lanes, 2 in 45 (`c5183570`, `53b09832`) -> 0.

### 4.4 complex_coding (main claude, backup agy)

**X1 `numbered-id-claim`**: see S2. It is counted once. complex_coding evidence: `5980f95c` and `198445a6` (both SPL-4798, a complex_coding lane).

**X2 `shared-state-two-writer-test`**
- Trigger: a diff that reads, then writes, shared state: a Postgres row or counter, a file under the spool root, a ledger or a cron-trimmed log.
- Does: (1) names each read-modify-write. (2) Puts it in one transaction (`SELECT ... FOR UPDATE`) or under one `flock`. (3) Adds a test with two writers started together (`&` + `wait`, or two goroutines) that fails without the lock.
- Evidence: "race or two writers" is 3 of 45: a login lockout counted before it is recorded, with no transaction (`c3fcfe47`), a trim that loses another mount's record (SPL-4629), a mirror key that does not move `updated_at` (`388e3d15`).
- Evidence kinds: complex_coding 2 (`c3fcfe47`, `388e3d15`), simple_coding 1 (`15e33699`).
- Gain: race findings, 3 in 45 -> 0.

**X3 `route-authz-matrix`**
- Trigger: a new or changed hub route or read that returns workspace data, or a WUI view over one.
- Does: runs a table-driven test over caller = {owner, member, guest/demo role, another workspace's owner, a box locked to someone else} x action = {read, list, counts, write}. It expects 403 or an empty, counted result where the spec says so. It checks the credential **type** (view token vs upload token), not only that a mock answered.
- Evidence: `15040649` (any workspace's channel owner could make the operator fleet spawn), SPL-4895 (counts and unread of a locked box leak), `a4433661` (the WUI sends the view token where the hub accepts only an upload token).
- Evidence kinds: complex_coding 3 of 3.
- Gain: authorisation-shaped findings, 3 in 45 -> 0; complex_coding issues with a FAILed head, 82 of 599 -> under 60. The 3 cut across the 3.3 classes: 2 (`15040649`, `dd8af748`) are in the leak class, and `a4433661` is labelled "a test that cannot go red".

### 4.5 i18n (main agy, backup claude)

**L1 `locale-fit-at-360`**
- Trigger: a new or changed WUI string in any locale.
- Does: (1) for each changed key, picks the longest of the 19 locale values. (2) Renders the view in Chrome at 360 px and 412 px with that value. (3) Fails on overlap with a neighbouring control, clipping without an ellipsis, or a horizontal scroll.
- Evidence: SPL-5349 W1 (`b3ab8726`, the `✓ N` badge drawn over the card-size control at 360 px).
- Evidence kinds: SPL-5349's first lane is complex_coding; an i18n lane and a specs_and_docs lane also carried it. n = 1: **thin**.
- Gain: layout FAILs on i18n rows, 1 in 45 -> 0, and no locale-only follow-up lane.

**L2 `native-word-order-pass`**
- Trigger: user-facing copy in several languages (WUI, blog, help), before the GCT check.
- Does: a per-language checklist, run before the machine check: (1) word order of time and frequency phrases ("24/7"). (2) Anglicisms with a native form. (3) Quote marks, number and date formats. (4) Formal vs informal address kept the same per locale. It prints each change as `locale key: old -> new`.
- Evidence: SPL-5480 W1/W2 (German "In Produktion 24/7." in English word order; French bare "24/7"). These are not translation-meaning errors, so a back-translation check does not catch them.
- Evidence kinds: SPL-5480's first lane is i18n (a later simple_coding lane carried its `Issue:` line). n = 1: **thin**.
- Gain: language W-lines per multilingual lane, measured as 2 in SPL-5480 -> 0. The panel may drop this one (Q5).

**L3 `e2e-no-swallowed-waits`**: see T3. It is counted once. i18n evidence: SPL-5372 (`4ed63dca`, `72b35ee8`), which an i18n lane carried; its first lane is complex_coding. One issue: **thin**.

All three i18n skills rest on one issue each. i18n has 6 issues with a FAIL message and 1 with a FAILed head (3.2), so a thicker baseline does not exist yet.

### 4.6 secret (main claude, backup grok)

**K1 `secret-off-argv-and-env`**
- Trigger: a diff that passes a token, key or password to a child process, a TUI or a log.
- Does: (1) refuses a secret on argv (it is readable in `/proc/<pid>/cmdline`). Pass it by file descriptor, stdin or a 0600 file. (2) Unsets **every alias** of the variable before exec, not only the canonical name. (3) Masks the whole value after wrapping, not per line. (4) A test reads the child's `/proc/<pid>/cmdline` and `environ`.
- Evidence: `ab83fbd3` (a bearer token on curl argv), SPL-5495 (an alias of the token variable left exported in 18 actions), SPL-4810 (a masked value's tail leaks on a hard wrap).
- Evidence kinds: secret 1 (`e5bd3a3f`), specs_and_docs 1 (`ab83fbd3`), complex_coding 1 (`daa93e52`).
- Gain: secret-leak findings, 3 in 45 -> 0.

**K2 `secret-teardown-on-disable`**
- Trigger: a feature that stores a credential, token file, cron line or saved option, and has an off switch.
- Does: (1) lists everything the "on" path writes. (2) A test turns the feature on, then off, and asserts that each item is gone and that nothing restarts.
- Evidence: SPL-4881, with 3 FAIL or SEND-BACK messages for the same W1 (turning the watchdog off left the token on disk and the loop restarting).
- Evidence kinds: secret (SPL-4881).
- Gain: repeat FAILs on secret lanes, 4 of 15 -> 1 or fewer.

**K3 `parse-boundary-cases`**
- Trigger: a diff that adds or changes a regex or a hand parser (bash `[[ =~ ]]`, Python `re`, Go `regexp`, jq).
- Does: (1) the regex is anchored at both ends, or carries a comment that says why not. (2) Adds table cases: prefix and suffix neighbours, digits next to words ("fourteen years" vs "4"), an empty value, quotes inside quotes, a trailing newline (`\z` vs `$`).
- Evidence: regex or parse edge cases are 4 of 45: `0ddab07c` (an unanchored, shortest-first `YEARS_RX` matched "fourteen" as 4), `fc46d63c` W2 ("five years" marked backed), `a70feab4` (a count read as a verdict), `66fea976` (a path resolved through a symlink).
- Evidence kinds: secret 2 (`0ddab07c`, `fc46d63c`, both SPL-5555, a secret-kind lane), tests 1, simple_coding 1.
- Gain: parse findings, 4 in 45 -> 1 or fewer.

### 4.7 orchestration (main claude, backup grok)

No lane in the window carried `Kind: orchestration`: the role seats (dispatch and orch lease holders) do this work. The evidence is the lead time in 3.4. Owner rule: "orchestration = code, not intelligence", so an if-else rule belongs in code. Question Q4 in section 6 therefore asks whether these three become actions instead of skills.

**O1 `plan-rows-parallel-place`**
- Trigger: a build plan gets its GO, or a plan row lands.
- Does: (1) reads the plan's rows and their paths. (2) Runs `lane-map.sh --check` on each row against the others. (3) Enqueues every row whose paths are disjoint and whose `SPAWN_AFTER` prerequisite is met, all in one sweep. (4) Prints each held row with the row it waits on.
- Evidence: SPL-6201, SPL-6203 and SPL-6207 (spec 123 rows L4, L6, L5) took 249 h to 252 h from the owner's last message to landing, while placed -> landed was about 1 h each (3.4).
- Gain: owner ask -> placed p90 -> under 24 h for plan rows. Plan rows were not measured apart: the baseline is a **proxy**, the all-row p90 of complex_coding (34.3 h) and simple_coding (128.8 h).

**O2 `owner-ask-same-sweep-enqueue`**
- Trigger: a dispatcher sweep finds an owner message that it has answered, but with no ask in the queue and no issue.
- Does: (1) when the ask is a clear order (no open question, and no panel needed by the work-process rules), drafts the brief and enqueues it in the **same** sweep. (2) Otherwise it writes the one blocking question as a poll form and marks the issue `needs-owner`. (3) It never leaves an answered owner ask with neither.
- Evidence: owner ask -> issue, median 2.6 h to 22.4 h, p90 33 h to 217 h, against a queue of 0.1 h to 0.5 h (3.4). On owner ask -> issue, tests waits the longest (median 22.4 h, n = 41); on owner ask -> placed, i18n does (26.8 h, n = 8).
- Gain: median owner ask -> placed for tests 23.5 h -> under 4 h; for all kinds, under 4 h.

**O3 `brief-header-complete`**
- Trigger: before a brief is enqueued.
- Does: refuses a brief whose header lacks any of `Issue:` (or "spawn files it"), `Epic:`, `Spec:`, `Kind:` (one of the 7 cnf kinds) and `Topic:`, each in its machine-readable form.
- Evidence: 622 of 3293 briefs (all in October) have no `Kind:` line. Only 1000 carry an `Issue:` line, so 1727 lanes in this spec could be tied to their issue only by title, 65 of them ambiguously. A lane without these lines is invisible to every per-kind measurement, including this one.
- Gain: briefs with both `Kind:` and `Issue:` lines, 990 of 3293 (30 %; `join.py` `lanes_with_kind_and_issue_line`) -> 95 % or more.

## 5. Cross-kind overlap: 21 slots, 18 skills

| skill | kinds | counted |
|---|---|---|
| `numbered-id-claim` | specs_and_docs, complex_coding | once |
| `failure-path-cases` | tests, simple_coding | once |
| `e2e-no-swallowed-waits` | tests, i18n | once |

The other 15 are each used by one kind. `sweep-bug-class` would also help complex_coding (`5577c422`), and `fold-ledger-delta` would help every author lane. They are listed under one kind each, to keep exactly three per kind.

| # | kind | skill 1 | skill 2 | skill 3 |
|---|---|---|---|---|
| 1 | specs_and_docs | claim-reruns-before-push | numbered-id-claim | fold-ledger-delta |
| 2 | tests | red-control-in-commit | failure-path-cases | e2e-no-swallowed-waits |
| 3 | simple_coding | failure-path-cases | sweep-bug-class | docs-none-proof |
| 4 | complex_coding | numbered-id-claim | shared-state-two-writer-test | route-authz-matrix |
| 5 | i18n | locale-fit-at-360 | native-word-order-pass | e2e-no-swallowed-waits |
| 6 | secret | secret-off-argv-and-env | secret-teardown-on-disable | parse-boundary-cases |
| 7 | orchestration | plan-rows-parallel-place | owner-ask-same-sweep-enqueue | brief-header-complete |

## 6. The owner's choices (for a poll form)

Each question puts the recommended option first, says why in one line, and names the part of this spec its answer changes. The questions are Q1..Q7; O1..O3 stay the names of the orchestration skills (4.7).

- **Q1. Which kinds are built first?** (A, recommended) the 3 shared skills first (`failure-path-cases`, `numbered-id-claim`, `e2e-no-swallowed-waits`): they fill 6 of the 21 slots with 3 builds; (B) the coding kinds first (tests, simple_coding, complex_coding: the most FAILed heads, 3.2); (C) all 7 kinds at once. -> Changes the order of the section 5 table and the build lanes' briefs.
- **Q2. Where do the skills live?** (A, recommended) in the repo under `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/`, rendered per vendor by the existing `do_spl_skills_refresh` (4.0): no new mechanism; (B) in the repo, read by the brief; (C) only in each agent user's home. -> Changes the paths in section 4.0 and the build lanes' scope; under A, a codex dir is a one-line add (section 1).
- **Q3. Skills that a script can check (S1, S2, T1, C3, O3)?** (A, recommended) the skill plus a gate action that refuses: 3.2 shows repeat FAILs on rules the authors already knew, so advice alone is not enough; (B) the skill only; (C) the gate only. -> Changes the "Does" lines of S1, S2, T1, C3 and O3 (each gains its gate action).
- **Q4. The orchestration three (O1, O2, O3)?** (A, recommended) build them as `./run` actions (code), not skills: owner rule "orchestration = code, not intelligence"; (B) skills for the role seats; (C) drop them. -> Changes section 4.7 and the orchestration row of the section 5 table.
- **Q5. `native-word-order-pass` (n = 1 issue)?** (A, recommended) keep it and re-measure under Q6: the i18n kind has no thicker baseline (4.5); (B) replace it with the panel's next pick. -> Changes 4.5 L2 and the i18n row of the section 5 table.
- **Q6. Re-measure the gains?** (A, recommended) 30 days after landing, with `join.py` and Appendix A: the window here is 52 to 61 days, so 30 days gives about half the n; (B) 14 days; (C) no re-measure. -> Changes every "Gain" line in section 4 (its date) and Appendix A.
- **Q7. Who builds?** (A, recommended) one lane per kind, its vendor from the cnf table: the skills must work for that kind's main and backup (section 1); (B) one claude lane for all. -> Changes no section here; it sets the build lanes' `Kind:` and vendor.

## 7. Limits

- This box's spawn log only. The other machine's lanes and reviews that never reached the hub are missing, so every n is a lower bound.
- **The spawn log starts 2026-10-03T03:05Z** (no rotated copy), so lanes cover 52 days while commits, issues and messages cover 61. A commit from 2026-09-24 .. 2026-10-03 maps to a kind only when it cites an issue that a later lane carries.
- 622 lanes (19 %) have no `Kind:` line and 56 carry another value: they are outside every per-kind number.
- The owner-ask time is the last owner message in the source topic before the issue (a lower bound on the wait).
- The issue for 1727 lanes comes from a title match; 65 were ambiguous (the lowest number was taken).
- The kind of an issue is its first lane's kind. The 3.3 sample was split by a different map (the lane with the `Issue:` line); 13 of the 45 findings differ (3.3, Appendix B).
- The section 3.3 classes come from one labeller on n = 45. The panel may re-label (Appendix B).
- CI covers 2026-11-15T19Z .. 2026-11-24T11Z, 9 of the 61 days: `gh run list` returns at most 1000 runs. 748 of the 1000 finished as success or failure; the other 252 are not counted. A re-fetch on 2026-11-25 of 2026-11-16 .. 2026-11-24T11:25Z (935 runs) shows every such run as `cancelled` (231 of 935), a run superseded by a newer push.
- "First commit" stands in for the first review head (3.4).
- The release-tag time stands for both dev and prd (inferred, section 2). `do_check_deploy_lag` gives only the current lag, not history.
- The CI column, the author-issue status column and the rework counts come from v0.1's scratch join and are not in `join.py`.

## Appendix A. Commands (v1.0 run 2026-11-25, read-only)

Raw files go in one directory (`<raw>`); `join.py` joins them. Window end `E=2026-11-24T11:25:00Z`.

1. Kinds: `grep -n -A8 'agent_split_by_kind:' csi-spl-cnf/csi-spl/all.env.yaml`
2. Lanes (read by `join.py` itself from `$SPAWN_DIR/serve.log` and `$SPAWN_DIR/briefs/<id>.md`): `awk -F'\t' '$2=="SPAWNED" && $1>="2026-09-24" && $1<"2026-11-24T11:25:00Z"' /var/spool-hub/spawn-remote/serve.log | wc -l` -> 3293
3. `<raw>/commits.raw`: `git log 7e31ade12 --since=2026-09-24T00:00:00Z --format='%H%x09%aI%x09%cI%x09%s%x1e%b%x1f'` -> 10532 records
4. `<raw>/tags.tsv`: `git for-each-ref --format='%(refname:short)%09%(creatordate:iso-strict)%09%(*objectname)%(objectname)' 'refs/tags/v*'` (`join.py` drops tags created after E)
5. `<raw>/issues.txt`: `cd csi-spl-orc && ENV=prd SQL="select number||'|'||created_at||'|'||status||'|'||coalesce(completed_at::text,'')||'|'||coalesce(substring(description from '/t/([0-9a-f-]{36})'),'')||'|'||array_to_string(labels,',') as r from issues where tenant_id='t1' and created_at>='2026-09-24' and created_at<'$E' and deleted_at is null" ./run -a do_spl_db_query` -> 6354 rows
6. `<raw>/titles.txt`: `SQL="select number||'|'||regexp_replace(left(title,200),'[|\s]+',' ','g') as r from issues where tenant_id='t1' and created_at>='2026-09-20' and created_at<'$E' and deleted_at is null"` -> 6354 rows
7. `<raw>/owner_msgs.txt`: `SQL="select task_id||'|'||ts as r from messages where tenant_id='t1' and from_id='HUM-10' and ts>='2026-09-01' and ts<'$E'"` -> 1371 rows
8. `<raw>/fails.txt`: `SQL="select msg_id||'|'||ts||'|'||from_id||'|'||kind||'|'||coalesce(array_to_string(array(select distinct m[1] from regexp_matches(body,'SPL-([0-9]+)','g') m),','),'')||'|'||(left(body,300) ~ 'SEND-BACK')::text||'|'||left(regexp_replace(body,'\s+',' ','g'),2000) as r from messages where tenant_id='t1' and ts>='2026-09-24' and ts<'$E' and mirror_of is null and (left(body,300) ~ 'SEND-BACK' or left(body,400) ~ '\m(R7|review|reviewer|verdict)\M.{0,80}\mFAIL\M')"` -> 1091 rows
9. Join: `SPAWN_DIR=/var/spool-hub/spawn-remote python3 -I csi-spl-doc/specs/193-skills-per-agent-kind/join.py <raw> 2026-11-24T11:25:00Z` (needs read access to the spawn dir) -> JSON with every number of 3.1 (spawns, issues, commits), 3.2 (FAIL columns), 3.3 (pool sizes, the seed-11 draw, the labels of `labels.tsv`) and 3.4.
10. Queue: `SQL="select work_kind, count(*), percentile_cont(0.5) within group (order by extract(epoch from updated_at-created_at)/3600) from fleet_asks where tenant_id='t1' and created_at>='2026-09-24' and state='done' group by 1"`
11. CI: `gh run list --workflow 10_ci-quality.yml --branch master --limit 1000 --created '>=2026-09-24' --json headSha,createdAt,conclusion` -> 1000 runs (oldest 2026-11-15T19:10Z); `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
12. Existing skills: `ls ~/.claude/skills .claude/skills csi-spl-orc/src/bash/features/spool-install/assets/*`; `git ls-tree -r --name-only origin/master | grep -E '/SKILL\.md$'`

## Appendix B. The 71 sampled messages and their labels

From `join.py` (`labels`); the labels are [`labels.tsv`](labels.tsv). "Sample kind" is the kind the pool was split by; "first lane" is the issue's kind in 3.1 and 3.2; "lane kinds" are all kinds of lanes that carried the issue. A `drop:` row is not one of the 45.

| msg | issue | sample kind | first lane | lane kinds | label |
|---|---|---|---|---|---|
| `a7ebbac7` | SPL-4817 | complex_coding | complex_coding | complex_coding | fail-open |
| `ebadef55` | SPL-4789 | complex_coding | complex_coding | complex_coding, i18n | fail-open |
| `0c77b97f` | SPL-4680 | complex_coding | complex_coding | complex_coding | fail-open |
| `5b1e8b4b` | SPL-5632 | specs_and_docs | specs_and_docs | specs_and_docs | fail-open |
| `21a21369` | SPL-1910 | simple_coding | simple_coding | simple_coding | fail-open |
| `a93e795a` | SPL-5698 | simple_coding | complex_coding | complex_coding, simple_coding | fail-open |
| `fc46d63c` | SPL-5555 | secret | secret | secret | fail-open |
| `53b09832` | SPL-4443 | complex_coding | complex_coding | complex_coding | doc-tree |
| `e25577a1` | SPL-5868 | specs_and_docs | specs_and_docs | specs_and_docs | doc-tree |
| `ece509e7` | SPL-4747 | specs_and_docs | specs_and_docs | specs_and_docs | doc-tree |
| `6ed5c1a1` | SPL-4499 | specs_and_docs | specs_and_docs | specs_and_docs | doc-tree |
| `a5e1921c` | SPL-6302 | specs_and_docs | specs_and_docs | specs_and_docs | doc-tree |
| `c5183570` | SPL-5740 | simple_coding | simple_coding | simple_coding | doc-tree |
| `ab83fbd3` | SPL-6036 | specs_and_docs | specs_and_docs | specs_and_docs | secret-authz |
| `e5bd3a3f` | SPL-5495 | secret | secret | secret | secret-authz |
| `3de9da82` | SPL-4881 | secret | secret | secret | secret-authz |
| `daa93e52` | SPL-4810 | i18n | complex_coding | complex_coding, i18n | secret-authz |
| `15040649` | SPL-5000 | tests | complex_coding | complex_coding, i18n, tests | secret-authz |
| `dd8af748` | SPL-4895 | i18n | complex_coding | complex_coding, i18n | secret-authz |
| `a4433661` | SPL-5560 | complex_coding | complex_coding | complex_coding | vacuous-test |
| `b53cd5c6` | SPL-4985 | tests | tests | specs_and_docs, tests | vacuous-test |
| `b8d356f9` | SPL-5441 | tests | tests | tests | vacuous-test |
| `4ed63dca` | SPL-5372 | i18n | complex_coding | complex_coding, i18n | vacuous-test |
| `72b35ee8` | SPL-5372 | i18n | complex_coding | complex_coding, i18n | vacuous-test |
| `66fea976` | SPL-5536 | specs_and_docs | simple_coding | simple_coding, specs_and_docs | parse-edge |
| `a70feab4` | SPL-4985 | tests | tests | specs_and_docs, tests | parse-edge |
| `0ddab07c` | SPL-5555 | secret | secret | secret | parse-edge |
| `fc46d63c` | SPL-5555 | secret | secret | secret | parse-edge |
| `c3fcfe47` | SPL-6182 | complex_coding | complex_coding | complex_coding | race |
| `388e3d15` | SPL-4654 | specs_and_docs | complex_coding | complex_coding, specs_and_docs | race |
| `15e33699` | SPL-4629 | simple_coding | simple_coding | simple_coding | race |
| `198445a6` | SPL-4798 | complex_coding | complex_coding | complex_coding | id-collision |
| `5980f95c` | SPL-4798 | complex_coding | complex_coding | complex_coding | id-collision |
| `5ef4a572` | SPL-5372 | i18n | complex_coding | complex_coding, i18n | id-collision |
| `c3ff1e57` | SPL-4808 | specs_and_docs | specs_and_docs | specs_and_docs | spec-undefined |
| `0a43b9dc` | SPL-4935 | tests | tests | tests | spec-undefined |
| `2e7df79c` | SPL-6152 | complex_coding | complex_coding | complex_coding | closing-trailer |
| `9648cf2c` | SPL-4870 | tests | tests | tests | closing-trailer |
| `5577c422` | SPL-4437 | complex_coding | complex_coding | complex_coding | sibling-left |
| `56b6185f` | SPL-5698 | simple_coding | complex_coding | complex_coding, simple_coding | other |
| `cddd2a68` | SPL-4824 | i18n | complex_coding | complex_coding, i18n | other |
| `b3ab8726` | SPL-5349 | i18n | complex_coding | complex_coding, i18n, specs_and_docs | other |
| `5f6ad82f` | SPL-5480 | simple_coding | i18n | i18n, simple_coding | other |
| `8e0f1262` | SPL-1910 | simple_coding | simple_coding | simple_coding | other |
| `aeef6c0e` | SPL-4808 | specs_and_docs | specs_and_docs | specs_and_docs | other |
| `14a0d7b1` | SPL-6204 | complex_coding | complex_coding | complex_coding | drop:relay |
| `bd5bfefc` | SPL-5440 | complex_coding | complex_coding | complex_coding, i18n | drop:relay |
| `8bf65a6f` | SPL-6152 | complex_coding | complex_coding | complex_coding | drop:relay |
| `924d60c1` | SPL-4761 | complex_coding | complex_coding | complex_coding | drop:relay |
| `9084aebf` | SPL-4860 | specs_and_docs | tests | specs_and_docs, tests | drop:relay |
| `c1fe271d` | SPL-4499 | specs_and_docs | specs_and_docs | specs_and_docs | drop:relay |
| `f0e19986` | SPL-5170 | specs_and_docs | specs_and_docs | specs_and_docs | drop:relay |
| `f490eecd` | SPL-5514 | specs_and_docs | simple_coding | simple_coding, specs_and_docs | drop:relay |
| `f6372707` | SPL-5120 | tests | complex_coding | complex_coding, tests | drop:relay |
| `3bf2242d` | SPL-5000 | tests | complex_coding | complex_coding, i18n, tests | drop:relay |
| `087b5b47` | SPL-4955 | tests | complex_coding | complex_coding, tests | drop:relay |
| `3f5b4807` | SPL-4804 | i18n | i18n | complex_coding, i18n | drop:relay |
| `2ab92549` | SPL-5349 | i18n | complex_coding | complex_coding, i18n, specs_and_docs | drop:relay |
| `65ad5307` | SPL-5372 | i18n | complex_coding | complex_coding, i18n | drop:relay |
| `b8ba1b8e` | SPL-4629 | simple_coding | simple_coding | simple_coding | drop:relay |
| `62ac95f4` | SPL-5698 | simple_coding | complex_coding | complex_coding, simple_coding | drop:relay |
| `ade02ca2` | SPL-1910 | simple_coding | simple_coding | simple_coding | drop:relay |
| `18281287` | SPL-4954 | tests | complex_coding | complex_coding, i18n, tests | drop:no-text |
| `6787a1ac` | SPL-4824 | i18n | complex_coding | complex_coding, i18n | drop:no-text |
| `2fb4c42a` | SPL-4629 | simple_coding | simple_coding | simple_coding | drop:no-text |
| `4372c752` | SPL-4629 | simple_coding | simple_coding | simple_coding | drop:no-text |
| `96f22a42` | SPL-5704 | simple_coding | simple_coding | simple_coding | drop:no-text |
| `cb2f1a37` | SPL-4881 | secret | secret | secret | drop:repeat |
| `ce2c8757` | SPL-4881 | secret | secret | secret | drop:repeat |
| `c9223396` | SPL-5698 | simple_coding | complex_coding | complex_coding, simple_coding | drop:repeat |
| `09a4b73b` | SPL-5698 | simple_coding | complex_coding | complex_coding, simple_coding | drop:repeat |
| `e78d2dd7` | SPL-5740 | simple_coding | simple_coding | simple_coding | drop:repeat |

## Appendix C. v0.1 FAIL items and where v1.0 answers them

Seat 1 is c-343 (msg 436bb29d), seat 2 is c-202 (msg 1ee0f7c0); both FAILed `99cc31e3c`.

| item | change in v1.0 |
|---|---|
| 1-W1, release note | The commit body ends with the release-note trailers. |
| 1-W2, README conflict | Rebased on origin/master; the 193 row sits before 194. Numbering line updated (header). |
| 1-W3, 2-W6, O-ids twice | Owner questions renamed Q1..Q7 (section 6); O1..O3 stay skills. |
| 1-W4, 2-W6, poll rules | Each Q has a recommended option first, a one-line why and "-> changes ..." (section 6). |
| 1-W5, 2-W3, totals | 3.1 gains the 56 other-`Kind:` lanes and a sum row; section 2 explains 3133 distinct commits = 3150 pairs - 17 counted twice. |
| 1-W6, 2-W5, kinds of evidence | 3.3 says how the sample was split and where the two maps differ (13 of 45); Appendix B lists all 71 with both kinds; every skill has an "Evidence kinds" line; L1-L3 are flagged thin; the sample sentence states each pool and draw. |
| 1-W7, skill home | 4.0 names the 7 `SKILL.md` files and `do_spl_skills_refresh`; Q2 (A) uses them. |
| 1-W8, re-runnable | `join.py` and `labels.tsv` committed; Appendix A gives the raw-file commands with the window end; Appendix B the 71 rows. |
| 2-W1, migration claims | 4.0 names `do_rdb_migration_next`; S2 drops migration numbers; SPL-5372 dated before it; section 0 line 4 says so. |
| 2-W2, lane window | Header, section 2 and section 7: lanes cover 2026-10-03T03:06Z onward. |
| 2-W4, X3 and C3 baselines | X3 says its 3 cut across classes; C3 names its 2. |
| 1-N1, 2-N1 | 4.0 paraphrases developer guide 2.12.1 without quotes. |
| 1-N2, 2-N7 | O2 names the metric for "longest". |
| 1-N3 | O1 marks its baseline as a proxy. |
| 1-N4, 2-N4 | 3.2 names run `45223415636` and why a SKIP is red. |
| 1-N5 | X3 and T3 say that their baselines sit inside 3.3 classes. |
| 1-N6 | Section 1 states codex's place. |
| 1-N7 | Section 0 line 2 is marked an inference. |
| 2-N2 | 3.3 states the pools (16, 11) and the drops (27 of 71). |
| 2-N3 | O3 uses 990 lanes with both lines (`join.py`). |
| 2-N5 | Section 7: the 252 runs, the 9 of 61 CI days, the 622 + 56 lanes outside the kinds, "first commit". |
| 2-N6 | Section 2 marks the one-tag-both-envs fact as inferred. |

<!-- last-edit: 2026-11-25T02:00:00Z -->
