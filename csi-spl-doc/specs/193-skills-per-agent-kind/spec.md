# Spec 193: the three most essential skills per agent kind

Status: **v0.1** (2026-11-24, draft for the panel; editor c-774, claude). Doc only: no skill, code, cnf or workflow changes here. The build is a later lane, after the owner picks (section 6).
Epic: **SPL-2402**. Issue: **SPL-6375** (label `answer`). Class: `feature`. Kind: `specs_and_docs`.
Discussion: t1 topic `b1ec7ce2`, task `dispatch-b1ec7ce2`.
Related: [115 vendor split by task kind](../115-vendor-split-by-task-kind/spec.md), [lane issue and docs](../../doc/md/lane-issue-and-docs.md), [developer guide](../../doc/md/developer-guide.md) section 2.

Baseline tree: the git counts ran on `origin/master` `7e31ade12fd86797b337cab9f55a3f654e5a0c4c`; the doc was written on `e57682be31e8c75270a7fec614283c4628ceae62`.
Window: **2026-09-24 .. 2026-11-24** (the last 2 months).
Numbering: `git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail` ends at `192-agent-login-from-wui`; `git ls-remote origin 'refs/heads/*' | grep -iE '193|skills-per'` -> empty.

## Owner's words (HUM-10, t1 `b1ec7ce2`, 2026-11-24)

> "Create a panel discussion to create the three most essential skills per agent kind, based on the vendor split settings for each of the agent kinds (based on the last 2 months of discussions and the type of work which has been done). By analyzing the database, the discussions, and the actual results, make how fast the feature has arrived." (msg `75bace2f`)

> "Note: the skills must be short, descriptive, and not overly generic. Create the topmost skills which give the most back for the buck." (msg `16f273e3`)

## 0. Answer in five lines

1. The time from the owner's ask to the result is spent **before the lane starts**, not in it: owner's last message -> lane placed has a median of 4.0 h (complex_coding) to 26.8 h (i18n), p90 34 h to 222 h. Lane placed -> landed has a median of 0.5 h to 1.8 h. Landed -> next release tag has a median of 0.3 h or less (section 3.4).
2. Inside the lane, the review rounds cost the most. 27 of the 82 complex_coding issues that got an R7 FAIL failed again on a second head (section 3.2).
3. The most common blocking findings in a hand-labelled sample of 45 are: **a failure path that fails open or is swallowed** (7), **a doc or claim that does not match the tree** (6), **a secret or authorisation leak** (6), and **a test that cannot go red** (5) (section 3.3).
4. Section 4 gives 21 skill slots (3 per kind), which come to **18 distinct skills** because 3 of them serve two kinds (section 5). None of them is a skill that already exists or a rule that an action already enforces (section 4.0).
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

The skills must work for the main vendor and the backup. For simple_coding that means agy as well as claude (41 against 44).

## 2. How it was measured

All counts are for **this box's** spawns. The spawn log on the other machine was not read, so "n" here is a lower bound on the fleet's.

- **Lanes**: `SPAWNED` rows of `/var/spool-hub/spawn-remote/serve.log` from 2026-09-24 onward: n = **3293** (agent id, vendor, slug, brief id). The kind is the brief's `Kind:` line. The issue is the brief's `Issue:` line (1000 lanes). For another 1727 lanes it is the hub issue whose title equals the brief's first line, because the spawn files the issue from the brief's title (65 of those titles were ambiguous: the lowest number was taken). That gives **2727 of 3293** lanes with an issue.
- **Landed work**: `git log origin/master --since=2026-09-24` -> **10532** commits. A commit belongs to an issue when its subject or a `Closes:` trailer names the key. **3133** commits map to a lane kind.
- **Deploys**: the first release tag (`v<X.Y.Z>` or `v<X.Y.Z>-c<N>`, `git for-each-ref refs/tags/v*`) at or after the commit on the linear trunk. Hub and WUI deploys mint one tag for dev and prd (developer guide 1.2/1.3), so the tag time stands for both. Docs-only commits are left out (they do not deploy).
- **Owner ask**: the owner's (HUM-10) **last** t1 message in the issue's source topic (`## Source /t/<uuid>` in the description) before the issue was created. This is a **lower bound**: in a long topic the actual ask may be older.
- **Review failures**: t1 hub messages (`do_spl_db_query`, read-only) with an R7 `FAIL <sha>` verdict or a `SEND-BACK`, n = **1101** messages. Reviews that stayed on one box and never reached the hub are missing, so these counts are lower bounds.
- **CI**: `gh run list --workflow 10_ci-quality.yml --branch master --limit 1000` (2026-11-15T19Z .. 2026-11-24T11Z, 748 finished runs) and `CI_GATE_RUNS=100 do_report_ci_gate`.
- Only t1 (the operator workspace) was read. No customer workspace, person or secret is quoted.

