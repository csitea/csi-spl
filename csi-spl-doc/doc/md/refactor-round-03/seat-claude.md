# Refactor round 03 plan: claude panel seat verdict

Seat: **claude**, cross-vendor panel seat `c-726` (rulebook 3.2), task
`dispatch-refactor-r03`, issue SPL-6540 (epic SPL-2402, spec 011).
Review of: `../refactor-round-03-plan.md` **v0.1**, editor a-808@sat (agy),
branch `review/c002-refactor-round-03-planner`.

## Verdict

**PASS on `7103bcac49235686302754839717971f5aadcbb0`**, with W1 to fold into
v1.0.

The sha came from `git ls-remote origin refs/heads/review/c002-refactor-round-03-planner`,
which printed `7103bcac49235686302754839717971f5aadcbb0` (2026-11-25T22:5xZ). It is one commit,
`docs(r03-plan, SPL-6540): refactor round 03 plan v0.1 (2 rows)`, on parent
`5bbbf53c1`, and touches one file (`refactor-round-03-plan.md`, +836). The
plan measures on `bfdbd57d5`, an ancestor of `5bbbf53c1`
(`git merge-base --is-ancestor bfdbd57d5 5bbbf53c1` -> yes).

Both rows are what they claim: one logical refactor each, with no behaviour
change. I rebuilt both heads from the plan's verbatim blocks (1.3, 1.4) on
`bfdbd57d5`, and all 8 file sha256 values match the plan. I re-ran every suite, all 7 red and
guard controls and all 5 mutations; every count matches 1.5. I also ran my
own differential harness, not taken from the plan, over 40 + 180 cases:
the output and rc are byte-identical on base and head. The one defect is a
missing test in row 01's R2 test column (W1).

How I ran things: each tree is a `git clone --shared` of the box checkout
at `bfdbd57d5` in my session scratch dir (a git tree, so
`no-literal-paths.tst.sh` reads it), run as the seat user with
`SPOOL_TEST=1`, `SPOOL_BOX_TAG`/`SPOOL_AGENT_ID` unset and stdin from
`/dev/null`. Pass lines are counted with `grep -ciE '^ *(ok|pass)'` and fail
lines with `grep -ciE '^ *(not ok|fail)'`, as the plan's 1.5 does. n=1 per
command.

## 1. Slug r03 unused since `W` (plan 1.1)

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r02-plan'`
  -> `118477b2a1a61038babeefc3567e7390163c5717 2026-11-25T23:34:49+02:00 docs(r02-plan, SPL-6526): refactor round 02 closed: ...`.
  This is the newest plan commit of the previous refactor round, so
  `W=2026-11-25T23:34:49+02:00` is right per rulebook 5.3.
