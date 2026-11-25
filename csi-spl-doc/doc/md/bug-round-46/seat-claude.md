# Bug round 46 - panel seat claude (c-440@sat)

Plan: `csi-spl-doc/doc/md/bug-round-46-plan.md` v0.1 on `review/c002-bug-round-46-planner`.  
**Sha read: `58d224dad70e147b4a9319f6bd3d9c2f85b8ec1f`** (`git ls-remote origin refs/heads/review/c002-bug-round-46-planner` -> that sha, 06:3xZ 2026-11-25). Its parent is the plan's base `5c0ba2f40c736bc907283eb932f3e9396d61e654` (`git rev-parse 58d224dad^`).  
Seat: c-440@sat, claude, cross-vendor panel seat of rulebook 3.2 (planner a-438@sat, agy). Read only: no code written, no plan edited.  
Ran on sat, 06:30Z..06:36Z on 2026-11-25, go1.26.10, `origin/master` = `d5f1a228d`. n=1 per command unless stated.

## Verdict: **FAIL** on `58d224dad`

One defect, W1, in row b46-02. The plan says no other test creates a non-`zz` category. That is false: `TestCategoryDeleteInUseRefused` in the same file does. So the row's fix scope and its red control both leave part of the defect it names in place. Rows b46-01 and b46-03 hold as written, and every cited line matches. Fold W1 (widen b46-02, or carry the rest of it out with a reason) and I sign v1.0.

---

## 1. Slug b46 unused since W

| command | output |
|---|---|
| `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(b45-plan'` | `5c0ba2f40 2026-11-25T08:08:40+02:00`: the round-45 close record. The previous one, `9f3c8a72e 2026-11-24T21:15:46+01:00`, is the plan's recorded `W`, read before the close landed (5.3: read once). Agreed. |
| `git log origin/master --since="2026-11-24T21:15:46+01:00" --oneline -E --grep='\(b46-' \| wc -l` | `0` |
| `git ls-remote origin \| grep -E 'b46-[0-9]{2}\|bug-round-46'` | `58d224dad70e147b4a9319f6bd3d9c2f85b8ec1f refs/heads/review/c002-bug-round-46-planner` only (the planner's branch; this seat's branch did not exist yet) |
| `ls /var/spool-hub/dispatch/briefs \| grep -E 'b46-[0-9]{2}\|bug-round-46'` | `c002-bug-round-46-claude-panel-seat.md`, `c002-bug-round-46-planner.md`: only the two expected |

**Pass.**

## 2. Sites on the base and on origin/master

Each line below was printed with `git show 5c0ba2f40:<file> | sed -n <N>p`:

| cite | printed | match |
|---|---|---|
| `hub/hours_me.go:527-548` | `func parseHoursMinutes(...)` .. `return out, loc, ""` / `}` | yes |
| `hub/hours_me.go:541` | `if at.After(now.Add(hoursMinuteSkew)) \|\| at.Before(now.Add(-hoursMinuteMaxAge)) {` | yes |
| `hub/hours_me.go:562-566` | `ms, loc, bad := parseHoursMinutes(body, now)` / `if bad != "" {` / `writeErr(w, http.StatusBadRequest, "bad_minutes", bad)` / `return` / `}` | yes |
| "`handlePutMyHoursMinutes` 40 lines" | the closing `}` is the 40th line from `:552` (`awk 'NR>=552 && NR<=600' \| grep -n '^}' \| head -1` -> `40:}`) | yes |
| `csi-spl-wui/src/utils/hours-recorder.mjs:121` | `if (e && e.status) return` (comment on `:120`: "a refusal (409 frozen, 400) is final") | yes |
| `hub/hours_me_test.go` "after `:176`" | `:176` is blank, `:177` is `// A frozen day is 409 ...`; file 550 lines | yes |
| `store/categories_test.go:64` | `leaf := "coding/hard/go_" + strings.ToLower(uid(""))` | yes |
| `hub/categories_test.go:44` | `leaf := "coding/hard/go_" + strings.ToLower(newTenantID(""))` | yes |
| `store/reporting_schema_test.go:180` | ``rows, err := tx.Query(ctx, `SELECT category_path FROM activity_categories WHERE category_path !~ '(^\|/)zz' ORDER BY 1`)`` | yes (the filter, not the func header) |
| `store/reporting_schema_test.go:199-201` | `leaf := "zz" + ...` / `INSERT ... VALUES ($1, 'coding/hard', 'Finer')` / `"coding/hard/"+leaf` | yes |
| `spl-review-go.func.sh:631-632` | `# condition word, if / when / unless / once / while / after / until, stands` / `# before it in the same clause, since the last . ; : , ! ? or line start:` | yes |
| `spl-review-go.func.sh:683` | `cond = re.compile(r"(?i)\b(?:if\|when\|unless\|once\|while\|after\|until)\b[^.;:,!?\n]*$")` | yes |
| `spl-review-go.tst.sh:1217` | `done` (end of case 30; `:1219` `echo "spl-review-go: ${fails} failure(s)"`; file 1220 lines) | yes |
| `hub/fleet_tokens.go:52` | `FleetAlertsChannel = "fleet-alerts"` | yes |