The commands are in Appendix A.

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
| (no `Kind:` line, all in October) | 622 | - | - | - |

"Author issues" excludes the review, panel and seat lanes (slug matches `review|reviewer|r7|seat|panel|verif|audit`), because a seat's issue is closed `diss` by design. Two numbers need care:
- 6 of the 8 i18n "diss" lanes are agy or claude **language reviews** whose slug does not say "review"; the other 2 are LinkedIn post drafts. This is not failed work.
- 14 of the 17 secret "diss" lanes, judged by their titles, could not land a csi-spl commit by their nature: ops, analysis, or documents in other repos.

The spawn mix on this box is not the cnf split: specs_and_docs went to claude 390 times and to agy 205 times. The likely reason is the data rule (a brief that reads hub data is secret-class), but that was not checked per lane.

### 3.2 What went wrong

| kind | issues with >= 1 R7 FAIL | of them FAILed again on a 2nd head | max FAILed heads | CI red heads (last 748 runs) |
|---|---|---|---|---|
| complex_coding | 82 of 599 | 27 | 5 | 11 of 76 |
| specs_and_docs | 37 of 642 | 14 | 11 | 17 of 206 |
| simple_coding | 25 of 394 | 7 | 4 | 23 of 174 |
| tests | 15 of 142 | 4 | 2 | 1 of 14 |
| secret | 15 of 159 | 4 | 3 | 4 of 21 |
| i18n | 1 of 64 | 0 | 1 | 0 of 6 |

- A "FAILed head" is a distinct `FAIL <sha>` per issue, so two reviewers failing the same head count once.
- A CI red is a red `10_ci-quality` run whose head commit cites an issue of that kind. The head is the pusher, not always the cause.
- CI is not the main cost: 7 of the last 100 runs failed (2026-11-23T13Z .. 2026-11-24T11Z). By the job that broke each run first: orc hermetic 4/4 broke 2, iac tfvars parity broke 2, hub go test broke 2 and orc hermetic 2/4 broke 1. One of the 7 was an orc check that was skipped in CI.
- **Rework** (a second author lane on the same issue): 3 specs_and_docs, 3 simple_coding, 2 complex_coding and 5 secret issues. This is rare. The cost is in the review rounds, not in respawns.

### 3.3 Why reviews fail: a hand-labelled sample

Keyword counts did not work. On a sample of 24, "red control" mostly matched a reviewer *reporting* that it ran the controls, which made only about 1 hit in 3 correct. So the blocking finding (`W1` / `B1`) of FAIL messages was read and labelled by hand.

The sample was a random draw (seed 11) per kind: 14 complex_coding, 14 specs_and_docs, 10 tests, 6 secret and 5 i18n, plus every simple_coding and i18n message in the pool. Relays ("W1 fixed", "W1-W3 folded") were dropped. That leaves **n = 45** findings. One labeller (this editor) did the labelling, and the panel may re-label.

