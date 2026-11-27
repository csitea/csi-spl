# Refactor round 11 (2026-11-27) - panel seat claude (c-862)

Issue: SPL-6676
Seat: c-862, claude, cross-vendor panel seat (rulebook 3.2), placement
`c002-refactor-round-11-claude-panel-seat`.
Reviewed: `csi-spl-doc/doc/md/refactor-round-11-20261127-plan.md` v0.1 on
`review/c002-refactor-round-11-planner` at
`937716f6cc0d5706980b8d2c0bd24308c50feefe` (`git ls-remote` at 12:12Z; the sha
the holder c-002 named in msg 46aa73fd). Plan file sha256
`b6ede2a00705f8300b0a0ea5cdad6aaa5927effe29b83fe793d833b84efb07f5`.
Base of the plan: `992866d6988a4518ea1df92e9797b3ab4e4d21c9`.

## Verdict v0.1: PASS on 937716f6

Both rows are one logical refactor with no behaviour change. Each red control
fails for the reason the plan gives, and goes green on its head. The fix of W1
(text only) goes into v1.0. No row code or test changes.

All runs 2026-11-27 12:13Z-12:20Z, n=1 each, as the agent user on this box, in
scratch copies (`git archive 992866d69`) under this session's scratchpad;
`SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, stdin `/dev/null`.
Pass/fail counts are `grep -ciE '^ *(ok|pass)'` / `grep -ciE '^ *(not ok|fail)'`.

## Checks

### 1. Slug r11 unused since W

- `git log origin/master --since="2026-11-27T09:21:57+02:00" --oneline -E --grep='\(r11-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r11-[0-9]{2}|refactor-round-11-2026'` -> 3 lines:
  `1da4da9b3… refs/heads/review/r11-03`, `512b48e5d… refs/heads/review/r11-06`,
  `8fdbf312f… refs/heads/review/r11-09`. Tips (`git log -1 --format=%cI`):
  `2026-10-15T08:35:59+03:00`, `2026-10-15T11:06:05+03:00`,
  `2026-10-15T12:38:53+03:00`; unlanded (`git rev-list --count origin/master..<sha>`)
  2, 2, 1. All three are before W and the plan lists all 3 with sha and tip
  date (plan lines 104-112). Nothing else. The planner's branch
  `review/c002-refactor-round-11-planner` does not match this pattern, so the
  grep does not list it (`git ls-remote origin refs/heads/review/c002-refactor-round-11-planner`
  -> `937716f6…`). My seat branch did not exist yet.
- W itself: `git log -1 --format='%H %cI' 6f9fef225` ->
  `6f9fef225dbf51e40a392c90248b7da1fdb0f0ae 2026-11-27T09:21:57+02:00`, as plan
  line 92 says.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r11-[0-9]{2}|refactor-round-11-2026'`
  on this box -> 12 old-cycle files (`c001-r11-01..07`, `-09`, `-10`,
  `c001-r11-03-claude-{review,takeover}`, `c002-r11-08`), all dated
  2026-10-15 (`ls -l`). Neither this cycle's planner brief nor mine is in that
  dir on this box: mine is `/var/spool-hub/spawn-remote/briefs/1a87bcb4-….md`.
  See N5.
- Dated paths (ruling e79facef (iii)):
  `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-11`
  -> `refactor-round-11-plan.md`, `refactor-round-11-retro.md`,
  `refactor-round-11`. The dated names are therefore required.

### 2. Sites exist on base and on origin/master

- Line counts on `992866d69` (`git show <base>:<f> | wc -l`): spl-cmd-guard-mode.func.sh 88,
  install-force-push-guard.func.sh 46, spl-cmd-guard-mode.tst.sh 140,
  clock-sync-check.func.sh 226, tmux-health-guard.func.sh 175,
  docker-test-container-prune.func.sh 292, clock-sync-check.tst.sh 245. These are
  equal to the plan's "before" counts.
- I read every cited range on base with `git show 992866d69:<f> | cat -n`:
  `_scg_homes` 50-64, `do_spl_cmd_guard_mode` 66-88, the fpg loop 29-42,
  `clock_sync_alert` 182-217 (block 203-216), `tmux_health_alert` 131-166
  (block 152-165), `_dtcp_note` 126-160 (block 146-159). Each holds what the
  plan says.
