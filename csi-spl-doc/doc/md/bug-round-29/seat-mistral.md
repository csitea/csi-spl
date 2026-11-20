# Bug round 29 (b29): mistral panel seat (m-486)

Seat: m-486@sat, placement `c002-bug-round-29-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-29-mistral-panel-seat.md`
(Issue SPL-6080, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `6de93116-d87b-46ec-8a86-00a3e64e2fdc`).

Review target: plan v0.1 `f62668ddc18ca01858942a577c8effe51821e6c8` on
`review/c002-bug-round-29-planner`. Provenance, all run from
`/opt/csi/csi-spl-wt/m-486` at 18:2xZ..18:5xZ on 2026-11-20: the holder's spool
message naming the sha had not arrived at my read (`spool recv --as m-486` ->
`[]`; one no-body ping from c-001); the planner's branch was pushed with subject
`docs(b29-plan, SPL-6080): bug round 29 plan v0.1, 2 rows: ...` and
`git log origin/review/c002-bug-round-29-planner -1 --format=%H` ->
`f62668ddc18ca01858942a577c8effe51821e6c8`, a single commit on `cbbc11996`
(`git rev-list --count cbbc11996..f62668ddc` -> 1), so the branch head is the
v0.1 sha the subject names. I reviewed that sha. If the holder names a different
plan version, I re-review that sha.

**Verdict: FAIL on `f62668ddc18ca01858942a577c8effe51821e6c8` — one defect (W1)
to fold before v1.0.** Checks 1-4, 6-8 pass; check 5 fails on row 02's R7 backup.

## Checks (each with the command I ran and what it printed)

1. **Slug b29 unused since the plan's `Window: W=`.**
   `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b28-plan')` ->
   `W=2026-11-20T20:04:17+02:00` (commit `7df5cecfc`, the b28 close record — the
   same W the plan records).
   `git log origin/master --since="$W" --oneline -E --grep='\(b29-' | wc -l` -> `0`.
   `git ls-remote origin | grep -E 'b29-[0-9]{2}|bug-round-29'` -> one line:
   `f62668ddc...  refs/heads/review/c002-bug-round-29-planner` (the planner's own
   review branch, expected; nothing else).
   `ls /var/spool-hub/dispatch/briefs | grep -E 'b29-[0-9]{2}|bug-round-29'` ->
   `c002-bug-round-29-mistral-panel-seat.md`, `c002-bug-round-29-planner.md` (the
   two expected briefs). PASS.