- `git log origin/master --since="$W" --oneline -E --grep='\(r03-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r03-[0-9]{2}|refactor-round-03'` -> only
  `7103bcac... refs/heads/review/c002-refactor-round-03-planner` (the planner's
  branch, which is expected; my seat branch did not exist yet).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r03-[0-9]{2}|refactor-round-03'`
  on this seat's box -> nothing (rc 1). The planner's brief and this seat's
  brief live on the holder's box. This seat's brief is the lane's own
  `lifetime/brief.md`, and the path relayed for it
  (`dispatch/briefs/c002-refactor-round-03-claude-panel-seat.md`) does not
  exist on this box. Briefs on this box that contain `r03` without matching
  the pattern (`c002-sat-alone-r03-issue-close-holder.md`,
  `c002-tokens-tab-r03-*.md`, `c003-anim-r03-reaction-pop.md`) belong to
  other review rounds, not refactor rows.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -E 'refactor-round-0?3'`
  -> `refactor-round-3-plan.md`, `refactor-round-3-retro.md`,
  `refactor-round-3/` and `refactor-round-30..35-plan.md`. There is no
  `refactor-round-03*`, so neither the plan nor this seat dir needs a date
  suffix (5.3 Files).

## 2. Sites exist on the base and on origin/master (plan 1.3, 1.4)

- `git diff --name-only bfdbd57d5 origin/master -- <13 paths: the 8 edited files, setup-box-stats-cron.func.sh and the 4 regression suites>`
  -> 0 files at `5bbbf53c1` (22:5xZ), and again 0 at `85f11faa9`
  (23:08Z, 6 commits past `bfdbd57d5`).
- `git log origin/master --since='24 hours ago' -- <the 13 paths>` -> only
  `8ff47fd73` (r02-02) and `3582fc44b` (r01-02), both already in the base.
- Line counts on `bfdbd57d5` match the plan's "from" counts: 92, 64, 106,
  93, 82, 81, 99 and 95 for the 8 edited files.
- Each cited line, read with `sed -n <N>p` on `bfdbd57d5`:
  - `spl-hub-agent-kinds.func.sh:69` = `# _spl_hub_fleet_load_error <subject_verb> -> ...`.
  - `hub-agent-kinds.tst.sh:105` and `hub-runner-cpu.tst.sh:92` =
    `[[ "$fails" -eq 0 ]] && { echo "PASS: all ..."; exit 0; }`.
  - `setup-gh-runner-cpu-budget-cron.tst.sh:93` = `echo`.
  - The `local ... current ...` lines are at `check-env-order-install-cron.func.sh:38`,
    `setup-ci-overflow-cron.func.sh:32` and `setup-gh-runner-cpu-budget-cron.func.sh:45`.
  - `_spl_simple_cron_apply` spans `setup-box-stats-cron.func.sh:67-105`.
  - `spl-review-go.tst.sh:1078,1096,1103,1109` are fixture markdown that
    names `do_spl_hub_agent_kinds`.
- Row 01's body diff, `diff <(sed -n 30,40p spl-hub-agent-kinds.func.sh) <(sed -n 29,39p spl-hub-runner-cpu.func.sh)`,
  -> one hunk `8c8`: the dry-run `do_log` action phrase only.
- Row 02's body diffs:
  - `setup-ci-overflow-cron.func.sh:50-80` against
    `setup-gh-runner-cpu-budget-cron.func.sh:68-98` -> 8 changed lines, i.e.
    4 one-line hunks (four labels).
  - The same block against `check-env-order-install-cron.func.sh:52-81` ->
    the 4 label hunks plus the one-line wrap of `[[ -n "$ran" && -x "$ran" ]] ||`
    (`7,8c7`).
  - Every line in these ranges, apart from the labels, the
    `ok_msg` and the `: prd ahead of dev warns nobody` suffix, is
    byte-equal to `_spl_simple_cron_apply` (read side by side).
- `git grep -nE '_spl_hub_fleet_load_prep|SPL_FL_DRY_DONE'` on the base ->
  0 lines.

## 3. Red controls, guard controls and mutations (plan 1.5)

Each head file was rebuilt from the plan's verbatim blocks. `sha256sum` (12
chars), `wc -l` and `git diff --numstat` all equal the plan's:

| file | sha256 | lines | numstat |
|---|---|---|---|
| `spl-hub-agent-kinds.func.sh` | `d5669d819ac0` | 106 | +25 -11 |
| `spl-hub-runner-cpu.func.sh` | `1e90207feada` | 58 | +5 -11 |
| `hub-agent-kinds.tst.sh` | `caafd2cde3bc` | 153 | +47 -0 |
| `hub-runner-cpu.tst.sh` | `2f92257b18c7` | 106 | +13 -0 |
| `check-env-order-install-cron.func.sh` | `a0a3a3065509` | 57 | +6 -31 |
| `setup-ci-overflow-cron.func.sh` | `5b72fb89a439` | 54 | +5 -32 |
| `setup-gh-runner-cpu-budget-cron.func.sh` | `abe05471b1f7` | 72 | +5 -32 |
| `setup-gh-runner-cpu-budget-cron.tst.sh` | `2a074cdaf4b7` | 150 | +55 -0 |

