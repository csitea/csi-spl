# Refactoring round 77 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6081  
Topic: 46307435-c998-446b-81c8-9d273fe1c0ac  
Discussion: 46307435-c998-446b-81c8-9d273fe1c0ac (t1 #refactoring, "Refactor round 77", opener msg 104cb484)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r77**, plan `refactor-round-77-plan.md`, rows `r77-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 76 ([refactor-round-76-plan.md](refactor-round-76-plan.md))
is closed (`74df8bcdf`): r76-01 landed `a70a2bbc7` (SPL-6069), r76-02 landed `7772cb07e`
(SPL-6070). No signed row is handed on: r77 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `2547249ec`: `perf 29 refactor 106 perf-share 21.5% floor-met`,
so this is a refactor round.

r73 to r76 moved 9 cron installers off a var dir spelled by hand from a variable
(`/var/${X%%-*}/$X/<sub>`) onto r71-01's helper `spl_var_app_subdir`. Nothing stops a
new one: `no-literal-paths.tst.sh` bans only the literal `/opt/<org>` and `/var/<org>`.
r76 named the gate for that shape as this round's first candidate, its baseline cut
once after r76 landed (r76 section 7). **Row 01** is that gate, a ratchet over every
spelling. **Row 02** moves the 2 `features/box-sessions` scripts (r76 section 7's other
round-77 candidate) and lowers row 01's baseline by their 2 lines.

**Status: v1.0**: panel seat m-484 (mistral) PASS on v0.1 `8badbf473`, one W finding
(W1, row 02's scratch layout, fixed) and N1-N4 recorded (section 8); no row changes
scope. m-484 PASS on v1.0 `1a835fa8c` too (section 9). Editor: **c-481** (claude).

**Round closed** (c-481, the editor): both rows landed. r77-01 `a8d2ea7d5` (SPL-6092,
R7 c-526 PASS on `32b64680f`), r77-02 `7ff2604dd` (SPL-6104, R7 c-343 PASS on
`586f33fca`). Read `git merge-base --is-ancestor <sha> origin/master` -> rc 0 for both,
at `7ff2604dd`. On that sha: `no-literal-paths-spelled.baseline` holds **17** files,
**19** lines (row 02's 19 -> 17 and 21 -> 19, as planned); `grep -c bs_org_app` -> 0 in
both box-sessions scripts; `no-literal-paths.tst.sh` rc 0 `ALL PASS` (17 files left);
`test-box-sessions.sh` 51 passed, 0 failed (1.5's 44 plus the new ones). n=1 each,
2026-11-20T21:5xZ, `SPOOL_TEST=1`, as the push user.

**One sha:** every count is measured on **`7df5cecfc`** (`origin/master`
7df5cecfc47f063e4c37818ea4b78bc5328382d7, committed 2026-11-20T20:04:17+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T19:53:31+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r76-plan'` -> commit
  `74df8bcdf` "refactor round 76 plan records the round closed, rows 01-02 landed".
  Every later read of r77 uses this W.
- **`r77` is free** (2026-11-20T18:11:43Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r77-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r77-*' 'refs/heads/wip/*r77*' 'refs/heads/*-r77-*' 'refs/heads/*refactor-round-77*'`
    -> **nothing** (rc 0). This planner's review branch is pushed after that read.
  - `grep -rlE 'r77-[0-9]{2}|refactor-round-77' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **2 files**: this planner's brief and the mistral
    panel seat's brief. The other box's briefs were not read by this lane.
  - Control: the same log read with `(r76-` since W -> 1 line, `74df8bcdf` (the r76
    close record), so the read sees a used id.
- **No `refactor-round-77*` file** exists under `csi-spl-doc/doc/md` on `7df5cecfc`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-77` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`.

| input | source | on `7df5cecfc` | here |
|---|---|---|---|
| the gate for the shape (extend `no-literal-paths.tst.sh` with a baseline over all spellings, `run/`, `scripts/` and `features/`) | r76 section 7, lines 87 and 362 | `no-literal-paths.tst.sh:42` still greps `/(opt\|var)/<org>` only; the spelled shape: **21 lines in 19 files** in its scope (1.3) | **row 01** |
| `features/box-sessions/scripts/{save-sessions,sessions-boot}.sh:41` | r76 section 7, line 361 | both lines there, unchanged; same dir on this box's 3 tree kinds, 3 of 3 (1.4) | **row 02** (after row 01) |
| `spl-unanswered-sweep-install-cron.func.sh:57` | the brief | the site is there; spec 182 L2b (c-973) is live | left out (section 7); row 01 lists it in its baseline only |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`) | the brief | on this lane's box: 13535 bytes, last changed 2026-11-20 14:13 (box local), the same size and time r76 read. Its refactor-shaped items are served on `7df5cecfc`: `reverse-tunnel-cron.sh:27` reads `$SPL_VAR_APP_DIR/reverse-tunnel`; the agent-boot-restore writer (`spl-agent-boot-restore-install-cron.func.sh:60`) and reader (`spl-watchdog.func.sh:541`) call `spl_var_app_subdir`; the watchdog / lane-rotate `/var` literals: `git grep -nE '/var/'` on both files, comments out -> 0 | nothing taken |
| r76 R7 findings | the brief | `a70a2bbc7` (c-186) and `7772cb07e` (c-205): `git log -1 --format=%B <sha> \| grep -nE '^(- ?)?(N[0-9]\|W[0-9])'` -> 0 each; one `review:` line each | nothing taken |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r76's reasons hold |

### 1.3 The spelled var dirs, repo-wide (row 01's baseline)

`lib:spl-run-paths.func.sh:66-76` (`spl_run_paths`) derives `SPL_VAR_APP_DIR` =
`<var>/<org>/<main checkout name>`; `spl_var_app_subdir <var> <sub>` (`:81-85`) sets the
named variable to `$SPL_VAR_APP_DIR/<sub>`. The developer guide (2.3.1): "No action
carries a literal `/opt/<org>` or `/var/<org>` path". A dir spelled from a variable is
the same path, written by hand, and `no-literal-paths.tst.sh` cannot see it.

**The pattern** (ERE): a root `/opt/` or `/var/` (not after a letter, digit, `_` or `}`,
so the helper's own `${base%/*}/var/...` is not counted), then one variable, bare or
braced, optionally with `%%-*`, then `/`:

```text
(^|[^A-Za-z0-9_}])/(opt|var)/\$\{?[A-Za-z_][A-Za-z0-9_]*(%%-\*)?\}?/
```

**The scope** is the existing gate's own (`nlp_counts`, `:40-41`): every tracked
`csi-spl-cnf/**/*.{yaml,yml,json}`, every `*.func.sh`, and every other `*.sh` outside a
`tests/` dir. On `7df5cecfc` that is 1259 files. The count, comment lines included as the
existing gate counts them:

```text
git grep -hcE '<the pattern>' 7df5cecfc -- <the 1259 files> | awk '{n+=$1} END{print n, NR}'
```

-> **21 lines in 19 files** (the same 21 without the leading boundary; no comment line
among them):

| lines | file | what it is |
|---|---|---|
| 1 | `csi-spl-iac/src/bash/run/gcp-backup-env.func.sh` | backup root, secret-class (r73) |
| 1 | `csi-spl-iac/src/bash/run/gcp-s3-download-all.func.sh` | download target |
| 1 | `csi-spl-iac/src/bash/run/install-weekly-full-scan-cron.func.sh` | cron log dir |
| 1 | `orc:features/box-sessions/scripts/save-sessions.sh` | state dir (row 02) |
| 1 | `orc:features/box-sessions/scripts/sessions-boot.sh` | state dir (row 02) |
| 1 | `orc:run/check-ysg-box-deps.func.sh` | `/opt/$box_user/`, a pattern for a user's dir, not a var dir (r76 panel N4) |
| 1 | `orc:run/spl-desk-install-service.func.sh` | cron log dir (r76 section 7) |
| 1 | `orc:run/spl-desk-rebox.func.sh` | tenant dir, secret-class |
| 1 | `orc:run/spl-invite-e2e.func.sh` | tenant dir, secret-class |
| 1 | `orc:run/spl-m3-e2e.func.sh` | tenant dir, secret-class |
| 1 | `orc:run/spl-spool-refresh.func.sh` | an operator NOTE text |
| 1 | `orc:run/spl-unanswered-sweep-install-cron.func.sh` | cron log dir (spec 182 L2b live) |
| 1 | `orc:run/spl-wd-ensure.func.sh` | a log reader |
| 1 | `orc:scripts/desk-reconcile-cron.sh` | cron wrapper |
| 2 | `csi-spl-utl/src/bash/run/box-disk-guard-install.func.sh` | `/opt/$org/$app`, `/var/$org/$app` |
| 2 | `csi-spl-utl/src/bash/run/box-proc-sample.func.sh` | desk checkout, sample dir |
| 1 | `csi-spl-utl/src/bash/scripts/box-disk-inventory.sh` | growth tsv |
| 1 | `csi-spl-utl/src/bash/scripts/disk-crossing-sizes.sh` | sizes tsv |
| 1 | `csi-spl-utl/src/bash/scripts/disk-growers.sh` | growth tsv |

In `orc:` outside tests this is r76's three gates (2 + 3 + 3 = 8 lines, r76 1.3, re-read on
`7df5cecfc`: `SPL_ORG_APP` 3 -> 2 and `org_app|ORG_APP|app` 5 -> 3, as r76 planned)
plus the 2 `bs_org_app` lines and `check-ysg-box-deps`; iac adds 3 and utl 7.

### 1.4 Row 02's sites: the box-sessions state dir

Both scripts open the same way (`:35-41`, identical in the two files):

```text
BS_ORC="$(cd "$BS_SELF/../../../../.." && pwd)"
. "$BS_SELF/../../spawn-agents/lib/spool-env.inc.sh" || exit 2
bs_org_app="$(basename "$BS_ORC")"; bs_org_app="${bs_org_app%-orc}"
BS_DIR="${BOX_SESSIONS_DIR:-/var/${bs_org_app%%-*}/$bs_org_app/box-sessions}"
```

`bs_org_app` is read only on `:41` (`grep -n bs_org_app` -> `:40`, `:41` in each file).
They are standalone scripts run from cron (`save-sessions.sh` each minute,
`sessions-boot.sh` `@reboot`), not `./run` actions: they source `spool-env.inc.sh`, not
the run lib, and `spool-env.inc.sh` sets no `APP_PATH`, `PROJ_PATH` or `SPL_VAR_APP_DIR`
(`grep -nE '^\s*(export )?(APP_PATH|PROJ_PATH|SPL_VAR_APP_DIR)='` -> 0). With neither set,
`spl_main_checkout` falls back to `_spl_run_paths_top`, the checkout the lib file sits
in (`lib:spl-run-paths.func.sh:33-36`), which is `$BS_ORC/..`. So sourcing
`$BS_ORC/lib/bash/funcs/spl-run-paths.func.sh` derives the dir from the script's own tree.

**Same dir today, measured** (this lane's box, 2026-11-20T18:13:44Z, n=1 per tree; run
as the push user under `env -i PATH=/usr/bin:/bin`): for `BS_ORC` = the main checkout's,
the desk-cron checkout's (a worktree) and this lane's worktree's `csi-spl-orc`, the hand
form and `spl_var_app_subdir d box-sessions` (sourced from that tree's lib) print the
same path: **3 of 3 EQUAL** (`/var/<org>/<org>-<app>/box-sessions`). The forms differ
only where r74 to r76's 1.3 say: a tree outside `<base>/<org>/<app>`, a preset
`SPL_VAR_APP_DIR` (it wins), and an `APP_PATH` / `PROJ_PATH` in the caller's env naming
another tree.

**The shape** (per file; the override kept, an empty one treated as unset as today):

```text
if [[ -n "${BOX_SESSIONS_DIR:-}" ]]; then BS_DIR="$BOX_SESSIONS_DIR"
else
  # shellcheck source=../../../../../lib/bash/funcs/spl-run-paths.func.sh
  . "$BS_ORC/lib/bash/funcs/spl-run-paths.func.sh" || exit 2
  spl_var_app_subdir BS_DIR box-sessions || { echo "<script>: cannot derive the state dir (spl_run_paths): set BOX_SESSIONS_DIR" >&2; exit 2; }
fi
```

The `bs_org_app` line goes. Exit 2 is each header's "usage or a missing library". Net
**+4 lines** per file.

**The suite** `orc:features/box-sessions/tests/test-box-sessions.sh` (136 lines) exports
`BOX_SESSIONS_DIR="$T/state"` at `:22` for every case: no case reads the default.
`save-sessions.sh:62` creates `$BS_DIR/archive` before anything else, so **a run of the
parent with the override unset writes the box's live state dir**. The row's red control
must therefore never run the parent's scripts from this tree with the override unset
(row 02, "red control").

The other tests that name either script (`git grep -lE 'save-sessions|sessions-boot' -- '*tests/*'`):
`orc:tests/boot-cron-gate.tst.sh` and `orc:tests/peer-restart.tst.sh` write stub copies
of the scripts; `orc:tests/install-box-crons.tst.sh` and `orc:tests/spl-box-deploy.tst.sh`
check the cron lines and tags. None runs the real scripts or reads `:41`.

### 1.5 Before (this lane, worktree at `7df5cecfc`)

2026-11-20T18:13:31Z to 18:13:37Z, n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`:

| suite | row | rc | pass lines | fail lines | last line |
|---|---|---|---|---|---|
| `orc:tests/no-literal-paths.tst.sh` | both | 0 | 8 | 0 | `ALL PASS` |
| `orc:features/box-sessions/tests/test-box-sessions.sh` | 02 | 0 | 44 | 0 | `-- test-box-sessions.sh: 44 passed, 0 failed` |
| `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | both | 0 | 15 | 0 | `PASS: all bash-cleancode.tst.sh assertions` |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `test(r77-01-orc-no-literal-paths-spelled-var-dirs)` | a gate with a red control (developer guide 2.12.1); canonical paths, no box path in an action (2.3.1) | r73 to r76 moved 9 hand-spelled var dirs by hand, and nothing stops a 10th: the literal-path gate sees only `/opt/<org>`, `/var/<org>` | **`orc:tests/no-literal-paths.tst.sh`** (`nlp_counts` `:38-44`, `nlp_check` `:47-58`, the fixture `:60-91`, the tree check `:93-99`)<br>`orc:tests/no-literal-paths-spelled.baseline` (new) | 1 gate, 21 lines in 19 files | **Gate:** a second ratchet in the same suite, same scope (`nlp_counts`' file list) and same rules (NEW / MORE / STALE), over 1.3's pattern, with its own baseline `no-literal-paths-spelled.baseline` (`<lines> <file>`, 1.3's 19 entries, a header line saying it only shrinks). Make the counter take its pattern (or a second counter), so the existing literal check and its baseline are unchanged. **Red controls** on the fixture tree, each FAIL: a new `run/*.func.sh` with `/var/${oa%%-*}/$oa/x`; a new `scripts/*.sh` with `/opt/$org/$app`; a new `features/*/scripts/*.sh` with one; a listed file that grew; a stale (too high) entry. **Pass** on the fixture: `$SPL_VAR_APP_DIR/x`, `${base%/*}/var/${org##*/}` (the helper's form), `/var/log/x`, `/opt/tf/bin`, the spelled form under a `tests/` dir. **Tree:** `pass` with 19 files left; the existing literal check still passes with its 1 file. Seen RED then GREEN, outputs in the body (C2). Pass lines 1.5's 8 plus the new ones. Tests: `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`; R9: once under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset, before the first push. | either | claude | tests | 1 |
| 02 `refactor(r77-02-orc-box-sessions-var-app-subdir)` | canonical paths (2.3.1); folded helpers exist once (2.2.4) | the 2 box-sessions cron scripts spell their state dir by hand; the run lib's helper derives the same dir (1.4, 3 of 3) | `orc:features/box-sessions/scripts/save-sessions.sh:40-41`<br>`orc:features/box-sessions/scripts/sessions-boot.sh:40-41`<br>`orc:tests/no-literal-paths-spelled.baseline` (drop the 2 lines)<br>(+ one new case in `orc:features/box-sessions/tests/test-box-sessions.sh`) | 2 sites | Each site takes 1.4's shape. **Gate:** row 01's ratchet, baseline 19 -> **17** files (21 -> 19 lines); the 2 entries dropped in this commit, else its STALE check fails. **New case:** `BOX_SESSIONS_DIR` unset (`env -u`), `SPL_VAR_APP_DIR=$T/var`: a `save-sessions.sh --stdout` against the suite's own tmux socket writes `$T/var/box-sessions/state.tsv`, and a `sessions-boot.sh --foreground` reads it from there (its marker or `boot.log` under `$T/var/box-sessions`); nothing else is created. **Red control:** that case FAILs on the parent, run ONLY on a scratch copy of the parent's **`csi-spl-orc` subtree**, renamed so its own dir is `acme-app-orc`: `mkdir -p $T/opt/acme/acme-app/acme-app-orc && git archive <parent> csi-spl-orc | tar -x --strip-components=1 -C $T/opt/acme/acme-app/acme-app-orc` (panel W1: a whole-repo archive keeps the dir name `csi-spl-orc`, so the hand form names the LIVE `/var/<org>/<org>-<app>/box-sessions`). Its hand form then names `/var/acme/acme-app/box-sessions`; check `[[ ! -e /var/acme ]]` first, and the run fails `cannot create /var/acme/acme-app/box-sessions`, rc 1 (1.4: never run the parent's scripts from a live tree with the override unset); output in the body. **Behaviour:** on this box, the derived dir printed by both forms is equal for the 3 trees of 1.4, re-run on the lane's start sha, in the body. Suite pass lines 1.5's 44 plus the new ones. Tests: `test-box-sessions.sh`, `no-literal-paths.tst.sh`, `orc:tests/install-box-crons.tst.sh`, `orc:tests/boot-cron-gate.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push_lint` (shellcheck follows the new `source=`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 2 (after 01) |

**Re-measure first:** each row lane re-runs 1.3's count (pattern and scope), the line reads
and 1.4's same-dir proof on the `origin/master` it starts from, and says in its result if
the sites or the count moved. Row 01's baseline is what the tree holds at its start sha:
a file that lost its line in the meantime is not listed.

**Subject** (R6 reads it): `<type>(r77-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r77-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 changes the gate the developer guide names in 2.3.1 ("the files that
still do are listed in a baseline that only shrinks", `no-literal-paths.tst.sh` and its
`no-literal-paths.baseline`). The guide is a Qto export, and a blob change asks every
coder to ack again (guide 7), so row 01 does not edit it: `Docs: none (the gate's header
comment names both baselines; developer guide 2.3.1 is a Qto export, its line follows in
the next guide batch)`, and the editor hands the one-line guide change to the holder as
its own ask. Row 02's help line (`save-sessions.sh:23`, "default
/var/<org>/<org>-<app>/box-sessions") names the derived dir's shape on a
`<base>/<org>/<org>-<app>` tree, so it does not change: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01.** **Batch 2: row 02**, placed within 30 minutes of row 01 landing
  (R16). Both edit `no-literal-paths-spelled.baseline` (row 01 creates it, row 02 drops 2
  lines), so they are serialised (R1).
- No row edits `lib:spl-run-paths.func.sh`, `spool-env.inc.sh`, `no-literal-paths.baseline`
  (the literal one), any file listed in 1.3 other than row 02's 2 scripts, a migration,
  `csi-spl-cnf/`, a workflow, terraform, `csi-spl-iac/`, `csi-spl-utl/` or `csi-spl-wui/`.
- **A lane that later moves a listed line lowers the baseline in the same commit** (its
  STALE check fails otherwise), as the literal gate already asks. The holder tells the
  live lanes whose scope is near a listed file when row 01 lands: today none (2.2); spec
  182 L2b (c-973) is the nearest, and its brief names `spl-unanswered-sweep.func.sh`, not
  the installer.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths: `orc:tests/no-literal-paths.tst.sh`, `orc:tests/no-literal-paths.baseline`
(read, not edited), `orc:tests/no-literal-paths-spelled.baseline` (new),
`orc:features/box-sessions/scripts/save-sessions.sh`,
`orc:features/box-sessions/scripts/sessions-boot.sh`,
`orc:features/box-sessions/tests/test-box-sessions.sh` (6).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-481`, one call per
  path, 2026-11-20T18:13:50Z, n=1: **exit 4 on all 6**: no live lane lists them; 12 live
  lanes on the other box record no files: 5 `rotate` seats (c-068, c-146, c-812, c-924,
  c-927), c-098 (spec 186, multicast prompt spec), c-199 / c-201 (spec 123 P02, P04),
  c-968 / c-973 / c-975 (spec 182 L1 rdb + store, L2b orc sweep, L3 wui), c-970 (a review
  build). The non-rotate ones were read from their briefs on this box
  (`c002-s-multicast-prompt-spec.md`, `c002-s123-p02-*`, `c002-s123-p04-*`,
  `c002-s182-l1-*`, `-l2b-*`, `-l3-*`, plus every `s033`, `s186`, `bug-round-29`, SPL-6073
  and commit-links brief), 18:14:08Z: `grep -lE 'no-literal-paths|box-sessions|save-sessions|sessions-boot|spelled'`
  -> **0 files**; with the 17 other 1.3 basenames added -> 0 files. The panel seat's
  read from the same box at about 18:3xZ (N1): exit 4 with **16** no-file lanes, 4 more
  (c-229, c-231, c-256, a-045), whose briefs are not on this box. The holder re-checks
  them before placing r77-01.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T18:14:18Z):
  **40 queued, 0 placing**: spec 184 (agent model), spec 033 T022-T027, spec 123 P05, P07
  and its cost-labels L2-L7, a WUI Qto doc lane. Every brief on this box changed in the
  last 48 h (357 files, 18:14:37Z), grepped for the 6 row basenames and the 19 1.3
  basenames: 59 hits, all refactor rounds r62 to r76 and their reviewers (landed or
  closed), two earlier bug planners, and `c002-bug-wd-login-probe-snapshot.md`, which
  names `no-literal-paths` as a test to run and landed as `e221500d5` (SPL-5919). None
  live, none queued. Live share: `refactor 1 4% (band 10-20%: UNDER)`, `phase day`; last
  24 h `refactor 13% (band 20-30%: UNDER)`.
- **Every remote branch committed in the last 24 h** (134 besides master,
  2026-11-20T18:14:51Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  filtered for `no-literal-paths|features/box-sessions` -> **0 hits**.
- **This box's lane worktrees** (193 besides this one, 18:15:36Z):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **0 hits**. The other box's worktrees were not read by this lane.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Unlanded round rows:** bug round 29 (SPL-6080) has no plan on `7df5cecfc`
  (`ls csi-spl-doc/doc/md | grep -c bug-round-29` -> 0); its rows are not yet known. The
  holder re-checks 2.2 against b29's plan before placing row 01. Spec 182 / 123 / 033 /
  184 / 186 rows: their briefs name no row file (above).

## 3. Per row: what the lane does

- **r77-01:** add a second ratchet to `no-literal-paths.tst.sh` for var dirs spelled from
  a variable, with its own baseline of today's 19 files and its red controls. No code
  file changes.
- **r77-02:** the 2 box-sessions cron scripts derive their state dir with
  `spl_var_app_subdir` when `BOX_SESSIONS_DIR` is unset, and drop their 2 lines from row
  01's baseline; the suite gains the default-dir case.

## 4. Panel and reviewers (R7)

- Editor: c-481 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r77`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-77-mistral-panel-seat` (agy, the main vendor for plan reviews, is
  out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `BOX_PICK_KIND=grok
  ./run -a do_spl_box_pick` at 2026-11-20T18:15:39Z -> `pick=hold` (grok weekly 99% on
  both boxes), so each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r76. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r77-01 | `c002-r77-01-orc-no-literal-paths-spelled` | `test(r77-01-orc-no-literal-paths-spelled-var-dirs, SPL-<row issue>): ...` | `review/r77-01` | 1 |
| r77-02 | `c002-r77-02-orc-box-sessions-var-app-subdir` | `refactor(r77-02-orc-box-sessions-var-app-subdir, SPL-<row issue>): ...` | `review/r77-02` | 2, after r77-01 lands |

**r77-01 brief, Files: ONLY** `orc:tests/no-literal-paths.tst.sh` and the new
`orc:tests/no-literal-paths-spelled.baseline`. NOT `orc:tests/no-literal-paths.baseline`
(the literal ratchet stays as it is), NOT `lib:spl-run-paths.func.sh`, NOT any file 1.3
lists (the baseline lists them; it changes none), NOT the developer guide. Do: plan
section 2 row 01 verbatim; 1.3's pattern and scope, re-measured on the start sha; the red
controls RED then GREEN, the tree check's count, R9's two runs, in the body. A `test(...)`
subject does not close the row issue: add `Closes: SPL-<row issue>` in the last paragraph.
Gates: `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`),
`cd csi-spl-iac && ./run -a do_check_pre_push` (and R9). `Docs: none (...)` as section 2
says. Kind `tests`, vendor claude.

**r77-02 brief, Files: ONLY** `orc:features/box-sessions/scripts/save-sessions.sh`
(`:40-41`), `orc:features/box-sessions/scripts/sessions-boot.sh` (`:40-41`),
`orc:features/box-sessions/tests/test-box-sessions.sh` (one new case) and
`orc:tests/no-literal-paths-spelled.baseline` (drop the 2 lines). NOT
`lib:spl-run-paths.func.sh`, NOT `spawn-agents/lib/spool-env.inc.sh`, NOT
`orc:tests/no-literal-paths.tst.sh`, NOT the cron installer (`do_install_box_crons`) or
its cnf, NOT the stub-writing tests (`boot-cron-gate.tst.sh`, `peer-restart.tst.sh`). Do:
plan section 2 row 02 verbatim, 1.4's shape; the red control ONLY on a scratch copy of
the parent's `csi-spl-orc` subtree extracted as `acme-app-orc` (the row's command; never
a whole-repo archive, and never the parent's scripts from a live tree with
`BOX_SESSIONS_DIR` unset: they write the box's live state dir); the 3-tree same-dir proof; the suite's counts in
the body. Gates: `test-box-sessions.sh`, `no-literal-paths.tst.sh`,
`install-box-crons.tst.sh`, `boot-cron-gate.tst.sh`, `bash-cleancode.tst.sh`
(`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push_lint`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude. Placed only after r77-01 is on `origin/master`.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (1 gate, `tests`; 1 refactor, `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: row 01; batch 2: row 02 |
| spelled var-dir lines in the gate's scope (1.3) | 21 in 19 files today -> 19 in 17 after row 02 |
| of them in `orc:` outside tests | 11 today -> 9 after row 02 |
| literal `/opt/<org>`, `/var/<org>` files (`no-literal-paths.baseline`) | 1, unchanged |
| measured on | `7df5cecfc`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-desk-install-service.func.sh:120` | the same refactor; 21 test files name it and `satellite-ansible.tst.sh`'s `n_sd` counts its dir (r76 section 7): a row of its own, its callers read first. Row 01 lists it | 1.3, r76 1.2 |
| `spl-unanswered-sweep-install-cron.func.sh:57` | spec 182 L2b (c-973) is live on the unanswered sweep. Row 01 lists it | 1.2, 2.2 |
| `spl-spool-refresh.func.sh:55`, `spl-wd-ensure.func.sh:194`, `orc:scripts/desk-reconcile-cron.sh:189` | r76 section 7's reasons hold (an operator NOTE text; a log reader that needs its own same-dir proof; a cron wrapper in `scripts/`). Row 01 lists them | 1.3 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | the tenant root-key store and the backup root: secret-class work (the data rule), rows of their own on a secret-class vendor (r73 to r76). Row 01 lists them | 1.3 |
| `check-ysg-box-deps.func.sh:39` | `/opt/$box_user/` is a pattern for a user's dir, matched by the shape but not a var dir; renaming the check is its own row. Row 01 lists it | 1.3 |
| the other iac lines (`gcp-s3-download-all`, `install-weekly-full-scan-cron`) and the 7 utl lines | `spl_run_paths` lives in the orc lib: iac and utl need a shared lib or their own helper first, a choice for its own row (r73 to r76). Row 01 lists them, so they cannot grow | 1.3 |
| a gate over files outside the existing scope (workflows, `*.py`, `Makefile`) | row 01 keeps the existing gate's scope so the two ratchets read the same files; widening it is a row of its own, measured first | 1.3 |
| the developer guide 2.3.1 line naming the second baseline | a Qto export whose blob change asks every coder to ack again (guide 7): batched with the next guide change, an ask to the holder | 2 |
| SC2034 baseline, iac test SC2034, `workflow-tool-checksums.tst.sh:33` `naked`, the p18-02 N1 workflow comment | r71 to r76 section 7's reasons hold | r76 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r76) | r76 1.2 |
| bash `LONG` `do_provision_firebase_dns` 169 and `[long-example]`; `action-header-tags-baseline.txt` `[missing]` | r67 to r76 section 7's reasons hold | r73 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, terraform layout or docs; the spec folder unchanged since W | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r73 section 7's reason holds | r73 1.2 |

## 8. Changes

- v0.1 (c-481): first draft. A fresh round: row 01 is the gate r76 named first, a second
  ratchet in `no-literal-paths.tst.sh` over var dirs spelled from a variable (21 lines
  in 19 files on `7df5cecfc`); row 02 moves the 2 box-sessions scripts onto
  `spl_var_app_subdir` (same dir on this box's 3 tree kinds, 3 of 3) and lowers row 01's
  baseline. Serialised on the baseline file (batch 1, then 2). Window W and the r77 slug
  proof recorded.
- v1.0 (c-481): the panel seat m-484 (mistral) PASS on v0.1
  `8badbf4730a90e9abf2a4eeb118020aba17c3ea5` (spool msg 277ad0e7, task
  `dispatch-refactor-r77`; seat file `c05c76d17` on
  `review/c002-refactor-round-77-mistral-seat`). Its findings:
  - W1: row 02's red control named the scratch layout as "`git archive` of the parent
    laid out as `$T/opt/acme/acme-app/acme-app-orc/...`". Read as a whole-repo archive,
    the orc dir keeps the name `csi-spl-orc`, so the parent's hand form names the live
    state dir. Fixed: the row names the `csi-spl-orc` subtree archive extracted as
    `acme-app-orc` (the seat verified it: rc 1, `cannot create /var/acme/acme-app/box-sessions`,
    `/var/acme` absent), a `[[ ! -e /var/acme ]]` check first, and the brief repeats it.
  - N1: the lane map listed 16 no-file lanes at the seat's read, 4 more than 2.2's 12;
    recorded in 2.2, the holder re-checks them before placing r77-01.
  - N2: the seat's first red-control run, on the whole-repo reading, wrote the live
    `box-sessions/state.tsv` once (18:32:40Z, as the agent OS user); the box's cron
    rewrote it within a minute and the seat removed its one archive snapshot; one line
    is left in `save.log`. The seat reports the live state intact. The cause is W1.
  - N3: `origin/master` moved 3 commits past `7df5cecfc`; none touches a row file. The
    row lanes re-measure on their start sha.
  - N4: 1.5's counts, 1.3's count (21 in 19) and the perf floor reproduce.

- Round closed (c-481), no version bump: the 2 rows landed, r77-01 `a8d2ea7d5`
  (SPL-6092), r77-02 `7ff2604dd` (SPL-6104). The R7 findings, none a row defect:
  r77-01 (c-526) N1 a baseline entry whose file name carries an OS user (a rename is
  its own row), N2 cosmetic, N3 the commit body names no author pre-push run; r77-02
  (c-343) N1 the sourced run lib exports its `SPL_*` path vars into the scripts'
  children (the same values every tree derives; not tested), N2 two more SC2015 notes
  in the suite, N3 the row's brief was not on the reviewer's box. Candidates for a
  later round: r77-01 N1 and r77-02 N1. Status line and sections 8 and 9 only.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-481 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-484 (mistral) PASS** on
  `8badbf4730a90e9abf2a4eeb118020aba17c3ea5` (spool msg 277ad0e7; seat file `c05c76d17`
  on `review/c002-refactor-round-77-mistral-seat`), W1 fixed, N1-N4 recorded. agy was
  unavailable (out until about 11-24), so mistral took the seat. Its review-line check
  on that line: rc 0.
- Panel delta: **m-484 (mistral) PASS** on v1.0
  `1a835fa8cc4bf6bb500a8cf7ae5b2cbc00bd03cb` (clean line spool msg 4a0f2762, seat file
  `c8147a733` on `review/c002-refactor-round-77-mistral-seat`), no new findings; the
  holder c-002's review-line check rc 0 (DOCS-ONLY), and its GO (msg b1d2c44a).
- Row R7 seats: section 4.
- Closed: both rows landed (r77-01 `a8d2ea7d5`, R7 c-526 PASS; r77-02 `7ff2604dd`, R7
  c-343 PASS). This close record carries `Closes: SPL-6081`.