- Drift: `git diff --name-only 992866d69 origin/master -- <the 7 row files>`
  -> empty, at origin/master `0339bf84c` (12:13Z), and again at `6a8a09e75`
  (about 12:19Z, `| wc -l` -> `0`).

### 3. Red controls

I rebuilt head1 and head2 from the plan's 9 verbatim `bash` blocks (replace
and insert at the plan's line numbers). Their sha256 values are equal to the plan
(12 hex), and so are their line counts:

| file | sha256 | lines |
|---|---|---|
| spl-cmd-guard-mode.func.sh | `a9b4c1881cc4` | 111 |
| install-force-push-guard.func.sh | `85ed017452ab` | 43 |
| spl-cmd-guard-mode.tst.sh | `c391193b75af` | 238 |
| clock-sync-check.func.sh | `aa38ac185018` | 238 |
| tmux-health-guard.func.sh | `6ddbd1d88885` | 164 |
| docker-test-container-prune.func.sh | `412690972f4b` | 281 |
| clock-sync-check.tst.sh | `bf1247df51ca` | 346 |

The red control files, full sha256:
- rc1 `spl-cmd-guard-mode.tst.sh` `c391193b75af3726982c9adbe2de69ca5ef224c7726694a6e43014999a8aa01b`
- rc2 `clock-sync-check.tst.sh` `bf1247df51ca4e55c3bf328362ebee54163462c32cac6a765788fd732912af75`

| run | rc | pass | fail | last line |
|---|---|---|---|---|
| base `spl-cmd-guard-mode.tst.sh` | 0 | 16 | 0 | `spl-cmd-guard-mode: 16/16 passed` |
| rc1 (head1 test on base) | 1 | 19 | 9 | `spl-cmd-guard-mode: 19/28 passed` |
| head1 | 0 | 28 | 0 | `spl-cmd-guard-mode: 28/28 passed` |
| base `clock-sync-check.tst.sh` | 0 | 16 | 0 | `==========================================` |
| rc2 (head2 test on base) | 1 | 20 | 7 | `==========================================` |
| head2 | 0 | 27 | 0 | `==========================================` |

Why each fails (the `FAIL` lines): rc1 has 7 checks with rc 127
`_spl_box_users_resolve` / `_spl_box_user_home` / `_spl_box_user_exec: command not found`,
plus `FAIL: 8: host` and `FAIL: 8: fpg own=[31:    SPOOL_ENV_NO_BINS=1 spool_env_resolve …`.
rc2 has 4 checks with rc 127 `_utl_send_throttled_alert: command not found`, plus `FAIL: 17. host check`,
`FAIL: 17. tmux-health-guard.func.sh own=[154: send=(bash …spool-send.sh")` and
`FAIL: 17. docker-test-container-prune.func.sh own=[148: …`. These are the
reasons the plan gives (1.5), not environment reasons. Base line 31 of
install-force-push-guard and line 154/148 of the two utl files hold exactly
those texts (`git show 992866d69:<f> | sed -n <N>p`).

Live state: the controls use `$T` temp dirs, stub `getent` and stub senders, and
run under `SPOOL_TEST=1`. After the runs, a `find` over both users'
`.local/state` for `*clock-sync*`, `*tmux-health*` and
`*docker-test-container-prune*` found no clock-sync, tmux-health or
docker-prune stamp (only an unrelated `rel-clock-sync.lock`). No `DRY_RUN=0`
path runs a real sender: every send goes to a stub or to a missing
`$T/no-such-tree`. I did not prove that nothing touched the live spool root. I
rely on the `SPOOL_TEST=1` guard for that.

### 4. Equivalence

Row 01, which I read against base 50-88 and 29-42:
- `_spl_box_users_resolve` sets the caller's `local users` and
  `_spl_box_user_home` sets the caller's `local h`, both through bash dynamic
  scope. Both callers declare them (`_scg_homes` `local u h="" users=()`, fpg
  line 21 `local … u h rc=0 users=() fn`, unchanged).
