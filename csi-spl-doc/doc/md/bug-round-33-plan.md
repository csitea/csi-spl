# Bug-fix round 33 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6160 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `a2e5c70e-f299-41c5-bb37-eeffd41245b2` ("Bug round 33", opener msg 41d68ebb, opened by c-002@sat 06:31Z). Round 32 ([bug-round-32-plan.md](bug-round-32-plan.md) v1.0 `8955c8b29`) is still open: b32-02 landed `1fadfb77b` (SPL-6159); b32-01 (c-649@`<box2>`) is not landed. b31-02 landed `0e9efb6c2` (SPL-6150) while this plan was drafted. This round does not wait for b32-01 and stays off its files.  
Round focus: two orc defects. A docs lane placed on an issue it does not own cannot `/exit-clean` (row 01, the first row round 32 named for this round). The claude quota reader leaves a key of the live access token in a file anyone on the box can read, and on a command line (row 02).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Sections 4 and 5 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-32-plan.md](bug-round-32-plan.md) (same shape, same 5 sources).

**Status: v0.1, for the panel. No row lane starts before the panel signs a plan sha.**

Editor: **c-725@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: the b33 mistral panel seat (ask `c002-bug-round-33-mistral-panel-seat`), asked of the holder (section 8). Both rows are orc bash with no WUI file, so a mistral seat may sit (developer guide 5.1).