| class | n | examples (msg id prefix or issue) |
|---|---|---|
| failure path fails open, is swallowed or does not fail fast | 7 | `a7ebbac7`, `ebadef55`, `0c77b97f`, `5b1e8b4b`, SPL-4343, SPL-5698 (`a93e795a`), SPL-5564 |
| doc, spec or claim does not match the tree | 6 | `53b09832`, `e25577a1`, `ece509e7` (coverage numbers wrong), `6ed5c1a1`, `a5e1921c`, SPL-5740 ("Docs: none" was false) |
| secret or authorisation leak | 6 | `ab83fbd3` (token on argv), SPL-5495 (alias env var stays exported), SPL-4881 (token left on disk when turned off), SPL-4810 (masked value leaks on wrap), `15040649` and SPL-4895 (another workspace or a locked box) |
| a test that cannot go red (mock, swallowed wait, runs on after an error) | 5 | `a4433661`, `b53cd5c6`, `b8d356f9`, SPL-5372 (x2) |
| regex or parse edge case | 4 | `66fea976`, `a70feab4`, SPL-5555 (unanchored), SPL-5564 |
| race or two writers | 3 | `c3fcfe47`, `388e3d15`, SPL-4629 |
| numbered id collides with trunk or another branch | 3 | `198445a6` (migration + spec section), `5980f95c` (spec 3.17 / C71), SPL-5372 (0276 on 3 branches) |
| spec leaves a case undefined or contradicts itself | 2 | `c3ff1e57`, `0a43b9dc` |
| issue-closing or trailer rule | 2 | `2e7df79c`, `9648cf2c` |
| a sibling of the fixed bug left in place | 1 | `5577c422` ("six more caller knobs, same bug class") |
| other (logic, layout at 360 px, word order, config precedence, literal fallback) | 6 | SPL-5698, SPL-4824, SPL-5349, SPL-5480, SPL-1910, `aeef6c0e` |

The issue-closing and trailer findings (2) are left out of section 4 because `/exit-clean` (`kill-your-self-report.sh --gate`) and the closer already enforce them.

### 3.4 How fast the feature arrived

Hours, median / p90 (n). Each segment is measured on the issues that have both ends, so the rows do not add up.

| kind | owner ask -> placed | placed -> first commit | placed -> landed | landed -> release tag | owner ask -> deployed |
|---|---|---|---|---|---|
| complex_coding | 4.0 / 34.3 (152) | 0.2 / 1.3 (502) | 1.8 / 10.3 (543) | 0.0 / 0.9 (538) | 14.5 / 60.1 (140) |
| simple_coding | 12.4 / 128.8 (82) | 0.1 / 0.6 (348) | 0.9 / 3.7 (367) | 0.2 / 1.4 (364) | 13.8 / 137.9 (78) |
| specs_and_docs | 8.6 / 119.2 (133) | 0.2 / 0.8 (176) | 0.5 / 3.9 (295) | 0.2 / 1.2 (145) | 11.3 / 139.6 (59) |
| tests | 23.5 / 59.6 (41) | 0.2 / 1.6 (103) | 1.5 / 8.6 (135) | 0.3 / 2.1 (63) | 18.0 / 60.6 (21) |
| secret | 15.5 / 221.9 (27) | 0.2 / 3.9 (48) | 1.1 / 5.8 (52) | 0.1 / 0.8 (48) | 20.3 / 152.7 (13) |
| i18n | 26.8 / 85.0 (8) | 0.3 / 0.5 (12) | 0.7 / 9.5 (21) | 0.0 / 0.0 (21) | 37.7 / 87.3 (8) |

- "Placed" is the spawn time. Issue -> placed is a median of 0.0 h for every kind, because the spawn files the issue. So **owner ask -> issue** is the wait before the lane: a median of 2.6 h (complex_coding) to 22.4 h (tests), p90 33 h to 217 h.
- The hub's queue is not that wait. `fleet_asks` (rows from 2026-11-16) goes from created to done in a median of 0.1 h to 0.5 h per `work_kind`, p90 0.3 h to 10.1 h. The time goes into the step before the ask is queued: the dispatcher's draft, panel and spec rounds, plan signing, and the owner's answers.
- "First commit" is the earliest author date of a citing commit. It stands in for the first review head, because review branches are deleted after landing.
- **The biggest waits** (owner ask -> landed): SPL-5027 370 h (a spec 158 row); SPL-4835 293 h; SPL-6201, SPL-6203, SPL-6204, SPL-6207 and SPL-6208 249 h to 252 h; SPL-6141 239 h; SPL-6133 236 h. SPL-6201, -6203 and -6207 are rows L4, L6 and L5 of spec 123 section 16.6. Each landed about 1 h after placement, so each was placed about 10 days after the owner's last message in that topic: **build-plan rows placed one after another**. Whether a real dependency held them was **not checked**.

