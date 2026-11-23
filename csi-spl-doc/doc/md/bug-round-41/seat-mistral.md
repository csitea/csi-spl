# Bug round 41 — panel seat mistral (m-154@<box2>)

Issue: SPL-6305 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/fa515e0d-4cc4-44d6-a8f2-dab56d04af0f.md`.
Review target: `csi-spl-doc/doc/md/bug-round-41-plan.md` on branch
`review/c002-bug-round-41-planner`, at the plan version sha
`ba1057c583180250b8bd7f757a0d39502cb4f81d` (v0.1), named by the brief (planner
c-136@<box2>). `git ls-remote origin refs/heads/review/c002-bug-round-41-planner`
-> exactly that sha, still the branch head at my check (2026-11-23T12:4xZ). The
branch is one docs commit on `bce008e61`:
`git rev-list --count origin/master..ba1057c5` -> `1`,
`git merge-base origin/master ba1057c5` -> `bce008e61949c09f847a6d3b008804cc8df71b65`,
`git show ba1057c5 --stat` -> `csi-spl-doc/doc/md/bug-round-41-plan.md | 251 +++...`,
1 file changed, 251 insertions — the "+251" the brief names. `origin/master` at
my fetch: `bce008e61949c09f847a6d3b008804cc8df71b65` (the plan's measurement sha).
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the
panel is a non-claude seat; this seat writes no code). Form:
`csi-spl-doc/doc/md/bug-round-40-plan.md` on origin/master. Every file:line below
was printed with `git show bce008e61:<file> | sed -n <N>p` (or the stated command)
before it is cited; every `ran:` line was run by me on this box, 2026-11-23
12:4xZ..12:59Z.

**Verdict: PASS, 2 rows, on `ba1057c583180250b8bd7f757a0d39502cb4f81d` (v0.1).**
No defect W; notes N1..N5 below.

## Check 1 — slug b41 unused since the plan's W

W per the plan: `2026-11-23T11:56:44+02:00`, commit `8f6f545e7`
(`git show -s --format='%H %cI %s' 8f6f545e7` ->
`8f6f545e7ae1b3c78e288f176639bd3e27c47733 2026-11-23T11:56:44+02:00 docs(b40-plan, SPL-6288): bug round 40 plan v1.0 signed, ...`;
`git log origin/master --format='%H %cI %s' -E --grep='^docs\(b40-plan' | head -3`
shows `7024772b1` at `2026-11-23T14:18:36+02:00` is the later b40 close commit, so
the plan's read-once W stays `8f6f545e7`'s date, as rulebook 5.3 says).

- `git log origin/master --since="2026-11-23T11:56:44+02:00" --oneline -E --grep='\(b41-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'b41-[0-9]{2}|bug-round-41'` ->
  `ba1057c583180250b8bd7f757a0d39502cb4f81d\trefs/heads/review/c002-bug-round-41-planner`
  only — the planner's branch, expected; this seat's review branch did not exist
  yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b41-[0-9]{2}|bug-round-41'` ->
  no match (rc 1): the dir is readable here (3280 entries) but holds no
  b41-named brief. `grep -lE 'b41-[0-9]{2}|bug-round-41' /var/spool-hub/spawn-remote/briefs/*.md`
  -> exactly two b41 briefs: `28d9692a-...md` (the planner's) and
  `fa515e0d-4cc4-44d6-a8f2-dab56d04af0f.md` (this seat's) — both expected.

## Check 2 — the two defects are real on `bce008e61` (every cited file:line printed)

b41-01 (`csi-spl-orc/src/bash/run/check-deploy-lag.func.sh`,
`.github/workflows/00_deploy-lag-watch.yml`):

- `check-deploy-lag.func.sh:194` -> `  if [[ "$age_min" -lt "$grace" ]]; then`
  (the grace check); `:198-201` -> the SPL-5641 hold comment ("Inside that
  window the lag is planned, not stuck: pending."); `:202-216` -> the
  `held`/`devhold` logic ending in `if ((held > 0)); then ... return 0`;
  `:218` -> `  echo "$ENV $comp lagging served=... age=${age_min}m grace=${grace}m age_from=$from url=$url"`
  — one second after the hold ends the verdict is `lagging`, rc 3 (`:219`).
  Matches the plan's description.
- Header `:32` -> `# @description GRACE_MINUTES keeps a just-pushed commit out of the verdict: the`,
  `:66` -> `# @param HUB_DEPLOY_COALESCE_MIN - optional: hub rollout hold in minutes (default 120, 0 = off); a younger served build reads pending held=<m> (SPL-5641)`.
  Matches.
- `00_deploy-lag-watch.yml:187-188` -> `# red, and GRACE_MINUTES keeps a roll that is still in flight out of the` /
  `# verdict. No GCP call, no credential, nothing mutated: one HTTPS GET per` —
  the comment the plan quotes. `:222` -> `GRACE_MINUTES: ${{ vars.DEPLOY_LAG_GRACE_MINUTES || '45' }}`.
  `:247` -> `echo "::error::$ENV does not serve ... Roll it (hub: bump cnf env.hub.image.tag, then 030 through make do-provision; WUI: dispatch 30) and re-run. ..."`
  — the hand-roll error text the plan says is stale. Matches.
- `21_hub-deploy-catchup.yml:45` -> `    - cron: '7,22,37,52 * * * *'` — the
  15-min catch-up. `20_hub-build-deploy.yml:443` -> the HUB_DEPLOY_COALESCE_MIN
  comment, `:487` -> the `held -- ... then 21's catch-up rolls trunk head (SPL-5641)`
  warning. `csi-spl-orc/src/bash/scripts/hub-deploy-coalesce.sh:35` ->
  `coalesce_hold() {`, `:55` -> `}`. `check-deploy-lag.tst.sh:104` ->
  `# 2b. the 2-hour rollout hold (SPL-5641): ...`, `:109` ->
  `lag_one "CONTROL: the same lag, served build 130 min old -> RED" ... 45 3 lagging`,
  `:110` -> the `HUB_DEPLOY_COALESCE_MIN=0` case. All match.

b41-02 (`csi-spl-api/src/go/spool-hub-api/internal/calrecur/calrecur.go`):

- `calrecur.go:127` -> `func (r *Rule) setPart(key, val string) error {` with the
  switch on FREQ/INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY/BYMONTH and
  `:144` -> `err = badRule("%s is not supported", key)` in `default:` — so WKST
  is refused with `WKST is not supported`; `:146` -> `return err`. Matches.
- `calrecur.go:53-62` -> `type Rule struct {` ... `}` (no wkst field).
  `:250` -> `func (r Rule) option(start time.Time, loc *time.Location) rrule.ROption {`,
  `:255` -> `Wkst:       rrule.MO,` — the literal the plan says the fix replaces.
  Matches.
- `calrecur_test.go:57` -> `refused := []string{`, `:73` -> `"FREQ=WEEKLY;WKST=SU",`,
  `:94` -> `for _, s := range refused {`. Matches: the test pins WKST=SU as refused.
- `gcal_sync_in.go:286` -> `func GcalSpoolOf(it gcal.Event, human string) store.CalendarEvent {`,
  `:296-299` -> the `for _, r := range it.Recurrence { if strings.HasPrefix(r, gcalRRulePrefix) { e.RRule = strings.TrimPrefix(...) ...` —
  the RRULE is mapped as-is. `store/calendar_series.go:32` ->
  `func calendarSeriesOf(e *CalendarEvent) (calrecur.Series, error) {`, `:36` ->
  the `calrecur.ErrBadRule` trim. `gcal_sync_sources.go:220` ->
  `if err != nil && !errors.Is(err, store.ErrInvalidCalendarEvent) {` and `:222-224` ->
  the `Log.Warn()...Msg("gcal: google event of an existing calendar not written to spool")`
  — a refused event is warn-only, the sync token moves past it. Matches.
- `csi-spl-doc/specs/097-calendar-full-editing/spec.md:299-303` -> the subset
  list ending "That covers every choice in Google's \"Custom\" repeat\ndialog." — matches the plan's 4.4 claim.
  `csi-spl-doc/specs/149-google-calendar-connect/spec.md:244` ->
  `` `rrule` <-> `recurrence` (only `RRULE:` lines; ... `` — matches.

## Check 3 — red controls extracted, hashed, run on `bce008e61` in a scratch copy

Extracted the two `bash` fences of plan section 4 into scratch files:
`sha256sum` ->
`bc3dd1f30c32489c8f557e55a4bb1a49f1948c4b77cdbbf79df39f06edf9c19d  rc01-b41.sh` (1761 B, first 12 hex `bc3dd1f30c32`)
and
`31eb5df69de38f31cf85a6821e6817315566cfbb9cbde6d9b9b54fe6e802f907  rc02-b41.sh` (2192 B, first 12 hex `31eb5df69de3`)
— both exactly the hashes and sizes the plan names.

- `bash rc01-b41.sh bce008e61` (run from the worktree; the script `git archive`s
  the sha into a `mktemp -d` and edits only that copy) ->
  `FAIL: rc01 b41: hold ended 10 min ago -> pending: rc=3 want 0, out='dev hub lagging served=48b7696a sha=9af3407b n=2 oldest=7a74ae14 age=400m grace=45m age_from=commit:gh-api-failed url=file:///tmp/tmp.*/b41h130.json' ...`
  / `rc01 after-hold-10m: lagging` /
  `PASS: rc01 b41 CONTROL: hold ended 180 min ago -> lagging (lagging, rc 3)` /
  `rc01 after-hold-180m: lagging` /
  `rc01 sha=bce008e61 suite: FAILED: 1`, **exit 1** — identical to the plan's
  bce008e61 row. Red on the defect, control (hold ended 180 min ago) reads
  `lagging` as it must.
- `bash rc02-b41.sh bce008e61` (same scratch pattern, drops a Go test into the
  archived tree's `internal/hub` and runs `go test` there) ->
  `rc02 wkst: rrule="FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO,WE" got=refused: calrecur: rule outside the supported subset: WKST is not supported want=taken` /
  `rc02 control: rrule="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE" got=taken want=taken` /
  `--- FAIL: TestB41GoogleWeeklyRuleWithWKSTIsTaken (0.00s)` /
  `rc02 sha=bce008e61 rc=1`, **exit 1** — identical to the plan's bce008e61 row.
- Live state: neither script touches the hub, prd, GitHub, a calendar or the
  spool. rc01 runs the archived tree's own test file against a `file://`
  fixture in a synthetic repo (its `gh` is the test's stub: `age_from=commit:gh-api-failed`);
  rc02 runs `go test` inside the `mktemp -d` copy and reads nothing outside it.
  Both `trap rm -rf` their temp dir.

## Check 4 — the evidence, re-read read-only

- wf 00: `gh run list --workflow 00_deploy-lag-watch.yml --limit 40 --json databaseId,conclusion,startedAt`
  -> 40 runs: 29 success, **11 failure**; the failed runs are
  44967708480 (2026-11-22T00:39:45Z) .. 45117169034 (2026-11-23T05:20:36Z);
  `gh run list --workflow 00_deploy-lag-watch.yml --limit 5` -> newest runs
  45138435733 (08:25:03Z) .. 45174043794 (12:24:44Z) all `success` — green since
  06:35Z, as the plan says. Run 45117169034's two failed jobs
  (`gh api repos/csitea/csi-spl/actions/runs/45117169034/jobs`, then `.../jobs/<id>/logs`)
  print `prd hub lagging served=751b083a sha=ce334b04 n=1 oldest=ce334b04 age=133m grace=45m age_from=landed url=https://api.spool-hub.ai/version`
  and the `dev` twin — `held` absent, verbatim the plan's end-to-end case, and
  the `::error::` text is the hand-roll instruction of `:247`.
- prd WARNING (read-only log tail, no write): `ENV=prd FRESHNESS=72h LINES=1000 FORMAT=json FILTER='jsonPayload.err:"WKST"' ./run -a do_gcp_tail_logs`
  -> 8 entries, all `"err": "invalid calendar event: rrule: WKST is not supported"`,
  timestamps 2026-11-21T11:25:05Z..2026-11-23T07:55:28Z, spread over 5
  workspaces, 3 of the entries in t1. (A `textPayload:"WKST"` filter returns `[]` —
  the field lives in `jsonPayload.err`; the plan's own source-6 filter did not
  use textPayload, so it saw them.) The plan's 6.5 h/3000-cap window saw 1 (t1);
  my wider 72 h read sees 8 across 5 tenants — the defect is broader than the
  plan's window, the row is unaffected. No connection id, member or calendar
  content is recorded here, per the brief.

## Check 5 — the rows

- Disjoint (R1): row 01's files are `check-deploy-lag.func.sh`,
  `check-deploy-lag.tst.sh`, `00_deploy-lag-watch.yml` (reads
  `hub-deploy-coalesce.sh`); row 02's are `calrecur.go`, `calrecur_test.go`,
  `gcal_map_test.go`, `specs/097-calendar-full-editing/spec.md`. No shared file;
  both batch 1. Matches the plan's R1 line.
- Narrow fix scope: b41-01 — after the hold ends the lag stays `pending` for a
  catch-up allowance (`LAG_CATCHUP_MINUTES`, default ~70 from the measured
  25 min tick gap + 42 min roll), then `lagging`; the CONTROL case at
  `check-deploy-lag.tst.sh:109` moves past hold + allowance; only the wf 00 error
  text changes besides `_spl_lag_one`. b41-02 — `WKST=MO|..|SU` one day only,
  default `MO` (today's behaviour at `calrecur.go:255`), anything else stays
  `ErrBadRule`; no store, migration or WUI change. Both scopes match the code I
  read; neither changes behaviour beyond the defect.
- Red controls prove the defect and turn green on a correct fix: rc01 red
  (after-hold-10m `lagging`, want `pending`) with the after-hold-180m control
  `lagging` — a fix that keeps `pending` until hold + allowance turns the first
  green and leaves the control red-as-expected; rc02 red (WKST refused) with the
  no-WKST control `taken`. I ran both on `bce008e61` (check 3).
- No row should be cut or merged: 2 rows, within the 1..3 owner order, each with
  reproduced evidence and a reproduced red control.

## Check 6 — inputs accounted for

- The plan's section 2 lists 9 sources; section 3.3 re-reads round 40's 7 first
  inputs (from `bug-round-40-plan.md` section 7 on origin/master: the selector's
  composed testids, the `monitoring-costs` hr-tab flake, the 6 reopened epic
  issues, SPL-6277 N2, SPL-6174's relay hash, b34-01 N2 + SPL-6212 N2, r87-01 N2)
  — every one is accounted for in the b41 plan's section 3.3 table.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (sections "next BUG
  round" and "Bug-shaped"): **NOT RUN** — the file is sat-only and is absent on
  this box (`ls /var/spool-hub/dispatch/c002-next-round-candidates.md` -> No such
  file or directory; `find /var/spool-hub -maxdepth 3 -name '*next-round*'` ->
  nothing). No bug-shaped input I could read on this box is left unserved and
  unaccounted.

## Check 7 — R3 lane map and the neighbouring lanes

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-41-plan.md,csi-spl-orc/src/bash/run/check-deploy-lag.func.sh,csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh,.github/workflows/00_deploy-lag-watch.yml,csi-spl-orc/src/bash/scripts/hub-deploy-coalesce.sh,csi-spl-api/src/go/spool-hub-api/internal/calrecur/calrecur.go,csi-spl-api/src/go/spool-hub-api/internal/calrecur/calrecur_test.go,csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_map_test.go,csi-spl-doc/specs/097-calendar-full-editing/spec.md --agent m-154`
  -> **exit 3**, naming exactly one path:
  `csi-spl-doc/doc/md/bug-round-41-plan.md owned by c-136@<box2> c-136-c002-bug-round-41-planner (changed in its worktree; no files recorded)`
  — the planner's own plan file, expected; this seat reviews it read-only and
  never edits it. None of the 8 row files is owned by a live lane.
- Neighbouring lanes, `git diff --name-only $(git merge-base origin/master origin/<b>) origin/<b> | grep -cE 'check-deploy-lag|00_deploy-lag-watch|hub-deploy-coalesce|21_hub-deploy-catchup|calrecur|gcal_sync_in|gcal_map|specs/097'`
  -> `review/c002-refactor-round-92-planner`: **0** (its diff is only
  `csi-spl-doc/doc/md/refactor-round-92-plan.md`; its rows r92-01
  `spl-search-speed-probe.func.sh` and r92-02 `box-go-switch.func.sh` are
  different files from every b41 row file);
  `review/c002-costs-month-range`: **0** (cost_* hub files, wui i18n, specs);
  `review/c002-costs-share-route`: **0** (cost_splits, spl-cost-*, rdb 0313);
  `review/c002-lane-mix-gct-language-rule-drift`: **0** (`spl-lane-mix.func.sh`,
  its test, `check-fleet-rules-drift.func.sh` + test, the fleet pins). No b41 row
  file is touched by any of them.

## Check 8 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain`, `ok - hidden workspace or private literal (SPL-1874)`,
`ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-154`,
**exit 0**.

## Defects

None. **W: none.**

## Notes

- N1: plan section 3.1's parenthetical "11 of 40 runs red (2026-11-21T20:17Z..2026-11-23T11:17Z)"
  reads as the red-run span; my re-read puts the 11 red runs at
  2026-11-22T00:39:45Z..2026-11-23T05:20:36Z (the parenthetical is the 40-run
  window the planner read at 12:2xZ, which ended at the 11:17Z run). Source 5's
  range (11-22T00:39Z..11-23T05:20Z) matches my read exactly. Count 11 of 40 and
  the per-run detail are correct; wording only.
- N2: the prd WKST WARNING lives in `jsonPayload.err`, not `textPayload`
  (check 4): a `textPayload:"WKST"` filter returns `[]` over 72 h. The plan's
  source-6 filter did not use textPayload, so its count stands; a future reader
  filtering on textPayload would miss these lines.
- N3: `/var/spool-hub/dispatch/c002-next-round-candidates.md` is sat-only and
  absent on this box (check 6, NOT RUN here); the round-40 section-7 chain is fully
  accounted in the plan's section 3.3.
- N4: lane-map exit 3 names only the plan file itself (owner c-136@<box2>, the
  planner); the 8 row files have no live-lane owner on any machine the hub
  answered (check 7).
- N5: the plan's W handling is consistent with rulebook 5.3 read-once:
  `git log origin/master -1 -E --grep='^docs\(b40-plan'` now returns `7024772b1`
  (2026-11-23T14:18:36+02:00, the b40 close), while the plan's W is
  `8f6f545e7` (2026-11-23T11:56:44+02:00, the b40 v1.0) — both verified present
  with those dates; my slug check used the plan's W and found 0 b41 commits.

The verdict stands: **PASS, 2 rows, on `ba1057c583180250b8bd7f757a0d39502cb4f81d` (v0.1).**
