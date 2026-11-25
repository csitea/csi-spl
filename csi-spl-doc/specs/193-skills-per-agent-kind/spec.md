# Spec 193: the three most essential skills per agent kind

Status: **v1.3 — decided** (2026-11-25; editor a-506, agy; issue **SPL-6478**). Panel: **same-vendor panel, waiver**: two claude seats, c-343 and c-202 (agy was out of quota until 12-01, grok and mistral were off). Both FAILed v0.1 (`99cc31e3c`) and v1.0 (`32c584732`) and PASSed v1.1 (`585691f6e`, landed as `89ac9e740`); v1.2 (`9af22344e`, SPL-6375) folded their two v1.1 notes. v1.3 folds the owner's Q1-Q7 answers (HUM-10, t1 `b1ec7ce2`, msg `70b8c145`, form `43ebb003`, `2026-11-25T07:36Z`), replaces the shared-skills-first order with 7 parallel build rows (`B1..B7`, disjoint files, one lane per kind), assigns the codex skill-dir render add to B2, turns O1..O3 into `./run` actions (and adds a `window start` arg to `join.py`) in B7, adds refusing gate actions for S1/S2/T1/C3/O3, and sets the re-measure window to 14 days. Appendix C maps each revision and review fold to its changes. Doc only: no skill, code, cnf or workflow changes here. Build rows `B1..B7` (section 5.2) are ready to queue.
Epic: **SPL-2402**. Issues: **SPL-6375** (v0.1..v1.2, label `answer`, done), **SPL-6478** (v1.3, owner Q1-Q7 answers). Class: `feature`. Kind: `specs_and_docs`.
Discussion: t1 topic `b1ec7ce2-9263-465a-aeac-232be97b8864`, task `dispatch-b1ec7ce2`.
Related: [115 vendor split by task kind](../115-vendor-split-by-task-kind/spec.md), [lane issue and docs](../../doc/md/lane-issue-and-docs.md), [developer guide](../../doc/md/developer-guide.md) section 2.