## 4. The skills: three per kind

### 4.0 Not already a skill or an enforced rule

Checked on this box on 2026-11-24:
- `ls ~/.claude/skills` -> agent-msg, exit-clean, graft, kill-your-self, paste-html-into-chrome, scrum-file-update, spec-kit-tasks, synced, tmux-color.
- `ls .claude/skills` in the repo -> none.
- `csi-spl-orc/src/bash/features/spool-install/assets/` -> claude (settings, claude-md), agy/rules (`30-exit-after-accepted.md`, `40-git-no-pager.md`), kill-guard, rm-guard, vibe-output-cap, vibe-push-guard.

These existing gates leave a gap that each pick below fills:
- `lint-migration` refuses a taken migration number only at push time, and checks nothing for spec folders, sections or case ids.
- `do_spl_review_line_check` proves that the **reviewer** ran the red controls. On the author's side the rule is "review only" (developer guide 2.12.1).
- `kill-your-self-report.sh --gate` checks that a `Docs: none (...)` line is **present**, not that it is true.
- `TestRLSCoversEveryTenantTable` works at the table level, not per route.
- `lint-gitleaks` and `lint-trufflehog` find secrets in files, not on argv or in a child's environment.
- `do_spl_spec_rows_unqueued` (daily digest) finds rows that are unqueued, not rows queued one at a time.
- `do_spl_unanswered_sweep` finds owner posts with no answer, not answered asks that were never enqueued.

Each skill below gives: name, trigger, what it does (5 lines or fewer), the evidence, and the expected gain (a target the build lane re-measures with Appendix A).

### 4.1 specs_and_docs (main agy, backup claude)

**S1 `claim-reruns-before-push`**
- Trigger: a doc or spec diff that contains a number, count, path or "command -> result" claim.
- Does: (1) finds every claim line in the diff that carries a command (backticked command, then `->`, then a result). (2) Re-runs each one read-only on the tree it names. (3) Prints MATCH or DIFF per line. (4) Refuses the push on a DIFF. (5) Flags a bare number with no command as "unchecked".
- Evidence: "doc or claim does not match the tree" is 6 of 45 sampled findings (3.3), including wrong coverage numbers (`ece509e7`) and a false sentence about what deploys (`a5e1921c`).
- Gain: specs_and_docs issues that FAIL again on a 2nd head, 14 of 37 -> under 7.

**S2 `numbered-id-claim`** (shared with complex_coding)
- Trigger: a new spec folder, spec section number, case id (`C71`), migration number or plan row id.
- Does: (1) lists the ids already taken on `origin/master`, every `review/*` and `wip/*` branch and every live worktree. (2) Prints the next free id. (3) Before each review head, runs `git merge-tree --write-tree origin/master HEAD` and flags an id this diff adds that another ref also adds.
- Evidence: numbered-id collisions are 3 of 45 (3.3): migration 0276 on 3 branches at once (SPL-5372), spec section 3.17 / C71 (`5980f95c`), migration plus spec section (`198445a6`). This lane's own brief had to check `review/*` for spec 192 by hand.
- Gain: id-collision FAILs and land-time renumbers, 3 in the sample -> 0.

**S3 `fold-ledger-delta`**
- Trigger: the editor or author receives a FAIL or SEND-BACK with W/N lines.
- Does: (1) writes one table, `W/N id | file:line changed | commit | check command -> result`. (2) Requires a check per W (e.g. `grep -c '25 posts' spec.md -> 0`). (3) Pushes ONE new head and sends the table, so the reviewer reviews a delta.
- Evidence: of the specs_and_docs issues with an R7 FAIL, 14 of 37 failed again on a later head, and one went to 11 FAILed heads (3.2). In the sample, the same issues come back with W-lines on the same code (SPL-5698, SPL-4629, SPL-4881).
- Gain: maximum FAILed heads per specs_and_docs issue 11 -> 3 or fewer; repeat-FAIL share 14 of 37 (38 %) -> under 20 %.

