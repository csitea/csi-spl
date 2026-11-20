# Refactor round 71 — seat mistral (panel, docs and reviews only)

Seat: m-163@sat, placement `c002-refactor-round-71-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-71-mistral-panel-seat.md`
(Issue SPL-6007, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `35e8ea36-d918-4937-b4b1-b880bf7a0962`).

Review target: plan v0.1 `8e3f74f3543e03a584a72e4fda89cbea428e8a35`, named by the
editor c-156@sat (msg f6608113, task `dispatch-refactor-r71`) and by the dispatch
holder c-002@sat (task `dispatch-refactor-r71`, 2026-11-20T00:52:52Z: "on plan v0.1
8e3f74f35 ... It signs only a sha you name; send it v1.0 on this task"). Provenance:
`git ls-remote origin | grep -E 'r71-[0-9]{2}|refactor-round-71'` ->
`8e3f74f3543e03a584a72e4fda89cbea428e8a35  refs/heads/review/c002-refactor-round-71-planner`
(the only match; my review branch did not exist yet at this read);
`git rev-parse 8e3f74f3543e03a584a72e4fda89cbea428e8a35^` ->
`6fedc5bbbd2f3f29641028378cf31d7a0afc9a6c` (the plan's stated base, = origin/master at
the plan's read); `git show 8e3f74f35 --stat` -> 1 file,
`csi-spl-doc/doc/md/refactor-round-71-plan.md`, +323, read in full at that sha
(323 lines). origin/master at my read: `git fetch origin && git rev-parse origin/master`
-> `5ed225ff7d01e86bb7b5764e7f660ae2c21e289c` (moved past the plan's base during the
read, N1; every site line re-verified identical on both, check 2). No later plan
version was named on task `dispatch-refactor-r71` at my read
(`SPOOL_ROOT=/var/spool-hub spool tail --task dispatch-refactor-r71` -> last message
2026-11-20T01:03:03Z `c-001 -> c-002 [note] placed: m-163@sat`; no `v1.0` line), so I
sign v0.1 `8e3f74f35`.

## Verdict

**FAIL on `8e3f74f3543e03a584a72e4fda89cbea428e8a35`** (plan v0.1, 2 rows). One defect:
W1, the row-02 gate regex counts 6 lines on `6fedc5bbb`, not the 5 the plan says, so
after row 02 it reads 1, not the claimed 0 — the gate as written can never reach 0.
Everything else verified clean (checks 1-10 below): slug free, all site file:lines
exist and did not drift, the helper is sound and the red control really is red on
`6fedc5bbb`, no live lane owns a row path, no perf/bug round row names the files, the
candidates file is fully served or listed, dist hygiene clean. Per rulebook 3.2 the
objection folds into the editor's v1.0 before row spawning; I sign that sha in a
second commit on this branch.

## Checks (each with the command run and what it printed, 2026-11-20 01:0x-01:13Z)

### 1. Slug r71 unused

- `git log origin/master --oneline -E --grep='\(r71-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r71-[0-9]{2}|refactor-round-71'` -> one line,
  `8e3f74f3543e03a584a72e4fda89cbea428e8a35  refs/heads/review/c002-refactor-round-71-planner`
  — the planner's branch, expected; nothing else (my own review branch is created
  only when I push this seat file).
- `grep -rlE 'r71-[0-9]{2}' /var/spool-hub/dispatch/briefs 2>/dev/null | wc -l` -> `1`,
  only `/var/spool-hub/dispatch/briefs/c002-refactor-round-71-mistral-panel-seat.md`
  (this brief). The planner's brief `c002-refactor-round-71-planner.md` sits in the
  same dir but `grep -oE 'r71-[0-9]{2}'` on it prints nothing (`grep -c 'r71'` -> 5:
  it names the round, no row ids), so it does not match the pattern (N4).
  `grep -rlE 'r71-[0-9]{2}' /var/spool-hub/spawn-remote/briefs 2>/dev/null | wc -l`
  -> `0`.
- Control: `git log origin/master --oneline -E --grep='\(r70-' | wc -l` -> `4`
  (`53d2fc25a` r70-02, `1a56f4a85` r70-01, `ef0094700` and `d3cbdc595` the r70 plan
  commits), so the read sees a used id.

### 2. Every site file:line of both rows exists on `6fedc5bbb` and on origin/master

Full paths (`git ls-tree -r --name-only origin/master | grep <name>`), one per name:
`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`,
`csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh`,
`csi-spl-orc/src/bash/run/spl-watchdog.func.sh`,
`csi-spl-orc/src/bash/run/setup-reverse-tunnel.func.sh`,
`csi-spl-orc/src/bash/run/prune-docker-images-install-cron.func.sh`,
`csi-spl-orc/src/bash/run/spl-workspace-docs-purge.func.sh`,
`csi-spl-orc/src/bash/tests/spl-run-paths.tst.sh`.

`git show <sha>:<file> | sed -n <N>p` for each cited site, on both `6fedc5bbb` and
`origin/master` (`5ed225ff7`) — **all identical, 0 drifted**:
- `spl-agent-boot-restore-install-cron.func.sh:59-61` ->
  `declare -F spl_run_paths >/dev/null || source ".../lib/bash/funcs/spl-run-paths.func.sh"` /
  `spl_run_paths && logdir="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/agent-boot-restore}"` /
  `[[ -n "$logdir" ]] || { do_log "FATAL cannot derive the boot restore dir (no tree for spl_run_paths): set BOOT_CRON_LOG_DIR"; return 1; }`
- `spl-watchdog.func.sh:540-542` (inside `spl_wd_boot_retired`, comment at `:534-536`
  "No dir derived: prints nothing") ->
  `declare -F spl_run_paths ... || source ...` /
  `spl_run_paths && d="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/agent-boot-restore}"` /
  `[[ -n "$d" ]] || return 0`
- `setup-reverse-tunnel.func.sh:48-50` -> same shape, `dir=.../reverse-tunnel`,
  FATAL rc 1 naming `REVERSE_TUNNEL_STATE_DIR`
- `prune-docker-images-install-cron.func.sh:38-40` -> same shape, `logdir=.../docker-prune`,
  FATAL rc 1 naming `PRUNE_CRON_LOG_DIR`
- `spl-workspace-docs-purge.func.sh:51-53` -> same shape,
  `dir="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/workspace-docs-purge/$ENV/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"`,
  FATAL rc 1 naming `PURGE_EXPORT_DIR`
- `spl-run-paths.func.sh:76` -> `}` (the close of `spl_run_paths`), so the helper goes
  after `:76` as the plan says.

### 3. Count of `SPL_VAR_APP_DIR:+` lines

- `git grep -nE 'SPL_VAR_APP_DIR:\+' origin/master -- . ':!csi-spl-doc'` -> **6 lines**
  (same count on `6fedc5bbb`): the 5 copies above plus
  `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh:217` ->
  `log="$( { spl_run_paths || :; } 2>/dev/null; printf '%s' "${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/zombie-topics/cron.log}")"`.
- Block shape: `git grep -nE 'spl_run_paths && .*SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' origin/master -- csi-spl-orc csi-spl-utl csi-spl-iac | wc -l`
  -> `5` — exactly the plan's 5 copies, all of the block's shape.
- The 6th line (`spl-reflection-gather.func.sh:217`, read at `:210-222` on
  origin/master) is a subshell read with `spl_run_paths || :`, no FATAL, no override
  var, and on empty it prints one "(not read: ...)" line and `return 0` (`:219`) —
  another shape, **rightly left out** of the rows (plan section 7). But see W1: it
  still matches the row-02 gate regex.

### 4. The helper

Read `spl_run_paths` in full on origin/master
(`git show origin/master:csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh | sed -n '1,76p'`):
`spl_main_checkout` (`:45-61`) resolves APP_PATH, else PROJ_PATH/.., else the file's
own top, rc 1 when no dir is known (`:50`, `:53`); `spl_run_paths` (`:66-76`) sets and
exports `SPL_ORG_DIR SPL_VAR_APP_DIR SPL_VAR_ORG_DIR SPL_WT_ROOT SPL_DESK_DIR` with
`: "${VAR:=...}"` (an env override of the same name wins), rc 1 via
`main="$(spl_main_checkout)" || return 1` (`:68`). **The plan's helper can be added
after `:76` without changing `spl_run_paths`** — it is a new function in the same file.
The helper as the plan writes it (no locals, `printf -v`, rc 1 with `<var>` untouched
when no dir) is sound: `printf -v` into a caller's var is already the tree's form
(`spl-uplink-probe.func.sh:77-86` `spl_uplink_probe_dir` does `printf -v "$1" ...`),
and running `spl_run_paths` in the caller's shell (not `$( )`) keeps its exports, as
today. Each caller's no-dir branch is kept by the plan's change (only the inner two
lines become the helper call): copies 1, 3, 4, 5 keep their own
`[[ -n "$<var>" ]] || { do_log "FATAL ..."; return 1; }`, copy 2 keeps
`[[ -n "$d" ]] || return 0` with nothing printed — verified at the lines of check 2.

### 5. Row structure (R2), vendor, kind, batch, R7 reviewer, red control

Both rows of the plan's section 2 table carry practice (folded helpers exist once,
developer guide 2.2.4; canonical paths 2.3.1), a red control that fails today and
passes after (new `spl-run-paths.tst.sh` cases), a test list (1.3's per-row columns —
all 18 named test files exist on origin/master, checked one by one with
`git ls-tree -r --name-only origin/master | grep -q`), box `either`, vendor `claude`,
kind `simple_coding`, batches 1 and 2 with `SPAWN_AFTER=c002-r71-01-...` (section 2.1,
files disjoint). **No mistral coding or testing row.** R7 reviewers (plan section 4):
cross-vendor first (2.7.2), the holder's call, a fresh claude seat under the claude
waiver — "Not a mistral code R7": satisfies the rule (cross-vendor or claude waiver,
never mistral).
**The red control really fails on `6fedc5bbb`**: `git grep -n 'spl_var_app_subdir'
6fedc5bbb -- csi-spl-orc | wc -l` -> `0` (no such function), and sourcing the bare
`6fedc5bbb` lib and calling it prints `bash: spl_var_app_subdir: command not found`,
rc 127 (run in a scratch dir, N3). With the plan's helper appended to that lib:
`APP_PATH=/opt/csi/csi-spl` -> rc 0, `d=/var/csi/csi-spl/agent-boot-restore`,
`SPL_WT_ROOT=/opt/csi/csi-spl-wt` set in the caller's shell; no tree
(`env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR SPL_RUN_PATHS_TOP=`) -> rc 1,
`v=old` untouched; bad name `'a b'` -> rc 1, `v=old`.
Also verified the plan's claim that no test reads a no-dir branch today:
`git grep -nE 'cannot derive the (boot restore|reverse tunnel|docker prune|purge export)' 6fedc5bbb -- '*tests*'` -> `0`.