Each control and mutation ran in its own clone (n=1). "Last line" is the
suite's final output line.

| control | suite | rc / pass / fail | last line, and the first failing line |
|---|---|---|---|
| rc1a (head1 test on base) | hub-agent-kinds | 1 / 23 / 8 | `FAIL: 7 assertion(s) in hub-agent-kinds.tst.sh`; 6 x `_spl_hub_fleet_load_prep: command not found` (rc 1 or 127), plus `FAIL: 7. kinds prep one copy` |
| rc1b (head1 test on base) | hub-runner-cpu | 1 / 18 / 2 | `FAIL: 1 assertion(s) ...`; `FAIL: 7. cpu prep one copy: own=[29: ... FATAL ORDERED_BY must be a HUM-* id ...` |
| gc1 (guard line deleted) | hub-runner-cpu | 1 / 17 / 3 | `FAIL: 2 assertion(s) ...`; `6. lazy cpu` and `7. lazy prep cpu`: `spl-hub-runner-cpu.func.sh: line 31: _spl_hub_fleet_load_prep: command not found` |
| rc2 (head2 test on base) | setup-gh-runner-cpu-budget-cron | 1 / 14 / 3 | `setup-gh-runner-cpu-budget-cron: 3 FAILED`; one-copy own=`[60:` / `[59:` / `[77: ... is installed and its script is executable` |
| gc2a | same | 1 / 15 / 2 | `5. lazy eo` and `5. eo ok` rc=127, `check-env-order-install-cron.func.sh: line 53: _spl_simple_cron_apply: command not found` |
| gc2b | same | 1 / 15 / 2 | `5. lazy co` and `5. co ok` rc=127, `setup-ci-overflow-cron.func.sh: line 51: ...` |
| gc2c | same | 1 / 9 / 8 | `dry default`, `derived log dir`, `install default`, `reinstall`, `check`, `floor 0`, `5. lazy cb`, `5. cb ok`; `line 69: ...` |
| m1a | hub-agent-kinds | 1 / 29 / 2 | `FAIL: 1. dry: ... to set the runner CPU cap to grok ...` |
| m1b | hub-runner-cpu | 1 / 17 / 3 | `FAIL: 1. dry` and `FAIL: 7. lazy prep cpu` (`switch off the agent kinds [80]`) |
| m2a | setup-gh-runner-cpu-budget-cron | 1 / 16 / 1 | `FAIL: 5. lazy eo (rc=1): ... (no line tagged csi-spl:env-order)` without the suffix |
| m2b | same | 1 / 15 / 2 | `5. lazy co`, `5. co ok` (`the box-stats cron`) |
| m2c | same | 1 / 15 / 2 | `5. lazy cb`, `5. cb ok` (`the box-stats cron`) |

Every red fails for the reason the plan gives:

- The helper is missing, or the action still holds its own copy (one-copy
  greps).
