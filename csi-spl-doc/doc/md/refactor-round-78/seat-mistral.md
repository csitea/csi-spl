# Refactor round 78 — panel seat mistral (m-555@<box>)

Issue: SPL-6109 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-78-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-78-plan.md` on branch
`review/c002-refactor-round-78-planner`, at the v0.1 sha the planner names as a plan
version. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 the
panel signs the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-77-plan.md` (on origin/master).

## Verdict

**PASS** on `a5f35558a1cf3b477e27f46bdae91ec1eb8c241d` — plan v0.1, branch
`review/c002-refactor-round-78-planner`, base `4c5633d8492832fa20e695afae69808ce4b25966`
(`origin/master` at read time, 2026-11-20T23:2xZ). Defects W1..: none. Notes N1..N3
below. Read-only review: this seat wrote no code and touched no file but this one.

How the sha was named: the planner's commit subject on the branch head reads
`docs(r78-plan, SPL-6109): refactor round 78 plan v0.1, 2 rows: ...`, so the planner
names `a5f35558a` as plan v0.1. `git ls-remote origin
refs/heads/review/c002-refactor-round-78-planner` ->
`a5f35558a1cf3b477e27f46bdae91ec1eb8c241d` (head at read time, 2026-11-20T23:2xZ, not a
moving head). The holder's sha post on task `dispatch-refactor-r78` had not landed yet
(`spool tail --task dispatch-refactor-r78` last line 2026-11-20T23:08:20Z `placed:
c-391@<box>`); per the brief this seat reviewed the sha the planner named as a plan
version. The plan was read whole (357 lines) via
`git show a5f35558a:csi-spl-doc/doc/md/refactor-round-78-plan.md`.

## Checks (each with the command run and what it printed, 2026-11-20T23:1x-23:3xZ, n=1)