### 6. Behaviour

- Copy 5's `<sub>` carries `/` and a stamp: with the helper,
  `APP_PATH=/opt/csi/csi-spl ENV=dev tenant=t1` and
  `spl_var_app_subdir dir "workspace-docs-purge/$ENV/$tenant/$(date -u +%Y%m%dT%H%M%SZ)"`
  -> rc 0, `dir=/var/csi/csi-spl/workspace-docs-purge/dev/t1/20261120T010845Z` —
  `printf -v '%s/%s'` passes the `/` and the stamp through unchanged, same path as
  today's inline expansion (scratch run, N3). The plan's note that the stamp is now
  evaluated before the call also when no dir is derived matches the code: line 52 is
  the only reader of the stamp.
- Override env vars still win: each caller reads its override first and only enters
  the derive block when empty — `spl-agent-boot-restore-install-cron.func.sh:57-58`
  `logdir="${BOOT_CRON_LOG_DIR:-}"` / `if [[ -z "$logdir" ]]`;
  `setup-reverse-tunnel.func.sh:41,47` (`REVERSE_TUNNEL_STATE_DIR`);
  `prune-docker-images-install-cron.func.sh:29,37` (`PRUNE_CRON_LOG_DIR`);
  `spl-workspace-docs-purge.func.sh:49-50` (`PURGE_EXPORT_DIR`);
  `spl-watchdog.func.sh:538-539` (`BOOT_CRON_LOG_DIR`). The plan replaces only the
  inner two lines of each block, so the `if [[ -z ... ]]` guard and the override win
  are unchanged.

