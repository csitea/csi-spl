# Refactoring round 79 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6126  
Topic: 06b1186c-f800-4891-8c88-cb23bfd4c6a5  
Discussion: 06b1186c-f800-4891-8c88-cb23bfd4c6a5 (t1 #refactoring, "Refactor round 79", opener msg bb83affb)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r79**, plan `refactor-round-79-plan.md`, rows `r79-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 78 ([refactor-round-78-plan.md](refactor-round-78-plan.md))
is closed (`12c6b0a9b`, SPL-6109): r78-01 landed `0557d609a` (SPL-6113), r78-02 landed
`ba7acd634` (SPL-6114). No signed row is handed on: r79 is a fresh round. The perf floor
(rulebook 4.4), the holder's read on `3af9dfaae`: `perf 29 refactor 107 perf-share 21.3%
floor-met`, so this is a refactor round.

**Row 01** rewrites one clause of a workflow comment that overstates the disk margin
(`10_ci-quality.yml:444-445`), r78 section 7's "first candidate for r79". **Row 02**
moves the desk-reconcile cron's `--print-crontab` reader (`desk-reconcile-cron.sh:189`)
onto `spl_var_app_subdir`, the reader r78-01 left behind, with the two tests that pin its
spelled form.

**Status: v1.0**: panel seat m-620 (mistral) PASS on v0.1 `043b1af86`, no W finding,
N1-N3 recorded (section 8); no row changes scope. m-620 PASS on v1.0 `2d00168fd` too
(section 9). **Closed**: both rows landed, r79-01 `75da57eb4`, r79-02 `21a8e0296` +
`f5256aa6b` (section 8). Editor: **c-509** (claude).

**One sha:** every count is measured on **`d6fc241f9`** (`origin/master`
d6fc241f99ca2bf96d8894317162ed996dfb411e, committed 2026-11-21T03:03:03+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T02:32:24+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r78-plan'` -> commit
  `12c6b0a9b` "refactor round 78 plan records the round closed, rows 01-02 landed".
  Every later read of r79 uses this W.
- **`r79` is free** (2026-11-21T02:15:53Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r79-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r79-*' 'refs/heads/wip/*r79*' 'refs/heads/*-r79-*' 'refs/heads/*refactor-round-79*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r79-[0-9]{2}|refactor-round-79' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**: this planner's brief. The panel seat's
    brief is on the other box and was not read by this lane.
  - Control: the same log read with `(r78-` since W -> 1 line (`12c6b0a9b`), so the read
    sees a used id.
- **No `refactor-round-79*` file** exists under `csi-spl-doc/doc/md` on `d6fc241f9`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-79` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/`, `wf10` = `.github/workflows/10_ci-quality.yml`.

| input | source | on `d6fc241f9` | here |
|---|---|---|---|
| `orc:scripts/desk-reconcile-cron.sh:189` | r78 section 7, line 344 | the line is there; r78-01 landed, so it is the last spelled `desk-reconcile` dir (1.4) | **row 02** |
| `wf10:444-445` comment | r78 section 7, line 345 ("first candidate for r79"); candidates item 3 | `:445` "and it also covers the downloaded archive the restore unpacks." still there | **row 01** |
| the other `local x="${1:?...}"` lines | r78 section 7, line 347 | not re-measured this round: 2 rows taken (5.1) | left out (section 7), first candidate of r80 |
| the rest of r78 section 7 | r78 section 7 | their reasons hold | left out (section 7) |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`, the other box) | the brief; its refactor items inlined by the holder (spool msg f36632b4, 02:2xZ) | re-measured below, item by item | rows 01 and 02 |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r78's reasons hold |

The holder's candidates, item by item (its numbering):

| # | item | on `d6fc241f9` | here |
|---|---|---|---|
| 1 | literal `/var` in `spl-watchdog.func.sh` and `spl-lane-rotate.func.sh` | `grep -nE '/var/'` on both, comment lines out -> **0**: served | nothing taken |
| 2 | `reverse-tunnel-cron.sh` literal | `:27` reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`: served | nothing taken |
| 3 | `wf10:444-445` "it also covers the downloaded archive" overstates the margin | still there (1.3) | **row 01** |
| 4 | the agent-boot-restore dir | the writer's `@param` reads `default <SPL_VAR_APP_DIR>/agent-boot-restore (spl_run_paths)` (`spl-agent-boot-restore-install-cron.func.sh:31`): served (r70-01) | nothing taken |
| 5 | `spl-uplink-probe.func.sh:14-15` wording | `:14-15` say "In probe mode a down link never fails the probe: it exits 0. A config fault does, FATAL with rc 1": served | nothing taken |
| 6 | `spl-spawn-place-argmax.tst.sh` section 9 lacks two guard cases | b30-01 (c-494) is on review on that file and `spl-spawn-place.func.sh`: R3, off limits | left out (section 7) |
| 7 | `tf-log-mask.func.sh:25` `${1:?}` | `grep -c '${1:?'` on the file -> **0**: served (r78-02) | nothing taken |
| - | spec 181 B10 R7 m-612 N1, N2, N4 (spec text) | doc-only spec edits; B10 (c-492) is live on specs 121/127/159; N4 waits on an owner poll | left out (section 7) |

### 1.3 Row 01's site: the wf10 disk-margin comment

`wf10` (2056 lines), `:439-451`:

```text
:439  # Perf round 18 row 02: the free-up below cost 58..151 s a job, yet a
:440  # hosted runner starts with 88 G free and needs 12.3 G (the guard's
:441  # CI_DISK_NEED_GB plus the trimmed cache, 2.3 G unpacked from 410 MB on
:442  # run 44365338095). So the guard first only reports: short=true below
:443  # CI_DISK_NEED_GB plus the save cap rounded up to whole GB (4000 MB ->
:444  # 4 G). The cap is the margin because no saved entry unpacks larger,
:445  # and it also covers the downloaded archive the restore unpacks.
:446  - name: Disk check, report only (short of the need plus the Go cache?)
...
:451    run: CI_DISK_NEED_GB=$((CI_DISK_NEED_GB + (CI_GO_CACHE_SAVE_MAX_MB + 1023) / 1024)) bash csi-spl-orc/src/bash/scripts/ci-disk-guard.sh
```

**What is wrong.** The cap `CI_GO_CACHE_SAVE_MAX_MB` (`"4000"`, `wf10:146`) is read by
`orc:scripts/ci-cache-save-cap.sh:31` against `du -sm` of the cache dir: unpacked MiB.
The margin `:451` adds is `(4000 + 1023) / 1024` = **4** GiB = 4096 MiB, so an entry at
the cap leaves **96 MiB** for its downloaded archive (today's archive is 410 MB, `:441`).
"It also covers the downloaded archive" holds for today's entry (2.3 G unpacked) but not
for one at the cap: the clause states more than the arithmetic does (p18-02 R7 c-982 N1,
candidates item 3).

**The shape:** replace `:444-445`'s last clause with what the numbers say, e.g. "The cap
is the margin because no saved entry unpacks larger; 4000 MB rounds up to 4 G, so only
about 96 MB of it is left for the downloaded archive the restore unpacks beside an entry
at the cap." Wording only: no step, `env`, `if:`, `run:` or expression changes.

**The tests.** No test holds a 30-character string of `:439-445` (`git grep -lF` of 9
phrases of those lines outside `csi-spl-doc` -> only `wf10` each). Tests that read `wf10`:
`git grep -lE '10_ci-quality' -- '*tests/*'` -> **41 files**; the two that read this step:
`iac:src/bash/tests/ci-hub-pg-disk.tst.sh` (its report-step checks) and
`orc:tests/ci-disk-guard.tst.sh` (the guard's report mode).

### 1.4 Row 02's site: the desk-reconcile `--print-crontab` reader

`orc:scripts/desk-reconcile-cron.sh` (567 lines), the `PRINT=1` block (`--print-crontab`,
`:90`), `:182-189`:

```text
:182  if [ "$PRINT" = 1 ]; then
:185    ORG_APP="$(basename "$ORC")"; ORG_APP="${ORG_APP%-orc}"
:187    printf '*/5 * * * * ENV=%s TENANT_ID=%s%s %s >> %s/cron.out 2>&1 # %s:desk-reconcile\n' \
:188      "$ENV_NAME" "$TENANT" "$m" "$SELF" \
:189      "${DESK_CRON_LOG_DIR:-/var/${ORG_APP%%-*}/$ORG_APP/desk-reconcile}" "$ORG_APP"
```

`ORC` is `:100`'s module dir. `ORG_APP` stays (it names the crontab tag,
`# <org>-<app>:desk-reconcile`); only the default log dir moves.

**The shape**, r77-02's for a script (`save-sessions.sh`, `7ff2604dd`) and r78-01's for
the same dir in the installer:

```text
if [ -n "${DESK_CRON_LOG_DIR:-}" ]; then ld="$DESK_CRON_LOG_DIR"
else
  . "$ORC/lib/bash/funcs/spl-run-paths.func.sh" &&
    spl_var_app_subdir ld desk-reconcile || { say "FATAL cannot derive the desk-reconcile log dir (spl_run_paths): set DESK_CRON_LOG_DIR"; exit 2; }
fi
```

inside the `PRINT=1` block only (the tick path does not read the dir), and `:189` prints
`"$ld"`.

**Same dir today, measured** (this lane's box, 2026-11-21T02:17:29Z, n=1 per tree, as the
push user under `env -i PATH=/usr/bin:/bin`): for the main checkout, the desk-cron
checkout (a worktree) and this lane's worktree, the hand form (`ORG_APP` from the orc dir
name) and `spl_var_app_subdir d desk-reconcile` (that tree's lib) print the same path:
**3 of 3 EQUAL** (`/var/<org>/<org>-<app>/desk-reconcile`). The main and desk-cron
checkouts were read at their own heads, not at `d6fc241f9`.

**The two tests that pin the spelled form:**

- `iac:src/bash/tests/satellite-ansible.tst.sh` (535 lines), `:270-272`: `n_sd` (`:271`)
  counts the distinct `/var/<var>/.../(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)`
  paths in orc and iac `src/bash`; `:272` passes at `-ge 5` and says "desk-reconcile
  included". On `d6fc241f9` the same grep prints **5** paths (r78-01 took one):
  `desk-reconcile-cron.sh:189`, `spl-unanswered-sweep-install-cron.func.sh:57`,
  `install-weekly-full-scan-cron.func.sh:48`, `gcp-backup-env.func.sh:55`, and the
  `tenants` form of `spl-desk-rebox.func.sh:111` / `spl-invite-e2e.func.sh:118` /
  `spl-m3-e2e.func.sh:159`. Row 02 removes the first: **5 -> 4, the test FAILS** unless
  its floor moves to `-ge 4` and its pass text drops "desk-reconcile included" (no
  spelled desk-reconcile path is left; the derived one is under `SPL_VAR_APP_DIR` by
  construction). The `bad` half of the check (`:270`) is unchanged.
- `orc:tests/desk-install-service-user.tst.sh` (174 lines), case 9 (`:144-155`): builds a
  fake checkout `$T/co/<OA>-orc` with the script and `spl-cloud-cnf.func.sh` only
  (`:148`), then runs `--print-crontab` with `DESK_CRON_LOG_DIR` unset. After row 02
  that block sources `spl-run-paths.func.sh`, which the fake tree lacks: case 9 would
  exit 2. The row copies the lib into the fake tree next to `:148` and adds one case
  (below).

Other tests naming the script (`git grep -lE 'desk-reconcile-cron' -- '*tests/*.sh'` ->
**16 files**): `desk-up-all.tst.sh` case 7 prints from a worktree path and is refused
(rc 2) at `:175`, before the block; `desk-cron-trunk.tst.sh` copies the script alone but
never prints; the rest run the tick or check crontab tags. None reads the printed dir.

**The baseline.** `orc:tests/no-literal-paths-spelled.baseline`: **18 lines in 16 files**
(r78 close); `:12` is `1 csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh`. Row 02
drops it: **17 in 15**, else the gate's STALE check fails.

### 1.5 Before (this lane, worktree at `d6fc241f9`)

2026-11-21T02:21Z, n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`:

| suite | row | rc | pass lines | fail lines | last line |
|---|---|---|---|---|---|
| `iac:src/bash/tests/ci-hub-pg-disk.tst.sh` | 01 | 0 | 5 | 0 | `PASS: all ci-hub-pg-disk.tst.sh assertions` |
| `orc:tests/ci-disk-guard.tst.sh` | 01 | 0 | 17 | 0 | `=== all ci-disk-guard.tst.sh assertions ...` |
| `orc:tests/desk-install-service-user.tst.sh` | 02 | 0 | 18 | 0 | `desk-install-service-user: 0 failure(s)` |
| `orc:tests/no-literal-paths.tst.sh` | 02 | 0 | 15 | 0 | `ALL PASS` |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 02 | 0 | 96 | 0 | `PASS: all satellite-ansible.tst.sh assertions` |
| `orc:tests/desk-up-all.tst.sh` | 02 | 0 | 110 | 0 | `=== all desk-up-all.tst.sh assertions ...` |
| `orc:tests/desk-cron-trunk.tst.sh` | 02 | 0 | 25 | 0 | `desk-cron-trunk: 0 failure(s)` |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `ci(r79-01-ci-wf10-disk-margin-comment)` | no comment describes behaviour the code does not perform (rulebook C5) | the clause says the 4 G margin also covers the downloaded archive; at the 4000 MB cap only 96 MB is left (1.3) | `wf10:444-445` (the comment's last clause) | 1 site | The comment takes 1.3's shape. **Grep-count test:** `grep -c 'it also covers the downloaded archive' .github/workflows/10_ci-quality.yml` **1 -> 0**, and the commit's diff is comment lines only (`git diff -U0 HEAD^ HEAD -- .github/workflows/10_ci-quality.yml \| grep -E '^[+-] ' \| grep -vcE '^[+-]\s*#'` -> 0). **Behaviour:** no step changes; `ci-hub-pg-disk.tst.sh` (5 pass) and `ci-disk-guard.tst.sh` (17) unchanged; `actionlint` on wf10 prints the same findings as on the parent. R9: the two suites once under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. Tests: those two, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r79-02-orc-desk-cron-print-var-app-subdir)` | canonical paths (developer guide 2.3.1); folded helpers exist once (2.2.4) | the cron script's `--print-crontab` spells the desk-reconcile log dir by hand; the run lib derives the same dir, as the installer already does since r78-01 (1.4, 3 of 3) | `orc:scripts/desk-reconcile-cron.sh:185-189`<br>`orc:tests/no-literal-paths-spelled.baseline:12` (drop the line)<br>`iac:src/bash/tests/satellite-ansible.tst.sh:272` (floor 5 -> 4, pass text)<br>`orc:tests/desk-install-service-user.tst.sh:148` (copy the lib; + one new case) | 1 site | The site takes 1.4's shape. **Gate:** the spelled ratchet, baseline 16 -> **15** files (18 -> 17 lines). **New case** in `desk-install-service-user.tst.sh` case 9: `pc` with `DESK_CRON_LOG_DIR` unset (`env -u`) and `SPL_VAR_APP_DIR=$T/var`: the one printed line holds `>> $T/var/desk-reconcile/cron.out`. **Red control:** that case on the parent's script prints the hand form (`/var/<OA%%-*>/<OA>/desk-reconcile`) and FAILs, then GREEN; `--print-crontab` writes nothing, so the red run touches no live path; output in the body. **`satellite-ansible.tst.sh`:** on head with the old floor it FAILs (`n_sd` 4), with `-ge 4` it passes; both in the body. **Behaviour:** 1.4's 3-tree same-dir proof re-run on the lane's start sha, in the body; with `DESK_CRON_LOG_DIR` set the printed line is byte-identical to the parent's. Tests: the 16 files of 1.4's grep (run each), `no-literal-paths.tst.sh`, `satellite-ansible.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads, row 01's grep, row 02's
baseline count, 1.4's `n_sd` read and same-dir proof, on the `origin/master` it starts
from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r79-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r79-NN` (R7, 2.7.4; the line box-free in a commit body). Row 01's type is `ci`
(a workflow file; rulebook 4.4 counts `ci` as a row type).

**Docs:** row 01 is a comment. Row 02's help is the script's own usage line (`:39`,
unchanged); no `csi-spl-doc/` page outside the round plans names `DESK_CRON_LOG_DIR`
(`git grep -n DESK_CRON_LOG_DIR -- csi-spl-doc | grep -v round-` -> 0). Each:
`Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their files are disjoint (a workflow vs an orc script, orc
  tests and one iac test), so both place at once.
- No row edits `lib:spl-run-paths.func.sh`, `orc:run/spl-desk-install-service.func.sh`,
  `orc:scripts/ci-cache-save-cap.sh`, `orc:scripts/ci-disk-guard.sh`,
  `orc:tests/no-literal-paths.tst.sh`, any wf10 step, `env`, `if:` or `run:` line, a
  migration, `csi-spl-cnf/`, terraform, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths: `wf10`, `orc:scripts/desk-reconcile-cron.sh`,
`orc:tests/no-literal-paths-spelled.baseline`, `iac:src/bash/tests/satellite-ansible.tst.sh`,
`orc:tests/desk-install-service-user.tst.sh` (5).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-509`, one call per
  path, 2026-11-21T02:17:49Z, n=1: **exit 4 on all 5**, the one `unknown:` lane being
  c-461 `c-461-rotate` on the other box (a rotate seat, no files recorded). No live lane
  lists a row path. The holder re-checks it before placing. (Panel N3: m-620's read at
  02:3xZ exited 4 with **16** `unknown:` lanes, none on a row path by slug; the count
  moves with the fleet, so the holder's re-check before placing is the one that counts.)
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 02:19:25Z): **32
  queued, 0 placing**: this round's mistral panel seat, b30-02 (`wt-dead-sweep`), b30-03
  (`spl-spawn-after`), spec 184, 181 v04, 143, 123 L0-L7, 033 T026, 182 v08, 187 and WUI
  lanes. None names a row path by slug. Live share at that read: `refactor 2 9% (band
  40-60%: UNDER)`, `phase night`; last 24 h `refactor 9% (band 20-30%: UNDER)`.
- **Remote branches committed in the last 24 h** (39 besides master, 02:19Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b>` filtered for the 5
  basenames -> **1 hit**, `review/c002-bug-round-30-mistral-seat` on the spelled
  baseline: that seat branch carries an older copy of r78-01 (`7bf3be9cb`, landed as
  `0557d609a`) among the commits it picked up; its own commits are `docs(b30-plan ...)`
  seat files. Not a live edit.
- **This box's lane worktrees** (328 besides this one, 02:18:17Z):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **0 hits**. The other box's worktrees were not read by this lane.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Live lanes named in the brief** (01:5xZ): b30-01 (spawn-place files), spec 181 B1
  (rdb, hub), B5 (tf step workspace vms), B6 (`iac:src/ansible/customer-box/`,
  `check-pre-push-cross.func.sh`), B10 (specs 121/127/159), spec 123 P02-P07 (cost, WUI,
  help), spec 033 T025/T027 (WUI kinds, locales): none on a row path by its listed files.
  B6 is the nearest (iac ansible); the holder re-checks `satellite-ansible.tst.sh`
  against it before placing row 02.

## 3. Per row: what the lane does

- **r79-01:** the wf10 comment's last clause says what the margin covers at the cap, in
  numbers; nothing else in the file moves.
- **r79-02:** `desk-reconcile-cron.sh --print-crontab` derives its default log dir with
  `spl_var_app_subdir`, its line leaves the spelled baseline, `satellite-ansible.tst.sh`'s
  floor follows the count, and case 9 gains the default-dir case.

## 4. Panel and reviewers (R7)

- Editor: c-509 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r79`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-79-mistral-panel-seat` (agy, the main vendor for plan reviews, is
  out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `BOX_PICK_KIND=grok
  ./run -a do_spl_box_pick` at 2026-11-21T02:20:19Z -> `pick=hold` (grok weekly 99% on
  both boxes), so each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r78. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r79-01 | `c002-r79-01-ci-wf10-disk-margin-comment` | `ci(r79-01-ci-wf10-disk-margin-comment, SPL-<row issue>): ...` | `review/r79-01` | 1 |
| r79-02 | `c002-r79-02-orc-desk-cron-print-dir` | `refactor(r79-02-orc-desk-cron-print-var-app-subdir, SPL-<row issue>): ...` | `review/r79-02` | 1 |

**r79-01 brief, Files: ONLY** `.github/workflows/10_ci-quality.yml` (`:444-445`, comment
lines). NOT any step, `env`, `run:` or `if:` line, NOT `ci-disk-guard.sh`, NOT
`ci-cache-save-cap.sh`, NOT their tests (run them, do not edit them). Do: plan section 2
row 01 verbatim, 1.3's shape (the wording may differ; the numbers 4000 MB, 4 G and about
96 MB must be right, re-derived from `wf10:146` and `:451`); the grep count and the
comment-only diff count in the body. Gates: `ci-hub-pg-disk.tst.sh`, `ci-disk-guard.tst.sh`,
`actionlint` (same findings as the parent), R9's two runs, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r79-02 brief, Files: ONLY** `orc:scripts/desk-reconcile-cron.sh` (`:185-189`, the
`PRINT=1` block), `orc:tests/no-literal-paths-spelled.baseline` (drop `:12`),
`iac:src/bash/tests/satellite-ansible.tst.sh` (`:272`: `-ge 5` -> `-ge 4`, the pass text
without "desk-reconcile included"; `:270-271` unchanged) and
`orc:tests/desk-install-service-user.tst.sh` (case 9: copy `spl-run-paths.func.sh` into
the fake tree, one new case). NOT `lib:spl-run-paths.func.sh`, NOT
`orc:run/spl-desk-install-service.func.sh`, NOT the script's tick path, NOT
`orc:tests/no-literal-paths.tst.sh`. Do: plan section 2 row 02 verbatim, 1.4's shape;
the red controls (new case on the parent's script; `satellite-ansible.tst.sh` with the
old floor on head) RED then GREEN in the body; the 3-tree same-dir proof; with
`DESK_CRON_LOG_DIR` set, the printed line byte-identical to the parent's. Gates: the 16
test files of 1.4, `no-literal-paths.tst.sh`, `satellite-ansible.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (1 ci comment, 1 refactor; both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| "it also covers the downloaded archive" in wf10 | 1 today -> 0 after row 01 |
| spelled var-dir lines (`no-literal-paths-spelled.baseline`) | 18 in 16 files today -> 17 in 15 after row 02 |
| `satellite-ansible.tst.sh` `n_sd` | 5 today -> 4 after row 02 (floor `-ge 5` -> `-ge 4`) |
| measured on | `d6fc241f9`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| the other `local x="${1:?...}"` lines (r78 1.4: 15 in 8 iac lib / run files; 10 in 4 orc lib / run files) | the same practice as r78-02; 2 rows taken (5.1); **first candidate for r80**, re-counted there | r78 1.4 |
| `spl-spawn-place-argmax.tst.sh` section 9's two guard cases (candidates item 6, b30-01 R7 c-504 N1) | b30-01 (c-494) is on review on that file: R3; a test row once it lands | 1.2 |
| spec 181 B10 R7 m-612 N1, N2, N4 (spec text) | doc edits in specs B10 (c-492) holds; N4 waits on an owner poll | 1.2 |
| `terraform init` without `-input=false`; the desk hop's env forwarding | behaviour changes: bug rows (r78 section 7) | r78 1.2 |
| r77-01 N1 `check-ysg-box-deps.func.sh`; r77-02 N1 `SPL_*` exports | r78 section 7's reasons hold | r78 1.2 |
| `spl-unanswered-sweep-install-cron.func.sh:57` | still spelled (1.4's `n_sd` list); spec 182 lanes were live on the unanswered sweep at r78; re-check the lane map next round. Moving it after row 02 drops `n_sd` to 3 | 1.4 |
| `orc:scripts/spl-desk-reply.sh:9`, `:19` usage text lists `--kind note\|result\|reject\|blocker\|msg`, no `task` (candidates item "[refactor] SPL-6107 N1", panel N1) | not in the holder's inlined list this lane read; the script passes `DESK_KIND` through (`:52`, `:239`) and whether `task` is accepted downstream is not measured here: re-measure next round, a wording row if it is | panel N1 |
| spec 182 L2: the `!inserted` branch untested (r78 section 7, panel N2) | test-shaped; spec 182 v08 is queued (1.2's queue read), so its files stay off | panel N2 |
| the install guide's reverse-tunnel literal (`installation-and-configuration-guide.md:594`) | a Qto export: an ask to the holder | r78 1.2 |
| `spl-spool-refresh.func.sh:55`, `spl-wd-ensure.func.sh:194` | r76 to r78's reasons hold; still in the spelled baseline | r78 1.2 |
| the iac / utl spelled lines; a gate over files outside the existing scope | r77 section 7's reasons hold | r77 1.3 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | secret-class work (the data rule), r73 to r78 | r77 1.3 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, terraform layout or docs; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-509): first draft. A fresh round: row 01 rewrites the wf10 comment clause that
  overstates the disk margin (4000 MB cap, 4 G margin, 96 MB left); row 02 moves the
  desk-reconcile cron's `--print-crontab` log dir onto `spl_var_app_subdir` (same dir on
  this box's 3 tree kinds, 3 of 3), lowers the spelled baseline and moves
  `satellite-ansible.tst.sh`'s `n_sd` floor with the count. Batch 1 both. Window W and
  the r79 slug proof recorded.
- v1.0 (c-509): the panel seat m-620 (mistral) PASS on v0.1
  `043b1af86df5ce2386c5f7e2d0d2188a36f6a321` (spool msg 2388c11d to the editor, task
  `dispatch-refactor-r79`; seat file `d832b6726` on
  `review/c002-refactor-round-79-mistral-seat`, folded into this landing), no W finding.
  Its notes, none changing a row:
  - N1: `spl-desk-reply.sh:9,19` usage text omits the `task` kind, a candidates item this
    plan neither served nor named: added to section 7 (the usage lines re-read on
    `d6fc241f9`; downstream acceptance of `task` not measured).
  - N2: spec 182 L2 (`!inserted` untested) was not named: added to section 7.
  - N3: the lane map read 16 `unknown:` lanes at 02:3xZ against 1 at 02:17:49Z, none on
    a row path: noted in 2.2; the holder re-checks before placing.
- Round closed (c-509), no version bump: the 2 rows landed, r79-01 `75da57eb4`
  (SPL-6134, R7 c-554 PASS), r79-02 `21a8e0296` (SPL-6137) with the fixture commit
  `f5256aa6b` (R7 c-594 PASS on both); both R7 seats claude under waiver 1a7c70da.
  c-554's review line reads the comment-only diff count 0 and the grep 0 on head;
  c-594's reads row 02's red controls (case 9 and the old `n_sd` floor) RED on the
  parent and GREEN on head. `merge-base --is-ancestor` rc 0 for
  all three on `f5256aa6b`. On that sha (n=1 each, `SPOOL_TEST=1`): "it also covers the
  downloaded archive" in wf10 1 -> **0**; the spelled baseline **17 lines in 15 files**
  (18 in 16 before); `satellite-ansible.tst.sh` floor `-ge 4`, 96 pass;
  `no-literal-paths.tst.sh` ALL PASS (15), `desk-install-service-user.tst.sh` 0
  failures, `desk-up-all.tst.sh` all assertions pass, `ci-hub-pg-disk.tst.sh` 5 pass,
  `ci-disk-guard.tst.sh` 17 pass. Status line and sections 8 and 9 only.
  - **Plan miss (c-594 N1):** 1.4 says `desk-up-all.tst.sh` case 7 "is refused (rc 2)
    at `:175`, before the block". It is not: its fake checkout reaches the `PRINT=1`
    block, which after row 02 sources `spl-run-paths.func.sh`, and the case FAILed
    ("No such file or directory") until `f5256aa6b` copied the lib into its fixture. The
    row needed one more test file than section 2's site list named.
  - **First inputs for round 80:** (1) c-594 N1 above: a planner that clears a test
    of a row's change runs it on the row's head, not only reads it; (2) section 7's
    first candidate, the remaining `local x="${1:?...}"` lines (r78 1.4), re-counted;
    (3) `spl-unanswered-sweep-install-cron.func.sh:57` (would drop `n_sd` 4 -> 3),
    after a lane-map check; (4) the `spl-desk-reply.sh` usage text (panel N1),
    measured downstream first.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-509 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-620 (mistral) PASS** on
  `043b1af86df5ce2386c5f7e2d0d2188a36f6a321` (spool msg 2388c11d; seat file `d832b6726`
  on `review/c002-refactor-round-79-mistral-seat`, in
  `csi-spl-doc/doc/md/refactor-round-79/seat-mistral.md`), N1-N3 recorded. agy was
  unavailable (out until about 11-24), so mistral took the seat. The holder's
  review-line check on that line: rc 0 ("OK 5 of 5 named in ran: are commands in" the
  seat's session log; holder msg 44a71224). m-620 signs v1.0 next.
- Panel delta: **m-620 (mistral) PASS** on v1.0
  `2d00168fd04d22f6677a95a14b6e5d12a24d6a81` (seat file `0453a6eb7`, section "v1.0
  signature"; supersedes `5b195323d`): the row table byte-identical to v0.1.
- Row R7 seats: section 4.
- Closed: both rows landed (r79-01 `75da57eb4`, R7 c-554 PASS; r79-02 `21a8e0296` +
  `f5256aa6b`, R7 c-594 PASS). This close record carries `Closes: SPL-6126`.
