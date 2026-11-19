# Review SPL-5886 — spec 107 v2.12 (mistral cross-vendor review)

- Reviewer: m-423 (mistral), 2026-11-19. Lane brief: spawn-remote brief `694dea5c-1a28-43cc-a4d1-39ac1750e36f` (placement `c002-spl5886-v212-mistral-reviewer`), issue SPL-5886, epic SPL-3036, author c-410 (report `72be5dd2`).
- Reviewed sha: `8575f2eeece57ed33b5c72ccde310010dda93fae` on branch `review/c002-spl5886-spec107-v212`. Only that sha was reviewed.
  - `git ls-remote origin review/c002-spl5886-spec107-v212` printed `8575f2eeece57ed33b5c72ccde310010dda93fae` — matches the author's report.
  - `git merge-base --is-ancestor cb56a8993 origin/master` → exit 0 (the base is on origin/master; origin/master has since moved to `f80db0b81`, `cb56a8993` remains an ancestor of it).
  - `git merge-base --is-ancestor cb56a8993 8575f2eeece57ed33b5c72ccde310010dda93fae` → exit 0.
  - `git diff --numstat cb56a8993 8575f2eeece57ed33b5c72ccde310010dda93fae` printed `98 24 csi-spl-doc/specs/107-hours-tracking/spec.md` and `17 5 csi-spl-doc/specs/107-hours-tracking/tasks.md` — matches the author's "+98 -24, +17 -5, 2 files".
- **Verdict: FAIL** on `8575f2eee` (one defect, W1). Every other check below passes.
- Re-review on the author's fix head `57c2a8f709e62f79a517ec1ca41c17cf19482bab`: **PASS** — see "Re-review on 57c2a8f70" below.
- Delta review on `96eeb4584c4f911bded8bef4096ac9528caa9c22` (Q34 = A fold on top of 57c2a8f70): **PASS** — see "Delta review on 96eeb4584" below.
- Final review on `03f8ee98389db6bf31b43cd75cde21567aa0cd70` (Q34 fold + N5 cleanup, delta 57c2a8f70..03f8ee98): **PASS** — see "Final review on 03f8ee98" at the end of this file.

## Check 1 — owner answers Q30..Q33 folded