### 7. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh,csi-spl-orc/src/bash/tests/spl-run-paths.tst.sh,csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh,csi-spl-orc/src/bash/run/spl-watchdog.func.sh,csi-spl-orc/src/bash/run/setup-reverse-tunnel.func.sh,csi-spl-orc/src/bash/run/prune-docker-images-install-cron.func.sh,csi-spl-orc/src/bash/run/spl-workspace-docs-purge.func.sh --agent m-163`
-> **exit 4**: `WARN no live lane lists <the 7 paths>, but 11 live lane(s) record no
files: their scope is unknown, not free`; `unknown:` c-049@<box>, c-060@<box>, c-606@<box>,
c-625@<box>, c-638@<box>, c-640@<box>, c-644@<box>, c-646@<box>, c-812@<box>, c-924@<box>, c-927@<box>.
Exit 4 (not 3): **no live lane owns any row path**; exit 4 means ask-first for the 11
no-file lanes, not free (N2) — the plan's 2.2 recorded the same exit 4 and defers to
the holder's R3 check before the spawn. The brief's named live lanes: c-638@<box>
(r69-02 api MergeTopic), c-646@<box> (b24-02 `sa:tests/lib.inc.sh`), c-640@<box> (SPL-6000
evlog store), c-046@sat (spec 143 B-6b.2 api), c-625@<box> (spec 181 doc) —
`grep -rlE 'spl-run-paths\.(func|tst)|spl_wd_boot_retired|agent-boot-restore-install-cron|setup-reverse-tunnel\.func|prune-docker-images-install-cron|spl-workspace-docs-purge'`
over their briefs (`c002-r69-02-*.md`, `hand-<box>-c002-b24-02-*.md`,
`c002-spl5882-*.md`) and over both briefs dirs -> the only matching briefs are old
landed lanes (r60-r70 rows, review seats), this seat's brief and the r71 planner's;
**none of the named live lanes' briefs names a row path**.

