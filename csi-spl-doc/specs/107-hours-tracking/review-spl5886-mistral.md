# Review SPL-5886 (mistral, cross-vendor): spec 107 v2.11 on `a49b3bc0e949eb5314f184034b94896f1c5342e2`

- **Reviewer**: m-564 (mistral), lane `c002-spl5886-spec-mistral-reviewer`, issue SPL-5886, epic SPL-3036
- **Reviewed sha**: `a49b3bc0e949eb5314f184034b94896f1c5342e2` on branch `review/c002-spl5886-hours-minimal-effort-review` (`git ls-remote origin` -> the same 40-hex, matches the brief), 1 commit on `bc559b2f6` (on origin/master), 1 file `csi-spl-doc/specs/107-hours-tracking/spec.md` +190 -1 (`git diff --stat bc559b2f6 a49b3bc0e` -> `1 file changed, 190 insertions(+), 1 deletion(-)`)
- **Code claims checked against**: `bc559b2f6` (the base, = origin/master at review time), every cite with `git show bc559b2f6:<file> | sed -n <N>p`
- **Verdict: PASS**

## Check 1 — P0.2 verbatim + translation, no FR text changed

- `git diff bc559b2f6 a49b3bc0e -- csi-spl-doc/specs/107-hours-tracking/spec.md` has exactly 4 hunks: `@@ -1,6 +1,6 @@` (status line v2.10 -> v2.11), `@@ -27,6 +27,14 @@` (the P0.2 block, spec.md:30-37 at the reviewed sha), `@@ -911,6 +919,7 @@` (version-log row 2.11, spec.md:922), `@@ -1252,4 +1261,184 @@` (section 23, spec.md:1264-1444). The only modified line outside section 23 and P0 is the status line; no FR text changed.
- Verbatim: `grep -o '"значи философията[^"]*"' <spec at a49b3bc0e>` vs the same grep on the author brief -> `diff` prints nothing, `QUOTE-IDENTICAL`. The P0.2 quote at spec.md:32 is byte-identical to the owner's `c791daf2` as quoted in the author brief.
- Translation at spec.md:34 ("so the philosophy of the whole feature must be this: minimal effort for the people who have to fill in their hours and for the people who have to collect and report them.") is a faithful rendering of the Bulgarian, including "значи ... трябва да бъде следната".
- All 9 Bulgarian owner quotes in the author brief appear verbatim in the 23.0 table (spec.md:1268-1283): a python check of `re.findall(r'"([^"]*[а-яА-Я][^"]*)"', brief)` against the spec printed `IN-SPEC` for all 9.

## Check 2 — every owner post answered in section 23

The 8 posts appended to the author brief (`c791daf2`, `ec6ab527`, `b4193b1e`, `ad99cb85`, `e9361d7c`, `b3832665`, `8551b4e6`, `1d9b6b83`) each have a row in 23.0 (spec.md:1268-1283) and a dedicated treatment: `c791daf2` -> P0.2 + all of section 23; `ec6ab527`/`ad99cb85` -> spec.md:1283 ("ad99cb85 settles ec6ab527") + row C1 (spec.md:1386); `b4193b1e` -> spec.md:1323 + Q32 (spec.md:1441); `e9361d7c` -> 23.4 (spec.md:1336) + Q33 (spec.md:1442) + E6; `b3832665` -> 23.7 (spec.md:1409); `8551b4e6` -> 23.2 item 1 (spec.md:1309) + M12 (spec.md:1380) + E8 at 412x915 (spec.md:1406); `1d9b6b83` -> 23.2 (spec.md:1294). **None dropped.**

## Check 3 — code claims on `bc559b2f6`

Sampled 25 file:line cites (the brief asked for at least 10, including the named ones); each run as `git show bc559b2f6:<file> | sed -n <N>p`:

| cite | what it printed | claim |
|---|---|---|
| `hub/hours_sweep.go:10-14` | comment: freeze sweep at end + grace, "open suggestions auto-approved first (owner Q2 = B)" | freeze sweep |
| `hub/hours_sweep.go:36-40` | `hoursOpenSuggestions` ... "as approved entries (owner Q2 = B)" | auto-approve at freeze |
| `hub/hours_team.go:36-46` | `hoursTeamAuth` calls `s.humanTenant` at :38, `s.permit(...)` at :46 | team auth chain |
| `hub/hours_team.go:188-190` | `NormDay int \`json:"norm_day_minutes"\`` | team read answers the norm |
| `hub/hours_team.go:213` | `NormDay: d.norms[id].Effective` | effective norm |
| `hub/hours_team.go:228,300` | `hoursTeamAuth(w, r, rbac.HoursRead)` / `HoursApprove` | routes through team auth |
| `hub/hours_export.go:294` | `hoursTeamAuth(w, r, rbac.HoursRead)` | export through team auth |
| `hub/resolve.go:60,80` | `func (s *Server) humanTenant(...)` / `s.o.Auth.ActiveTenant(r, host)` | session workspace |
| `auth/tenant.go:64` | `func (h *Handler) ActiveTenant(...)`; comment: membership checks, "Every lookup error fails closed" | membership gate |
| `hub/rbac.go:83` | `func (s *Server) permit(...)` "writes 403 unless hum may perm in tenant" | role check |
| `0151_hours.sql:78-88` | `ALTER TABLE hours_minutes FORCE ROW LEVEL SECURITY;` :78, `tenant_scope` :79-81, `hours_entries ... FORCE` :87-88 | FORCE RLS |
| `pages/people/[id].vue:59` | `<PersonHoursNorm v-if="canSetHoursNorm" :human-id="humanId" />` | People card norm |
| `hub/hours_export_test.go:134` | `if resp, _ := export(t, e, t2, owner, ...); resp.StatusCode != http.StatusForbidden` | cross-workspace 403 |
| `store/hours_rls_test.go:92,167` | `func TestRLSHoursScopes` / `CONTROL: without FORCE the owner read %d of t1's minutes under t2's scope, want 1` | RLS test + red control |
| `utils/hours-calendar-api.mjs:17-30` | `fetch(\`${base}/v1/me/hours?period=...\`)` — no workspace in the call | hours per active workspace |
| `hub/realm.go:298` | `PrimaryWorkspaceID string \`json:"primary_workspace_id"\`` | primary workspace field |
| `components/CalendarHoursDay.vue:24-33,199-207` | banner button `hours-approve-open` (`approve_open`), week button `hours-approve-week` (`approve_week`) | Approve N days / Approve week |
| `components/CalendarPhoneDay.vue:17`, `CalendarPhoneWeek.vue:56`, `CalendarPhoneMonth.vue:61` | `<CalendarHoursLine v-if="hoursLine(...)" ... compact ...>` in all three phone views | Working hours line on phone |
| `components/TopBar.vue:108-114` | `LazyHoursTimer` / `hours-timer-open` button in the header | timer in the header |
| `components/CalendarPhone.vue:237` | `data-test="calphone-menu-hours"` menu item | phone menu -> Hours |
| `hub/hours_me.go:202` | `func (s *Server) suggestHours(...)` | suggestion site for E2 |
| `components/CalendarHoursLine.vue:57,69,495` | `min-block-size: 28px` (desktop), `.cal-hours-line--compact { min-block-size: 44px; }`, `@media (max-width: 820px)` | 28/44 px, 820 px breakpoint |
| `components/CalendarHoursDay.vue:57,108,149-150,495` | `approve_today` ("Approve so far") button, `+15` button, `hours-day__stepper` with `−15`/`stepTo(-HOURS_STEP)`, `@media (max-width: 820px)` | M3/M5 taps, phone buttons |
| `components/CalendarHoursTeam.vue:36` | `data-test="hours-team-approve-all"` | Approve all |