2. **Every site file:line of every row exists on the plan's base sha and still on
   origin/master.** Base sha `cbbc11996` (the plan's "one sha"); origin/master at
   my first read was `cbbc11996`, at my last read `cc13eac0b` (12 commits of spec
   182 / SPL-6030 rdb+store work landed meanwhile).
   `git diff --name-only cbbc11996 origin/master -- <the 10 row/site files>` ->
   empty (rc 0): no row file drifted.
   `git cat-file -e origin/master:<f>` for each of the 10 files -> all present.
   Each cited line checked with `git show cbbc11996:<file> | sed -n <N>p` and again
   on `origin/master` (`cc13eac0b`), identical in every case:
   - `spl-box-quota.func.sh:224` -> `# spl_box_quota_claude_json: the login and cached usage fields of the agent`; `:240` -> `}`; `:314` -> `# spl_box_quota_outdated PCT SEEN LOGIN ACCOUNT JSON NOW: exit 0 when a kept`; `:330` -> `spl_box_quota_outdated() {`; `:342` -> `# spl_box_quota_keep READING: merge READING into the kept file, print the`; `:345` -> `spl_box_quota_keep() {`; `:385` -> `# measured again. A new reading replaces a kept one, except inside one reset`
   - `spl-spawn-place.func.sh:108` -> `# @description         or a panel seat (slug ending -panel-seat, or`; `:110` -> `# @description         SPL-6071) stays mistral (SPL-3954, owner msg 594d77e1:`; `:1010` -> `# may review them, read-only (it writes no code; your UI-work rule still`; `:1017` -> `# prints "refuse\t<why>".`; `:1023` -> `  local seat_rx='-panel-seat(-(agy|claude|grok|mistral|qwen)(-[0-9a-z]+)?)?$'`; `:1036` -> `    case "$kind" in specs_and_docs|i18n) to=agy ;; esac`
   - `spl-spawn-queue.tst.sh:1105` -> `# to claude, never agy. A review seat's swap onto its author's vendor is`; `:1166` -> `HUB_DIR="$T/hub" "$T/bin/hub" ask "done" --fleet main --id "$R7" --by c-001@box-desk --reason "placed: c-519@box-desk" >/dev/null`
   - `spl-box-pick.tst.sh:566` -> `kq() { run LANES="$T/lanes.json" LANE_BOX=box-a ... BOX_PICK_KIND=claude BOX_QUOTA_WEEKLY_MAX_PCT=90; }`; `:700` -> `  kept "$p" "$A"; cj "$B" "$A" $(( KS - 60 )) "$p"`
   PASS.

3. **Each red control: read, sha256, run on the base in a scratch copy.**
   `ls -la /var/spool-hub/dispatch/b29-red-controls/` -> `rc01.sh` 2771 B,
   `rc02.sh` 2316 B (the sizes the plan quotes).
   `sha256sum rc01.sh rc02.sh` -> `80ad5c0dc46687577b6a543e31c5d9132f1876fc8919395e365c635db28da92f`,
   `bba8a88e57e6711176e1bb0370de438f3713e4e67c9e8f86e18119ce02bfbfc6` — first 12 hex
   `80ad5c0dc466`, `bba8a88e57e6`, exactly the plan's quoted prefixes, so the files
   are the ones the plan printed. Tools present: `jq`, `python3`, `yq`, `bash`,
   `git` (no install needed).
   `bash /var/spool-hub/dispatch/b29-red-controls/rc01.sh cbbc11996` (from the
   worktree, n=1) ->
   `rc01 copy: first=claude:98@1795458816 then=claude:98@1795458816 kept-98=yes want=no` /
   `rc01 renewal: ... kept-98=yes want=yes` / `rc01 none: ... kept-98=yes want=yes` /
   `rc01 sha=cbbc11996 wrong=1`, **exit 1**. RED for the plan's reason: the `copy`
   case (credential of another login written after the reading, `~/.claude.json`
   `oauthAccount` still the old label) keeps the 98 that must be dropped; the
   `renewal` and `none` controls keep it, as they must. Not an environment reason.
   `bash /var/spool-hub/dispatch/b29-red-controls/rc02.sh cbbc11996 /var/spool-hub/dispatch/briefs/c002-monitoring-panel-seat-3.md /var/spool-hub/dispatch/briefs/c002-bug-round-29-mistral-panel-seat.md`
   (n=1) ->
   `rc02 x-panel-seat-3 -> agy (mistral takes no UI work ...)` /
   `rc02 x-monitoring-panel-seat-12 -> agy (...)` /
   `rc02 x-mistral-panel-seat -> mistral` / `rc02 x-panel-seat-mistral-2 -> mistral` /
   `rc02 x-orc-panel-seat-no-ui-swap -> claude (...)` /
   `rc02 x-orc-panel-seat-3-no-ui-swap -> claude (...)` /
   `rc02 (live) c002-monitoring-panel-seat-3.md -> agy` /
   `rc02 (live) c002-bug-round-29-mistral-panel-seat.md -> mistral` /
   `rc02 sha=cbbc11996 wrong=2`, **exit 1**. RED for the plan's reason: the two
   `-panel-seat-<digits>` seats swap to agy; the b27-02 / b28-01 forms and the two
   coding controls behave as they must.
   Live state: both scripts `mktemp -d` + `trap rm -rf`, export the sha with
   `git archive` into the temp dir, point `LANE_QUOTA_STATE` at a temp file, and
   rc01 writes fixture credentials only ("no real credential is read"); neither
   touches the repo, the kept-reading file, or any live state. PASS.

4. **Root cause of each row, read at the cited lines on `cbbc11996`.**
   - Row 01: `git show cbbc11996:csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh | sed -n '300,342p'`
     shows `spl_box_quota_outdated` (:330) returns 0 (outdated) only when the kept
     row's login label differs from the current `oauthAccount.accountUuid`, or a
     newer CLI fetch (`cachedUsageUtilization.fetchedAtMs` > the row's read time)
     under another tag shows a lower reading. `spl_box_quota_keep` (:345) reads
     `acct` from `.oauthAccount.accountUuid` of `~/.claude.json` only. A credential
     copy replaces `.credentials.json`, not `.claude.json`, so `login == acct` and
     no newer fetch exists: the kept 98 survives. The plan's reading holds; rc01
     proves it. Live symptom re-measured: `BOX_PICK_KIND=claude ./run -a do_spl_box_pick`
     -> `BOX <box> ... claude weekly 98%` / `BOX <box2> ... claude weekly 6%  <- pick`;
     the kept file on <box> holds `claude 98 1795424400 1795175709` (reset
     2026-11-23T09:00Z, read 2026-11-20T11:55:09Z) — exactly the plan's evidence.
     The plan's correction of the "key on the credential sha" idea also holds: the
     credential file is rewritten at every token renewal, so a sha key would drop
     true readings; the plan's measure-first step (refresh-token stability) is the
     right order.
   - Row 02: `git show cbbc11996:csi-spl-orc/src/bash/run/spl-spawn-place.func.sh | sed -n '1000,1045p'`
     shows `spl_spawn_place_swap` with `seat_rx` at :1023 =
     `-panel-seat(-(agy|claude|grok|mistral|qwen)(-[0-9a-z]+)?)?$`; a slug
     `-panel-seat-3` does not match (after `-panel-seat` the optional group needs a
     vendor word), so the brief falls through to the UI/code rules and
     `specs_and_docs` swaps to agy at :1036. The plan's reading holds; rc02 proves
     it. Evidence re-measured: `ls /var/spool-hub/dispatch/briefs | grep -cE 'panel-seat-[0-9]'`
     -> `3` (`c002-monitoring-panel-seat-{1,2,3}.md`, mtime 2026-11-18 12:51Z), each
     quoting one `csi-spl-wui/` path (`grep -c 'csi-spl-wui/'` -> 1 each). PASS.

5. **Each row: control, test list, vendor, kind, batch; no mistral coding row; R7
   reviewer never mistral.** Both rows carry a red control that fails on
   `cbbc11996` (check 3) with the pass-after requirement in the fix scope (commit
   body: rc on the fix -> exit 0, on `cbbc11996` -> exit 1), a test column, vendor
   claude, batch 1, and R1-disjoint edit sets (row 01: `spl-box-quota.func.sh`,
   `spl-box-pick.tst.sh`; row 02: `spl-spawn-place.func.sh`,
   `spl-spawn-queue.tst.sh`; `git diff --name-only` between the two sets -> empty).
   No row is a mistral coding or testing row (both vendor claude; row 01 kind
   `secret` with vendor claude satisfies the data rule). Row 01's R7 is the claude
   waiver seat — allowed. **Row 02's R7 cell names "backup the b29 mistral panel
   seat" — see W1.** `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` re-run ->
   `pick=hold reason=waiting: grok weekly >= 95% on <box>, <box2> [<box> 99% ...; <box2> 99% ...]`,
   so the waiver seat stands. FAIL (W1).

6. **R3 lane-map check on the row paths.**
   `bash .../spawn-agents/scripts/lane-map.sh --check csi-spl-orc/lib/bash/funcs/spl-box-quota.func.sh,csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh,csi-spl-orc/src/bash/tests/weekly-limit-alert.tst.sh,csi-spl-orc/src/bash/tests/rotate-weekly-first.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-orc/src/bash/tests/spl-spawn-place-argmax.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-lane-issue.sh --agent m-486`
   -> `WARN no live lane lists <the paths>...` and **exit 4**: 16 live lanes record
   no files (unknown scope, all @<box2>): a-045, c-068, c-098, c-146, c-199, c-201,
   c-229, c-231, c-256, c-812, c-924, c-927, c-968, c-970, c-973, c-975. Of these,
   the spec 182 (c-968/c-970/c-973/c-975), spec 123 (c-199/c-201) and spec 186
   (c-098) lanes are the ones the planner's brief lists; by their brief scopes none
   touches a row file. Exit 4 = ask-first, not free; the plan asked the holder for
   the `<box2>` half (its section 8). Queue re-run: `do_spl_spawn_queue` ->
   `34 queued, 0 placing`; grepping all 34 queued briefs for the row file names ->
   0 hits. No row file is touched by a live or queued lane I can read. PASS (with
   N6).

7. **Inputs accounted for.** The plan's not-rows lists (sections 4, 5, 6) against
   `/var/spool-hub/dispatch/c002-next-round-candidates.md` (62 lines, read whole)
   and b28 plan section 7 (read whole): every "next BUG round" / "Bug-shaped" entry
   is served or accounted — review-go retired author (fixed `2f634fbd4`), the
   08:3xZ entry's (a) c-091 staged files and (b) SPL-5613 stale base (closed/fixed
   per b27 plan lines 171-172: (b) fixed `1ce9158a1`, (a) closed in round 22 —
   `git log origin/master -E --grep='SPL-5613|SPL-5936'` confirms no open row),
   orc/iac suites (not reproduced, re-run by the plan), placer note / review-notify
   `author c-NNN` (fixed `3e46a758c`), done-claim sha256sum and `src-<hex>` (fixed,
   SPL-5990 / `f136d78da`), reflection rows A/B and `fallback_postgres.go:83-86`
   (named, test-round inputs), 06:2xZ panel-seat UI swap (served b27-02/b28-01),
   07:3xZ review-go "found locally only" + GO loop (fixed `656ab3389`, whose subject
   is "review GO keeps the msg id out of do_log's globals"), unanswered-sweep §12
   (owned by live L2b c-973), c-325 W1 vendor suffix (served b28-01), kept weekly
   reading (row 01), SPL-5850 AltGr and the blog-switcher Enter (carried, no rule),
   SPL-6073 N1 (re-measured: prd messages of the last 7 days -> `total 14610,
   tasks_hex 2, ask_hex 0`, so only the `tasks <hex>` form prints, 2 posts —
   carried to round 30 as the plan says), blog.test.mjs:329 (served b26-01),
   SPL-5824/5825/5828/r63-01/p18-02 (named, refactor inputs). b28 section 7's eight
   first inputs for round 29 are all in the plan's sections 3-4. The done-claim
   cron log re-read from line 45574: 51 STARTs, `14 rc=124`, 3 alert rows, `0 job
   <hex>` — the plan's source-4 counts hold. **No bug-shaped input is neither
   served nor accounted for.** PASS.

8. **Distribution hygiene.** `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
   `ok - personal name`, `ok - literal OS user / box / AD id`, `ok - personal home
   directory`, `ok - owner mail address or domain`, `ok - hidden workspace or
   private literal (SPL-1874)`, `ok - retired relay estate (SPL-1910)`, `ok - no
   tracked .vibe/ dir`, `INFO distribution-hygiene: clean over the tracked tree of
   /opt/csi/csi-spl-wt/m-486`, exit 0 (re-run after this file was written: still
   clean). PASS.

Plan cross-counts re-run: `git rev-list --count d2f3f3b90..cbbc11996` -> `60`
(the plan's section 1 says 57 — see N1); `git rev-list --count cbbc11996
--since='2026-11-20T18:04:17Z'` -> `4` (the plan says "1 since W" — see N2).

## Defects

- **W1 (plan line 50, row 02 `fix(b29-02-orc-place-panel-seat-digit-suffix)`, R7
  reviewer cell):** the cell names "backup the b29 mistral panel seat (read-only,
  cross-vendor)" as the backup R7 reviewer of a `simple_coding` row. The fleet
  rule (global CLAUDE.md, spawn-an-agent) is "Coding: never mistral, as main or
  backup, in tests, simple_coding, complex_coding, secret or orchestration", and
  this brief's check 5 requires the R7 reviewer to be a cross-vendor seat or the
  claude waiver seat, never mistral; rulebook 2.7.2 makes the backup part of the
  R7 assignment, and C4 has the reviewer run the row's tests, which mistral must
  not do on a coding row. The primary (claude waiver seat 1a7c70da) is fine; drop
  the mistral backup or replace it with a non-mistral non-author seat before v1.0.

## Notes

- **N1:** the plan's section 1 count `git rev-list --count d2f3f3b90..cbbc11996 ->
  57` measures `60` here (plain and `--first-parent`). Prose count only; no row
  depends on it.
- **N2:** the plan's "1 since W" measures `4` commits at `cbbc11996` since
  2026-11-20T18:04:17Z. Prose count only.
- **N3:** origin/master moved during the review (`cbbc11996` at the plan's 18:20Z
  -> `cc13eac0b` at my last read, 12 spec-182/SPL-6030 commits); the row files are
  unchanged (check 2 diff empty) and the cited lines are byte-identical on
  `cc13eac0b`, so the verdict is unaffected by the churn.
- **N4:** I ran each red control n=1 (the plan ran n=3); outputs match the plan's
  quotes line for line except the epoch in rc01's `first=`/`then=` fields
  (time-dependent). rc01/rc02 sha256 and sizes match the plan's claims exactly, so
  the runs are the plan's controls, not lookalikes.
- **N5:** the candidates file's 08:3xZ entry (a)/(b) are not open inputs (b27 plan
  lines 171-172 record their dispositions), so the plan need not re-serve them;
  named here so the accounting is auditable.
- **N6:** lane-map exit 4 names 16 unknown no-file lanes, all @<box2>; their briefs
  are not all readable from <box>. The spec 182/123/186 ones match the planner
  brief's list and none touches a row file by scope; the `<box2>` half was asked of
  the holder per the plan's section 8. Exit 4 = ask-first, not free; the
  orchestrator re-runs R3 before the rows spawn.
- **N7:** row 01's live symptom re-verified (`do_spl_box_pick` claude: <box> 98% /
  <box2> 6%; grok: `pick=hold`, 99% both boxes), matching the plan's evidence and
  section 8; the kept file on <box> holds `claude 98` reset 2026-11-23T09:00Z read
  2026-11-20T11:55:09Z.
- **N8:** the prd message count for the SPL-6073 check moves with the rolling
  window (plan: 14627 at 18:1xZ; mine: 14610 at 18:5xZ); the dispositions rest on
  `tasks_hex 2, ask_hex 0`, which match.

---

## Re-review: plan v0.2 `adfa2dbd8e6338c9df7404319fdf236550cd8765`

**Verdict: PASS on `adfa2dbd8e6338c9df7404319fdf236550cd8765`** (named by the holder,
msg 059fc336, 19:0xZ; `git log f62668ddc..adfa2dbd8 -1 --format=%H` ->
`adfa2dbd8e6338c9df7404319fdf236550cd8765`, one commit on my v0.1 `f62668ddc`,
plan file only, +20 -17). The delta was judged as asked: W1's fold, the counts,
and that no row changed.

- **W1 folded.** `git diff f62668ddc adfa2dbd8 -- csi-spl-doc/doc/md/bug-round-29-plan.md`
  has hunks at lines 13, 16, 27, 40, 49-50, 60, 63, 191, 218, 230, 237-243,
  249-252 only. Row 02's R7 cell (line 50) now reads "claude waiver seat
  (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when
  the row is queued. No mistral backup (a coding row; panel W1): if the seat is
  absent 15 min, a replacement claude waiver seat (rulebook 2.7.3, R10) ..." —
  the mistral backup is gone, the replacement is a claude waiver seat, and
  section 8's R7 line names the claude waiver seat for both rows. Check 5 now
  passes: no mistral coding/testing row, R7 reviewer never mistral.
- **Counts corrected.** Line 27 now reads `git rev-list --count d2f3f3b90..cbbc11996`
  -> 60 commits; `git rev-list --count --since="$W" cbbc11996` -> 4`. Re-run by me
  at 19:0xZ: `git rev-list --count d2f3f3b90..cbbc11996` -> `60`;
  `git rev-list --count cbbc11996 --since='2026-11-20T18:04:17Z'` -> `4`. Match
  (my N1/N2).
- **No row changed.** The only row-line changes are row 02's R7 cell (W1) and
  row 01's evidence cell (the holder's `<box2>` answers folded: same credential
  file, kept row `claude 6` there, different week resets). No hunk touches
  section 3.2 (red controls, lines 67-190), and the defect / sites / red control /
  fix scope / box / vendor / kind / batch cells of both rows are byte-identical
  (`diff <(sed -n '49,50p' v0.1 | tr '|' '\n') <(sed -n '49,50p' v0.2 | tr '|' '\n')`
  shows only the evidence and R7 cells). Base sha unchanged (`cbbc11996`, line 18).
- **Slug still free.** `git log origin/master --since="$W" --oneline -E --grep='\(b29-'`
  -> 0 at 19:0xZ (origin/master `cc13eac0b`); the plan's commits live on the
  review branch only.

All other checks stand as on v0.1 (base `cbbc11996`, red controls unchanged and
RED as run, row files undrifted on `cc13eac0b`). No new W; N1/N2 are resolved by
the fold.