**One sha:** every count below is measured on **`5083f4cf9`** (`origin/master` at this seat's fetch, 07:00Z), on sat, between 07:00Z and 07:11Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated. `git diff --name-only 5083f4cf9 dc435a712` (origin/master at 07:08Z) -> `csi-spl-doc/doc/md/refactor-round-80-plan.md` only: no row file moved, and both red controls are RED on `dc435a712` too (section 3.2). At 07:15Z origin/master is `0e9efb6c2` (b31-02): `git diff --name-only 5083f4cf9 0e9efb6c2` names no row file, and rc02 is RED there (`wrong=4`).  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b32-plan')` -> `Window: W=2026-11-21T07:57:34+02:00` (commit `8955c8b29`, b32 plan v1.0), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 32. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS user the agents run as. The public repo names neither.

---

## 1. How to read this

- Round 32 measured on `8b7828a6b`. This plan reads round 32's first inputs for round 33 (its section 7), the holder's pick for row 01 (the brief, c-655 ae541e19), the holder's candidates file and the CI report. For each it says why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `5083f4cf9`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `5083f4cf9`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since round 32** | the brief's inputs; no owner word on a defect names a site since round 32's 05:36Z read | 0 | **0 rows** from new reports. Not re-queried on the hub here: the brief carries no human report. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (07:00Z..07:05Z) | wf 10: 100 runs (2026-11-20T16:26Z..2026-11-21T06:50Z): 57 success, 35 cancelled, 6 failure, 2 running. First red per job: `orc: hermetic action tests 2/4` x2 (`hub_cloudtranslate_user` not covered, 75da57eb, ad950c0e); `hub: Postgres gate` x2 (`TestTopicLoopSweepPickIndexOnly`, 2026-11-20 19:07Z); `wui: browser e2e 6/8` x1 (`workspace-doc-preamble.test.mjs`, 44832401773). Last green of every one of those jobs: 44875947658 on `f886bfcd`, 06:31Z (e2e 6/8: 44872362546 on `cd201282`, 05:45Z) | **0 rows** from a red: the same three round 32 read, green since, no new sighting. |
| **3. Skipped or disabled tests** | `git diff 8b7828a6b 5083f4cf9 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | the round 32 plan only (its text quotes `t.Skip`) | **0 rows.** |
| **4. The holder's pick (round 32 section 5, line 215)** | the brief; the hub card of SPL-6086 (`do_spl_issue_list --json`, epic SPL-2373, read only, 07:0xZ); the cards of epic SPL-2402 (24 issues) | 1 report (c-655 ae541e19), 1 card, 24 cards | **Row 01**, in the place the holder picked after the re-measure (option A, msg 08e9399f; section 3, row 01). |
| **5. Round 32's first inputs, the holder's candidates, R7 notes** | round 32 section 7 (11 inputs); the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 101 lines, its "next BUG round" and "Bug-shaped" entries) | 11 + the file's bug-shaped entries | **Row 02**: b29-01 N2 (the b29-01 R7, c-334 792c93fb), re-measured on `5083f4cf9` and on sat's live file mode. Sections 4 and 5 cover the rest. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `5083f4cf9`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b33-01-orc-enqueue-docs-lane-shared-issue)` | **A `Kind: specs_and_docs` lane placed on an issue it does not own cannot `/exit-clean`: its docs commit never closes the key, and the gate refuses a wip key with no end reason.** `li_gate` (`lane-issue.inc.sh:578-616`) passes a lane only when `li_review_lane` (`:543-555`) finds `Issue-Role: shared` in its brief, or a review heading. The enqueue reads the brief (`spl_spawn_place_brief`, `spl-spawn-enqueue.func.sh:131`), but writes nothing into it, and its one hub read of an issue is status only (`li_hub_read` -> `do_spl_issue_status`, `spl-issue-status.func.sh:30`: `issue-status <key> <status>`). | c-655 ae541e19 (04:38Z, n=1): `kill-your-self-report.sh --gate` exit 3, "issue SPL-6086 is still wip: ... no end reason"; the holder fixed it by hand 04:39Z (c-001 9e39576b). c-655's brief `c002-s143-cwv-v02-owner-answers.md:5-7`: `Issue: SPL-6086`, `Kind: specs_and_docs`, no `Issue-Role:` line. **The re-measure changed the premise:** SPL-6086 is not a discussion issue. Its card reads `- scope: the brief of lane c-259` (prd hub, read only, n=1): the placer filed it for an earlier spec lane, and c-655's brief named it. A discussion issue's card reads `- scope: the topic` plus `- Taken by: <id>` (`spl_lane_issue_discussion`, `spl-lane-issue.func.sh:501-523`). On epic SPL-2402, 6 of 24 cards read `scope: the topic`, 16 `scope: the brief`, 2 neither (SPL-6136, the b31 issue, has no marker). So the pick of round 32's line 215 (discussion keys only) would not have fired for c-655. The holder picked **A** on that measurement (msg 08e9399f, re 99869b13). | `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh:127-140` (the `[[ -n "$place" ]]` brief block of `spl_spawn_q_enqueue`), `:1-48` (header); the test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` (2294 lines, 102 `do_spl_spawn_enqueue` lines; a new case at its end); read only: `lane-issue.inc.sh:393-407` (`li_hub_read`, the `LI_HUB_STATUS_CMD` seam to twin), `:527-555` (`li_review_lane`) | `bash /var/spool-hub/dispatch/b33-red-controls/rc01.sh 5083f4cf9` (section 3.2) -> `rc01 c655: role=none gate=3 want=shared gate=0` / `rc01 disc: role=none gate=3 want=shared gate=0` / `rc01 nomark: role=none gate=3 want=shared gate=0` / `rc01 hubfail: role=none gate=3 want=none gate=3` / `rc01 coding: role=none gate=3 want=none gate=3` / `rc01 sha=5083f4cf9 wrong=3`, exit 1, n=3 (07:10Z). `RC01_PLANT=1` (the line written by hand) -> `wrong=0`: the gate half goes green once the line is there. | `spl-spawn-enqueue.func.sh` and `spl-spawn-queue.tst.sh` only. **Option A, the holder's words:** at enqueue, for a SPAWN_PLACE brief with `Kind: specs_and_docs` and an `Issue: <KEY>` line and no `Issue-Role:` line, read KEY's card once from the hub. When the card is NOT `- scope: the brief of lane <this placement's lane>`, append `Issue-Role: shared` to the brief (rc01 `c655`, `disc`, `nomark`). A discussion key, an earlier lane's key and a no-marker key all count as shared. A hub read that fails leaves the brief unchanged and logs one WARN line, never a guess (`hubfail`). Any other kind is unchanged (`coding`), and so is a brief with no `Issue:` line (the lane's test; the placer files that issue). The card read has a test seam, `LI_HUB_CARD_CMD <key>` (rc01 uses it), a twin of `LI_HUB_STATUS_CMD`. **Measured, for the lane and the panel:** the placer writes the filed key only into the lane's `lifetime/brief.md` (`spl-lane-issue.func.sh:353`), never into `dispatch/briefs/<slug>.md`. So at enqueue the brief's `Issue:` key was always filed before, and no lane exists yet whose id a card could name. On `5083f4cf9` the card test can therefore only answer "shared", and in effect A is the brief-only rule (specs_and_docs + `Issue:` -> shared). The lane keeps the card read as the holder ruled. It may drop the read only on the holder's word, recorded in its commit body. No change to `li_gate`, `li_review_lane` or the placer. The suite: rc01's five cases, `c655`/`disc`/`nomark` red on `5083f4cf9`, plus the WARN line of `hubfail` and the no-`Issue:` case. Commit body: rc01 on the fix -> exit 0, on `5083f4cf9` -> exit 1. Docs: the header's `@description` and `lane-issue-and-docs.md` say that a docs lane on a key it does not own shares it; or `Docs: none (<why>)`. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b33-02-orc-quota-token-key-private)` | **The claude quota reader keeps a key of the live access token (`a` + the first 12 hex of its sha256) in two files the box's other users can read, and passes it on the command line of the agent-user hop, visible to `ps`.** `spl_box_quota_cred_account` and `spl_box_quota_usage_fetch` derive it (`spl-box-quota.func.sh:258`, `:331`). `spl_box_quota_claude_key` writes it to `<kept file>.account` (`:308`) and puts it on `spool_agent_exec`'s argv (`:304`, `printf '%q '` of `$ak`). `spl_box_quota_usage` writes it to `<kept file>.usage` (`:377`, `:399`) and puts it on the argv (`:389`). The writes use the caller's umask, so the files are not private. | b29-01 R7 N2 (c-334@`<box2>` PASS 792c93fb on `2421505485b8`, candidates file "b29-01 N2", n=1): "a token hash at rest, against the b29 plan's data rule". Re-measured: the sites above are on `5083f4cf9` (`git show 5083f4cf9:csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh \| grep -n 'mv -f "$c.$$" "$c"'` -> `:308`, `:377`, `:399`). On sat at 07:06Z, `stat -c %a` of `<AGENT_USER>`'s `~/.local/state/csi-spl/weekly-quota-reading.tsv.account` -> `664`, and every file of that dir is `-rw-rw-r--` (`.usage` included); contents not read. The last changes to the file (SPL-6112, `7270e861f`, `164ed93f8`, `28f802950`, 2026-11-21 00:19Z..01:20Z) have landed, and no live lane lists it (section 3.1). | `csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh:280-312` (`spl_box_quota_claude_key`: the hop `:304`, the write `:308`), `:348-405` (`spl_box_quota_usage`: the writes `:377`, `:399`, the hop `:389`), `:243-266` and `:321-346` (the two fetchers: their `ATKEY` argument, read only unless the hop's argument moves to stdin); the test `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh` (the cred cases `:755-830`) | `bash /var/spool-hub/dispatch/b33-red-controls/rc02.sh 5083f4cf9` (section 3.2) -> `rc02 acctid: got=kcb23951a2432 want=kcb23951a2432` / `rc02 acctmode: got=644 want=600` / `rc02 usagemode: got=644 want=600` / `rc02 acctargv: got=1 want=0` / `rc02 usageargv: got=1 want=0` / `rc02 sha=5083f4cf9 wrong=4`, exit 1, n=3 (07:07Z) | `spl-box-quota.func.sh` and `spl-box-pick.tst.sh` only. The `.account` and `.usage` writes create their temp file with mode 600 (for example `umask 077` in the write's subshell), so the `mv` leaves the kept file 600 (`acctmode`, `usagemode`); a live 664 file becomes 600 at its next write. The access-token key no longer rides the hop's command line: it goes on the hop's stdin, or the hop prints the key and the comparison runs in the caller (`acctargv`, `usageargv`). The token itself still never leaves the fetcher, and the account key is still read and kept (`acctid`). No change to the kept reading `weekly-quota-reading.tsv`, the throttle, or the pick. The suite: rc02's five cases, four red on `5083f4cf9`. Commit body: rc02 on the fix -> exit 0, on `5083f4cf9` -> exit 1. Docs: the function comments say 600 and "never on a command line"; or `Docs: none (<why>)`. **Secret class** (the data rule): claude or grok only, and the brief names no credential path beyond the code's own. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `secret` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`. Row 02: `spl-box-quota.func.sh`, `spl-box-pick.tst.sh`. Neither sources the other (`grep -c spl-box-quota csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh` -> 0).
- **Test column (R2):**
  - Row 01: `git grep -l -E 'spl-spawn-enqueue\|do_spl_spawn_enqueue\|spl_spawn_q_enqueue' 5083f4cf9 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests` -> the tests `spl-spawn-queue.tst.sh`, `spl-spawn-after.tst.sh`, `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`, `spl-security-round-queue.tst.sh`, `spl-epic-stall-check.tst.sh`, `spl-reflection-gather.tst.sh`, `alert-issue-tick.tst.sh` (orc `src/bash/tests`), plus 4 files that are not tests (`action-header-tags-baseline.txt`, `brief-reflection.tpl.md`, `spawn-an-agent.md`, `lane-issue.inc.sh`). The gate side it feeds: `test-lane-issue.sh`, `test-lane-issue-remote-desk.sh` (`spawn-agents/tests`), `spl-lane-issue.tst.sh` (`git grep -l -E 'li_review_lane\|li_gate\b'`). Also `rc01.sh`.
  - Row 02: `git grep -l -E 'spl-box-quota\|spl_box_quota' 5083f4cf9 -- <the same dirs>` -> `spl-box-pick.tst.sh`, `rotate-weekly-first.tst.sh`, `weekly-limit-alert.tst.sh` (and `spawn-window.sh`, not a test). Also `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); b32-01's files (`spl-push-master.func.sh`, `spl-push-master.tst.sh`; c-649@`<box2>`); `lane-issue.inc.sh` and `spl-lane-issue.func.sh` (read only); the placer `spl-spawn-place.func.sh`; the hub.
- **How the files were checked (2026-11-21, sat):**
  - 07:06:48Z `lane-map.sh --check csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh,csi-spl-orc/src/bash/tests/spl-box-quota.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-enqueue.tst.sh,csi-spl-doc/doc/md/bug-round-33-plan.md --agent c-725` -> `WARN no live lane lists` them, exit 4 for 17 `<box2>` lanes that record no files (c-506, c-548, c-562, c-579, c-598, c-601, c-602, c-610, c-634, c-649, c-812, c-924, c-927 and others). 07:10:31Z the same for `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` -> the same exit 4, no lane lists it. Two of the paths in the first check do not exist (`spl-box-quota.tst.sh`, `spl-spawn-enqueue.tst.sh`): the row tests are `spl-box-pick.tst.sh` and `spl-spawn-queue.tst.sh`.
  - `<box2>` half (c-001@`<box2>` msg e9372b0a, forwarded by c-002@sat as ee62a2a4, on `dc435a712`): in each of the 26 live worktrees of its `registry.tsv`, `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched exactly against `spl-box-quota.func.sh`, `spl-box-pick.tst.sh`, `spl-spawn-enqueue.func.sh`, `spl-spawn-enqueue.tst.sh` -> **0 hits in all 26**. In the 331 worktrees not in `registry.tsv`: 2 stale hits, both retired ids with no live process (c-705, retired 11-18, branch `c-705-rotate`, touches `spl-spawn-enqueue.func.sh`; m-399, retired 10-30, touches `spl-box-pick.tst.sh`). `spl-spawn-queue.tst.sh` was not in that list (my ask named a file that does not exist). Asked again at 07:10Z, it reads **0 hits in all 26** (c-001@`<box2>` msg 1bf7b495, forwarded as dfdf6088, on `dc435a712`).
  - 07:08:17Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `13 queued, 0 placing`. The holder's R3 check (rulebook 2.3) reads the queued briefs again when the rows are queued.
- **Slug b33 is unused as a round id** (sat, 07:00:27Z, on `5083f4cf9`): `git log origin/master --since="$W" --oneline -E --grep='\(b33-'` -> 0. `git ls-remote origin 'refs/heads/review/b33-*' 'refs/heads/wip/*b33*' 'refs/heads/*-b33-*'` -> nothing. `git worktree list \| grep -E 'b33\|bug-round-33'` -> this planner's (`c-725-c002-bug-round-33-planner`), plus `c-307` whose HEAD `656ab3389` holds the hex `b338` (not a round). `ls /var/spool-hub/dispatch/briefs \| grep -E 'b33\|bug-round-33'` -> the planner's and the panel seat's briefs, 0 row briefs (1 more hit is the hex `dab3344` in another brief's name). `<box2>`'s half (msg e9372b0a): `ls /var/spool-hub/dispatch/briefs \| grep -E 'b33-[0-9]{2}\|bug-round-33'` -> no output, `git worktree list \| grep -cE 'b33-[0-9]{2}\|bug-round-33'` -> 0. **b33 is free on both boxes.**

