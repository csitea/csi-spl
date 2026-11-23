# Bug-fix round 41 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6305 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `ee2cb369-ac12-4bf4-b84c-f66ad15d5b27` ("Bug round 41", opened by c-002@sat 12:04Z). Round 40 ([bug-round-40-plan.md](bug-round-40-plan.md)) served both rows (b40-01 `031b2b04e`, b40-02 `c94af8e0c` + `88ba4f05e`) and closed (`7024772b1`).  
Round focus: as in round 40, the inputs are widened past wf 10: the prd error and warning logs, the prd alert incidents, the open bug issues, the CI runs of EVERY workflow on master (round 40 read wf 10 only), and the R7 notes of the lanes landed since W. Both rows come from sources round 40 did not read: the other workflows (row 01) and the prd WARNING log (row 02).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-40-plan.md](bug-round-40-plan.md).

**Status: v0.1, draft for the panel.**

Editor: **c-136@`<box2>`** (claude, `specs_and_docs`).  
Panel: to be placed by the holder (rulebook 3.2), a non-claude vendor.

**One sha:** every count below is measured on **`bce008e61`** (`origin/master` at this seat's last fetch, 2026-11-23T12:32Z), on `<box2>`, 12:17Z..12:36Z on 2026-11-23, unless a line says otherwise. The first reads (lane map, queue, CI report, rc01 and rc02 first runs) ran on `85f0e60fc` / `7024772b1`; the two commits between (`7024772b1`, `bce008e61`) are docs-only plan updates of rounds b40 and r91, none of this plan's sites (`git diff --name-only 85f0e60fc bce008e61` -> 3 files under `csi-spl-doc/doc/md/`: the b40 plan, its seat file and the r91 plan). n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b40-plan')` read at 12:18Z -> `Window: W=2026-11-23T11:56:44+02:00` (commit `8f6f545e7`). (`7024772b1`, the b40 close at 14:18+02:00, is a later `docs(b40-plan` commit; 5.3 says the window is read once, when the round opens, so W stays `8f6f545e7`'s date.)

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 40. The public repo does not name it.

---

## 1. How to read this

- Since round 40 measured (`2286c85ce`), `origin/master` moved by 14 commits (`git log --oneline 2286c85ce..bce008e61 | wc -l` -> 14): the b40 rows and plan, the r91 rows and plan, SPL-6285 (Settings "Google Sync"), SPL-6297 (cnf, People API).
- **Paths** are repo-relative. Line numbers are as of `bce008e61`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- Both red controls are scripts printed in section 4. Each extracts the named sha's tree with `git archive` into a `mktemp -d` dir and changes nothing in the checkout.

---

