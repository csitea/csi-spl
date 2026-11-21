# Refactor round 82 — panel seat mistral (m-742@<box>)

Issue: SPL-6166 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-82-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-82-plan.md` on branch
`review/c002-refactor-round-82-planner`, at the v0.1 sha the dispatch holder named
(spool msg d1b444fd-9c70-419a-bedd-d5c551029327, 2026-11-21T08:00:32Z, task
`dispatch-refactor-r82`): `68117dca89e4a32b006c551752a968cf60e3e04e` (1 commit on
a83052abd, 1 file +402; `git log -1 --format='%H %cI %s'` -> `68117dca89e4a32b006c551752a968cf60e3e04e
2026-11-21T08:59:16+01:00 docs(r82-plan, SPL-6166): ... v0.1 ...`). Editor c-706@<box>.
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 the panel signs
the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-81-plan.md` and `refactor-round-81/seat-mistral.md`
(on origin/master). Measured base `3174e591a` (the plan's own "One sha",
`git log -1 --format='%H %cI %s' 3174e591a` -> `3174e591a3be523484f450c60a7a8c7f97fc65d9
2026-11-21T09:44:36+02:00 refactor(r81-01-..., SPL-6163): ...`); `origin/master` at my
reads `5d9bcef49` (`git log -1 --format='%H %cI %s' origin/master` -> `5d9bcef497b71bfeb857374753b05f04d33cefe0
2026-11-21T10:44:59+02:00 docs(spec-190, SPL-6152): ...`). Every file:line below was
checked with `git show <sha>:<file> | sed -n <N>p` on both shas.

## Verdict

**PASS** on `68117dca89e4a32b006c551752a968cf60e3e04e`. 2 rows (5.1: aim 2, at most 3),
both `refactor`, vendor claude, kind `simple_coding`, batch 1, files disjoint (check 5).
No W defect. Notes N1-N4 below.

### 1. Slug r82 unused since the plan's `Window: W=`

W recorded `2026-11-21T09:19:19+02:00`; its source verified:
`git log -1 --format='%H %cI %s' 864f7ff17` -> `864f7ff17f842cd9b60d8b3067138e3dec2bc6cf
2026-11-21T09:19:19+02:00 docs(r81-plan, SPL-6161): refactor round 81 plan v1.0, panel
m-723 mistral PASS on v0.1 7dbfe9f78 ...` — matches the plan's 1.1 exactly. (Re-deriving
now gives `b474a58fb` 2026-11-21T10:38:08+02:00, the r81 close record landed after the
plan's read; per rulebook 5.3 the recorded W is the one every later read uses.)

- `git log origin/master --since="$W" --oneline -E --grep='\(r82-' | wc -l` -> **0**; the
  same grep over all history (no `--since`) -> **0**. Control: `(r81-` since W -> **5**
  lines (`3174e591a`, `864f7ff17`, `67546e091`, `1fd68677a`, `b474a58fb`), so the read sees
  a used id. (The plan read 3 at 07:48:48Z; r81-02 `1fd68677a` and the close record
  `b474a58fb` landed since — N3.)