Owner answers (HUM-10, csitea `4a2d2cc8`, msg `2cbfb662`, 2026-11-19, poll `8535cf7e`, quoted in c-410's lane brief): Q30 = A, one value per person, FR-41a's allocation is also FR-14's standard day (E1); Q31 = A, an empty working day is prefilled at the allocation, marked "no activity", counted only after the person's tap (E2, T082); Q32 = B, every week needs the person's own tap, nothing is auto-approved, reversing v1-Q2 = B; Q33 = A, hours go to the workspace the calendar shows, named in the dialog, personal calendar defaults to the primary workspace (E6, T086).

Q32 = B, place by place. Line numbers are `spec.md` at `8575f2eee`; each was read with `git show 8575f2eeece57ed33b5c72ccde310010dda93fae:csi-spl-doc/specs/107-hours-tracking/spec.md | sed -n <N>p`:

| place | line | reads B? |
|---|---|---|
| 4.2 freeze bullet | 303 | yes — "the sweep approves nothing (owner Q32 = B, v2.12, msg `2cbfb662`, section 23.9). This reverses v1-Q2 = B" |
| section 14 intro | 610 | yes — "v2.12: owner Q32 = B (msg `2cbfb662`, 23.9) reverses it: nothing is auto-approved" |
| FR-06 | 473 | yes — "v2.12, Q32 = B: the sweep approves nothing (23.9, T089)" |
| FR-07 | 474 | yes — adds the "not confirmed" Team-tab mark (23.9, T085) |
| FR-15 | 642 | yes — "The sweep auto-approves nothing (v2.12, owner Q32 = B, msg `2cbfb662`, 23.9; it reverses v1-Q2 = B and v2.0's evidence-only rule)" |
| 14.14 Rule 2 | 729 | yes — "approves the week with one tap (v2.12, Q32 = B: the sweep approves nothing); a day nobody tapped counts zero" |
| 21.3 item 2 | 1049 | yes — "v2.12 (owner Q32 = B, 23.9): the sweep approves nothing, so a suggestion nobody tapped never counts" |
| 23.3 built-behaviour bullet | 1322 | yes — keeps the built v1-Q2 = B statement (it describes the code as built) and appends "v2.12: owner Q32 = B ends this (23.9, T089)" |
| 23.3 M2 row | 1371 | yes — "(Q2 = B; Q32 = B ends it, T089)" |
| 23.5 C5 row | 1391 | yes — "Q32 = B: a frozen day nobody confirmed shows **not confirmed** (T085, 23.9)" |
| new section 23.9 | 1501 | yes — "Nothing is auto-approved; every week needs the person's own tap" |
| new row T089 | 1418 (23.7 table, order 2, right after T082 at 1417) and its 23.7.1 brief from 1426 | yes |

Old-wording sweep: `git grep -n -i -E 'auto-approv|v1-Q2' 8575f2eee -- csi-spl-doc/specs/107-hours-tracking/` — the remaining hits are only (a) historical records (section 18, the version table, the 23.8 question text at 1489, `reviews/s107-*.md`) and (b) "today, built" columns that carry an explicit v2.12 note (spec.md:1322, :1371; tasks.md:48 T007, :154 T044, :203). No place reads the old Q32 answer as the current rule.

- Q30 = A: folded in FR-14 (spec.md:641, row ends "v2.12, owner Q30 = A (msg `2cbfb662`, E1): one value per person ... No `hours.standard_day_minutes` key and no second per-person setting in the Crew tab") and in 23.8 (1496). **Not folded in tasks.md** — see W1.
- Q31 = A: folded — 23.7 T082 row (1417, "Q31 = A") and 23.8 (1497, "E2 is built: T082").
- Q33 = A: folded — 23.7 T086 row (1422, "Q33 = A") and 23.8 (1499, "E6: T086").

## Check 2 — code claims true on `cb56a8993`

Each cite was read with `git show cb56a8993:<file> | sed -n <N>p` (`api/` = `csi-spl-api/src/go/spool-hub-api/internal/`):

| cite | what the line printed | ok |
|---|---|---|
| `api/hub/hours_sweep.go:33` | `return hs.SweepHours(ctx, s.o.Now(), s.hoursOpenSuggestions, tenants...)` | yes — passes `hoursOpenSuggestions` |
| `api/hub/hours_sweep.go:36-93` | comment at :36, `func (s *Server) hoursOpenSuggestions(...)` at :40, closing brace at :93 | yes — the function spans :36-93 |
| `api/hub/hours_sweep.go:88-89` | `out = append(out, store.HoursEntry{Day: d, Target: tg, Minutes: n,` / `SuggestedMinutes: rows[tg].Minutes, State: store.HoursApproved})` | yes — state approved at :88-89 |
| `api/store/hours_sweep.go:257-264` | `if w.open != nil {` (:257), `if es, err = w.open(ctx, tenant, id, s, e); err != nil {` (:259), `created, pruned, err := st.freezeHoursPeriod(..., es)` (:263-264) | yes — calls it and writes those entries with the frozen period row |
| `api/store/hours_sweep.go:230` | `open   HoursOpenSuggestions // nil: open suggestions count zero` | yes — the nil count-zero path |
| `api/store/hours_sweep_test.go:15-16` | "With no HoursOpenSuggestions an unapproved suggestion counts zero; with one (owner Q2 = B) the open ..." | yes — the test covers it |
| `api/hub/hours_sweep_test.go:17` | `func TestHoursSweepAutoApprovesOpenSuggestions(t *testing.T) {` | yes |
| `api/hub/hours_sweep_test.go:38-39` | `if err != nil || len(es) != 1 {` / `t.Fatalf("a's entries = %v %v, want the one auto-approved row", es, err)` | yes — the base-tree red control |
| `api/hub/hours_team.go:111` | `es, err := c.team.HoursApprovedEntries(ctx, c.tenant.ID, q.member, from, to)` | yes — every approved entry per day |
| `api/hub/hours_team.go:213` | `NormDay: d.norms[id].Effective}` | yes — `members[].norm_day_minutes` |
| `csi-spl-rdb/src/sql/postgres/spool-hub/0151_hours.sql:52` | `state text NOT NULL CHECK (state IN ('approved', 'rejected')),` | yes — only approved/rejected |

Extra cites of my choice from the diff, same method, all ok: `api/hub/hours_me.go:80` (`func (c hoursMe) withMemberNorm(...)`), `:202` (`func (s *Server) suggestHours(...)`), `:346` (`func (p *hoursPeriod) dayJSON(...)`); `api/hub/hours_sweep.go:40` (the `hoursOpenSuggestions` func); `api/store/hours_sweep.go:16-18` and `:52-55` (the Q2 = B comments T089 rewrites); `wui/src/composables/useCalendarHours.ts:15` (`export type HoursRow = {...}`), `:78` (`export function useHoursWrite(...)`); `wui/src/utils/hours-mine.mjs:19` (`export const HOURS_ADD_DEFAULT = 30`), `:89` (`export function hoursApproveEntries(...)`); `wui/src/utils/hours-team.mjs:54` (`export function hoursTeamGrid(...)`); `wui/src/components/CalendarPhone.vue:393-396` (the `calphone-hours` inject comment); `wui/src/components/CalendarHoursDay.vue:24-33` (banner + approve-open button), `:74` (`hours_cal.empty`), `:199-207` (Approve week), `:371-378` (+ Add defaults to `HOURS_ADD_DEFAULT`); `wui/src/components/CalendarPhoneDay.vue:17`, `CalendarPhoneWeek.vue:56`, `CalendarPhoneMonth.vue:61` (the per-day Working hours line); `wui/src/pages/people/[id].vue:59` (`<PersonHoursNorm ...>`).

File existence for the 23.7.1 row briefs: every non-new file listed there exists on `cb56a8993` (`git cat-file -e cb56a8993:<path>` → ok for all 16), and `git ls-tree --name-only cb56a8993:csi-spl-wui/i18n/locales | wc -l` printed `19`, matching "all 19 files of `wui/i18n/locales/`".

## Check 3 — the 2026-12-01 cut (23.7 / 23.7.1)

- Table order (spec.md:1416-1424): 0 no-code, 1 T082, 2 T089, 3 T083, 4 T085, 5 T087, 6 T086, 7 T088 — T089 sits right after T082, as the author brief required.
- Row briefs (23.7.1, from spec.md:1426): T082, T089, T083, T085, T087 and T086 each list Files, a Test and a red control; T088 lists files and the live proof only (N2).
- Order constraint holds: 23.7.1 states "**T089 lands before T082, or T082 holds its push until T089 is on master**" (the sweep's `hoursOpenSuggestions` would otherwise approve T082's prefill at the freeze), and tasks.md:324 says "Lands with or after T089" — consistent, T089-before-T082 is explicit.
- Disjoint files where claimed: the shares table matches the per-row file lists — T089 shares none in the cut (later T044), T088 none, T083/T085 locales only, T082/T087/T086 share `CalendarHoursDay.vue` plus locales. All listed existing files verified to exist on `cb56a8993` (check 2).

## Check 4 — tasks.md

- T007 (tasks.md:48): v2.12 note appended — "**v2.12: owner Q32 = B reverses this; T089 removes it (spec 23.9).**" — as the spec says.
- T044 (tasks.md:154): the evidence rule is struck through with "(v2.12, owner Q32 = B: the sweep approves nothing, T089 removes `hoursOpenSuggestions`; spec 23.9)".
- T066 (tasks.md:188): Rule 2 reworded — "approved with one tap, v2.12 Q32 = B; an untapped day counts zero".
- The v2.12 cut list (tasks.md:320-330) matches the spec 23.7 order exactly: T082, T089, T083, T085, T087, T086, T088.
- No row lost: the T-id sets of tasks.md at `cb56a8993` vs `8575f2eee` (`git show <sha>:...tasks.md | grep -oE 'T[0-9]{3}' | sort -u | diff -`) differ by additions only: T082, T083, T085, T086, T087, T088, T089.
- W1 (see check 1): T026 and T070 were not amended although 23.8:1496 says they lose their standard-day setting.

## Check 5 — the open question (T082's prefill on a returned day)

Yes, it is a real owner decision, answerable A or B without reading the spec: under Q32 = B a returned week shows no suggestions (FR-04) and its tab minutes are pruned at the freeze, so the person types those hours again; whether T082's prefill should also appear on a returned day is a pure effort-vs-strict-reading choice. Proposed A/B wording:

- (A) T082's prefill also appears on a returned day: the day is open again and the allocation stands; the row is still marked `no_activity` and counts only after the person's tap.
- (B) FR-04 unchanged: a returned day shows no suggestions; the person types those hours again (strict Q32 = B reading: nothing is suggested on a day that is not closed).

## Check 6 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` printed "INFO distribution-hygiene: clean over the tracked tree", rc 0.
- The added lines of `git diff cb56a8993 8575f2eee` grepped for domain/URL/`/home/`/IP/box-name/user-name patterns: no matches.

## Defects

- **W1** — tasks.md:131 (T026) still registers `hours.standard_day_minutes` among the v2 workspace keys, and tasks.md:143 (T070) still has `PUT /v1/hours/people/{member}` setting "standard day or weekday pattern"; neither row carries a v2.12 note (`grep -n 'v2.12\|Q30'` over tasks.md at the sha hits only lines 48, 154, 188, 203, 320-322). This contradicts spec 23.8:1496 ("T026 and T070 lose their own standard-day setting") and FR-14's v2.12 sentence (spec.md:641: "No `hours.standard_day_minutes` key and no second per-person setting in the Crew tab"). Q30 = A is folded in the spec but not in these two task rows; a lane reading tasks.md would build the old two-value design.

## Notes

- N1 — spec.md:722 (section 15) still lists `hours_standard_days` (member overrides with effective date, FR-14) without a Q30 = A note; FR-14's "a weekday pattern or an effective date, when built, extends that one value" may justify the table, but the line is unannotated.
- N2 — T088's 23.7.1 brief carries files and the live proof but no explicit red control; acceptable for a proof-only row (the proof fails on the base tree by construction), flagged for the holder.
- N3 — FR-14's row body (spec.md:641) keeps the old mechanism text with the v2.12 negation appended in the same row; the negation is explicit, but the row reads contradictory until edited.
- N4 — `lane-map.sh --check csi-spl-doc/specs/107-hours-tracking/review-spl5886-v212-mistral.md --agent m-423` exits 4 (unknown lanes c-926, c-946, c-947 record no files; none lists this path); the lane brief assigns this exact file to m-423.

## Verdict

**FAIL** on `8575f2eeece57ed33b5c72ccde310010dda93fae` — W1. Everything else checked passes: Q32 = B reads B in every place the author lists, the code cites are true on `cb56a8993`, the cut rows carry files/test/red control with T089 required before T082, tasks.md T007/T044/T066 and the v2.12 cut list match the spec, and distribution hygiene is clean.

## Re-review on 57c2a8f709e62f79a517ec1ca41c17cf19482bab (2026-11-19, after the author's fix)

- `git ls-remote origin review/c002-spl5886-spec107-v212` printed `57c2a8f709e62f79a517ec1ca41c17cf19482bab`; `git log -1 --format='%H %P'` printed parent `8575f2eeece57ed33b5c72ccde310010dda93fae` — a fast-forward, no force.
- `git diff --numstat 8575f2eee 57c2a8f70` printed `3 3 spec.md`, `2 2 tasks.md` (2 files, +5/-5), matching the holder's quote and the author's report `59aa106d`. The whole fix diff (53 lines) contains only the four fixes below — nothing else changed, so every check 1..6 result on `8575f2eee` carries over unchanged.

Re-checks, each cite read with `git show 57c2a8f70:<file> | sed -n <N>p`:

- **W1 — fixed.** tasks.md:131 (T026) opens with "**v2.12, owner Q30 = A (spec FR-14, 23.8): drop `hours.standard_day_minutes` and the person's standard-day override with its weekday pattern from this row; the standard day is FR-41's `hours.norm_day_minutes` and FR-41a's `hours_norm_day_minutes`, already built. The other keys and the overtime override stay; the row is re-sized when it is next queued.**"; tasks.md:143 (T070) strikes "~~standard day or weekday pattern~~" with "v2.12 Q30 = A: dropped, the person's value is FR-41a's, set on the People card". Both rows now say they lose the standard-day setting, as spec 23.8:1496 claims.
- **N1 — fixed.** spec.md:722 (section 14.13) strikes "~~`hours_standard_days` (member overrides with their effective date, FR-14)~~ (v2.12, Q30 = A: dropped, the person's value is FR-41a's membership setting)".
- **N3 — fixed.** spec.md:641 (FR-14) is rewritten to read one way: "**Standard day, per organisation and per person: one value each** (v2.12, owner Q30 = A …)"; the organisation's value is FR-41's `hours.norm_day_minutes`, the person's is FR-41a's `hours_norm_day_minutes`, "There is no other standard-day key and no second per-person setting (no Crew-tab override)"; the old 098-key mechanism text is gone from the row.
- **N2 — fixed.** spec.md:1470 (T088 brief) now ends "Red control: run it once against a tree without T082 (or a member with allocation 0): the five-prefilled-days step must fail."
- **Nothing else added**: the `8575f2eee`→`57c2a8f70` diff touches only spec.md:641, spec.md:722, spec.md:1470, tasks.md:131, tasks.md:143.

New note:

- N5 — `git show 57c2a8f70:…spec.md | grep -n -o '.\{80\}hours\.standard_day_minutes.\{80\}'` hits spec.md:722 in the **unstruck** "New registered keys:" list on the same line as the struck table, and the same grep on tasks.md hits tasks.md:131 three times (the bold drop note, the register list "`hours.standard_day_minutes` (480, 0..1440)", and the red test "After: 450 accepted"). So the author's reports `59aa106d`/`60108cc9` ("grep hits only the struck lines") are not accurate: the key name survives unstruck in the 14.13 sketch key list and in T026's not-yet-resized body. Non-normative (14.13 is a "sketch, for the tasks round"; FR-14 is the authority and T026's note says the row is re-sized when queued), so a note, not a defect.

## Re-review verdict

**PASS** on `57c2a8f709e62f79a517ec1ca41c17cf19482bab` — W1, N1, N2, N3 fixed, the fix adds nothing else, N5 recorded.

## Delta review on 96eeb4584c4f911bded8bef4096ac9528caa9c22 (2026-11-19, Q34 = A fold)

- `git log 8575f2eee..96eeb4584` shows exactly two fast-forward commits: `57c2a8f70` (the W1/N1/N2/N3 fixes, reviewed PASS above) and `96eeb4584` ("folds owner Q34 = A, a returned period shows suggestions again", parent `57c2a8f70`).
- `git diff --numstat 8575f2eee 96eeb4584` → `14 12 spec.md`, `3 3 tasks.md`; the Q34 commit alone (`57c2a8f70..96eeb4584`) → `11 9 spec.md`, `1 1 tasks.md`, 10 spec hunks + 1 tasks hunk, all of them Q34 — the delta adds nothing else, so every earlier check carries over.
- Owner answer as quoted by the dispatch holder: HUM-10 `ffa470cd` answered poll `e815cf44` with "A — Yes: show the suggestions again, counted only after the tap". The 23.8 question row (spec.md:1491) quotes option A with exactly those words.
- The wider reading — a returned period computes suggestions as an open one does, each counted only after the tap — is the same in every place the holder named, each read with `git show 96eeb4584:<file> | sed -n <N>p`:
  - 2.2 item 2, spec.md:173 — "a returned period shows suggestions again, as an open one does, each counted only after the tap"
  - 4.3 Return, spec.md:310 — "with suggestions again, 2.2, counted only after the tap"
  - FR-04, spec.md:471 — "none for frozen days (v2.12, Q34 = A: a returned period shows them again, counted only after the tap, 23.9)"
  - 23.9 "What it means for the person", spec.md:1518 — the open question is replaced by the answer: "a returned period shows suggestions again … the meetings and T082's prefill, each counted only after the tap … FR-04, 2.2 and 4.3 say so; T082 builds it"
  - 23.7.1 T082 brief, spec.md:1444 — "nor a frozen day" (the returned-day exclusion is gone) and "Q34 = A: a returned period gets suggestions again, the prefill included"; the test adds "the same Monday in a returned period -> the same row, counted 0 until approved (red on the base tree)"
  - tasks.md T082, tasks.md:324 — "Q34 A: also in a returned period"
  - plus the status line (spec.md:3), the version-log 2.12 row (:923), and the 23.8 answered table (:1493, :1501)
- Old wording: `grep -n 'frozen or returned\|no suggestions'` at `96eeb4584` hits only spec.md:540, the historical v1 panel table the author explicitly left unchanged — correct.
- Code sites for T082's Q34 change, true on `cb56a8993` (`git show cb56a8993:… | sed -n <N>p`): `api/hub/hours_me.go:189-196` — comment at :189 "No suggestion for a frozen day nor in a returned period (spec 2.2)", `if !open || p.returned() {` at :195, `return p, nil` at :196; and :577 "// entry already held (a returned period has no suggestions), else 0".
- Hygiene: the delta's added lines carry no domain/URL/`/home/`/IP literals; `do_check_dist_hygiene` clean rc 0.
- Observation: the branch head has since moved to `03f8ee98` ("strikes the last three `hours.standard_day_minutes` mentions (Q30 = A)"), which addresses N5 above. This verdict is on `96eeb4584` as instructed.

## Delta-review verdict

**PASS** on `96eeb4584c4f911bded8bef4096ac9528caa9c22` — Q34 = A folded consistently in 2.2, 4.3, FR-04, 23.9, 23.7.1 and tasks.md T082, matching the answer's words; the delta adds nothing beyond the reviewed fixes and the Q34 fold; code sites true on `cb56a8993`; hygiene clean.

## Final review on 03f8ee98389db6bf31b43cd75cde21567aa0cd70 (2026-11-19, Q34 fold + N5 cleanup)

- `git ls-remote origin review/c002-spl5886-spec107-v212` printed `03f8ee98389db6bf31b43cd75cde21567aa0cd70` — the final head the holder named (msg `abe77f64`).
- `git log --oneline 57c2a8f70..03f8ee98` shows exactly two commits, both fast-forward on `57c2a8f70`: `96eeb4584` (Q34 = A fold, reviewed PASS above) and `03f8ee983` ("strikes the last three `hours.standard_day_minutes` mentions (Q30 = A)", author report `64b0b069`).
- `git diff --numstat 57c2a8f70 03f8ee98` → `12 10 csi-spl-doc/specs/107-hours-tracking/spec.md`, `2 2 csi-spl-doc/specs/107-hours-tracking/tasks.md` (2 files, +14/-12), matching the holder's quote. `git diff --name-only` lists only those two files.
- The cleanup commit alone (`git diff 96eeb4584..03f8ee98`) is `1 1 spec.md`, `1 1 tasks.md` with exactly two hunks, `@@ -719,7 +719,7 @@` (spec.md:722) and `@@ -128,7 +128,7 @@` (tasks.md:131). The remaining 11/9 + 1/1 of the delta is the Q34 commit already reviewed PASS on `96eeb4584`. The delta `57c2a8f70..03f8ee98` adds nothing else.
- Q34 = A reads the same at `03f8ee98` as at `96eeb4584` in every place the holder named, each read with `git show 03f8ee98:<file> | sed -n <N>p`:
  - 2.2 item 2, spec.md:173 — "**a returned period shows suggestions again**, as an open one does, each counted only after the tap"
  - 4.3 Return, spec.md:310 — "Q34 = A: with suggestions again, 2.2, counted only after the tap"
  - FR-04, spec.md:471 — "a returned period shows them again, counted only after the tap, 23.9"
  - 23.7.1 T082 brief, spec.md:1444 — "**Q34 = A (msg `ffa470cd`): a returned period gets suggestions again, the prefill included**: drop the `p.returned()` skip in `loadHoursPeriod` (`api/hub/hours_me.go:189-196`, the check at `:195`) and fix the write path's comment that a returned period has none (`:577`)"
  - 23.9 "What it means for the person", spec.md:1518 — "**a returned period shows suggestions again** (owner Q34 = A, msg `ffa470cd`, poll `e815cf44`): the meetings and T082's prefill, each counted only after the tap"
  - tasks.md T082, tasks.md:324 — "Q34 A: also in a returned period"
  - 23.8 question row, spec.md:1491, quotes option A verbatim: "Yes: show the suggestions again, counted only after the tap" — the exact words of HUM-10 msg `ffa470cd` answering poll `e815cf44`.
- Code sites for T082's Q34 change, true on the base `cb56a8993` (`git show cb56a8993:csi-spl-api/src/go/spool-hub-api/internal/hub/hours_me.go | sed -n <N>p`; the spec cites the file as `api/hub/hours_me.go`): :189 comment "No suggestion for a frozen day nor in a returned period (spec 2.2).", :195 `if !open || p.returned() {`, :196 `return p, nil`, :577 "// entry already held (a returned period has no suggestions), else 0".
- N5 cleanup verified: `git grep -o 'hours.standard_day_minutes' 03f8ee98 -- csi-spl-doc/specs/107-hours-tracking/` → 4 occurrences, the same 4 as at `57c2a8f70`. At `03f8ee98` three are struck: spec.md:722 "~~`hours.standard_day_minutes`~~ (v2.12, Q30 = A: dropped, FR-41's key)"; tasks.md:131 register list "~~`hours.standard_day_minutes` (480, 0..1440)~~ (v2.12, Q30 = A: dropped)"; tasks.md:131 red test "~~a tenant settings write of `hours.standard_day_minutes = 450` is refused as an unknown key on `3724f6dc2` …~~ (v2.12, Q30 = A: dropped; the red uses another key of this row, refused as unknown on the base tree, then accepted in range and refused out of range)". The fourth, the drop note itself at tasks.md:131 ("drop `hours.standard_day_minutes` and the person's standard-day override with its weekday pattern from this row"), stays unstruck on purpose — it is the Q30 = A instruction, not a stale mention.
- Hygiene: `git diff 57c2a8f70 03f8ee98 | grep '^+' | grep -nE 'https?://|/home/|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'` → no hits; `do_check_dist_hygiene` clean rc 0.

## Final-review verdict

**PASS** on `03f8ee98389db6bf31b43cd75cde21567aa0cd70` — the delta `57c2a8f70..03f8ee98` is exactly the Q34 = A fold (already PASS on `96eeb4584`) plus the N5 cleanup striking the three stale `hours.standard_day_minutes` mentions; Q34 = A reads the same in 2.2, 4.3, FR-04, 23.9, 23.7.1 (T082) and tasks.md T082, matching the owner answer's words; the T082 code sites are true on `cb56a8993`; hygiene clean; nothing else changed.