- The guard is gone (`command not found` from the action file's own line).
- A label or suffix was swapped.

None fails for an environment reason. The heads themselves are green: head1 gives
0/31/0 and 0/20/0, head2 gives 0/17/0.

Live state: none of the controls touches any.

- The hub tests stub `do_spl_cloud_cnf`, `spl_hub_operator_url` and
  `do_log`. Every new row-01 case is either a dry run or a direct call of
  the helper, which never reaches `do_gcp_pin_account` or a hub call.
- The row-02 section 5 puts a stub `crontab` first on `PATH`, writes to
  `FAKE_CRONTAB=$T/crontab.s5`, and uses `DESK_CRON_SRC=$T/shared` and
  `*_CRON_LOG_DIR=$T/log-*`. `spl_desk_cron_checkout` is a no-op unless
  `SPL_DESK_CRON_CREATE=1` (`spl-desk-cron-checkout.func.sh:16`).

Weakness (not a defect): rc1a's 6 direct-helper checks are red only because
the helper is absent. The structural reds are rc1a's one-copy check, rc1b and
rc2.

## 4. Equivalence per row

**Row 01.** The cited code was read on `bfdbd57d5`:

- `spl-hub-agent-kinds.func.sh:25-53`
- `spl-hub-runner-cpu.func.sh:23-52`

The new `_spl_hub_fleet_load_prep` runs the same statements in the same
order as `:30-40` and `:29-39`. The checks that differ per action
(`_spl_hub_agent_kinds_list`, the `RUNNER_CPU_PCT` range) stay in the
callers, before the helper, as they were. `$SPL_HUB_URL` and `$SPL_PROJECT`
are still expanded after `do_spl_cloud_cnf` and `spl_hub_operator_url`,
because the action phrase is passed in and the log line is built inside the
helper. `do_gcp_pin_account` and `do_gcp_require_live_account` stay in the
callers.

`kinds=""` replaces the bare `local kinds`. That is no change: `kinds` is
read only as `${kinds:-none}` (dry run) and `--arg k "$kinds"` (write mode,
always set). The `drc` local moves into the helper, and the return codes
are unchanged.

My differential harness sources each action file on base and on head1 and
runs both actions over 20 env cases each (40 runs). Only the edges are
stubbed (cloud cnf, URL, pin, operator call with code 200/403/500); the cases
cover read, dry run, `KINDS_OFF=none` and bogus, bad `ORDERED_BY`,
`ORDERED_VIA` > 64, `DRY_RUN=0` with and without `ORDERED_BY`, a bad
`DRY_RUN`, `RUNNER_CPU_PCT=0` and `default`, and a cnf failure. The output
plus rc is byte-identical (`diff` empty): 24 rc 0, 16 rc 1, 4 `CALL PATCH`,
11 `FATAL`.

The plan's controls would catch a difference in the dry-run phrase (m1a, m1b),
a lost guard (gc1) or an own copy left behind (rc1a, rc1b). The `1. dry` and
`7.` checks pin the exact dry-run text.

**Row 02.** The three installers' `:52-81`, `:50-80` and `:68-98` equal
`_spl_simple_cron_apply` `:70-104` except for the label, `ok_msg` and
`miss_why` arguments. The `current` local moves into the helper.
`setup-box-stats-cron.func.sh` has no top-level code other than three
guarded `declare -F ... || source` lines, so sourcing it from inside a
function defines functions only (and `do_setup_box_stats_cron` as a side
effect, as r02-02 already does for two siblings).

My differential harness runs each installer, on base and on head2, over
every combination of:

- 5 crontab states: empty, a foreign line, a stale line, a non-executable
  script, and a differing line with an executable script;
- 4 actions: `install`, `remove`, `check` and `bogus`;
- 3 values of `DRY_RUN`: 1, 0 and `x`.

That is 180 runs with a stub crontab. The output, rc and final crontab
are byte-identical. All branches are reached:

- 12 installs, 15 removes and 12 "NOT installed";
- 12 "gone or not executable", 6 "INFO installed with other settings"
  and 6 "is installed";
- 30 "OK DRY_RUN" and 3 "missing or not executable in";
- 0 `command not found`.

The plan's controls catch a lost guard (gc2a-c), a wrong label or a lost
suffix (m2a-c), and an own copy left behind (rc2).

**Gates on base / head1 / head2**: identical rc 0 and counts for all 9 shared
suites:

| suite | pass |
|---|---|
| `no-box-path-source` | 10 |
| `action-header-tags` | 6 |
| `param-required` | 17 |
| `run-lazy-loader` | 30 |
| `bash-cleancode` | 15 |
| `gcloud-account-pinned` | 48 |
| `run-eager-files` | 14 |
| `no-literal-paths` | 15 |
| `func-name-unique` | 2 |

The row suites on base and head:

| suite | base | head | change |
|---|---|---|---|
| `hub-agent-kinds` | 24 | 31 | +7 |
| `hub-runner-cpu` | 18 | 20 | +2 |
| `setup-gh-runner-cpu-budget-cron` | 8 | 17 | +9 |
| `check-env-order` | 34 | 34 | = |
| `route-ci-overflow` | 38 | 38 | = |
| `apply-gh-runner-cpu-budget` | 90 | 90 | = |
| `box-stats-cron` | 44 | 44 | = |

`shellcheck` 0.10.0 `-S warning -x` on the 4 head1 files gives rc 0, and on
the 4 head2 files rc 0.

Function lengths are well under the cap of 75 (awk over `^name() {`..`^}`).

- `do_spl_hub_agent_kinds`: 29 -> 21.
- `_spl_hub_fleet_load_prep`: 17.
- `do_spl_hub_runner_cpu`: 30 -> 24.
- `do_check_env_order_install_cron`: 54 -> 29.
- `do_setup_ci_overflow_cron`: 53 -> 26.
- `do_setup_gh_runner_cpu_budget_cron`: 58 -> 31.

## 5. Row fields, R1, R2 and R7

Both rows carry everything required:

- a red control that fails today and passes after;
- a test list;
- vendor **claude** and kind `simple_coding`;
- batch 1 and box `either`.

Neither is a mistral coding or testing row. R7 is an **agy** seat, with the
claude waiver backup only under ruling `dc84300a`, and never mistral; that
satisfies 2.7.2 for a claude author.

R1 holds: row 01's 4 files and row 02's 4 files are disjoint (plan 2.1,
checked against the numstat of each head).

R2: the 30-character comment scan finds 10 comments of at least 30
characters in the 5 `.func.sh` files, with 0 hits in any `*.tst.sh`,
`*_test.go`, `*/tests/*`, `*.test.*` or `*.spec.*`. I scanned whole files,
a superset of the ±3 lines around each site. Row 02's name grep gives
exactly the plan's 5 suites. Row 01's does not; see **W1**.

## 6. R3

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <13 paths> --agent c-726`
ran at 2026-11-25T23:08:44Z. The 13 paths are the 8 edited files, the 4
regression suites and `setup-box-stats-cron.func.sh`, plus
`box-stats-cron.tst.sh`. It returned **exit 4**: "no live lane lists
<the 13 paths>, but 9 live lane(s) record no files".

The 9 `unknown:` lanes are all on the holder's box: a-801, a-806, a-808 (the
planner), a-810, a-823 (SPL-6516 latency reviewer, new since the plan's
read), c-298, c-718, c-722 and c-780. Six of them have a head on origin:

- `review/a-806-spec150-v1.9`
- `review/a-810-spec196-v0.3`
- `review/c-298-taxes-{0326,build,tab}`
- `review/c-718-c002-e3b16fea-lat-a6-grok-agy`

For each, `git diff --name-only $(git merge-base origin/master <head>) <head> -- <the 13 paths>`
-> 0 files. a-801, a-823, c-722 and c-780 have no head on origin, so I could
not check their files from this box. Their scopes, as the plan names them
(2.2) and as their branch names say, are pin-hold quota, latency review and
hub "seen" records. Nothing points at a row file.

The plan's own R3 read, 19 `unknown:` lanes at 22:28:22Z, differs only by
time. The holder re-reads at placement, as R3 says.

## 7. Inputs accounted for, and refactor-only

- **r02 plan section 7** (read on `origin/master`), all 7 rows:
  - #1, the fleet-load write guard, is served by row 01.
  - `spl-msg-{dedup,wipe}`, `spl-box-restart`/`spl-peer-crons`/the 5
    probes, `gcp-*alert*`, `spl-channel-agent-*`, the `_spl_*_holder`
    trio, and the box-band/wui-perf/utl/secret/sec/Go-WUI catch-all are
    each carried in r03 section 7 with a reason.
  - None is dropped.
- **`/var/spool-hub/dispatch/c002-next-round-candidates.md`**: **NOT RUN**.
  The file is not on this seat's box (`ls` -> No such file or directory); it
  is on the holder's box. The only candidates-like file here,
  `c002-a8000a91-candidates.txt`, is a 66-line topic dump from 09-25, not a
  round input. I take the plan's 1.2 (c) read (no `## for refactor round 03`
  block) as unchecked.