### 3.2 Red controls run on `5083f4cf9`

The two files are on sat in `/var/spool-hub/dispatch/b33-red-controls/`. They are printed below so a seat on `<box2>` can rebuild them. `rc01.sh` is 5395 B and `rc02.sh` 3117 B (`sha256sum` first 12 hex `0d16044948a4`, `3576b3fc05ce`). Each exports `csi-spl-orc` of the sha with `git archive` (no worktree of the repo, nothing installed) and needs bash, git, tar and jq. rc01 stubs the enqueue's hub calls and runs the real `do_spl_spawn_enqueue` and `li_gate` on a temp `SPOOL_ROOT`. rc02 uses a fake credential (the token `tok-rc02-fixture`), stubbed profile and usage calls and a stub `spool_agent_exec` that records its argv. Neither reads a live queue, worktree, spool, state file or credential, and neither calls the hub or the network.

| row | command | output | who |
|---|---|---|---|
| 01 | `bash rc01.sh 5083f4cf9`, from a checkout, n=3 (07:10Z) | RED in 3 of 3, the same output each time: `rc01 c655: role=none gate=3 want=shared gate=0` / `rc01 disc: role=none gate=3 want=shared gate=0` / `rc01 nomark: role=none gate=3 want=shared gate=0` / `rc01 hubfail: role=none gate=3 want=none gate=3` / `rc01 coding: role=none gate=3 want=none gate=3` / `rc01 sha=5083f4cf9 wrong=3`, exit 1. On `dc435a712`: `wrong=3`. With `RC01_PLANT=1` (the line appended by hand on the three cases that want it): `wrong=0`, exit 0. What it shows: the enqueue leaves c-655's brief shape unshared, so the gate refuses the lane. With the line, the real gate passes it; a failed card read and a coding brief must stay as they are. | editor c-725 |
| 02 | `bash rc02.sh 5083f4cf9`, from a checkout, n=3 (07:07Z) | RED in 3 of 3, the same output each time: `rc02 acctid: got=kcb23951a2432 want=kcb23951a2432` / `rc02 acctmode: got=644 want=600` / `rc02 usagemode: got=644 want=600` / `rc02 acctargv: got=1 want=0` / `rc02 usageargv: got=1 want=0` / `rc02 sha=5083f4cf9 wrong=4`, exit 1. On `dc435a712` and `0e9efb6c2`: `wrong=4`. The fixture JSON is built with `jq --arg` and the account case is named `acctid`, so gitleaks' `generic-api-key` rule does not fire on the fixture (it did on v0.1's first draft: the pre-push `lint-gitleaks` part, 07:13Z). What it shows: under a 022 umask both kept files come out 644, and the token key is on the hop's command line both times. The account key is still read, and must stay so. | editor c-725 |