### 4.2 tests (main claude, backup agy)

**T1 `red-control-in-commit`**
- Trigger: a commit that adds or changes a test.
- Does: (1) reverts the fix, or plants the bug, in a throwaway copy. (2) Runs only the new cases and records `rc` and the failing count. (3) Re-applies the fix and records the green run. (4) Writes both lines into the commit body. (5) Refuses when the new case did not run (it was skipped or 0 cases matched).
- Evidence: "a test that cannot go red" is 5 of 45 (3.3): a test that checks the mock instead of the contract (`a4433661`), controls that stay green (`b53cd5c6`), e2e that runs on after an error (`b8d356f9`). An orc check skipped in CI broke 1 of 7 recent CI reds (3.2).
- Gain: vacuous-test findings, 5 in 45 -> 1 or fewer; tests issues with an R7 FAIL, 15 of 142 -> under 8.

**T2 `failure-path-cases`** (shared with simple_coding)
- Trigger: a diff that calls something that can be missing or fail: a binary, file, OS user, hub read, network or child process.
- Does: (1) lists each such call site. (2) For each one, writes the case where it is missing or fails. (3) Asserts the documented outcome: fail fast (`rc != 0`, FATAL on stderr) or a **named** fail-open. (4) Refuses `|| true`, `.catch(() => null)` or `2>/dev/null` without a comment that names the decision.
- Evidence: the largest class, 7 of 45 (3.3): a FATAL text captured as a unit name (SPL-5698), a match that fails open (SPL-4343), a source status discarded (`5b1e8b4b`), a failed hub read that goes on (`ebadef55`), an uncaught missing tool (SPL-5564).
- Gain: failure-path findings, 7 in 45 -> 2 or fewer.

**T3 `e2e-no-swallowed-waits`** (shared with i18n)
- Trigger: a WUI e2e test is added or changed.
- Does: (1) refuses `.catch(() => null)` on `waitFor*`. (2) Stops the case at the first navigation error. (3) Runs against the generated bundle (`nuxt generate` + mock serve), never `nuxi dev`. (4) Repeats a new case 3 times (n = 3) before it is called green.
- Evidence: SPL-5372 (FAIL W1 twice: a swallowed 8 s wait, then a pick that fails on `nuxi dev`), SPL-5441 (`b8d356f9`: the test runs on after `nav()` fails). The WUI e2e shards are 8 of the gate's jobs (`do_report_ci_gate`).
- Gain: e2e findings of this shape, 3 in 45 -> 0.

### 4.3 simple_coding (main claude, backup agy)

**C1 `failure-path-cases`**: see T2. It is counted once.

**C2 `sweep-bug-class`**
- Trigger: a reviewer W names a bug, or the lane fixes one.
- Does: (1) turns the bug into a search pattern (the bad call, the unanchored regex, the unset env knob). (2) Greps the whole repo for siblings. (3) Fixes them in the same head, or lists them with a reason. (4) Adds one test per sibling fixed.
- Evidence: `5577c422` ("six more caller knobs still reach the hook, same bug class as your knob fix"); SPL-5698 and SPL-4629, which each came back with several FAIL messages on the same function. 7 of the 25 simple_coding issues with a FAIL failed again on a 2nd head (3.2).
- Gain: simple_coding repeat FAILs, 7 of 25 -> 3 or fewer.

**C3 `docs-none-proof`**
- Trigger: a commit message with `Docs: none (...)`, or a behaviour change with no `csi-spl-doc/` path.
- Does: (1) takes the changed identifiers (action names, env vars, function names, event kinds, file names) from the diff. (2) Greps `csi-spl-doc/` and the root `*.md` for each one. (3) Prints every hit with `file:line`. (4) A hit means a doc to update, or a written reason why it still holds.
- Evidence: SPL-5740, where the W1 was "the Docs: none reason is wrong, two docs go false with this commit". `6ed5c1a1` (fleet-rules-index row stale after the code moved). "Doc does not match tree" is 6 of 45.
- Gain: doc-drift findings on coding lanes, 3 in 45 -> 0.

