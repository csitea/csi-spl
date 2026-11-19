# Refactor round 70 — seat mistral (panel, docs and reviews only)

Seat: m-117@sat, placement `c002-refactor-round-70-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-70-mistral-panel-seat.md`
(Issue SPL-6003, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `9f978f35-bf40-4d3d-890f-1d57bd3d00f7`).

Review target: plan v0.1 `87a07ddb595cab628e62414588f427f82003f823`, named by the
editor c-112@sat (msg e76055af, task `dispatch-refactor-r70`) and by the dispatch
holder c-002@sat (task `dispatch-refactor-r70`, 2026-11-19T22:25:22Z). Provenance:
`git ls-remote origin | grep refactor-round-70` ->
`87a07ddb595cab628e62414588f427f82003f823  refs/heads/review/c002-refactor-round-70-planner`
(the only match; my review branch did not exist yet at this read);
`git log --oneline -3 87a07ddb5` -> `87a07ddb5 docs(r70-plan, SPL-6003): ... v0.1 ...`
over `cb8f0f117` (parent = the plan's stated base, `git rev-parse 87a07ddb5^` ->
`cb8f0f117e3baf8998f694d2e917532e1837a3ac` = origin/master at the plan's read);
`git show --stat 87a07ddb5` -> 1 file, `csi-spl-doc/doc/md/refactor-round-70-plan.md`,
+311, read in full at that sha (311 lines). origin/master at my read:
`git fetch origin && git rev-parse origin/master` -> `418c40de8577dd00ea6ab001684e691378a90d3e`
(one commit past the plan's base, SPL-5963 calendar, no row file touched — check 2).
No later plan version was named on task `dispatch-refactor-r70` at my read
(`spool tail --task dispatch-refactor-r70` -> last message 2026-11-19T22:26:33Z
`c-001 -> c-002 [note] placed: m-117@sat`; no `v1.0` line), so I sign v0.1
`87a07ddb5`.

## Verdict

**PASS on `87a07ddb595cab628e62414588f427f82003f823`** (plan v0.1, 2 rows, both
verified on `cb8f0f117` and re-verified on origin/master `418c40de8` at read time).
Defects: none. Notes N1..N5 below.

## Checks (each with the command run and what it printed, 2026-11-19 22:2x-22:3xZ)

### 1. Slug r70 unused

- `git log origin/master --oneline -E --grep='\(r70-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r70-[0-9]{2}|refactor-round-70'` -> one line,
  `87a07ddb595cab628e62414588f427f82003f823  refs/heads/review/c002-refactor-round-70-planner`
  — the planner's branch, expected; nothing else.
- `grep -rlE 'r70-[0-9]{2}' /var/spool-hub/dispatch/briefs 2>/dev/null | wc -l` -> `1`,
  only `/var/spool-hub/dispatch/briefs/c002-refactor-round-70-mistral-panel-seat.md`
  (this brief). The planner's brief `c002-refactor-round-70-planner.md` sits in the
  same dir but `grep -cE 'r70-[0-9]{2}'` on it -> `0` (it names the round, no row
  ids), so it does not match the pattern (N4).
- Control: `git log origin/master --oneline -E --grep='\(r69-' | wc -l` -> `4`
  (the read sees a used id); `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-70`
  -> `0` (no r70 file on master, the plan takes the plain name per 5.3);
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r69-plan'` ->
  `2026-11-19T21:46:55+01:00` = the plan's recorded W.

### 2. Every site file:line of both rows exists on `cb8f0f117` and on origin/master

`git show <sha>:<file> | sed -n <N>p` for each cited site, on both shas —
**12 OK on `cb8f0f117`, 12 OK on origin/master (`418c40de8`), identical text, 0
drifted** (the only commit between them, `418c40de8`, touches 12 calendar files
only: `git diff cb8f0f117 origin/master --stat` -> api hub calendar tests, specs
089/097, `spl-calendar-event-{add,update}.func.sh` + their tests). Spot lines:
- `csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh:31` ->
  `# @param BOOT_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/agent-boot-restore`
- `...install-cron.func.sh:57` ->
  `  logdir="${BOOT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/agent-boot-restore}"`
- `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:534-540` -> the comment
  (`# The boot restore's retired marker: <BOOT_CRON_LOG_DIR>/retired, by default`,
  `# /var/<org>/<org>-<app>/agent-boot-restore/retired (as the install-cron action).`),
  `spl_wd_boot_retired() {`, `local oa=...`, `oa="${oa%-orc}"`,
  `echo "${BOOT_CRON_LOG_DIR:-/var/${oa%%-*}/$oa/agent-boot-restore}/retired"`, `}`
- `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh:746` ->
  `  local pane="$1" text="$2" needle i shown`; `:749` ->
  `  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do`
- `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-poke-queue.inc.sh:487` ->
  `  local pane alt tty head text plain notice log shown="" esc=$'\033' blue="" dim="" off=""`

Full paths: `git ls-tree -r --name-only origin/master | grep <name>` -> each name
resolves to exactly the cited path (the two `run/` funcs, the two `sa:lib/` incs,
`csi-spl-orc/src/bash/tests/wd-reboot.tst.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh`,
`.shellcheck-warning-baseline.txt` at the repo root).

### 3. r70-02 baseline and shellcheck

- `git show origin/master:.shellcheck-warning-baseline.txt | grep -vcE '^\s*(#|$)'`
  -> **70** (the plan's 70).
- SC2034 lines: `... | grep SC2034` -> **25 lines**; in `sa:lib/`
  (`grep 'spawn-agents/lib'`) -> **4**: `spool-env.inc.sh|2`,
  `spool-mirror-hooks.inc.sh|2`, `spool-notify.inc.sh|1`, `spool-poke-queue.inc.sh|1`.
- The 2 lines the row drops are in it today:
  `SC2034|csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh|1` and
  `SC2034|csi-spl-orc/src/bash/features/spawn-agents/lib/spool-poke-queue.inc.sh|1`.
- `command -v shellcheck` -> on PATH, `shellcheck --version` -> 0.10.0
  (present, not installed by me). Per row file,
  `git show origin/master:<file> > /tmp/sc-<name>; shellcheck -S warning -f gcc /tmp/sc-<name> | grep SC2034`
  -> spool-notify.inc.sh: `:749:3: warning: i appears unused. ... [SC2034]`;
  spool-poke-queue.inc.sh: `:487:27: warning: text appears unused. ... [SC2034]`.
  **Exactly the row's 2 warnings, at the cited lines**; each file has 1 warning at
  `-S warning` (`grep -c warning` -> 1 each), matching its baseline count of 1.

### 4. r70-01 scope

- `git grep -n 'agent-boot-restore' origin/master -- csi-spl-orc` -> **46 lines in 12
  files**. The lines that build or read the default dir
  (`grep -E 'agent-boot-restore[/}]'` over them) -> exactly the plan's two sites:
  `spl-agent-boot-restore-install-cron.func.sh:57` (writer) and
  `spl-watchdog.func.sh:535` (comment), `:539` (reader). All other hits are the
  action/script/test names or test-local `$L`/`$T` log dirs
  (`boot-cron-gate.tst.sh:82,116` use `$L/agent-boot-restore/...`). So the plan's
  two sites are all the writers and readers of the dir.
- `git grep -n 'BOOT_CRON_LOG_DIR' origin/master -- csi-spl-orc` ->
  `install-cron.func.sh:31,57`, `spl-watchdog.func.sh:534,539`, and the tests set it:
  `test-agent-boot-restore.sh:115`, `boot-cron-gate.tst.sh:53`,
  `wd-reboot.tst.sh:236,341` — exactly the plan's 1.3 list, so no test reads the
  default today.
- `spl_run_paths`: `git show origin/master:csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh | grep -n 'spl_run_paths()\|SPL_VAR_APP_DIR:='`
  -> `66:spl_run_paths() {`, `71:  : "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"`
  — the plan's cited `66-71`.
- Equality on this box (the plan's 1.3 command):
  `ls -la /opt/csi/csi-spl-desk-cron/.git` -> a **58-byte file** (worktree pointer);
  `env -i PATH=/usr/bin:/bin bash -c 'source /opt/csi/csi-spl-desk-cron/csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh; PROJ_PATH=/opt/csi/csi-spl-desk-cron/csi-spl-orc spl_run_paths; echo "$SPL_VAR_APP_DIR/agent-boot-restore"'`
  -> `/var/csi/csi-spl/agent-boot-restore`; the literal with `oa=csi-spl` ->
  `/var/${oa%%-*}/$oa/agent-boot-restore` = `/var/csi/csi-spl/agent-boot-restore` —
  **equal**. Same from this lane's worktree
  (`PROJ_PATH=/opt/csi/csi-spl-wt/m-117/csi-spl-orc` -> `SPL_VAR_APP_DIR=/var/csi/csi-spl`).
  the push user's `crontab -l | grep boot-restore` -> the installed `@reboot` line waits
  on `[ -d /var/csi/csi-spl/agent-boot-restore ]` and appends to
  `/var/csi/csi-spl/agent-boot-restore/cron.out` — the same dir.

### 5. Row fields (practice, R2 control, tests, vendor, kind, batch, R7)

Read in the plan's section 2 table and section 4 at `87a07ddb5`: row 01 — practice
"canonical paths (developer guide 2.3.1)", red control (new `wd-reboot.tst.sh` case
with `BOOT_CRON_LOG_DIR` unset and `SPL_VAR_APP_DIR=$T/var`: FAIL on `cb8f0f117`,
PASS after), test column (1.3's five tests + cleancode + no-literal-paths +
`do_check_pre_push`), box `either`, vendor **claude**, kind **simple_coding**,
batch 1. Row 02 — practice "bash that fails safely (developer guide 2.4.3)", red
control (sites fixed, baseline left -> `do_sec_shellcheck` FAILS; lines dropped ->
PASS), test column (1.4's list + `run-all-tests.sh` + `sec-shellcheck.tst.sh` +
`do_check_pre_push_lint`), box `either`, vendor **claude**, kind **simple_coding**,
batch 1. Section 4: row R7 reviewers are "cross-vendor first (2.7.2), the holder's
call when the row is queued (a fresh claude seat under the claude waiver, as r63 to
r69). Not a mistral code R7." **No mistral coding or testing row.** All fields
present.

### 6. Behaviour

- r70-02, each removed variable never read: `git show origin/master:.../spool-notify.inc.sh | grep -nE '\$\{?i\b'`
  -> rc 1, **0 lines** (`i` is only the `for` variable at `:749`; the loop body reads
  `$shown` and `$needle` only — read at `:744-757`);
  `git show origin/master:.../spool-poke-queue.inc.sh | grep -nE '\$\{?text\b'` ->
  rc 1, **0 lines** (`text` in the `local` at `:487` is never assigned or read;
  `spool_poke_show` body `:484-553` read);
  `git grep -nE '\$\{?text\b' origin/master -- csi-spl-orc/src/bash/features/spawn-agents/lib`
  -> **12 lines**, all in `channel-move.inc.sh:290,315,316`, `go-ask-guard.inc.sh:41,42`,
  `owner-orders.inc.sh:56,67,100,103,107`, `spool-notify.inc.sh:747,760` — functions
  that declare their own `local text`; **0 in `spool-poke-queue.inc.sh`**, so no
  callee of `spool_poke_show` reads an outer `text`. Both variables confirmed dead.
- r70-01: writer `:57` and reader `:539` both use
  `${BOOT_CRON_LOG_DIR:-<default>}`, so when `BOOT_CRON_LOG_DIR` is set they still
  agree (both take it). When unset, both build the same literal today and would
  both take `$SPL_VAR_APP_DIR/agent-boot-restore` after the row — and check 4
  proved the two are the same string on this box.
- The red controls would really fail today — verified by reading the code, NOT run
  (running them needs the row's code change, which this read-only seat must not
  make, N3): on `cb8f0f117` with `BOOT_CRON_LOG_DIR` unset, `install-cron.func.sh:57`
  and `spl-watchdog.func.sh:539` print the `/var/<org>/<org>-<app>` dir, not
  `$T/var/...`, so the plan's new `wd-reboot.tst.sh` case FAILS on the parent;
  `csi-spl-iac/lib/bash/funcs/sec-baseline.func.sh:67` ->
  `FATAL $tool: fewer findings than baselined -- lower this line in $bl (delete it at 0 found):`
  with `rc=1` at `:69`, so row 02's "sites fixed, baseline left" case FAILS and
  "lines dropped" PASSES.

### 7. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh,csi-spl-orc/src/bash/run/spl-watchdog.func.sh,csi-spl-orc/src/bash/tests/wd-reboot.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh,csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh,csi-spl-orc/src/bash/features/spawn-agents/lib/spool-poke-queue.inc.sh,.shellcheck-warning-baseline.txt --agent m-117`
-> **exit 4**: `WARN no live lane lists <the 7 paths>, but 11 live lane(s) record no
files: their scope is unknown, not free`; `unknown:` c-049, c-060, c-606, c-625,
c-638, c-640, c-644, c-646, c-812, c-924, c-927 (all `@<box>`). `lane-map.sh --all`
shows the brief's named live lanes all live — c-638@<box> (r69-02 api MergeTopic),
c-644@<box> (b24-01 api flow), c-646@<box> (b24-02 `sa:tests/lib.inc.sh`), c-640@<box>
(SPL-5882 T2 evlog store), c-946@sat (SPL-5963 wui calendar), c-046@sat (spec 143
B-6b api hub github sync), c-625@<box> (spec 181 doc) — plus m-117@sat (this seat).
Exit 4 (not 3): **no live lane owns any row path**; none of the named lanes touches
a row file. Exit 4 means ask-first for the 11 no-file lanes, not free (N2); the
plan's 2.2 already defers to the holder's R3 check before the spawn.

### 8. R1 across rounds

Newest plans on origin/master: `perf-round-18-plan.md` (last touched `da68ad993`,
2026-11-18T16:51:12+01:00), `bug-round-24-plan.md` (`cb8f0f117`,
2026-11-19T22:43:09+01:00). `git show origin/master:csi-spl-doc/doc/md/<f> | grep -cE 'agent-boot-restore|spl_wd_boot_retired|spool-notify|spool-poke-queue|wd-reboot|shellcheck-warning-baseline|test-agent-boot-restore'`
-> perf-18/17/16 and bug-24/23/22: `0, 0, 0, 1, 0, 0`. Over **all** perf- and
bug-round plans on origin/master, the only hit is `bug-round-24-plan.md:63`, which
names `.shellcheck-warning-baseline.txt` only as r69-01's landed diff (a closed
round) in its row-02 scope note — **no live perf or bug round row names any row
file**.

### 9. Candidates (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, sat)

`ls -la` -> 9542 bytes, mtime Nov 19 22:49; read in full (48 lines). Refactor-shaped
items in it: (a) **line 48**, the agent-boot-restore dir — the plan's row 01 does
what that line asks: writer AND reader in ONE commit, equality proved on the box
(check 4: `/var/csi/csi-spl/agent-boot-restore` both ways); (b) line 1, the r34 N3
literal `/var` at `spl-watchdog.func.sh:72,:1311` and `spl-lane-rotate.func.sh:112`
— **already served on origin/master**: `spl-watchdog.func.sh:72` now documents the
default as `spl_claude_login_state_dir` (`<SPL_VAR_APP_DIR>/agent-login-check`) and
`:1318` calls `spl_claude_login_state_dir`; `git grep -nE '/var/' origin/master -- csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh | wc -l`
-> `0`, `:112-116` derive via `spl_claude_login_state_dir`; the only `/var/csi`
literals left in `run/`+`scripts/` are `spl-file-erase.func.sh`'s protected-root
deny list (the `no-literal-paths.baseline` item, left out in plan section 7);
(c) the r63-01 W1 reverse-tunnel literal `reverse-tunnel-cron.sh:23` — served:
`:27` gates on `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`;
(d) p18-02 N1, the `10_ci-quality.yml:444-445` comment wording — a workflow edit,
listed in plan section 7 as left out. The rest of the file is bug-shaped (b12-02,
SPL-5824/5825/5828 follow-ups, SPL-5850, review-go, hermetic suites, placer notes,
sha256 prefix, reflection rows A/B). **No refactor-shaped item is left unserved by
the plan and unlisted in its section 7.**

### 10. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-117`
(all `ok -` lines, rc 0); re-run after this file is committed -> clean again.

## Defects

None.

## Notes

- N1: origin/master was `418c40de8577dd00ea6ab001684e691378a90d3e` at my read, one
  commit past the plan's base `cb8f0f117` (SPL-5963, calendar files only:
  `git diff cb8f0f117 origin/master --stat` -> 12 files, none a row file). No row
  site drifted (check 2); the plan's counts measured on `cb8f0f117` still hold on
  `418c40de8` (checks 3, 4, 6 re-run on origin/master).
- N2: lane-map exits 4 (not 3) on all 7 row paths — 11 live lanes record no files,
  so per the seed exit 4 means "ask first, never free"; the plan's 2.2 records the
  same read and defers to the holder's R3 check before the spawn, which is the
  conservative and correct reading.
- N3: the red controls of both rows were verified by reading the gate and site code
  (`sec-baseline.func.sh:67-69`, `install-cron.func.sh:57`, `spl-watchdog.func.sh:539`),
  not by running them: running them requires making the row's code change, which
  this read-only seat must not do.
- N4: the briefs grep counts 1 file (this brief) because the planner's brief
  `c002-refactor-round-70-planner.md` carries no `r70-NN` literal
  (`grep -cE 'r70-[0-9]{2}'` on it -> 0); it is present in the same dir.
- N5: no plan v1.0 was named on task `dispatch-refactor-r70` at my read (last
  message 2026-11-19T22:26:33Z, `placed: m-117@sat`), so I sign v0.1
  `87a07ddb5` as the brief and the editor name it. When the editor names v1.0 on
  that task, I sign that sha in a second commit on this branch.

## Report line (sent on task `dispatch-refactor-r70`)

`panel: m-117@sat mistral PASS 87a07ddb595cab628e62414588f427f82003f823 seat-file: review/c002-refactor-round-70-mistral-seat <commit sha> ran: <commands> | read: <files> | log: m-117@sat:.vibe/logs/session/unified/0938e72d-5d4e-5dcc-2d01-f42f2a554e35`