### 1. Slug r78 unused since the plan's Window W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(r77-plan')` ->
  `W=2026-11-20T23:56:41+02:00`, commit `0782cf525` (matches the plan's 1.1).
- `git log origin/master --since="$W" --oneline -E --grep='\(r78-' | wc -l` -> `0`;
  the same grep over all history -> `0`.
- Control: `--grep='\(r77-'` since W -> 1 line, `0782cf525` (the read sees a used id).
- `git ls-remote origin | grep -E 'r78-[0-9]{2}|refactor-round-78'` -> exactly 2 heads:
  `b847bc3f2... refs/heads/review/c002-refactor-round-78-mistral-seat` (this seat's own
  branch) and `a5f35558a... refs/heads/review/c002-refactor-round-78-planner` (the
  planner's). No `r78-NN` row head; nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r78-[0-9]{2}|refactor-round-78'` ->
  `c002-refactor-round-78-mistral-panel-seat.md`, `c002-refactor-round-78-planner.md`
  (this seat's and the planner's; expected).

### 2. Every site file:line of every row exists on the base sha and on origin/master

26 cited lines checked with `git show <sha>:<file> | sed -n <N>p` on `4c5633d84` and on
`origin/master`: 26 of 26 identical (SAME), none empty, none drifted. Row sites:
`csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh:83` ->
`# @param DESK_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/desk-reconcile`;
`:120` -> `logdir="${DESK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/desk-reconcile}"`;
`:127/:130/:138/:169/:196/:236` all present (cron line, JSON `log_dir`, `mkdir -p`, dry
plan); `csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline:6` ->
`1 csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh`;
`csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh:25` ->
`local f="${1:?do_tf_log_open: the log file}"` (`:24-27` the whole function);
`csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:189` ->
`"${DESK_CRON_LOG_DIR:-/var/${ORG_APP%%-*}/$ORG_APP/desk-reconcile}"` (the plan's
`orc:scripts/...` shorthand expands to `csi-spl-orc/src/bash/scripts/...` per its own
1.2 legend); `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:82`,
`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh:75`,
`csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh:59-60`,
`csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh:270-272`, and the 5 callers
`csi-spl-iac/src/bash/run/tf-apply.func.sh:22`, `tf-apply-target.func.sh:38`,
`tf-destroy.func.sh:17`, `tf-destroy-target.func.sh:32`,
`tf-destroy-local-step-bucket.func.sh:27` (each `do_tf_log_open "$..." || return 1`)
all SAME. Drift: `git diff --name-only 4c5633d84 origin/master -- <the 5 row files>` ->
empty (rc 0). All 5 row files exist on both shas (`git cat-file -e`). Line counts:
`spl-desk-install-service.func.sh` 505, `tf-log-mask.func.sh` 27 (match the plan).
`git log origin/master --since="$W" -- <the 5 row paths> | wc -l` -> `0`.
`git ls-tree --name-only 4c5633d84 csi-spl-doc/doc/md/ | grep -c refactor-round-78` ->
`0` (the plan takes the plain name, 5.3 Files).

### 3. Red controls, run on the plan's base in a scratch copy

Scratch copy: `git archive 4c5633d84 | tar -x -C /tmp/r78-base`. sha256sums there:
`31d97981f0df9b738878a34b8c076179afe3664131bf662b9b94b62d4a6603d7
csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh`;
`bacce00626ee8056b3a6201c9ecc0bbd41a06608bae81fcc0566cfdf7fc8db9e
csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh`;
`563ff3b731f54691caee19597a5702e3cdbffa751f358f132fcfd1d91c03558d
csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline`;
`ac22d44d2cec45ebf5516f998a3c3aed8a5a1bc0932bf80fd0d6b9fa74a7a801
csi-spl-orc/src/bash/tests/desk-install-service-envs.tst.sh`;
`089426f4f7ccdeffa1cb144d7a990ad43c6fee188252725fa616e575e8f1f54c
csi-spl-iac/src/bash/tests/tf-apply-no-input.tst.sh`.

- Row 02 red control (empty argument): `bash -c 'source
  csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh; do_tf_log_open ""; echo "rc=$?"'`
  in /tmp/r78-base -> stdout empty (no `rc=` line), stderr
  `csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh: line 25: 1: do_tf_log_open: the log
  file`, subshell exit 127; same with no argument. `find /tmp/r78-base -newer <out>` ->
  nothing: the run created no file, so it never touches live state. It fails for the
  plan's reason (`${1:?}` exits the caller's shell at :25, so the caller's `|| return 1`
  never runs), not for an environment reason.
- Row 01 red control (default dir, read-only check): in /tmp/r78-base/csi-spl-orc,
  `env -u DESK_CRON_LOG_DIR PROJ_PATH=/tmp/r78-base/csi-spl-orc APP_PATH=<scratch repo>
  SPL_ORG_APP=csi-spl SPL_VAR_APP_DIR=$T/var STUB_CRONTAB=<scratch> PATH=<stub>:$PATH
  TENANT_ID=t1 ENV=prd DESK_SERVICE_ACTION=check bash -c '<source libs+run funcs;
  do_spl_desk_install_service>'` (the envs suite's own `svc` invocation shape) -> JSON
  `"log_dir": "/var/csi/csi-spl/desk-reconcile"` — the hand form, NOT
  `$T/var/desk-reconcile` — exit 1 (not installed in the stub crontab). `$T/var` was not
  created; `/var/csi/csi-spl/desk-reconcile` pre-exists (mtime 2026-11-19T00:31:57+02:00,
  before this run), so the red run touched no live path. It fails for the plan's reason
  (the spelled default ignores `SPL_VAR_APP_DIR`), not for an environment reason.

### 4. Equivalence of each row (code read at the cited lines)

- Row 01: `logdir` feeds the cron line (:127, :130), the check JSON `log_dir` (:138,
  :196), the dry plan (:236) and the install `mkdir -p` (:169) — all read, all present.
  Same-dir proof re-run by this seat, `env -i PATH=/usr/bin:/bin`, hand form
  `/var/${OA%%-*}/$OA/desk-reconcile` vs `spl_var_app_subdir d desk-reconcile` (that
  tree's `lib/bash/funcs/spl-run-paths.func.sh`) in the 3 trees of this box: main
  checkout `/opt/csi/csi-spl`, desk-cron checkout `/opt/csi/csi-spl-desk-cron`, this
  lane's worktree `/opt/csi/csi-spl-wt/m-555` -> all 3 print
  `/var/csi/csi-spl/desk-reconcile`, **3 of 3 EQUAL**. The proposed shape keeps
  `DESK_CRON_LOG_DIR` winning when set; the default dir is identical on the box's
  trees and differs only where the plan says (a preset `SPL_VAR_APP_DIR` —
  `spl_run_paths` keeps a preset, `: "${SPL_VAR_APP_DIR:=...}"` — or a tree outside
  `<base>/<org>/<app>`). The new envs-suite case would catch a derivation difference
  (its red control above shows the parent prints the hand form). Behaviour kept.
- Row 02: the 5 callers each pass a set log path and do `|| return 1` (verified at the
  cited lines); for a non-empty argument the function body after the guard is unchanged
  (`mkdir -p "${f%/*}" && (umask 027 && : >>"$f") && chmod 0640 "$f"`), so every real
  call keeps its output, exit code and paths. Only the empty-argument path changes: from
  a shell exit (observed: exit 127, no `rc=` line, bash's `line 25: 1: ...` message) to
  `return 1` with `do_tf_log_open: the log file` on stderr — see N1. The new section-3b
  case would catch a regression (subshell must print `rc=1` and create nothing).

### 5. Row fields (R2, tests, vendor, kind, batch, R7, R1)

From the plan's section 2 table, re-read: both rows carry a red control that fails
today (check 3) and passes after (R2), a test list (row 01: the 21 files of
`git grep -lE 'spl-desk-install-service|do_spl_desk_install_service' 4c5633d84 --
'*tests/*.sh' | wc -l` -> `21`, plus `no-literal-paths.tst.sh`,
`satellite-ansible.tst.sh`, `bash-cleancode.tst.sh`, `do_check_pre_push`; row 02:
`tf-apply-no-input.tst.sh`, `tf-log-mask-billing-id.tst.sh`,
`tf-apply-destroy-quoted-paths.tst.sh`, `bash-cleancode.tst.sh`, `do_check_pre_push`),
vendor `claude`, kind `simple_coding`, batch 1. **No mistral coding or testing row**
(vendor column is claude for both). R7: `BOX_PICK_KIND=grok ./run -a do_spl_box_pick`
re-run 2026-11-20T23:2xZ -> `pick=hold reason=waiting: grok weekly >= 95% on <box>,
<box> [<box> 99% ...; <box> 99% ...]`, so each row takes the claude waiver seat
(1a7c70da) — a
cross-vendor-or-waiver R7, never mistral. R1: batch 1 = rows 01 and 02; their files are
the 5 distinct paths of check 6 (orc run + 2 orc tests vs iac lib + iac test) — disjoint.
Baseline counts re-measured: `no-literal-paths-spelled.baseline` on `4c5633d84` ->
`19 lines in 17 files` (sum of column 1 over 17 files, header excluded), `:6` the
row-01 entry, so row 01 gives 18 in 16; `satellite-ansible.tst.sh` `n_sd` grep on
`4c5633d84` -> 6 distinct paths, `-ge 5` floor, row 01 removes 1 -> 5, still passes;
4 test files pass `DESK_CRON_LOG_DIR` (`desk-install-service-envs`, `-user`,
`desk-reconcile-boot`, `desk-up-all`); `git grep -n DESK_CRON_LOG_DIR 4c5633d84 --
csi-spl-doc | wc -l` -> `0` (the `Docs: none` claim holds).

### 6. R3: lane map over the row paths

`bash .../lane-map.sh --check csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh,csi-spl-orc/src/bash/tests/desk-install-service-envs.tst.sh,csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline,csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh,csi-spl-iac/src/bash/tests/tf-apply-no-input.tst.sh --agent m-555`
(2026-11-20T23:2xZ) -> **exit 4**: no live lane lists any of the 5 paths; 13 live lanes
record no files (unknown): c-146, c-199 (s123 p02), c-229, c-292 (s181 b1), c-324,
c-342 (s182 n4), c-345, c-347 (s033 t024), c-380 (bug wui export-pdf), c-391 (this
round's planner), c-812, c-924, c-927 — all on the other box. By slug none of the
spec 182 / 123 /
033 lanes (c-342, c-199, c-347) is a coding lane near these orc/iac paths (hub `topic_loop*`,
cost, CLI kinds). No `r78` row is queued yet (`do_spl_spawn_queue | grep -iE 'r78|round-78'`
-> empty). The plan's own 2.2 read the same exit 4 and says the holder re-checks the
unknown lanes before placing; this seat asked c-380 (a WUI lane) and it answered no.

### 7. Inputs accounted for

- Candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (75 lines,
  read whole), refactor-shaped items only: item 1 (`/var/` in `spl-watchdog.func.sh` /
  `spl-lane-rotate.func.sh`) — re-measured served: `git grep -nE '/var/' 4c5633d84 --
  <both> | grep -vE '^\S+:[0-9]+:\s*#' | wc -l` -> `0`; item 2 N3 -> row 02; item 2 N2
  (`terraform init` without `-input=false`) — left out as a behaviour change (my count:
  21 lines matching `\binit\b` without `input=false` in `csi-spl-iac/src/bash/run/tf-*.func.sh`
  incl. comments; `tf-plan-pending.func.sh:38` carries `-input=false`); item 2 N1 —
  no duplicate found, nothing taken; item 3 (desk hop env forwarding, SPL-5824) — left
  out, a forwarded-list change is a bug row; item 4 N1 (`spl-uplink-probe.func.sh:14-15`)
  — served (`:14-15` read, match the plan's quote); item 5 W1 (`reverse-tunnel-cron.sh`)
  — served (`:27` reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`);
  item 5 N3 (install guide :594) — left out, Qto export; item 6 (`10_ci-quality.yml:445`)
  — still there (`:445` read), left out, named first r79 candidate; item 7
  (agent-boot-restore dir) — served (`:59-60` call `spl_var_app_subdir`); item 8 (spec
  182 L2 `!inserted` untested) — left out while spec 182 N4 is live. Bug/test/secret-
  shaped candidates (SPL-5825, review-go, quota, sweep, panel-seat placer gap, etc.)
  are correctly not taken by a refactor round.
- r77 plan section 7 (lines 365-382 on `0782cf525`, read): `spl-desk-install-service.func.sh:120`
  -> row 01; `spl-unanswered-sweep-install-cron.func.sh:57` -> left out (spec 182 live;
  `:57` read, still spelled); `desk-reconcile-cron.sh:189` -> left out (own row, `n_sd`
  floor); the iac/utl spelled lines and the gate scope -> left out; the 3 tenant-dir
  sites -> secret-class, left out; `check-ysg-box-deps` -> left out (frozen engine name);
  spec 011 tasks -> left out. **Named as unaccounted (N2):** r77 s7's other two orc sites,
  `spl-spool-refresh.func.sh:55` (a NOTE text literal) and `spl-wd-ensure.func.sh:194`
  (the wd log dir literal) — both read on `4c5633d84`, both still in the spelled baseline
  (lines 10 and 12), but r78's section 7 does not name them.
- Each row is ONE logical refactor: row 01 changes no exit code, message, path or
  default on the box's trees (3 of 3 EQUAL, check 4); row 02 changes only the
  empty-argument error path (N1).

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` (2026-11-20T23:2xZ, this worktree) ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-555`,
rc 0.

## Defects

None. W1..: none.

## Notes

- **N1 (row 02, exit code on the error path):** the empty-argument path changes from a
  shell exit (observed exit 127, stderr `line 25: 1: do_tf_log_open: the log file`) to
  `return 1` with stderr `do_tf_log_open: the log file` — an exit-code and message
  change, confined to a path no caller exercises (all 5 callers pass a set log path).
  The plan states this delta in 1.4 and developer guide 2.4.3 mandates return-instead-
  of-exit, so this seat reads the row as a refactor with a documented error-path delta,
  not a bug row; the editor may rule otherwise.
- **N2 (inputs):** r77 s7's `spl-spool-refresh.func.sh:55` and `spl-wd-ensure.func.sh:194`
  are refactor-shaped inputs the plan neither serves nor names in its section 7 (both
  remain in the spelled baseline, so the gate still counts them). Candidates-file
  SPL-5825 N4 (a cap on reflection section 7) is hardening-shaped and also unnamed.
- **N3 (cosmetic counts):** the plan's "10 in 4 orc" `${1:?}` count reads as orc lib+run
  only (`git grep -cE '^\s*local [a-z_]+="\$\{1:\?' 4c5633d84 -- csi-spl-orc/lib
  csi-spl-orc/src/bash/run` -> 10 in 4 files; over all of csi-spl-orc -> 13 in 6). The
  plan's "13 init calls" is the same class as my 21 matching lines incl. comments. Both
  are left-out items, so the counts do not change any row.

## State history

- 2026-11-20T22:55Z commit `b847bc3f2`: state commit after the 23:03Z lane rotation —
  verdict PENDING, checks 1 and 8 pre-run, checks 2-7 marked NOT RUN (no plan sha yet),
  pushed to `review/c002-refactor-round-78-mistral-seat` only.
- 2026-11-20T23:2x-23:3xZ this commit: full review of `a5f35558a` (checks 1-8 above),
  verdict PASS, notes N1-N3.

Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md`, then
`cd csi-spl-orc && sudo -u <PUSH_USER> env AGENT_ID=m-555 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
-> `OK m-555 already confirmed developer-guide.md blob 8b1916cdc...` (recorded
2026-11-20T22:xxZ by the previous m-555 session; re-confirmed 2026-11-20T23:0xZ).
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-5), the plan at `a5f35558a`,
`csi-spl-doc/doc/md/refactor-round-77-plan.md` section 7 (on `0782cf525`),
`/var/spool-hub/dispatch/c002-next-round-candidates.md`, the planner's brief
`c002-refactor-round-78-planner.md`.

## v1.0 signature

**PASS** on the editor's v1.0 `2b7bb502ac83b1bd38098d623e75f52ad3b1d46b` (on
`origin/master`, read 2026-11-20T23:5xZ). Verified before signing:
`git diff bacd0159c 2b7bb502a -- csi-spl-doc/doc/md/refactor-round-78-plan.md` touches
only sections 8-9 and the N3 count wording; the row table is byte-identical
(`diff <(git show bacd0159c:<plan> | sed -n '/## 2. The 2 rows/,/### 2.1/p') <(git show
2b7bb502a:<plan> | sed -n '/## 2. The 2 rows/,/### 2.1/p')` -> empty, ROWS-IDENTICAL).
Section 9 of v1.0 records this seat's PASS on `a5f35558a` with N1-N3 and the holder's
review-line check rc 0 (DOCS-ONLY). Rows unchanged from the reviewed v0.1, no new
defect: this seat signs v1.0 `2b7bb502ac83b1bd38098d623e75f52ad3b1d46b`.