## 2. Where rows could come from (measured on `bce008e61`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=26h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (12:18Z) | 117 entries, 2026-11-22T10:22Z..2026-11-23T11:50Z: 11 hub `issue backlog` (`conflict`, t1, the last 11:09:08Z, hub 3.2.3..3.4.1); 3 Cloud Run request errors (18:45Z, 21:53Z x2); 103 Cloud SQL statement errors as the hub's runtime user | **0 rows.** The 11 `issue backlog` lines are b40-01's defect, all before its fix was served: `031b2b04e` landed 11:13:41Z, `ENV=prd SHA=031b2b04e ./run -a do_check_deploy_lag` -> `prd hub current served=031b2b04` (12:1xZ); none after 11:09Z. The 3 request errors: no repeat, no incident (source 2). The 103 SQL errors are hand-written reads: `FILTER='... textPayload:"STATEMENT" ...'` over 09:57Z..10:13Z -> 51 statements, 48 of them three polls of `messages` by task id (`ts > ''` x18, `ts > (select ts from messages where id=...)` x15 x2), the shape of a seat watching a topic with `do_spl_db_query`; no hub or action code builds them (`git grep -n "from_id not like 'HUM%'" bce008e61` -> 0). Not a row. |
| **2. prd alert incidents** | `ENV=prd SINCE=26h ./run -a do_gcp_list_alert_incidents` (csi-spl-iac, 12:19Z) | 9 policies, 0 incidents in 2026-11-22T10:19Z..2026-11-23T12:19Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, ... from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (read-only, 12:20Z) | 14 issues; 1 new since round 40: SPL-6291 (`blocked`, Settings -> Contacts for any Google member, the holder's; its cnf half `de4090a46` SPL-6297 landed) | **0 rows.** Each is its lane's or the holder's. The 8 issues round 40 found `wip` with a landed fix are b40-02's subject; its fix is forward-only (round 40 section 5, "After b40-02 lands"). |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (12:17Z..12:23Z) | 100 runs, 2026-11-22T08:45Z..2026-11-23T11:53Z: 79 success, 15 cancelled, 5 failure, 1 running; the same 5 failed runs as round 40 (`box-seat-counts` x2, iac tfvars parity x2, `monitoring-costs` x1, the last 06:33Z); every failed job green since run 45167963469 on `b2edf8c7` (11:45Z); every job's p90 under 75 % of its timeout (the highest, hermetic 1/4, 59 %) | **0 rows**, as round 40 read them: two fixed, `monitoring-costs` still 1 sighting (carried). |
| **5. CI, every other workflow on master** (new) | `gh run list --branch master --status failure --limit 40`, then per workflow `gh run list --workflow <file> --limit 40` (12:2xZ) | since 2026-11-22T08:00Z: `00_deploy-lag-watch.yml` 11 of 40 runs red (11-22T00:39Z..11-23T05:20Z, green since 06:35Z); `50_oss-standalone.yml` 3 red on 11-22 (15:54Z..16:35Z), green on its 12 runs since | **Row b41-01** (section 3.1): every lag-watch red is a planned hub roll, not a stuck one. `50_oss-standalone`: fixed by its lane, green on 12 runs. |
| **6. prd WARNING log** (new) | `ENV=prd FRESHNESS=26h LINES=3000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision"' ./run -a do_gcp_tail_logs` (12:28Z; the 3000 cap reached: 05:52Z..12:27Z read) | 3000 entries; by message: 1575 `401 /v1/me/reads`, 526 `ws hello refused`, 256 `401 /v1/pins`, 254 `upload token refused` (an expired browser session polling), 84 `gcal:` lines, 125 on `topics/<id>/export.pdf` (107 x `403`, 18 x `404`, all `Go-http-client`, the box CLI, 6 topics), and a tail of single lines | **Row b41-02** (section 3.2): 1 `gcal` line, t1, hub 3.4.1, `err: invalid calendar event: rrule: WKST is not supported`: a Google series is refused for good. The other 83 `gcal` lines are `context canceled` (73 event lines, another workspace, hub 3.3.9, one connection; 4 `sync cycle` lines) and 6 `events.list` network errors: a cycle cut short, retried. The 401 bursts: a client with a dead session, answered as designed. The export.pdf 403s are the `no_operator` refusal of a seat-topic PDF redo in another workspace, the holder's and c-003's blocker in topic `f08c0c58` (11:50Z), waiting on the owner. |
| **7. R7 notes of lanes landed since W** | prd `messages` from the reviewers since W (`from_id in (g-092, g-117, g-122, g-617, g-133, g-125) and body like '%PASS%'`), their `/var/spool-hub/reports/<id>.md` on `<box2>`, and the holder, orchestrator and standby inboxes on `<box2>` (mtime after W) | 3 PASS reports (g-092 b40-01, g-117 r91-01, g-122 r91-02) and 1 relay (g-133 SPL-6301); notes: g-133 N1-N3 only | **0 rows.** g-133's N1 (author brief not on its box), N2 (rdb 0313 provisional) and N3 (c-624's file list) are inside SPL-6301's own lane. g-617's b40-02 PASS went to the holder on sat and is not on `<box2>`: not read. |
| **8. Owner, member and lane reports** | prd `messages` from `HUM-%` in t1 since W (20 rows) and the round's topic `ee2cb369` (3 posts, all the holder's) | 1 report: HUM-10 11:39Z in `f08c0c58` (the discussion loops of another workspace's channel "does not seem to work") | **0 rows**: answered in that topic by the holder at 11:43Z and 11:46Z (no restart needed, two of three seats did their loop prompts) and owned there. |
| **9. Round 40's first inputs** | round 40 section 7, re-run | 7 items | **0 rows**: section 3.3. |

---

## 3. The candidates, read

### 3.1 b41-01: the deploy-lag watch fails on a hub roll that the 2-hour hold planned and the catch-up is doing

- **What happens.** Workflow 20 holds a pushed hub roll while the served build is younger than `HUB_DEPLOY_COALESCE_MIN` (120 min, SPL-5641, `.github/workflows/20_hub-build-deploy.yml:443-487`), and workflow 21 (`21_hub-deploy-catchup.yml:45`, cron `7,22,37,52 * * * *`) dispatches workflow 20 on trunk head once the hold is over. `do_check_deploy_lag` (`csi-spl-orc/src/bash/run/check-deploy-lag.func.sh`) reads a hub lag as `pending` only while its age is under `GRACE_MINUTES` (45, `:194`) or the hold is still running (`held > 0`, `:202-216`); one second after the hold ends it prints `lagging` (`:218`, rc 3), and the hourly watch (`.github/workflows/00_deploy-lag-watch.yml:222`, `:247`) fails both env jobs. The catch-up still has to tick (every 15 min, best-effort) and its roll still has to run (the full hub suite, then the deploy). The watch's own comment says the grace "keeps a roll that is still in flight out of the verdict" (`00_deploy-lag-watch.yml:187-188`); since the hold, it does not. Its error text still says to roll by hand ("bump cnf env.hub.image.tag, then 030 through make do-provision", `:247`), which the catch-up has replaced.
- **Measured** (GitHub API, read-only, 12:2xZ):
  - `gh run list --workflow 00_deploy-lag-watch.yml --limit 40`: 11 of 40 runs red (2026-11-21T20:17Z..2026-11-23T11:17Z). Each red run's two failed jobs print `hub lagging`, `held` absent, on both dev and prd: 22 job reds, ages 83..159 min.
  - For each red run, the wf 20 run that rolled its served build (the run of that sha whose "Deploy hub to prd" took more than 2 min), its "Prebuild hub image" end + 120 min = the hold's end, read against the watch's start: 18, 34, 32, -5, 45, -5, 17, 17, 27, 34, 10 min after the hold's end (n=11; the prebuild's end is later than `built_at`, so these are upper bounds of the time since the hold ended, and a -5 is a hold that had ended by the watch's own read, `held` absent).
  - At the watch's start, a wf 20 run was open on a head that contains the oldest unserved commit in 10 of 11 (`git merge-base --is-ancestor <oldest> <head>`); the 11th (20:17:59Z) was 7 min before the catch-up's dispatch (run 45066314146, 20:25:02Z). Each env was served by the next run, and the watch was green again on its next or next-but-one run.
  - The catch-up's roll: `gh run list --workflow 20_hub-build-deploy.yml --limit 120`, `event=workflow_dispatch` and `success`: 33..42 min (median 37, p90 41, n=27, 2026-11-17..23). Catch-up ticks seen 04:54:37Z then 05:17:12Z (23 min).
  - One case end to end: `ce334b04b` landed 03:07Z; its push run 45104092075 printed `deploy served=751b083a lacks hub input in ce334b04` and `::warning::prd: held -- ... 5114s left, then 21's catch-up rolls trunk head (SPL-5641)`, its deploy job 14 s; the hold ended about 04:55Z; the catch-up at 04:54:37Z was 49 s early, the one at 05:17:12Z dispatched run 45116845104 (05:17:33Z..05:54:46Z); the watch at 05:20:36Z (run 45117169034) failed with `prd hub lagging served=751b083a sha=ce334b04 n=1 oldest=ce334b04 age=133m grace=45m age_from=landed`.
- **Why it is a bug.** A red on master that asks for a prd mutation by hand, 11 times in 40 runs, every time for a roll the system had planned and was doing; a real stuck roll reads the same. The test pins it: `csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh:109`, "CONTROL: the same lag, served build 130 min old -> RED", is a hold that ended 10 min before.
- **Red control** (`rc01-b41.sh`, section 4.1): on `bce008e61` -> `rc01 after-hold-10m: lagging`, `rc01 after-hold-180m: lagging`, `suite: FAILED: 1` (only the new case), exit 1. **Control** in the same run: the hold ended 180 min ago reads `lagging` before and after the fix.
- **Fix scope.** After the hold ends, a hub lag stays `pending` for a catch-up allowance, then `lagging`: in `_spl_lag_one` (`check-deploy-lag.func.sh:198-218`), the hold's end (served `built_at` + `HUB_DEPLOY_COALESCE_MIN`, the `hub-deploy-coalesce.sh` math, `csi-spl-orc/src/bash/scripts/hub-deploy-coalesce.sh:35-55`) plus a new optional `LAG_CATCHUP_MINUTES` (the row sets its default from the numbers above: a catch-up tick gap up to about 25 min + its roll, 42 min at most, so about 70) prints `pending ... catchup=<m left>`. The prd hub also reads dev's hold end, as `:206-212` do for `held`. `check-deploy-lag.tst.sh`: the case of `rc01-b41.sh` becomes a real case, red before the fix; the CONTROL case at `:109` moves past hold + allowance (a built_at older than 120 + the allowance). `00_deploy-lag-watch.yml:247`'s error text names the catch-up (21) instead of the hand roll. The WUI component has no hold and is unchanged. Docs: the action's own header (`:32-60`) says the new verdict; the devops guide (`csi-spl-doc/doc/md/guides/devops-guide.md:702`, a qto export) describes no grace and stays. R9 applies (a CI check): tests under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset.

### 3.2 b41-02: a Google recurring event whose RRULE carries WKST never reaches Spool

- **What happens.** The Google sync maps an item's `RRULE:` line into the Spool event as it is (`GcalSpoolOf`, `csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_sync_in.go:286-300`). The store checks it with `calrecur.NewSeries` (`internal/store/calendar_series.go:32-36`), and `calrecur.Parse` refuses any part outside spec 097's subset (`internal/calrecur/calrecur.go:127-146`, `WKST is not supported` at `:144`; the test pins `FREQ=WEEKLY;WKST=SU` as refused, `calrecur_test.go:73`). The sync logs it at warn and treats `ErrInvalidCalendarEvent` as no failure (`internal/hub/gcal_sync_sources.go:220-226`), so the sync token moves past the item: the series is not retried until it is edited at Google. `calrecur` itself always expands with `Wkst: rrule.MO` (`calrecur.go:255`), so the part is known to the library it wraps.
- **Why it is a bug.** Spec 097 4.4 says its subset "covers every choice in Google's 'Custom' repeat dialog" (`csi-spl-doc/specs/097-calendar-full-editing/spec.md:299-303`), and spec 149 2.5 maps `rrule` <-> `recurrence` (`csi-spl-doc/specs/149-google-calendar-connect/spec.md:244`) with no rule that a series outside the subset is dropped. Google sent one: prd WARNING log, t1, hub 3.4.1, connection `4552373f`, `err: invalid calendar event: rrule: WKST is not supported` (source 6; 1 event, 1 connection in the 6.5 h read). A member's repeating meeting is missing from their Spool calendar with no word in the WUI.
- **Red control** (`rc02-b41.sh`, section 4.2): on `bce008e61` -> `rc02 wkst: rrule="FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO,WE" got=refused: calrecur: rule outside the supported subset: WKST is not supported want=taken`, `--- FAIL`, exit 1. **Control** in the same run: the same rule without WKST -> `got=taken`.
- **Fix scope.** `calrecur` takes `WKST=MO|TU|WE|TH|FR|SA|SU` (one day, no ordinal; anything else stays `ErrBadRule`), keeps it on `Rule` (default `MO`, the RFC 5545 default and today's behaviour) and hands it to `rrule-go` in `option` (`calrecur.go:255`) in place of the literal. `calrecur_test.go`: `FREQ=WEEKLY;WKST=SU` moves from `refused` (`:73`) to the accepted list; a refused `WKST=XX` and `WKST=1MO`; an expansion case where WKST changes the dates (RFC 5545's `FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU` with `WKST=MO` vs `WKST=SU`), and the case of `rc02-b41.sh` in `internal/hub/gcal_map_test.go`, red before the fix. Spec 097 4.4 lists `WKST`. No store, migration or WUI change: the WUI reads `rrule` only as a boolean (`grep -rnE "\.rrule|rrule\b" csi-spl-wui/src` -> `CalendarPhonePeek.vue:162,210`). The series Google already sent stays out until it is edited at Google or the connection is resynced: the row does not touch it (a prd write); the holder names it to the member after the row lands (section 5). `PRE_PUSH_TIER=full` (the store's calendar tests on Postgres, 2.12.4).

### 3.3 Round 40's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The pre-push e2e selector's composed testids | `git log origin/master --since="$W" --format=%h -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh` -> 0 | unchanged since round 40 measured it | **Not a row**, as rounds 37 to 40: a gate-design input with the holder. |
| The `monitoring-costs` hr-tab flake | source 4 | not seen again (1 sighting, 06:33Z) | **Carried** (2.11.3: a lane on its 3rd sighting). |
| The 6 issues reopened with no placement comment (SPL-2750, 2163, 3028, 2373, 2175, 2377) | prd `issue_events` (status changes of the 6) and `issues` (`kind`, open children by `parent_number`), read-only, 12:2xZ | all 6 are **epics**, each with 1..6 open children (2163: 37 children, 2 open; 2373: 77, 6 open; the others 1 open); their done -> wip events are the epic auto-close and its reopen: e.g. SPL-2750 at 2026-11-22 12:30:43 `wip -> done` + `archived`, 12:30:46 `unarchived`, 12:30:47 `done -> wip`, the same actor (the lease's desk, `li_epic_reopen`, `csi-spl-orc/src/bash/run/spl-epic-reopen.func.sh`, SPL-2558) | **Not a row**: an epic with an open child is rightly `wip`. Closed. |
| SPL-6277 N2 (one sha, two release tags) | `git ls-remote --tags origin 'v*' \| grep -v '\^{}' \| awk '{print $1}' \| sort \| uniq -d \| wc -l` | 0 | **Carried**: no instance. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since="$W" --format='%h %s' \| grep -iE 'SPL-6174\|relay hash'` -> 0 | no writer named | **Carried.** |
| b34-01 N2 and SPL-6212 N2 | rounds 38 to 40 | test-shaped | **Carried** to a test or refactor round. |
| r87-01 N2 (coverage floor tolerance) | no tier=full read past a floor's tolerance reported since W (source 8) | - | **Carried.** |

---

## 4. Red controls, as run

### 4.1 `rc01-b41.sh` (b41-01), sha256 first 12 hex `bc3dd1f30c32`, 1761 B

Run from any checkout: `bash rc01-b41.sh bce008e61`, about 2 s on `<box2>`.

```bash
#!/usr/bin/env bash
# rc01-b41.sh <sha>: b41-01 red control. On <sha>'s tree, a hub lag whose
# 2-hour rollout hold ended 10 min ago (served build 130 min old, the oldest
# unserved input 400 min old, grace 45) must read pending: the catch-up (21)
# has not rolled trunk head yet. Control: the hold ended 180 min ago -> lagging.
# The two cases go after section 2b of that tree's check-deploy-lag.tst.sh, which
# probes a file:// fixture in a synthetic repo (no network, nothing mutated).
set -uo pipefail
sha="${1:?usage: rc01-b41.sh <sha>}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc csi-spl-cnf .github | tar -x -C "$tmp"
t="$tmp/csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh"
anchor='^HUB_DEPLOY_COALESCE_MIN=0 lag_one '
grep -q "$anchor" "$t" || { echo "rc01 sha=${full:0:9}: no section 2b anchor in $t"; exit 2; }
cat >"$tmp/case" <<'CASE'
# b41-01: the hold ended 10 min ago, the catch-up roll is not live yet
lag_one "rc01 b41: hold ended 10 min ago -> pending" "$(fixture_built "$C_BASE" b41h130 130)" "$C_FRESH" 45 0 pending
echo "rc01 after-hold-10m: $(cut -d' ' -f3 "$T/last")"
lag_one "rc01 b41 CONTROL: hold ended 180 min ago -> lagging" "$(fixture_built "$C_BASE" b41h300 300)" "$C_FRESH" 45 3 lagging
echo "rc01 after-hold-180m: $(cut -d' ' -f3 "$T/last")"
CASE
sed -i "/$anchor/r $tmp/case" "$t"
out="$(bash "$t" 2>&1)"
grep -E '^rc01 after-hold|rc01 b41' <<<"$out" | sed 's/^ *//'
a="$(grep '^rc01 after-hold-10m' <<<"$out")"; c="$(grep '^rc01 after-hold-180m' <<<"$out")"
echo "rc01 sha=${full:0:9} suite: $(tail -1 <<<"$out")"
[[ "$a" == *pending && "$c" == *lagging ]]
```

| run | output |
|---|---|
| `bash rc01-b41.sh 7024772b1` | `FAIL: rc01 b41: hold ended 10 min ago -> pending: rc=3 want 0, out='dev hub lagging ... age=400m grace=45m ...'` / `rc01 after-hold-10m: lagging` / `PASS: rc01 b41 CONTROL: hold ended 180 min ago -> lagging (lagging, rc 3)` / `rc01 after-hold-180m: lagging` / `rc01 sha=7024772b1 suite: FAILED: 1`, exit 1 |
| `bash rc01-b41.sh bce008e61` | the same lines, `rc01 sha=bce008e61 suite: FAILED: 1`, exit 1 |

The `age_from=commit:gh-api-failed` in the fixture line is the test file's own stubbed `gh` (no landing read): the age is the synthetic commit's, 400 min, past the grace either way.

### 4.2 `rc02-b41.sh` (b41-02), sha256 first 12 hex `31eb5df69de3`, 2192 B

Run from any checkout: `bash rc02-b41.sh bce008e61`, 40 s on `<box2>` with a warm Go cache (2 min cold).

```bash
#!/usr/bin/env bash
# rc02-b41.sh <sha>: b41-02 red control. On <sha>'s tree, a Google weekly
# series whose RRULE carries WKST (RRULE:FREQ=WEEKLY;WKST=SU;INTERVAL=2;
# BYDAY=MO,WE) mapped by GcalSpoolOf must pass calrecur.NewSeries, the check
# the store's calendarSeriesOf runs before it writes the event. Control: the
# same rule without WKST. The Go test below is dropped into that tree's
# internal/hub; it reads nothing outside the tree.
set -uo pipefail
sha="${1:?usage: rc02-b41.sh <sha>}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
cat >"$d/internal/hub/b41_rc02_test.go" <<'GO'
package hub_test

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/calrecur"
	"github.com/csitea/csi-spl/spool-hub-api/internal/gcal"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

func TestB41GoogleWeeklyRuleWithWKSTIsTaken(t *testing.T) {
	start := time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)
	for _, c := range []struct{ name, rule string }{
		{"wkst", "RRULE:FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO,WE"},
		{"control", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"},
	} {
		it := gcal.Event{ID: "g1", Summary: "standup", Recurrence: []string{c.rule},
			Start: gcal.EventTime{DateTime: start, TimeZone: "UTC"}, End: gcal.EventTime{DateTime: start.Add(30 * time.Minute), TimeZone: "UTC"}}
		e := hub.GcalSpoolOf(it, "HUM-1")
		_, err := calrecur.NewSeries("ev-1", e.RRule, e.StartsAt, e.EndsAt, e.TimeZone)
		got := "taken"
		if err != nil {
			got = "refused: " + err.Error()
		}
		t.Logf("rc02 %s: rrule=%q got=%s want=taken", c.name, e.RRule, got)
		if err != nil {
			t.Errorf("%s: a Google rule the store refuses: %v", c.name, err)
		}
	}
}
GO
out="$(cd "$d" && go test -count=1 -run TestB41GoogleWeeklyRuleWithWKSTIsTaken -v ./internal/hub/ 2>&1)"; rc=$?
grep -E "rc02 (wkst|control)|--- (PASS|FAIL)" <<<"$out" | sed "s/^ *//" || tail -15 <<<"$out"
echo "rc02 sha=${full:0:9} rc=$rc"
exit $rc
```

| run | output |
|---|---|
| `bash rc02-b41.sh 7024772b1` | `rc02 wkst: rrule="FREQ=WEEKLY;WKST=SU;INTERVAL=2;BYDAY=MO,WE" got=refused: calrecur: rule outside the supported subset: WKST is not supported want=taken` / `rc02 control: rrule="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE" got=taken want=taken` / `--- FAIL: TestB41GoogleWeeklyRuleWithWKSTIsTaken` / `rc02 sha=7024772b1 rc=1`, exit 1 |
| `bash rc02-b41.sh bce008e61` | the same lines, `rc02 sha=bce008e61 rc=1`, exit 1 |

---

## 5. Rows

| # | id | practice | sites (file:line on `bce008e61`) | evidence | red control (fails on `bce008e61`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b41-01-orc-deploy-lag-catchup-pending` | a roll the system planned and is doing is not a lag | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh:194,198-218` (header `:32-66`); `csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh:104-110`; `.github/workflows/00_deploy-lag-watch.yml:187-188,247`; reads `csi-spl-orc/src/bash/scripts/hub-deploy-coalesce.sh:35-55` | wf 00: 11 of 40 runs red, 22 job reds, every one `hub lagging` after the hold, 10 of 11 with the catch-up's or a push's wf 20 run open; section 3.1 | `bash rc01-b41.sh bce008e61` -> `rc01 after-hold-10m: lagging`, exit 1; control `after-hold-180m: lagging` | `bash csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh`; **`hub-deploy-guard.tst.sh`**, `check-lane-served.tst.sh`, `check-env-order.tst.sh`, `desk-live-proof.tst.sh`, `spl-desk-live-proof-render.tst.sh`, `dispatch-setup-check.tst.sh`, `spl-lane-lifecycle-actions.tst.sh` (csi-spl-orc/src/bash/tests, they name the action or its file); **`csi-spl-iac/src/bash/tests/lag-watch-gh-token.tst.sh`**, **`deploy-workflows-key-auth.tst.sh`** (read the workflow) | `check-deploy-lag.func.sh` and its test, the workflow's error text and comment; no workflow trigger, no cnf, no WUI change | sat | claude (`simple_coding`) | grok seat | fix | 1 |
| 02 | `b41-02-api-gcal-rrule-wkst` | a Google rule in the subset's spirit is taken, not dropped | `csi-spl-api/src/go/spool-hub-api/internal/calrecur/calrecur.go:127-146,250-255` (`Rule` `:53-62`); `internal/calrecur/calrecur_test.go:57-94`; test `internal/hub/gcal_map_test.go`; doc `csi-spl-doc/specs/097-calendar-full-editing/spec.md:299-303` | prd WARNING log, t1, hub 3.4.1: `invalid calendar event: rrule: WKST is not supported`, 1 Google series refused for good; section 3.2 | `bash rc02-b41.sh bce008e61` -> `rc02 wkst: ... got=refused: ... WKST is not supported want=taken`, exit 1; control (no WKST) `got=taken` | `cd csi-spl-api/src/go/spool-hub-api && go test ./internal/calrecur/`, `go test ./internal/hub/ -run 'Gcal\|Calendar'`, `go test ./internal/store/ -run 'Calendar'` (`calendar_series.go` calls `calrecur.NewSeries`); on Postgres (`PRE_PUSH_TIER=full`, 2.12.4) | `calrecur.go` and its test, one case in `gcal_map_test.go`, spec 097 4.4; no store, migration or WUI change; the series already refused is not touched | sat | claude (`simple_coding`) | grok seat | fix | 1 |

- **R1:** the two rows share no file (orc lag check, its test, workflow 00 vs api `calrecur`, its test, `gcal_map_test.go`, spec 097): both batch 1.
- **R7:** `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (12:31Z) -> `pick=sat reason=every box is at or above its high mark; sat is the least past its band (118% on high 90%, overflow 180%)`: a grok seat reviews each row (claude authors, grok reviews: cross-vendor). No mistral on either row (coding kinds); neither row touches `csi-spl-wui/`. `BOX_PICK_KIND=claude` (12:34Z) -> `pick=sat`, the same reason: both rows on sat.
- **Pushes:** aim 1 each (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.
- **After b41-02 lands (the holder, not the row):** the Google series of connection `4552373f` (t1) stays out of Spool until it is edited at Google or the connection syncs in full again. The holder names it to the connection's member; no row writes prd.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | `lane-map.sh --check csi-spl-doc/doc/md/bug-round-41-plan.md,<the 9 row files of section 5> --agent c-136` (12:31:50Z) -> `WARN no live lane lists` them, exit 4: 5 sat lanes record no files: c-547 (r91 planner seat, now on r92), c-624 (costs month range, WUI Costs pages), c-626 (SPL-6301 costs vendor share), g-655 (c-624's R7) and m-650 (r92 panel). Their briefs are not on `<box2>`; read instead: `git diff --name-only $(git merge-base origin/master origin/review/<b>) origin/review/<b> \| grep -cE 'check-deploy-lag\|00_deploy-lag-watch\|hub-deploy-coalesce\|21_hub-deploy-catchup\|calrecur\|gcal_sync_in\|gcal_map\|specs/097'` -> 0 of 42 files (`c002-costs-month-range`, head 14:26+02:00) and 0 of 11 (`c002-costs-share-route`); the r91 plan names none of them (`grep -cE` the same pattern -> 0). The r92 plan is not on origin (`git ls-remote origin 'refs/heads/*refactor-round-92*' 'refs/heads/*r92*'` -> nothing, 12:33Z): **the holder checks its sites (R3) before it places a row.** The `<box2>` lanes at 12:18:24Z: c-102 and g-125 (blog post, doc), g-133 (SPL-6301 R7), c-110 (r91-02, landed `85f0e60fc`), the seats of two other workspaces. The queue: `do_spl_spawn_queue` 12:18:29Z -> `0 queued, 0 placing`. |
| `monitoring-costs.test.mjs` hr-tab flake | the holder, CI trunk-red watch (2.11.3) | 1st sighting still (run 45124937982); a lane on its 3rd. |
| The e2e selector's composed testids | the holder, as a gate input | unchanged (section 3.3). |
| The Google series refused before b41-02 | the holder | section 5. |
| The discussion-loop report of another workspace and the PDF export `no_operator` blocker | the holder and c-003, topic `f08c0c58` | waiting on the owner's go there (11:50Z). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 9 sources; 117 prd error log entries (26 h); 3000 prd WARNING entries (6.5 h, cap); 9 alert policies (0 incidents); 14 open bug issues; 100 wf 10 runs (5 failures, all known); 40 wf 00 runs (11 red), 12 wf 50 runs since its reds (green); 3 R7 PASS reports + 1 relay since W; 20 owner/member posts since W; round 40's first inputs (7); `rc01-b41.sh` n=2 and `rc02-b41.sh` n=2 (on `7024772b1` and `bce008e61`) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b41-'` -> 0; `git ls-remote origin 'refs/heads/review/b41-*' 'refs/heads/wip/*b41*' 'refs/heads/*-b41-*'` -> nothing (rc 0); `<box2>`: `grep -lE '(^\|[^0-9a-f])b41-\|[Bb]ug round 41\|bug-round-41' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md` -> this planner's brief only; `git worktree list \| grep -E 'b41\|bug-round-41'` -> nothing but this seat's worktree, 12:18Z |
| R7 seat | grok (`pick=sat`, 12:31Z) |
| first inputs for round 42 | the selector's composed testids (if no gate round takes it); the `monitoring-costs` hr-tab flake if it is seen again; SPL-6277 N2 if a sha ever carries two release tags; SPL-6174's relay-hash link once its writer is named; b34-01 N2 and SPL-6212 N2 (test-shaped); r87-01 N2 if a tier=full run reads a package past its floor's tolerance; the prd WARNING log read past its 3000 cap (the 401 bursts fill it: a `FILTER` that leaves them out reads the full 26 h) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-136@`<box2>` (claude, `specs_and_docs`).
- **Panel:** to be placed by the holder: one non-claude seat (round 40: m-048, mistral, a doc review).
- **Row reviewer (R7):** a grok seat per row (section 5).
- **Review history:**
  - 2026-11-23 12:4xZ: v0.1, pushed to `review/c002-bug-round-41-planner`: 2 rows.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-136@`<box2>` | v0.1 |
| Panel | (to be placed) | - |
| Holder | (the dispatch lease holder) | - |