Drift: `git diff --name-only 5c0ba2f40 origin/master -- <the 6 row files + reporting_schema_test.go + hours-recorder.mjs + fleet_tokens.go>` -> empty (`origin/master` `d5f1a228d`). The plan's "only the two review-go files changed since `9f3c8a72e`": `git diff --name-only 9f3c8a72e 5c0ba2f40 -- <the 6 row files>` -> `spl-review-go.func.sh`, `spl-review-go.tst.sh`. **Pass.**

## 3. Red controls, read and run

Each script was cut verbatim from section 4 of `58d224dad`'s plan into this seat's scratch dir, then run from this worktree (`bash <script> <sha> [fix-shape]`).

| script | `sha256sum` | bytes | plan says |
|---|---|---|---|
| `rc01-b46.sh` | `a30567d4343c8af2f9b08768126e2544ce24d086d9598fbc0d13dc6939b8b1cf` | 3735 | `a30567d4343c`, 3735: match |
| `rc02-b46.sh` | `acf0e97bb55284eac9d7a5b330dd6c2de15d137d82a9531075fe150e5f416241` | 2511 | `acf0e97bb552`, 2511: match |
| `rc03-b46.sh` | `3888320d0f9fc55f3fb59928eb75e89e8efb55e9107c51e2c3f5549c81c19aea` | 2334 | `3888320d0f9f`, 2334: match |

| run | last lines | exit |
|---|---|---|
| `rc01-b46.sh 5c0ba2f40` | `rc01_b46_test.go:56: rc01: 400 bad_minutes logged no warn with future reason; output={"level":"info",...,"path":"/v1/me/hours/minutes",...,"status":400,...,"message":"http"}` / `rc01 exit 1` | 1 |
| `rc01-b46.sh 5c0ba2f40 fix-shape` | `ok github.com/csitea/csi-spl/spool-hub-api/internal/hub 0.037s` / `rc01 exit 0` | 0 |
| `rc02-b46.sh 5c0ba2f40` | both `leaf "coding/hard/go_deadbeef" does not match (^\|/)zz` lines / `rc02 exit 1` | 1 |
| `rc02-b46.sh 5c0ba2f40 fix-shape` | `ok .../internal/store 0.023s` / `rc02 exit 0` | 0 |
| `rc03-b46.sh 5c0ba2f40` | `... -> rc 1 (want 0); ... -> rc 1 (want 0); ... -> rc 1 (want 1); ... -> rc 1 (want 1)` / `rc03 exit 1` | 1 |
| `rc03-b46.sh 5c0ba2f40 fix-shape` | `rc 0, 0, 1, 1` / `rc03 exit 0` | 0 |
| `rc03-b46.sh 958049e92^` | `rc 0, 0, 0, 0` / `rc03 exit 1` | 1 |
| `rc03-b46.sh 958049e92^ fix-shape` | `AssertionError: fix-shape: cond line not found once` | 2 (expected: `cond` does not exist before b45-01) |

**Failing for the right reason:**

- rc01: the go test fails on the missing warn line. The only log line on the 400 is the middleware's `info` `http` line, so this is the defect itself, not the environment.
- rc02: it fails on the two literals. See N2 for what this does not prove.
- rc03: the script sends output to `/dev/null`, so I re-ran the owner-go scan by hand on `5c0ba2f40`'s copy:
  - `3. Check if green` / `No terraform apply.` printed `the author brief names owner-go keyword 'apply' and has no Owner-go: line`, rc 1.
  - The same with `3. Check if green.` (a full stop): rc 0.
  - In Python on that text, `cond.search(t,0,e)` gives `True` with `$` and `False` with `\Z`. A blank line between the two lines gives `False` with `$`. The same-line `If no errors apply` still gives `True` with `\Z`.

  So the hold is exactly the `$`-before-trailing-newline match the plan describes.

**Live state:** none is touched.

- rc01 and rc02: `git archive` into `mktemp -d` and in-process go tests, with no DB DSN.
- rc03: `git show` into `mktemp -d`, with `SPOOL_ROOT` and `SPL_STATE_DIR` set to that dir. `ls -A` of it afterwards held only the fixtures and `rg.sh`.