All match. Supporting greps on `bc559b2f6`: `grep -ci norm` on `CalendarHoursTeam.vue` -> 2, on `utils/hours-team.mjs` -> 0 (the 23.3 claim); `bg.json` `hours_cal` -> 87 keys, en -> 87, identical-to-en -> 0; `people.hours_norm*` -> 3 keys in each of the 19 locale files; openapi.json lists `/v1/me/hours`, `/v1/hours`, `/v1/hours/periods`, `/v1/hours/export`, `/v1/hours/norm`, `/v1/members/{human_id}/hours/norm`; `store/hours.go:291,294,346` -> `HoursMemberNorms`, `SetHoursMemberNorm`, `HoursNormOf`; `auth/settings.go:96` -> `HoursNormDayMinutes *int json:"hours_norm_day_minutes,omitempty"`; `0125_calendar.sql:47-48` -> `calendar_events ... FORCE ROW LEVEL SECURITY`; `utils/realm-hours-api.mjs:8` -> "request naming a workspace (X-Spool-Tenant), so none is sent"; test files `store/hours_test.go:418` (`TestHoursMemberNorm`), `hub/hours_norm_test.go:94,129,143`, `tests/unit/hours-norm-member.test.mjs`, `tests/e2e/person-hours-norm.test.mjs` all exist; SPL-5558 commits `7a84257c1` (api) and `34c1072c2` (wui) are on origin/master (`git merge-base --is-ancestor` exits 0 for both).

**Built share, re-counted myself** on `bc559b2f6` from `tasks.md` (python over `- [x] Tnnn` / `- [ ] Tnnn` rows): 81 task rows total; v1 T001..T019: 18 built of 19 present, open = T010 (dropped in v1.2 per tasks.md:7); v2 T020..T070: 7 built of 51 (T020..T025, T065); v2.4 T071..T081: 1 built of 11 (T078). Build rows excluding T001 (spec) and T010 (dropped): 79, built 25 = 32%. Matches the author's "25 of 79" exactly. FRs: `grep -oE 'FR-[0-9]+a?' spec.md | sort -u | wc -l` -> 42; the "15 of 42" = FR-01..FR-13 (v1 loop, built per the T-rows) + FR-41 + FR-41a (built per SPL-5440/5558) is a fair classification, and the 42 is exact.

**Ran myself** (not copied): `go test ./internal/hub/ -run 'TestHoursExportCrossWorkspace|TestTeamHoursPermissions|TestTeamHoursNoLeak|TestHoursMemberNorm' -count=1` in the worktree at `bc559b2f6` -> `ok github.com/csitea/csi-spl/spool-hub-api/internal/hub 0.122s` (memory store, n=1). `ENV=dev ./run -a do_check_deploy_lag` and `ENV=prd ...` -> both: `hub current served=04ca1d89 sha=bc559b2f n=0`, `wui current served=8de1d37b sha=bc559b2f n=0`, so "built" is live on dev and prd at the base sha. Read-only prd queries (`ENV=prd SQL=... ./run -a do_spl_db_query`, counts only): csitea members 4, with `hours_norm_day_minutes` 0; workspace norm `hours.norm_day_minutes` 0; `hours_entries` last 30 days 378 rows from 2 distinct members; `hours_periods` 24 rows, 0 `approved`. All four match 23.1.

## Check 4 — effort table tap counts

Every "today" count I sampled has code behind it: M1 phone lines (`CalendarPhoneDay.vue:17`, `CalendarPhoneWeek.vue:56`, `CalendarPhoneMonth.vue:61`); M2 banner Approve N days / Approve week (`CalendarHoursDay.vue:24-33`, `:199-207`) plus the 0-tap sweep path (`hub/hours_sweep.go:36-40`); M3 "Approve so far" (`CalendarHoursDay.vue:57`, key `hours_cal.approve_today`); M5 ±15 stepper and +15 (`CalendarHoursDay.vue:108`, `:149-150`); M6 header timer (`TopBar.vue:108-114`); M11 active workspace, no workspace in the call (`utils/hours-calendar-api.mjs:17-30`, `hub/resolve.go:60,80`); M12 44 px compact / 28 px desktop / 820 px breakpoint (`CalendarHoursLine.vue:57,69,495`, `CalendarHoursDay.vue:495`), bg `hours_cal` 87 keys 0 identical to en; C1 People card (`pages/people/[id].vue:59`); C4 phone path (`CalendarPhone.vue:237`); C5 Approve all (`CalendarHoursTeam.vue:36`); C7 download component exists (`CalendarHoursDownload.vue`); C8 "not possible" matches T072/T079 open in tasks.md. 23.1 states plainly "From the code, not clicked" — no count is claimed as clicked. No count found without code behind it.

