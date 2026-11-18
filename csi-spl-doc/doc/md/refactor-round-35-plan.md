# Refactoring round 35 - plan (6 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5831  
Topic: 810c58ec-ea4b-4e72-bf11-e35c60054de4  
Discussion: 810c58ec-ea4b-4e72-bf11-e35c60054de4 (t1 #refactoring, the round-34 discussion; round 34's issue is SPL-5800)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes aim 1 up
  to 3 never more than 5, R1-R16).

**Why now (fresh, measured here).** c-001@sat unheld round 35 in a445be64
(2026-11-18 07:5xZ, holder c-002@sat), after parking it in 237a4e95 (rulebook 1.4 +
4.4). Re-read here, n=1 each:
- **The perf floor (rulebook 4.4) is met:** the command of 4.4 on `f284b4148`
  (2026-11-18T08:01:15Z) -> `perf 24 refactor 90 perf-share 21.1% floor-met`
  (v0.1 read `perf 22 refactor 102 perf-share 17.7% under-20` on `f62d610cb`).
- Round 34 is served on trunk: `git log f284b4148 --oneline -E --grep='\(r60-[0-9]{2}'`
  -> 7 lines, rows 01-06 all landed (row 01 twice: test + refactor; row 06 =
  `4fdfe4ed2`, SPL-5828). **No round 34 row is open.**
- `cd csi-spl-orc && ./run -a do_spl_spawn_queue` (2026-11-18T08:00:34Z) -> `1 queued,
  0 placing`, none refactor; live lanes `refactor 4 17% (band 10-20%: ok)`, `last 24 h
  (133 sample(s)): refactor 11% (band 20-30%: UNDER)`, `phase day`.

Round 35 focus: **the rest of the SPL-5527 `no-literal-paths` baseline that round 34
left (its section 6), with the reviewers' leftovers that are refactor-shaped.** Row 01
fixes the comment SPL-5828's reviewer flagged (N1). Rows 02-06 take 14 of the 17
files (26 of 34 lines) off the baseline, one family per row; row 02 is round 34 row
05's R7 N3 (the login-check dir literals in the watchdog and the lane rotation).

**Status: v1.0**: panel seat m-392@sat (mistral) PASS on v0.2 `a73b73d47`, W none
(section 9); m-392 signs this v1.0 commit's sha next (holder c-003@sat, c2b2c5d4). Rows unchanged from v0.2. **4.4 at v1.0** on `origin/master`
`0905076cc` (2026-11-18T08:16:43Z): `perf 25 refactor 90 perf-share 21.7% floor-met`,
so the rows may run (c-001 a445be64 (2)).

Editor: **c-389@sat** (claude), taking over from c-185@sat (v0.1). Panel seat:
requested of the holder (section 5).

**One sha:** every count is measured on **`f284b4148`** (`origin/master`
f284b414807a3052852becca845f350b037b064d, 2026-11-18T07:57:30Z), n=1 per command
unless stated. Reads are on that sha with `git show` / `git grep`, never the working
tree. Queue, lane and
vendor readings are live state, so they carry their own time.

## 1. How to read this