Baseline tree: the git counts ran on `origin/master` `7e31ade12fd86797b337cab9f55a3f654e5a0c4c`. v1.0 re-ran every count with [`join.py`](join.py) on raw files pinned to the window end (Appendix A); v1.1 fixed how `join.py` credits a FAIL to an issue, which moved section 3.2; v1.2 pinned key order in `fails-order.txt` and matched the spawn's `Kind:` pattern. **v1.3 `file:line` citations** were verified on `origin/master` `208e5f757b7f6678df9753bfa8e6a97367f8fa27`.
Window: **2026-09-24T00:00Z .. 2026-11-24T11:25Z** (the last 2 months) for commits, issues and messages. **Lanes cover only 2026-10-03T03:06Z .. 2026-11-24T11:25Z**: the spawn log's first line is 2026-10-03T03:05Z and there is no rotated copy (section 7).
Numbering: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -c /193` -> 0 (2026-11-25). 194 is taken by `194-workspace-google-drive-upload`, so 193 fills a gap.

## Owner's words (HUM-10, t1 `b1ec7ce2`)

Original ask (2026-11-24):

> "Create a panel discussion to create the three most essential skills per agent kind, based on the vendor split settings for each of the agent kinds (based on the last 2 months of discussions and the type of work which has been done). By analyzing the database, the discussions, and the actual results, make how fast the feature has arrived." (msg `75bace2f`)

> "Note: the skills must be short, descriptive, and not overly generic. Create the topmost skills which give the most back for the buck." (msg `16f273e3`)

Owner answers to section 6 poll (msg `70b8c145`, form `43ebb003`, `2026-11-25T07:36Z`):

- **Answer 1: C** — All 7 kinds at once
- **Answer 2: A** — In the repo, rendered for each vendor by the existing skills refresh action
- **Answer 3: A** — The skill plus a gate action that refuses
- **Answer 4: A** — Build them as `./run` actions (code), not skills
- **Answer 5: A** — Keep it and re-measure it with the others (Q6)
- **Answer 6: B** — 14 days after landing
- **Answer 7: A** — One lane per kind, its vendor taken from the kind table

## 0. Answer in five lines

1. The time from the owner's ask to the result is spent **before the lane starts**, not in it: owner's last message -> lane placed has a median of 4.5 h (complex_coding) to 26.8 h (i18n), p90 34 h to 222 h. Lane placed -> landed has a median of 0.5 h to 1.8 h. Landed -> next release tag has a median of 0.3 h or less (section 3.4).
2. Inside the lane, the review rounds are the likely main cost (an inference: placed -> landed is not split into review time). 26 of the 83 complex_coding issues that got an R7 FAIL failed again on a second head (section 3.2).
3. The most common blocking findings in a hand-labelled sample of 45 are: **a failure path that fails open or is swallowed** (7), **a doc or claim that does not match the tree** (6), **a secret or authorisation leak** (6), and **a test that cannot go red** (5) (section 3.3).
4. Section 4 defines 21 slots (3 per kind), which come to **18 distinct deliverables**: **15 skills** under `assets/skills/` (3 shared across two kinds, filling 18 skill slots) plus **3 orchestration `./run` actions** (O1..O3, code not skills per Q4 A), plus **4 refusing gate actions** for checkable skills (S1, S2, T1, C3 per Q3 A; O3 is itself a refusing action). None of the 15 skill names or 7 action files is taken on `origin/master` `208e5f757`; S2 leaves migration numbers to `do_rdb_migration_next` (section 4.0).
5. Owner decided Q1-Q7 (msg `70b8c145`, form `43ebb003`, section 6): all 7 kinds build in parallel (`B1..B7`, one lane per kind with disjoint files, vendor from section 1, section 5.2), skills live in the repo and render via `do_spl_skills_refresh` (including a codex skill dir owned by B2), L2 stays, and gains re-measure 14 days after the last build row lands (with the sample-size cost of 14 vs 52-61 days noted in sections 6 and 7).

## 1. The kinds, as the vendor split defines them today

Source: `csi-spl-cnf/csi-spl/all.env.yaml:1567-1574` (`origin/master` `208e5f757`, key `env.box.agent_split_by_kind`; no env file overrides it, `grep -l agent_split_by_kind csi-spl-cnf/csi-spl/*.env.yaml` -> only `all.env.yaml`). The main vendor is the one with the biggest share.

| kind | split (cnf) | main | backup |
|---|---|---|---|
| specs_and_docs | agy 80, mistral 15, claude 5 | agy | claude |
| tests | claude 70, agy 15, codex 15 | claude | agy |
| simple_coding | claude 44, agy 41, codex 15 | claude | agy |
| complex_coding | claude 90, agy 10 | claude | agy |
| i18n | agy 100 | agy | claude |
| secret | claude 100 | claude | grok |
| orchestration | claude 100 | claude | grok |

The skills must work for the main vendor and the backup. For simple_coding that means agy as well as claude (41 against 44). codex holds 15 in tests and in simple_coding (`all.env.yaml:1569-1570`), took 3 lanes in the window (3.1), and keeps its home dir at `~/.codex` (`trust-workdir.sh:23,239`, `install.sh:533`), while `do_spl_skills_refresh` (`csi-spl-orc/src/bash/run/spl-skills-refresh.func.sh:98-118`, `csi-spl-orc/src/bash/features/spool-install/install.sh:1050-1060`, `origin/master` `208e5f757`) today renders only 5 vendors (`claude`, `qwen`, `agy`, `mistral`, `grok`). Because **Q2 A** ("rendered for each vendor") included adding the codex skill dir, **B2** (`tests`, claude, where codex holds 15) solely owns adding `~/.codex/skills` rendering to `install.sh`, `spl-skills-refresh.func.sh` and `spl-skills-refresh.tst.sh` (section 5.2). All 6 vendors (`claude`, `qwen`, `agy`, `mistral`, `grok`, `codex`) are therefore in scope for `B1..B7` with zero file overlap.

## 2. How it was measured

All counts are for **this box's** spawns. The spawn log on the other machine was not read, so "n" here is a lower bound on the fleet's.

- **Lanes**: `SPAWNED` rows of `/var/spool-hub/spawn-remote/serve.log` before the window end (the first is 2026-10-03T03:06Z): n = **3293** (agent id, vendor, slug, brief id). The kind is the brief's `Kind:` line: the 7 kinds of section 1 hold 2615 lanes, 618 have no `Kind:` line, and 60 carry another value (`review` 37, `stability` 8, `clean` 3, `fleet` 3, `reviews` 3, `spec` 3, `wui` 3). The issue is the brief's `Issue:` line (1000 lanes). For another 1727 lanes it is the hub issue whose title equals the brief's first line, because the spawn files the issue from the brief's title (65 of those titles were ambiguous: the lowest number was taken). That gives **2727 of 3293** lanes with an issue. **The kind of an issue** is the kind of the first lane (in log order) that carries it; an issue that lanes of two kinds worked counts under the first one only.
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
| (no `Kind:` line; 616 in October, 2 in November) | 618 | 116 | 158 | - |
| (`Kind:` review 37, or another value 23) | 60 | 13 | 24 | - |
| **sum** | **3293** | | **3150 pairs = 3133 commits + 17 counted twice** | |

Spawns, issues and commits come from `join.py`. The last column was counted in v0.1's scratch join and is not in `join.py`. "Author issues" excludes the review, panel and seat lanes (slug matches `review|reviewer|r7|seat|panel|verif|audit`), because a seat's issue is closed `diss` by design. Two numbers need care:
- 6 of the 8 i18n "diss" lanes are agy or claude **language reviews** whose slug does not say "review"; the other 2 are LinkedIn post drafts. This is not failed work.
- 14 of the 17 secret "diss" lanes, judged by their titles, could not land a csi-spl commit by their nature: ops, analysis, or documents in other repos.

The spawn mix on this box is not the cnf split: specs_and_docs went to claude 390 times and to agy 205 times. The likely reason is the data rule (a brief that reads hub data is secret-class), but that was not checked per lane.

### 3.2 What went wrong

| kind | issues with any FAIL message | issues with >= 1 FAILed head | of them FAILed again on a 2nd head | max FAILed heads | CI red heads (last 748 runs) |
|---|---|---|---|---|---|
| complex_coding | 114 | 83 of 599 | 26 | 5 | 11 of 76 |
| specs_and_docs | 51 | 32 of 642 | 17 | 11 | 17 of 206 |
| simple_coding | 43 | 24 of 394 | 7 | 5 | 23 of 174 |
| tests | 18 | 15 of 142 | 4 | 2 | 1 of 14 |
| secret | 17 | 14 of 159 | 4 | 4 | 4 of 21 |
| i18n | 6 | 1 of 64 | 0 | 1 | 0 of 6 |

- A "FAILed head" is a distinct `FAIL <sha>` per issue, from a verdict that names the head (`FAIL` then a sha in the first 400 characters), so two reviewers failing the same head count once. "Any FAIL message" also counts relays and send-backs that name no head. That is why i18n has 6 issues with a FAIL message but 1 with a FAILed head. specs_and_docs was 37 in v0.1 (no end bound on the message query). An issue is the message's first SPL key that a lane carries; v1.0 took the message's first SPL key, which could be a plan or fleet issue named next to the lane's (c-343 v1.0 W3), and read specs_and_docs 57 / 36 / 14, complex_coding 118 / 82 / 27, simple_coding 44 / 25 / 7 / max 4, secret 19 / 15 / 4 / max 3.
- The CI column was counted in v0.1's scratch join from the `gh run list` output of Appendix A and is not in `join.py`.
- A CI red is a red `10_ci-quality` run whose head commit cites an issue of that kind. The head is the pusher, not always the cause.
- CI is not the main cost: 7 of the last 100 runs failed (2026-11-23T13Z .. 2026-11-24T11Z). By the job that broke each run first: orc hermetic 4/4 broke 2, iac tfvars parity broke 2, hub go test broke 2 and orc hermetic 2/4 broke 1. One of the 7 (run `45223415636`, job orc hermetic 4/4) went red because an orc test printed a SKIP line: the gate fails a skipped check, because a skip proves nothing (`do_report_ci_gate` signature "an orc check skipped in CI").
- **Rework** (a second author lane on the same issue; v0.1 scratch, not in `join.py`): 3 specs_and_docs, 3 simple_coding, 2 complex_coding and 5 secret issues. This is rare. The cost is in the review rounds, not in respawns.

### 3.3 Why reviews fail: a hand-labelled sample

Keyword counts did not work. On a sample of 24, "red control" mostly matched a reviewer *reporting* that it ran the controls, which made only about 1 hit in 3 correct. So the blocking finding (`W1` / `B1`) of FAIL messages was read and labelled by hand.

The pool is the first `W1` / `B1` line of each FAIL message whose issues all map to one kind (`join.py`, `sample`). From it, a random draw (seed 11) took 14 complex_coding, 14 specs_and_docs, 10 tests and 6 secret messages. For simple_coding (pool 16) and i18n (pool 11) every message in the pool was taken. That makes 71 messages. 27 were dropped: 17 relays ("W1 fixed", "W1-W3 folded", a fold list), 5 verdict lines with no finding text ("W1 W2 W3 | log"), and 5 repeats of a finding already labelled on the same issue. The other 44 messages give **n = 45** findings (`fc46d63c` holds two). One labeller (this editor) did the labelling; Appendix B lists all 71 with their labels (72 rows: `fc46d63c` holds two findings), and the panel may re-label.

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

## 4. The skills and actions: three per kind

### 4.0 Not already a skill or an enforced rule

Checked on this box on 2026-11-24, and on `origin/master` `208e5f757b7f6678df9753bfa8e6a97367f8fa27` on 2026-11-25:
- `ls ~/.claude/skills` -> agent-msg, exit-clean, graft, kill-your-self, paste-html-into-chrome, scrum-file-update, spec-kit-tasks, synced, tmux-color.
- `ls .claude/skills` in the repo -> none. The repo's skill home (decided by **Q2 A**, msg `70b8c145`) is `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/<name>/SKILL.md`: `git ls-tree -r --name-only origin/master | grep -E '/SKILL\.md$'` -> 7 files: `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{agent-msg,exit-clean,kill-your-self,paste-html-into-chrome,spec-kit-tasks,tmux-color}/SKILL.md` and `csi-spl-orc/src/bash/features/graft/assets/skills/graft/SKILL.md`.
- **Renderer and auto-discovery**: `csi-spl-orc/src/bash/features/spool-install/install.sh:1038-1060` (`origin/master` `208e5f757`) walks `os.listdir(os.path.join(assets, "skills"))` dynamically, substitutes `{{HARNESS_DIR}}`, `{{SPOOL_ROOT}}`, `{{AGENT_CEILING}}`, and `{{ORCHESTRATOR_ID}}`, appends the `<!-- spool-install: sha256=... -->` marker, and writes `~/.claude/skills/<name>/SKILL.md` plus (where the vendor dir exists) `~/.qwen/skills`, `~/.gemini/config/skills`, `~/.vibe/skills`, and `~/.grok/skills`. `do_spl_skills_refresh` (`csi-spl-orc/src/bash/run/spl-skills-refresh.func.sh:31-76,88-91,96-118`) extracts that same `EOF_PY` renderer from `install.sh` and runs it for every box user. `csi-spl-orc/src/bash/features/spool-install/tests/test-y5-adopt.sh:70,116` computes its expected count dynamically from `ls "$HARNESS/assets/skills"`. Adding a new `<name>/SKILL.md` therefore edits zero shared manifests; B2 alone adds the `~/.codex/skills` branch to `install.sh` and `spl-skills-refresh.func.sh` (Q2 A).
- **`./run` action and test auto-discovery** (used by **Q3 A** gate actions and **Q4 A** orchestration actions): `csi-spl-orc/src/bash/run/run.sh:347-357,389-390` discovers `src/bash/run/<kebab-name>.func.sh` -> `do_<snake_name>` (described in the lazy-loader rationale comment at `run.sh:879-896`), and `csi-spl-orc/src/bash/tests/run-all-tests.sh:116` discovers every `csi-spl-orc/src/bash/tests/*.tst.sh`. Parallel lanes adding distinct actions and tests touch zero shared registry files. None of the 15 skill names or 7 action files (`spl-{claim-reruns-check,numbered-id-check,red-control-check,docs-none-check,plan-rows-parallel-place,owner-ask-sweep-enqueue,brief-header-check}.func.sh`) exists on `origin/master` `208e5f757`.
- `csi-spl-orc/src/bash/features/spool-install/assets/` -> claude (settings, claude-md), agy/rules (`30-exit-after-accepted.md`, `40-git-no-pager.md`), kill-guard, rm-guard, vibe-output-cap, vibe-push-guard.

These existing gates (verified on `origin/master` `208e5f757`) leave a gap that each pick below fills:
- Migration numbers are already covered: `do_rdb_migration_next` claims the next number on the remote (`refs/rdb-claims/NNNN`) before the file is written (`csi-spl-orc/src/bash/run/rdb-migration-next.func.sh:1-20`, SPL-5515, landed 2026-11-14; developer guide 2.8.3), and `lint-migration` refuses a taken number at push time. Nothing claims spec folders, spec sections, case ids or plan row ids. S2 is cut to those.
- `do_spl_review_line_check` (`csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:1-25`) proves that the reviewer ran the named tests (developer guide 2.12.1, which names review as the only enforcement). Nothing proves on the author's side that a new test went red on the planted defect.
- `kill-your-self-report.sh --gate` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh:55` via `csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh:249-262,610,652`) checks that a `Docs: none (<why>)` line is **present**, not that it is true.
- `TestRLSCoversEveryTenantTable` works at the table level, not per route.
- `lint-gitleaks` and `lint-trufflehog` find secrets in files, not on argv or in a child's environment.
- `do_spl_spec_rows_unqueued` (`csi-spl-orc/src/bash/run/spl-spec-rows-unqueued.func.sh:28-63`, read-only daily digest) finds rows that are unqueued, not rows queued one at a time.
- `do_spl_unanswered_sweep` (`csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh:120-154`) finds owner posts with no answer, not answered asks that were never enqueued.
- `spl_spawn_q_enqueue` in `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh` (function starts at `:217`; placed-brief block `if [[ -n "$place" ]]` at `:246-257` on `origin/master` `208e5f757`) checks `Epic:` + `Spec:` via `li_brief_epic_spec` (`lane-issue.inc.sh:183`) and discussion links via `spl_spawn_q_enqueue_links` (`spl-spawn-enqueue.func.sh:337-343`), but does not refuse a brief missing a valid `Kind:` from the 7 cnf kinds or an explicit `Issue:` / spawn-files-it declaration. Enqueues without `SPAWN_PLACE` have no brief file and skip that block.

Each item below gives: name, trigger, what it does (5 lines or fewer; including its refusing gate action where **Q3 A** applies, or its `./run` action where **Q4 A** applies), the evidence, **the kinds its evidence came from** (the issue's first-lane kind, Appendix B), and the expected gain (re-measured **14 days after the last build row of `B1..B7` lands on `origin/master`** per **Q6 B**, using `join.py` and Appendix A; see sections 6 and 7 for the 14-day sample-size cost).

### 4.1 specs_and_docs (main agy, backup claude) — build row B1

**S1 `claim-reruns-before-push`** (skill + refusing gate action, Q3 A; owned by B1)
- Trigger: a doc or spec diff that contains a number, count, path or "command -> result" claim.
- Does: (1) finds every claim line in the diff that carries a command (backticked command, then `->`, then a result). (2) Re-runs each one read-only on the tree it names. (3) Prints MATCH or DIFF per line. (4) Refuses the push on a DIFF. (5) Flags a bare number with no command as "unchecked". **Gate action (Q3 A)**: `cd csi-spl-orc && ./run -a do_spl_claim_reruns_check` (`csi-spl-orc/src/bash/run/spl-claim-reruns-check.func.sh`, test `spl-claim-reruns-check.tst.sh`) implements steps 1-5 and exits non-zero on any DIFF; the skill calls it before every push.
- Evidence: "doc or claim does not match the tree" is 6 of 45 sampled findings (3.3), including wrong coverage numbers (`ece509e7`) and a false sentence about what deploys (`a5e1921c`).
- Evidence kinds: specs_and_docs 4 of the 6 (`53b09832` is complex_coding, `c5183570` simple_coding).
- Gain (re-measure at +14 d, Q6 B): specs_and_docs repeat-FAIL rate (issues that FAIL again on a 2nd head), 17 of 32 (53.1 %) -> **under 25.0 %** (exact rate of v1.2 `< 8 of 32`; at 14 d expected `n ≈ 8.6` on the 52 d lane window [`7.3` on 61 d], i.e. 2 or fewer of ~9).

**S2 `numbered-id-claim`** (shared with complex_coding; skill + refusing gate action, Q3 A; **owned by B4**)
- Trigger: a new spec folder, spec section number, case id (`C71`) or plan row id. Migration numbers are out: `do_rdb_migration_next` claims them (4.0).
- Does: (1) lists the ids already taken on `origin/master`, every `review/*` and `wip/*` branch and every live worktree. (2) Prints the next free id. (3) Before each review head, runs `git merge-tree --write-tree origin/master HEAD` and flags an id this diff adds that another ref also adds. **Gate action (Q3 A)**: `cd csi-spl-orc && ./run -a do_spl_numbered_id_check` (`csi-spl-orc/src/bash/run/spl-numbered-id-check.func.sh`, test `spl-numbered-id-check.tst.sh`) runs steps 1-3 and exits non-zero on any collision; the skill calls it before every review push.
- Evidence: numbered-id collisions are 3 of 45 (3.3). Two remain in scope after the cut: spec section 3.17 / cases C71-C72 (`5980f95c`) and the spec section half of `198445a6`. The third, migration 0276 on 3 branches (`5ef4a572`, SPL-5372, 2026-11-12/13), predates `do_rdb_migration_next` (2026-11-14). In this spec's own v0.1, the specs README row collided with spec 194 (c-343 W2).
- Evidence kinds: complex_coding 2 of 2. From specs_and_docs lanes: none in the sample; only this lane (n = 1). The specs_and_docs slot is therefore thin; the complex_coding slot (X1) carries the evidence, so B4 owns both the skill and gate action.
- Gain (re-measure at +14 d, Q6 B): spec-section and case-id collision FAILs, 2 in the sample -> 0.

**S3 `fold-ledger-delta`** (skill; owned by B1)
- Trigger: the editor or author receives a FAIL or SEND-BACK with W/N lines.
- Does: (1) writes one table, `W/N id | file:line changed | commit | check command -> result`. (2) Requires a check per W (e.g. `grep -c '25 posts' spec.md -> 0`). (3) Pushes ONE new head and sends the table, so the reviewer reviews a delta.
- Evidence: of the specs_and_docs issues with a FAILed head, 17 of 32 failed again on a later head, and one went to 11 FAILed heads (3.2). In the sample, the same issues come back with W-lines on the same code (SPL-5698, SPL-4629, SPL-4881).
- Evidence kinds: the 17 of 32 are specs_and_docs; the three sample issues are complex_coding, simple_coding and secret.
- Gain (re-measure at +14 d, Q6 B): maximum FAILed heads per specs_and_docs issue 11 -> **3 or fewer**; repeat-FAIL share 17 of 32 (53.1 %) -> **under 20.0 %** (at 14 d expected `n ≈ 8.6` [`7.3` on 61 d]).

### 4.2 tests (main claude, backup agy) — build row B2

**T1 `red-control-in-commit`** (skill + refusing gate action, Q3 A; owned by B2)
- Trigger: a commit that adds or changes a test.
- Does: (1) reverts the fix, or plants the bug, in a throwaway copy. (2) Runs only the new cases and records `rc` and the failing count. (3) Re-applies the fix and records the green run. (4) Writes both lines into the commit body. (5) Refuses when the new case did not run (it was skipped or 0 cases matched). **Gate action (Q3 A)**: `cd csi-spl-orc && ./run -a do_spl_red_control_check` (`csi-spl-orc/src/bash/run/spl-red-control-check.func.sh`, test `spl-red-control-check.tst.sh`) verifies that outgoing commits adding/changing tests carry the red-control (`rc != 0` / failing count) and green-run evidence with zero skips and exits non-zero when absent or vacuous; the skill calls it before push.
- Evidence: "a test that cannot go red" is 5 of 45 (3.3): a test that checks the mock instead of the contract (`a4433661`), controls that stay green (`b53cd5c6`), e2e that runs on after an error (`b8d356f9`). One of 7 recent CI reds was an orc test that printed SKIP (3.2).
- Evidence kinds: tests 2 of 3 (`b53cd5c6`, `b8d356f9`); `a4433661` is complex_coding.
- Gain (re-measure at +14 d, Q6 B): vacuous-test findings, 5 in 45 (11.1 %) -> **<= 2.2 %** (exact rate of v1.2 `<= 1 in 45`); tests issues with an R7 FAILed head, 15 of 142 (10.6 %) -> **under 5.6 %** (exact rate of v1.2 `< 8 of 142`; at 14 d expected ~38 tests issues, `n ≈ 4.0` FAILed at baseline [`3.4` on 61 d]).

**T2 `failure-path-cases`** (shared with simple_coding; skill; **owned by B3**)
- Trigger: a diff that calls something that can be missing or fail: a binary, file, OS user, hub read, network or child process.
- Does: (1) lists each such call site. (2) For each one, writes the case where it is missing or fails. (3) Asserts the documented outcome: fail fast (`rc != 0`, FATAL on stderr) or a **named** fail-open. (4) Refuses `|| true`, `.catch(() => null)` or `2>/dev/null` without a comment that names the decision.
- Evidence: the largest class, 7 of 45 (3.3): a FATAL text captured as a unit name (SPL-5698), a match that fails open (`21a21369`, SPL-1910), a source status discarded (`5b1e8b4b`), a failed hub read that goes on (`ebadef55`), an uncaught missing tool (`fc46d63c`).
- Evidence kinds: complex_coding 4 (`a7ebbac7`, `ebadef55`, `0c77b97f`, `a93e795a`), simple_coding 1 (`21a21369`), specs_and_docs 1, secret 1. **From tests lanes: 0 of 7.** It sits under tests because each failure path becomes a test case; the simple_coding slot (C1) has its own items (`21a21369`; `a93e795a`, SPL-5698, also had a simple_coding lane), so B3 owns the file.
- Gain (re-measure at +14 d, Q6 B): failure-path findings, 7 in 45 (15.6 %) -> **<= 4.4 %** (exact rate of v1.2 `<= 2 in 45`).

**T3 `e2e-no-swallowed-waits`** (shared with i18n; skill; **owned by B2**)
- Trigger: a WUI e2e test is added or changed.
- Does: (1) refuses `.catch(() => null)` on `waitFor*`. (2) Stops the case at the first navigation error. (3) Runs against the generated bundle (`nuxt generate` + mock serve), never `nuxi dev`. (4) Repeats a new case 3 times (n = 3) before it is called green.
- Evidence: SPL-5372 (FAIL W1 twice: a swallowed 8 s wait, then a pick that fails on `nuxi dev`), SPL-5441 (`b8d356f9`: the test runs on after `nav()` fails). The WUI e2e shards are 8 of the gate's jobs (`do_report_ci_gate`).
- Evidence kinds: tests 1 (`b8d356f9`); SPL-5372 2 (`4ed63dca`, `72b35ee8`), whose first lane is complex_coding and which an i18n lane also carried. B2 (`tests`, claude) owns the file.
- Gain (re-measure at +14 d, Q6 B): e2e findings of this shape, 3 in 45 -> 0. These 3 are inside the 5 of "a test that cannot go red" (3.3), not a class of their own.

### 4.3 simple_coding (main claude, backup agy) — build row B3

**C1 `failure-path-cases`**: see T2. It is counted once and **owned by B3**. simple_coding evidence: `21a21369` (a match that fails open, SPL-1910 lane) and `a93e795a` (SPL-5698, which a simple_coding lane carried).

**C2 `sweep-bug-class`** (skill; owned by B3)
- Trigger: a reviewer W names a bug, or the lane fixes one.
- Does: (1) turns the bug into a search pattern (the bad call, the unanchored regex, the unset env knob). (2) Greps the whole repo for siblings. (3) Fixes them in the same head, or lists them with a reason. (4) Adds one test per sibling fixed.
- Evidence: `5577c422` ("six more caller knobs still reach the hook, same bug class as your knob fix"); SPL-5698 and SPL-4629, which each came back with several FAIL messages on the same function. 7 of the 24 simple_coding issues with a FAILed head failed again on a 2nd head (3.2).
- Evidence kinds: complex_coding (`5577c422`, SPL-5698) and simple_coding (SPL-4629).
- Gain (re-measure at +14 d, Q6 B): simple_coding repeat-FAIL rate, 7 of 24 (29.2 %) -> **<= 12.5 %** (exact rate of v1.2 `<= 3 of 24`; at 14 d expected `n ≈ 6.5` FAILed issues [`5.5` on 61 d]).

**C3 `docs-none-proof`** (skill + refusing gate action, Q3 A; owned by B3)
- Trigger: a commit message with `Docs: none (...)`, or a behaviour change with no `csi-spl-doc/` path.
- Does: (1) takes the changed identifiers (action names, env vars, function names, event kinds, file names) from the diff. (2) Greps `csi-spl-doc/` and the root `*.md` for each one. (3) Prints every hit with `file:line`. (4) A hit means a doc to update, or a written reason why it still holds. **Gate action (Q3 A)**: `cd csi-spl-orc && ./run -a do_spl_docs_none_check` (`csi-spl-orc/src/bash/run/spl-docs-none-check.func.sh`, test `spl-docs-none-check.tst.sh`) extracts changed identifiers from a behaviour-changing diff carrying `Docs: none (...)`, greps `csi-spl-doc/` and root `*.md`, prints hits, and exits non-zero when an unaddressed doc hit exists; the skill calls it before push.
- Evidence: SPL-5740, where the W1 was "the Docs: none reason is wrong, two docs go false with this commit". `6ed5c1a1` (fleet-rules-index row stale after the code moved). "Doc does not match tree" is 6 of 45.
- Evidence kinds: simple_coding 1 (`c5183570`), complex_coding 1 (`53b09832`), specs_and_docs 1 (`6ed5c1a1`).
- Gain (re-measure at +14 d, Q6 B): doc-drift findings on coding lanes, 2 in 45 (`c5183570`, `53b09832`) -> 0.

### 4.4 complex_coding (main claude, backup agy) — build row B4

**X1 `numbered-id-claim`**: see S2. It is counted once and **owned by B4** (both skill and refusing gate action `do_spl_numbered_id_check`). complex_coding evidence: `5980f95c` and `198445a6` (both SPL-4798, a complex_coding lane).

**X2 `shared-state-two-writer-test`** (skill; owned by B4)
- Trigger: a diff that reads, then writes, shared state: a Postgres row or counter, a file under the spool root, a ledger or a cron-trimmed log.
- Does: (1) names each read-modify-write. (2) Puts it in one transaction (`SELECT ... FOR UPDATE`) or under one `flock`. (3) Adds a test with two writers started together (`&` + `wait`, or two goroutines) that fails without the lock.
- Evidence: "race or two writers" is 3 of 45: a login lockout counted before it is recorded, with no transaction (`c3fcfe47`), a trim that loses another mount's record (SPL-4629), a mirror key that does not move `updated_at` (`388e3d15`).
- Evidence kinds: complex_coding 2 (`c3fcfe47`, `388e3d15`), simple_coding 1 (`15e33699`).
- Gain (re-measure at +14 d, Q6 B): race findings, 3 in 45 -> 0.

**X3 `route-authz-matrix`** (skill; owned by B4)
- Trigger: a new or changed hub route or read that returns workspace data, or a WUI view over one.
- Does: runs a table-driven test over caller = {owner, member, guest/demo role, another workspace's owner, a box locked to someone else} x action = {read, list, counts, write}. It expects 403 or an empty, counted result where the spec says so. It checks the credential **type** (view token vs upload token), not only that a mock answered.
- Evidence: `15040649` (any workspace's channel owner could make the operator fleet spawn), SPL-4895 (counts and unread of a locked box leak), `a4433661` (the WUI sends the view token where the hub accepts only an upload token).
- Evidence kinds: complex_coding 3 of 3.
- Gain (re-measure at +14 d, Q6 B): authorisation-shaped findings, 3 in 45 (6.7 %) -> **0 %**; complex_coding issues with a FAILed head, 83 of 599 (13.9 %) -> **under 10.0 %** (exact rate of v1.2 `< 60 of 599`; at 14 d expected ~161 issues, `n ≈ 22.3` FAILed at baseline [`19.0` on 61 d]). The 3 cut across the 3.3 classes: 2 (`15040649`, `dd8af748`) are in the leak class, and `a4433661` is labelled "a test that cannot go red".

### 4.5 i18n (main agy, backup claude) — build row B5

**L1 `locale-fit-at-360`** (skill; owned by B5)
- Trigger: a new or changed WUI string in any locale.
- Does: (1) for each changed key, picks the longest of the 19 locale values. (2) Renders the view in Chrome at 360 px and 412 px with that value. (3) Fails on overlap with a neighbouring control, clipping without an ellipsis, or a horizontal scroll.
- Evidence: SPL-5349 W1 (`b3ab8726`, the `✓ N` badge drawn over the card-size control at 360 px).
- Evidence kinds: SPL-5349's first lane is complex_coding; an i18n lane and a specs_and_docs lane also carried it. n = 1: **thin**.
- Gain (re-measure at +14 d, Q6 B): layout FAILs on i18n rows, 1 in 45 -> 0, and no locale-only follow-up lane (at 14 d expected `n = 0..1`; flag underpowered).

**L2 `native-word-order-pass`** (skill; kept per Q5 A; owned by B5)
- Trigger: user-facing copy in several languages (WUI, blog, help), before the GCT check.
- Does: a per-language checklist, run before the machine check: (1) word order of time and frequency phrases ("24/7"). (2) Anglicisms with a native form. (3) Quote marks, number and date formats. (4) Formal vs informal address kept the same per locale. It prints each change as `locale key: old -> new`.
- Evidence: SPL-5480 W1/W2 (German "In Produktion 24/7." in English word order; French bare "24/7"). These are not translation-meaning errors, so a back-translation check does not catch them.
- Evidence kinds: SPL-5480's first lane is i18n (a later simple_coding lane carried its `Issue:` line). n = 1: **thin**.
- Gain (re-measure at +14 d, Q6 B): language W-lines per multilingual lane, measured as 2 in SPL-5480 -> 0. **Kept per Q5 A** (msg `70b8c145`) and re-measured with the others at 14 days (expected `n = 0..1`; flag underpowered rather than dropping on zero sample).

**L3 `e2e-no-swallowed-waits`**: see T3. It is counted once and **owned by B2**. i18n evidence: SPL-5372 (`4ed63dca`, `72b35ee8`), which an i18n lane carried; its first lane is complex_coding. One issue: **thin**.

All three i18n skills rest on one issue each. i18n has 6 issues with a FAIL message and 1 with a FAILed head (3.2), so a thicker baseline does not exist yet.

### 4.6 secret (main claude, backup grok) — build row B6

**K1 `secret-off-argv-and-env`** (skill; owned by B6)
- Trigger: a diff that passes a token, key or password to a child process, a TUI or a log.
- Does: (1) refuses a secret on argv (it is readable in `/proc/<pid>/cmdline`). Pass it by file descriptor, stdin or a 0600 file. (2) Unsets **every alias** of the variable before exec, not only the canonical name. (3) Masks the whole value after wrapping, not per line. (4) A test reads the child's `/proc/<pid>/cmdline` and `environ`.
- Evidence: `ab83fbd3` (a bearer token on curl argv), SPL-5495 (an alias of the token variable left exported in 18 actions), SPL-4810 (a masked value's tail leaks on a hard wrap).
- Evidence kinds: secret 1 (`e5bd3a3f`), specs_and_docs 1 (`ab83fbd3`), complex_coding 1 (`daa93e52`).
- Gain (re-measure at +14 d, Q6 B): secret-leak findings, 3 in 45 -> 0.

**K2 `secret-teardown-on-disable`** (skill; owned by B6)
- Trigger: a feature that stores a credential, token file, cron line or saved option, and has an off switch.
- Does: (1) lists everything the "on" path writes. (2) A test turns the feature on, then off, and asserts that each item is gone and that nothing restarts.
- Evidence: SPL-4881, with 3 FAIL or SEND-BACK messages for the same W1 (turning the watchdog off left the token on disk and the loop restarting).
- Evidence kinds: secret (SPL-4881).
- Gain (re-measure at +14 d, Q6 B): repeat-FAIL rate on secret lanes, 4 of 14 (28.6 %) -> **<= 7.1 %** (exact rate of v1.2 `<= 1 of 14`; at 14 d expected `n ≈ 3.8` FAILed issues [`3.2` on 61 d], flag underpowered).

**K3 `parse-boundary-cases`** (skill; owned by B6)
- Trigger: a diff that adds or changes a regex or a hand parser (bash `[[ =~ ]]`, Python `re`, Go `regexp`, jq).
- Does: (1) the regex is anchored at both ends, or carries a comment that says why not. (2) Adds table cases: prefix and suffix neighbours, digits next to words ("fourteen years" vs "4"), an empty value, quotes inside quotes, a trailing newline (`\z` vs `$`).
- Evidence: regex or parse edge cases are 4 of 45: `0ddab07c` (an unanchored, shortest-first `YEARS_RX` matched "fourteen" as 4), `fc46d63c` W2 ("five years" marked backed), `a70feab4` (a count read as a verdict), `66fea976` (a path resolved through a symlink).
- Evidence kinds: secret 2 (`0ddab07c`, `fc46d63c`, both SPL-5555, a secret-kind lane), tests 1, simple_coding 1.
- Gain (re-measure at +14 d, Q6 B): parse findings, 4 in 45 (8.9 %) -> **<= 2.2 %** (exact rate of v1.2 `<= 1 in 45`).

### 4.7 orchestration (main claude, backup grok) — build row B7 (`./run` actions, not skills — Q4 A)

No lane in the window carried `Kind: orchestration`: the role seats (dispatch and orch lease holders) do this work. The evidence is the lead time in 3.4. Per **Q4 A** (msg `70b8c145`, enforcing owner rule "orchestration = code, not intelligence"), O1, O2 and O3 are built as **`./run` actions in `csi-spl-orc/src/bash/run/`**, not `SKILL.md` files; each ships with its test in `csi-spl-orc/src/bash/tests/` (developer guide 2.4.5, 2.12.1) and defaults to `DRY_RUN=1`.

**O1 `do_spl_plan_rows_parallel_place`** (`csi-spl-orc/src/bash/run/spl-plan-rows-parallel-place.func.sh`, test `spl-plan-rows-parallel-place.tst.sh`; owned by B7)
- Trigger: a build plan gets its GO, or a plan row lands.
- Does: (1) reads the plan's rows and their owned paths. (2) Runs `lane-map.sh --check` on each row against live lanes and checks pairwise disjointness across rows. (3) Enqueues every row whose paths are disjoint and whose `SPAWN_AFTER` prerequisite (`csi-spl-orc/src/bash/run/spl-spawn-after.func.sh:49-70`, `origin/master` `208e5f757`) is met, all in one sweep (`DRY_RUN=0` enqueues; default `DRY_RUN=1` prints the plan). (4) Prints each held row with the row or lane it waits on. Companion to read-only `do_spl_spec_rows_unqueued` (`csi-spl-orc/src/bash/run/spl-spec-rows-unqueued.func.sh:28-63`).
- Evidence: SPL-6201, SPL-6203 and SPL-6207 (spec 123 rows L4, L6, L5) took 249 h to 252 h from the owner's last message to landing, while placed -> landed was about 1 h each (3.4).
- Gain (re-measure at +14 d, Q6 B): owner ask -> placed p90 -> under 24 h for plan rows. Plan rows were not measured apart: the baseline is a **proxy**, the all-row p90 of complex_coding (34.3 h) and simple_coding (128.8 h).

**O2 `do_spl_owner_ask_sweep_enqueue`** (`csi-spl-orc/src/bash/run/spl-owner-ask-sweep-enqueue.func.sh`, test `spl-owner-ask-sweep-enqueue.tst.sh`; owned by B7)
- Trigger: a dispatcher sweep finds an owner message that it has answered, but with no ask in the queue and no issue (or an open issue not `needs-owner`). Companion to `do_spl_unanswered_sweep` (`csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh:120-154`, `origin/master` `208e5f757`).
- Does: (1) when the ask is a clear order (no open question, and no panel needed by the work-process rules), drafts/emits the brief enqueue call in the **same** sweep (`DRY_RUN=0` enqueues; default `DRY_RUN=1` prints the action). (2) Otherwise it emits the one blocking question as a poll form and marks the issue `needs-owner`. (3) It never leaves an answered owner ask with neither.
- Evidence: owner ask -> issue, median 2.6 h to 22.4 h, p90 33 h to 217 h, against a queue of 0.1 h to 0.5 h (3.4). On owner ask -> issue, tests waits the longest (median 22.4 h, n = 41); on owner ask -> placed, i18n does (26.8 h, n = 8).
- Gain (re-measure at +14 d, Q6 B): median owner ask -> placed for tests 23.5 h -> under 4 h; for all kinds, under 4 h.

**O3 `do_spl_brief_header_check`** (`csi-spl-orc/src/bash/run/spl-brief-header-check.func.sh`, test `spl-brief-header-check.tst.sh`; refusing gate action per Q3 A + Q4 A; owned by B7)
- Trigger: before a placed brief is enqueued — run standalone and called from `spl_spawn_q_enqueue` in `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh` (function at `:217`, inside the `if [[ -n "$place" ]]` block at `:246-257` on `origin/master` `208e5f757`, right beside `li_brief_epic_spec` and `spl_spawn_q_enqueue_links`). Limit: an enqueue without `SPAWN_PLACE` has no brief file and skips O3.
- Does: refuses (exit non-zero, FATAL naming every missing/malformed field) a brief whose header lacks any of `Issue:` (or an explicit `Issue-Note:` / "spawn files it" line), `Epic:`, `Spec:`, `Kind:` (one of the 7 keys under `env.box.agent_split_by_kind` in `csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`), and `Topic:` (or `Discussion:`), each in its machine-readable form.
- Evidence: 618 of 3293 briefs (616 in October, 2 in November) have no `Kind:` line. Only 1000 carry an `Issue:` line, so 1727 lanes in this spec could be tied to their issue only by title, 65 of them ambiguously. A lane without these lines is invisible to every per-kind measurement, including this one.
- Gain (re-measure at +14 d, Q6 B): briefs with both `Kind:` and `Issue:` (or explicit spawn-files-it) lines, 990 of 3293 (30.1 %; `join.py` `lanes_with_kind_and_issue_line`) -> **95.0 % or more** (high-volume check: `3293 x 14/52 =` **~887 briefs** expected in 14 d, of which ~704 are in the 7 kinds).

## 5. Cross-kind overlap and parallel build rows

### 5.1 Cross-kind overlap: 21 slots, 18 deliverables (15 skills + 3 `./run` actions)

Each of the 3 shared skills is owned by **exactly one** build lane (the lane whose kind carries the stronger evidence in section 3.3 / Appendix B), so the 7 lanes edit zero overlapping files:

| shared skill | kinds served | counted | owning lane | why that owner |
|---|---|---|---|---|
| `numbered-id-claim` (+ gate `do_spl_numbered_id_check`) | specs_and_docs, complex_coding | once | **B4** (`complex_coding`, claude) | complex_coding holds 2 of 2 sample findings (`5980f95c`, `198445a6`); specs_and_docs had 0 in sample (4.1, 4.4) |
| `failure-path-cases` | tests, simple_coding | once | **B3** (`simple_coding`, claude) | simple_coding holds direct evidence (`21a21369`, SPL-5698); tests had 0 of 7 in sample (4.2, 4.3) |
| `e2e-no-swallowed-waits` | tests, i18n | once | **B2** (`tests`, claude) | tests holds direct evidence (`b8d356f9`) and owns test-suite hygiene; i18n is `agy 100` focused on locale/copy (4.2, 4.5) |

The other 12 skills are each used by one kind; the 3 orchestration items (O1..O3) are `./run` actions rather than skills (Q4 A). `sweep-bug-class` would also help complex_coding (`5577c422`), and `fold-ledger-delta` would help every author lane; they stay listed under one kind each to keep three slots per kind.

| # | kind | slot 1 | slot 2 | slot 3 | form |
|---|---|---|---|---|---|
| 1 | specs_and_docs | `claim-reruns-before-push` (+ gate) | `numbered-id-claim` *(B4)* | `fold-ledger-delta` | 2 skills + 1 gate (B1); 1 shared (B4) |
| 2 | tests | `red-control-in-commit` (+ gate) | `failure-path-cases` *(B3)* | `e2e-no-swallowed-waits` | 2 skills + 1 gate (B2); 1 shared (B3) |
| 3 | simple_coding | `failure-path-cases` | `sweep-bug-class` | `docs-none-proof` (+ gate) | 3 skills + 1 gate (B3) |
| 4 | complex_coding | `numbered-id-claim` (+ gate) | `shared-state-two-writer-test` | `route-authz-matrix` | 3 skills + 1 gate (B4) |
| 5 | i18n | `locale-fit-at-360` | `native-word-order-pass` | `e2e-no-swallowed-waits` *(B2)* | 2 skills (B5); 1 shared (B2) |
| 6 | secret | `secret-off-argv-and-env` | `secret-teardown-on-disable` | `parse-boundary-cases` | 3 skills (B6) |
| 7 | orchestration | `do_spl_plan_rows_parallel_place` | `do_spl_owner_ask_sweep_enqueue` | `do_spl_brief_header_check` | 3 `./run` actions, no skills (B7) |

### 5.2 Build rows (parallel, one lane per kind — Q1 C, Q7 A)

Per **Q1 C** (drop the shared-skills-first staging) and **Q7 A** (one lane per kind, vendor from `csi-spl-cnf/csi-spl/all.env.yaml:1567-1574`), all 7 rows queue **in parallel** with no `SPAWN_AFTER` chain and strictly disjoint files:

| row | kind (vendor / backup) | deliverables | owned files (disjoint) | verify |
|---|---|---|---|---|
| B1 | `specs_and_docs` (`agy` / `claude`) | S1 `claim-reruns-before-push` + gate `do_spl_claim_reruns_check`; S3 `fold-ledger-delta` *(S2 owned by B4)* | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{claim-reruns-before-push,fold-ledger-delta}/SKILL.md`, `csi-spl-orc/src/bash/run/spl-claim-reruns-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-claim-reruns-check.tst.sh` | `spl-claim-reruns-check.tst.sh` (with red control) + `do_spl_skills_refresh` dry-run |
| B2 | `tests` (`claude` / `agy`) | T1 `red-control-in-commit` + gate `do_spl_red_control_check`; T3 `e2e-no-swallowed-waits` *(shared with i18n; T2 owned by B3)*; **codex skill dir (`~/.codex/skills`)** in `install.sh` + `do_spl_skills_refresh` (Q2 A) | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{red-control-in-commit,e2e-no-swallowed-waits}/SKILL.md`, `csi-spl-orc/src/bash/run/spl-red-control-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-red-control-check.tst.sh`, `csi-spl-orc/src/bash/features/spool-install/install.sh`, `csi-spl-orc/src/bash/run/spl-skills-refresh.func.sh`, `csi-spl-orc/src/bash/tests/spl-skills-refresh.tst.sh`, `csi-spl-doc/specs/193-skills-per-agent-kind/codex-skills-refresh.md` | `spl-red-control-check.tst.sh` + `spl-skills-refresh.tst.sh` (case 10 codex + red control) + `do_spl_skills_refresh` dry-run |
| B3 | `simple_coding` (`claude` / `agy`) | C1 `failure-path-cases` *(shared with tests)*; C2 `sweep-bug-class`; C3 `docs-none-proof` + gate `do_spl_docs_none_check` | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{failure-path-cases,sweep-bug-class,docs-none-proof}/SKILL.md`, `csi-spl-orc/src/bash/run/spl-docs-none-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-docs-none-check.tst.sh` | `spl-docs-none-check.tst.sh` (with red control) + `do_spl_skills_refresh` dry-run |
| B4 | `complex_coding` (`claude` / `agy`) | X1 `numbered-id-claim` + gate `do_spl_numbered_id_check` *(shared with specs_and_docs)*; X2 `shared-state-two-writer-test`; X3 `route-authz-matrix` | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{numbered-id-claim,shared-state-two-writer-test,route-authz-matrix}/SKILL.md`, `csi-spl-orc/src/bash/run/spl-numbered-id-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-numbered-id-check.tst.sh` | `spl-numbered-id-check.tst.sh` (with red control) + `do_spl_skills_refresh` dry-run |
| B5 | `i18n` (`agy` / `claude`) | L1 `locale-fit-at-360`; L2 `native-word-order-pass` *(kept per Q5 A; L3 owned by B2)* | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{locale-fit-at-360,native-word-order-pass}/SKILL.md`, `csi-spl-orc/src/bash/tests/spl-skills-i18n-render.tst.sh` | `spl-skills-i18n-render.tst.sh` + `do_spl_skills_refresh` dry-run |
| B6 | `secret` (`claude` / `grok`) | K1 `secret-off-argv-and-env`; K2 `secret-teardown-on-disable`; K3 `parse-boundary-cases` | `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/{secret-off-argv-and-env,secret-teardown-on-disable,parse-boundary-cases}/SKILL.md`, `csi-spl-orc/src/bash/tests/spl-skills-secret-render.tst.sh` | `spl-skills-secret-render.tst.sh` + `do_spl_skills_refresh` dry-run |
| B7 | `orchestration` (`claude` / `grok`) | O1 `do_spl_plan_rows_parallel_place`; O2 `do_spl_owner_ask_sweep_enqueue`; O3 `do_spl_brief_header_check` *(code, not skills, Q4 A; O3 refusing gate wired into `spl_spawn_q_enqueue`)*; optional `[window start]` arg in `join.py` for the 14-day re-measure (Q6 B) | `csi-spl-orc/src/bash/run/{spl-plan-rows-parallel-place,spl-owner-ask-sweep-enqueue,spl-brief-header-check}.func.sh`, `csi-spl-orc/src/bash/tests/{spl-plan-rows-parallel-place,spl-owner-ask-sweep-enqueue,spl-brief-header-check}.tst.sh`, `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh`, `csi-spl-doc/specs/193-skills-per-agent-kind/join.py`, `csi-spl-doc/specs/193-skills-per-agent-kind/orchestration-actions.md` | all 3 `.tst.sh` files (with red controls) + existing `spl-spawn-enqueue` tests + `join.py` 2-arg baseline unchanged & 3-arg `[S, E]` filter green |

### 5.3 Disjointness, wiring, and post-land rollout

- **Zero file overlap across `B1..B7`** (verified on `origin/master` `208e5f757`):
  - Skill files auto-discover via `os.listdir` in `csi-spl-orc/src/bash/features/spool-install/install.sh:1050-1060` (and `test-y5-adopt.sh:70,116`), so only **B2** edits `install.sh`, `spl-skills-refresh.func.sh`, and `spl-skills-refresh.tst.sh` (solely to add `~/.codex/skills` per Q2 A; no other lane touches them).
  - `./run` actions auto-discover via `csi-spl-orc/src/bash/run/run.sh:347-357,389-390`, and orc tests auto-discover via `csi-spl-orc/src/bash/tests/run-all-tests.sh:116`, so no lane edits `run.sh` or `run-all-tests.sh`.
  - The 4 skill gate actions (`do_spl_claim_reruns_check`, `do_spl_red_control_check`, `do_spl_docs_none_check`, `do_spl_numbered_id_check`) ship as standalone refusing `./run` actions invoked by their skills; **none of `B1..B4` edits `csi-spl-iac/src/bash/run/check-pre-push.func.sh`**. Promoting any of them into the pre-push hook is a separate follow-up after the 14-day re-measure proves signal-to-noise.
  - Only **B7** touches `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh` (`spl_spawn_q_enqueue`, inside `if [[ -n "$place" ]]` right beside `li_brief_epic_spec` and `spl_spawn_q_enqueue_links`, to hook O3 `do_spl_brief_header_check`; note `spl-spawn-enqueue.func.sh` is an active file so B7 locates the hook by function name, not fixed line numbers) and `csi-spl-doc/specs/193-skills-per-agent-kind/join.py` (optional `[window start]` arg for Appendix A's 14-day re-measure).
  - **Docs rule (developer guide 2.10.2 & C3)**: none of `B1..B7` edits `spec.md` in parallel. **B2** (behaviour change to `install.sh` / `do_spl_skills_refresh` for codex) ships `csi-spl-doc/specs/193-skills-per-agent-kind/codex-skills-refresh.md`. **B7** (behaviour change to `spl_spawn_q_enqueue` adding O3 refusal + `O1..O3` actions) ships `csi-spl-doc/specs/193-skills-per-agent-kind/orchestration-actions.md` (`csi-spl-doc/doc/md/lane-issue-and-docs.md` is a Qto export, `:3`, so updating Qto follows after B7 lands). **B1, B3, B4, B5, B6** check changed identifiers with C3 (`docs-none-proof`) against `csi-spl-doc/` and root `*.md`, and use `Docs: none (...)` only when no existing doc goes stale.
- **Skill conciseness**: every `SKILL.md` must stay short, descriptive, and actionable per owner msg `16f273e3`, carry YAML `name:` + `description:` frontmatter (as `exit-clean/SKILL.md:1-7`), and use only the renderer's known tokens (`{{HARNESS_DIR}}`, `{{SPOOL_ROOT}}`, `{{AGENT_CEILING}}`, `{{ORCHESTRATOR_ID}}` at `install.sh:1038`) if any token is needed.
- **Post-land rollout and re-measure clock (`T0`)**: once all 7 rows land on `origin/master`, run `cd csi-spl-orc && DRY_RUN=0 ./run -a do_spl_skills_refresh` on each fleet box to render all 15 skills into every user's vendor dirs (including `~/.codex/skills` from B2). **`T0`** is the **committer date (`%cI`)** of the sha of the last row of `B1..B7` that landed on `origin/master` (not the author date, which can be older than landing after a rebase); the **Q6 B** re-measure runs at `T0 + 14 days`.

## 6. Owner decisions (Q1-Q7, decided 2026-11-25)

Owner HUM-10 answered poll form `43ebb003` in t1 `b1ec7ce2`, msg `70b8c145` (`2026-11-25T07:36Z`). Five answers matched the v1.1 recommendation (`A`); two changed the plan (**Q1 C** and **Q6 B**):

| Q | owner answer (msg `70b8c145`) | vs v1.1 rec | effect in v1.3 |
|---|---|---|---|
| **Q1** | **C** — All 7 kinds at once | changed (was A) | Dropped shared-skills-first staging; section 5.2 schedules all 7 rows `B1..B7` in parallel with disjoint files and explicit single-lane ownership of the 3 shared skills. |
| **Q2** | **A** — In the repo, rendered for each vendor by `do_spl_skills_refresh` | same | Confirmed `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/<name>/SKILL.md` (4.0, 5.2); **B2** owns adding `~/.codex/skills` to `install.sh` and `spl-skills-refresh.func.sh` so all 6 vendors receive the skills (section 1, 5.2). |
| **Q3** | **A** — The skill plus a gate action that refuses | same | S1, S2, T1 and C3 each gain a refusing `./run` gate action in `csi-spl-orc` (4.1-4.4, 5.2); O3 is a refusing `./run` action wired into `do_spl_spawn_enqueue` (4.7). |
| **Q4** | **A** — Build them as `./run` actions (code), not skills | same | O1..O3 converted to `./run` actions in B7 (`spl-plan-rows-parallel-place`, `spl-owner-ask-sweep-enqueue`, `spl-brief-header-check`), 0 orchestration `SKILL.md` files (4.7, 5.1, 5.2). |
| **Q5** | **A** — Keep `native-word-order-pass` and re-measure with the others (Q6) | same | L2 stays in B5 (4.5, 5.2) and re-measures at 14 days with its low-`n` caveat noted. |
| **Q6** | **B** — 14 days after landing | changed (was A, 30 d) | Every Gain target in section 4 and Appendix A sets the re-measure to `T0 + 14 days`. **Sample-size cost** (below and section 7): 14 days is 27 % of the 52-day lane window and 23 % of the 61-day commit/issue/FAIL window. |
| **Q7** | **A** — One lane per kind, its vendor taken from the kind table | same | `B1..B7` map 1:1 to the 7 rows of `all.env.yaml:1567-1574` (`agy` for B1, B5; `claude` for B2, B3, B4, B6, B7). |

### Sample-size cost of Q6 B (14 days vs 52-61 days)

The baseline in section 3 spans **52 days** for lanes (`2026-10-03T03:06Z .. 2026-11-24T11:25Z`, **3293** total briefs / 2615 in the 7 kinds) and **61 days** for raw commits, issues and FAIL messages (`2026-09-24T00:00Z .. 2026-11-24T11:25Z`). Because section 3.2 (`review_fails` in `join.py:198,285`) only counts FAIL messages whose issue appears in `kmap` (built from `serve.log`, 52 days), the effective window for per-kind FAILed-issue counts is the **52-day** lane window (**26.9 %**, `14 / 52`); scaling instead by the **61-day** raw message query bound (**23.0 %**, `14 / 61`) gives the lower bound shown in brackets below:

- **Well-powered at 14 days**: header completeness (`O3`, `3293 x 14/52 =` **~887 briefs** expected vs 3293 in 52 d, of which ~704 are in the 7 kinds), lead time (`O1`/`O2` `owner ask -> placed` for `complex_coding`, `specs_and_docs`, `simple_coding`), and `complex_coding` FAILed heads (`83 x 14/52 =` **22.3** [`19.0` at `14/61`]).
- **Single-digit at 14 days (wide noise)**: `specs_and_docs` (`32` -> **8.6** [`7.3`]), `simple_coding` (`24` -> **6.5** [`5.5`]), `tests` (`15` -> **4.0** [`3.4`]), `secret` (`14` -> **3.8** [`3.2`]). One or two outlier issues swing repeat-FAIL percentages by 15-25 points.
- **Underpowered at 14 days (`n = 0..2`)**: `i18n` had 1 FAILed head (`0.3` [`0.2`] expected) and 8 `owner ask -> deployed` issues (`2.2` expected) across 52 days, and individual section 3.3 finding classes (`n = 1..7` in 61 days) yield 0 to 2 findings per class unless every FAIL in the 14-day window is hand-labelled rather than sub-sampled. The 14-day re-measure report must therefore print `n` beside every metric, label every FAIL in the 14-day window where total FAILs are small, and mark cells with `n < 10` as underpowered (do not drop L1/L2/L3 or small-class skills on `n = 0..2`; carry them to a second read at +30 d if inconclusive).

### Original poll questions (v1.2 `9af22344e:329-335`, verbatim)

- **Q1. Which kinds are built first?** (A, recommended) the 3 shared skills first (`failure-path-cases`, `numbered-id-claim`, `e2e-no-swallowed-waits`): they fill 6 of the 21 slots with 3 builds; (B) the coding kinds first (tests, simple_coding, complex_coding: the most FAILed heads, 3.2); (C) all 7 kinds at once. -> Changes the order of the section 5 table and the build lanes' briefs.
- **Q2. Where do the skills live?** (A, recommended) in the repo under `csi-spl-orc/src/bash/features/spawn-agents/assets/skills/`, rendered per vendor by the existing `do_spl_skills_refresh` (4.0): no new mechanism; (B) in the repo, read by the brief; (C) only in each agent user's home. -> Changes the paths in section 4.0 and the build lanes' scope; under A, a codex dir is a small add: a flag block and a term in the `plan` line, as each vendor has (section 1).
- **Q3. Skills that a script can check (S1, S2, T1, C3, O3)?** (A, recommended) the skill plus a gate action that refuses: 3.2 shows repeat FAILs on rules the authors already knew, so advice alone is not enough; (B) the skill only; (C) the gate only. -> Changes the "Does" lines of S1, S2, T1, C3 and O3 (each gains its gate action).
- **Q4. The orchestration three (O1, O2, O3)?** (A, recommended) build them as `./run` actions (code), not skills: owner rule "orchestration = code, not intelligence"; (B) skills for the role seats; (C) drop them. -> Changes section 4.7 and the orchestration row of the section 5 table.
- **Q5. `native-word-order-pass` (n = 1 issue)?** (A, recommended) keep it and re-measure under Q6: the i18n kind has no thicker baseline (4.5); (B) replace it with the panel's next pick. -> Changes 4.5 L2 and the i18n row of the section 5 table.
- **Q6. Re-measure the gains?** (A, recommended) 30 days after landing, with `join.py` and Appendix A: the window here is 52 to 61 days, so 30 days gives about half the n; (B) 14 days; (C) no re-measure. -> Changes every "Gain" line in section 4 (its date) and Appendix A.
- **Q7. Who builds?** (A, recommended) one lane per kind, its vendor from the cnf table: the skills must work for that kind's main and backup (section 1); (B) one claude lane for all. -> Changes no section here; it sets the build lanes' `Kind:` and vendor.

## 7. Limits

- This box's spawn log only. The other machine's lanes and reviews that never reached the hub are missing, so every n is a lower bound.
- **The spawn log starts 2026-10-03T03:05Z** (no rotated copy), so lanes cover 52 days while commits, issues and messages cover 61. A commit from 2026-09-24 .. 2026-10-03 maps to a kind only when it cites an issue that a later lane carries.
- **14-day re-measure sample size (Q6 B)**: re-measuring at `T0 + 14 days` gives 26.9 % (`14/52`) of the 52-day lane window and 23.0 % (`14/61`) of the 61-day raw commit/issue/FAIL window. High-volume metrics (`O3` ~887 briefs, `complex_coding` ~22.3 [19.0] FAILed heads) have usable `n`, while `specs_and_docs` (~8.6 [7.3]), `simple_coding` (~6.5 [5.5]), `tests` (~4.0 [3.4]), `secret` (~3.8 [3.2]), and `i18n` (~0.3 [0.2]) have single-digit or zero expected FAILed issues (section 6). Cells with `n < 10` are directional only.
- 618 lanes (19 %) have no `Kind:` line and 60 carry another value: they are outside every per-kind number.
- The owner-ask time is the last owner message in the source topic before the issue (a lower bound on the wait).
- The issue for 1727 lanes comes from a title match; 65 were ambiguous (the lowest number was taken).
- The kind of an issue is its first lane's kind. The 3.3 sample was split by a different map (the lane with the `Issue:` line); 13 of the 45 findings differ (3.3, Appendix B).
- The section 3.3 classes come from one labeller on n = 45. The panel may re-label (Appendix B).
- CI covers 2026-11-15T19Z .. 2026-11-24T11Z, 9 of the 61 days: `gh run list` returns at most 1000 runs. 748 of the 1000 finished as success or failure; the other 252 are not counted. A re-fetch on 2026-11-25 of 2026-11-16 .. 2026-11-24T11:25Z (935 runs) shows every such run as `cancelled` (231 of 935), a run superseded by a newer push.
- "First commit" stands in for the first review head (3.4).
- The release-tag time stands for both dev and prd (inferred, section 2). `do_check_deploy_lag` gives only the current lag, not history.
- The CI column, the author-issue status column and the rework counts come from v0.1's scratch join and are not in `join.py`.

## Appendix A. Commands (v1.0 run 2026-11-25, read-only; Q6 B re-measure at `T0 + 14 days`)

Raw files go in one directory (`<raw>`); `join.py` joins them. Baseline window end `E=2026-11-24T11:25:00Z` (baseline start `START = "2026-09-24"` at `join.py:22`).

1. Kinds: `grep -n -A8 'agent_split_by_kind:' csi-spl-cnf/csi-spl/all.env.yaml`
2. Lanes (read by `join.py` itself from `$SPAWN_DIR/serve.log` and `$SPAWN_DIR/briefs/<id>.md`): `awk -F'\t' '$2=="SPAWNED" && $1>="2026-09-24" && $1<"2026-11-24T11:25:00Z"' /var/spool-hub/spawn-remote/serve.log | wc -l` -> 3293
3. `<raw>/commits.raw`: `git log 7e31ade12 --since=2026-09-24T00:00:00Z --format='%H%x09%aI%x09%cI%x09%s%x1e%b%x1f'` -> 10532 records
4. `<raw>/tags.tsv`: `git for-each-ref --format='%(refname:short)%09%(creatordate:iso-strict)%09%(*objectname)%(objectname)' 'refs/tags/v*'` (`join.py` drops tags created after E)
5. `<raw>/issues.txt`: `cd csi-spl-orc && ENV=prd SQL="select number||'|'||created_at||'|'||status||'|'||coalesce(completed_at::text,'')||'|'||coalesce(substring(description from '/t/([0-9a-f-]{36})'),'')||'|'||array_to_string(labels,',') as r from issues where tenant_id='t1' and created_at>='2026-09-24' and created_at<'$E' and deleted_at is null" ./run -a do_spl_db_query` -> 6354 rows
6. `<raw>/titles.txt`: `SQL="select number||'|'||regexp_replace(left(title,200),'[|\s]+',' ','g') as r from issues where tenant_id='t1' and created_at>='2026-09-20' and created_at<'$E' and deleted_at is null"` -> 6354 rows
7. `<raw>/owner_msgs.txt`: `SQL="select task_id||'|'||ts as r from messages where tenant_id='t1' and from_id='HUM-10' and ts>='2026-09-01' and ts<'$E'"` -> 1371 rows
8. `<raw>/fails.txt`: `SQL="select msg_id||'|'||ts||'|'||from_id||'|'||kind||'|'||coalesce(array_to_string(array(select distinct m[1] from regexp_matches(body,'SPL-([0-9]+)','g') m),','),'')||'|'||(left(body,300) ~ 'SEND-BACK')::text||'|'||left(regexp_replace(body,'\s+',' ','g'),2000) as r from messages where tenant_id='t1' and ts>='2026-09-24' and ts<'$E' and mirror_of is null and (left(body,300) ~ 'SEND-BACK' or left(body,400) ~ '\m(R7|review|reviewer|verdict)\M.{0,80}\mFAIL\M') order by ts, msg_id"` -> 1091 rows. The v1.0 dump ran without the `order by`, so its rows came in no fixed order (332 out of `(ts, msg_id)` order); [`fails-order.txt`](fails-order.txt) keeps that dump's row order and each row's SPL keys in their dumped order (the 1091 msg ids and their issue numbers, nothing else); `join.py` uses both, so a re-dump in any order gives the same seed-11 draw, the same first-message dedup and the same first lane-carried key (v1.2). Checked: rows and keys within rows shuffled -> identical `join.py` output.
9. Join: `SPAWN_DIR=/var/spool-hub/spawn-remote python3 -I csi-spl-doc/specs/193-skills-per-agent-kind/join.py <raw> 2026-11-24T11:25:00Z` (needs read access to the spawn dir) -> JSON with every number of 3.1 (spawns, issues, commits), 3.2 (FAIL columns), 3.3 (pool sizes, the seed-11 draw, the labels of `labels.tsv`) and 3.4.
10. Queue: `SQL="select work_kind, count(*), percentile_cont(0.5) within group (order by extract(epoch from updated_at-created_at)/3600) from fleet_asks where tenant_id='t1' and created_at>='2026-09-24' and state='done' group by 1"`
11. CI: `gh run list --workflow 10_ci-quality.yml --branch master --limit 1000 --created '>=2026-09-24' --json headSha,createdAt,conclusion` -> 1000 runs (oldest 2026-11-15T19:10Z); `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
12. Existing skills: `ls ~/.claude/skills .claude/skills csi-spl-orc/src/bash/features/spool-install/assets/*`; `git ls-tree -r --name-only origin/master | grep -E '/SKILL\.md$'`

### A.1 Q6 B 14-day re-measure commands (`[S, E]`)

On `origin/master` `208e5f757`, `join.py` hard-codes `START = "2026-09-24"` (`join.py:22,42,47`), takes exactly 2 args (`join.py:264-270`), and requires every baseline `labels.tsv` msg id to be present (`join.py:381-395`). **B7** owns adding an optional 3rd arg `[window start, ISO UTC]` to `join.py` (default `START = "2026-09-24"`, skipping the baseline `labels.tsv` lookup when a custom start is passed, keeping the 2-arg baseline output byte-identical).

Let `S=<T0>` be the **committer date (`%cI`, UTC)** of the sha of the last row of `B1..B7` that landed on `origin/master`, `E=<T0 + 14 days>` (ISO UTC), `S_TITLES=<T0 - 4 days>` (for title-match issues created just before `T0`), and `S_OWNER=<T0 - 30 days>` (for owner asks posted before `T0` whose lanes ran inside `[S, E]`). Run steps 1, 4, 11, 12 unchanged and substitute:
- Step 2 (lane check): `awk -F'\t' -v s="$S" -v e="$E" '$2=="SPAWNED" && $1>=s && $1<e' /var/spool-hub/spawn-remote/serve.log | wc -l`
- Step 3 (`<raw>/commits.raw`): `git log origin/master --since="$S" --until="$E" --format='%H%x09%aI%x09%cI%x09%s%x1e%b%x1f'`
- Step 5 (`<raw>/issues.txt`): replace `created_at>='2026-09-24'` with `created_at>='$S'` and `created_at<'$E'`
- Step 6 (`<raw>/titles.txt`): replace `created_at>='2026-09-20'` with `created_at>='$S_TITLES'` and `created_at<'$E'`
- Step 7 (`<raw>/owner_msgs.txt`): replace `ts>='2026-09-01'` with `ts>='$S_OWNER'` and `ts<'$E'`
- Step 8 (`<raw>/fails.txt`): replace `ts>='2026-09-24'` with `ts>='$S'` and `ts<'$E'`
- Step 9 (join, after B7 lands): `SPAWN_DIR=/var/spool-hub/spawn-remote python3 -I csi-spl-doc/specs/193-skills-per-agent-kind/join.py <raw> "$E" "$S"`
- Step 10 (queue): replace `created_at>='2026-09-24'` with `created_at>='$S' and created_at<'$E'`

Print `n` beside every metric, hand-label every FAIL in `[S, E]` where total FAILs are small, and mark any cell with `n < 10` as underpowered (section 6).

## Appendix B. The 71 sampled messages and their labels (72 rows: `fc46d63c` holds two findings)

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

## Appendix C. FAIL items and where they are answered

### C.1 v0.1 (`99cc31e3c`) FAIL items and where v1.0 answers them

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

### C.2 v1.0 (`32c584732`) FAIL items and where v1.1 answers them

Seat 1 is c-343 (msg e4eba434), seat 2 is c-202 (msg a7e5816f); both FAILed `32c584732`.

| item | change in v1.1 | check -> result |
|---|---|---|
| 1-W1, 2-W1, 7 kinds total | Section 2: 3237 -> 2615 (2615 + 622 + 56 = 3293). | `join.py` lanes_by_kind, the 7 kinds -> 924 + 715 + 438 + 217 + 205 + 116 = 2615 |
| 1-W2, unordered FAIL dump | Appendix A step 8 gains `order by ts, msg_id`; `fails-order.txt` pins the v1.0 dump's row order; `join.py` `fail_rows` sorts by it. The draw and labels are unchanged. | `shuf fails.txt` then `join.py` -> output identical to the unshuffled run |
| 1-W3, FAIL credited to first key | `review_fails` takes the first key that a lane carries, as `sample` does. 3.2 re-run: four rows move; section 0 line 2, S1, S3, C2, X3 and K2 quote the new numbers; tests, i18n and T1 do not move. | v1.0 and v1.1 `join.py` output diff -> only `review_fails` differs |
| 1-N1 | Status line names both seats. | |
| 1-N2, 2-N1 | Section 1: 5 vendors, named; Q2: "a small add". | `spl-skills-refresh.func.sh` checks `.qwen`, `.gemini`, `.vibe`, `.grok` besides `.claude` |
| 1-N3, 2-N2 | T2: SPL-4343 -> `21a21369` (SPL-1910). | `grep -c SPL-4343 spec.md` -> 0 |
| 1-N4, anchored `Kind:` | Not changed: the spawn reads the first `Kind:` anywhere (`spawn-window.sh:598`, `spl-lane-mix.func.sh:366`, `grep -m1 -oE 'Kind:...'`), so `join.py` reads it as lanes are routed; a comment says so. Anchoring would move 200 lanes to `none` (e.g. "Language: Go. Kind: stability"). | anchored `join.py` -> 200 lanes change kind |
| 1-N5 | `join.py` comment: the simple_coding and i18n draws stay because they advance the RNG. | |
| 1-N6, 2-N3 | Appendix B heading and section 3.3 say 72 rows for 71 messages. | |

### C.3 v1.1 (`585691f6e`) notes and where v1.2 answers them

Both seats PASSed v1.1 (c-343 msg 452d9df0, c-202 msg 38adb88d); the holder's GO put these two notes in a follow-up commit.

| item | change in v1.2 | check -> result |
|---|---|---|
| 2-N1, key order in a row | `fails-order.txt` now also holds each message's SPL keys in the v1.0 dump's order (`<msg id> <keys>`, `-` for none); `fail_rows` uses that order, and number order for a message it lacks. | 72 of the 159 rows with 2+ keys are in text order, so the dump's key order is not reproducible from SQL; rows and keys within rows shuffled -> `join.py` output identical |
| 1-N1, `Kind:` pattern | `join.py` uses the spawn's pattern, `Kind:[*_ ]*([A-Za-z0-9_]+)`, lowercased. 4 October lanes with no issue move from no `Kind:` to `wui` (3) and `spec` (1): section 2, 3.1, O3 and section 7 read 618 and 60. Section 2's 2615 and every issue, commit and 3.2 number are unchanged. | v1.1 vs v1.2 `join.py` output diff -> only `lanes_by_kind` |

### C.4 v1.2 (`9af22344e`) -> v1.3: owner Q1-Q7 answers and `c-512` review folded (`SPL-6478`)

Owner HUM-10 answered form `43ebb003` in t1 `b1ec7ce2`, msg `70b8c145` (`2026-11-25T07:36Z`). Because v1.2 had already landed on `origin/master` as `9af22344e` (folding the two v1.1 panel notes), folding Q1-Q7 becomes **v1.3 — decided** without regressing v1.2. Every `file:line` citation was verified on `origin/master` `208e5f757b7f6678df9753bfa8e6a97367f8fa27`.

| Q / requirement | change in v1.3 | verified on `origin/master` `208e5f757` |
|---|---|---|
| Q1 C (all 7 kinds at once) + Q7 A (one lane per kind, cnf vendor) | Section 5.1 assigns each of the 3 shared skills to exactly one lane (`numbered-id-claim` -> B4, `failure-path-cases` -> B3, `e2e-no-swallowed-waits` -> B2); section 5.2 adds 7 parallel build rows `B1..B7` with disjoint files and no `SPAWN_AFTER`; section 5.3 proves zero file overlaps across all 38 owned paths. | `all.env.yaml:1567-1574` (`agent_split_by_kind`), `install.sh:1050-1060` (`os.listdir`), `run.sh:347-357,389-390`, `run-all-tests.sh:116`, `test-y5-adopt.sh:70,116` -> all auto-discovered; 33 new paths free, 5 existing files each owned by one lane |
| Q2 A (repo + `do_spl_skills_refresh` + codex dir) | Sections 1, 4.0 and 5.2 pin `assets/skills/<name>/SKILL.md` and `do_spl_skills_refresh`, and assign `~/.codex/skills` rendering (`install.sh`, `spl-skills-refresh.func.sh`, `spl-skills-refresh.tst.sh`, `codex-skills-refresh.md`) exclusively to **B2**. | `spl-skills-refresh.func.sh:31-76,88-91,96-118`, `install.sh:533,1038-1060`, `trust-workdir.sh:23,239`, `spl-skills-refresh.tst.sh:17-20` |
| Q3 A (skill + refusing gate action) | Sections 4.1-4.4 and 5.2 add standalone refusing `./run` gate actions for S1, S2, T1, C3 (none touching `check-pre-push.func.sh`), plus O3 in B7. | `run.sh:347-357,389-390`; 4 new `spl-*-check.func.sh` paths free |
| Q4 A (O1..O3 as `./run` actions, not skills) | Sections 0, 4.7, 5.1 and 5.2 convert O1..O3 to `./run` actions in B7; B7 is the sole editor of `spl-spawn-enqueue.func.sh` (`spl_spawn_q_enqueue`, `if [[ -n "$place" ]]` block) for O3 and ships `orchestration-actions.md`. | `spl-spawn-enqueue.func.sh:217,246-257,337-343`, `lane-issue.inc.sh:183`, `spl-spawn-after.func.sh:49-70`, `spl-spec-rows-unqueued.func.sh:28-63`, `spl-unanswered-sweep.func.sh:120-154` |
| Q5 A (keep `native-word-order-pass`) | Section 4.5 L2 and section 5.2 B5 keep L2 and schedule its re-measure under Q6 B with low-`n` guard. | `grep -n 'native-word-order-pass' spec.md` -> in 4.5, 5.1, 5.2, 6 |
| Q6 B (14 days after landing) + Gain rates | Section 4 Gain lines convert every absolute v1.2 target to its exact equivalent rate with zero loosening (`S1 < 25.0 %`, `T1 <= 2.2 % / < 5.6 %`, `T2 <= 4.4 %`, `C2 <= 12.5 %`, `X3 < 10.0 %`, `K2 <= 7.1 %`, `K3 <= 2.2 %`, `O3 >= 95.0 %` on ~887 briefs); section 6, section 7 and Appendix A.1 state the 52 d (`26.9 %`) vs 61 d (`23.0 %`) sample-size cost and exact `[S, E]` re-measure commands; B7 adds `[window start]` to `join.py`. | `join.py:22,42,47,198,264-270,285,381-395`; `spec-rows-unqueued.py` parses `decided v1.3` + `B1..B7` |

Cross-vendor review fold (`c-512@sat`, claude, FAIL on `dc0f01191`, msg `09fe4349`):

| item | change in v1.3 (head 2) | check -> result |
|---|---|---|
| W1, 14-day re-measure recipe & `join.py` | Appendix A.1 gives exact `[S, E]` substituted commands (`S = T0`, `E = T0 + 14 d`, `S_TITLES = T0 - 4 d`, `S_OWNER = T0 - 30 d`); B7 owns adding optional `[window start]` (skipping baseline `labels.tsv` when custom) to `join.py` (`join.py:22,42,47,264-270,381-395`). | `grep -n 'join.py' spec.md` -> owned by B7 in 5.2, 5.3, A.1 |
| W2, Q6 sample-size numbers | O3 14-day briefs fixed from ~700 to ~887 (`3293 x 14/52`, ~704 in 7 kinds); section 6 and 7 explain why `kmap`-joined 3.2 FAILed-issue counts scale on the 52 d lane window (`join.py:198,285`, 26.9 %) and print the 61 d bound (23.0 %) in brackets beside every kind. | `3293 * 14 / 52 = 886.6`, `83 * 14 / 61 = 19.0`, `32 * 14 / 61 = 7.3` |
| W3, codex under Q2 A | Restored codex (`~/.codex/skills`) in scope; **B2** solely owns `install.sh`, `spl-skills-refresh.func.sh`, `spl-skills-refresh.tst.sh` and `codex-skills-refresh.md` (zero overlap with other rows). | disjointness script -> 7 rows, 38 paths, 0 overlaps |
| W4, verbatim poll text | Section 6 restores `9af22344e:329-335` byte-for-byte under `Original poll questions (v1.2 9af22344e:329-335, verbatim)`. | `diff` against `git show 9af22344e:...:spec.md \| sed -n 329,335p` -> 0 lines |
| W5, Gain target rates | Removed silent loosening on C2 (`15 %` -> `<= 12.5 %`, exact `3/24`) and K2 (`10 %` -> `<= 7.1 %`, exact `1/14`), replaced S1's absolute `under 8` with `< 25.0 %` (exact `8/32`), and stated every Gain target as its exact rate with baseline and 14 d `n`. | every Gain line in 4.1-4.7 matches v1.2 count / v1.2 n |
| N1, `spl_spawn_q_enqueue` | Named `spl_spawn_q_enqueue` (`:217`, `if [[ -n "$place" ]]` `:246-257`), stated non-`SPAWN_PLACE` skip limit, cited by function name in 5.3. | `grep -c 'spl_spawn_q_enqueue' spec.md` -> 7 |
| N2, `T0` committer date | Defined `T0` as committer date (`%cI`, UTC) of the last landed sha of `B1..B7` in 5.3 and A.1. | `grep -c 'committer date' spec.md` -> 3 |
| N3, docs rule for B2/B7 | B2 owns `codex-skills-refresh.md` and B7 owns `orchestration-actions.md`; B1/B3-B6 verify with C3 (`docs-none-proof`) before using `Docs: none`. | section 5.2 and 5.3 updated |
| N4, `run.sh:879-896` | Scoped `run.sh:347-357,389-390` as discovery code and labelled `:879-896` as the lazy-loader rationale comment (4.0) and dropped it from 5.3. | `grep -n 'run.sh:' spec.md` -> 4.0, 5.3, C.4 |

<!-- last-edit: 2026-11-25T09:44:00Z -->