- Empty user: base fpg `FATAL …; return 1`. Head: hrc=1 -> `(( hrc == 0 )) || return "$hrc"`
  -> return 1, same text. Missing home in fail mode: `FAIL no home for $u`, rc=1, continue, the
  same. `_scg_homes`: FATAL and return 1 in both empty and missing cases, the same.
- `_spl_box_user_exec`: the same `id -un` test, the same `sudo -n -u "$u" -H`, and the
  exit code reaches `|| rc=$?` unchanged.
- spool-env.inc.sh is sourced only on the non-override branch, as on base.
- Side effect of the lazy source: `spl-cmd-guard-mode.func.sh` has no
  top-level statements (lines 1-27 are comments, then function definitions), so it
  only defines functions (N2).

Row 02, which I read against base 182-217, 131-166 and 126-160:
- The sender array parse, the `${PROJ_PATH:-.}` sibling, `[[ -f ]]`,
  `timeout -k 2 "$send_tmo"` (dtcp `20`), the flags and `--no-poke`, the stamp
  payloads (`"$state $now"`, `"$sig $now"`) and return 0 are all the same.
  The messages are the same per kind: missing `alert not sent` (csc, thg) /
  `note not sent` (dtcp); `the next run alerts again` / `sends again`;
  `INFO <label> note sent to $to`; `WARN <label>: the note to $to failed`. Each
  label matches base.
- dtcp keeps its order (dry check before the stamp read), and so do csc and thg
  (throttle, then dry, then send).
- The top-level code of `clock-sync-check.func.sh` is line 52
  `type do_log &>/dev/null || do_log() …`, line 55 the `spl_box_name` guard and
  lines 224-226 the `_func_to_file` registration. When it is sourced from
  thg/dtcp, the first two are no-ops and the third only re-registers a mapping (N2).
- One difference, only on a broken tree: `|| return 0` after a failed lazy
  source (plan lines 585 and 613) returns silently, where base would still
  send (N3).

Would the controls catch a difference? Yes. I ran 2 of the plan's 6 mutations
myself, on fresh copies of the heads:
- m1a (fpg passes `fatal`; the `diff` shows line 34 changed): rc 1, 27 pass, 1 fail,
  `FAIL: 8: fpg missing (1: FATAL no home for r11_nohome)`.
- m2b (dtcp passes `alert`): rc 1, 26 pass, 1 fail,
  `FAIL: 17. standalone dtcp miss`.

Both are equal to plan 1.5. I did not run m1b, m1c, m2a or m2c.

Suites on base and the heads ("=" means the same rc, pass and fail as base):

| suite | base | head |
|---|---|---|
| orc `features/spool-install/tests/test-y13-force-push-guard.sh` | 0/22/0 | head1 = |
| orc `func-name-unique.tst.sh` | 0/2/0 | head1 =, head2 = |
| iac `bash-cleancode.tst.sh` | 0/15/0 | head1 =, head2 = |
| iac `run-lazy-loader.tst.sh` | 0/30/0 | head1 = |
| orc `run-eager-files.tst.sh` | 0/14/0 | head1 = |
| utl `tmux-health-guard.tst.sh` | 0/17/0 | head2 = |
| utl `docker-test-container-prune.tst.sh` | 0/25/0 | head2 = |
| utl `print-help.tst.sh` | 0/4/0 | head2 = |
| orc `reliability-checks-cron.tst.sh` | 0/9/0 | head2 = |
| orc `box-name-from-cnf.tst.sh` | 0/14/0 | head2 = |

`shellcheck 0.10.0 -S warning -x` on the 3 head1 files gives rc 0, and on the 4 head2 files rc 0.
`python3 -I csi-spl-iac/src/bash/scripts/tmp-path-lint.py` on each head's test
file gives rc 0 (the `/tmp/sock17` in section 17 is a socket label that no
code writes). Not run by me: `no-literal-paths`, `no-box-path-source`,
`action-header-tags`, `param-required`, `gcloud-account-pinned`,
`do_sec_shellcheck`, `do_check_pre_push`. The row lanes run those.

### 5. Row form (R1, R2, vendor, kind, batch)

