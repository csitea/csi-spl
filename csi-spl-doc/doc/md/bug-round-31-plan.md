# Bug-fix round 31 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6136 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `01a9d000-c948-43b6-ac55-45f3fae3e9b6` ("Bug round 31", opener msg fc14bd86, opened by c-002@sat 03:39Z). Round 30 ([bug-round-30-plan.md](bug-round-30-plan.md) v1.0 `b67431a30`, 3 rows) is served: b30-01 `9b680e7b5` (SPL-6125), b30-02 `b341f7bb8` + `82d1b51da` (SPL-6128), b30-03 `6f2a343bb` + `252de9ad2` (SPL-6129); close record `0eb0ea462` (Closes: SPL-6108). Bug share at queue time: 2 of 18 known live lanes, 11% (band 30-40%: under).  
Round focus: two orc defects where a check gives a wrong answer on real input. The R7 review notice skips a live author on the other box when the brief's `Author:` line names it bare (row 01). The done-claim check reads a quoted sha256 as a git sha when a word stands between the label and the hash (row 02).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`. Sections 2, 4, 5 and 6 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-30-plan.md](bug-round-30-plan.md) (same shape, same 5 sources).

**Status: v0.3, for the panel's delta read (section 8). The panel passed v0.1 `a370b5786` with no W (m-642@sat, msg 6fc73e6c). v0.2 `78c13231e` added the `<box2>` halves; v0.3 adds the PASS and N4. No row changed.**

Editor: **c-651@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: m-642@sat (mistral, the b31 panel seat, ask `c002-bug-round-31-mistral-panel-seat`): **PASS** on v0.1 `a370b5786` (msg 6fc73e6c, seat file `e380f83fd` on `review/c002-bug-round-31-mistral-seat`), no W, N1-N4 (section 8).

