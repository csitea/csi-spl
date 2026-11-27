# Refactoring round 11 (2026-11-27) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6676  
Topic: bec70bed-c8ad-4001-b077-e2c7c8e8e1df  
Discussion: bec70bed-c8ad-4001-b077-e2c7c8e8e1df (t1 #refactoring, "Refactor round 11", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3). Because the older
  cycle already created `refactor-round-11-plan.md`, `refactor-round-11-retro.md`, and
  `refactor-round-11/` on `origin/master`, this round carries its open date per rulebook
  5.3 and orchestrator ruling `e79facef` (option B, same pattern requested for r11): plan
  `refactor-round-11-20261127-plan.md`, retro `refactor-round-11-20261127-retro.md`,
  seat dir `refactor-round-11-20261127/`, Qto doc title the same, rows `r11-<NN>`,
  commit scope `docs(r11-plan, SPL-6676)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
  `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 11:18:22Z reported
  `main=claude`, `backup=agy`, `pick=claude` (`claude` 4/16 = 25% vs 44% effective
  weight; `agy` 11/16 = 69% vs 56% effective weight; `grok` and `qwen` off in instance
  settings, `paused none`, `codex` no CLI). Per R14 and the brief (cross-vendor `agy` R7
  for `claude` code rows), both rows are assigned **vendor claude** with **agy R7**
  (claude waiver backup only while agy is out of quota or paused, under ruling
  `dc84300a`; never mistral; re-checked at placement).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 10 ([refactor-round-10-20261127-plan.md](refactor-round-10-20261127-plan.md),
editor `a-546`) is closed (`c696a294d`, SPL-6649): both rows landed on `origin/master`
with cross-vendor agy R7 PASS (`r10-01` `35467af49`, SPL-6660, agy R7 `a-589` PASS;
`r10-02` `054294929`, SPL-6672, agy R7 `a-628` PASS; both Bash-only, verified ancestors
of `origin/master` and the box checkout, no hub or WUI deploy required). The rulebook 5.2
serve gate is met, so r10 does not hold r11 rows once the plan is signed and landed. The
perf floor (rulebook 4.4), re-measured on `992866d69` at 2026-11-27T11:18:15Z (14 days):
`perf 37 refactor 112 perf-share 24.8% floor-met` (5 x 37 = 185 >= 149), so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), non-secret, zero-PG, with
zero behaviour change:
- **Row 01 (`_spl_box_users_resolve`, `_spl_box_user_home`, and `_spl_box_user_exec` — 3 files):**
  `orc:src/bash/run/spl-cmd-guard-mode.func.sh:50-88` extracts `_spl_box_users_resolve`
  (shared `spool-env.inc.sh` source, `spool_env_resolve`, deduplicated agent+box users
  list), `_spl_box_user_home` (empty-user `FATAL` rc 1, `getent passwd` home lookup, and
  `fatal` rc 1 vs `fail` rc 2 missing-home handling), and `_spl_box_user_exec` (direct vs
  `sudo -n -u "$u" -H` execution), delegating `_scg_homes` and `do_spl_cmd_guard_mode` to
  them; `orc:src/bash/run/install-force-push-guard.func.sh:29-42` lazy-loads
  `spl-cmd-guard-mode.func.sh` and delegates its user/home resolution and execution to
  those three helpers while preserving `FAIL no home for $u; rc=1; continue` (closes r10
  section 7 #3), guarded by section `8` in `orc:src/bash/tests/spl-cmd-guard-mode.tst.sh`.
- **Row 02 (`_utl_send_throttled_alert` throttled `*_SEND_CMD` alert sender — 4 files):**
  `utl:src/bash/run/clock-sync-check.func.sh:182-217` extracts `_utl_send_throttled_alert`
  (shared `*_SEND_CMD` array parse, `PROJ_PATH` sibling `spool-send.sh` fallback, missing
  sender `WARN`, `timeout -k 2 "$send_tmo"` `--no-poke` note send, stamp write on delivery
  only, `INFO` sent / `WARN` failed logs, and `alert` vs `note` wording switch) and
  delegates `clock_sync_alert` to it; `utl:src/bash/run/tmux-health-guard.func.sh:131-166`
  and `utl:src/bash/run/docker-test-container-prune.func.sh:126-160` lazy-load
  `clock-sync-check.func.sh` inside their `DRY_RUN=0` send path (zero load cost on
  `DRY_RUN=1` or OK probes) and delegate to `_utl_send_throttled_alert` (wave 1 of r10
  section 7 #1's `*_SEND_CMD` consolidation: 3 shellcheck-clean non-secret actions),
  guarded by section `17` in `utl:src/bash/tests/clock-sync-check.tst.sh`.

The two rows touch different sub-projects (`csi-spl-orc/` vs `csi-spl-utl/`) and share no
file: both are **Batch 1**.

**Status: v1.0 for panel sign-off (folds panel W1 and notes N1-N7; text-only, zero row changes).**
Editor: **a-629** (agy). Cross-vendor claude panel seat **c-862**
(`c002-refactor-round-11-claude-panel-seat`) signed v0.1
`937716f6cc0d5706980b8d2c0bd24308c50feefe` (**PASS**, W1 text-only to fold in v1.0; seat
commit `eedf5e7fe5ad952a4a8d7d827f3a3a9bf3eb13ea` on
`review/c002-refactor-round-11-claude-seat`, msg `6e490bd7` / holder `3525cddb`, relay
`281ecf9c`; `REVIEW_LINE_SYNTAX=1` rc 0 on planner box; all 9 fenced `bash` blocks
byte-identical to v0.1 `937716f6`; zero drift on all 10 checked paths from `992866d69` to
`origin/master` `677e80255`). Awaiting `c-862` sign-off on v1.0 and holder
`do_spl_review_line_check` rc 0 confirmation before landing to `master`.

**One sha:** every count is measured on **`992866d69`**
(`992866d6988a4518ea1df92e9797b3ab4e4d21c9`, `origin/master` at 2026-11-27T11:18:15Z),
n=1 per command unless stated. Reads are on `992866d69` with `git show` / `git grep`. The
tests of 1.5 ran in scratch clones checked out at `992866d69` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a fresh scratch clone of its own. All helper, caller, and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 6 mutation checks byte-for-byte on `992866d69` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window, slug proof, and ruling `e79facef` conditions (rulebook 5.3)

2026-11-27T11:18:15Z-11:18:21Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-27T09:21:57+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r10-plan'`:
  `6f9fef225dbf51e40a392c90248b7da1fdb0f0ae`
  (`docs(r10-plan, SPL-6649): refactor round 10 plan v1.1 (fold panel W4; signed by c-420 PASS on 1549aaf35)`),
  read once at the start as 5.3 says. All later R4, R6, 2.7.5, and `PRUNE_SINCE` reads
  for r11 use `W=2026-11-27T09:21:57+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'` ->
  `perf 37 refactor 112 perf-share 24.8% floor-met` (5 x 37 = 185 >= 149).
- **Slug proof since `W`:**
  `git log origin/master --since="2026-11-27T09:21:57+02:00" --oneline -E --grep='\(r11-' | wc -l` -> **0**.
- **Ruling `e79facef` (option B) condition (i) — known before-window old-cycle heads:**
  `git ls-remote origin 'refs/heads/review/r11-*' 'refs/heads/wip/*r11*' 'refs/heads/*-r11-*' 'refs/heads/*refactor-round-11*'`
  returns exactly **3** old-cycle heads (all holding unlanded commits, all tips older than
  `W=2026-11-27T09:21:57+02:00`, never deleted):
  1. `refs/heads/review/r11-03` — `1da4da9b36ad5ccd4cfd895cf8391cec1f3045e6`, tip
     `2026-10-15T08:35:59+03:00`, 2 unlanded commits
     (`test(r11-03-no-box-path-source, SPL-1928): add gate for fixed box paths in source/./include lines`)
  2. `refs/heads/review/r11-06` — `512b48e5d04a51dfd9fa9fd214fab253d493db23`, tip
     `2026-10-15T11:06:05+03:00`, 2 unlanded commits
     (`ci(r11-06-review-line-log-check, SPL-1964): read a compacted vibe session store`)
  3. `refs/heads/review/r11-09` — `8fdbf312fe578015fc9056a1be78fbba94906271`, tip
     `2026-10-15T12:38:53+03:00`, 1 unlanded commit
     (`refactor(r11-09-bash-small-tf-init, SPL-1972): split do_tf_init into named steps under 80 lines`)
  Zero other `r11` or `refactor-round-11` heads exist on `origin` (before this plan's
  review branch push).
- **Ruling `e79facef` (option B) condition (ii) — pre-prune DRY check:**
  `cd csi-spl-orc && ROUND=11 PRUNE_SINCE="2026-11-27T09:21:57+02:00" DRY_RUN=1 ./run -a do_git_prune_round_branches`
  (run at 11:18:18Z, n=1) printed:
  - `WINDOW r11 W=2026-11-27T09:21:57+02:00`
  - `KEEP review/r11-03 before-window 2026-11-27T09:21:57+02:00`
  - `KEEP review/r11-06 before-window 2026-11-27T09:21:57+02:00`
  - `KEEP review/r11-09 before-window 2026-11-27T09:21:57+02:00`
  - `DRY_RUN round r11: 0 branch(es) listed, 0 kept unlanded, 3 before the window on origin, nothing deleted (DRY_RUN=0 deletes the listed)`
  All 3 old-cycle heads read `KEEP <branch> before-window 2026-11-27T09:21:57+02:00`. R8
  re-runs this exact DRY check before `DRY_RUN=0` and stops to tell the holder if any of
  the 3 does not read `KEEP <branch> before-window <W>`.
- **Ruling `e79facef` (option B) condition (iii) — existing `refactor-round-11` files:**
  `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-11`
  returns **3** old-cycle entries: `refactor-round-11-plan.md`,
  `refactor-round-11-retro.md`, and `refactor-round-11/`. Therefore this round uses the
  dated paths `refactor-round-11-20261127-plan.md`, `refactor-round-11-20261127-retro.md`,
  and `refactor-round-11-20261127/` (0 existing hits on `origin/master`).
- **Briefs on the planner/holder box:**
  `ls /var/spool-hub/dispatch/briefs | grep -E 'r11-[0-9]{2}|refactor-round-11'` (local to
  the planner/holder box only, run at 11:18:21Z) shows, beyond this planner's brief and
  the panel seat's brief (`c002-refactor-round-11-claude-panel-seat.md`):
  - 13 old-cycle r11 briefs dated 2026-11-18 (`c001-r11-01..07`, `c001-r11-09`,
    `c001-r11-10`, `c002-r11-08`, `c001-r11-03-claude-{review,takeover}`, and
    `c002-refactor-round-11-planner.md`, all before `W`); 0 `r11-NN` row briefs for this
    cycle.

### 1.2 The brief's inputs, re-measured

- **(a) r10 section 7 (`refactor-round-10-20261127-plan.md`):** re-read on `992866d69`:
  - `orc:src/bash/run/install-force-push-guard.func.sh:29-42` and
    `spl-cmd-guard-mode.func.sh:50-88` (r10 section 7 #3): re-read on `992866d69`. Both
    are non-secret, zero-PG, shellcheck-clean (rc 0), and duplicate the agent+box user
    resolution (`spool-env.inc.sh` + `spool_env_resolve` + deduplicated `users`),
    `getent passwd` home lookup, empty-user `FATAL`, and direct vs `sudo -n -u "$u" -H`
    execution. The subtle missing-home difference (`FAIL no home for $u; rc=1; continue`
    in `install-force-push-guard` vs `FATAL no home for $u; return 1` in `_scg_homes`) is
    preserved explicitly via a `mode` parameter (`fatal` vs `fail`) -> **row 01** (1.3).
  - `utl:src/bash/run/` `*_SEND_CMD` spool note senders (r10 section 7 #1): `git grep -n
    'SEND_CMD' 992866d69 -- csi-spl-utl/src/bash/run/` finds **7** actions (the 6 named in
    r10 section 7 plus `box-beat-telemetry.func.sh:217`). Re-measuring all 7 with
    `shellcheck -S warning -x` and inspecting each for secret access and semantics:
    - `clock-sync-check.func.sh:203-216`, `tmux-health-guard.func.sh:152-165`, and
      `docker-test-container-prune.func.sh:146-159`: all 3 are non-secret, zero-PG,
      shellcheck-clean (rc 0), use `timeout -k 2` + `--no-poke` + stamp-write on delivery,
      and differ only in `send_tmo` (`$send_tmo` vs `20`), labels, and `"alert not sent"`
      / `"alerts again"` vs `"note not sent"` / `"sends again"` -> **row 02** (1.4;
      one-time night-phase `parts=all` CI cost accepted, W2 note below).
    - `orphan-process-reap.func.sh:141-155` carries a pre-existing `shellcheck` error at
      line 208 (`SC2071 (error): > is for string comparisons. Use -gt instead` on ISO
      timestamp string comparison), so touching it would fail `do_sec_shellcheck` without
      mixing in a separate lint fix; left in section 7.
    - `gh-runner-health.func.sh:293-306` sources `gh-box-token.func.sh` (reads GitHub
      token from `$HOME/.github/.csi/crs`, secret-class); excluded per brief rule and
      recorded in section 7.
    - `net-cert-expiry-check.func.sh:184-196` (no `timeout -k 2`, no `--no-poke`) and
      `box-beat-telemetry.func.sh:217-229` (`rm -f "$pending"` instead of stamp write,
      `"note kept in $pending"`) have distinct delivery/post-send semantics; left in
      section 7.
    - **Why row 02 does not reuse `r10-02`'s `_utl_send_spool_note`** (W1, naming the two
      `csi-spl-utl` sender families so `r12` does not count them as one): `r10-02`
      (`054294929`) extracted Family A `_utl_send_spool_note`
      (`reboot-required-check.func.sh:85`), which takes a `*_SEND_BIN` override plus
      `PROJ_PATH` sibling / `PATH` fallback, runs with no `timeout` and no `--no-poke`,
      writes no stamp, and returns `1` on missing/failed sender; row 02 extracts Family B
      `_utl_send_throttled_alert` (`clock-sync-check.func.sh`), which parses a
      `*_SEND_CMD` array (sibling `spool-send.sh` fallback, no `PATH`), runs under
      `timeout -k 2` with `--no-poke`, writes the throttle stamp on delivery only, and
      always returns `0`.
  - Remaining r10 section 7 items (`systemd-unit-health.func.sh` +
    `cloud-sql-backup-verify.func.sh` — where `cloud-sql-backup-verify.func.sh:125` also
    carries pre-existing `SC2155` warning — NM keyfile writers with `sed` test mutations,
    3 `is a linked worktree:` sites, `spl-issue-*`, secret-class/PG-heavy actions) remain
    accounted for in section 7.
- **(b) R7 notes of r10-01 (`a-589` agy), r10-02 (`c-799` / `a-628`), and r10 panel (`c-420`):**
  - `r10-01` (`35467af49`, SPL-6660, R7 `a-589` PASS on `a2b86e645`): commit body carries
    zero refactor follow-up notes.
  - `r10-02` (`054294929`, SPL-6672, `c-799`, agy R7 `a-628` PASS on `28a8dfa24`): landed
    on `origin/master` and round 10 closed (`c696a294d`, SPL-6649); commit body carries
    zero refactor follow-up notes.
  - r10 panel (`c-420`) W1-W4 and N1-N4 were all folded in r10 v1.0 / v1.1 (`6f9fef225`);
    W2 (`csi-spl-utl/` `parts=all` CI cost in `ci-doc-only.sh:124`) is carried forward
    explicitly in row 02 (1.4).
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to the planner/holder
  box only; 173 lines, unchanged since r10):
  - All open refactor-labelled entries (line 25 `reverse-tunnel-cron.sh:23`, line 48
    `agent-boot-restore` dir, line 76 `spl-desk-reply.sh` usage text, line 104
    `spl-lane-mix.func.sh` stale agy wording, line 113 `_ppe_keys`, line 115
    `i18n-lang-review-exempt.json:2`, line 125 WUI entry-chunk headroom, line 133
    `spl-unanswered-sweep.func.sh:196`) are accounted for in section 7; bug-shaped,
    test-shaped, and perf-shaped entries are out of scope for a refactor round.
- **(d) spec 011 tasks:**
  `git log 84f86ab8c..992866d69 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r10; remaining open/partial tasks (`T001`-`T008` owner-deferred,
  `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `_spl_box_users_resolve`, `_spl_box_user_home`, and `_spl_box_user_exec` (`spl-cmd-guard-mode`, `install-force-push-guard`)

`orc:` = `csi-spl-orc/`. On `992866d69`:

- Two `csi-spl-orc` box-wide guard installers operate on both the box's agent user and
  box user and duplicate the identical user resolution (`source spool-env.inc.sh`,
  `SPOOL_ENV_NO_BINS=1 spool_env_resolve`, deduplicated `users` array), empty-user
  `FATAL`, `getent passwd "$u" | cut -d: -f6` home lookup, and direct vs
  `sudo -n -u "$u" -H` execution:
  1. `orc:src/bash/run/spl-cmd-guard-mode.func.sh:50-88` (88 lines; `_scg_homes` `:50-64`
     and `do_spl_cmd_guard_mode` `:66-88`; missing home logs `FATAL no home for $u` and
     returns `1`).
  2. `orc:src/bash/run/install-force-push-guard.func.sh:29-42` (46 lines;
     `do_install_force_push_guard` `:19-46`; missing home logs `FAIL no home for $u`,
     sets `rc=1`, and continues to the next user).
- Hosting `_spl_box_users_resolve`, `_spl_box_user_home`, and `_spl_box_user_exec` in
  `spl-cmd-guard-mode.func.sh` adds zero new files and zero eager loads.
  `install-force-push-guard.func.sh` lazy-sources `spl-cmd-guard-mode.func.sh` only on
  the non-override path (`FORCE_PUSH_GUARD_HOMES` unset) when `_spl_box_users_resolve` is
  not yet defined. `_spl_box_user_home <user> <fatal|fail>` returns `1` on empty user
  (`FATAL`) in both modes, and on missing home returns `1` (`FATAL`) in `fatal` mode or
  `2` (`FAIL`) in `fail` mode so `do_install_force_push_guard` keeps its exact
  `rc=1; continue` loop semantics.
- None of the 3 edited files reads or writes any secret, key, or credential (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `_spl_box_users_resolve` 7 lines, `_spl_box_user_home` 9 lines, `_spl_box_user_exec` 5
  lines, `_scg_homes` 14 -> 8 lines, `do_spl_cmd_guard_mode` 23 -> 21 lines,
  `do_install_force_push_guard` 28 -> 25 lines.
  None of the 3 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-cmd-guard-mode.func.sh`: replace `:50-88` with
  `_spl_box_users_resolve`, `_spl_box_user_home`, `_spl_box_user_exec`, thin
  `_scg_homes`, and updated `do_spl_cmd_guard_mode`. 88 -> 111 lines (`+32 -9`).
- `orc:src/bash/run/install-force-push-guard.func.sh`: replace `:29-42` with lazy-source
  of `spl-cmd-guard-mode.func.sh` and calls to `_spl_box_users_resolve`,
  `_spl_box_user_home "$u" fail`, and `_spl_box_user_exec`. 46 -> 43 lines (`+8 -11`).
- `orc:src/bash/tests/spl-cmd-guard-mode.tst.sh`: add section `8` to header after `:20`;
  insert section `8` immediately before `echo "spl-cmd-guard-mode: $((n - fails))/$n passed"`
  at `:139` (followed by one blank line; `:138` is already blank): 2 `_spl_box_users_resolve`
  checks, 4 `_spl_box_user_home` checks, 1 `_spl_box_user_exec` check, 2 one-copy checks
  across both files, and 3 standalone hermetic checks using a stub `getent` (never
  reading real `$HOME`). 140 -> 238 lines (`+98 -0`). Total edited files: **3** (within
  rulebook 3.1's max 5).
- head1's files, sha256 (12 chars): `spl-cmd-guard-mode.func.sh` `a9b4c1881cc4`,
  `install-force-push-guard.func.sh` `85ed017452ab`,
  `spl-cmd-guard-mode.tst.sh` `c391193b75af`.

Verbatim helper, caller, and test hunks (head1 on `992866d69`):

`orc:src/bash/run/spl-cmd-guard-mode.func.sh` (replace `:50-88`):
```bash
# _spl_box_users_resolve: source spool-env.inc.sh and fill caller-scoped users
# with SPOOL_AGENT_USER and (when distinct) SPOOL_BOX_USER.
_spl_box_users_resolve() {
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
  users=("${SPOOL_AGENT_USER:-}")
  [[ "${SPOOL_BOX_USER:-}" != "${SPOOL_AGENT_USER:-}" ]] && users+=("${SPOOL_BOX_USER:-}")
  return 0
}

# _spl_box_user_home <user> <missing_mode>: validate user and set caller-scoped
# h from getent passwd; missing_mode=fatal logs FATAL and returns 1, fail logs
# FAIL and returns 2. Empty user logs FATAL and returns 1 in both modes.
_spl_box_user_home() {
  local u="$1" mode="${2:-fatal}"
  [[ -n "$u" ]] || { do_log "FATAL no agent / box user: set SPOOL_AGENT_USER and SPOOL_BOX_USER"; return 1; }
  h="$(getent passwd "$u" | cut -d: -f6)"
  if [[ ! -d "$h" ]]; then
    if [[ "$mode" == fail ]]; then do_log "FAIL no home for $u"; return 2; fi
    do_log "FATAL no home for $u"; return 1
  fi
}

# _spl_box_user_exec <user> <cmd...>: run <cmd...> as <user> (no sudo if self).
_spl_box_user_exec() {
  local u="$1"; shift
  if [[ "$(id -un)" == "$u" ]]; then "$@"
  else sudo -n -u "$u" -H "$@"; fi
}

# _scg_homes: "<user> <home>" per line, the agent user and the box user
_scg_homes() {
  local u h="" users=()
  _spl_box_users_resolve || return 1
  for u in "${users[@]}"; do
    _spl_box_user_home "$u" fatal || return 1
    printf '%s %s\n' "$u" "$h"
  done
}

do_spl_cmd_guard_mode() {
  local impl="${SPL_CMD_GUARD_IMPL:-}" dry="${DRY_RUN:-1}" bin="${SPL_CMD_GUARD_BIN:-}" u h rc=0 rows
  local script="$PROJ_PATH/src/bash/features/spawn-agents/scripts/spl-cmd-guard-install.sh"
  case "$impl" in py | shadow | rust) ;; *) do_log "FATAL SPL_CMD_GUARD_IMPL must be py, shadow or rust"; return 2 ;; esac
  case "$dry" in 0 | 1) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 2 ;; esac
  if [[ "$impl" != py && -z "$bin" ]]; then
    bin="$(_scg_build)" || { do_log "FAIL the spl-cmd-guard build failed"; return 1; }
  fi
  [[ -n "$bin" ]] || bin=-
  if [[ -n "${SPL_CMD_GUARD_HOMES:-}" ]]; then
    for h in $SPL_CMD_GUARD_HOMES; do bash "$script" "$h" "$impl" "$bin" "$dry" || rc=$?; done
  else
    rows="$(_scg_homes)" || return 1
    while read -r u h; do
      do_log "INFO spl-cmd-guard $impl for $u ($h)$([[ $dry == 1 ]] && echo ' - DRY RUN')"
      _spl_box_user_exec "$u" bash "$script" "$h" "$impl" "$bin" "$dry" || rc=$?
    done <<<"$rows"
  fi
  (( rc == 0 )) || { do_log "FAIL spl-cmd-guard mode exited $rc"; return "$rc"; }
  do_log "OK spl-cmd-guard $impl $([[ $dry == 1 ]] && echo 'planned (DRY_RUN=0 writes)' || echo set)"
}
```

`orc:src/bash/run/install-force-push-guard.func.sh` (replace `:29-42`):
```bash
    # shellcheck source=spl-cmd-guard-mode.func.sh
    declare -F _spl_box_users_resolve >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cmd-guard-mode.func.sh" || return 1
    _spl_box_users_resolve || return 1
    for u in "${users[@]}"; do
      local hrc=0
      _spl_box_user_home "$u" fail || hrc=$?
      (( hrc == 2 )) && { rc=1; continue; }
      (( hrc == 0 )) || return "$hrc"
      do_log "INFO force-push-guard for $u ($h)$([[ $dry == 1 ]] && echo ' - DRY RUN')"
      _spl_box_user_exec "$u" bash -c "$fn" _ "$step" "$h" "$dry" || rc=$?
    done
```

`orc:src/bash/tests/spl-cmd-guard-mode.tst.sh` (append to header after `:20`; insert
section `8` immediately before `echo "spl-cmd-guard-mode: $((n - fails))/$n passed"` at
`:139`, followed by one blank line; `:138` is already blank):
```bash
#   8. _spl_box_users_resolve / _spl_box_user_home / _spl_box_user_exec,
#      one-copy across spl-cmd-guard-mode and install-force-push-guard, and
#      standalone lazy-load checks preserving FAIL/continue vs FATAL (r11-01)
```
```bash
# 8. _spl_box_users_resolve / _spl_box_user_home / _spl_box_user_exec and one-copy (r11-01)
ME="$(id -un)"
mkdir -p "$T/bin8" "$T/spool8"
cat >"$T/bin8/getent" <<EOF
#!/usr/bin/env bash
case "\$2" in
  "$ME") printf '%s:x:1001:1001::%s:/bin/bash\n' "$ME" "$T/h1" ;;
  r11_nohome) printf 'r11_nohome:x:1002:1002::%s:/bin/bash\n' "$T/no-such-home" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin8/getent"

out="$(SPOOL_ROOT="$T/spool8" SPOOL_AGENT_USER="$ME" SPOOL_BOX_USER="r11_nohome" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }; PROJ_PATH="$1"
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  users=(); _spl_box_users_resolve || exit $?
  printf "U=%s\n" "${users[*]}"' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "U=$ME r11_nohome" ]] &&
  pass "8: _spl_box_users_resolve returns both distinct agent and box users" || fail "8: resolve two ($rc: $out)"

out="$(SPOOL_ROOT="$T/spool8" SPOOL_AGENT_USER="$ME" SPOOL_BOX_USER="$ME" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }; PROJ_PATH="$1"
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  users=(); _spl_box_users_resolve || exit $?
  printf "N=%d U=%s\n" "${#users[@]}" "${users[*]}"' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "N=1 U=$ME" ]] &&
  pass "8: _spl_box_users_resolve deduplicates identical agent and box user" || fail "8: resolve one ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  h=""; _spl_box_user_home "$2" fatal || exit $?
  printf "H=%s\n" "$h"' _ "$ORC" "$ME" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "H=$T/h1" ]] &&
  pass "8: _spl_box_user_home resolves existing user home" || fail "8: home ok ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  h=""; _spl_box_user_home "" fail' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no agent / box user: set SPOOL_AGENT_USER and SPOOL_BOX_USER"* ]] &&
  pass "8: _spl_box_user_home refuses empty user with rc 1" || fail "8: home empty ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  h=""; _spl_box_user_home r11_nohome fatal' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no home for r11_nohome"* ]] &&
  pass "8: _spl_box_user_home fatal mode logs FATAL and returns 1" || fail "8: home fatal ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  h=""; _spl_box_user_home r11_nohome fail' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *"FAIL no home for r11_nohome"* ]] &&
  pass "8: _spl_box_user_home fail mode logs FAIL and returns 2" || fail "8: home fail ($rc: $out)"

out="$(bash -c '
  set -uo pipefail; . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  _spl_box_user_exec "$2" printf "EXEC=%s\n" ok' _ "$ORC" "$ME" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "EXEC=ok" ]] &&
  pass "8: _spl_box_user_exec runs command directly for current user" || fail "8: exec ($rc: $out)"

scg_f="$ORC/src/bash/run/spl-cmd-guard-mode.func.sh"
fpg_f="$ORC/src/bash/run/install-force-push-guard.func.sh"
[[ "$(grep -c '^_spl_box_users_resolve()' "$scg_f")" -eq 1 &&
   "$(grep -c '^_spl_box_user_home()' "$scg_f")" -eq 1 &&
   "$(grep -c '^_spl_box_user_exec()' "$scg_f")" -eq 1 ]] &&
  pass "8: one copy: spl-cmd-guard-mode.func.sh hosts _spl_box_user* helpers" || fail "8: host"
own_fpg="$(grep -nE 'spool_env_resolve|getent passwd|sudo -n -u|no agent / box user' "$fpg_f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$own_fpg" ]] && grep -q '_spl_box_users_resolve' "$fpg_f" && grep -q '_spl_box_user_home ' "$fpg_f" && grep -q '_spl_box_user_exec ' "$fpg_f" &&
  pass "8: one copy: install-force-push-guard.func.sh delegates to _spl_box_user*" || fail "8: fpg own=[$own_fpg]"

out="$(PATH="$T/bin8:$PATH" SPOOL_ROOT="$T/spool8" SPOOL_AGENT_USER="$ME" SPOOL_BOX_USER="$ME" PROJ_PATH="$ORC" DRY_RUN=1 bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/install-force-push-guard.func.sh"
  do_install_force_push_guard' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"INFO force-push-guard for $ME ($T/h1) - DRY RUN"* && "$out" == *"OK force-push-guard planned (DRY_RUN=0 writes)"* ]] &&
  pass "8: standalone: install-force-push-guard lazy-loads helpers and plans for current user" || fail "8: fpg ok ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" SPOOL_ROOT="$T/spool8" SPOOL_AGENT_USER="r11_nohome" SPOOL_BOX_USER="$ME" PROJ_PATH="$ORC" DRY_RUN=1 bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/install-force-push-guard.func.sh"
  do_install_force_push_guard' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FAIL no home for r11_nohome"* && "$out" == *"INFO force-push-guard for $ME ($T/h1) - DRY RUN"* && "$out" == *"FAIL force-push-guard install exited 1"* ]] &&
  pass "8: standalone: install-force-push-guard preserves FAIL/continue on missing home" || fail "8: fpg missing ($rc: $out)"

out="$(PATH="$T/bin8:$PATH" SPOOL_ROOT="$T/spool8" SPOOL_AGENT_USER="r11_nohome" SPOOL_BOX_USER="$ME" PROJ_PATH="$ORC" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-cmd-guard-mode.func.sh"
  _scg_homes' _ "$ORC" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no home for r11_nohome"* && "$out" != *"$ME $T/h1"* ]] &&
  pass "8: standalone: _scg_homes preserves FATAL/return 1 on missing home" || fail "8: scg missing ($rc: $out)"
```

**Behaviour:** zero behaviour change. Both `do_spl_cmd_guard_mode` and
`do_install_force_push_guard` preserve exact exit codes, exact `FATAL`/`FAIL`/`INFO`/`OK`
messages, exact loop ordering (including `install-force-push-guard` continuing past a
missing home to process the second user and exiting 1, while `_scg_homes` aborts on the
first missing home with `FATAL` and rc 1), and exact direct vs `sudo -n -u "$u" -H`
execution. All 3 standalone checks pass on unmodified `base` too, proving equivalence.
- **Branch coverage:** the `sudo -n -u` branch inside `_spl_box_user_exec` stays untested
  hermetically, the same as on `base` (all hermetic tests run as `$ME`).

### 1.4 Row 02's site: `_utl_send_throttled_alert` throttled alert sender (`clock-sync-check`, `tmux-health-guard`, `docker-test-container-prune`)

`utl:` = `csi-spl-utl/`. On `992866d69`:

- Three shellcheck-clean, non-secret `csi-spl-utl` reliability checks duplicate the same
  14-line `*_SEND_CMD` alert delivery and stamp-write block (`read -ra send`, `PROJ_PATH`
  sibling `spool-send.sh` fallback, missing-sender `WARN`, `timeout -k 2 "$send_tmo"`
  `--no-poke` note send, `mkdir -p` + stamp write on delivery only, `INFO ... note sent` /
  `WARN ... failed`):
  1. `utl:src/bash/run/clock-sync-check.func.sh:182-217` (`clock_sync_alert`, block
     `:203-216`; override `CLOCK_SYNC_SEND_CMD`, timeout `$send_tmo` default 20, `alert`
     wording).
  2. `utl:src/bash/run/tmux-health-guard.func.sh:131-166` (`tmux_health_alert`, block
     `:152-165`; override `TMUX_HEALTH_SEND_CMD`, timeout `$send_tmo` default 20, `alert`
     wording).
  3. `utl:src/bash/run/docker-test-container-prune.func.sh:126-160` (`_dtcp_note`, block
     `:146-159`; override `DOCKER_PRUNE_SEND_CMD`, timeout `20`, `note` wording:
     `"note not sent"` and `"the next run sends again"`).
- Hosting `_utl_send_throttled_alert` in `clock-sync-check.func.sh` adds zero new files
  and zero eager loads. `tmux-health-guard.func.sh` and
  `docker-test-container-prune.func.sh` lazy-source `clock-sync-check.func.sh` inside
  their `DRY_RUN=0` delivery path (after the throttle and `dry != 0` returns), so normal
  `DRY_RUN=1` or OK probes incur zero extra sourcing cost (both `< 500 ms` probe budgets
  in `clock-sync-check.tst.sh` and `tmux-health-guard.tst.sh` stay unchanged).
- None of the 4 edited files reads or writes any secret, key, or credential (non-secret).
- **CI cost (accepted, carrying forward r10 W2):**
  `orc:src/bash/scripts/ci-doc-only.sh:124` has no `csi-spl-utl/` narrow case (classifies
  as `parts=all`). Landing row 02 triggers one full CI workflow 10 run (`parts=all`)
  during the night phase; this one-time CI cost is explicitly named and accepted to
  consolidate wave 1 of the `*_SEND_CMD` alert senders.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `_utl_send_throttled_alert` 20 lines, `clock_sync_alert` 35 -> 22 lines,
  `tmux_health_alert` 35 -> 24 lines, `_dtcp_note` 32 -> 21 lines.
  None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `utl:src/bash/run/clock-sync-check.func.sh`: replace `:182-217` with
  `_utl_send_throttled_alert` + delegated `clock_sync_alert` (dropping unused
  `local -a send`). 226 -> 238 lines (`+27 -15`).
- `utl:src/bash/run/tmux-health-guard.func.sh`: replace `:131-166` with lazy-source of
  `clock-sync-check.func.sh` + `_utl_send_throttled_alert` call inside `tmux_health_alert`
  (dropping unused `local -a send`). 175 -> 164 lines (`+4 -15`).
- `utl:src/bash/run/docker-test-container-prune.func.sh`: replace `:126-160` with
  lazy-source of `clock-sync-check.func.sh` + `_utl_send_throttled_alert ... note` call
  inside `_dtcp_note` (dropping unused `local -a send`). 292 -> 281 lines (`+4 -15`).
- `utl:src/bash/tests/clock-sync-check.tst.sh`: add section `17` to header after `:21`;
  insert section `17` immediately before `echo "=========================================="`
  at `:242` (followed by one blank line; `:241` is already blank): 4 direct
  `_utl_send_throttled_alert` checks (sibling discovery + `--no-poke` + stamp, missing
  sender `alert` mode, missing sender `note` mode, failing sender), 3 one-copy checks
  across all 3 actions, and 4 standalone lazy-load checks for `tmux_health_alert` and
  `_dtcp_note`. 245 -> 346 lines (`+101 -0`). Total edited files: **4** (within rulebook
  3.1's max 5).
- head2's files, sha256 (12 chars): `clock-sync-check.func.sh` `aa38ac185018`,
  `tmux-health-guard.func.sh` `6ddbd1d88885`,
  `docker-test-container-prune.func.sh` `412690972f4b`,
  `clock-sync-check.tst.sh` `bf1247df51ca`.

Verbatim helper, caller, and test hunks (head2 on `992866d69`):

`utl:src/bash/run/clock-sync-check.func.sh` (replace `:182-217`):
```bash
# _utl_send_throttled_alert <send_cmd> <send_tmo> <from> <to> <task> <body> <stamp> <stamp_val> <sent_label> <fail_label> [alert|note]
# Send one --no-poke spool note (override cmd or PROJ_PATH sibling spool-send.sh)
# under timeout -k 2; write <stamp_val> to <stamp> only on delivery. Always returns 0.
_utl_send_throttled_alert() {
  local send_cmd="$1" send_tmo="$2" from="$3" to="$4" task="$5" body="$6"
  local stamp="$7" stamp_val="$8" sent_label="$9" fail_label="${10}" kind="${11:-alert}"
  local missing_msg="alert not sent" retry_verb="alerts"
  [[ "$kind" == note ]] && missing_msg="note not sent" retry_verb="sends"
  local -a send
  read -ra send <<<"$send_cmd"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: $missing_msg"; return 0; }
  fi
  if timeout -k 2 "$send_tmo" "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$stamp_val" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run $retry_verb again"
    do_log "INFO $sent_label note sent to $to"
  else
    do_log "WARN $fail_label: the note to $to failed"
  fi
  return 0
}

# clock_sync_alert <state> <detail> <dry> <offset> <server> - one throttled note
clock_sync_alert() {
  local state="$1" detail="$2" dry="$3" off="$4" server="$5" stamp prev="" at=0 now box body from
  local to="${CLOCK_SYNC_ALERT_TO:-orchestrator}" task="${CLOCK_SYNC_ALERT_TASK:-clock-sync}"
  local throttle="${CLOCK_SYNC_THROTTLE_S:-3600}" send_tmo="${CLOCK_SYNC_SEND_TIMEOUT:-20}"
  box="$(spl_box_name)"
  from="${CLOCK_SYNC_ALERT_FROM:-${SPOOL_AGENT_ID:-clock-sync-check@$box}}"
  stamp="$(clock_sync_dir)/last-alert.stamp"
  now="${CLOCK_SYNC_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$state" ]] && ((now - at < throttle)); then
    do_log "INFO clock-sync $state alert throttled by $stamp"
    return 0
  fi
  body="clock-sync $state on $box: $detail. Offset $off, server $server. A drifting clock skews the hub beat (false fences), auth tokens and TLS checks. Nothing was changed: check by hand with timedatectl timesync-status (or chronyc tracking)."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  _utl_send_throttled_alert "${CLOCK_SYNC_SEND_CMD:-}" "$send_tmo" "$from" "$to" "$task" "$body" \
    "$stamp" "$state $now" "clock-sync $state" "clock-sync"
}
```

`utl:src/bash/run/tmux-health-guard.func.sh` (replace `:131-166`):
```bash
# tmux_health_alert <socket> <state> <detail> <dry> - one throttled note
tmux_health_alert() {
  local sock="$1" state="$2" detail="$3" dry="$4" stamp prev="" at=0 now box body from
  local to="${TMUX_HEALTH_ALERT_TO:-orchestrator}" task="${TMUX_HEALTH_ALERT_TASK:-tmux-health}"
  local throttle="${TMUX_HEALTH_THROTTLE_S:-1800}" send_tmo="${TMUX_HEALTH_SEND_TIMEOUT:-20}"
  box="$(spl_box_name)"
  from="${TMUX_HEALTH_ALERT_FROM:-${SPOOL_AGENT_ID:-tmux-health-guard@$box}}"
  stamp="$(tmux_health_stamp "$sock")"
  now="${EPOCHSECONDS:-$(date +%s)}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$state" ]] && ((now - at < throttle)); then
    do_log "INFO tmux-health $state alert throttled by $stamp"
    return 0
  fi
  body="tmux-health $state on $box: the tmux server at $sock ($detail). Every agent pane of this box runs on it. Nothing was restarted: check the server by hand (as its owner: tmux -S $sock list-sessions)."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  # shellcheck source=clock-sync-check.func.sh
  declare -F _utl_send_throttled_alert >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/clock-sync-check.func.sh" || return 0
  _utl_send_throttled_alert "${TMUX_HEALTH_SEND_CMD:-}" "$send_tmo" "$from" "$to" "$task" "$body" \
    "$stamp" "$state $now" "tmux-health $state" "tmux-health"
}
```

`utl:src/bash/run/docker-test-container-prune.func.sh` (replace `:126-160`):
```bash
# _dtcp_note <dry> <signature> <body> [once]: send (or plan) the orchestrator
# note, once per new signature or per throttle interval; with "once", once per
# new signature only.
_dtcp_note() {
  local dry="$1" sig="$2" body="$3" once="${4:-}" stamp prev_sig="" prev_t=0 now from
  local to="${DOCKER_PRUNE_ALERT_TO:-orchestrator}" task="${DOCKER_PRUNE_ALERT_TASK:-docker-test-container-prune}"
  stamp="$(_dtcp_stamp)"
  now="${DOCKER_PRUNE_NOW:-$(date +%s)}"
  from="${DOCKER_PRUNE_ALERT_FROM:-${SPOOL_AGENT_ID:-docker-test-container-prune@$(_dtcp_box)}}"
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  if [[ -f "$stamp" ]]; then read -r prev_sig prev_t <"$stamp" 2>/dev/null || true; fi
  [[ "$prev_t" =~ ^[0-9]+$ ]] || prev_t=0
  if [[ "$prev_sig" == "$sig" ]] && { [[ -n "$once" ]] || ((now - prev_t < ${DOCKER_PRUNE_THROTTLE_S:-21600})); }; then
    do_log "INFO docker-test-container-prune note throttled by $stamp"
    return 0
  fi
  # shellcheck source=clock-sync-check.func.sh
  declare -F _utl_send_throttled_alert >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/clock-sync-check.func.sh" || return 0
  _utl_send_throttled_alert "${DOCKER_PRUNE_SEND_CMD:-}" 20 "$from" "$to" "$task" "$body" \
    "$stamp" "$sig $now" "docker-test-container-prune" "docker-test-container-prune" note
}
```

`utl:src/bash/tests/clock-sync-check.tst.sh` (append to header after `:21`; insert
section `17` immediately before `echo "=========================================="` at
`:242`, followed by one blank line; `:241` is already blank):
```bash
#  17. _utl_send_throttled_alert helper, one-copy across clock-sync-check,
#      tmux-health-guard, and docker-test-container-prune, and lazy-load (r11-02)
```
```bash
# 17. _utl_send_throttled_alert helper and one-copy delegation (r11-02)
THG_SH="$UTL_ROOT/src/bash/run/tmux-health-guard.func.sh"
DTCP_SH="$UTL_ROOT/src/bash/run/docker-test-container-prune.func.sh"
mkdir -p "$T/fake17/csi-spl-utl" "$T/fake17/csi-spl-orc/src/bash/features/spawn-agents/scripts" "$T/state17"
S17_LOG="$T/s17.log"
cat >"$T/fake17/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<'S17_EOF'
#!/bin/bash
printf 'SIB17 %s\n' "$*" >>"$S17_LOG"
S17_EOF
chmod +x "$T/fake17/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
: >"$S17_LOG"

out=$(S17_LOG="$S17_LOG" PROJ_PATH="$T/fake17/csi-spl-utl" bash -c '
  source "$1"
  _utl_send_throttled_alert "" 15 "from17@b" "orchestrator" "task17" "body17" "$2" "ST 123" "demo ST" "demo"' _ "$FUNC_SH" "$T/state17/a.stamp" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"INFO demo ST note sent to orchestrator"* && "$(cat "$T/state17/a.stamp" 2>/dev/null)" == "ST 123" ]] &&
  grep -q -- "SIB17 --from from17@b --to orchestrator --kind note --task task17 --no-poke --body body17" "$S17_LOG"; then
  pass "17. _utl_send_throttled_alert uses PROJ_PATH sibling spool-send.sh, --no-poke, and writes stamp"
else
  fail "17. sibling send (rc=$rc, out=$out, stamp=$(cat "$T/state17/a.stamp" 2>/dev/null), log=$(cat "$S17_LOG"))"
fi

out=$(PROJ_PATH="$T/no-such-tree" bash -c '
  source "$1"
  _utl_send_throttled_alert "" 15 "from17@b" "orchestrator" "task17" "body17" "$2" "ST 123" "demo ST" "demo"' _ "$FUNC_SH" "$T/state17/missing.stamp" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"WARN no spool-send.sh at $T/no-such-tree/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh: alert not sent"* && ! -f "$T/state17/missing.stamp" ]]; then
  pass "17. _utl_send_throttled_alert warns 'alert not sent' and returns 0 when default sender missing"
else
  fail "17. missing sender alert (rc=$rc, out=$out)"
fi

out=$(PROJ_PATH="$T/no-such-tree" bash -c '
  source "$1"
  _utl_send_throttled_alert "" 15 "from17@b" "orchestrator" "task17" "body17" "$2" "ST 123" "demo ST" "demo" note' _ "$FUNC_SH" "$T/state17/missing-n.stamp" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"WARN no spool-send.sh at $T/no-such-tree/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh: note not sent"* && ! -f "$T/state17/missing-n.stamp" ]]; then
  pass "17. _utl_send_throttled_alert note mode warns 'note not sent' when default sender missing"
else
  fail "17. missing sender note (rc=$rc, out=$out)"
fi

out=$(bash -c '
  source "$1"
  _utl_send_throttled_alert "$2" 15 "from17@b" "orchestrator" "task17" "body17" "$3" "ST 123" "demo ST" "demo"' _ "$FUNC_SH" "$BIN_DIR/failing-send.sh" "$T/state17/fail.stamp" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"WARN demo: the note to orchestrator failed"* && ! -f "$T/state17/fail.stamp" ]]; then
  pass "17. _utl_send_throttled_alert logs fail_label and skips stamp on sender failure"
else
  fail "17. failing sender (rc=$rc, out=$out)"
fi

if [[ "$(grep -c '^_utl_send_throttled_alert()' "$FUNC_SH")" -eq 1 ]] && grep -q '_utl_send_throttled_alert ' "$FUNC_SH"; then
  pass "17. one copy: clock-sync-check.func.sh hosts _utl_send_throttled_alert"
else
  fail "17. host check"
fi
for uf in "$THG_SH" "$DTCP_SH"; do
  own_u="$(grep -nE 'spool-send\.sh|the next run (alerts|sends) again|cannot write \$stamp' "$uf" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [[ -z "$own_u" ]] && grep -q '_utl_send_throttled_alert ' "$uf"; then
    pass "17. one copy: $(basename "$uf") delegates alert send to _utl_send_throttled_alert"
  else
    fail "17. $(basename "$uf") own=[$own_u]"
  fi
done

: >"$SEND_LOG"
out=$(TMUX_HEALTH_STATE_DIR="$T/state17/thg" TMUX_HEALTH_SEND_CMD="$BIN_DIR/send.sh" SPOOL_DESK_BOX="box17" bash -c '
  source "$1"; tmux_health_alert "/tmp/sock17" HUNG "timeout" 0' _ "$THG_SH" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"INFO tmux-health HUNG note sent to orchestrator"* && -f "$T/state17/thg/tmp_sock17.stamp" ]] &&
  grep -q -- "--from tmux-health-guard@box17 --to orchestrator --kind note --task tmux-health --no-poke" "$SEND_LOG"; then
  pass "17. standalone: tmux-health-guard lazy-loads _utl_send_throttled_alert and sends"
else
  fail "17. standalone thg ok (rc=$rc, out=$out, log=$(cat "$SEND_LOG"))"
fi

out=$(TMUX_HEALTH_STATE_DIR="$T/state17/thg-fail" TMUX_HEALTH_SEND_CMD="$BIN_DIR/failing-send.sh" SPOOL_DESK_BOX="box17" bash -c '
  source "$1"; tmux_health_alert "/tmp/sock17" HUNG "timeout" 0' _ "$THG_SH" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"WARN tmux-health: the note to orchestrator failed"* && ! -f "$T/state17/thg-fail/tmp_sock17.stamp" ]]; then
  pass "17. standalone: tmux_health_alert preserves failure wording and skips stamp"
else
  fail "17. standalone thg fail (rc=$rc, out=$out)"
fi

: >"$SEND_LOG"
out=$(DOCKER_PRUNE_STATE_DIR="$T/state17/dtcp" DOCKER_PRUNE_SEND_CMD="$BIN_DIR/send.sh" DOCKER_PRUNE_NOW=2000000100 DEV_BOX="box17" bash -c '
  source "$1"; _dtcp_note 0 sig17 "body-dtcp"' _ "$DTCP_SH" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"INFO docker-test-container-prune note sent to orchestrator"* && "$(cat "$T/state17/dtcp/alert.stamp" 2>/dev/null)" == "sig17 2000000100" ]] &&
  grep -q -- "--from docker-test-container-prune@box17 --to orchestrator --kind note --task docker-test-container-prune --no-poke --body body-dtcp" "$SEND_LOG"; then
  pass "17. standalone: docker-test-container-prune lazy-loads _utl_send_throttled_alert and sends"
else
  fail "17. standalone dtcp ok (rc=$rc, out=$out, stamp=$(cat "$T/state17/dtcp/alert.stamp" 2>/dev/null), log=$(cat "$SEND_LOG"))"
fi

out=$(PROJ_PATH="$T/no-such-tree" DOCKER_PRUNE_STATE_DIR="$T/state17/dtcp-miss" DOCKER_PRUNE_SEND_CMD="" DOCKER_PRUNE_NOW=2000000100 DEV_BOX="box17" bash -c '
  source "$1"; _dtcp_note 0 sig17 "body-dtcp"' _ "$DTCP_SH" 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"WARN no spool-send.sh at $T/no-such-tree/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh: note not sent"* && ! -f "$T/state17/dtcp-miss/alert.stamp" ]]; then
  pass "17. standalone: _dtcp_note preserves 'note not sent' missing-sender wording"
else
  fail "17. standalone dtcp miss (rc=$rc, out=$out)"
fi
```

**Behaviour:** zero behaviour change. All three actions keep exact sender resolution
(`*_SEND_CMD` override > `PROJ_PATH` sibling `spool-send.sh`), exact `timeout -k 2` and
`--no-poke` flags, exact `WARN`/`INFO` wording (`"alert not sent"` / `"alerts again"` for
`clock-sync-check` and `tmux-health-guard`; `"note not sent"` / `"sends again"` for
`docker-test-container-prune`), exact stamp payloads and failure handling, and exact
return codes (all 4 standalone `tmux_health_alert` and `_dtcp_note` checks pass on
unmodified `base` too, proving equivalence). Distinct from `r10-02`'s Family A
`_utl_send_spool_note` (`reboot-required-check.func.sh:85`, 1.2 (a)). Per panel N2/N3:
the lazy sources only define functions (`func-name-unique.tst.sh` 0/2/0, no top-level
side effects), and `source ... || return 0` is silent only on a broken tree (zero
behaviour change on a whole tree; kept as written without adding a `WARN` message).

### 1.5 Before and on the rows' heads

2026-11-27T11:31:06Z-11:35:06Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts; "-" means that row's head does not touch the suite's
tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/spl-cmd-guard-mode.tst.sh` | 01 | 0 / 16 / 0 | 0 / 28 / 0 (+12 new checks) | - |
| `orc:src/bash/features/spool-install/tests/test-y13-force-push-guard.sh` | 01 | 0 / 22 / 0 | = | - |
| `utl:src/bash/tests/clock-sync-check.tst.sh` | 02 | 0 / 16 / 0 | - | 0 / 27 / 0 (+11 new checks) |
| `utl:src/bash/tests/tmux-health-guard.tst.sh` | 02 | 0 / 17 / 0 | - | = |
| `utl:src/bash/tests/docker-test-container-prune.tst.sh` | 02 | 0 / 25 / 0 | - | = |
| `utl:src/bash/tests/print-help.tst.sh` | 02 | 0 / 4 / 0 | - | = |
| `orc:src/bash/tests/reliability-checks-cron.tst.sh` | 02 | 0 / 9 / 0 | - | = |
| `orc:src/bash/tests/box-name-from-cnf.tst.sh` | 02 | 0 / 14 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |

Note (\*): on Row 01 mutation check `m1c`, multi-line `$out` dumped inside `FAIL: 8: fpg
missing` includes `FAIL force-push-guard install exited 1` on its own line, so
`grep -ciE '^ *(not ok|fail)'` counts 3 fail lines (2 real `FAIL:` checks + 1 dumped
`FAIL` line; suite summary reads `26/28 passed`). `gcloud-account-pinned.tst.sh` counts
are box-dependent (48 on this box; equal on base and heads). Run
`no-literal-paths.tst.sh` in a git checkout owned by the user running git.

`shellcheck 0.10.0 -S warning -x` on all 7 edited files (head1: 3 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own scratch clone of `992866d69`, reconstructed
from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `spl-cmd-guard-mode.tst.sh` on base): rc 1, 19 pass
  (16 base + all 3 standalone equivalence checks passing on base), 9 fail (2
  `_spl_box_users_resolve: command not found`, 4 `_spl_box_user_home: command not found`,
  1 `_spl_box_user_exec: command not found`, `FAIL: 8: host`, and `FAIL: 8: fpg` naming
  `install-force-push-guard.func.sh:31`); head1: rc 0, 28 pass, 0 fail.
- Row 02 red control (`rc2`, head2's `clock-sync-check.tst.sh` on base): rc 1, 20 pass
  (16 base + all 4 standalone equivalence checks passing on base), 7 fail (4
  `_utl_send_throttled_alert: command not found`, `FAIL: 17. host check`,
  `FAIL: 17. tmux-health-guard.func.sh` naming `:154`, and
  `FAIL: 17. docker-test-container-prune.func.sh` naming `:148`); head2: rc 0, 27 pass,
  0 fail.

**Mutation checks** (n=1 each, fresh scratch clones of `992866d69` with head1/head2
applied, then one defect planted; all hermetic, never touching `$HOME`):
- `m1a` (`install-force-push-guard.func.sh` passes `fatal` instead of `fail` to
  `_spl_box_user_home`): `spl-cmd-guard-mode.tst.sh` rc 1, 27 pass, 1 fail
  (`FAIL: 8: fpg missing`).
- `m1b` (`spl-cmd-guard-mode.func.sh` `_scg_homes` passes `fail` instead of `fatal` to
  `_spl_box_user_home`): `spl-cmd-guard-mode.tst.sh` rc 1, 27 pass, 1 fail
  (`FAIL: 8: scg missing`).
- `m1c` (`_spl_box_users_resolve` drops appending distinct `SPOOL_BOX_USER`):
  `spl-cmd-guard-mode.tst.sh` rc 1, 26 pass (`26/28 passed`), `3*` fail lines (2 real
  `FAIL:` checks `8: resolve two` and `8: fpg missing` + 1 dumped `FAIL` line).
- `m2a` (`_utl_send_throttled_alert` drops `--no-poke`): `clock-sync-check.tst.sh` rc 1,
  23 pass, 4 fail (`5. LOST real run`, `17. sibling send`, `17. standalone thg ok`,
  `17. standalone dtcp ok`).
- `m2b` (`_dtcp_note` passes `alert` instead of `note` to `_utl_send_throttled_alert`):
  `clock-sync-check.tst.sh` rc 1, 26 pass, 1 fail (`17. standalone dtcp miss`).
- `m2c` (`tmux_health_alert` passes `"clock-sync"` instead of `"tmux-health"` as
  `fail_label`): `clock-sync-check.tst.sh` rc 1, 26 pass, 1 fail
  (`17. standalone thg fail`).

The tests that name the sites (R2): `git grep -nE` over `orc/src/bash/tests/*`,
`orc/src/bash/features/*/tests/*`, `iac/src/bash/tests/*`, `utl/src/bash/tests/*` on
`992866d69`:
- Row 01 (`install-force-push-guard|do_install_force_push_guard|spl-cmd-guard-mode|do_spl_cmd_guard_mode|_scg_homes`) ->
  **`orc:src/bash/tests/spl-cmd-guard-mode.tst.sh`** (edited) and
  **`orc:src/bash/features/spool-install/tests/test-y13-force-push-guard.sh`** (checks
  `^do_install_force_push_guard()` and `DRY_RUN:-1`; 0 hits in `csi-spl-iac/` or
  `csi-spl-utl/`).
- Row 02 (`clock-sync-check|do_os_clock_sync_check|do_clock_sync_check|tmux-health-guard|do_fleet_tmux_health_guard|docker-test-container-prune`) ->
  **`utl:src/bash/tests/clock-sync-check.tst.sh`** (edited),
  `utl:src/bash/tests/tmux-health-guard.tst.sh`,
  `utl:src/bash/tests/docker-test-container-prune.tst.sh`,
  `utl:src/bash/tests/print-help.tst.sh`,
  `orc:src/bash/tests/reliability-checks-cron.tst.sh`, and
  `orc:src/bash/tests/box-name-from-cnf.tst.sh` (calls `_dtcp_box`; 0 hits in
  `features/*/tests/` or `csi-spl-iac/`).
- 30-char comment/string grep across edited sites (+/- 3 lines): only generic phrases
  (`the agent user and the box user` in `test-spawn-dry-run.sh:304` and
  `agent-settings-check.tst.sh:22,142`, neither asserting on our files). No new test file
  is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r11-01-orc-box-user-homes)` | one fact, one copy (developer guide 2.2.4) | `spl-cmd-guard-mode.func.sh:50-88` and `install-force-push-guard.func.sh:29-42` duplicate agent+box user resolution (`spool-env.inc.sh` + `spool_env_resolve` + deduplicated `users`), empty-user `FATAL`, `getent passwd` home check, and direct vs `sudo -n -u "$u" -H` execution (1.3, r10 section 7 #3) | `orc:src/bash/run/spl-cmd-guard-mode.func.sh:50-88`<br>`orc:src/bash/run/install-force-push-guard.func.sh:29-42`<br>`orc:src/bash/tests/spl-cmd-guard-mode.tst.sh:20,139` | copies of the agent+box user/home resolution and target-user exec block across `spl-cmd-guard-mode` and `install-force-push-guard` 2 -> 1 (hosted once as `_spl_box_users_resolve`, `_spl_box_user_home`, `_spl_box_user_exec` in `spl-cmd-guard-mode.func.sh`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `spl-cmd-guard-mode.tst.sh` on parent FAILs 9 checks (`rc1`, rc 1, 19 pass, 9 fail: 7 helper-missing + 2 one-copy checks naming `install-force-push-guard.func.sh:31`; all 3 standalone checks pass on base), then GREEN (`0/28/0`, +12 new checks); hermetic mutations `m1a` (`install-force-push-guard` uses `fatal` mode, rc 1, 1 fail), `m1b` (`_scg_homes` uses `fail` mode, rc 1, 1 fail), and `m1c` (`_spl_box_users_resolve` drops distinct `SPOOL_BOX_USER`, rc 1, 26 pass, 2 real `FAIL:` / `3*` fail lines) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change (exact `FAIL; rc=1; continue` vs `FATAL; return 1` missing-home handling preserved; `sudo -n -u` branch stays untested hermetically as on base). Tests: **`orc:.../spl-cmd-guard-mode.tst.sh`**, **`orc:.../features/spool-install/tests/test-y13-force-push-guard.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r11-02-utl-throttled-alert-send)` | one fact, one copy (developer guide 2.2.4) | `clock-sync-check.func.sh:203-216`, `tmux-health-guard.func.sh:152-165`, and `docker-test-container-prune.func.sh:146-159` duplicate the 14-line `*_SEND_CMD` / `PROJ_PATH` sibling `spool-send.sh` lookup, missing-sender `WARN`, `timeout -k 2` `--no-poke` send, stamp write on delivery, and sent/failed logs (1.4, wave 1 of r10 section 7 #1) | `utl:src/bash/run/clock-sync-check.func.sh:182-217`<br>`utl:src/bash/run/tmux-health-guard.func.sh:131-166`<br>`utl:src/bash/run/docker-test-container-prune.func.sh:126-160`<br>`utl:src/bash/tests/clock-sync-check.tst.sh:21,242` | copies of the 14-line throttled `*_SEND_CMD` `--no-poke` alert sender across `clock-sync-check`, `tmux-health-guard`, and `docker-test-container-prune` 3 -> 1 (hosted once as `_utl_send_throttled_alert` in `clock-sync-check.func.sh`, lazy-loaded on `DRY_RUN=0` send only) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `clock-sync-check.tst.sh` on parent FAILs 7 checks (`rc2`, rc 1, 20 pass, 7 fail: 4 helper-missing + 3 one-copy checks naming `tmux-health-guard.func.sh:154` and `docker-test-container-prune.func.sh:148`; all 4 standalone checks pass on base), then GREEN (`0/27/0`, +11 new checks); mutations `m2a` (drop `--no-poke`, rc 1, 4 fail), `m2b` (`_dtcp_note` uses `alert` instead of `note` wording, rc 1, 1 fail), and `m2c` (`tmux_health_alert` wrong `fail_label`, rc 1, 1 fail) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change (CI cost accepted: `csi-spl-utl/` runs `parts=all` once at night, 1.4). Tests: **`utl:.../clock-sync-check.tst.sh`**, `utl:.../tmux-health-guard.tst.sh`, `utl:.../docker-test-container-prune.tst.sh`, `utl:.../print-help.tst.sh`, `orc:.../reliability-checks-cron.tst.sh`, `orc:.../box-name-from-cnf.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `utl:` = `csi-spl-utl/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r11-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r11-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows consolidate internal shell helper copies with zero change to any
output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper consolidation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  across two sub-projects (row 01: `orc:src/bash/run/spl-cmd-guard-mode.func.sh`,
  `orc:src/bash/run/install-force-push-guard.func.sh`,
  `orc:src/bash/tests/spl-cmd-guard-mode.tst.sh`; row 02:
  `utl:src/bash/run/clock-sync-check.func.sh`,
  `utl:src/bash/run/tmux-health-guard.func.sh`,
  `utl:src/bash/run/docker-test-container-prune.func.sh`,
  `utl:src/bash/tests/clock-sync-check.tst.sh`).
- Neither row edits `utl:src/bash/run/reboot-required-check.func.sh`,
  `utl:src/bash/run/cron-heartbeat-snitch.func.sh` (live r10-02 `c-799`),
  `utl:src/bash/run/orphan-process-reap.func.sh`, `utl:src/bash/run/gh-runner-health.func.sh`,
  `utl:src/bash/run/net-cert-expiry-check.func.sh`,
  `utl:src/bash/run/box-beat-telemetry.func.sh`,
  `orc:src/bash/features/spool-install/steps/y13-force-push-guard.sh`,
  `orc:src/bash/features/spawn-agents/scripts/spl-cmd-guard-install.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7 edited + 3 sibling regression-run files = 10 checked via `lane-map.sh --check`
at 2026-11-27T11:30:48Z):
`orc:src/bash/run/spl-cmd-guard-mode.func.sh`,
`orc:src/bash/run/install-force-push-guard.func.sh`,
`orc:src/bash/tests/spl-cmd-guard-mode.tst.sh`,
`orc:src/bash/features/spool-install/tests/test-y13-force-push-guard.sh`,
`utl:src/bash/run/clock-sync-check.func.sh`,
`utl:src/bash/run/tmux-health-guard.func.sh`,
`utl:src/bash/run/docker-test-container-prune.func.sh`,
`utl:src/bash/tests/clock-sync-check.tst.sh`,
`utl:src/bash/tests/tmux-health-guard.tst.sh`,
`utl:src/bash/tests/docker-test-container-prune.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <paths> --agent a-629`, n=1, at
  2026-11-27T11:30:48Z: **exit 4** ("no live lane lists `<paths>`, but 24 live lane(s)
  record no files", 0 owned). All 24 `unknown:` live lanes are on the other box (15
  channel/workspace/other-repo seats `c-029`, `c-041`, `c-079`, `c-086`, `c-146`, `c-187`,
  `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-935`, `c-936`, `c-971`, plus
  `c-264` s158 P2 pin sweep, `c-704` + `c-791` SPL-6652 other-repo loop feature, `c-749` b53 panel
  seat, `c-752` s187 S1 channel move, `c-799` r10-02 `reboot-required-check` +
  `cron-heartbeat-snitch`, `c-806` p19-07 WUI perf counters, `c-819` spec 197 review, and
  `c-832` SPL-6675 WUI search panel). Verified via `do_spl_lane_map` at 11:18:26Z — live
  lanes on this box (`a-629`, `a-546` r10 planner, `a-628` r10-02 R7, `a-264` b52 planner,
  `a-604` SPL-6659 R7, `a-934` s182 planner, `c-312` / `a-556` SPL-6646 WUI issues,
  `c-314` / `a-602` SPL-6647 calendar phone, `c-309` / `a-567` s181 B14, `a-580` search
  panel) touch none of our 10 paths. No live lane owns any of the 10 paths; the holder
  re-reads at placement per R3.
- **Panel lane-map check (12:17:44Z):** panel seat `c-862` ran
  `lane-map.sh --check <7 row paths> --agent c-862` -> **exit 4** (4 `unknown:` lanes,
  none on any row path; 0 owned) and confirmed zero drift on the 7 row files up to
  `origin/master` `6a8a09e75` (re-checked up to `677e80255`: 0 drift across all 10 paths).
- **Landed row `r10-02` (rulebook 5.2 gate met):** `r10-02` (`054294929`, SPL-6672,
  `c-799`, `reboot-required-check.func.sh`, `cron-heartbeat-snitch.func.sh`,
  `reboot-required-check.tst.sh`) and round 10's close record (`c696a294d`, SPL-6649)
  have landed on `origin/master` and the box checkout with **0 overlap** with our 10
  paths. Both r10 rows are Bash-only and served; rulebook 5.2 does not hold r11 rows.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-27T11:18:29Z):
  95 queued, 0 placing (including `53de3c81` this round's claude panel seat, CI A1b/A2/A3
  refactor rows, bug lanes `d552df78` / `75b8810c` / `65bd772b`, WUI asks `f7b4d754` /
  `2b4f6cee` / `a338e1e9`, and s107/s150/s162/s169/s173/s177/s179/s185/s190/s193/s195/s196
  feature rows). None touches any of our 10 paths.
- **Briefs on this box** modified in the last 48 h matching any of our 10 paths (at
  11:30:52Z): **0 live overlapping briefs**.
- **Remote branches committed in the last 48 h** (`git for-each-ref`, at 11:30:52Z):
  167 branches checked with `git diff --name-only $(git merge-base 992866d69 <b>) <b> -- <10 paths>` ->
  **0 hits**.
- **Commits in the last 48 h** on the 10 checked paths (`git log origin/master --since='48 hours ago'`,
  at 11:30:52Z) -> **0**.

## 3. Per row: what the lane does

- **r11-01:** `orc:src/bash/run/spl-cmd-guard-mode.func.sh` extracts
  `_spl_box_users_resolve`, `_spl_box_user_home`, and `_spl_box_user_exec`, and delegates
  `_scg_homes` and `do_spl_cmd_guard_mode` to them.
  `orc:src/bash/run/install-force-push-guard.func.sh` replaces `:29-42` with lazy-load of
  `spl-cmd-guard-mode.func.sh` and calls to `_spl_box_users_resolve`,
  `_spl_box_user_home "$u" fail`, and `_spl_box_user_exec`.
  `orc:src/bash/tests/spl-cmd-guard-mode.tst.sh` adds section `8` to the header (`:20`)
  and inserts section `8` before `:139` (7 helper checks, 2 one-copy checks, and 3
  standalone hermetic checks).
- **r11-02:** `utl:src/bash/run/clock-sync-check.func.sh` extracts
  `_utl_send_throttled_alert` and delegates `clock_sync_alert` to it.
  `utl:src/bash/run/tmux-health-guard.func.sh` and
  `utl:src/bash/run/docker-test-container-prune.func.sh` replace their 14-line
  `*_SEND_CMD` delivery blocks with lazy-load of `clock-sync-check.func.sh` and a call to
  `_utl_send_throttled_alert` (`alert` default vs `note` wording).
  `utl:src/bash/tests/clock-sync-check.tst.sh` adds section `17` to the header (`:21`)
  and inserts section `17` before `:242` (4 helper checks, 3 one-copy checks, and 4
  standalone lazy-load checks).

## 4. Panel and reviewers (R7)

- Editor: **a-629** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat
  (`c002-refactor-round-11-claude-panel-seat`, queued as ask `53de3c81` at 11:18:29Z).
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-27T11:19:57Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix` at 11:19:41Z reported
    `main=agy`, `backup=claude`, `pick=agy` (`paused none`, mistral skipped on review).
    R7 review of each claude coding row goes to an **agy seat** per row (claude waiver
    backup only while agy is out of quota or paused, citing ruling `dc84300a`; never
    mistral).
  - `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 11:19:44Z picked the less-loaded box
    (152% vs 230% on this box; note agy on the other box is out of quota until 12-03 per
    brief, so agy runs on this box); `BOX_PICK_KIND=claude` at 11:19:50Z picked the other
    box (152%, `claude weekly 19%` vs `20%` on this box). The holder re-checks capacity at
    row placement.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

### 4.1 Consensus table (rulebook 3.1 / 3.2)

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `a-629` | agy | editor | v0.1 (`937716f6`) -> v1.0 | draft -> folded W1, N1-N7 | all 17 base/head suites green; shellcheck + `do_sec_shellcheck` rc 0; `rc1`/`rc2` + 6 mutations verified RED on `992866d69`; all 9 fenced `bash` blocks in v1.0 byte-identical to `937716f6` |
| `c-862` | claude | panel | `937716f6cc0d5706980b8d2c0bd24308c50feefe` (v0.1); v1.0 pending | v0.1 **PASS** (W1 folded in v1.0); v1.0 pending | seat commit `eedf5e7fe5ad952a4a8d7d827f3a3a9bf3eb13ea` (`review/c002-refactor-round-11-claude-seat`), msg `6e490bd7` / holder `3525cddb`, relay `281ecf9c`; all 7 head sha256 matched; `rc1`/`rc2` + `m1a`/`m2b` + 10 sibling suites verified; `REVIEW_LINE_SYNTAX=1` rc 0 on planner box; awaiting `c-862` sign-off on v1.0 |

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r11-01 | `c002-r11-01-orc-box-user-homes` | `refactor(r11-01-orc-box-user-homes, SPL-<row issue>): ...` | `review/r11-01` | 1 |
| r11-02 | `c002-r11-02-utl-throttled-alert-send` | `refactor(r11-02-utl-throttled-alert-send, SPL-<row issue>): ...` | `review/r11-02` | 1 |

**r11-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-cmd-guard-mode.func.sh` (replace `:50-88` with
`_spl_box_users_resolve`, `_spl_box_user_home`, `_spl_box_user_exec`, thin `_scg_homes`,
and updated `do_spl_cmd_guard_mode`),
`csi-spl-orc/src/bash/run/install-force-push-guard.func.sh` (replace `:29-42` with
lazy-load + `_spl_box_users_resolve` + `_spl_box_user_home "$u" fail` +
`_spl_box_user_exec`), and
`csi-spl-orc/src/bash/tests/spl-cmd-guard-mode.tst.sh` (header `:20`, insert section `8`
before `:139`). NOT `y13-force-push-guard.sh`, NOT `spl-cmd-guard-install.sh`, NOT
`test-y13-force-push-guard.sh`, NOT `csi-spl-utl/`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01
verbatim, 1.3's shape (verbatim blocks in 1.3); red control (`rc1`, head1's
`spl-cmd-guard-mode.tst.sh` on parent: rc 1, 19 pass, 9 fail) RED then GREEN (`0/28/0`)
in the body; hermetic mutations `m1a` (rc 1, 1 fail), `m1b` (rc 1, 1 fail), and `m1c`
(rc 1, 26 pass, 2 real `FAIL:` / `3*` fail lines) caught. Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 3 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota or
paused, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if
the claude backup is used; never mistral; re-checked at placement).

**r11-02 brief, Files: ONLY**
`csi-spl-utl/src/bash/run/clock-sync-check.func.sh` (replace `:182-217` with
`_utl_send_throttled_alert` + delegated `clock_sync_alert`),
`csi-spl-utl/src/bash/run/tmux-health-guard.func.sh` (replace `:131-166` with lazy-load +
`_utl_send_throttled_alert`),
`csi-spl-utl/src/bash/run/docker-test-container-prune.func.sh` (replace `:126-160` with
lazy-load + `_utl_send_throttled_alert ... note`), and
`csi-spl-utl/src/bash/tests/clock-sync-check.tst.sh` (header `:21`, insert section `17`
before `:242`). NOT `tmux-health-guard.tst.sh`, NOT
`docker-test-container-prune.tst.sh`, NOT `orphan-process-reap.func.sh`, NOT
`gh-runner-health.func.sh`, NOT `csi-spl-orc/`, NOT `.shellcheck-warning-baseline.txt`,
or any other file. Do: plan section 2 row 02 verbatim, 1.4's shape (verbatim blocks in
1.4); red control (`rc2`, head2's `clock-sync-check.tst.sh` on parent: rc 1, 20 pass, 7
fail) RED then GREEN (`0/27/0`) in the body; mutations `m2a` (rc 1, 4 fail), `m2b`
(rc 1, 1 fail), and `m2c` (rc 1, 1 fail) caught. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. Note (accepted): touching `csi-spl-utl/`
runs `parts=all` in CI once (`ci-doc-only.sh:124`).
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota or
paused, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if
the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the agent+box user/home resolution and target-user exec block across row 01's 2 actions (1.3) | 2 on `992866d69` (`spl-cmd-guard-mode`, `install-force-push-guard`) -> 1 (hosted once as `_spl_box_users_resolve`, `_spl_box_user_home`, `_spl_box_user_exec` in `spl-cmd-guard-mode.func.sh`) |
| copies of the 14-line throttled `*_SEND_CMD` `--no-poke` alert sender across row 02's 3 actions (1.4) | 3 on `992866d69` (`clock-sync-check`, `tmux-health-guard`, `docker-test-container-prune`) -> 1 (hosted once as `_utl_send_throttled_alert` in `clock-sync-check.func.sh`) |
| lines (`git diff --numstat` of each head) | row 01: `spl-cmd-guard-mode.func.sh` +32 -9, `install-force-push-guard.func.sh` +8 -11, `spl-cmd-guard-mode.tst.sh` +98 -0; row 02: `clock-sync-check.func.sh` +27 -15, `tmux-health-guard.func.sh` +4 -15, `docker-test-container-prune.func.sh` +4 -15, `clock-sync-check.tst.sh` +101 -0 |
| measured on | `992866d69`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `utl:src/bash/run/` two distinct spool note-sender families (`_utl_send_spool_note` vs `_utl_send_throttled_alert`) | Family A (`_utl_send_spool_note`, `reboot-required-check.func.sh:85`, `r10-02` `054294929`: `*_SEND_BIN` + `PATH`, no `timeout`/`--no-poke`/stamp, rc 1) and Family B (`_utl_send_throttled_alert`, `clock-sync-check.func.sh`, `r11-02`: `*_SEND_CMD` array + sibling only, `timeout -k 2`, `--no-poke`, stamp write, rc 0) have intentionally different contracts; kept separate so `r12` does not count them as one copy | `git show 054294929:csi-spl-utl/src/bash/run/reboot-required-check.func.sh` vs 1.4 (W1, n=1) |
| Remaining 4 `utl:src/bash/run/` `*_SEND_CMD` actions: `orphan-process-reap.func.sh:141-155`, `gh-runner-health.func.sh:293-306`, `net-cert-expiry-check.func.sh:184-196`, `box-beat-telemetry.func.sh:217-229` | `orphan-process-reap.func.sh:208` has a pre-existing `SC2071 (error)` (`[[ "$r_ts" > ... ]]`) that fails `do_sec_shellcheck` without a separate lint fix (fix first, then wave 2 in r12); `gh-runner-health.func.sh` sources `gh-box-token.func.sh` (secret-class, excluded); `net-cert-expiry-check` omits `timeout` and `--no-poke`; `box-beat-telemetry` uses `pending-note` removal instead of stamp write | `git grep -n 'SEND_CMD' 992866d69 -- csi-spl-utl/src/bash/run/`; `shellcheck -S warning -x` on each file (n=1) |
| `utl:src/bash/run/systemd-unit-health.func.sh:148-181` (`_unit_health_send`) and `cloud-sql-backup-verify.func.sh:226-245` (`_csq_send_spool`) | distinct semantics (`-x "$send_bin"` + `spool send` fallback; `systemd-unit-health` writes stamp inside `_unit_health_send`), and `cloud-sql-backup-verify.func.sh:125` carries a pre-existing `SC2155` warning (`export CLOUDSDK_CONFIG="$(...)"`); candidate for r12 after shellcheck cleanup | `shellcheck -S warning -x csi-spl-utl/src/bash/run/{systemd-unit-health,cloud-sql-backup-verify}.func.sh` (n=1) |
| `orc:src/bash/run/net-usb-tether-profiles.func.sh` and `net-wired-priority.func.sh` NM keyfile writer | both test suites mutate `install -D -m 0600` in copied `$T/red2.func.sh` files; moving the writer requires re-designing existing red controls | r10 section 7 (n=1) |
| Remaining 3 `is a linked worktree:` sites in `orc:src/bash/run/`: `spl-private-overlay-install-cron.func.sh:70-71` (secret-class), `box-peer-ssh-grant.func.sh:53`, and `spl-box-deploy.func.sh:151` | secret-class exclusion or distinct control flow and wording | r10 section 7 (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` / `*_apply`, non-matching cron installers, secret-class probe / `gcp-*` / `build-push-*` / `spl-search-*-probe` actions, PG-heavy actions | secret-class, pulls PostgreSQL into R2, or distinct semantics | r10 section 7 (n=1) |
| Candidates-file open items: `reverse-tunnel-cron.sh:23` (line 25), `agent-boot-restore` dir (line 48), `spl-desk-reply.sh` usage text (line 76), `spl-lane-mix.func.sh` stale agy wording (line 104), `_ppe_keys` (line 113), `i18n-lang-review-exempt.json:2` `_doc` (line 115), WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125), `spl-unanswered-sweep.func.sh:196` (line 133), process churn (lines 147-148), and `b52`/`b53` bug inputs (lines 153-173) | single-line doc/usage tweaks, gate-design, perf-shaped, bug-shaped, or live-cron path changes better scoped on their own; rulebook 5.1 aims at 2 rows | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (1.2 (c), n=1) |
| Spec 011 deferred/owner-decision tasks (`T001`-`T008`, `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) | each is wider than one row or awaits an owner decision | `git log 84f86ab8c..992866d69 --oneline -- csi-spl-doc/specs/011-spool-project-refactor` (0 commits; 1.2 (d), n=1) |

## 8. Changes

- v0.1 (a-629): the rows and every read on `992866d69`; both heads built in scratch
  clones; the 17-suite column of 1.5 run on base and each row's head (all 17 base, 11
  head1, and 15 head2 suites green); `shellcheck 0.10.0 -S warning -x` and
  `do_sec_shellcheck` rc 0; both red controls (`rc1`, `rc2`) and all 6 hermetic mutation
  checks (`m1a`, `m1b`, `m1c`, `m2a`, `m2b`, `m2c`) run in fresh scratch clones and
  verified RED; all helper, caller, and test hunks included verbatim in 1.3 and 1.4.
  Pushed to `review/c002-refactor-round-11-planner` (`937716f6cc0d5706980b8d2c0bd24308c50feefe`).
- v1.0 (a-629): folded cross-vendor claude panel (`c-862`, v0.1 **PASS** on
  `937716f6cc0d5706980b8d2c0bd24308c50feefe`, seat commit
  `eedf5e7fe5ad952a4a8d7d827f3a3a9bf3eb13ea` on `review/c002-refactor-round-11-claude-seat`,
  msg `6e490bd7` / holder `3525cddb`, relay `281ecf9c`) **W1** and **N1-N7** (text-only;
  zero row code or test changes; all 9 fenced `bash` blocks byte-identical to v0.1
  `937716f6`; zero drift across all 10 checked paths from `992866d69` to `origin/master`
  `677e80255`):
  - **W1 (intro, 1.2 (a)-(b), 1.4, 2.2, section 7):** updated `r10-02` to landed
    (`054294929`, SPL-6672, agy R7 `a-628` PASS; r10 closed at `c696a294d`, SPL-6649; both
    Bash-only and verified ancestors of `origin/master` and the box checkout, so rulebook
    5.2's serve gate is met), and named the two distinct `csi-spl-utl` sender families so
    `r12` does not count them as one (Family A `_utl_send_spool_note` from `r10-02` vs
    Family B `_utl_send_throttled_alert` in `r11-02`).
  - **N1:** `W` stays `2026-11-27T09:21:57+02:00` (`6f9fef225`, read once per rulebook
    5.3; `c696a294d` does not move `W`).
  - **N2 / N3 (1.4):** recorded that lazy sources only define functions
    (`func-name-unique.tst.sh` 0/2/0, no top-level side effects) and `source ... || return 0`
    is silent only on a broken tree (kept as written).
  - **N4 / N5:** noted panel box could not read the planner-box candidates file
    (unverified by panel seat) and old-cycle briefs carry 2026-11-18 mtimes on the planner
    box vs 2026-10-15 on the panel box (all before `W`).
  - **N6 / N7:** `sudo -n -u` branch untested hermetically as on base (1.3) and
    `parts=all` CI cost (1.4) accepted by panel.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-629 (agy): v0.1 (`937716f6`), v1.0 (folds W1 and N1-N7, text-only).
- Panel reviewer seat: c-862 (claude, `c002-refactor-round-11-claude-panel-seat`, seat
  `eedf5e7fe5ad952a4a8d7d827f3a3a9bf3eb13ea` on
  `review/c002-refactor-round-11-claude-seat`):
  - v0.1 `937716f6cc0d5706980b8d2c0bd24308c50feefe`: **PASS** with text-only W1 to fold in
    v1.0 and N1-N7 (msg `6e490bd7` / holder `3525cddb`, relay `281ecf9c`; all 7 head sha256
    matched; `rc1`/`rc2`, `m1a`/`m2b`, and 10 sibling suites verified;
    `REVIEW_LINE_SYNTAX=1` rc 0 on planner box).
  - v1.0: pending sign-off and holder `do_spl_review_line_check` rc 0 confirmation.
- Row R7 seats: section 4; agy per row (claude waiver backup only under ruling `dc84300a`;
  never mistral).