- `git ls-remote origin | grep -E 'r82-[0-9]{2}|refactor-round-82'` -> one line:
  `68117dca89e4a32b006c551752a968cf60e3e04e  refs/heads/review/c002-refactor-round-82-planner`
  (the planner's, expected; my seat branch is pushed after this read). The 5.3 pattern
  set `git ls-remote origin 'refs/heads/review/r82-*' 'refs/heads/wip/*r82*' 'refs/heads/*-r82-*' 'refs/heads/*refactor-round-82*'`
  -> the same one line.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r82-[0-9]{2}|refactor-round-82'` -> exactly
  the 2 expected files (`c002-refactor-round-82-planner.md`,
  `c002-refactor-round-82-mistral-panel-seat.md`); `ls /var/spool-hub/spawn-remote/briefs | grep ...`
  -> none (rc 1).
- `git ls-tree 3174e591a csi-spl-doc/doc/md | grep -c refactor-round-82` -> **0**, so the
  plain plan name is right (rulebook 5.3 "Files").

### 2. Every site file:line of every row exists on the base sha and on origin/master

Every cited line printed with `git show 3174e591a:<file> | sed -n <N>p` and
`git show origin/master:<file> | sed -n <N>p`: all **SAME**, none empty.

- row 01 sites, both copies (`csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh` and
  `csi-spl-orc/...`): `:40` -> `  local key="${1:?key}" cnf="${2:-}"`, `:138` ->
  `  local ENV="${1:?env}" ORG="${ORG:-}" ...`, `:171` -> `  local key="${1:?key}" email have`,
  `:216` -> `  local mode="${1:?mode}" cnf="${2:-}" account key`, `:264` ->
  `  local mode="${1:?mode}" cnf="${2:-}" account`; `:159` ->
  `  email=$(jq -r '.client_email // ""' "${1:?key}" 2>/dev/null)` (the left-out line);
  header `:23-24` ("kept byte-identical in csi-spl-iac and csi-spl-orc"); stdout prints
  `:56` `printf '%s' "${val}"`, `:182` `printf '%s' "${email}"`, `:218` the account printf.
- row 01 test `csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`: `:21` Purpose
  ("4. The csi-spl-iac and csi-spl-orc copies of the lib are byte-identical."), `:35`
  `PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"`, `:194-195`
  `ORC_PIN=...` / `cmp -s "$PIN" "$ORC_PIN" && pass ... || fail ...`.
- row 02 sites: `csi-spl-orc/lib/bash/funcs/validate-params.func.sh` `:13`
  `local file_path="${1:?Usage: do_validate_params <file_path>"}`, `:26` ->
  `    # Extract variable name (first word)`, `:30` -> `    # Check if marked as required`;
  iac and utl copies `:26-27` / `:30-31` carry the two-line forms; the caller guard is
  `src/bash/run/run.sh:159-160` (`if [[ -n "$func_file" ]] && type do_validate_params ...`
  / `do_validate_params "$func_file"`), identical in all 4 copies (iac, orc, utl, root —
  N2: a module-root `run.sh` does not exist).
- row 02 test `csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`: `:3-11` Purpose, `:24-32`
  the `for mod in orc utl root` cmp loop (`:32` is `done`; the root-copy real-file check is
  `:33-37` — N2), `:38-41` the planted-drift control.
- Copies on base: `git show 3174e591a:<f> | md5sum` -> pin iac = pin orc
  `991ba303277e299530ad0146f4ed0d3e`, 322 lines each, `grep -c ':?'` -> **6** per copy;
  validate-params iac = utl `e0417d8329220049987e2b3bfc7cbdc9` (65 lines), orc
  `8cc55f38063b7075be76574f8ce9b2ef` (63 lines); `diff` iac vs orc -> 2 hunks, comment
  lines only (`26,27c26` / `31,32c30`; the plan prints the reverse direction — N2).
- `git grep -nE 'local [A-Za-z_]+="?\$\{[0-9]:\?' 3174e591a` over the 6 lib+run dirs ->
  **30 lines in 12 files** (matches plan section 6).
- Drift: `git diff --name-only 3174e591a origin/master -- <the 5 row paths>` -> empty
  (rc 0); `git log origin/master --since="$W" -- <the 5 row paths> | wc -l` -> **0**.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch: `git archive 3174e591a | tar -x -C /tmp/r82-scratch3` + `git init` + `git add -A`
(a staged index is needed: the pin suite's section-6 CONTROL at `:264-271` runs
`git grep`, blind on an empty index — N4), run with `SPOOL_TEST=1` and `SPOOL_ROOT`
pointed at the scratch; the guard `spool_test_guard` (`spool-env.inc.sh:381-387`) refuses
the live spool root under `SPOOL_TEST=1`; the tests write only under their own `mktemp $T`.
Nothing touched `/var/spool-hub`. sha256sums at base (`git show 3174e591a:<f> | sha256sum`):

- `d0aa1d8acbbadf7cb62e418fbbe089ac410b8434b3ee6046ce05b597cbaa1bc9  csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`
- `5a4786de38c2607a51ae3bd791eb52486a641fe22ef9cd0fee5fa6b6cc2b81bd  csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh`
- `62f5a3470888d1fecd0e78a78081d7adc40b05a97f136760fb3ef00fee6abe5a  csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh`
- `62f5a3470888d1fecd0e78a78081d7adc40b05a97f136760fb3ef00fee6abe5a  csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh`
- `ac6ab34a9d8ad03e1351afb0d5132a20649dad339cdd2b8d653a8d7b4f001e84  csi-spl-orc/lib/bash/funcs/validate-params.func.sh`
- `8a6cc385efb5d5d31dff32b15af86bfbbb45a4466eee19bbe4bacca38f83406a  csi-spl-iac/lib/bash/funcs/validate-params.func.sh`

(the two pin copies share one sum, as the plan's byte-identical claim says; the suites
were re-read from the archive, so the sums match the scratch copies byte for byte).

Before (unmodified base, staged git-init copy, n=1): `SPOOL_TEST=1 bash
csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh` -> rc **0**, 38 pass 0 fail
(matches plan 1.5's "before 0/38 git init copy"); `SPOOL_TEST=1 bash
csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh` -> rc **0**, 6 pass 0 fail.

- **Row 01, red control (plan 1.3's section 4b inserted after `:195`, lib unmodified):**
  rc **1**, last line `FAIL: 11 assertion(s) in gcloud-account-pinned.tst.sh`, 10 `4b`
  FAIL lines, e.g. `FAIL: 4b. do_gcp_cnf_value '""': .../gcp-account-pin.func.sh: line 40:
  1: key` (likewise `:138` `1: env`, `:171` `1: key`, `:216` `1: mode`, `:264` `1: mode`),
  each with **no `rc=` line** — fails for exactly the plan's reason (the `${1:?}` exits
  the shell), not for an environment reason. **Green** (1.3's shape applied to both
  copies, `cmp` of the copies stays equal, 322 -> 327 lines, only `:159` keeps `:?`):
  rc **0**, 48 pass 0 fail, 10/10 `4b` PASS lines; direct measure per function and form
  (`""` and no argument): `FATAL <fn>: usage: <fn> <args>` on stderr + `rc=1`.
- **Row 02, red control (plan 1.4's cmp loop inserted after `:32`, orc copy unmodified):**
  rc **1**, last line `FAIL: 1 assertion(s) in run-sh-parity.tst.sh`, FAIL line
  `FAIL: iac and orc validate-params.func.sh differ -- diff ...` (utl passes). **Green**
  (orc copy := iac text, `diff` -> empty, 63 -> 65 lines): rc **0**, 8 pass 0 fail, both
  `PASS: iac and orc|utl validate-params.func.sh are byte-identical`.

### 4. Equivalence of each row

- **Row 01:** on a non-empty first argument `local x="$1"` is identical to
  `local x="${1:?word}"`, so every real call behaves as before; only the empty/missing
  path changes. Measured on the base lib (n=1 per form): direct call `""` prints
  `line 40: 1: key` and **no `rc=` line** (the shell exits); in `x=$(fn "")` the caller
  reads `caller-rc=1`. Callers outside the lib (`git grep -nE ... 3174e591a`): 
  `do_gcp_cnf_value` 1 (`csi-spl-iac/src/bash/run/gcp-evlog-reader-key.func.sh:39`, a
  literal key), `do_gcp_env_sa_key_file` 4 (the `gcp-get-alert-incident`,
  `gcp-list-alert-incidents`, `gcp-list-monitoring`, `gcp-list-secrets` actions, each
  `key=$(do_gcp_env_sa_key_file "${env}" ...) || {...}`), `do_gcp_activate_sa_key` 4
  actions + tests (`gcp-copy-secret.func.sh:80` the one direct call, the rest in `$(...)`),
  `_do_gcp_resolve_account` and `_do_gcp_pin` 0 outside the lib (the wrappers pass the
  literals `run`/`bootstrap` at `:202`, `:212`, `:252`, `:260`; `_do_gcp_pin` calls the
  resolver with its own `mode` at `:268`). Every caller passes a non-empty first argument;
  none takes the empty path. The control catches the difference: 4b RED on the parent,
  GREEN on the head (check 3).
- **Row 02:** `diff -U0` iac vs orc on base -> `grep -E '^[-+][^-+#]' | grep -vE '^[-+]\s*#'` ->
  **0** non-comment changed lines; the code under each comment is the same. The cmp loop
  catches any difference (the file's own planted-drift control `:38-41` proves `cmp -s`
  sees a one-byte change).

### 5. Row fields (R2, R7, R1)

Each row has a control that fails today and passes after (check 3), a test list (plan
1.5), vendor **claude**, kind **simple_coding**, batch **1**. No mistral coding or testing
row. R7 reviewer per row: a fresh **claude waiver seat** (1a7c70da) per plan section 4
(`BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 07:56:08Z printed `pick=hold ...`) —
cross-vendor or waiver, never mistral. R1: `comm -12` of row 01's file set
(`gcp-account-pin.func.sh` iac+orc, `gcloud-account-pinned.tst.sh`) and row 02's
(`orc validate-params.func.sh`, `run-sh-parity.tst.sh`) -> **0** shared files; 5 distinct
row paths.

### 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh,csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh,csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh,csi-spl-orc/lib/bash/funcs/validate-params.func.sh,csi-spl-iac/src/bash/tests/run-sh-parity.tst.sh --agent m-742`
-> **exit 4**, 15 `unknown:` lanes, all on the other box: c-146, c-461 (s123-p05), c-463, c-490
(s033-t025-t027), c-506, c-562, c-579 (wui qto), c-598, c-601, c-602, c-697 (s123-l2b),
c-706 (the r82 planner itself), c-812, c-924, c-927 — all rotate/spec/wui/planner slugs,
none a row path. Per path individually: exit 4 on all 5, no exit 3 — no live lane lists a
row path. The r81 rows are landed (`3174e591a`, `1fd68677a`, in the check-1 control), bug
round 33's plan v1.0 is landed (`a83052abd`), the spec 123 (c-461, c-697) and spec 033
(c-490) lanes are live on the other box but their slugs name cost/wui files, not a row path. Spawn
queue (`./run -a do_spl_spawn_queue`): 15 queued, 0 placing; held items spec 184
(SPL-6036), s033-t026, s123 L2b-L7 — none on a row path. Briefs naming a row basename in
the last 24 h (`find ... -mmin -1440 | xargs grep -lE 'gcp-account-pin|gcloud-account-pinned|validate-params\.func|run-sh-parity'`):
only the r81 and r82 planner briefs.

### 7. Inputs accounted for

The candidates file **is on this box** (`ls -la
/var/spool-hub/dispatch/c002-next-round-candidates.md` -> 101 lines, mtime
2026-11-21T06:39Z; the plan's "not on this lane's box" holds for the other box only — N4). Every
refactor-shaped item in it is served or accounted for:

- served: `[refactor] SPL-6107 N1` `spl-desk-reply.sh:9,19` -> r81-01 `3174e591a`; the
  watchdog/rotate `/var` literals, `reverse-tunnel-cron.sh:23`, the agent-boot-restore
  dir and the wf10 comment -> r79-01 (`75da57eb4`; re-verified on origin/master: no
  `/var/` literals left in `spl-watchdog.func.sh`/`spl-lane-rotate.func.sh` outside
  comments, `reverse-tunnel-cron.sh:23` is now a shellcheck source line); `tf-log-mask`
  `${1:?}` -> r78-02 (`ba7acd634`; `:25` now reads `[[ -n "${1:-}" ]] || { ... return 1; }`).
- accounted in r82 section 7 with reasons: `parse-metadata.func.sh` 3 copies (12 lines
  over 3 files, over the 5-site cap; first candidate for r83), `validate-params:13`
  (caller guarded at `src/bash/run/run.sh:159-160`, all 4 copies), pin `:159` (already
  returns 1), the other `${N:?}` lines (re-measured: 30 in 12 files), `tf-each-target`,
  `gcp-billing-cnf`, `spl-cost-gcp` (`set -e` by design; beside the s123 lanes),
  `spl-self-host-up.func.sh:317` (r81-02, landed `1fd68677a`), the `DESK_KIND` check,
  `terraform init` without `-input=false` and the desk hop's env forwarding (bug rows),
  the tenant-dir sites and `gcp-backup-env.func.sh` (secret-class), spec 011 tasks
  (owner-deferred), `spl-spawn-place-argmax.tst.sh` s9, spec 182 L2 `!inserted`,
  `ws-docs-head.mjs`, spec 181 B10 N1/N2/N4 (r81 section 7's reasons hold).
  `installation-and-configuration-guide.md:594` is accounted by r80 section 7's "ask to
  the holder" ruling (r81 N4), not re-listed in r82 section 7.
- Behaviour-change scan: row 01 changes only the empty/missing-argument path, which no
  caller takes (check 4): shell exit -> `return 1` plus a usage line on stderr, disclosed
  in plan 1.3 and section 2 and pinned by 4b, the same shape as landed r80-02 `5083f4cf9`
  and r81-02 `1fd68677a` (N1). Row 02 changes comment lines only (0 non-comment diff
  lines, check 4): no exit code, message, path or default changes.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean
over the tracked tree of /opt/csi/csi-spl-wt/m-742`, exit 0 (re-run after this file was
added: clean).

## Defects

None. No W.

## Notes

- **N1:** row 01 does change an exit behaviour on the empty/missing-argument path: on
  base the `${1:?}` exits the caller's shell (measured: no `rc=` line direct,
  `caller-rc=1` in `$(...)`), the row returns 1 with a usage line. Confined to a path no
  caller takes (check 4), it is the fail-safe developer guide 2.4.3 mandates, disclosed
  in plan 1.3 and pinned by the row's control; r80-02 `5083f4cf9` and r81-02 `1fd68677a`
  set the same precedent. Recorded, not a W.
- **N2:** citation imprecisions, none touching a row site: "run.sh:159" is
  `src/bash/run/run.sh:159` (a module-root `run.sh` does not exist; the guard `:159-160`
  is identical in all 4 copies); run-sh-parity's "root-copy check (`:32`)" is `:33-37`
  (`:32` is `done` — the loop goes after `:32`, not before it); the plan's iac/orc
  validate-params diff is printed in the reverse direction (`26,27c26` / `31,32c30` vs
  the plan's `26c26,27` / `30c31,32` — same content).
- **N3:** live-state counts moved between the plan's reads and mine: the `(r81-` since-W
  control 3 -> 5 lines (`1fd68677a` r81-02 and `b474a58fb` the r81 close record landed;
  r81 is closed); lane map 11 -> 15 `unknown:` lanes (exit 4 both times, none on a row
  path); spawn queue 12 -> 15 queued; the share line refactor 6/37 16% -> 3/31 9% UNDER.
  All carry their own times; the holder's re-check before placing is the one that counts.
- **N4:** the candidates file is on this box and was read here; and a scratch copy
  of the base needs a staged git index (`git init` + `git add -A`) or the pin suite's
  section-6 CONTROL fails `CONTROL: the literal grep is blind` (`git grep` reads the
  index); with it staged, before = 38 pass rc 0 exactly as the plan's 1.5 says.

## State history

- 2026-11-21T09:0xZ commit on `review/c002-refactor-round-82-mistral-seat`: full review of
  `68117dca89e4a32b006c551752a968cf60e3e04e` (checks 1-8 above), verdict PASS, notes
  N1-N4.

Seed STEP 0: `cd csi-spl-orc && sudo -u <push user> env AGENT_ID=m-742 DEV_GUIDE_ACK=yes ./run -a
do_dev_guide_ack` -> `OK m-742 already confirmed developer-guide.md blob 8b1916cdc`.
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-5), the plan at `68117dca` (via
`git show <sha>:csi-spl-doc/doc/md/refactor-round-82-plan.md`),
`refactor-round-81-plan.md` and `refactor-round-81/seat-mistral.md` (origin/master, the
form), `/var/spool-hub/dispatch/c002-next-round-candidates.md`, both r82 briefs, and the
row site and test files at `3174e591a` via `git show` / `git grep`.