## 4. The defects, read on the tree

- **b46-01: real, narrow, the control proves it.**
  - `handlePutMyHoursMinutes` calls `writeErr` on `bad != ""` with no `s.o.Log` call (`:563-565`), and the WUI drops a 400 as final (`hours-recorder.mjs:120-121`).
  - The fix is one warn line before `writeErr`, so the handler stays far under 75 lines.
  - rc01 without `fix-shape` turns green on any fix whose warn line carries the `bad` text, because the future-skew text holds "future".
  - prd read by this seat: see N1.
- **b46-02: the leak is real, but the fix scope is incomplete (W1).**
  - `dropCategories` (`store/categories_test.go:17-26`) deletes only in `t.Cleanup`, so a killed run leaves the row.
  - A row left from `hub/categories_test.go` is visible to the store test while `go test ./internal/store ./internal/hub` runs both packages at once. `git grep -c 't.Parallel()'` on the three files -> none, so within the store package the tests run one after another and only the kill path applies.
- **b46-03: real, narrow, the control proves it.** See section 3. The fix is one character class (`$` to `\Z`), as the comment at `:632` already says ("line start"). I did not re-measure the "6954 briefs, 0 differ" corpus figure.

## 5. Rows: R2, vendors, R1

- Each row has a failing-then-passing control, a test column, vendor `claude`, kind `simple_coding` and batch 1. R7 goes to agy, else the claude waiver seat (`1a7c70da`).
- There is no mistral and no grok anywhere in the row table.
- **Test names exist**, checked with `git grep -h -o -E '^func (TestMyHours|TestHours)\w*' 5c0ba2f40 -- .../hub/` (30 names, e.g. `TestMyHoursMinutesRefusals`). In the store test column:
  - `TestCategoriesStoreCRUD`, `TestCategoryDeleteInUseRefused`, `TestSetAskCategory`, `TestCheckAskCategory` and `TestActivityCategoriesSchema` each give 1 file.
  - `^TestTokensByCategory` matches `TestTokensByCategoryRollup` (`store/categories_test.go:225`) by prefix.
  - The hub column's `^TestCategory` matches `TestCategoryRoutes` and `TestCategoryTokensRoute`.
- **R1:** the row file sets are disjoint: b46-01 `hub/hours_me.go`, `hub/hours_me_test.go`; b46-02 `store/categories_test.go`, `hub/categories_test.go`; b46-03 `spl-review-go.func.sh`, `spl-review-go.tst.sh`. If W1 is folded by widening b46-02 to `store/reporting_schema_test.go`, R1 still holds, because no other row touches that file.

## 6. R3

- `lane-map.sh --check <the 6 row paths> --agent c-440` (06:34:27Z) -> **exit 4**:
  - 17 `unknown:` lanes on `<box2>` (c-029, c-041, c-086, c-114, c-146, c-165, c-187, c-190, c-210, c-217, c-249, c-728, c-774, c-927, c-936, c-957, c-965), the same 17 the plan names.
  - `WARN no live lane lists <the paths>`.
  - So the paths are not free until the holder re-runs `--check` at placement, as the plan says.
- Worktrees on sat: `git worktree list` (235) -> no worktree has commits in `origin/master..HEAD` on the 6 row files.
- The queue, `sudo -u <HARNESS_USER> env SPOOL_ROOT=/var/spool-hub ./run -a do_spl_spawn_queue` (06:35:57Z) -> 1 row, `5b1b7d82` `claude:c001-s186-m9-n2-qto-sync`, as the plan says. It touches no row file by slug.

## 7. Inputs accounted for

- **Round 45's first inputs** (`bug-round-45-plan.md` section 7, row "first inputs for round 46") all appear in plan 3.6, 6 or 7:
  - Served by a row: hours-minutes (b46-01) and the store fresh-DB need (b46-02).
  - r96-01 N1 served: `git grep -n send_to_peers_on 5c0ba2f40 -- csi-spl-orc/src/bash/run/ | wc -l` -> `0`.
  - Topic loop cap already atomic: `git grep -n 'func TestTopicLoopCapConcurrent' 5c0ba2f40` -> `store/topic_loop_test.go:298`, and `topic_loop_postgres.go:189` is in the guarded `UPDATE`.
  - Out of repo: `zip_dirs`.
  - Carried: the non-instruction `apply`, `unknown_token`, the hub dir mode, hermetic 2/4, composed testids, and the N2 list.