- Section 2, plan lines 834-835: each row has a red control that fails today
  and passes after (shown in 3 above), a test list, vendor `claude`, kind
  `simple_coding` and batch `1`. There is no mistral row. R7 is an agy seat (cross-vendor),
  with the claude waiver backup only under ruling `dc84300a`. Never mistral
  (lines 996-998, 1019-1021).
- R1: row 01 touches only `csi-spl-orc/` and row 02 only `csi-spl-utl/`, so they share no file.
- Rulebook 5.1: 2 rows. Rulebook 3.1: 3 and 4 files (5 at most).

### 6. R3 lane map

`lane-map.sh --check <the 7 row paths> --agent c-862` at 12:17:44Z gives exit 4:
`WARN no live lane lists <paths>, but 4 live lane(s) record no files`.
Those 4 are `a-629@sat` (the planner itself), `c-309@sat` (s181 B14 month-end
invoice issuer), `c-312@sat` (11d7836d issues select like topics) and
`c-635@sat` (codex pin 0172). Their briefs' names name no row path. The
planner names r10-02 (c-799) as the only live code lane near these files, and
its files (`reboot-required-check.func.sh`, `cron-heartbeat-snitch.func.sh`,
`reboot-required-check.tst.sh`; `git show --stat 054294929`) are none of the
row files. No live lane touches a row file.

### 7. Inputs accounted for

- r10 section 7 (origin/master `refactor-round-10-20261127-plan.md`):
  - Row 1, the 6 `*_SEND_CMD` senders. 2 are served by row 02 (csc, thg), plus dtcp.
    The other 4 are listed in r11 section 7 with reasons I re-checked:
    - `shellcheck -S warning -x orphan-process-reap.func.sh` gives rc 1 with
      `SC2071 (error)` at line 208 (`if [[ "$r_ts" > "${retired_agents[$r_id]:-}" ]]; then`).
    - `gh-runner-health.func.sh:45,116` name `gh-box-token.func.sh`.
    - `net-cert-expiry-check.func.sh:184-196` has no `timeout` or `--no-poke`
      (grep exit 1).
    - `box-beat-telemetry.func.sh` does `rm -f "$pending"`.
  - Row 3, the fpg/`_scg_homes` user and home resolution: served by row 01.
  - Every other r10 left-out row appears again in r11 section 7.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: NOT RUN. The file
  does not exist on this box (`wc` -> `No such file or directory`), and an ssh
  read on the planner's box as the push user gives `Permission denied`. I
  cannot check the plan's candidates-file accounting (plan line 1044) (N4).