- **Refactor only.** Neither row changes an exit code, a message, a path or a
  default. That is shown by the 220 byte-identical differential runs in
  section 4 and by the unchanged counts of the 4 + 9 untouched suites. The
  only new state is the unexported shell global `SPL_FL_DRY_DONE` (N3).

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` on this worktree at
`85f11faa9` -> rc 0, last line `INFO distribution-hygiene: clean over the
tracked tree`.

## Defects

- **W1 (R2 test column, row 01, plan line 599 and 1.5 at lines 583-586).**
  R2 puts in the column every test file that names a function the site
  defines. `csi-spl-api/src/go/spool-hub-api/internal/hub/fleet_load_test.go:238`
  names `do_spl_hub_agent_kinds`:
  `// member session: the path of csi-spl-orc do_spl_hub_agent_kinds. A token`.
  The plan's grep is limited to `*.tst.sh` and `features/*/tests/*`, so it
  misses this file. R7's C4 requires the reviewer to run every column test or
  list it as `NOT RUN`.
  Fix in v1.0, either way:
  - add it to row 01's column (for example
    `cd csi-spl-api/src/go/spool-hub-api && go test ./internal/hub -run FleetLoad`);
  - or write in 1.5 why it stays out: it is a comment-only mention, row 01
    changes no Go code, and the PATCH body is byte-identical (section 4).

  Measured with `git grep -lE '<plan 1.5 row-01 pattern>' -- '*.tst.sh' '*/features/*/tests/*' '*_test.go' '*.test.*' '*.spec.*'`
  on `bfdbd57d5`, which lists `fleet_load_test.go` together with the plan's
  3 files.