No prototype fix was written: each change belongs to its row lane, with its own red controls. There is no green control of a fix on this sha; the green half is the lane's (rc01's `RC01_PLANT=1` shows only that the gate half can go green).

rc01's card seam is named `LI_HUB_CARD_CMD`. A lane that names its seam otherwise sets that name in its copy of rc01 and says so in its commit body. `role=shared` and `gate=0` are the parts that must hold.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b33-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree of the repo), runs its do_spl_spawn_enqueue on a fixture brief
# (the hub queue op, the reply and the ask reads stubbed; no hub, no network),
# then copies the queued brief into a fake lane's lifetime/ and runs the exit
# gate li_gate on it, as /exit-clean does for c-655 (ae541e19).
# The issue card comes from LI_HUB_CARD_CMD <key> (the seam the fix adds,
# a twin of LI_HUB_STATUS_CMD); a sha without the seam ignores it.
#   c655   : c-655's brief shape (Kind: specs_and_docs, Issue: SPL-6086), card
#            "scope: the brief of lane c-259" (SPL-6086's real card) ->
#            Issue-Role: shared written, gate exit 0 (RED: unchanged, exit 3)
#   disc   : same brief, card "scope: the topic" + "Taken by:" -> shared, 0
#   nomark : same brief, a card with no scope line (SPL-6136 shape) -> shared, 0
#   hubfail: same brief, the card read fails -> brief unchanged, gate 3
#            (control; the fix also logs one WARN, asserted by the lane's test)
#   coding : Kind: simple_coding, card as c655 -> unchanged, gate 3 (control)
# RC01_PLANT=1 plays the fix by hand (appends the line where the fix would, only
# on the cases that want it): proves the gate half goes green, not a fix.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$T" || exit 2
mkdir -p "$T/spool/c-901/lifetime" "$T/briefs"
git -c init.defaultBranch=master init -q "$T/wd"
printf '#!/bin/sh\nprintf "issue-status\\t%%s\\twip\\n" "$1"\n' >"$T/status"; chmod +x "$T/status"
brief() {  # KIND ISSUE-LINE -> c-655's brief shape (c002-s143-cwv-v02-owner-answers.md:1-9)
  printf '# Lane brief: spec 143 costs-workspace-views v0.2, the owner'"'"'s four answers recorded (spec lane, docs only)\n\nEpic: SPL-2373\nSpec: csi-spl-doc/specs/143-reporting-section\n%sClass: feature\nKind: %s\nTopic: bc9956bf-1de7-494c-8644-3c5b3b3c5b4f\nDiscussion: bc9956bf-1de7-494c-8644-3c5b3b3c5b4f (owned by the dispatch holder; you post in NO topic)\n\nYou write a SPEC change, no code.\n' "$2" "$1"
}
card() {  # SCOPE-LINES -> a card script
  printf '#!/bin/sh\ncat <<EOF_C\n## Source\n/t/fcf09921-8f21-4518-a117-f8ddb41bfff5\n\n## Restart\n- key: $1\n%s- spec: csi-spl-doc/specs/123-cost-tracking\nEOF_C\n' "$1" >"$T/card"
  chmod +x "$T/card"
}
enq() {  # run do_spl_spawn_enqueue on $T/briefs/c002-rc01-x.md
  (cd "$T/csi-spl-orc" && env PROJ_PATH="$PWD" APP_PATH="$T" SPOOL_ROOT="$T/spool" ASK_ID=aaaaaaaa SPAWN_CLASS=bug \
    SPAWN_PLACE=claude:c002-rc01-x LI_HUB_CARD_CMD="$T/card" LI_HUB_STATUS_CMD="$T/status" RC_B="$T/briefs/c002-rc01-x.md" \
    bash -c 'set -uo pipefail
      do_log() { echo "$*" >&2; }
      for f in lib/bash/funcs/*.func.sh; do source "$f"; done 2>/dev/null
      source src/bash/run/spl-spawn-queue.func.sh 2>/dev/null; source src/bash/run/spl-spawn-enqueue.func.sh
      spl_spawn_q_init() { return 0; }; spl_asks_discussion_ok() { return 0; }; spl_asks_by() { echo c-002@sat; }
      spl_spawn_q_resolve() { echo aaaaaaaa-0000-4000-8000-000000000000; }; spl_spawn_q_enqueue_archived() { return 0; }
      spl_spawn_q_discussion() { return 0; }; spl_spawn_q_enqueue_links() { return 0; }
      spl_spawn_after_enqueue() { return 0; }; spl_spawn_place_brief() { echo "$RC_B"; }
      spl_spawn_q_op() { echo "{\"position\":1,\"queue_len\":1}"; }; spl_spawn_q_reply() { return 0; }
      do_spl_spawn_enqueue' >"$T/enq.log" 2>&1)
}
gate() {  # the exit gate on lane c-901 placed with the queued brief
  cp "$T/briefs/c002-rc01-x.md" "$T/spool/c-901/lifetime/brief.md"
  local k; k="$(grep -m1 -oE 'SPL-[0-9]+' <<<"$(grep -m1 '^Issue:' "$T/briefs/c002-rc01-x.md")")"
  printf '%s\n' "$k" >"$T/spool/c-901/lifetime/issue"; printf '%s\n' "$k" >"$T/spool/c-901/lifetime/origin-issue"
  (cd "$T/csi-spl-orc" && env SPOOL_ROOT="$T/spool" LI_HUB_STATUS_CMD="$T/status" bash -c 'set -uo pipefail
    do_log() { :; }; for f in lib/bash/funcs/*.func.sh; do source "$f"; done 2>/dev/null
    . src/bash/features/spawn-agents/lib/lane-issue.inc.sh; li_gate "$SPOOL_ROOT" c-901 "$1"' _ "$T/wd" >/dev/null 2>&1)
  echo $?
}
bad=0
chk() {  # NAME KIND ISSUE-LINE CARD-SCOPE(or FAIL) WANT-ROLE(shared|none) WANT-GATE(0|3|-)
  local role g
  brief "$2" "$3" >"$T/briefs/c002-rc01-x.md"
  if [[ "$4" == FAIL ]]; then printf '#!/bin/sh\nexit 1\n' >"$T/card"; chmod +x "$T/card"; else card "$4"; fi
  enq
  grep -q '^OK ask' "$T/enq.log" || echo "rc01 $1: enqueue did not finish: $(tail -1 "$T/enq.log")"
  [[ "${RC01_PLANT:-0}" == 1 && "$5" == shared ]] && printf 'Issue-Role: shared\n' >>"$T/briefs/c002-rc01-x.md"
  role=none; grep -qiE '^Issue-Role:[ ]*shared' "$T/briefs/c002-rc01-x.md" && role=shared
  g=-; [[ "$6" == - ]] || g="$(gate)"
  echo "rc01 $1: role=$role gate=$g want=$5 gate=$6"
  [[ "$role" == "$5" && "$g" == "$6" ]] || bad=$((bad + 1))
}
I=$'Issue: SPL-6086\n'
chk c655    specs_and_docs "$I" $'- scope: the brief of lane c-259\n' shared 0
chk disc    specs_and_docs "$I" $'- scope: the topic\n- Taken by: c-002\n' shared 0
chk nomark  specs_and_docs "$I" '' shared 0
chk hubfail specs_and_docs "$I" FAIL none 3
chk coding  simple_coding  "$I" $'- scope: the brief of lane c-259\n' none 3
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b33-02 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree of the repo), sources its lib/bash/funcs/spl-box-quota.func.sh and
# runs the two claude readers on a fixture: a temp LANE_QUOTA_STATE, a fake
# credential (token "tok-rc02-fixture", not a real one), stubbed profile and
# usage calls, and a stub spool_agent_exec that records its argv. No network,
# no real credential, no live state file.
#   acctmode : spl_box_quota_claude_key writes <kept>.account -> mode 600
#              (RED when 644/664: sat's live file is 664, b29-01 N2)
#   usagemode: spl_box_quota_usage writes <kept>.usage -> mode 600 (RED: 644)
#   acctargv : the agent-user hop of spl_box_quota_claude_key -> the argv
#              holds no access-token key (RED: the kept "a<12 hex>" is on it)
#   usageargv: the agent-user hop of spl_box_quota_usage -> no key on the argv
#   acctid  : the account key is still read and kept (control: "k<12 hex>")
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$T" || exit 2
jq -n --arg t tok-rc02-fixture '{claudeAiOauth: {accessToken: $t}}' >"$T/cred.json"
printf '#!/bin/sh\ncat >/dev/null; echo %s\n' "'{\"account\":{\"uuid\":\"u-rc02\"}}'" >"$T/profile"
printf '#!/bin/sh\ncat >/dev/null; echo %s; echo "200 -"\n' "'{\"seven_day\":{\"utilization\":10,\"resets_at\":\"2099-01-01T00:00:00Z\"}}'" >"$T/usage"
chmod +x "$T/profile" "$T/usage"
AK="a$(printf '%s' tok-rc02-fixture | sha256sum | cut -c1-12)"
q() {  # FUNC [env...] -> runs FUNC under umask 022 in the exported tree
  local fn="$1"; shift
  (cd "$T/csi-spl-orc" && umask 022 && env -u LANE_PANES_CMD -u LANE_QUOTA_CMD LANE_QUOTA_STATE="$T/kept.tsv" \
    LANE_QUOTA_CLAUDE_PROFILE_HOST=profile.invalid SPOOL_AGENT_USER=rc02 RC_T="$T" RC_AK="$AK" "$@" bash -c 'set -uo pipefail
      do_log() { :; }
      source lib/bash/funcs/spl-box-quota.func.sh 2>/dev/null
      spool_agent_exec() { printf "%s\n" "$*" >"$RC_T/argv"; echo "$RC_AK k000000000000 200 - 10@4070908800"; }
      '"$fn" 2>/dev/null)
}
bad=0
chk() {  # NAME WANT GOT
  echo "rc02 $1: got=${3:-none} want=$2"
  [[ "${3:-none}" == "$2" ]] || bad=$((bad + 1))
}
mode() { stat -c %a "$1" 2>/dev/null || echo none; }
key="$(q spl_box_quota_claude_key LANE_QUOTA_CLAUDE_CRED="$T/cred.json" LANE_QUOTA_CLAUDE_PROFILE_CMD="$T/profile")"
chk acctid "k$(printf '%s' u-rc02 | sha256sum | cut -c1-12)" "$key"
chk acctmode 600 "$(mode "$T/kept.tsv.account")"
q spl_box_quota_usage LANE_QUOTA_CLAUDE_CRED="$T/cred.json" LANE_QUOTA_CLAUDE_USAGE_CMD="$T/usage" >/dev/null
chk usagemode 600 "$(mode "$T/kept.tsv.usage")"
rm -f "$T/argv"; q spl_box_quota_claude_key >/dev/null
chk acctargv 0 "$(grep -c -- "$AK" "$T/argv" 2>/dev/null || echo none)"
rm -f "$T/argv" "$T/kept.tsv.usage"; printf '1 0 0 %s -\n' "$AK" >"$T/kept.tsv.usage"
q spl_box_quota_usage >/dev/null
chk usageargv 0 "$(grep -c -- "$AK" "$T/argv" 2>/dev/null || echo none)"
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 32's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b32-01, b32-02 | `git log origin/master --oneline -E --grep='\(b32-0[12]-'` | b32-02 landed `1fadfb77b`; b32-01 none | b32-02 is served. b32-01 is live (c-649@`<box2>`), so it is off limits (R3). |
| c-655's exit gate on a discussion issue | section 3 | the holder picked A (msg 08e9399f) on the re-measure | **Row 01.** |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | not re-read: b31-02 (the done-claim check) was live on its files at the read, and landed `0e9efb6c2` at 07:1xZ | - | **Not a row**: no alert read since b31-02 landed. Carried. |
| The AltGr picker; the blog switcher's Enter | source 1 | no owner word | **No rule it breaks and no owner word.** Carried. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` and as `<PUSH_USER>` on `5083f4cf9`, 07:03Z..07:05Z: `bash csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` (the candidates file's "section 12 ... want 3" report, c-973 fecf24d8) -> `unanswered-sweep: all passed`, rc 0, as both users | not red (n=1 each user) | **Not reproduced**, as in rounds 27 to 32. |
| `gcp-billing-invoices.tst.sh` `download iframe`; `workspace-doc-preamble.test.mjs` at their 3rd sightings | source 2 | 0 and 1 (the same run 44832401773 round 32 counted) in 100 runs | **Not a row**: no new sighting. |
| The `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms | not re-queried here | - | **Not a row.** Carried. |
| b29-01 N1 on `<box2>` (the profile account across a renewal) | not read here: `<box2>` | no `differs` reported | **Not a row.** Carried. |
| The overlay mount that outlives its `/tmp` worktree | as round 32: its red control needs a mount, which needs root | - | **Not a row this round.** Carried. |
| `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on | `WT_SWEEP_TMP_ROOT` still off | not observable | **Not a row.** Carried. |
| The lease vendor order writer once named | sat, 07:06Z: `grep -n LEASE_VENDOR_ORDER /var/spool-hub/dispatch/lease.conf` -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2` (no grok); the file's last write 04:35Z, after the 02:35Z hand fix | not reverted on sat since | **Not a row.** No writer named. Carried. |

---

## 5. The holder's candidates and other reports, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **The topic loop's hourly cap: two fires at once both pass the count** (SPL-6032 R7 N2, c-297) | `csi-spl-api/src/go/spool-hub-api/internal/hub/topic_loop_fire.go:416` calls `CountTopicLoopFire`; `store/topic_loop_postgres.go:180-194` counts and checks in one `UPDATE ... WHERE ... fires_in_hour < $4 ... RETURNING` (since `99a2f0255`); `store/topic_loop_memory.go:172-173` holds `s.mu` across it. The R1 hold (c-342, SPL-6105) has landed: `4c5633d84`. | **Not a row**: the count and the increment are one statement under the row lock, so a 2nd fire re-reads the raised count. No race on this tree. The untested `!inserted` branch (N1) is test-shaped, for a refactor or test round. |
| **The review-go GO retried to a retired author; the re-PASS on a landed sha ("found locally only") and its loop** | `git log origin/master --format='%h %s' -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` | **Served**: `2f634fbd4` (b20-01), `656ab3389` (b27-01). |
| **The review notice's `Author:` in a never clause** (c-001 364398a4) | `git log origin/master --grep='b22-02'` | **Served**: `3e46a758c` (b22-02). |
| **The panel-seat UI swap, its `-panel-seat-<vendor>` and `-<digits>` suffixes** | `git log origin/master --grep='panel-seat'` | **Served**: `21abdb87e` (b27-02), `2547249ec` (b28-01), `ae4898ae1` (b29-02). |
| **The kept weekly reading across a credential copy; the CI-first rule** | `git log origin/master --grep='b29-01\|b30-01'` | **Served**: `ac367b7a5` (b29-01), `9b680e7b5` (b30-01). |
| **The done-claim sha256 prefix** (c-001 95722c63) | `git log origin/master --oneline -E --grep='\(b31-02-'` | **Served**: `0e9efb6c2` (b31-02). |
| **The customer box role check's ban-list limits** (spec 181 B6, c-502 N1-N4) | `3f33e9dab` (SPL-6122, "R7 c-502 W1-W5") | **Not a row this round**: spec 181's lanes own the file, and its fix of W1-W5 landed after the notes; whether N1-N3 still pass on it is the spec lane's to read (R3). |
| **The blog switcher e2e `blog.test.mjs:329` alone** (SPL-5960 R7 N3) | not re-run: a WUI e2e needs the generated bundle and Chrome, and a WUI row could not take the mistral seat | **Not a row this round.** Carried. |
| **Test, refactor and doc notes** (b30-01 N1, the `ws-docs-head.mjs` click, the spec 181 and B5 notes, SPL-6107 N1, Rows A and B of the reflection, the literal-path notes) | as rounds 31 and 32 | **Not bugs this round**, as round 32 reads them; spec 181's stay with its lanes (R3). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file (lane map 07:06:48Z and 07:10:31Z, queue 07:08:17Z); the 26 live `<box2>` worktrees: 0 hits for all four row files (msgs e9372b0a, 1bf7b495). |
| b32-01 (the push-master seat review-only) | c-649@`<box2>` | Not landed; its files are off limits. |
| Row 01's card read, if the lane finds it can only answer "shared" | the holder | Measured in row 01: the lane drops the read only on the holder's word. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 11 round 32 inputs, the holder's pick and its card (SPL-6086), 24 cards of epic SPL-2402; 100 CI runs; the candidates file's bug-shaped entries (5 served, 1 live, 1 not a race, 1 carried WUI e2e, spec 181 notes with their lanes); 2 red controls (n=3 each); 1 suite run as both OS users; sat's `lease.conf` and quota state dir |
| first inputs for round 34 | the done-claim `job` label, now b31-02 has landed, if it alerts alone; the AltGr picker and the blog switcher's Enter if a rule or the owner says how they must pick; `blog.test.mjs:329` alone, re-run on a bundle; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` and `workspace-doc-preamble.test.mjs` at their 3rd sightings; the `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms if printed again; b29-01 N1 on `<box2>` if it reads `differs`; the overlay mount that outlives its `/tmp` worktree; `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on; the lease vendor order writer once named; the topic loop's `!inserted` branch (test-shaped) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-725@sat (claude, `specs_and_docs`).
- **Panel:** the b33 mistral panel seat (ask `c002-bug-round-33-mistral-panel-seat`), asked of the holder with v0.1. Both rows are orc bash with no WUI file, so a mistral seat may sit (developer guide 5.1). It reviews the plan only; it writes no row code. Until b32-01 lands, the seat must push with `PUSH_BRANCH=review/c002-bug-round-33-mistral-seat`.
- **Asked of the holder, answered:**
  1. Row 01's place (msg 99869b13): **A** (msg 08e9399f).
  2. The `<box2>` half of R3 and of the slug (msg 99869b13): 0 hits in 26 live worktrees, b33 free (c-001@`<box2>` e9372b0a, forwarded as ee62a2a4).
  3. `spl-spawn-queue.tst.sh` in the same 26 `<box2>` worktrees (07:10Z): 0 hits (c-001@`<box2>` 1bf7b495, forwarded as dfdf6088).
- **Row reviewer (R7):** rows 01 and 02: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (07:10:39Z) -> `pick=hold reason=waiting: grok weekly >= 95% or unknown on sat, <box2> [sat unknown (no reading); <box2> unknown (no reading)]: queue the lane, spawn nothing`. No row has a mistral backup: row 01 is a coding kind (`simple_coding`) and row 02 is `secret`, and mistral takes neither, as main or backup. An absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 07:1xZ: v0.1, pushed to `review/c002-bug-round-33-planner` for the panel.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-725@sat | v0.1 |
| Panel | the b33 mistral panel seat | asked |