- **The holder's list:** `wc -l` -> `140`, mtime `2026-11-24 22:12:57 +0200`. Its bug-shaped lines are served, carried or out of repo, the latest checked by me:
  - `:73`, `:95`, `:118`, `:128` and `:139` appear in plan 3.6.
  - `:121` (the CLI invite logs `component` twice) is served by b44-02 `158664186`.
  - The older lines are named as served in plan 3.6, or by rounds 21 to 45.
  - `:118` part (2) (the buffer-budget tests) is carried in plan 3.2 and 7.
- **prd sources, re-read by this seat:**
  - `ENV=prd SINCE=12h ./run -a do_gcp_list_alert_incidents` (06:35:07Z) -> `incidents ... none`, rc 0. Agrees with source 2.
  - The 72 h hours-minutes read: N1.
  - I did not re-read sources 1, 3, 4, 5 or 8 (ERROR log, issues, CI, owner posts).
- **Row count:** 3, at the 5.1 cap of 3, against an aim of 2. Justified: three disjoint, independent defects, each with its own red control, all in batch 1, and none is a 4th that 5.1 would push to round 47.
- No bug-shaped input is left out apart from W1, which is inside row b46-02's own defect class.

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-440`, rc 0.

---

## Defects

- **W1 (b46-02 scope; plan lines 63 (Seen), 65 (Fix scope) and 360 (row 02); line numbers checked with `git show 58d224dad:csi-spl-doc/doc/md/bug-round-46-plan.md | grep -n`):**
  - **The false claim.** Line 63 says "no other test inserts non-`zz` leaves into `activity_categories`". `TestCategoryDeleteInUseRefused` in the same file creates two non-`zz` categories, a top-level root and its child:
    - `store/categories_test.go:113` `root := "t_" + strings.ToLower(uid(""))`
    - `:114` `child := root + "/used"`
    - `:117` `pg.CreateCategory(ctx, c)`
  - **Why it leaks.** Its cleanup is the same `t.Cleanup`-only `dropCategories` (`:115`), so a killed run leaves both rows. They break `TestActivityCategoriesSchema` twice:
    - the seed read at `reporting_schema_test.go:180` (`t_<uid>` does not match `(^|/)zz`);
    - the top-level count at `:196-197` (`SELECT 1 FROM activity_categories WHERE parent_path IS NULL` ... `n != 5` -> `top-level areas: %d %v, want 5`), which has **no** `zz` filter. A leaked `zz` root would break this one too.
  - **What the row misses.** The fix scope only renames the two `leaf :=` literals and marks `reporting_schema_test.go` read-only. `rc02` checks only the `leaf\s*:=` literals, so it turns green with this half of the defect still in place.
  - **Fold** one of:
    - widen b46-02: give the `t_` root and child a name the `:180` filter skips, and make the `:196` count skip test roots, which touches `reporting_schema_test.go`; add a case to rc02 and to the Postgres check (a leaked root turns the schema test red today, green after);
    - or keep the row narrow and carry the `t_` root and the `:196` count to round 47 by name, and correct line 63's claim.

## Notes

- **N1 (b46-01 count).** `ENV=prd FRESHNESS=72h LINES=500 FORMAT=json FILTER='httpRequest.requestUrl:"/v1/me/hours/minutes" AND httpRequest.status>=400' ./run -a do_gcp_tail_logs` (06:35:18Z) -> 12 entries:
  - **8** `PUT` 400 `responseSize 385`, Android UA: 2026-11-24 12:50:27, 12:52:30, 12:56:17, 13:00:31; 2026-11-23 16:02:16, 16:07:11, 16:12:11 and **08:21:10**;
  - 4 `PUT` 401.

  The plan says 7. The 08:21:10Z one is inside the plan's own 72 h window (read at 06:11Z). The count changes; the row does not.
- **N2 (rc02 is static).** rc02 shows the literals miss `(^|/)zz`; it does not show a row left in Postgres turning the schema test red. The row's test column already asks the lane for that Postgres check under `PRE_PUSH_TIER=full`. Keep it as a gate of the row, not an option, and add W1's root to it.
- **N3 (rc03 discards output).** rc03 sends the scan's output to `/dev/null`, so an rc 1 from any other refusal would read the same. I checked the reason by hand (section 3). Printing the `owner-go keyword 'apply'` line, or grepping for it, would make the control self-proving.
- **N4 (b46-02 kind).** The row changes test files only, so kind `tests` fits better than `simple_coding`. Both route to claude main / agy backup, so placement does not change.
- **N5 (R3 at placement).** Lane-map exit 4 (17 `unknown:` on `<box2>`) means the holder must re-run `--check` at placement, as the plan says.