## Notes

- **N1 (plan line 302).** The pass label of the `hub-agent-kinds.tst.sh`
  one-copy check says "defines and calls `_spl_hub_fleet_load_prep` once",
  but the check asserts `grep -c "_spl_hub_fleet_load_prep " -ge 1`. The
  header comment alone satisfies that. The one-copy proof comes from the three
  FATAL-string counts (`-eq 1`), so the check is sound and only the wording
  overstates it. Suggested label: "holds one copy of the write-mode prep".
- **N2 (plan lines 443-484).** The new section 5 runs inherit any ambient
  `ENV_ORDER_CRON_AT`, `ENV_ORDER_CRON_ACTION` or `CI_OVERFLOW_CRON_ACTION`,
  since only the `CPU_BUDGET_*` vars are `env -u`'d. An exported value would
  turn `5. eo ok` and `5. co ok` red. That is low risk: the existing
  sections do the same.
- **N3 (plan lines 222-235).** `SPL_FL_DRY_DONE` is a new global left set in
  the `./run` shell after either action. It is documented in the helper
  header, and `git grep` finds 0 other readers. That is acceptable for a
  refactor row, and the R7 reviewer should confirm it stays unexported.
- **N4 (plan lines 60 and 834).** The status of this seat is "live" at line
  60 and "queued with this planner" at line 834. v1.0 should say "signed on
  `<sha>`".
- **N5 (plan lines 92-94).** The briefs claim (2 briefs) can be checked only
  on the holder's box. On this seat's box neither brief is under
  `dispatch/briefs` (section 1). Not a defect.
- **N6.** At 23:08Z `git-fetch-fresh.sh` printed `Could not resolve host:
  github.com`, but `origin/master` had moved to `85f11faa9` (6 commits past
  the base), and `git ls-remote` worked. The drift check in section 2 used
  that `origin/master`.

## Signatures

- v0.1 `7103bcac49235686302754839717971f5aadcbb0`: **PASS** (W1 to fold),
  c-726, 2026-11-25.