## Check 5 — the 2026-12-01 cut (23.7, spec.md:1409-1422)

Ordered (0..6), sized (M/S), phone-first with a live proof at 412x915 on dev then prd (T088/E8, spec.md:1406,1421). Together the rows cover the promise: a new untrained member gets prefilled working days (T082/E2), approves the week in 1 tap from the calendar (T083/E3) or 2 taps (E2), books the rest of the day in one Save (T087/E7); the biz owner sees approved against allocation in the Team tab (T085/E5) and approves all in 1 tap (C5, built); the workspace is named (T086/E6). Row 0 (no code: set the allocation on the People card) is built today (FR-41a). Nothing missing for the stated promise; FR-30 absences correctly in "later" (first row after the cut). See N1/N3 for two cosmetic gaps.

## Check 6 — owner questions Q30..Q33 (23.8, spec.md:1435-1442)

Four real owner decisions, each answerable A or B without reading the spec (one allocation vs two; prefill an empty working day vs leave empty; keep the sweep's auto-approve vs require a weekly tap; calendar-shows-workspace vs always primary), each with a recommended answer (header "A = the recommendation", spec.md:1435). All four pass.

## Check 7 — repo hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` on the reviewed tree -> `INFO distribution-hygiene: clean over the tracked tree`. `grep '^+'` over the v2.11 diff for `/home/`, domains, box tags, box names, env-project literals -> no matches. The only org literal is `csitea` (allowed), ids are HUM-*/msg ids.

## Defects

None. W1..: none.

## Notes

- N1 (spec.md:1416-1421): the new-row numbering skips T084 (T082, T083, then T085..T088); `grep -n 'T084' spec.md` at the reviewed sha -> no match. Cosmetic: define T084 or renumber.
- N2 (spec.md:922): the 2.11 version-log row sits between 2.10 and 2.6; the pre-existing log already had 2.6 after 2.10 (`grep -n '^| 2\.'` on the v2.10 file -> `... 2.9 2.10 2.6`), so the placement matches the file's own order. Cosmetic only.
- N3 (spec.md:1416-1421): the cut rows name no per-row test; the live proof T088/E8 covers the cut as a whole. Acceptable for a spec addendum; the build rows should each carry their test when queued.
- N4 (spec.md:1358): 23.4 honestly marks `TestRLSHoursScopes` (Postgres) as "not run in this review"; I ran the memory-store hub tests myself (ok, n=1) but not the Postgres RLS test. The route-level proof (403 cross-workspace, `hub/hours_export_test.go:134`) did run green.
- N5 (spec.md:1369): M1 scopes out "taps from the app start to the calendar" — stated openly, not hidden.

## ran:

`git ls-remote origin review/c002-spl5886-hours-minimal-effort-review`; `git log --oneline bc559b2f6..a49b3bc0e`; `git diff --stat bc559b2f6 a49b3bc0e`; `git diff bc559b2f6 a49b3bc0e -- spec.md` (4 hunks); `grep -o '"значи философията[^"]*"'` on spec and author brief + `diff` (identical); python quote check (9/9 IN-SPEC); 25x `git show bc559b2f6:<file> | sed -n <N>p`; greps: `grep -ci norm` (2 / 0), locale key counts (87/87, 0 identical; 3x19 people.hours_norm), `git grep approve_today`, openapi route grep, `git merge-base --is-ancestor 7a84257c1/34c1072c2 origin/master`; python checkbox count on tasks.md (81 rows, 25/79 built, 42 FRs); `go test ./internal/hub/ -run 'TestHoursExportCrossWorkspace|TestTeamHoursPermissions|TestTeamHoursNoLeak|TestHoursMemberNorm' -count=1` -> ok; `ENV=dev|prd ./run -a do_check_deploy_lag` -> served 04ca1d89/8de1d37b sha=bc559b2f n=0; 4x read-only `ENV=prd SQL=... ./run -a do_spl_db_query` (4 members/0 norm; 0 ws norm; 378 entries/2 members; 24 periods/0 approved); `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean; hygiene grep over the diff -> no matches; `lane-map.sh --check <spec dir> --agent m-564` -> exit 4 (unknown lanes, none owns this file; the file is this lane's named deliverable).