### 8. R1 across rounds

Newest plans on origin/master (`5ed225ff7`): `perf-round-18-plan.md`,
`bug-round-24-plan.md`, `refactor-round-70-plan.md` (numeric sort of
`git ls-tree --name-only origin/master csi-spl-doc/doc/md/`). For each of
perf-18/17/16 and bug-24/23/22:
`git show origin/master:csi-spl-doc/doc/md/<f> | grep -cE 'spl-run-paths\.func|spl_wd_boot_retired|agent-boot-restore-install-cron|setup-reverse-tunnel\.func|prune-docker-images-install-cron|spl-workspace-docs-purge'`
-> `0, 0, 0, 0, 1, 0`. The one hit, `bug-round-23-plan.md:158`, is a left-out note
(r66-02 N1, shallow APP_PATH) that cites `spl-run-paths.func.sh:66-73` and says "Not a
row" — **no live perf or bug round row names any row file**. (`refactor-round-70-plan.md`
-> 13 hits: r70 carried N2, expected.)

### 9. Candidates (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, sat)

`ls -la` -> 9542 bytes, mtime Nov 19 22:49 (same as the plan's read); read in full
(48 lines). Refactor-shaped items in it and where the plan takes them: (a) line 48,
the agent-boot-restore dir — served by r70-01 `1a56f4a85` (plan 1.2 row a); (b) line 1,
r34 N3 literal `/var` in `spl-watchdog.func.sh:72,:1311` and `spl-lane-rotate.func.sh:112`
— served (plan 1.2 row b); (c) the r63-01 W1 `reverse-tunnel-cron.sh:23` literal —
served (plan 1.2 row c); (d) SPL-5828 N1 `spl-uplink-probe.func.sh:14-15` wording —
served (plan 1.2 row d); (e) p18-02 N1 `.github/workflows/10_ci-quality.yml:444-445`
comment — listed in plan section 7 as left out. The rest is bug-shaped (review-go
retired-author retry, reflection sweep W1/W2, desk hop env, placer author pick,
sha256-prefix, OS-user suites, e2e flake, terraform `-input=false` ruled not a
refactor row in plan 1.2). **No refactor-shaped item in the file is neither served
nor listed.**

### 10. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> every line `ok`/`allowed`
(owner-approved cnf keys only), `INFO distribution-hygiene: clean over the tracked
tree of /opt/csi/csi-spl-wt/m-163`, exit 0.

## Defects

- **W1 (plan `8e3f74f35`, line 180 row-02 gate cell and line 293 section-6 counts
  row):** the gate `git grep -nE 'SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' -- csi-spl-orc/src/bash/run`
  counts **6** on `6fedc5bbb`, not the 5 the plan writes ("5 on `6fedc5bbb`, 2 after
  row 01", "-> 0 after row 02"): the 6th match is
  `spl-reflection-gather.func.sh:217`, which the plan itself leaves out in section 7
  but which still matches the regex. Measured: the gate on `6fedc5bbb` -> 6 lines
  (listed in check 3); after row 01 it would read 3, after row 02 **1, never 0**.
  The row-02 lane would chase a gate that cannot reach its stated 0. Fix for v1.0:
  anchor the gate on the block shape the plan's own 1.3 used, e.g.
  `git grep -nE 'spl_run_paths && .*SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' -- csi-spl-orc/src/bash/run`
  (measured 5 on `6fedc5bbb` -> 2 after row 01 -> 0 after row 02), or exclude
  `spl-reflection-gather` explicitly; and correct the section-6 counts row to the
  same numbers. The code change of the rows is unaffected.

## Notes

- **N1:** origin/master moved past the plan's base during my read:
  `6fedc5bbb` -> `5ed225ff7` (commits `6fedc5bbb..5ed225ff7`: spec 162 T2 docs/api,
  `docs`); every cited site line re-verified identical on both shas (check 2), so
  nothing drifted.
- **N2:** lane-map exits 4 (not 3) on all 7 row paths — 11 live lanes record no
  files, ask-first, not free; the named live lanes' briefs name no row path (check 7).
- **N3:** the helper probes of checks 4-6 were run in a scratch dir
  (`git show 6fedc5bbb:...spl-run-paths.func.sh` + the plan's helper appended), not
  in the repo — this seat writes no code into the tree.
- **N4:** the briefs grep of check 1 counts 1 file (this brief) because the planner's
  brief names the round but no `r71-NN` row id (`grep -oE 'r71-[0-9]{2}'` -> none).
- **N5:** no plan v1.0 was named on task `dispatch-refactor-r71` at my read (last
  message 2026-11-20T01:03:03Z `placed: m-163@sat`); I sign v0.1 `8e3f74f35` and will
  sign the v1.0 sha the editor names, in a second commit on this branch.

## Report line (sent on task `dispatch-refactor-r71`)

`panel: m-163@sat mistral FAIL 8e3f74f3543e03a584a72e4fda89cbea428e8a35 seat-file: review/c002-refactor-round-71-mistral-seat <this commit's sha> ran: <commands> | read: <files> | log: m-163@sat:.vibe/logs/session/unified/b2963654-8846-764f-a8f4-c880b640ab5a`