### 4.4 complex_coding (main claude, backup agy)

**X1 `numbered-id-claim`**: see S2. It is counted once.

**X2 `shared-state-two-writer-test`**
- Trigger: a diff that reads, then writes, shared state: a Postgres row or counter, a file under the spool root, a ledger or a cron-trimmed log.
- Does: (1) names each read-modify-write. (2) Puts it in one transaction (`SELECT ... FOR UPDATE`) or under one `flock`. (3) Adds a test with two writers started together (`&` + `wait`, or two goroutines) that fails without the lock.
- Evidence: "race or two writers" is 3 of 45: a login lockout counted before it is recorded, with no transaction (`c3fcfe47`), a trim that loses another mount's record (SPL-4629), a mirror key that does not move `updated_at` (`388e3d15`).
- Gain: race findings, 3 in 45 -> 0.

**X3 `route-authz-matrix`**
- Trigger: a new or changed hub route or read that returns workspace data, or a WUI view over one.
- Does: runs a table-driven test over caller = {owner, member, guest/demo role, another workspace's owner, a box locked to someone else} x action = {read, list, counts, write}. It expects 403 or an empty, counted result where the spec says so. It checks the credential **type** (view token vs upload token), not only that a mock answered.
- Evidence: `15040649` (any workspace's channel owner could make the operator fleet spawn), SPL-4895 (counts and unread of a locked box leak), `a4433661` (the WUI sends the view token where the hub accepts only an upload token).
- Gain: authorisation findings, 3 in 45 -> 0; complex_coding issues with an R7 FAIL, 82 of 599 -> under 60.

### 4.5 i18n (main agy, backup claude)

**L1 `locale-fit-at-360`**
- Trigger: a new or changed WUI string in any locale.
- Does: (1) for each changed key, picks the longest of the 19 locale values. (2) Renders the view in Chrome at 360 px and 412 px with that value. (3) Fails on overlap with a neighbouring control, clipping without an ellipsis, or a horizontal scroll.
- Evidence: SPL-5349 W1 (the `✓ N` badge drawn over the card-size control at 360 px).
- Gain: layout FAILs on i18n rows, 1 in 45 -> 0, and no locale-only follow-up lane.

**L2 `native-word-order-pass`**
- Trigger: user-facing copy in several languages (WUI, blog, help), before the GCT check.
- Does: a per-language checklist, run before the machine check: (1) word order of time and frequency phrases ("24/7"). (2) Anglicisms with a native form. (3) Quote marks, number and date formats. (4) Formal vs informal address kept the same per locale. It prints each change as `locale key: old -> new`.
- Evidence: SPL-5480 W1/W2 (German "In Produktion 24/7." in English word order; French bare "24/7"). These are not translation-meaning errors, so a back-translation check does not catch them.
- Gain: language W-lines per multilingual lane, measured as 2 in SPL-5480 -> 0. The baseline is thin (n = 1 lane); the panel may drop this one.

**L3 `e2e-no-swallowed-waits`**: see T3. It is counted once. The evidence is the i18n-kind lane SPL-5372.

### 4.6 secret (main claude, backup grok)

**K1 `secret-off-argv-and-env`**
- Trigger: a diff that passes a token, key or password to a child process, a TUI or a log.
- Does: (1) refuses a secret on argv (it is readable in `/proc/<pid>/cmdline`). Pass it by file descriptor, stdin or a 0600 file. (2) Unsets **every alias** of the variable before exec, not only the canonical name. (3) Masks the whole value after wrapping, not per line. (4) A test reads the child's `/proc/<pid>/cmdline` and `environ`.
- Evidence: `ab83fbd3` (a bearer token on curl argv), SPL-5495 (an alias of the token variable left exported in 18 actions), SPL-4810 (a masked value's tail leaks on a hard wrap).
- Gain: secret-leak findings, 3 in 45 -> 0.

**K2 `secret-teardown-on-disable`**
- Trigger: a feature that stores a credential, token file, cron line or saved option, and has an off switch.
- Does: (1) lists everything the "on" path writes. (2) A test turns the feature on, then off, and asserts that each item is gone and that nothing restarts.
- Evidence: SPL-4881, with 3 FAIL or SEND-BACK messages for the same W1 (turning the watchdog off left the token on disk and the loop restarting).
- Gain: repeat FAILs on secret lanes, 4 of 15 -> 1 or fewer.

**K3 `parse-boundary-cases`**
- Trigger: a diff that adds or changes a regex or a hand parser (bash `[[ =~ ]]`, Python `re`, Go `regexp`, jq).
- Does: (1) the regex is anchored at both ends, or carries a comment that says why not. (2) Adds table cases: prefix and suffix neighbours, digits next to words ("fourteen years" vs "4"), an empty value, quotes inside quotes, a trailing newline (`\z` vs `$`).
- Evidence: regex or parse edge cases are 4 of 45: SPL-5555 (an unanchored, shortest-first `YEARS_RX` matched "fourteen" as 4), SPL-5564, `a70feab4` (a count read as a verdict), `66fea976` (a path resolved through a symlink).
- Gain: parse findings, 4 in 45 -> 1 or fewer.

### 4.7 orchestration (main claude, backup grok)

No lane in the window carried `Kind: orchestration`: the role seats (dispatch and orch lease holders) do this work. The evidence is the lead time in 3.4. Owner rule: "orchestration = code, not intelligence", so an if-else rule belongs in code. Question O4 in section 6 therefore asks whether these three become actions instead of skills.

**O1 `plan-rows-parallel-place`**
- Trigger: a build plan gets its GO, or a plan row lands.
- Does: (1) reads the plan's rows and their paths. (2) Runs `lane-map.sh --check` on each row against the others. (3) Enqueues every row whose paths are disjoint and whose `SPAWN_AFTER` prerequisite is met, all in one sweep. (4) Prints each held row with the row it waits on.
- Evidence: SPL-6201, SPL-6203 and SPL-6207 (spec 123 rows L4, L6, L5) took 249 h to 252 h from the owner's last message to landing, while placed -> landed was about 1 h each (3.4).
- Gain: owner ask -> placed p90 for plan rows (complex_coding 34.3 h, simple_coding 128.8 h) -> under 24 h.

**O2 `owner-ask-same-sweep-enqueue`**
- Trigger: a dispatcher sweep finds an owner message that it has answered, but with no ask in the queue and no issue.
- Does: (1) when the ask is a clear order (no open question, and no panel needed by the work-process rules), drafts the brief and enqueues it in the **same** sweep. (2) Otherwise it writes the one blocking question as a poll form and marks the issue `needs-owner`. (3) It never leaves an answered owner ask with neither.
- Evidence: owner ask -> issue (placement), median 2.6 h to 22.4 h, p90 33 h to 217 h, against a queue of 0.1 h to 0.5 h (3.4). tests waits the longest (median 22.4 h, n = 41).
- Gain: median owner ask -> placed for tests 23.5 h -> under 4 h; for all kinds, under 4 h.

**O3 `brief-header-complete`**
- Trigger: before a brief is enqueued.
- Does: refuses a brief whose header lacks any of `Issue:` (or "spawn files it"), `Epic:`, `Spec:`, `Kind:` (one of the 7 cnf kinds) and `Topic:`, each in its machine-readable form.
- Evidence: 622 of 3293 briefs (all in October) have no `Kind:` line. Only 1000 carry an `Issue:` line, so 1727 lanes in this spec could be tied to their issue only by title, 65 of them ambiguously. A lane without these lines is invisible to every per-kind measurement, including this one.
- Gain: briefs with both `Kind:` and `Issue:` lines, 1000 of 3293 (30 %) -> 95 % or more.

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

- **O1. Which kinds are built first?** (A) all 7 at once; (B) the coding kinds first (tests, simple, complex: the most FAILs); (C) the shared 3 first (`failure-path-cases`, `numbered-id-claim`, `e2e-no-swallowed-waits`).
- **O2. Where do the skills live?** (A) in the repo, rendered per vendor by spool-install (claude skills, agy rules); (B) only in each agent user's home; (C) in the repo, read by the brief.
- **O3. A skill that can be checked by a script (S1, S2, T1, C3, O3)?** (A) skill plus a gate action that refuses; (B) skill only; (C) gate only.
- **O4. The orchestration three (O1-O3)?** (A) build them as `./run` actions (code), not skills; (B) skills for the role seats; (C) drop them.
- **O5. `native-word-order-pass` (thin baseline, n = 1 lane)?** (A) keep; (B) replace with the panel's next pick.
- **O6. Re-measure the gains?** (A) 30 days after landing, with Appendix A; (B) 14 days; (C) no re-measure.
- **O7. Who builds?** (A) one lane per kind, vendor from the cnf table; (B) one claude lane for all.

## 7. Limits

- This box's spawn log only. The other machine's lanes and reviews that never reached the hub are missing, so every n is a lower bound.
- The owner-ask time is the last owner message in the source topic before the issue (a lower bound on the wait).
- The issue for 1727 lanes comes from a title match; 65 were ambiguous.
- The section 3.3 classes come from one labeller on n = 45. The panel may re-label.
- The release-tag time stands for both dev and prd. `do_check_deploy_lag` gives only the current lag, not history.

## Appendix A. Commands (run 2026-11-24, read-only)

The scratch scripts that joined these sources are not part of this spec. Each step can be re-run from the commands below.

1. Kinds: `grep -n -A8 'agent_split_by_kind:' csi-spl-cnf/csi-spl/all.env.yaml`
2. Lanes: `awk -F'\t' '$2=="SPAWNED" && $1>="2026-09-24"' /var/spool-hub/spawn-remote/serve.log | wc -l` -> 3293; kind and issue from `grep -m1 -E '^(Kind|Issue):' /var/spool-hub/spawn-remote/briefs/<id>.md`
3. Commits: `git log origin/master --since=2026-09-24T00:00:00Z --format='%H%x09%aI%x09%cI%x09%s%x1e%b%x1f'` -> 10532
4. Tags: `git for-each-ref --format='%(refname:short)%09%(creatordate:iso-strict)%09%(*objectname)%(objectname)' 'refs/tags/v*'` -> 2952
5. Issues: `cd csi-spl-orc && ENV=prd SQL="select number, created_at, status, completed_at, substring(description from '/t/([0-9a-f-]{36})'), labels from issues where tenant_id='t1' and created_at>='2026-09-24' and deleted_at is null" ./run -a do_spl_db_query` -> 6354 rows
6. Issue titles (for the title match): `SQL="select number, title from issues where tenant_id='t1' and created_at>='2026-09-20' and deleted_at is null"` -> 6355 rows
7. Owner messages: `SQL="select task_id, ts from messages where tenant_id='t1' and from_id='HUM-10' and ts>='2026-09-01'"` -> 1409 rows
8. Review FAILs: `SQL="select msg_id, ts, from_id, kind, <SPL keys>, left(body,2000) from messages where tenant_id='t1' and ts>='2026-09-24' and mirror_of is null and (left(body,300) ~ 'SEND-BACK' or left(body,400) ~ '\m(R7|review|reviewer|verdict)\M.{0,80}\mFAIL\M')"` -> 1101 rows
9. Queue: `SQL="select work_kind, count(*), percentile_cont(0.5) within group (order by extract(epoch from updated_at-created_at)/3600) from fleet_asks where tenant_id='t1' and created_at>='2026-09-24' and state='done' group by 1"`
10. CI: `gh run list --workflow 10_ci-quality.yml --branch master --limit 1000 --created '>=2026-09-24' --json headSha,createdAt,conclusion` -> 1000 runs (oldest 2026-11-15T19:10Z); `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
11. Existing skills: `ls ~/.claude/skills .claude/skills csi-spl-orc/src/bash/features/spool-install/assets/*`

<!-- last-edit: 2026-11-24T12:45:00Z -->
