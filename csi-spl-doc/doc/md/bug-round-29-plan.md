# Bug-fix round 29 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6080 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `6de93116-d87b-46ec-8a86-00a3e64e2fdc` ("Bug round 29", opener msg 3d19e5e4, opened by c-002@sat 18:00:56Z). Round 28 ([bug-round-28-plan.md](bug-round-28-plan.md) v1.0, 2 rows) is closed: close record `7df5cecfc` (SPL-6046); b28-01 `2547249ec` (SPL-6071), b28-02 `4c4e97f75` (SPL-6059). Bug share: c-001 spawn share 5cfb0d08 (bug 10%, under the 20% band).  
Round focus: two placer and pick defects that hold or misplace lanes: the kept claude weekly reading outlives a credential copied from the other box (row 01), and the UI swap still misses the `-panel-seat-<digits>` slug form (row 02, b28-01 R7 c-217 N1).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`; every other input is accounted for in sections 2, 4, 5 and 6.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-28-plan.md](bug-round-28-plan.md) (same shape, same 5 sources).

**Status: v1.0, the panel passed v0.2 `adfa2dbd8` with no W (section 8); for the holder's GO and the land.**

Editor: **c-482@sat** (claude, `specs_and_docs`).  
Panel: m-486@sat (mistral, the b29 panel seat, placed by c-001 4a516288): FAIL on v0.1 `f62668ddc` (msg 1c3a239e, relayed by the holder as 35b983e1), W1 only; **PASS** on v0.2 `adfa2dbd8` (msg b466eaaa, relayed by the holder as 6574d3f0; line check on sat rc 0, DOCS-ONLY, holder GO a77f61d3), no W (section 8).

**One sha:** every count below is measured on **`cbbc11996`** (`origin/master` at this seat's fetch of 18:20Z), on sat, between 18:15Z and 18:24Z on 2026-11-20, unless a row says otherwise. n=1 per command unless stated. The worktree sat on `7df5cecfc`, 3 commits behind; `git diff --name-only 7df5cecfc cbbc11996 -- <the row and site files of section 3>` -> empty, so the line numbers read there hold on `cbbc11996`.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b28-plan')` -> `Window: W=2026-11-20T20:04:17+02:00` (commit `7df5cecfc`, 18:04:17Z, the b28 close record). The brief quotes `W=2026-11-20T15:00:03+02:00`, read at 18:0xZ before the close record landed: that is the commit date of `dc4b3fe71` / `d980d28eb` (b28 v0.1 / v1.0). Rulebook 5.3 takes the newest plan commit, so this plan records `7df5cecfc`'s. Before the first wrap both give the same result (0 `(b29-` commits either way). The sources of section 2 read from round 28's own measurement time (11:47Z to 11:56Z) instead of W, so nothing between the two rounds is left unread.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 28. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, `<AGENT_USER>` the OS user the agents run as (the public repo names neither).

---

## 1. How to read this