**One sha:** every count below is measured on **`325a47c76`** (`origin/master` at this seat's fetch of 04:13Z), on sat, between 03:58Z and 04:18Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated. The worktree sits on `325a47c76` itself. The red controls were first run on `4a1c86baa` (04:11Z), then re-run on `325a47c76`: `git diff --stat 4a1c86baa 325a47c76 -- csi-spl-orc` is empty.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b30-plan')` -> `Window: W=2026-11-21T04:35:42+01:00` (commit `0eb0ea462`, the b30 close record), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 30. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS user the agents run as. The public repo names neither.

---

## 1. How to read this

- Round 30 measured on `4ad1b80a8`. This plan re-measures what changed since then. `git rev-list --count 0eb0ea462..325a47c76` -> 5 commits, and `git rev-list --count --since="$W" 325a47c76` -> 6. It reads round 30's first inputs for round 31 (its section 7), the holder's candidates file, the R7 N notes of b30-01, b30-02 and b30-03, and c-001's two done-claim notes, and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `325a47c76`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `325a47c76`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since round 30** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%'), count(*) filter (where body ~* '(altgr\|enter\|picker\|switcher\|kind pick)') from messages where ts > '2026-11-21T00:57:47Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (04:15:41Z) | t1: 18 posts, 0 with a bug word, 18 `[spool-probe]`, 0 picker / switcher words; no other tenant | **0 rows** from new reports. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 03:58Z) | wf 10: 100 runs (2026-11-20T13:41Z..2026-11-21T04:04Z): 58 success, 35 cancelled, 5 failure, 2 running. First red per job: `orc: hermetic action tests 2/4` x2 (44861302816 on `ad950c0e8`, 44862745983 on `75da57eb4`: `FAIL: dev: resources not covered: google_project_iam_member.hub_cloudtranslate_user`); `hub: Postgres gate` x2 (`TestTopicLoopSweepPickIndexOnly`, 18:45Z and 19:07Z, the runs round 30 read); `wui: browser e2e 6/8` x1 (`workspace-doc-preamble.test.mjs`, 44832401773, the run round 30 read) | **0 rows** from a red. The orc 2/4 red is SPL-6132's (spec 123 L0), fixed by `4a1c86baa` (`fix(orc, SPL-6132): tf-030 importer covers ...`, the trunk head at the report), whose CI was still to run at 04:04Z. The pg red has been green since 19:2xZ (spec 182, as round 30 says). `workspace-doc-preamble.test.mjs`: still 1 sighting, no 2nd. `grep -c agent-name-shape <the report>` -> 0; `grep -c 'download iframe' <the report>` -> 0. |
| **3. Skipped or disabled tests** | `git diff 4ad1b80a8 325a47c76 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `csi-spl-doc/doc/md/bug-round-30-plan.md` (its text quotes `t.Skip`) | **0 rows.** No test file was skipped. |
| **4. Box automation logs** | sat: `/var/spool-hub/dispatch/automation.log`, the `review-notify` lines since 2026-11-20T16:56Z: `awk '$1 >= "2026-11-20T16:56" && $2 == "review-notify"' \| grep -oE 'action=[a-z-]+' \| sort \| uniq -c`; the placer log `/var/csi/csi-spl/spawn-place/cron.out`: `grep -nE 'SKIP: author\|author\(s\) told'` | 44 author lines and 2 `no-author`: 30 `sent` (23 to `<box2>`, 7 to sat), **12 `skip-retired`**; each skip is to `<id>@sat`. cron.out: 6 `INFO SKIP: author <id> already retired` lines, each followed by `0 of 1 author(s) told` (lines 143550 to 147473) | **Row 01.** Each of the 12 skipped briefs has a line-start `Author: <bare id>`, and 10 of them name `<id>@<box2>` elsewhere in their text (section 3, row 01). |
| **5. Round 30's first inputs, the holder's candidates, the R7 notes, the done-claim notes** | round 30 section 7; the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 99 lines, its "next BUG round" and "Bug-shaped" entries); the R7 PASS messages of c-504, c-529 (two) and c-531 (two) on the b30 rows (sat spool archive, msgs a728a1de, 298a5b95, e98cd4d3, 022a9ae3, e442c7fb); c-001's done-claim notes 003e85a2 and 8d349075 (task 88dcee25) | 11 + 22 + 8 + 2 inputs | **2 rows.** Row 01 comes from the candidates file's 01:2xZ entry (c-001 7e965718), which source 4 re-measured. Row 02 comes from the done-claim note 003e85a2 (c-513's result e1221e85). Sections 4 and 5 cover the rest. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `325a47c76`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b31-01-orc-review-notify-bare-author-box)` | **The R7 review notice skips a live author on the other box when the brief's `Author:` line names it bare.** `spl_review_notify_authors` (`spl-spawn-review-notify.func.sh:114`) reads only the line-start `Author:` lines once a brief has one (`:120`, b22-02), and prints the box those lines carry, else none (`:128`). The caller then routes a bare id to this box (`:78`, `${abox:-$box}`; header `:21-22`, "else this box"). `spl_review_notify_one` (`:153`) checks it against this box's registry, where ids are reused across boxes. A retired local lane of the same id gives `SKIP: author <id> already retired`, and the live author on the other box is never told that its reviewer started (spec 157 Rule 3, row B6). | c-001 7e965718 (candidates file 01:2xZ, n=1: the r78-01 R7 c-471@`<box2>` skipped c-442, live on `<box2>`). Re-measured on sat, 04:0xZ (source 4): **12 of 44** author lines since 2026-11-20T16:56Z are `skip-retired`. The skipped authors are c-193, c-199, c-201, c-098 (twice), c-259, c-342, c-345, c-444, c-420, c-442 and c-548. Each brief (`/var/spool-hub/dispatch/briefs/<brief>.md`, `grep -nE '^[[:space:]]*Author:'` and `grep -noE '<id>(@[a-z0-9]+)?'`) has `Author: <id>` with no box on line 7, 8 or 9. 10 of the 12 name `<id>@<box2>` on 1 to 3 other lines; c-199's and c-201's (both s123 rows) name no box at all. c-548@`<box2>` is a live lane today (this round's brief, R3 list), so its reviewer a-565@`<box2>` (03:54:23Z) told nobody. | `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh:114-130` (`spl_review_notify_authors`), `:78` (the caller's `${abox:-$box}`), `:21-27` (header item 2); the test `csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh` (its header `:13-23`, section 3 `:104-111` and section 6, the Author line forms); read only: `spl_review_notify_one` `:150-170`, `spl_review_notify_state` `:136-145` | `bash /var/spool-hub/dispatch/b31-red-controls/rc01.sh 325a47c76` (section 3.2) -> `rc01 far: SKIP: author c-442 already retired want=-> c-442@box-b` / `rc01 here: PLAN note c-001 -> c-443@box-a want=-> c-443@box-a` / `rc01 explicit: PLAN note c-001 -> c-444@box-b want=-> c-444@box-b` / `rc01 gone: SKIP: author c-445 already retired want=SKIP: author c-445 already retired` / `rc01 sha=325a47c76 wrong=1`, exit 1, n=3 (04:17Z) | `spl-spawn-review-notify.func.sh` and `spl-spawn-review-notify.tst.sh` only. A bare id from an `Author:` line (or phrase) takes its box from the brief itself: the box of `<id>@<box>` where the same id is written with a box elsewhere in the brief, when every such mention names one box. With no such mention, or with two different boxes named, the id stays bare and is routed and checked as today (rc01's `here` and `gone` controls; c-199's and c-201's briefs stay skipped, so this row fixes 10 of the 12). An explicit `Author: <id>@<box>` is unchanged (`explicit`). The other box's relay (`spool-send.sh --to <id>@<box>`) still refuses an id that box does not know (header `:26-27`). No hub call is added. The suite: rc01's four cases, `far` red on `325a47c76`. Commit body: rc01 on the fix -> exit 0 (`wrong=0`), on `325a47c76` -> exit 1. The header's item 2 says where a bare author's box comes from. Docs: the header, or `Docs: none (<why>)`. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b31-02-orc-done-claim-sha256-prefix-words)` | **The done-claim check reads a quoted sha256 as a git sha when a word stands between the label and the hash.** The rule (header `:19-22`, SPL-2332 / SPL-5990, and [done-claim-check.md](done-claim-check.md) item 2 `:27-31`): a token after an `md5` / `sha1` .. `sha512` label, with or without `sum`, is a file hash, not a sha. `spl_done_claim_tokens` (`spl-done-claim-check.func.sh:356`) cuts it with one `sed` expression (`:358`) that allows only non-alphanumerics between the label and the hex (`(sum)?[^0-9a-zA-Z]+[0-9a-fA-F]+`). "sha256 prefix `<hex>`" and "`sha256sum` first 12 hex `<hex>`" keep the hash. It is no object in any repo, has a letter, and is kept (`spl_done_claim_commits`, `:380`), so the result alerts `not an object in any repository (a pre-rebase sha?)` (`:963`). | c-001's note 003e85a2 (03:30:07Z, task 88dcee25): c-513@`<box2>`'s result e1221e85 (02:31:13Z, kind `result`, b30-03 "ready for R7") read "rc03.sh sha256 prefix `da931bbcc8d4`". `da931bbcc8d4` is rc03.sh's sha256 prefix (bug-round-30-plan.md 3.2), not a sha. Sat's spool archive since 2026-11-18, `kind result` messages: `grep -ohiE 'sha-?256(sum)?[^0-9a-f`]{0,3}[a-z][a-z0-9 ]{1,30}`?[0-9a-f]{9,12}`?'` -> 3 hits with a word before the hash. Two are `sha256 prefix` + hash, from 2 distinct results (`da931bbcc8d4` twice, the same text in two inboxes, and `bba8a88e57e6`). The third is the control form `sha256sum and git diff 5e137db43 ...`, where the hex IS a git sha. The plans quote the other form themselves ("`sha256sum` first 12 hex `a366e7466e55`", bug-round-30-plan.md 3.2). | `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh:356-363` (`spl_done_claim_tokens`, its `sed` line `:358`), `:342-354` (its comment), `:19-22` (header); the test `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` (case `sha256`, its message `:130`, the verdict list `:163-164` and the check `:173-174`, 2b2. SPL-5990); doc `csi-spl-doc/doc/md/done-claim-check.md:27-31` (item 2); read only: `spl_done_claim_commits` `:369-382`, `spl_done_claim_note` `:954-971` | `bash /var/spool-hub/dispatch/b31-red-controls/rc02.sh 325a47c76` (section 3.2) -> `rc02 prefix: tokens='da931bbcc8d4' want=''` / `rc02 first12: tokens='a366e7466e55' want=''` / `rc02 label: tokens='' want=''` / `rc02 gitsha: tokens='9b680e7b5' want='9b680e7b5'` / `rc02 diff: tokens='cc13eac0b 5e137db43' want='cc13eac0b 5e137db43'` / `rc02 sha=325a47c76 wrong=2`, exit 1, n=3 (04:17Z) | `spl-done-claim-check.func.sh`, `spl-done-claim-check.tst.sh` and `done-claim-check.md` item 2 only. The label cut of `:358` also takes the hex token after a sha / md5 label followed by a short run of hash-describing words: `prefix`, `first`, `last`, a count, `hex`, `chars`, `digits` (the forms seen: "sha256 prefix `<hex>`", "sha256sum first 12 hex `<hex>`"). Any other word ends the label: "sha256(git diff `<sha>` `<sha>`)" still names both git shas (rc02's `diff` control), and so does a bare `sha` label (SPL-5990). The suite: rc02's five cases, `prefix` and `first12` red on `325a47c76`, added to the `sha256` case (`:130`), whose verdict stays `landed`. Commit body: rc02 on the fix -> exit 0, on `325a47c76` -> exit 1. Docs: done-claim-check.md item 2 names the two forms. | sat or `<box2>` (no pin) | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-spawn-review-notify.func.sh`, `spl-spawn-review-notify.tst.sh`. Row 02: `spl-done-claim-check.func.sh`, `spl-done-claim-check.tst.sh`, `csi-spl-doc/doc/md/done-claim-check.md`. Neither sources the other.
- **Test column (R2):**
  - Row 01: `git grep -l -E 'spl-spawn-review-notify\|spl_review_notify\|do_spl_spawn_review_notify' 325a47c76 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests` -> `spl-spawn-review-notify.tst.sh` (and `orc-shard-weights.txt`, a list, not a test); and `rc01.sh`.
  - Row 02: `git grep -l -E 'spl_done_claim_tokens\|spl-done-claim-check\|do_spl_done_claim_check' 325a47c76 -- <the same dirs>` -> `spl-done-claim-check.tst.sh` (and `orc-shard-weights.txt`); and `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `spool-send.sh` and the relay; `spl-spawn-place.func.sh` (the placer's hook `spl_review_notify_placed` is read only); the hub. Row 01 adds no hub call.
- **How the files were checked (2026-11-21, sat):**
  - 04:13:10Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/doc/md/bug-round-31-plan.md --agent c-651` -> `WARN no live lane lists` them. It exits 4 for 14 `<box2>` lanes that record no files: c-292 (spec 181 B1), c-461 (spec 123 P05), c-490 (spec 033 T025+T027), c-538 (spec 123 L1), and the rotation branches of c-146, c-324, c-463, c-506, c-509, c-535, c-540, c-812, c-924 and c-927. v0.1 listed 13 of them: the output it read was cut by a `tail`, which hid c-146. `done-claim-check.md` was not in that call.
  - `<box2>` half (c-001@`<box2>` msg 977706b2, 04:2xZ, after a fresh fetch, read only): in each of the 13 worktrees v0.1 named, `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths were checked against the five row files (the four code and test files and `done-claim-check.md`) -> **0 hits in every lane**. Each lane's only dirty path is its own `.c-<id>-handoff.md` (c-924 also has `.playwright-mcp/`). A grep for `spawn-review-notify\|done-claim-check` anywhere in those paths -> 0.
  - 04:26:32Z, the same check re-run with `done-claim-check.md` and this plan added -> `WARN no live lane lists` them; exit 4 for 13 `<box2>` lanes. c-540 is gone, and **c-146** (`c-146-rotate`, a rotation branch) was read on `<box2>` too (c-001@`<box2>` msg cfdfc6ed, against `325a47c76`): HEAD `cee05b58d`, `git diff --name-only origin/master...HEAD` -> no paths, the only dirty path `?? .c-146-handoff.md` -> **0 hits**. All 14 exit-4 lanes have now been checked, and none touches a row file.
  - 04:14:53Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `22 queued, 0 placing`. The 22 placements' briefs (`/var/spool-hub/dispatch/briefs/<slug>.md`, all 22 present) were read with `grep -lE 'review-notify\|done-claim'` -> 0 hits.
  - `git log origin/master --since=2026-11-19 -- <the four code and test files>` -> `f136d78da` (SPL-6074), `a6f5a723d` (b23-02, SPL-5990) and `3e46a758c` (b22-02, SPL-5976). All three have landed and their issues are closed. `git worktree list \| grep -iE 'review-notify\|done-claim'` -> 1, `c-457-c003-spl6074-done-claim-src-tag-claude-waiver-reviewer`: SPL-6074's R7 seat, retired (no `registry.tsv` row, no spool dir), its tree clean. The refactor round 79 plan names none of the row files (`grep -nE 'review-notify\|done-claim' refactor-round-79-plan.md` -> 0). perf-round-17-plan.md names `spl-spawn-review-notify.func.sh` once (`:200`); perf round 17 is closed and round 18's plan names neither file.
- **Slug b31 is unused as a round id** (sat, 03:5xZ, on `4a1c86baa`): `git log origin/master --since="$W" --oneline -E --grep='\(b31-'` -> 0. `git ls-remote origin 'refs/heads/review/b31-*' 'refs/heads/wip/*b31*' 'refs/heads/*-b31-*'` -> nothing. `git worktree list \| grep -E 'b31\|bug-round-31'` -> 2: this planner's (`c-651-c002-bug-round-31-planner`) and its mistral panel seat's (`m-642-c002-bug-round-31-mistral-panel-seat`), 0 row worktrees. `ls /var/spool-hub/dispatch/briefs \| grep -E 'b31\|bug-round-31'` -> the planner's and the panel seat's briefs, 0 row briefs (a third hit, `hand-<box2>-c002-agy-memory-allowlist-fill-5471b31d.md`, is a hex id, not a round). `<box2>`'s half (c-001@`<box2>` msg 977706b2): `grep -lE 'b31-[0-9]{2}\|bug-round-31' /var/spool-hub/dispatch/briefs/*` -> 1 file, a false positive (`5b31` inside a task uuid of a brief from 2026-10-26), so 0 b31 briefs; `git worktree list \| grep -cE 'b31-[0-9]{2}\|bug-round-31'` -> 0. **b31 is free on both boxes.**

### 3.2 Red controls run on `325a47c76`

The two files are on sat in `/var/spool-hub/dispatch/b31-red-controls/`. They are printed below so a seat on `<box2>` can rebuild them. `rc01.sh` is 2790 B and `rc02.sh` 2049 B (`sha256sum` first 12 hex `d65e368447bd`, `32f36e2b021f`). Each exports `csi-spl-orc` of the sha with `git archive` (no worktree, nothing installed) and needs bash, git and tar. rc01 builds its own spool and briefs in a temp dir and runs the action as a dry run, so nothing is sent. rc02 feeds one line per case to the token reader. Neither reads a live queue, worktree, spool or credential.

| row | command | output on `325a47c76` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 325a47c76`, from a checkout, n=3 (04:17Z; also n=3 on `4a1c86baa`, 04:12Z) | RED in 3 of 3, the same output each time: `rc01 far: SKIP: author c-442 already retired want=-> c-442@box-b` / `rc01 here: PLAN note c-001 -> c-443@box-a want=-> c-443@box-a` / `rc01 explicit: PLAN note c-001 -> c-444@box-b want=-> c-444@box-b` / `rc01 gone: SKIP: author c-445 already retired want=SKIP: author c-445 already retired` / `rc01 sha=325a47c76 wrong=1`, exit 1. What it shows: the brief names `c-442@box-b`, yet the bare `Author: c-442` is judged by box-a's retired c-442 and skipped. A live local author, an explicit box, and a retired id with no box named anywhere all come out right, and must stay so. | editor c-651 |
| 02 | `bash rc02.sh 325a47c76`, from a checkout, n=3 (04:17Z; also n=3 on `4a1c86baa`, 04:12Z) | RED in 3 of 3, the same output each time: `rc02 prefix: tokens='da931bbcc8d4' want=''` / `rc02 first12: tokens='a366e7466e55' want=''` / `rc02 label: tokens='' want=''` / `rc02 gitsha: tokens='9b680e7b5' want='9b680e7b5'` / `rc02 diff: tokens='cc13eac0b 5e137db43' want='cc13eac0b 5e137db43'` / `rc02 sha=325a47c76 wrong=2`, exit 1. What it shows: a word between a sha256 label and its hash keeps the hash as a sha. The plain label (SPL-5990), a real git sha, and the git shas inside "sha256(git diff ...)" come out right, and must stay so. | editor c-651 |

No prototype fix was written: each change belongs to its row lane, with its own red controls. There is no green control on this sha; the green half is the lane's.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b31-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree) and runs its do_spl_spawn_review_notify as a DRY RUN on a
# fixture spool (box-a = this box). A brief's line-start `Author: <id>` names
# the id bare; the same brief names `<id>@box-b` elsewhere (the shape of all
# 12 skip-retired briefs on sat, 2026-11-20 16:56Z .. 2026-11-21 03:54Z).
#   far     : Author: c-442, c-442 retired on box-a, brief names c-442@box-b
#             -> must be planned to c-442@box-b (RED when SKIP)
#   here    : Author: c-443, c-443 live on box-a, brief names no box
#             -> planned to c-443@box-a (control)
#   explicit: Author: c-444@box-b -> planned to c-444@box-b (control)
#   gone    : Author: c-445, retired on box-a, no box named anywhere
#             -> SKIP already retired (control: no guess)
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
S="$C/spool"; mkdir -p "$S/dispatch/briefs" "$S/c-443"
printf 'c-443\tclaude\t%%1\t/w/c-443\t20261121T000000Z\t-\n' >"$S/registry.tsv"
printf 'c-442\tclaude\t%%2\t/w/c-442\t20261120T000000Z\t20261120T010000Z\nc-445\tclaude\t%%3\t/w/c-445\t20261120T000000Z\t20261120T010000Z\n' >"$S/registry.retired.tsv"
mk() {  # NAME AUTHOR-LINE EXTRA-LINE
  printf '# R7 reviewer seat\n\n%s\n\nReport on task dispatch-bug-r99.\nBranch `review/b99-01`, head abc.\n%s\n' "$2" "$3" >"$S/dispatch/briefs/$1.md"
  echo "$S/dispatch/briefs/$1.md"
}
plan() {  # BRIEF -> the PLAN / SKIP lines
  (cd "$C/csi-spl-orc" && env PROJ_PATH="$PWD" SPOOL_ROOT="$S" ASKS_BOX=box-a SPL_SPOOL=/nonexistent \
    REVIEW_NOTIFY_FROM=c-001 REVIEW_NOTIFY_DISPATCHER=c-002 REVIEW_NOTIFY_BRIEF="$1" REVIEW_NOTIFY_REVIEWER=c-900@box-b DRY_RUN=1 \
    bash -c 'set -uo pipefail
      do_log() { echo "$*"; }; do_require_bin() { return 0; }
      for f in lib/bash/funcs/*.func.sh src/bash/run/*.func.sh; do source "$f"; done 2>/dev/null
      do_spl_spawn_review_notify' 2>&1 | grep -oE 'PLAN note c-001 -> [a-z]-[0-9]+@[a-z0-9-]+|SKIP: author [a-z]-[0-9]+ [a-z ]+' | head -1)
}
bad=0
chk() {  # NAME WANT BRIEF
  local got; got="$(plan "$3")"
  echo "rc01 $1: ${got:-none} want=$2"
  [[ "$got" == *"$2" ]] || bad=$((bad + 1))
}
chk far      "-> c-442@box-b"            "$(mk far 'Author: c-442' 'Author lane: c-442@box-b (claude).')"
chk here     "-> c-443@box-a"            "$(mk here 'Author: c-443' 'The author lane of this row.')"
chk explicit "-> c-444@box-b"            "$(mk explicit 'Author: c-444@box-b' '')"
chk gone     "SKIP: author c-445 already retired" "$(mk gone 'Author: c-445' 'No box named.')"
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b31-02 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), sources its spl-done-claim-check.func.sh and asks
# spl_done_claim_tokens which hex tokens of a result line it reads as a git
# sha (no repos file: every lettered 9..12 / 40 hex token is kept, as the
# check does before it judges them). The rule (its header, SPL-2332 /
# SPL-5990): a token after a sha256 / sha256sum / md5 label is a file hash.
#   prefix   : "rc03.sh sha256 prefix `da931bbcc8d4`" (c-513 e1221e85, the
#              alert 003e85a2) -> no token (RED when kept)
#   first12  : "sha256sum first 12 hex `a366e7466e55`" (bug-round-30-plan.md
#              3.2's own form) -> no token (RED when kept)
#   label    : "sha256 `faa73d5664fe`" -> no token (control, served SPL-5990)
#   gitsha   : "landed `9b680e7b5`" -> 9b680e7b5 (control)
#   diff     : "sha256(git diff cc13eac0b 5e137db43)" -> both (control: the
#              hash of a diff of two git shas names the git shas)
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
tok() {  # LINE -> the tokens read
  (cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" bash -c 'set -uo pipefail
    do_log() { :; }
    source src/bash/run/spl-done-claim-check.func.sh
    printf "%s\n" "$1" | spl_done_claim_tokens' _ "$1" 2>/dev/null)
}
bad=0
chk() {  # NAME WANT LINE
  local got; got="$(tok "$3")"
  echo "rc02 $1: tokens='${got}' want='$2'"
  [[ "$got" == "$2" ]] || bad=$((bad + 1))
}
chk prefix  ""                    'rc03.sh sha256 prefix `da931bbcc8d4`.'
chk first12 ""                    'rc01.sh 2488 B (`sha256sum` first 12 hex `a366e7466e55`).'
chk label   ""                    'rc02.sh sha256 `faa73d5664fe`.'
chk gitsha  "9b680e7b5"           'landed `9b680e7b5` on master.'
chk diff    "cc13eac0b 5e137db43" 'sha256(git diff cc13eac0b 5e137db43) equal.'
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 30's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b30-01, b30-02, b30-03 | `git log origin/master --oneline -E --grep='\(b30-0[123]-'` | landed `9b680e7b5`, `b341f7bb8`, `82d1b51da`, `6f2a343bb`, `252de9ad2` | Served (SPL-6108 closed by `0eb0ea462`). Their R7 notes: section 5. |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | sat `/var/csi/csi-spl/done-claim-check/cron.log` (46409 lines), the 2 notes of task 88dcee25 since round 30 | 0 `job <hex>` alerts; the two notes are a sha256 prefix (row 02) and a result with no sha | **Not a row**: the condition did not occur. It stays an input. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. It stays an input. |
| The AltGr picker; the desktop blog switcher's Enter on its one match | source 1 | 0 picker / switcher words since 00:57Z | **No rule it breaks and no owner word.** Carried. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` on `325a47c76`, 04:16Z: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> rc 0, `81 passed, 0 failed` | not red (n=1 each) | **Not reproduced**, as in rounds 27 to 30. It stays an input if seen red with its user and tree. |
| `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting | source 2 | `grep -c 'download iframe' <the report>` -> 0 in 100 runs | **Not a row**: no 3rd sighting. |
| `workspace-doc-preamble.test.mjs` at its 3rd sighting | source 2 | 1 sighting (44832401773), the one round 30 counted | **Not a row**: no 2nd or 3rd sighting. |
| The `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms, if printed again | prod messages since 00:57:47Z (487): `body ~* '\mtasks [0-9a-f]{7,40}\M'` -> 0, `'\m(forward\|multicast) [0-9a-f]{7,40}\M'` -> 0 | not printed again | **Not a row.** Carried with round 30's count (1 text in 6.5 h, then 0 in 3.3 h). |
| b29-01 N1: the profile account same / differs across a real renewal | sat, 04:16Z: the `<AGENT_USER>` claude credential's mtime is 03:54:12Z (a renewal), and `<kept file>.account` was rewritten at 03:55:05Z, 1 line. Its account key equals the key of the login's `~/.claude.json` `oauthAccount.accountUuid` (sha256 of it, same 12-hex form) and the kept reading row's key (column 10). Printed `claude.json-key==account-key`, `row-key==account-key`; no key shown | reads **same** (n=1, sat) | **Not a row**: the b29-01 design keeps the row across this renewal. The file is rewritten only when its pair changes (`spl_box_quota_claude_key`, `lib/bash/funcs/spl-box-quota.func.sh:308`), and its account key is the login's, so the access-token key is what changed. `<box2>`'s reading (c-275 measures there) is not read here. |
| The overlay mounts of dead `/tmp` worktrees | sat, 04:16Z: `findmnt -rn -o TARGET,FSTYPE \| grep '^/tmp/'` -> 1, `/tmp/g-334-spl5639-review/csi-spl-wui/node_modules overlay`. `git -C <main checkout> worktree list` no longer lists `g-334-spl5639-review` (removed by hand on 11-20) | 1 mount on a tree git no longer knows | **Not a row this round** (it would be a 3rd row, and its red control needs a mount, which needs root). Carried: the mount outlives the tree, so `git worktree remove` is not the place to fix it. Who mounts it (a seat's `pnpm` overlay helper) is not traced here. |
| The 8 dashless `/tmp` seat worktrees, if b30-02's prefix rule leaves them | sat, 04:16Z: `git -C <main checkout> worktree list \| awk '$1 ~ /^\/tmp\//' \| wc -l` -> 10; not `<agent-id>-<rest>`: 2, `/tmp/c090-r7-4y3F/base` and `/head` (nested one level, not dashless) | sat has 0 dashless; `<box2>`'s 8 are not read here | **Not a row**: b30-02 ships default-off (`WT_SWEEP_TMP_ROOT`) and nobody has turned it on yet, so whether it leaves them cannot be seen. Carried, with the 2 nested ones. |

---

## 5. The holder's candidates, the R7 notes and the done-claim notes, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **The review notice: bare `Author:` resolves to this box** (c-001 7e965718) | section 3 | **Row 01.** Its fix idea "the notice reaches `<id>@<other box>`" is taken from the brief's own `<id>@<box>` mention. The alternative, asking the hub's lane map, is not taken: all 10 measured briefs that name a box write the same box. Workaround meanwhile (the entry's): `Author: <id>@<box>` in every reviewer brief, the only fix for the 2 briefs that name no box. |
| **The done-claim note on c-513's "ready for R7" result** (c-001 003e85a2; the brief: "a pre-rebase sha") | section 3 | **Row 02.** It was not a pre-rebase sha but rc03.sh's sha256 prefix. Firing on a `kind result` that is not a land claim is the rule (SPL-2265: "a lane result names a sha on the trunk"), and the review-branch path (SPL-3673) keeps a sha on `review/*` quiet. The wrong verdict here is the hash read as a sha. |
| **The done-claim note on c-533's result with no sha** (c-001 8d349075, result c6b6b22e on task dispatch-93b73456) | On sat, `grep -lr 'c6b6b22e-3671' /var/spool-hub/c-*/archive` -> only the note. The body was read on `<box2>` (c-001@`<box2>` msg 977706b2, verbatim): a repo registration and ingest on dev and prd, "SPL-6131 done (applied, no commit)", "sha: none" | **Not a row**: the result has no commit, and its body says so (`sha: none`). "names no sha" is the documented note for such a result (SPL-5841, done-claim-check.md item 4), so the verdict is true. Whether a lane result that lands no commit should be noted at all is a rule question for the holder, not a bug. |
| **The review notice names only `review/` branches** (c-001 7717bbb1, n=1) | `spl_review_notify_branch` (`spl-spawn-review-notify.func.sh:101-107`) greps `review/[A-Za-z0-9._/-]*` only; sat's spool archive since 11-19: `grep -l 'no review/ branch named'` -> 1 message, 7717bbb1 itself (notes to `<box2>` authors go through the relay and are not kept on sat) | **Not a row this round**: same file as row 01 (R1), n=1. It is the first row of round 32 if it is seen again or if row 01 lands first. Fix scope then: also read a `wip/` ref (or the brief's `Branch` line). |
| **The per-box lease vendor order reverts with grok in it** (c-001 1a36d045, n=2 boxes; cause UNCHECKED) | sat `/var/spool-hub/dispatch/lease.conf*`, `grep -h '^LEASE_VENDOR_ORDER'` per file and its mtime: `lease.conf.20261112T1808Z.bak` (mtime 11-12 13:53Z) `claude,agy,claude2`; the next file, `lease.conf.bak-20261113T030600Z-...-failover-orch` (mtime 11-12 18:07Z), `claude,grok,agy,claude2`; every later backup up to `...20261121T023513Z-orch-grok-off` carries grok; `lease.conf` now (02:35Z hand fix) `claude,agy,claude2`. `grep -rnE '>\s*"?\$\{?LEASE_CONF\|mv [^\|]*LEASE_CONF' csi-spl-orc/src/bash --include=*.sh` (non-test) -> 0 writers of the whole file | **Not a row**: on sat, grok came in at 11-12 18:07Z, one minute before a backup named in a hand style (`<UTC>.bak`, not the code's `.bak-<UTC>`). That was a hand edit, made the day grok was placeable again (prd kinds off = [qwen] only, 11-13 01:3xZ). After it, the rotations copied the file as it was; no rotation or failover introduced grok on sat. No code writer of the line was found. `<box2>`'s history (11-12 ~19:15Z, "with a failover run") is not read here: an input for the holder, with a red control once a writer is named. |
| **b30-01 R7 c-504 N1, N2** (a728a1de) | the PASS message | **Not bugs.** N1 asks for two guard cases in `spl-spawn-place-argmax.tst.sh` section 9 (two ci rows; a `_l false` ci ahead of a launchable one), which pass ad hoc: a test round input. N2 says a `_l false` ci HEAD is still taken by the old HEAD test, unchanged and as the row says. |
| **b30-02 R7 c-529 W1, N1, N2, N3** (298a5b95, e98cd4d3) | the PASS messages; W1 fixed by `82d1b51da` (a6e88f960, PASS) | **Not bugs.** W1 is closed. N1: the salvage path's `--force` applies to a `/tmp` tree only if `registry.retired.tsv` lists its path, which the retire never does. N2: the id is taken from the name, and the in-use, clean, landed and 72 h checks still guard it. N3: an INFO line before START, cosmetic. |
| **b30-03 R7 c-531 W1, N1** (022a9ae3, e442c7fb) | the PASS messages; W1 fixed by `252de9ad2` (6d9b571a9, PASS) | **Not bugs.** W1 (the `here` control did not prove the local path) is closed. N1: `ASKS_BOX` before `SPOOL_DESK_BOX`, as `spl-spawn-place.func.sh` does, fine. |
| **spec 181 B6 R7 c-502 N1-N4** (ban-list limits of `spl-customer-box-role-check.func.sh`) | `git log origin/master -E --grep='SPL-6122'` -> `3f33e9dab`, `91804ac3e`, `59d9adf7a` (B6 landed) | **Not this round's (R3)**: spec 181's checks (live lanes B1 c-292, B5 c-477), and a ban list cannot prove absence. For the spec 181 lanes, through the holder. |
| **spec 181 B5 R7 c-507 N3-N5, N8; B10 R7 m-612 N1, N2, N4** | the candidates file | **Not this round's (R3)**: spec 181 notes (N8 is B8's, the provisioning action) and doc rows after the owner answers the `pricing_not_ready` poll. |
| **`ws-docs-head.mjs` synthetic `el.click()`** (c-473 W1 on SPL-6115) | the candidates file | **Not a bug**: the test proves less than it says, but nothing a user sees is broken. A test-hardening input. |
| **Served since round 22**: the kept weekly reading after a credential copy (b29-01 `ac367b7a5`), review-go's "found locally only" and its loop (b27-01 `656ab3389`, b28-02 `4c4e97f75`), review-go's send to a retired author held once, not retried (b20-01 `2f634fbd4`, panel N4), the panel-seat UI swap and its slug forms (b27-02 `21abdb87e`, b29-02 `ae4898ae1`), the never-list author (b22-02 `3e46a758c`), the done-claim sha256 label (b23-02 `a6f5a723d`) and image tag (`f136d78da`), the CI-first rule (b30-01), the `/tmp` worktrees (b30-02), the `After:` box (b30-03), `unanswered-sweep.tst.sh` section 12 (`74bd535d8`) | `git log origin/master --format='%h %s' -E --grep=<key>` per item | **Served.** |
| **b29-01 N2, N6; the topic loop cap race; Rows A and B of the reflection; the agent-boot-restore dir; SPL-6107 N1** | as round 30 section 5 | **Not bugs this round**, as round 30 reads them: a hardening input, untraced callers, not a bug (one `UPDATE ... WHERE`), detectors, a refactor and a usage text. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file (lane map 04:13:10Z, queue 04:14:53Z); the `<box2>` halves are asked of the holder. |
| The orc 2/4 red at `ad950c0e8` and `75da57eb4` (`hub_cloudtranslate_user` not covered) | spec 123 L0 (SPL-6132) | Fixed by `4a1c86baa`; its CI had not run at the report's read. |
| The lease vendor order on `<box2>` (c-001 1a36d045) | the holder | Sat's change was a hand edit (section 5); `<box2>`'s writer is untraced. |
| The overlay mount of the removed `/tmp/g-334-spl5639-review` | the next round's input | 1 on sat (section 4). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 11 round 30 inputs, 22 holder candidate entries, 8 R7 notes (b30-01 N1-N2, b30-02 W1 N1-N3, b30-03 W1 N1), 2 done-claim notes; 18 human posts since 00:57Z (all probes); 100 CI runs; 44 review-notify author lines and 12 skipped briefs read; 487 prod messages for the commit-links forms; 2 red controls (n=3 each, on two shas); 2 suites re-run as the agent OS user; 10 `/tmp` worktrees and 1 mount on sat |
| first inputs for round 32 | the review notice's `wip/` branch (c-001 7717bbb1) once row 01 lands or a 2nd sighting comes; the done-claim `job` label if it alerts alone; the AltGr picker and the blog switcher's Enter if a rule or the owner says how they must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` and `workspace-doc-preamble.test.mjs` at their 3rd sightings; the `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms if printed again; b29-01 N1 on `<box2>` if it reads `differs`; the overlay mount that outlives its `/tmp` worktree; `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on; the lease vendor order writer on `<box2>` once named |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-651@sat (claude, `specs_and_docs`).
- **Panel:** the b31 mistral panel seat (ask `c002-bug-round-31-mistral-panel-seat`; its worktree `m-642-c002-bug-round-31-mistral-panel-seat` is on sat). Both rows are orc bash plus one doc item, with no WUI file, so a mistral seat may sit (developer guide 5.1).
- **Asked of the holder with v0.1, answered** (c-001@`<box2>` msg 977706b2, also forwarded by c-002@sat as fd34b0fb; folded into sections 3.1 and 5); c-146, which v0.1 left out, was answered in msg cfdfc6ed:
  1. The 14 exit-4 lanes of section 3.1, all on `<box2>`: for each worktree, `git diff --name-only origin/master...HEAD` and its dirty paths, checked against the row files (the four code and test files and `csi-spl-doc/doc/md/done-claim-check.md`).
  2. `<box2>`'s slug half: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b31-[0-9]{2}\|bug-round-31'` and `git worktree list \| grep -cE 'b31-[0-9]{2}\|bug-round-31'`.
  3. Optional, for section 5: the body of c-533's result c6b6b22e (on `<box2>`), to see whether it names a sha in a form the check misses.
- **Row reviewer (R7):** rows 01 and 02: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (04:15Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 45m ago; <box2> 99% billing read 1h45m ago]: queue the lane, spawn nothing`. No row has a mistral backup: both are a coding kind (`simple_coding`), and mistral takes no coding kind, as main or backup. An absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 04:24Z: the editor pushed v0.1 (`a370b5786`) to `review/c002-bug-round-31-planner` and reported to the holder (msg 6f2d517b). The holder checked the head and sent it to m-642@sat for the panel (msg d2604ba8).
  - 2026-11-21 04:3xZ: m-642@sat **PASS** on v0.1 `a370b578614753c566e2f92deb642883a02770bb` (msg 6fc73e6c; seat file `e380f83fd`), no W. It re-ran rc01 and rc02 on `325a47c76` (n=3 each, exit 1, wrong=1 and wrong=2), read every cited line at `325a47c76`, checked the rc files' sha256, ran the lane map (exit 4, no row file owned), grepped the queue (0 hits in 19 briefs) and ran `do_spl_box_pick` (hold), `do_check_dist_hygiene` (clean) and `do_check_pre_push` (all parts PASSED). N1: the exit-4 lanes are on `<box2>`, and section 8 asks for them (answered in v0.2). N2: the queue moved from 22 to 19, with 0 hits at both reads. N3: `origin/master` moved `325a47c76` -> `986ddca84` (one docs commit, SPL-6086); `git diff --stat 325a47c76 986ddca84 -- csi-spl-orc csi-spl-doc/doc/md/done-claim-check.md` is empty, so no cited line drifted. N4: the retired-author no-retry is b20-01 `2f634fbd4` (bug-round-27-plan.md:167); section 5's served list now names it.
  - 2026-11-21 04:3xZ: v0.2 `78c13231e`, one commit on `a370b5786` (a fast-forward of the review branch). It folds in the `<box2>` halves: 14 lanes with 0 hits (c-146 in msg cfdfc6ed), b31 free on `<box2>`, c-533's body. It corrects the exit-4 list (14 lanes, with c-146) and records the 04:26Z re-run. This file is the only one it touches. No row changed.
  - 2026-11-21 04:4xZ: v0.3, one commit on `78c13231e` (a fast-forward of the review branch). It records the status, panel and consensus lines, the PASS with N1-N4, and b20-01 in section 5's served list (N4). This file is the only one it touches. No row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-651@sat | v0.3 (`<box2>` halves, the PASS and N4 folded) |
| Panel | m-642@sat (mistral) | **PASS** on v0.1 `a370b5786` (msg 6fc73e6c), no W; delta v0.1..v0.3 to read |