- Behaviour: neither row changes an exit code, a message, a path or a default
  (4 above), so both are refactor rows, not bug rows.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` (worktree at `0339bf84c`) prints
`INFO distribution-hygiene: clean over the tracked tree`, rc 0. It runs again
on the commit that adds this file, before the push.

## Defects

- **W1** (plan lines 35-37, 181-182 and 899-902): r10-02's state is stale, and
  its new helper is not accounted for. The plan says r10-02 "has not yet landed"
  and that "r11 rows still wait for `r10-02`". But
  `054294929 refactor(r10-02-utl-spool-note-send, SPL-6672): one copy of the spool note sender`
  is on origin/master (committed 11:22:35Z), and `c696a294d` (11:42:44Z, before
  the plan commit at 11:44:28Z) closes round 10. r10-02 created
  `_utl_send_spool_note` in `csi-spl-utl/src/bash/run/reboot-required-check.func.sh:85`
  (origin/master). Row 02 adds a second utl note-send helper,
  `_utl_send_throttled_alert`, in another host file. v1.0 should do two things.
  First, state r10-02 as landed, with its sha, and say whether its serve gate (5.2) is met. Second,
  in 1.2 (a) or section 7, say in one line why row 02 does not reuse or extend
  `_utl_send_spool_note`. From my read the semantics differ: `*_SEND_BIN`
  override plus `PATH` fallback, no `timeout`, no `--no-poke`, return 1 on
  failure, versus `*_SEND_CMD` array, timeout, `--no-poke`, stamp write and
  return 0. If that is the reason, it holds; then name the two families so r12
  does not count them as one. This is a text fix. It changes no row.

## Notes

- **N1** W stays `6f9fef225` (rulebook 5.3: read once, at the start). A newer
  `docs(r10-plan…)` commit, `c696a294d`, now exists. It does not change W for this round.
- **N2** The lazy sources define extra functions in the caller's shell
  (`do_spl_cmd_guard_mode` and `_scg_*` in the fpg run; `do_os_clock_sync_check`
  and `clock_sync_*` in the thg and dtcp runs). That is harmless:
  `func-name-unique.tst.sh` is 0/2/0 on both heads, and neither host file has
  top-level side effects beyond the guards above.
- **N3** Plan lines 585 and 613: `source … || return 0` is silent. If
  `clock-sync-check.func.sh` is unreadable, base would still send, while the head
  logs nothing and sends nothing. This can only happen on a broken tree, so it
  is not a behaviour change on a whole tree. The row lane may keep it as written. A `WARN` there
  would add a message, so leave it out of a refactor row.
- **N4** I could not read the candidates file (7 above). The plan's line
  numbers into it (lines 25-173) are unverified by this seat.
- **N5** Plan lines 133-139 say the old-cycle briefs on the planner's box are
  "dated 2026-11-18". On this box the same names are dated 2026-10-15, the
  same day as the 3 old heads' tips. I cannot read the planner box's dir, so
  this is unverified, not a defect.
- **N6** The `sudo -n -u` branch of `_spl_box_user_exec` stays untested
  hermetically, as on base (plan line 445). This is accepted.
- **N7** Row 02's `parts=all` CI cost (`ci-doc-only.sh:124`) is named and
  accepted in the plan (lines 473-477). I did not re-measure it.

## v1.0: PASS on f2b9c27e

Plan v1.0 `f2b9c27ef85a91a40fa6fa44178bc67ebc475141` on
`review/c002-refactor-round-11-planner` (`git ls-remote` returned this sha at the
time of the check). Its parent is `937716f6cc0d5706980b8d2c0bd24308c50feefe`
(v0.1, signed above). Author and committer are both the repo CLAUDE.md "Commits:" address
(`git log -1 --no-mailmap`).

- `git diff --stat 937716f6c f2b9c27ef` -> 1 file,
  `refactor-round-11-20261127-plan.md`, +79 -21.
- No row changed:
  - All 9 fenced `bash` blocks were extracted from both versions and compared:
    `blocks 9 9 identical`. head1 and head2, the red controls and the mutations
    of the checks above therefore hold for v1.0 unchanged.
  - The row table: `diff` of the `^| 0[12] ` lines of both versions is
    empty (2 rows).
  - Section 5, the row briefs: `diff` of `## 5.`..`## 6.` of both versions is
    empty.
- W1 is resolved:
  - The intro, 1.2 (b) and 2.2 now state that r10-02 landed (`054294929`) and
    that r10 was closed by `c696a294d`, with the 5.2 serve gate met. The
    "has not yet landed" text and "r11 rows still wait" are gone (they are `-`
    lines of the diff).
  - 1.2 (a), 1.4 and section 7 name Family A `_utl_send_spool_note`
    (`reboot-required-check.func.sh:85`) and Family B
    `_utl_send_throttled_alert`, and say why row 02 does not reuse A.
  - I checked the Family A description against origin/master
    `reboot-required-check.func.sh:80-105`. It reads "override > PROJ_PATH
    sibling > PATH", runs no `timeout`, has no `--no-poke` and writes no stamp,
    and it does `return 1` on a missing or failed sender. That is what v1.0 says.
- N1-N7 are recorded in 1.4, 2.2, 4.1, 8 and 9. N5's "2026-11-18 mtimes on the
  planner box" is the planner's statement. This seat cannot read that box and
  still has not verified it.

No new defects.

## Sign-off

| plan sha | verdict | seat |
|---|---|---|
| `937716f6cc0d5706980b8d2c0bd24308c50feefe` (v0.1) | PASS, W1 to fold in v1.0 | c-862 claude |
| `f2b9c27ef85a91a40fa6fa44178bc67ebc475141` (v1.0) | PASS, W1 resolved, no row changed | c-862 claude |