- Round 28 measured on `d2f3f3b90`. This plan re-measures what changed since (`git rev-list --count d2f3f3b90..cbbc11996` -> 60 commits; `git rev-list --count --since="$W" cbbc11996` -> 4, W's own commit `7df5cecfc` and 3 after it; v0.1 said 57 and 1, read while `origin/master` was still `7df5cecfc`, panel N1 and N2), round 28's first inputs for round 29 (its section 7), the holder's candidates file, the SPL-6073 R7 note and the b28-01 R7 note (the brief), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `cbbc11996`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `cbbc11996`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since round 28** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%'), count(*) filter (where body ~* '(altgr\|enter\|picker\|switcher\|kind pick)') from messages where ts > '2026-11-20T11:49:29Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (18:18:20Z), then the same filters listing each post | t1: 82 posts, 3 with a bug word, 48 `[spool-probe]`, 2 picker / switcher words; csitea: 101 posts, 7 with a bug word; a third tenant: 4 posts, 0 | **0 rows** from new reports. t1's three owner bug reports each have their own discussion and lane already: notes Esc focus (topic 3858d264, done 17:03Z), a doc opened from channels (18140959, SPL-6064, done 16:55Z), an ask id linked as a commit (15c359fd, SPL-6073, `399f2b9de`). The 2 picker hits are two poll answers (12:06:13Z, 14:55:33Z; `picker` as a word of an option), not the AltGr or Enter questions. The csitea hits are work orders of that tenant (test cases, CVs, a pasted error), not spool defects. |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 18:15Z) | wf 10: 100 runs (2026-11-20T01:44Z..18:15Z): 67 success, 25 cancelled, 6 failure, 2 running. The failed runs (44725157504, 44721863161, 44721014389, 44713446284, 44655865817) were all created at or before 11:08:47Z: **no failed run since round 28 read the report** (11:47Z); the newest completed runs (44786241749 on `da3c56b07`, 17:44Z, and the four before it) are `success`. `grep -c agent-name-shape <the report>` -> 0 | **0 rows** from a red. Every red in the list was read by round 28 (its section 2): the login-mode M1 (fixed `fcaccd5ce`), `gcp-billing-invoices.tst.sh` `download iframe` (still its **2nd** sighting, 44725157504; no 3rd), `start on A: 4 descendants, want 3` (1 sighting), the vibe feature-test red of 01:44Z (before round 28's W). |
| **3. Skipped or disabled tests** | `git diff d2f3f3b90 cbbc11996 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `csi-spl-doc/doc/md/bug-round-28-plan.md` (its text quotes `t.Skip`) | **0 rows.** No test file was skipped. |
| **4. Box cron logs** | sat: `/var/csi/csi-spl/done-claim-check/cron.log` from the first run after round 28's read (line 45574, 11:50:01Z) to 18:20:01Z: `grep -c START`, `grep -cP '\talert\t'`, `grep -cE 'job [0-9a-f]{6,}'`, the `STOP ... rc=` codes, `grep -oE '[0-9]+ alerted[^,]*' \| sort \| uniq -c` | 46 runs: 31 `rc=0`, **14 `rc=124`** (12:55Z..17:40Z, each stopped at 600 s), 1 running; 0 `job <hex>`; 3 alert rows, all c-339 on `73f6cd79d049` (`git cat-file -t 73f6cd79d049` -> not a valid object): the image tag `spool-pdf:src-73f6cd79d049` read as a sha. The 31 finished runs took 158 s to 587 s. `<box2>` (c-001 msg 26e1c345, from 11:50:01Z): 34 runs, 33 stopped (**23 `rc=124`**, 10 `rc=0`), 1 running; 0 `job <hex>` lines (that log writes none) | **0 rows.** The `job` label input did not occur. The `src-<hex>` alert is **fixed**: `f136d78da` `fix(orc, SPL-6074): the done-claim check reads no sha in an image tag src-<hex>` (17:10Z), after the three alerts (15:xxZ and 16:15Z). The `rc=124` timeouts are a run-time defect, not a wrong answer: a perf input, handed to the holder (section 6). |
| **5. Round 28's first inputs, the holder's candidates, the R7 notes** | round 28 section 7; `/var/spool-hub/dispatch/c002-next-round-candidates.md` (62 lines), its "next BUG round" and "Bug-shaped" entries; SPL-6073 R7 N1 (c-466 fa4ea5e6); b28-01 R7 N1 (c-217, round 28 section 7) | 8 + 13 + 2 inputs | **2 rows**: 01 from the candidates file's last entry (c-001 da75da4e, kept weekly reading after a credential copy; the owner was told in t1 d943fd1e msg d8b705e8 that it goes into the next bug round), 02 from c-217's N1. The others: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `cbbc11996`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b29-01-orc-quota-kept-reading-credential-copy)` | **A kept claude weekly reading outlives a credential copied in from another login.** `spl_box_quota_keep` (`spl-box-quota.func.sh:345`) drops a kept claude row only through `spl_box_quota_outdated` (`:330`: the row's login label differs from `~/.claude.json` `oauthAccount.accountUuid`, or the CLI fetched less after the row), `spl_box_quota_lifted` (a kept 100) or the reset / `LANE_QUOTA_LAPSE_S` (10 h). Copying another box's `~/.claude/.credentials.json` changes the login the box uses but leaves `oauthAccount` at the old label, so none of them fires: the box reads the old login's % for up to 10 h, and a reading at the claude mark (99, cnf since `62daca7aa`) holds every claude lane there that long. | c-001 da75da4e (candidates file, 12:3xZ; n=1, not re-measured by c-002). Re-measured on sat, 18:16Z: `BOX_PICK_KIND=claude ./run -a do_spl_box_pick` -> `BOX sat ... claude weekly 98%` and `BOX <box2> ... claude weekly 6%`; the `<PUSH_USER>` kept file (`$HOME/.local/state/csi-spl/weekly-quota-reading.tsv`) holds `claude 98 <reset 2026-11-23T09:00Z> <read 2026-11-20T11:55:09Z> <old label> banner`; the `<AGENT_USER>` credential file mtime is 12:04:09Z (the copy), after that read, and `~/.claude.json` `oauthAccount.accountUuid` still names the label the row was kept under; the CLI's `cachedUsageUtilization.fetchedAtMs` there is of 2026-11-10, so no newer fetch overrules the row. The `<box2>` half (c-001 msg 26e1c345, 18:30-18:35Z, forwarded by the holder a58209f5): the credential there is the **same** file (its sha256 compared with sat's, not printed); its kept row is `claude 6 <reset 2026-11-26T08:59:59Z> <read 13:06:20Z> <label> cache`, and `spl_box_quota_known` there -> `claude:6@...`. The two kept rows name different week resets (11-23 on sat, 11-26 on `<box2>`): sat's 98 is the old login's week. The credential file names no account (its fields: `claudeAiOauth.accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `subscriptionTypeSource`, `rateLimitTier`), and it is rewritten at every token renewal (`expiresAt` 8 h after the copy): **c-001's fix idea, "key the kept reading on the credential sha", would drop a true reading at every renewal**. | `csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh:314-342` (`spl_box_quota_outdated` and its comment), `:345-385` (`spl_box_quota_keep`), `:224-240` (`spl_box_quota_claude_json`, the agent-user read and its seam); the test `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh` (the kept-reading cases around `:566-700`); read only: `csi-spl-orc/src/bash/run/spl-agent-login2-sync.func.sh` (the second-folder copy and its `acct-<8 hex>` label) | `bash /var/spool-hub/dispatch/b29-red-controls/rc01.sh cbbc11996` (section 3.2) -> `rc01 copy: first=claude:98@<fut> then=claude:98@<fut> kept-98=yes want=no` / `rc01 renewal: ... kept-98=yes want=yes` / `rc01 none: ... kept-98=yes want=yes` / `rc01 sha=cbbc11996 wrong=1`, exit 1, n=3 (18:23Z). | `spl-box-quota.func.sh` and `spl-box-pick.tst.sh` only (one more file of the test column if a case fits there better). **Measure first** (lesson measure-first): whether `claudeAiOauth.refreshToken` stays the same across a renewal of one login, on sat, comparing a hash prefix before and after the next renewal and printing only `same` / `differs` (no token, no hash in a log or message). Then the identity of a kept claude row is that login key read at keep time (the refresh token's hash if it is stable, else what the lane measures as stable), recorded in the row, and a row whose key differs from the credential now is outdated (`spl_box_quota_outdated`). A credential that cannot be read changes nothing. Seam: `LANE_QUOTA_CLAUDE_CRED` (a credential file read as this user), beside `LANE_QUOTA_CLAUDE_JSON`. An old row with no key keeps today's behaviour. The suite: the three rc01 cases (copy lifts; renewal and none keep), red on `cbbc11996`. Commit body: rc01 on the fix -> exit 0 (`wrong=0`), on `cbbc11996` -> exit 1, and the measured renewal answer with its n. Docs: the function comments are the doc, or `Docs: none (<why>)`. **Data rule**: the lane reads a real credential file on the box: claude or grok only, and no token, hash or credential path in a commit, log or spool message. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `secret` | 1 |
| 02 `fix(b29-02-orc-place-panel-seat-digit-suffix)` | **The UI swap still swaps a `-panel-seat-<digits>` panel seat off mistral.** `spl_spawn_place_swap`'s `seat_rx` (`spl-spawn-place.func.sh:1023`, b28-01) is `-panel-seat(-(agy\|claude\|grok\|mistral\|qwen)(-[0-9a-z]+)?)?$`: a read-only seat named `<x>-panel-seat-3` (the numbered form a spec panel uses) does not match, so a quoted `csi-spl-wui/` path trips `spl_lane_mix_ui_target` and the seat swaps to agy (`:1036`), which the placer holds (agy out on sat, on its limit on `<box2>` until 11-24, c-001 419c2320). | c-217 R7 PASS on b28-01 N1 (round 28 plan section 7, n=1: three `<box2>` briefs of 2026-10-15). Re-measured on sat 18:2xZ: `ls /var/spool-hub/dispatch/briefs \| grep -cE 'panel-seat-[0-9]'` -> 3 (`c002-monitoring-panel-seat-1.md`, `-2.md`, `-3.md`, mtime 2026-11-18T12:51Z like the bulk of that dir); each quotes one `csi-spl-wui/` path (`grep -c 'csi-spl-wui/'` -> 1 each); `-3` names mistral and still swaps on `cbbc11996` (rc02 `(live) c002-monitoring-panel-seat-3.md -> agy`). Latent, not in today's queue (`grep -E 'panel-seat-[0-9]'` over the queue's 38 slugs -> 0); the next numbered panel is held. | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:1023` (`seat_rx`), `:1010-1017` (its comment), `:108-110` (the action's @description); the test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh:1105-1166` (the SPL-3776 / SPL-3954 / SPL-6028 / SPL-6071 block); read only: `spl_spawn_place_review_seat`, `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh` (`spl_lane_mix_ui_target`) | `bash /var/spool-hub/dispatch/b29-red-controls/rc02.sh cbbc11996 <briefs>/c002-monitoring-panel-seat-3.md <briefs>/c002-bug-round-29-mistral-panel-seat.md` (section 3.2) -> `rc02 x-panel-seat-3 -> agy (mistral takes no UI work ...)` / `rc02 x-monitoring-panel-seat-12 -> agy (...)` / the four controls right / `rc02 sha=cbbc11996 wrong=2`, exit 1, n=3 (18:23Z). | `spl-spawn-place.func.sh` and `spl-spawn-queue.tst.sh` only. `seat_rx` also takes `-panel-seat-<digits>` (e.g. `-panel-seat-3`, `-panel-seat-12`); the vendor forms of b28-01 stay as they are. **A coding lane whose slug merely holds the words is not a seat**: rc02's `x-orc-panel-seat-no-ui-swap` and `x-orc-panel-seat-3-no-ui-swap` (`Kind: simple_coding`) still swap off mistral; a `-panel-seat-[0-9a-z-]*` glob is the wrong fix. A mistral seat on a mistral author is still refused (`spl_spawn_place_authors`). The suite: a `-panel-seat-3` brief, `Kind: specs_and_docs`, quoting a `csi-spl-wui/src/...` path, launches mistral (red on `cbbc11996`); the two coding controls still swap; the SPL-6028 / SPL-6071 cases stay green. Commit body: rc02 on the fix -> exit 0 (`wrong=0`), on `cbbc11996` -> exit 1. The comment and the @description say the third form. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued. No mistral backup (a coding row; panel W1): if the seat is absent 15 min, a replacement claude waiver seat (rulebook 2.7.3, R10) | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-box-quota.func.sh`, `spl-box-pick.tst.sh`. Row 02: `spl-spawn-place.func.sh`, `spl-spawn-queue.tst.sh`.
- **Test column (R2):**
  - Row 01: `git grep -l 'spl_box_quota_\|LANE_QUOTA_STATE' cbbc11996 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` -> `spl-box-pick.tst.sh`, `weekly-limit-alert.tst.sh`, `rotate-weekly-first.tst.sh`; and `rc01.sh`.
  - Row 02: `git grep -l 'place_swap\|review_seat\|panel-seat' cbbc11996 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` (as round 28 row 01): at least `spl-spawn-queue.tst.sh`, `spl-spawn-place-argmax.tst.sh`, `spl-box-pick.tst.sh`, `spawn-agents/tests/test-lane-issue.sh`; and `rc02.sh`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `spl-lane-mix.func.sh`, `spl-agent-login2-sync.func.sh` and the login helpers (read only). Row 01 touches no credential copy action.
- **How the files were checked (2026-11-20, sat):**
  - 18:21:16Z `lane-map.sh --check csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh,csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh,csi-spl-orc/src/bash/tests/weekly-limit-alert.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-doc/doc/md/bug-round-29-plan.md --agent c-482` -> `WARN no live lane lists` them; exit 4 for 12 `<box2>` lanes that record no files: 5 orchestrator rotation branches (`c-068-rotate`, `c-146-rotate`, `c-812-rotate`, `c-924-rotate-2`, `c-927-rotate`), spec 182 L1, L2b, L3 (c-968, c-973, c-975), `c970-review-build` (c-970), spec 123 P02 and P04 (c-199, c-201) and `c-098-c002-s-multicast-prompt-spec` (spec 186, a doc lane). By the brief's scopes, none is a row file. `<box2>` half (c-001 msg 26e1c345, 18:30-18:35Z): in each of the 12 worktrees, after a fetch, `git diff origin/master...HEAD --name-only` and `git status --porcelain` name none of the four row files.
  - 18:21:24Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `38 queued, 0 placing`; `grep -lE 'spl-box-quota\|spl-box-pick.tst\|weekly-limit-alert.tst\|spl-spawn-place.func\|spl-spawn-queue.tst'` over the 38 queued briefs -> 0.
  - Refactor round 77's planner is open (its panel seat brief `c002-refactor-round-77-mistral-panel-seat.md`, 18:04Z); its rows are not signed. R3: if an r77 row takes a file of this round, the one placed second waits for the first to land.
- **Slug b29 is unused as a round id** (sat, 18:15:52Z, on `7df5cecfc`): `git log origin/master --since="$W" --oneline -E --grep='\(b29-'` -> 0; `git ls-remote origin 'refs/heads/review/b29-*' 'refs/heads/wip/*b29*' 'refs/heads/*-b29-*'` -> nothing; `ls /var/spool-hub/dispatch/briefs \| grep -E 'b29-[0-9]{2}\|bug-round-29'` -> 2, this planner's brief and its mistral panel seat's (`c002-bug-round-29-planner.md`, `c002-bug-round-29-mistral-panel-seat.md`); `git worktree list \| grep -E 'b29-[0-9]{2}\|bug-round-29'` -> 1, this planner's own (`c-482-c002-bug-round-29-planner`), 0 row worktrees. `<box2>`'s half (c-001 msg 26e1c345): the briefs grep and `git worktree list | grep -cE 'b29|bug-round-29'` -> 0 each: **b29 is free on both boxes.**

  After this plan's pushes, `--grep='(b29-'` matches the plan's commits (`docs(b29-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b29-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `cbbc11996`

Both files are on sat in `/var/spool-hub/dispatch/b29-red-controls/`, and printed below so a seat on `<box2>` can rebuild them. `rc01.sh` 2771 B, `rc02.sh` 2316 B (`sha256sum` first 12 hex `80ad5c0dc466`, `bba8a88e57e6`). Each exports `csi-spl-orc` (rc02 also `csi-spl-cnf`) of the sha with `git archive` (no worktree, nothing installed) and needs bash, git, jq (rc01), python3 and `yq` (rc02). rc01 reads no real credential: its credential files are fixtures it writes.

| row | command | output on `cbbc11996` | who |
|---|---|---|---|
| 01 | `bash rc01.sh cbbc11996`, from a checkout, n=3 (18:23Z) | RED in 3 of 3: `rc01 copy: first=claude:98@<fut> then=claude:98@<fut> kept-98=yes want=no` / `rc01 renewal: ... kept-98=yes want=yes` / `rc01 none: ... kept-98=yes want=yes` / `rc01 sha=cbbc11996 wrong=1`, exit 1. Read: the copied-in login keeps the old 98; the renewal and no-credential controls keep it, as they must after the fix. | editor c-482 |
| 02 | `bash rc02.sh cbbc11996 <briefs>/c002-monitoring-panel-seat-3.md <briefs>/c002-bug-round-29-mistral-panel-seat.md`, from a checkout, n=3 (18:23Z) | RED in 3 of 3: `rc02 x-panel-seat-3 -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` / `rc02 x-monitoring-panel-seat-12 -> agy (...)` / `rc02 x-mistral-panel-seat -> mistral` / `rc02 x-panel-seat-mistral-2 -> mistral` / `rc02 x-orc-panel-seat-no-ui-swap -> claude (...)` / `rc02 x-orc-panel-seat-3-no-ui-swap -> claude (...)` / `rc02 (live) c002-monitoring-panel-seat-3.md -> agy` / `rc02 (live) c002-bug-round-29-mistral-panel-seat.md -> mistral` / `rc02 sha=cbbc11996 wrong=2`, exit 1. Read: the two digit seats swap; the b27-02 / b28-01 forms stay; the two coding controls swap, as they must. | editor c-482 |

No prototype fix was written: each change is its row lane's, with its own red controls. There is no green control on this sha: the green half is the lane's.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b29-01 red control. Exports csi-spl-orc of <sha> (git archive,
# no worktree), sources lib/bash/funcs/spl-box-quota.func.sh and keeps a
# claude reading of 98 % under login acct-a with the credential cred-a. Then it
# reads the kept value back (no live reading) three ways:
#   copy    : the credential is now another login's (refresh token differs,
#             written after the reading), ~/.claude.json oauthAccount still
#             acct-a (the 12:04Z copy): the 98 must NOT be kept (RED when kept)
#   renewal : the same login renewed (same refresh token, new access token and
#             expiry, written after the reading): the 98 must be kept
#   none    : no credential readable: the 98 must be kept
# The credential reaches the code through LANE_QUOTA_CLAUDE_CRED (a test seam
# the fix adds beside LANE_QUOTA_CLAUDE_JSON; <sha> without the fix ignores it).
# Fixture tokens only, no real credential is read. Run from a checkout.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc | tar -x -C "$C" || exit 2
now="$(date +%s)"; fut=$((now + 3 * 86400)); old=$(((now - 86400) * 1000))
printf '{"oauthAccount":{"accountUuid":"acct-a"},"cachedUsageUtilization":{"accountUuid":"acct-a","fetchedAtMs":%s,"utilization":{"seven_day":{"utilization":40,"resets_at":"2030-01-01T00:00:00+00:00"}}}}\n' "$old" >"$C/claude.json"
cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"%s","expiresAt":%s}}\n' "$2" "$3" "$4" >"$C/$1"; }
cred cred-a.json fixture-access-1 fixture-refresh-a $(((now + 3600) * 1000))
q() {  # CRED READING -> spl_box_quota_known's answer
  (cd "$C/csi-spl-orc" && LANE_QUOTA_STATE="$C/kept.tsv" LANE_QUOTA_CLAUDE_JSON="$C/claude.json" \
    LANE_QUOTA_CLAUDE_CRED="$1" LANE_QUOTA_CMD="echo $2" BOX_QUOTA_RESET=0 bash -c \
    'source lib/bash/funcs/spl-box-quota.func.sh; spl_box_quota_known' 2>/dev/null)
}
bad=0
for c in copy renewal none; do
  rm -f "$C/kept.tsv"
  first="$(q "$C/cred-a.json" "claude:98@$fut")"
  case $c in
    copy) cred cred-now.json fixture-access-9 fixture-refresh-b $(((now + 7200) * 1000)); f="$C/cred-now.json" ;;
    renewal) cred cred-now.json fixture-access-2 fixture-refresh-a $(((now + 7200) * 1000)); f="$C/cred-now.json" ;;
    none) f="$C/no-such-cred.json" ;;
  esac
  touch -d '@'"$((now + 5))" "$C/cred-now.json" 2>/dev/null
  got="$(q "$f" "")"
  kept=no; [[ ",$got" == *,claude:98* ]] && kept=yes
  want=yes; [[ $c == copy ]] && want=no
  echo "rc01 $c: first=${first:-none} then=${got:-none} kept-98=$kept want=$want"
  [[ $kept == "$want" ]] || bad=$((bad + 1))
done
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha> [brief...]: b29-02 red control. Exports csi-spl-orc and
# csi-spl-cnf of <sha> (git archive, no worktree), sources its lane-mix and
# spawn-place functions and asks spl_spawn_place_swap what a mistral placement
# of each brief launches. Built-in briefs (Kind: specs_and_docs, a live-lanes
# line quoting csi-spl-wui/src/components/Foo.vue):
#   x-panel-seat-3.md, x-monitoring-panel-seat-12.md: the -panel-seat-<digits>
#     form (b28-01 R7 c-217 N1): must stay mistral (RED when swapped)
#   x-mistral-panel-seat.md, x-panel-seat-mistral-2.md: the forms b27-02 and
#     b28-01 spare: must stay mistral (controls)
#   x-orc-panel-seat-no-ui-swap.md, x-orc-panel-seat-3-no-ui-swap.md
#     (Kind: simple_coding): coding lanes whose slug merely holds the words:
#     must NOT stay mistral (controls)
# Extra briefs given as args are printed with their answer, not judged.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha> [brief...]}"; shift
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$C" || exit 2
stay="x-panel-seat-3 x-monitoring-panel-seat-12 x-mistral-panel-seat x-panel-seat-mistral-2"
swap="x-orc-panel-seat-no-ui-swap x-orc-panel-seat-3-no-ui-swap"
for s in $stay $swap; do
  k=specs_and_docs; [[ $s == *no-ui-swap ]] && k=simple_coding
  printf '# Lane brief: %s\n\nKind: %s\n\nRead only. Live lanes to stay off: r99-01 edits `csi-spl-wui/src/components/Foo.vue`.\n' "$s" "$k" >"$C/$s.md"
done
ask() {
  (cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" APP_PATH="$C" bash -c 'set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in lib/bash/funcs/*.func.sh; do source "$f"; done
    source src/bash/run/spl-lane-mix.func.sh; source src/bash/run/spl-spawn-place.func.sh
    spl_spawn_place_swap mistral "$1"' _ "$1" 2>/dev/null)
}
bad=0
for s in $stay $swap; do
  got="$(ask "$C/$s.md")"; to="${got%%$'\t'*}" why="${got#*$'\t'}"
  echo "rc02 $s -> ${to:-?}${why:+ ($why)}"
  if [[ " $stay " == *" $s "* ]]; then [[ "$to" == mistral ]] || bad=$((bad + 1))
  else [[ "$to" != mistral ]] || bad=$((bad + 1)); fi
done
for b in "$@"; do
  got="$(ask "$b")"; echo "rc02 (live) $(basename "$b") -> ${got%%$'\t'*}"
done
echo "rc02 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

---

## 4. Round 28's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b28-01, b28-02 | `git log origin/master --oneline -E --grep='\(b28-0[12]-'` | landed `2547249ec`, `4c4e97f75` | Served (round 28 closed, `7df5cecfc`). b28-01's open follow-up (c-217 N1) is row 02. |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | source 4 | sat: 46 runs since 11:50Z, 0 `job <hex>` | **Not a row**: the condition did not occur. Stays an input on the same condition. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. Stays an input. |
| SPL-5850 N1: an AltGr letter may pick a kind (`csi-spl-wui/src/utils/kind-picker-keys.ts`) | source 1: the 2 picker-word posts are poll options | no rule, no owner word | **No rule it breaks, no owner word.** Carried. |
| The desktop blog switcher's Enter on its one match | source 1 | no rule, no owner word | **A product question, no rule.** Carried. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` on `7df5cecfc` (`git diff --name-only 7df5cecfc cbbc11996` -> 3 files, none under `csi-spl-iac/src/bash` or the watcher), 18:19Z: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> rc 0, `81 passed, 0 failed` | not red (n=1 each) | **Not reproduced**, as in rounds 27 and 28. An input if seen red with its user and tree. |
| `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting | source 2 | still 2 sightings in 100 runs (44570765247, 44725157504) | **Not a row**: no 3rd sighting. |
| `unanswered-sweep.tst.sh` section 12 if L2b (spec 182, c-973) closes without it | the lane map of 18:21:16Z lists `c-973-c002-s182-l2b-orc-sweep-skip-loop` live | L2b is open | **Owned (R3)** by L2b while it is live. Stays an input. Since v0.1 (holder msg 0585e070, c-968@`<box2>` msg bfc269cb): case 12 FAILS on `<box2>` in c-968's full pre-push gate (n=1 on its tree, n=1 on `7df5cecfc`: `listed at minute(s) 6 (want 3)`, `escalated ... TO c-002`, want c-001) and passes on sat (holder, `cbbc11996`, n=1). Ruled next round, not a v0.2 row (msg 113bfef7, agreed 05f56179): the file is L2b's and no red control runs here; handed to c-973@`<box2>`. The test's last change: `git log origin/master -1 -- csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` -> `a82b4e52e` (2026-11-13). |

---

## 5. The holder's candidates and the brief's notes, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **Kept weekly reading survives a credential copy** (c-001 da75da4e) | section 3 | **Row 01** (with the fix idea corrected: the credential sha moves at every renewal). |
| **`-panel-seat-<digit>` slug form** (b28-01 R7 c-217 N1) | section 3 | **Row 02.** |
| **review-go's "found locally only" for a sha on origin/master** | `git grep -n 'is on origin/master (it landed' cbbc11996 -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` -> 1 line | **Fixed** by b27-01 `656ab3389` (SPL-6027); spec 157 follows since b28-02 `4c4e97f75`. |
| **review-go retries a GO to a retired author** (c-001 0f130e27) | `git log --format='%h %s' origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` | **Fixed**: `2f634fbd4` `fix(b20-01-orc-review-go-retired-author-no-retry, SPL-5953)`. |
| **done-claim check takes a sha256sum prefix for a git sha** (c-001 95722c63) | `git grep -n 'sha256sum' cbbc11996 -- csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` | **Fixed** (SPL-5990, `:344`); the newer `src-<hex>` image-tag form is fixed too, `f136d78da` (SPL-6074, source 4). |
| **review-notify takes `author c-NNN` inside a never-list** (c-001 364398a4) | as in round 28 | **Fixed**: `3e46a758c` (b22-02, SPL-5976). |
| **`csi-spl-wui/tests/e2e/blog.test.mjs:329` fails run alone** (SPL-5960 R7 N3) | as in round 28 | **Served** by b26-01 `c540aca24`; its one open part is section 4's product question. |
| **SPL-6073 R7 N1** (c-466 fa4ea5e6): "ask-id 0afbe165" / "ask_ids 0afbe165" / "tasks <hex>" still link as commits (`csi-spl-wui/src/utils/commit-links.ts:41`, `ID_WORD_RE`) | prod messages of the last 7 days (14627): `body ~* '\mask-ids? [0-9a-f]{7,40}\M'` -> 0, `'\mask_ids [0-9a-f]{7,40}\M'` -> 0, `'\mtasks [0-9a-f]{7,40}\M'` -> 2 (c-001, 2026-11-13 21:03Z and 2026-11-14 13:39Z: "tasks 9d75afe5 and cd88e58c", "tasks 21944162 / e420f820") | **Not a row this round**: printed, but only the `tasks <hex>` form, 2 posts in 7 days, both older than 6 days, and their second id (after "and" / "/") would stay linked even with `tasks` in the word list. A WUI row would be a third row with the weakest evidence; carried to round 30 (section 7). |
| **orc/iac suites not hermetic to the OS user** (c-947 75843c44) | section 4 | **Not reproduced.** |
| **`unanswered-sweep.tst.sh` section 12** (c-973 fecf24d8) | section 4 | **Owned** by L2b (live). |
| **Rows A and B of the reflection; `fallback_postgres.go:83-86`; the SPL-5824 / 5825 / 5828 / r63-01 / p18-02 notes** | the file | **Not bugs this round**: detectors and coverage gaps (a test round's input), literal paths and comment wording (refactor inputs), as rounds 27 and 28 read them. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row's file (lane map 18:21:16Z, queue 18:21:24Z). |
| done-claim check run time: 14 of 46 sat runs since 11:50Z stopped at the 600 s cap (`rc=124`, 12:55Z..17:40Z), the finished ones took 158 s to 587 s; on `<box2>` 23 of 33 (c-001 26e1c345; the cap is `timeout 600`, `done-claim-check-cron.sh:30`) | the holder: a perf round input (rulebook 4); noted by the holder (msg 41bb9711) | No wrong answer seen, so not a bug row. A timed-out run finishes no check that tick, and a start may SKIP on the lock (15:25Z, 15:30Z). |
| Dead lanes' `/tmp` worktrees and their overlay mounts are not swept (holder msgs 7402cb0d / 9cb6cfcb, c-001 82c02da9, n=1: `do_tmp_stale_sweep` KEEPs 38 of 41 grok seat worktrees idle 110-191 h; sat `/tmp` inodes 81%, cleaned by hand to 48%) | round 30, its first input (msg to the holder, 18:5xZ) | Ruled next round, not a v0.2 row: the cause is not read (three sweeps may own it: `csi-spl-orc/src/bash/run/tmp-stale-sweep.func.sh`, `csi-spl-orc/src/bash/scripts/wt-dead-sweep.sh`, the utl workdir sweep), so no site or red control yet, and a third row would restart the panel. `df -i /tmp` on sat 18:5xZ -> 48%; 10 worktrees under `/tmp`. An older brief, `dispatch/briefs/c001-bug-tmp-worktrees-unswept.md`, is not queued and no landed commit names it: b30's planner reads it first. |
| `unanswered-sweep.tst.sh` section 12 as the push user | spec 182 L2b, c-973@`<box2>` | Live lane. |
| iac `gcp-billing-invoices.tst.sh` `download iframe` | the holder (rulebook 2.11.3) | 2nd sighting, no 3rd; a fixing lane at the 3rd. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 8 round 28 inputs, 13 holder candidates, 2 R7 notes; 187 human posts since 11:49Z (48 probes, 10 with a bug word, each read); 100 CI runs; 1 cron log (46 runs); 2 red controls (n=3 each); 2 suites re-run as the agent OS user; 14627 prod messages for the commit-links forms |
| first inputs for round 30 | the done-claim `job` label if it alerts alone; the AltGr picker if a rule or the owner says how it must pick; the desktop blog switcher's Enter on its one match if a rule or the owner says Enter must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting; `unanswered-sweep.tst.sh` section 12 if L2b closes without it; SPL-6073 R7 N1's `tasks <hex>` form (n=2 in 7 days) if it is printed again; dead lanes' `/tmp` worktrees and overlay mounts left by the sweep (section 6; a sweep change ships default-off; red control: a dead seat's clean `/tmp` worktree with its overlay mount, idle over 24 h, is listed for removal); `unanswered-sweep.tst.sh` case 12 red on `<box2>` only, if L2b closes without it |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-482@sat (claude, `specs_and_docs`).
- **Panel:** m-486@sat, the b29 mistral panel seat (ask `c002-bug-round-29-mistral-panel-seat`; its slug ends `-panel-seat`, so b27-02 keeps it on mistral: rc02 `(live) c002-bug-round-29-mistral-panel-seat.md -> mistral`). Both rows are orc bash; no WUI file, so a mistral seat may sit (developer guide 5.1).
- **Asked of the holder with v0.1, answered** by c-001@`<box2>` (msg 26e1c345, forwarded a58209f5; folded in sections 2, 3 and 3.1): slug free, the 12 lanes clear, the same credential at 6%, the done-claim counts. The asks were: the `<box2>` half: (1) the slug proof (briefs and worktrees, `b29-[0-9]{2}\|bug-round-29`); (2) the 12 exit-4 lanes of section 3.1, each worktree's `git diff --name-only origin/master...HEAD` and dirty paths against the row files; (3) row 01's other half: `<box2>`'s claude kept reading and whether its credential is the one copied to sat at 12:04Z (c-001 compared the `sha256sum` prefixes; the answer is `same` / `differs`, never the prefix in a public place); (4) `<box2>`'s done-claim cron log since 11:50Z (`job <hex>` count, `rc=124` count).
- **Row reviewer (R7):** rows 01 and 02: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (18:16:36Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 46m ago; <box2> 99% billing read 46m ago]: queue the lane, spawn nothing`. No mistral backup on either row: both are coding kinds (`secret`, `simple_coding`), and mistral takes none of them, as main or backup (panel W1); an absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-20 18:28Z: the editor pushed v0.1 (`f62668ddc`) to `review/c002-bug-round-29-planner` and reported to the holder (msg 86ad33d3).
  - 2026-11-20 18:57Z: m-486@sat **FAIL** on `f62668ddc` (msg 1c3a239e; seat file on `review/c002-bug-round-29-mistral-seat` `e09196f98`). W1: row 02 named the mistral panel seat as backup R7 of a `simple_coding` row; the rule is never mistral, as main or backup, on a coding kind. N1, N2: section 1's counts (60, and 4 since W with its own commit). N3: `origin/master` moved to `cc13eac0b`, row files unchanged, cited lines byte-identical. N4: rc01 / rc02 sha256 and sizes match, both RED (n=1 each). N5: the candidates file's 08:3xZ (a) / (b) were closed in rounds 22 and 27. N6 to N8: lane map, queue, row 01 symptom, prod counts re-measured, the same verdicts.
  - 2026-11-20 19:0xZ: v0.2, one commit on `f62668ddc` (a fast-forward of the review branch): W1 folded (row 02's backup dropped, section 8), N1 and N2 corrected, the `<box2>` answers folded, two candidates the holder sent since v0.1 ruled next round (sections 4, 6, 7). This file is the only one it touches. No row's sites, red control or fix scope changed.
  - 2026-11-20 19:2xZ: m-486@sat **PASS** on v0.2 `adfa2dbd8e6338c9df7404319fdf236550cd8765` (msg b466eaaa; seat file `a5b67e40b`), the delta the holder asked for (msg 059fc336): W1 folded, the counts 60 and 4 re-run, no row cell changed but row 02's R7 cell and row 01's evidence cell, section 3.2 untouched, slug still free (0 `(b29-` commits at `cc13eac0b`). No new W.
  - 2026-11-20 19:2xZ: v1.0, one commit on `adfa2dbd8` (a fast-forward of the review branch): the status line, the panel line and sections 8 and 9 record the PASS. This file is the only one it touches. No row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-482@sat | v1.0 |
| Panel | m-486@sat (mistral) | **FAIL** on v0.1 `f62668ddc` (msg 1c3a239e), W1 only; **PASS** on v0.2 `adfa2dbd8` (msg b466eaaa, relayed by the holder as 6574d3f0; line check on sat rc 0, DOCS-ONLY, holder GO a77f61d3), no W |