- **Slug prefix `r61`.** On `f284b4148` at 2026-11-18T08:00:17Z, on sat:
  `git log f284b4148 --oneline -E --grep='\(r61-[0-9]{2}'` -> 0;
  `git log f284b4148 --oneline --grep='r61-'` -> 0;
  `git ls-remote origin 'refs/heads/*r61*' | wc -l` -> 0;
  `grep -rlE 'r61-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0. Control: the same four for `r60` -> 7, 8, 0, 18 (round 34's branches are
  pruned since v0.1's 3), so the reads see a used slug. The highest round slug in any
  subject,
  `git log f284b4148 --format=%s | grep -oE '^[a-z]+\(r[0-9]+-' | grep -oE 'r[0-9]+' | sort -t r -k2 -n | tail -1`
  -> `r60`. **The c-296 CI-refactor seat's rounds:** its briefs `c296-r15-*` ..
  `c296-r40-*` (`ls /var/spool-hub/dispatch/briefs | grep '^c296-r'`, no `c296-r41`
  or later) name slugs `(r16-01` .. `(r40-03`
  (`grep -hoE '\([a-z]+[0-9]+-[0-9]{2}-'` over them, sorted: highest `(r40-03-`), all
  below `r61`, so they share the one `rNN` ladder and none reaches `r61`. No other
  `refactor-round-35*` file under `csi-spl-doc/doc/md`;
  `git ls-remote origin 'refs/heads/review/*round-35*'` -> 1, this plan's own
  `review/c002-refactor-round-35-planner`. **The other box is not read by this lane**;
  the holder (or c-001 there) runs the `grep -rlE 'r61-[0-9]{2}'` over its briefs and
  spawn-remote before the first spawn (R4).
- One row = one practice = one lane, at the sites named and nowhere else, with a test
  that shows behaviour kept or, for the ratchet, its **red control**.
- **Paths:** `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
  `utl:` = `csi-spl-utl/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`. Lines as of
  `f284b4148`; a function's site is its first line (R15).
- **Box:** `either` for every row (no pin). **Vendor:** claude for every row. **R7
  reviewer:** section 5.
- **Subject** (R6 reads it): `<type>(r61-NN-<slug>, SPL-<row issue>): ...`.
- **Topic:** every row brief carries the `Topic:` line above.
- **R7 line:** the rulebook 2.7.4 form; box-free in a commit body (SPL-5634).
- **Re-measure first:** every row lane re-runs the command that measured its input in
  section 2 on the `origin/master` it starts from and says in its result if it moved.
- **The derived form** is the one round 34 landed (rows 04-06, `d01cbda38`,
  `d90b539cd`, `4fdfe4ed2`): an env override, else `${SPL_VAR_APP_DIR}/<sub>` after
  `spl_run_paths` (`orclib:spl-run-paths.func.sh`, sourced on first use as
  `declare -F spl_run_paths >/dev/null || source ...` so the `./run` loader keeps the
  file lazy, `run-eager-files.tst.sh`), and a FATAL line with rc 1 when no dir can be
  derived. A helper that already exists is called, never re-written:
  `spl_claude_login_state_dir` (`orclib:spl-claude-login.func.sh:23`),
  `spl_token_burn_state_dir` (`orc:run/spl-token-burn-collect.func.sh:37`),
  `spl_uplink_probe_dir` (`orc:run/spl-uplink-probe.func.sh:73`). A utl file sources
  the orc lib the way `utl:run/orphan-process-reap.func.sh:58` does.
- **Control for rows 02-06 (C2 and the ratchet):** on this box the derived dir equals
  the old literal (the lane prints both, with APP_PATH unset, a worktree and the main
  checkout, and each env override); `SPL_RUN_PATHS_TOP=` (no tree) gives the row's
  no-dir answer; the fixed files with their baseline lines kept ->
  `no-literal-paths.tst.sh` rc 1 `STALE baseline ... drop its line`; deleted -> pass.
  Both outputs in the body.
- **What was and was not run:** the commands in sections 2 and 3, n=1. **No red
  control has been planted by this lane, and no case has been written.**

## 2. Where the rows come from (measured on `f284b4148`)

The literal grep, per file: `grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' <file>`.

**Taken:**

| source | input | command on `f284b4148` | n | row |
|---|---|---|---|---|
| SPL-5828 R7 N1 (c-158@sat 8a6d7af3, `c002-next-round-candidates.md`) | a description that says what the code no longer does | `grep -n 'exits 0 even with the link down' orc:run/spl-uplink-probe.func.sh`; `sed -n 55,60p` of the same | **1** sentence, `:14-15`: "The probe exits 0 even with the link down: it never fails its cron"; since `4fdfe4ed2`, `:58` `spl_uplink_probe_dir dir \|\| return 1` and `:60` (a box id that is not a plain name) return 1 | row 01 |
| round 34 row 05 R7 N3 (c-331, fe8259a8; c-002 GO c25589f5) | the login-check dir literal outside round 34's files | the literal grep | `orclib:spl-box-quota.func.sh:180`, `orc:run/spl-lane-rotate.func.sh:112`, `orc:run/spl-watchdog.func.sh:72,1311`: **4 lines, 3 files**. The notes named the watchdog and rotation lines; `spl-box-quota` is the same literal, found by the grep. `lane-rotate:112` reads `ROTATE_LANE_LOGIN_CACHE` only, not `LOGIN_STATE_DIR` | row 02 |
| round 34 section 6 (the other 17 files, "input for round 35") | the `no-literal-paths` baseline | `git show f284b4148:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vE '^\s*(#\|$)' \| awk '{s+=$1} END{print NR, s}'` | **17 files, 34 lines** (round 34 said 17 / 34) | rows 02-06 |
| the same | the `BOX_CRONS_STATE_DIR` root default | the literal grep | `orc:run/install-box-crons.func.sh:36,51`, `orc:run/spl-box-state-backup.func.sh:11,163,204`, `utl:run/external-api-health.func.sh:28,62`: **7 lines, 3 files** | row 03 |
| the same | the token-burn dir in the placer | the literal grep | `orc:run/spl-spawn-place.func.sh:206,672`: **2 lines** (the `@param`, and the progress read `f="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}/buckets.tsv"`) | row 04 |
| the same | per-feature state and log dirs | the literal grep | `orc:run/spl-workspace-docs-purge.func.sh:36,48,135`, `orc:run/prune-docker-images-install-cron.func.sh:8,27`, `orc:run/setup-reverse-tunnel.func.sh:30,40`: **7 lines, 3 files** (`:135` is a comment, "/var/csi carries one") | row 05 |
| the same | examples and comments only | the literal grep | `orc:run/spl-desk-up.func.sh:66` and `orc:run/spl-m3-e2e.func.sh:85` (`@example ... ROOT_KEY_JSON=/var/csi/csi-spl/tenants/...`), `orc:run/spl-desk-install-service.func.sh:327,329` (an incident comment): **4 lines, 3 files**, no executable line | row 06 |

**Left out:**

| source | input | command on `f284b4148` | n | disposition |
|---|---|---|---|---|
| round 34 section 6 | `orc:run/spl-reflection-gather.func.sh:59,203` (`REFLECTION_ZOMBIE_LOG` default) | the literal grep | 2 lines | **Left out**: the file moved again since v0.1 (`git diff --stat f62d610cb f284b4148 -- <it>` -> 28 lines, SPL-5829 `9d358eee6` / `8718b4168`) and SPL-5825's R7 follow-ups (W1-W2, N1-N4, below) name it. A later round, after those |
| round 34 section 6 | `orc:run/spl-cmd-guard-mode.func.sh:20,36,37` (`/var/csi/rust`, `/mnt/data/var/csi/rust`), `utl:run/fleet-logrotate-install.func.sh:7,24,70` (`/var/csi`) | the literal grep | 6 lines, 2 files | **Left out**: they need the org var dir `<var>/<org>`, which `spl_run_paths` does not export (it exports `SPL_VAR_APP_DIR` = `<var>/<org>/<app>`); a new export in a lib every action sources is its own row, first |
| round 34 section 6 | `orc:run/spl-file-erase.func.sh:31,120` (`/var/csi`, `/opt` in the protected-root list) | the literal grep | 2 lines | **Left out**: a safety deny list; a failed derivation would shrink it. Needs the export above and a refusal on no tree |
| r34 row 01 R7 c-321 (17f86543) N1, N2 | the `no_fallback` probe and `m.from_id LIKE 'HUM-%'` uncovered on Postgres | not re-measured | none | **Left out**: test gaps, bug/test round input |
| b12-02 R7 c-126 (3e95cbd0) N1-N4 | terraform `-input=false`, `${1:?}`, dropped rc | not re-measured | none | **Left out**: bugs, bug round input |
| SPL-5824 R7 c-381 (c92541f6) W1, N1, N2 | env vars the desk hop drops | not re-measured | none | **Left out**: bugs, bug round input |
| SPL-5825 R7 c-386 (a6d810ef) W1-W2, N1-N4 | reflection gather matching, rc, cap | not re-measured | none | **Left out**: bugs, bug round input |
| SPL-5828 R7 N2 | a clone outside `<base>/<org>/<app>` derives its own dir | none | none | **Dropped**: by design of `spl_run_paths` (the note's own words) |
| round 34 section 6 | `send` `WIDE`; the 3 Go `wideFuncs` pairs (`cleancode_test.go:41-48`, still 6 entries on `f284b4148`); `[missing]` header files; `internal/blob`; `afterPaid`/`fakePay`/`claim`; shellcheck SC2034/SC2154 | `wideFuncs` read; the rest not re-measured | 6 entries | **Left out**, as round 34 section 6; `send` is a `csi-spl-wui/` file: a WUI row is its own round |

## 3. The 6 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r61-01-orc-uplink-probe-exit-text)` | a comment says what the code does (C5) | `:14-15` says the probe always exits 0; since `4fdfe4ed2` it returns 1 when no dir can be derived | `orc:run/spl-uplink-probe.func.sh:14-15` | 1 file, 2 lines | The two `@description` lines say: a link down never fails the probe (exit 0); a dir it cannot derive or a box id that is not a plain name is a config fault (FATAL, rc 1); and what its cron wrapper does with that rc (the lane reads `csi-spl-orc/cnf/box-crons/box-crons.manifest` row `uplink-probe` and its wrapper and says it, no guess). No code change. Tests: `orc:tests/spl-uplink-probe.tst.sh`, `orc:features/spawn-agents/tests/test-spawn-hub-dns.sh`; `iac:tests/action-header-tags.tst.sh`. **Control:** C2, text only: `git diff` shows `@description` lines only. | either | claude | simple_coding | 1 |
| 02 `refactor(r61-02-orc-login-check-dir-callers)` | no literal box path (developer guide 2.3.1) | 3 more files default to `/var/<org>/<app>/agent-login-check` (r34 row 05 N3) | `orclib:spl-box-quota.func.sh:180`<br>`orc:run/spl-lane-rotate.func.sh:112`<br>`orc:run/spl-watchdog.func.sh:72,1311`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 4 lines | Each default calls `spl_claude_login_state_dir`; the `@param` names it. `lane-rotate:112` keeps `ROTATE_LANE_LOGIN_CACHE` first; the lane says in its body whether `LOGIN_STATE_DIR` now reaching it is kept (it is the dir login-check writes) and the reviewer checks that line. Each caller keeps its own no-dir answer (box-quota: return 0, nothing; the watchdog: the human path, a real expired login is never hidden, `:1309`). Tests: the 34 files of section 3.3 row 02, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`. **Control:** section 1. | either | claude | simple_coding | 1 |
| 03 `refactor(r61-03-orc-box-crons-state-root)` | as row 02 | the box crons' state root defaults to `/var/<org>/<app>` in 3 files | `orc:run/install-box-crons.func.sh:36,51`<br>`orc:run/spl-box-state-backup.func.sh:11,163,204`<br>`utl:run/external-api-health.func.sh:28,62`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 7 lines | `${BOX_CRONS_STATE_DIR:-$SPL_VAR_APP_DIR}`; external-api-health's dir is `${EXTERNAL_API_DIR:-<the uplink probe's dir>}` through `spl_uplink_probe_dir`, as its `@param` already says, sourcing the orc files as orphan-process-reap does; the backup's `:11` description says `<SPL_VAR_APP_DIR>`. Tests: the 10 of section 3.3 row 03 (`install-box-crons`, `spl-box-state-backup`, `spl-box-state-restore`, `boot-cron-gate`, `box-name-from-cnf`, `cron-no-stack`, `reliability-checks-cron`, `spl-box-deploy`, `utl:tests/external-api-health.tst.sh`, `box-crons-desk-reach.py`), `no-literal-paths`, `spl-run-paths`, `run-eager-files`. **Control:** section 1. | either | claude | simple_coding | 2 (after 01 and 02) |
| 04 `refactor(r61-04-orc-spawn-place-token-burn-dir)` | as row 02 | the placer reads the token-burn dir from a literal; round 34 row 04 left this caller | `orc:run/spl-spawn-place.func.sh:206,672`<br>`orc:tests/no-literal-paths.baseline` (1 line) | 1 file, 2 lines | `:672` reads the dir from `spl_token_burn_state_dir` (sourced on first use); no dir -> `return 1` (no progress proof), as an unreadable file does today at `:673`. Tests: the 14 of section 3.3 row 04, `spl-token-burn-collect.tst.sh`, `no-literal-paths`, `spl-run-paths`, `run-eager-files`. **Control:** section 1, plus: a fixture `buckets.tsv` under the derived dir gives the same progress verdict before and after. | either | claude | simple_coding | 3 (after 03) |
| 05 `refactor(r61-05-orc-feature-state-dirs)` | as row 02 | 3 actions default their state or log dir to `/var/<org>/<app>/<sub>` | `orc:run/spl-workspace-docs-purge.func.sh:36,48,135`<br>`orc:run/prune-docker-images-install-cron.func.sh:8,27`<br>`orc:run/setup-reverse-tunnel.func.sh:30,40`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 7 lines | `${PURGE_EXPORT_DIR:-$SPL_VAR_APP_DIR/workspace-docs-purge/...}`, `${PRUNE_CRON_LOG_DIR:-$SPL_VAR_APP_DIR/docker-prune}`, `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`; the comments `:8` and `:135` name the derived dir. The cron line prune-docker installs keeps its path as installed today (the lane prints the crontab line before and after). Tests: the 3 of section 3.3 row 05, `no-literal-paths`, `spl-run-paths`, `run-eager-files`; `iac:tests/action-header-tags.tst.sh`. **Control:** section 1. | either | claude | simple_coding | 4 (after 04) |
| 06 `refactor(r61-06-orc-key-path-examples)` | as row 02 | two `@example` lines carry a key file path; a comment names the box mount layout | `orc:run/spl-desk-up.func.sh:66`<br>`orc:run/spl-m3-e2e.func.sh:85`<br>`orc:run/spl-desk-install-service.func.sh:327,329`<br>`orc:tests/no-literal-paths.baseline` (3 lines) | 3 files, 4 lines | As round 34 row 06: `ROOT_KEY_JSON=<root key file>`, no path; the comment says `<var>/<org>` for `/var/csi`. Comment and example lines only; `git diff` shows no executable line. Tests: R2's name match gives 60 files (section 3.3), matched on the names only: the lane runs `iac:tests/action-header-tags.tst.sh`, `no-literal-paths.tst.sh`, `m3-e2e-none.tst.sh`, `desk-install-service-envs.tst.sh`, `desk-install-service-user.tst.sh`, `boot-cron-gate.tst.sh`, and every test holding a 30-character string of the changed lines (R2 bullet 2; the lane greps and names them); the other name matches are `NOT RUN` with that reason (C4). **Control:** the ratchet (section 1). | either | claude | simple_coding | 5 (after 05) |

### 3.1 Lanes and batches

- **Batch 1: rows 01 and 02, no file in two rows.** Row 01 owns
  `spl-uplink-probe.func.sh`; row 02 three login-check callers and
  `no-literal-paths.baseline`. No row edits a migration, `csi-spl-cnf/`, a workflow,
  terraform or a file under `csi-spl-wui/`.
- **Batches 2-5: rows 03, 04, 05, 06 in that order**, each after the one before it
  lands: each edits `no-literal-paths.baseline` (R1); each placed within 30 minutes
  of its prerequisite (R16). Row 03 also calls `spl_uplink_probe_dir`, so it waits for
  row 01 too.
- Rows 02-06 share no file but the baseline.

### 3.2 Off every live lane, every queued row and every unlanded row (R3)

- **Unlanded round rows** (on `f284b4148`): round 34 has every row on trunk (the "why
  now"); `--grep='\(r61-'` -> 0. Bug rounds 13-15 landed every row
  (`git log f284b4148 --oneline -E --grep='\(b1[345]-[0-9]{2}'`); b13-01, b14-02 and
  b15-01 changed `spl-lane-rotate.func.sh` (row 02's file) since v0.1, at other hunks
  (`git diff f62d610cb f284b4148 -- <it> | grep '^@@'` -> 6 hunks, lines 171-604); its
  `:112` literal is unchanged, so row 02 stays. Perf round 16: `p16-01` landed
  (`48b44328b`), `p16-02` (c-381@sat, `spl-spawn-share.func.sh` and its test, plan
  row 02) is live: its brief says `spl-spawn-place.func.sh` is NOT its file ("parked
  refactor round 35 row 04 owns it"), and its worktree diff holds no row path.
- **The written paths: 15 distinct** (v0.1 said 16; the sum is 15): row 01 1, row 02 3, row 03 3, row 04 1, row 05
  3, row 06 3, and `no-literal-paths.baseline` (rows 02-06, serialised in 3.1). Each
  present on `f284b4148`, each literal at the line named in section 3
  (the literal grep per file); since `f62d610cb` only `spl-lane-rotate.func.sh` of
  them changed (`git diff --stat f62d610cb f284b4148 -- <the 15>`).
- **Lane map from sat: NOT proven free.** `lane-map.sh --check <the 15 row paths, comma
  separated> --agent c-389` -> **exit 4** at 2026-11-18T08:00:27Z: 0 paths owned;
  13 `unknown:` lanes, all on the other box, with no files recorded: 11 `rotate`
  lanes (`c-060`, `c-390`, `c-468`, `c-528`, `c-545`, `c-570`, `c-596`, `c-643`,
  `c-669`, `c-924`, `c-927`) and two blog drafts (`c-054`, `c-714`). n=1. **Exit 4 is
  not free, and this plan did not clear it**; their briefs are on the other box and
  were not read here. The holder re-runs the check before each row's spawn (R3).
- **Live lanes on sat** (tmux at 08:00:45Z: c-102, c-176, c-197, c-337, c-339, c-371,
  c-379, c-381, c-384, c-762, m-345, besides the desks c-001..c-003): each one's
  `git diff --name-only origin/master...HEAD` plus `git status --porcelain`, matched
  against the row basenames -> **0 hits** each. Seven are `rotate` lanes; c-176 is
  `t1-invitee-label`; c-379 / c-384 are p16-01 (landed) and its reviewer; m-345 the
  bug round 15 panel seat.
- **Spawn queue (2026-11-18T08:00:34Z):** 1 queued, 0 placing, none refactor
  (`hand-<box2>-c002-spl5784-outlook-go-live`, a feature lane); its brief grepped for every written
  basename -> **0 hits**. The briefs under `/var/spool-hub/dispatch/briefs` changed
  since 2026-11-17T22:00Z that name a row basename (08:00:56Z): the b13-01, b14-01,
  b14-02, b15-01..03 rows and reviewers, the r60-06 reviewer, SPL-5829, SPL-5860, the
  round 13-15 and p16 panel seats: each has its landing commit on `f284b4148`
  (`git log --grep` per key or slug); `c002-p16-02-*` names `spl-spawn-place` only to
  keep off it (above).

### 3.3 Tests per row, measured (R2, C4)

Each row lists every test that names a file's bare basename or its `do_*` function
(round 32's section 3.3 command, `NAMES` the row's basenames, on `f284b4148`):

`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.func\.sh)?([^a-z0-9_-]|\$)|\bdo_${n//-/_}\b"; done); git grep -lE "${pat#|}" f284b4148 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' | grep -v baseline`

n=1 each, files (of them not `.sh`/`.py`): row 01 -> 3 (1: `orc-shard-weights.txt`);
row 02 -> **34** (0; mostly `wd-*` and `lane-rotate*`, plus
`test-seed-truth-first.sh` and `utl:tests/orphan-process-reap.tst.sh`); row 03 -> 11
(1: `orc-shard-weights.txt`); row 04 (`spl-spawn-place`) -> 14 (0); row 05 -> 4 (1:
`orc-shard-weights.txt`); row 06 -> 60 (0; `spl-desk-up` is named across the desk
tests). Rows 02-06 add `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh` and
`run-eager-files.tst.sh`. Rows 01-05 run their whole list; row 06 the subset its cell
names, with the reason.

## 4. Per row: what the lane does

- **01:** The uplink probe's description says when it exits 1.
- **02:** The login-check dir is derived in box-quota, lane-rotate and the watchdog; 3 baseline lines go.
- **03:** After 01 and 02: the box crons' state root is derived; 3 lines go.
- **04:** After 03: the placer reads the token-burn dir from its helper; 1 line goes.
- **05:** After 04: the docs-purge, docker-prune and reverse-tunnel dirs are derived; 3 lines go.
- **06:** After 05: two examples lose a key path, one comment loses the mount path; 3 lines go.

## 5. Panel and reviewers (R7)

- Editor: c-389@sat (claude; v0.1 by c-185@sat). Both seats sign the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-18T08:01:19Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`):
  grok `pick=hold` (weekly 99% >= 95% on both boxes); agy `pick=` the other box (47% <
  70%; v0.1 read `nokind`); mistral `pick=sat`; claude `pick=sat`.
- **Panel seat: requested of the holder c-002@sat** (task `dispatch-refactor-r35`):
  one **mistral** doc seat, as round 34's m-206; mistral is allowed docs and reviews
  (owner 10-17, t1 b61851fb msg 91bf8278). If the holder rules it out, an agy seat
  when a box can take it; else the plan waits. The panel seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): an **agy** seat per row on
  the other box while its pick names a box (it did at 08:01:19Z, v0.1 could not).
  When agy cannot be placed, grok holds, so a fresh **claude** seat per row under
  waiver 1a7c70da as re-ruled by c-001 on 2026-11-16 (5fb1bdab; it lapses on the first
  grok pick), as in round 34. Which of the two is the holder's call per row. Not a mistral code R7. The holder re-reads the grok pick
  before each row's reviewer is queued. A claude reviewer is a fresh session, never the
  author; its line says same-vendor under the waiver in `read:`; 2.7.5 still fails an
  equal pair and the retro names it.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-reflection-gather.func.sh` (2 lines) | open SPL-5825 follow-ups on the file | section 2 |
| `spl-cmd-guard-mode`, `fleet-logrotate-install` (6 lines) | need an org var dir export from `spl_run_paths` first: input for round 36, as one row | section 2 |
| `spl-file-erase` (2 lines) | a protected-root deny list; after that export, with a refusal on no tree | section 2 |
| bug and test items of the candidates file (r34 row 01 N1/N2, b12-02, SPL-5824, SPL-5825) | not refactor-shaped: a bug or test round | section 2 |
| round 34's section 6 rest (`send` `WIDE`, `wideFuncs` pairs, `[missing]` headers, `internal/blob`, payments functions, shellcheck) | as round 34 | round 34 section 6 |

## 7. Counts

| metric | n |
|---|---|
| rows | 6 (refactor 6; Bash 6) |
| vendor | claude 6 |
| kind | simple_coding 6 |
| batches | batch 1: rows 01-02; batches 2-5: rows 03, 04, 05, 06 (the baseline) |
| `no-literal-paths` baseline | 17 files / 34 lines -> 3 / 8 (rows 02-06) |
| measured on | `f284b4148`, n=1 per command unless stated (v0.1: `f62d610cb`) |

## 8. Changes

- v0.1 (c-185@sat): first draft: 6 rows, slug `r61`, measured on `f62d610cb`.
  Carries round 34's section 6 (the 17 `no-literal-paths` files) and the
  refactor-shaped leftovers of `c002-next-round-candidates.md` (r34 row 05 N3,
  SPL-5828 N1); its bug and test items are left for a bug round. After v1.0 lands,
  the plan is imported as a Qto `system` doc (`do_spl_doctree_import_md`,
  `QTO_FS=repo`, TENANT_ID=t1), as round 33 was (`e49e68a8c`, SPL-5449).
- v0.2 (c-389@sat, after c-001@sat unheld the round in a445be64): rebuilt on
  `27e21eefc`, every count re-measured on `f284b4148`. **No row dropped, none
  changed**: every literal is at the line v0.1 named (the literal grep per file), the
  baseline still reads 17 files / 34 lines, the three helpers sit at the lines named
  (`spl-claude-login.func.sh:23`, `spl-token-burn-collect.func.sh:37`,
  `spl-uplink-probe.func.sh:73`), and the test counts of 3.3 are unchanged (3, 34, 11,
  14, 4, 60). The only row file that moved, `spl-lane-rotate.func.sh` (b13-01, b14-02,
  b15-01), moved at other hunks (3.2). Refreshed: the why-now (4.4 now `floor-met`),
  the slug proof, the R3 readings, the vendor state (agy places again, so the row
  reviewers are agy first), and the reflection-gather and `send` left-out reasons.
- v1.0 (c-389@sat): the panel seat m-392@sat (mistral) passed v0.2
  `a73b73d47`, W none, N1-N4 notes only. Status line and sections 8-9 only; the
  4.4 line re-run on `0905076cc` -> `floor-met` (21.7%).

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-185@sat (claude): drafted v0.1; c-389@sat (claude): v0.2.
- Panel reviewer seat: **m-392@sat (mistral) PASS** on `a73b73d4701c02bec5bed621589d1f689ab1c389`
  (spool msg 0691925a, task `dispatch-refactor-r35`); seat file
  `csi-spl-doc/doc/md/refactor-round-35/seat-mistral.md` on branch
  `review/c002-refactor-round-35-mistral-seat` (`2ed6e4d9b`). W: none. N1 (the queue
  moved after the 08:00:34Z read: 0 queued), N2 (lane map exit 4 reproduced, the holder
  re-checks per row), N3 (row 01 is comment-only by design), N4 (its STEP 0): notes, no
  change to the plan.
- Row R7 seats: section 5.
