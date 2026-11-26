# Refactoring round 08 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6604  
Topic: d1fcde3d-36cf-4da5-966e-548ef3655f78  
Discussion: d1fcde3d-36cf-4da5-966e-548ef3655f78 (t1 #refactoring, "Refactor round 08", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r08**, plan `refactor-round-08-plan.md` (free: 0 `refactor-round-08` files on
  `origin/master`, so no date suffix; `refactor-round-8*` are from an older single-digit
  cycle), rows `r08-<NN>`, scope `docs(r08-plan, SPL-6604)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row** (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 15:00:40Z:
  `pick=claude`, `main=claude`, `backup=agy`).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 07 ([refactor-round-07-plan.md](refactor-round-07-plan.md)
v1.0 `34d67a385`, editor `a-071`) has both rows landed on `origin/master`: `r07-01`
(`bab949a92`, SPL-6601, agy R7 `a-106` PASS) and `r07-02` (`e5af88d93`, SPL-6602, agy R7
`a-115` PASS); nothing of r07 remains unlanded (`a-071` writes r07's close record). The
perf floor (rulebook 4.4), re-measured on `e5af88d93` at 2026-11-26T15:00:39Z (14 days):
`perf 36 refactor 117 perf-share 23.5% floor-met` (5 x 36 = 180 >= 153), so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), with zero behaviour change:
- **Row 01 (`cron_refuse_linked_worktree` optional wording and remaining 3 non-secret
  callers — 5 files):** `orc:lib/bash/funcs/cron-tagged-line.func.sh:42-56` adds two
  optional backward-compatible parameters (`fatal_verb="${3:-install}"` and
  `warn_noun="${4:-the path below}"`); the remaining 3 non-secret linked-worktree
  installers (`orc:src/bash/run/install-box-crons.func.sh:55,65-70`,
  `orc:src/bash/run/spl-agent-hooks-install.func.sh:30-40`, and
  `orc:src/bash/run/spl-agent-identity-install.func.sh:35,38-45`) drop their duplicated
  inline `git-dir`/`git-common-dir` guards and unused `gd cd` locals and lazy-load
  `cron_refuse_linked_worktree` (bringing non-secret linked-worktree installers in
  `orc:src/bash/run/` from 10/13 to **13/13**), guarded by section `9` in
  `orc:src/bash/tests/cron-tagged-line.tst.sh` (which also updates the header list `:6-11`
  to cover sections 7-9, closing r07-01 R7 N1).
- **Row 02 (`_spl_user_step_install` per-user `spool-install` step runner wave 1 — 4
  files):** `orc:src/bash/run/spl-git-pager-off-install.func.sh:16-43` extracts the
  shared per-user `spool-install` step loop (`SPOOL_AGENT_USER` / `box.env` resolution,
  user deduplication, `getent passwd` home lookup, `bash -c` vs `sudo -n -u` dispatch,
  and `INFO`/`OK` logging) into `_spl_user_step_install` (with optional `home_suffix` and
  `repo` args so wave 2 in r09 can reuse it verbatim), and
  `orc:src/bash/run/spl-vibe-output-cap-install.func.sh:17-44` and
  `orc:src/bash/run/spl-vibe-push-guard-install.func.sh:18-45` drop their verbatim
  24-line copies and delegate to it (3/5 per-user `spool-install` actions consolidated),
  guarded by section `8` in
  `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`.

The two rows share no file: both are **Batch 1**.

**Status: v0.1 draft for cross-vendor panel review.** Editor: **a-121** (agy).
Cross-vendor claude panel seat (`c002-refactor-round-08-claude-panel-seat`, queued as
ask `a46d7902`) to review and sign on `review/c002-refactor-round-08-planner`.

**One sha:** every count is measured on **`e5af88d93`**
(`e5af88d937230224ba556e6f2753b0356a4a1dd0`, `origin/master` at 2026-11-26T15:00:12Z),
n=1 per command unless stated. Reads are on `e5af88d93` with `git show` / `git grep`. The
tests of 1.5 ran in scratch clones checked out at `e5af88d93` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a fresh scratch clone of its own. All helper, caller, and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 6 mutation checks byte-for-byte on `e5af88d93` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T15:00:12Z-15:00:42Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-26T15:42:29+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r07-plan'`:
  `34d67a38514d599902ca3971ebe06bb5d2995932`
  (`docs(r07-plan, SPL-6579): refactor round 07 plan v1.0 (fold W1, record N1-N6; signed by c-073 PASS on bbbbe0cfc)`),
  read once at the start as 5.3 says. Per rulebook 5.3, `W` stays fixed at this recorded
  date (`2026-11-26T15:42:29+02:00`, commit `34d67a385`); even after `a-071` lands r07's
  close record, all later R4, R6, 2.7.5, and `PRUNE_SINCE` reads for r08 must use
  `W=2026-11-26T15:42:29+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk ...` ->
  `perf 36 refactor 117 perf-share 23.5% floor-met` (5 x 36 = 180 >= 153).
- `git log origin/master --since="$W" --oneline -E --grep='\(r08-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r08-*' 'refs/heads/*-r08-*' 'refs/heads/*refactor-round-08*' 'refs/heads/wip/*r08*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r08-[0-9]{2}|refactor-round-08'` (local to
  this planner/holder box only) -> **2** briefs only: this planner's brief and the panel
  seat's brief (`c002-refactor-round-08-claude-panel-seat.md`); 0 `r08-NN` row briefs.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-08`
  -> **0** (`refactor-round-08-plan.md` is free with no date suffix per rulebook 5.3;
  `refactor-round-8*` belong to the earlier single-digit cycle).

### 1.2 The brief's inputs, re-measured

- **(a) r07 section 7:** re-read on `e5af88d93`:
  - Remaining linked-worktree guards in `orc:src/bash/run/`:
    Both `r07-01` (`bab949a92`) and `r07-02` (`e5af88d93`) have now landed on
    `origin/master`. `git grep -n "is a linked worktree:" e5af88d93 -- csi-spl-orc/src/bash/run/`
    now returns **10 lines across 6 files**:
    - 3 clean non-secret plural/verb callers that share the exact same `git-dir` vs
      `git-common-dir` refusal/warning structure as `cron_refuse_linked_worktree`:
      `install-box-crons.func.sh:68-69` (278 lines; FATAL `"install"`, WARN `"the paths
      below"`), `spl-agent-hooks-install.func.sh:37,39` (97 lines; FATAL `"run the
      install"`, WARN `"the paths below"`, uninstall warns instead of refusing), and
      `spl-agent-identity-install.func.sh:42,44` (108 lines; FATAL `"run the install"`,
      WARN `"the paths below"`, uninstall warns instead of refusing) -> **row 01** (1.3).
    - 3 remaining files kept out (section 7): `spl-private-overlay-install-cron.func.sh:70-71`
      (secret-class, names `RESERVE_GH_TOKEN_FILE`), `box-peer-ssh-grant.func.sh:53`
      (distinct one-off `"grant from..."`, no WARN branch), and
      `spl-box-deploy.func.sh:151` (distinct prereq collector `"PREREQ checkout missing"`).
  - `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and
    `spl-issue-owner-question-diss.func.sh` `*_read` / `*_apply` scaffolding: still kept
    out (section 7) because `brc_apply` (`:136-161`) and `oq_apply` (`:111-137`) differ
    semantically on `chmod 600`, `2>/dev/null` vs `2>&1`, exact status equality vs
    `done|diss`, and log lines, while cleaner exact-match duplicates exist.
  - All other r07 section 7 items (non-matching cron installers, secret-class 5 probe
    actions and `gcp-*alert*`, PG-heavy `spl-msg-{dedup,wipe}` and `spl-channel-agent-*`)
    remain accounted for in section 7.
  - Broad duplicate scan across `orc:src/bash/run/*.func.sh` on `e5af88d93` surfaced a
    clean, non-secret 5-file exact-copy family: the `spool-install` per-user step runners
    (`spl-git-pager-off-install.func.sh`, `spl-vibe-output-cap-install.func.sh`,
    `spl-vibe-push-guard-install.func.sh`, `spl-grok-memory-install.func.sh`, and
    `spl-agy-memory-install.func.sh`), each carrying the identical ~22-line `SPOOL_AGENT_USER`
    / `box.env` / `getent passwd` / dedup / `sudo -n -u` dispatch loop. The 3 two-arg
    callers (`y16`, `y15`, `y12`) form **row 02** (1.4; 4 files), leaving the 2 three-arg
    memory callers (`y18`, `y20`, 3 files) as a ready wave-2 candidate for `r09` (section 7).
- **(b) R7 notes of r07-01 and r07-02:**
  - `r07-01` (`bab949a92`, SPL-6601, agy R7 `a-106` PASS): N1 `cron-tagged-line.tst.sh:6-11`
    header comment lists sections 1..6 only (folded into **row 01** while editing that
    file); N2 commit body `Re-measure first:` line ranges off by one (cosmetic, historical).
  - `r07-02` (`e5af88d93`, SPL-6602, agy R7 `a-115` PASS on `d881eb399`): all 4 sha256s
    matched plan 1.4, 13/13 suites PASS, `rc2` and `m2a`-`m2c` matched plan 1.5; no
    refactor follow-up.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to this planner/holder
  box only; 163 lines, read 15:00Z):
  - New entries since r07 (lines 153-163): all bug-shaped for `b52` (SPL-5254 phone Back
    level 1, seat rotation sidecar poke delivery, declined bug asks, review-go `DRY_RUN=0`
    false positive, review-go missing C4 test-column check).
  - All earlier open refactor-labelled entries (lines 113 `_ppe_keys`, 115
    `i18n-lang-review-exempt.json:2`, 125 WUI entry-chunk headroom) remain accounted for in
    section 7.
- **(d) spec 011 tasks:**
  `git log 34d67a385..e5af88d93 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r07; remaining open/partial tasks (T001-T008 owner-deferred,
  T018-T021, T023, T025-T028, T031, T034) are each wider than one row or await an owner
  decision.

### 1.3 Row 01's site: `cron_refuse_linked_worktree` optional wording and remaining 3 non-secret callers (`install-box-crons`, `spl-agent-hooks-install`, `spl-agent-identity-install`)

`orc:` = `csi-spl-orc/`. On `e5af88d93`:

- `orc:lib/bash/funcs/cron-tagged-line.func.sh:42-56` hosts `cron_refuse_linked_worktree`
  (already shared by 10/10 verbatim non-secret cron installers after `r06-02`, `r07-01`,
  and `r07-02`). Adding two optional trailing parameters (`fatal_verb="${3:-install}"` and
  `warn_noun="${4:-the path below}"`) preserves every 2-arg caller byte-for-byte while
  letting the 3 remaining non-secret linked-worktree installers share the single helper:
  1. `orc:src/bash/run/install-box-crons.func.sh:55,65-70` (278 lines; allow knob
     `BOX_CRONS_ALLOW_WORKTREE:-0`, guarded on `$act == install`, FATAL verb `"install"`,
     WARN noun `"the paths below"`).
  2. `orc:src/bash/run/spl-agent-hooks-install.func.sh:30-40` (97 lines; allow knob
     `HOOKS_ALLOW_WORKTREE:-0`, uninstall `un == 1` warns instead of refusing, FATAL verb
     `"run the install"`, WARN noun `"the paths below"`).
  3. `orc:src/bash/run/spl-agent-identity-install.func.sh:35,38-45` (108 lines; allow knob
     `IDENTITY_ALLOW_WORKTREE:-0`, uninstall `un == 1` warns instead of refusing, FATAL
     verb `"run the install"`, WARN noun `"the paths below"`).
- Because `boot-cron-gate.tst.sh:60`, `test-agent-hook.sh:311`, and
  `test-agent-identity-reconcile.sh:144` source these 3 `.func.sh` files standalone
  without pre-sourcing `cron-tagged-line.func.sh`, each caller lazy-loads it inside the
  function body (`declare -F cron_refuse_linked_worktree >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/cron-tagged-line.func.sh" || return 1`),
  keeping `run-eager-files.tst.sh` unchanged.
- None of the 5 files handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `cron_refuse_linked_worktree` 12 -> 12 lines (`cron_drop_tagged_line` 20 lines,
  unchanged); `do_install_box_crons` 42 -> 40 lines; `do_spl_agent_hooks_install` 39 -> 32
  lines; `do_spl_agent_identity_install` 71 -> 65 lines.
  None of the 5 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:lib/bash/funcs/cron-tagged-line.func.sh`: replace `:42-56` to add optional
  `fatal_verb="${3:-install}"` and `warn_noun="${4:-the path below}"` and update its
  comment. 56 -> 58 lines (`+8 -6`).
- `orc:src/bash/run/install-box-crons.func.sh`: drop unused `gd cd` from `local` at `:55`;
  replace `:65-70` with `if [[ "$act" == install ]]; then` lazy-loading
  `cron-tagged-line.func.sh` and calling `cron_refuse_linked_worktree "$dry" "${BOX_CRONS_ALLOW_WORKTREE:-0}" "install" "the paths below" || return 1`.
  278 -> 276 lines (`+4 -6`).
- `orc:src/bash/run/spl-agent-hooks-install.func.sh`: drop `local gd cd` at `:30`; replace
  `:33-40` with lazy-load and `cron_refuse_linked_worktree "$([[ "$un" == 1 ]] && echo 1 || echo "$dry")" "${HOOKS_ALLOW_WORKTREE:-0}" "run the install" "the paths below" || return 1`.
  97 -> 90 lines (`+2 -9`).
- `orc:src/bash/run/spl-agent-identity-install.func.sh`: drop unused `gd cd` from `local`
  at `:35`; replace `:38-45` with lazy-load and `cron_refuse_linked_worktree "$([[ "$un" == 1 ]] && echo 1 || echo "$dry")" "${IDENTITY_ALLOW_WORKTREE:-0}" "run the install" "the paths below" || return 1`.
  108 -> 102 lines (`+3 -9`).
- `orc:src/bash/tests/cron-tagged-line.tst.sh`: add sections 7-9 to the header comment
  after `:11` (closing r07-01 R7 N1); update host one-copy grep at `:94` from literal
  `install` to `\$fatal_verb` (runtime default wording stays pinned at `:85` and `:88`);
  insert section `9` immediately before `[ "$fails" -eq 0 ]` at `:167` (3 custom-wording
  helper checks, 3 one-copy checks, and 9 standalone plural-caller linked-worktree checks
  covering `DRY_RUN=0`, `DRY_RUN=1`, and `remove`/`*_UNINSTALL=1` for all 3 callers).
  167 -> 247 lines (`+81 -1`). Total edited files: **5** (within rulebook 3.1's max 5).
- head1's files, sha256 (12 chars): `cron-tagged-line.func.sh` `35815c400147`,
  `install-box-crons.func.sh` `8e966e56793f`,
  `spl-agent-hooks-install.func.sh` `0d2593700f57`,
  `spl-agent-identity-install.func.sh` `0912482b3903`,
  `cron-tagged-line.tst.sh` `8068b26331f2`.

Verbatim helper, caller, and test hunks (head1 on `e5af88d93`):

`orc:lib/bash/funcs/cron-tagged-line.func.sh` (replace `:42-56`):
```bash
# cron_refuse_linked_worktree <dry> [allow] [fatal_verb] [warn_noun]: refuse an
# install from a linked git worktree ($PROJ_PATH vanishes with it); dry=1 warns
# and returns 0, dry=0 logs FATAL and returns 1. allow=1 skips the check (for
# tests). Optional fatal_verb (default "install") and warn_noun (default "the
# path below") preserve caller wording verbatim.
cron_refuse_linked_worktree() {
  local dry="$1" allow="${2:-0}" fatal_verb="${3:-install}" warn_noun="${4:-the path below}" gd cd
  [[ "$allow" == 1 ]] && return 0
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$gd" && "$gd" != "$cd" ]] || return 0
  if [[ "$dry" == 0 ]]; then
    do_log "FATAL $PROJ_PATH is a linked worktree: $fatal_verb from the main checkout - nothing changed"
    return 1
  fi
  echo "WARN $PROJ_PATH is a linked worktree: $warn_noun would vanish with it; install from the main checkout"
}
```

`orc:src/bash/run/install-box-crons.func.sh` (drop `gd cd` from `local` at `:55`; replace
`:65-70`):
```bash
  if [[ "$act" == install ]]; then
    declare -F cron_refuse_linked_worktree >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/cron-tagged-line.func.sh" || return 1
    cron_refuse_linked_worktree "$dry" "${BOX_CRONS_ALLOW_WORKTREE:-0}" "install" "the paths below" || return 1
  fi
```

`orc:src/bash/run/spl-agent-hooks-install.func.sh` (drop `local gd cd` at `:30`; replace
`:33-40`):
```bash
  declare -F cron_refuse_linked_worktree >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/cron-tagged-line.func.sh" || return 1
  cron_refuse_linked_worktree "$([[ "$un" == 1 ]] && echo 1 || echo "$dry")" "${HOOKS_ALLOW_WORKTREE:-0}" "run the install" "the paths below" || return 1
```

`orc:src/bash/run/spl-agent-identity-install.func.sh` (drop `gd cd` from `local` at `:35`;
replace `:38-45`):
```bash
  declare -F cron_refuse_linked_worktree >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/cron-tagged-line.func.sh" || return 1
  cron_refuse_linked_worktree "$([[ "$un" == 1 ]] && echo 1 || echo "$dry")" "${IDENTITY_ALLOW_WORKTREE:-0}" "run the install" "the paths below" || return 1
```

`orc:src/bash/tests/cron-tagged-line.tst.sh` (append to header after `:11`; update `:94`
host grep; insert section `9` immediately before `[ "$fails" -eq 0 ]` at `:167`, followed
by one blank line; `:166` is already blank):
```bash
#   7. cron_refuse_linked_worktree and wave-1 delegation (r06-02)
#   8. cron_refuse_linked_worktree wave-2 delegation (r07-01)
#   9. cron_refuse_linked_worktree optional wording and plural callers (r08-01)
```
```bash
[ "$(grep -c 'is a linked worktree: \$fatal_verb from the main checkout' "$ctl_f")" -eq 1 ] && grep -q '^cron_refuse_linked_worktree()' "$ctl_f" \
```
```bash
# 9. cron_refuse_linked_worktree optional wording and plural callers (r08-01 one copy)
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 0 "run the install" "the paths below")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" ] \
  && pass "9. cron_refuse_linked_worktree honours custom fatal_verb when dry=0" || fail "9. custom dry=0 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 1 0 "run the install" "the paths below")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" ] \
  && pass "9. cron_refuse_linked_worktree honours custom warn_noun when dry=1" || fail "9. custom dry=1 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 1 "run the install" "the paths below")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "9. cron_refuse_linked_worktree custom wording still skips when allow=1" || fail "9. custom allow=1 ($rc: $out)"

for sib in \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh"; do
  own="$(grep -nE 'is a linked worktree:|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "9. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "9. one copy $(basename "$sib"): own=[$own]"
done

# standalone plural-caller linked-worktree checks (lazy-loads cron-tagged-line.func.sh)
printf 'demo | * * * * * | demo.sh | demo.log |\n' >"$T/wt-linked/demo.manifest"
touch "$T/wt-linked/csi-spl-orc/demo.sh"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. install-box-crons refuses a linked worktree when DRY_RUN=0" || fail "9. box-crons dry=0 ($rc: $out)"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. install-box-crons warns with plural wording when DRY_RUN=1" || fail "9. box-crons dry=1 ($rc: $out)"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" BOX_CRONS_ACTION=remove DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'linked worktree' <<<"$out" \
  && pass "9. install-box-crons remove skips worktree refusal" || fail "9. box-crons remove ($rc: $out)"

mkdir -p "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/scripts"
touch "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent-hook.sh"
printf '{}\n' >"$T/hooks-set.json"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-agent-hooks-install refuses a linked worktree when DRY_RUN=0" || fail "9. hooks dry=0 ($rc: $out)"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-hooks-install warns with plural wording when DRY_RUN=1" || fail "9. hooks dry=1 ($rc: $out)"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" HOOKS_UNINSTALL=1 DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-hooks-install uninstall warns instead of refusing when DRY_RUN=0" || fail "9. hooks uninstall ($rc: $out)"

mkdir -p "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/lib" "$T/wt-linked/csi-spl-orc/lib/bash/funcs" "$T/wt-id-spool/agents"
cp "$PROJ_ROOT/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/lib/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-lock.func.sh" "$T/wt-linked/csi-spl-orc/lib/bash/funcs/"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-agent-identity-install refuses a linked worktree when DRY_RUN=0" || fail "9. identity dry=0 ($rc: $out)"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" SPOOL_TMUX_SOCKET="$T/no.sock" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; ai_tmux() { return 0; }; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-identity-install warns with plural wording when DRY_RUN=1" || fail "9. identity dry=1 ($rc: $out)"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" SPOOL_TMUX_SOCKET="$T/no.sock" IDENTITY_UNINSTALL=1 DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; ai_tmux() { return 0; }; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-identity-install uninstall warns instead of refusing when DRY_RUN=0" || fail "9. identity uninstall ($rc: $out)"
```

**Behaviour:** zero behaviour change. All 10 existing 2-arg cron installers keep their exact
default wording; all 3 plural/verb callers preserve their exact `FATAL`, `WARN`, exit
codes, `*_ALLOW_WORKTREE=1` skip, and `remove` / `*_UNINSTALL=1` behaviour (all 9
standalone installer checks pass on unmodified `base` too).

### 1.4 Row 02's site: `_spl_user_step_install` per-user `spool-install` step runner wave 1 (`spl-git-pager-off-install`, `spl-vibe-output-cap-install`, `spl-vibe-push-guard-install`)

`orc:` = `csi-spl-orc/`. On `e5af88d93`:

- Five per-user `spool-install` step actions in `orc:src/bash/run/` inline the same
  ~22-line loop: step readability check, `SPOOL_AGENT_USER` / `box.env` fallback,
  user-list deduplication, `getent passwd` home lookup, `INFO`/`OK` logging, and
  `bash -c` vs `sudo -n -u` step invocation. Wave 1 consolidates the 3 two-arg callers
  into `_spl_user_step_install` hosted in `spl-git-pager-off-install.func.sh` (adding no
  new file and no eager load, matching `_spl_simple_cron_apply` in
  `setup-box-stats-cron.func.sh` and `_spl_issue_brc_run_plan` in
  `spl-issue-blocker-rca-close.func.sh`):
  1. `orc:src/bash/run/spl-git-pager-off-install.func.sh:16-43` (43 lines; host + caller 1,
     step `y16-git-pager-off.sh`, label `"git pager off"`, `GIT_PAGER_OFF_USERS`, no home
     suffix).
  2. `orc:src/bash/run/spl-vibe-output-cap-install.func.sh:17-44` (44 lines; caller 2,
     step `y15-vibe-output-cap.sh`, label `"vibe output cap"`, `VIBE_OUTPUT_CAP_USERS`,
     home suffix `"/.vibe"`).
  3. `orc:src/bash/run/spl-vibe-push-guard-install.func.sh:18-45` (45 lines; caller 3,
     step `y12-vibe-push-guard.sh`, label `"vibe push guard"`, `VIBE_PUSH_GUARD_USERS`,
     home suffix `"/.vibe"`).
- `_spl_user_step_install` also accepts an optional 7th `repo` arg (forwarding it to the
  step function and logging `, repo $repo`), so wave 2 in `r09` (`spl-grok-memory-install`
  and `spl-agy-memory-install`) can delegate to it without modifying the host file.
- None of the 4 files handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_spl_git_pager_off_install` 28 -> 8 lines, `_spl_user_step_install` 34 lines;
  `do_spl_vibe_output_cap_install` 28 -> 10 lines; `do_spl_vibe_push_guard_install`
  28 -> 10 lines.
  None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-git-pager-off-install.func.sh`: replace `:16-43` with thin
  `do_spl_git_pager_off_install` calling `_spl_user_step_install` + the shared helper
  `_spl_user_step_install`. 43 -> 62 lines (`+30 -11`).
- `orc:src/bash/run/spl-vibe-output-cap-install.func.sh`: replace `:17-44` with lazy
  source of `spl-git-pager-off-install.func.sh` and `_spl_user_step_install` call.
  44 -> 26 lines (`+6 -24`).
- `orc:src/bash/run/spl-vibe-push-guard-install.func.sh`: replace `:18-45` with lazy
  source of `spl-git-pager-off-install.func.sh` and `_spl_user_step_install` call.
  45 -> 27 lines (`+6 -24`).
- `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`: add section 8 to
  header after `:16`; insert section `8` immediately before the summary `echo` at `:102`
  (6 direct `_spl_user_step_install` checks covering unreadable step, missing user, dedup,
  `home_suffix`, optional `repo`, and `SPOOL_BOX_ENV` fallback; 3 one-copy checks ignoring
  `#` comment lines; and 2 standalone dry-run checks for `do_spl_vibe_output_cap_install`
  and `do_spl_vibe_push_guard_install` sourced alone with stubbed `getent`).
  103 -> 159 lines (`+56 -0`). Total edited files: **4** (within rulebook 3.1's max 5).
- head2's files, sha256 (12 chars): `spl-git-pager-off-install.func.sh` `0900fd75c3b6`,
  `spl-vibe-output-cap-install.func.sh` `7bef959013de`,
  `spl-vibe-push-guard-install.func.sh` `be118d1a811a`,
  `test-y16-git-pager-off.sh` `e3554ae3158c`.

Verbatim helper, caller, and test hunks (head2 on `e5af88d93`):

`orc:src/bash/run/spl-git-pager-off-install.func.sh` (replace `:16-43`):
```bash
do_spl_git_pager_off_install() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin git || return 1
  _spl_user_step_install "git pager off" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y16-git-pager-off.sh" \
    spool_install_git_pager_off "${GIT_PAGER_OFF_USERS:-}" "$dry"
}

# _spl_user_step_install <label> <step_file> <fn> <users_override> <dry> [home_suffix] [repo]
# Runs <fn> from <step_file> for each unique user in <users_override> (default:
# SPOOL_AGENT_USER from env or box.env, plus the running user), via sudo -n -u
# for another user. Passes "$home<home_suffix>" "$dry" [repo] to <fn>.
_spl_user_step_install() {
  local label="$1" step="$2" fn="$3" users="$4" dry="$5" hsuf="${6:-}" repo="${7:-}"
  local me agent f u home target seen=" " rc=0
  local -a args=()
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  me="$(id -un)"
  if [[ -z "$users" ]]; then
    agent="${SPOOL_AGENT_USER:-}"
    f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
    if [[ -z "$agent" && -r "$f" ]]; then
      agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
    fi
    users="$agent $me"
  fi
  for u in $users; do
    [[ "$seen" == *" $u "* ]] && continue
    seen+="$u "
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { do_log "ERROR no passwd entry for $u"; rc=1; continue; }
    target="${home}${hsuf}"
    args=("$step" "$fn" "$target" "$dry")
    [[ -n "$repo" ]] && args+=("$repo")
    do_log "INFO $label: $u ($target)${repo:+, repo $repo}, DRY_RUN=$dry"
    if [[ "$u" == "$me" ]]; then
      # shellcheck disable=SC2016
      bash -c '. "$1" && "$2" "${@:3}"' _ "${args[@]}" || rc=1
    else
      # shellcheck disable=SC2016
      sudo -n -u "$u" bash -c '. "$1" && "$2" "${@:3}"' _ "${args[@]}" || rc=1
    fi
  done
  [[ "$rc" == 0 ]] && do_log "OK $label: $users (DRY_RUN=$dry)"
  return "$rc"
}
```

`orc:src/bash/run/spl-vibe-output-cap-install.func.sh` (replace `:17-44`):
```bash
do_spl_vibe_output_cap_install() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "vibe output cap" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y15-vibe-output-cap.sh" \
    spool_install_vibe_output_cap "${VIBE_OUTPUT_CAP_USERS:-}" "$dry" "/.vibe"
}
```

`orc:src/bash/run/spl-vibe-push-guard-install.func.sh` (replace `:18-45`):
```bash
do_spl_vibe_push_guard_install() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "vibe push guard" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y12-vibe-push-guard.sh" \
    spool_install_vibe_push_guard "${VIBE_PUSH_GUARD_USERS:-}" "$dry" "/.vibe"
}
```

`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh` (append to header
after `:16`; insert section `8` immediately before
`echo "--- y16 git pager off: $((n - fails))/$n passed, $skips skipped"` at `:102`,
followed by one blank line; `:101` is already blank):
```bash
#   8. _spl_user_step_install helper and wave-1 delegation (r08-02 one copy)
```
```bash
# 8. _spl_user_step_install helper and wave-1 delegation (r08-02 one copy)
me="$(id -un)"
printf 'fake_step_fn() { echo "CALL:$*"; }\n' >"$T/fake-step.sh"
printf 'SPOOL_AGENT_USER=%s\n' "$me" >"$T/box.env"
step_run() {
  env -u SPOOL_AGENT_USER SPOOL_BOX_ENV="$T/box.env" PROJ_PATH="$ORC" T_H="$T/h1" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    getent() { [ "$2" = "'"$me"'" ] && printf "x:x:0:0::%s:/bin/sh\n" "$T_H" || return 2; }
    . "$1/src/bash/run/spl-git-pager-off-install.func.sh" && _spl_user_step_install "${@:2}"' _ "$ORC" "$@" 2>&1
}
out="$(step_run "demo" "$T/no-such-step.sh" fake_step_fn "$me" 1)"; rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"FATAL the step $T/no-such-step.sh is not readable"* ]]
then pass "8. _spl_user_step_install refuses an unreadable step"; else fail "8. unreadable step ($rc: $out)"; fi
out="$(step_run "demo" "$T/fake-step.sh" fake_step_fn "no-such-user-r08" 1)"; rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"ERROR no passwd entry for no-such-user-r08"* ]]
then pass "8. _spl_user_step_install reports a missing passwd entry"; else fail "8. missing user ($rc: $out)"; fi
out="$(step_run "demo" "$T/fake-step.sh" fake_step_fn "$me $me" 1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c '^CALL:' <<<"$out")" = 1 ] && [[ "$out" == *"CALL:$T/h1 1"* ]] && [[ "$out" == *"INFO demo: $me ($T/h1), DRY_RUN=1"* ]] && [[ "$out" == *"OK demo: $me $me (DRY_RUN=1)"* ]]
then pass "8. _spl_user_step_install deduplicates users and logs INFO/OK"; else fail "8. dedup ($rc: $out)"; fi
out="$(step_run "demo" "$T/fake-step.sh" fake_step_fn "$me" 1 "/.vibe")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"CALL:$T/h1/.vibe 1"* ]] && [[ "$out" == *"INFO demo: $me ($T/h1/.vibe), DRY_RUN=1"* ]]
then pass "8. _spl_user_step_install appends optional home_suffix"; else fail "8. hsuf ($rc: $out)"; fi
out="$(step_run "demo" "$T/fake-step.sh" fake_step_fn "$me" 1 "" "$R")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"CALL:$T/h1 1 $R"* ]] && [[ "$out" == *"INFO demo: $me ($T/h1), repo $R, DRY_RUN=1"* ]]
then pass "8. _spl_user_step_install forwards optional repo arg and logs it"; else fail "8. repo ($rc: $out)"; fi
out="$(step_run "demo" "$T/fake-step.sh" fake_step_fn "" 1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c '^CALL:' <<<"$out")" = 1 ] && [[ "$out" == *"OK demo: $me $me (DRY_RUN=1)"* ]]
then pass "8. _spl_user_step_install reads SPOOL_AGENT_USER from SPOOL_BOX_ENV when users unset"; else fail "8. box.env ($rc: $out)"; fi

host_f="$ORC/src/bash/run/spl-git-pager-off-install.func.sh"
if grep -q '^_spl_user_step_install()' "$host_f" && [ "$(grep -c 's/\^SPOOL_AGENT_USER=//p' "$host_f")" -eq 1 ]
then pass "8. one copy: spl-git-pager-off-install.func.sh hosts _spl_user_step_install"; else fail "8. host one copy"; fi
for sib in \
  "$ORC/src/bash/run/spl-vibe-output-cap-install.func.sh" \
  "$ORC/src/bash/run/spl-vibe-push-guard-install.func.sh"; do
  own="$(grep -nE 's/\^SPOOL_AGENT_USER=|getent passwd|sudo -n -u' "$sib" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$own" ] && grep -q '_spl_user_step_install ' "$sib"
  then pass "8. one copy: $(basename "$sib") delegates user loop to _spl_user_step_install"
  else fail "8. one copy $(basename "$sib"): own=[$own]"; fi
done

VH="$T/vhome"; mkdir -p "$VH/.vibe"; : >"$VH/.vibe/hooks.toml"
out="$(PROJ_PATH="$ORC" VIBE_OUTPUT_CAP_USERS="$me" DRY_RUN=1 VH="$VH" bash -c '
  do_log() { echo "$*"; }; do_require_bin() { command -v "$1" >/dev/null; }
  getent() { printf "x:x:0:0::%s:/bin/sh\n" "$VH"; }
  . "$1/src/bash/run/spl-vibe-output-cap-install.func.sh" && do_spl_vibe_output_cap_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"INFO vibe output cap: $me ($VH/.vibe), DRY_RUN=1"* ]] && [[ "$out" == *"would: write the spool-output-cap"* ]] && [[ "$out" == *"OK vibe output cap: $me (DRY_RUN=1)"* ]] && [ ! -e "$VH/.vibe/spool-output-cap" ]
then pass "8. spl-vibe-output-cap-install sourced alone plans dry run via _spl_user_step_install"; else fail "8. vibe-output-cap ($rc: $out)"; fi
out="$(PROJ_PATH="$ORC" VIBE_PUSH_GUARD_USERS="$me" DRY_RUN=1 VH="$VH" bash -c '
  do_log() { echo "$*"; }; do_require_bin() { command -v "$1" >/dev/null; }
  getent() { printf "x:x:0:0::%s:/bin/sh\n" "$VH"; }
  . "$1/src/bash/run/spl-vibe-push-guard-install.func.sh" && do_spl_vibe_push_guard_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"INFO vibe push guard: $me ($VH/.vibe), DRY_RUN=1"* ]] && [[ "$out" == *"would: write the spool-push-guard"* ]] && [[ "$out" == *"OK vibe push guard: $me (DRY_RUN=1)"* ]] && [ ! -e "$VH/.vibe/spool-push-guard" ]
then pass "8. spl-vibe-push-guard-install sourced alone plans dry run via _spl_user_step_install"; else fail "8. vibe-push-guard ($rc: $out)"; fi
```

**Behaviour:** zero behaviour change. All three wave-1 installers emit their exact `FATAL`,
`ERROR`, `INFO`, and `OK` messages, keep user deduplication, `SPOOL_AGENT_USER`/`box.env`
fallback, `sudo -n -u` dispatch for other users, and return codes (both standalone vibe
action dry-run checks pass on unmodified `base` too).

### 1.5 Before and on the rows' heads

2026-11-26T15:08:35Z-15:34:07Z, n=1, as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG`
and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts; "-" means that row's head does not touch the suite's
tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/cron-tagged-line.tst.sh` | 01 | 0 / 31 / 0 | 0 / 46 / 0 (+15 new checks) | - |
| `orc:src/bash/tests/install-box-crons.tst.sh` | 01 | 0 / 40 / 0 | = | - |
| `orc:src/bash/features/spawn-agents/tests/test-agent-hook.sh` | 01 | 0 / 225 / 0 | = | - |
| `orc:src/bash/features/spawn-agents/tests/test-agent-identity-reconcile.sh` | 01 | 0 / 46 / 0 | = | - |
| `orc:src/bash/tests/boot-cron-gate.tst.sh` | 01 | 0 / 10 / 0 | = | - |
| `orc:src/bash/tests/cron-no-stack.tst.sh` | 01 | 0 / 26 / 0 | = | - |
| `orc:src/bash/tests/od-pool-replace.tst.sh` | 01 | 0 / 9 / 0 | = | - |
| `orc:src/bash/tests/reliability-checks-cron.tst.sh` | 01 | 0 / 9 / 0 | = | - |
| `orc:src/bash/tests/spl-box-deploy.tst.sh` | 01 | 0 / 36 / 0 | = | - |
| `orc:src/bash/tests/spl-box-update-install-cron.tst.sh` | 01 | 0 / 12 / 0 | = | - |
| `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh` | 01 | 0 / 29 / 0 | = | - |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 01 | 0 / 96 / 0 | = | - |
| `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh` | 02 | 0 / 11 / 0 | - | 0 / 22 / 0 (+11 new checks) |
| `orc:src/bash/features/spool-install/tests/test-y15-vibe-output-cap.sh` | 02 | 0 / 11 / 0 | - | = |
| `orc:src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh` | 02 | 0 / 11 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 45 / 0 | = | = |

Note (\*): on mutation checks `m1a`, `m1c`, and `m2a`-`m2c`, multi-line `$out` dumped
inside a `FAIL:` message includes raw `OK ...` log lines on their own lines, which
`grep -ciE '^ *(ok|pass)'` counts alongside real `PASS:` checks (broken down per mutation
below). Run `no-literal-paths.tst.sh` in a git checkout owned by the user running git (a
cross-user `/tmp` clone triggers git's `dubious ownership` guard).

`shellcheck 0.10.0 -S warning -x` on all 9 edited files (head1: 5 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own scratch clone of `e5af88d93`, reconstructed
from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `cron-tagged-line.tst.sh` on base): rc 1, 40 pass
  (31 base + all 9 standalone plural-caller checks passing on base, proving equivalence),
  6 fail (`FAIL: 7. host one copy`, `FAIL: 9. custom dry=0`, `FAIL: 9. custom dry=1`, and
  3 `FAIL: 9. one copy` checks naming `:66` in `install-box-crons.func.sh`, `:34` in
  `spl-agent-hooks-install.func.sh`, and `:39` in `spl-agent-identity-install.func.sh`);
  head1: rc 0, 46 pass, 0 fail.
- Row 02 red control (`rc2`, head2's `test-y16-git-pager-off.sh` on base): rc 1, 13 pass
  (11 base + both standalone vibe dry-run checks passing on base, proving equivalence),
  9 fail (6 `FAIL: 8.` `_spl_user_step_install: command not found` checks,
  `FAIL: 8. host one copy`, and 2 `FAIL: 8. one copy` checks naming `:27` in
  `spl-vibe-output-cap-install.func.sh` and `:28` in
  `spl-vibe-push-guard-install.func.sh`); head2: rc 0, 22 pass, 0 fail.

**Mutation checks** (n=1 each, fresh scratch clones of `e5af88d93` with head1/head2
applied, then one defect planted):
- `m1a` (`install-box-crons.func.sh` passes allow `"1"` instead of
  `"${BOX_CRONS_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 46 `ok|pass` lines
  (44 real `PASS:` + 2 dumped `OK` lines), 2 fail (`FAIL: 9. box-crons dry=0`,
  `FAIL: 9. box-crons dry=1`).
- `m1b` (`spl-agent-hooks-install.func.sh` passes allow `"1"` instead of
  `"${HOOKS_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 43 `ok|pass` lines
  (43 real `PASS:`), 3 fail (`FAIL: 9. hooks dry=0`, `FAIL: 9. hooks dry=1`,
  `FAIL: 9. hooks uninstall`).
- `m1c` (`spl-agent-identity-install.func.sh` passes allow `"1"` instead of
  `"${IDENTITY_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 46 `ok|pass` lines
  (43 real `PASS:` + 3 dumped `OK` lines), 3 fail (`FAIL: 9. identity dry=0`,
  `FAIL: 9. identity dry=1`, `FAIL: 9. identity uninstall`).
- `m2a` (`spl-vibe-output-cap-install.func.sh` omits `"/.vibe"` suffix):
  `test-y16-git-pager-off.sh` rc 1, 22 `ok|pass` lines (21 real `PASS:` + 1 dumped `OK`
  line), 1 fail (`FAIL: 8. vibe-output-cap`).
- `m2b` (`spl-vibe-push-guard-install.func.sh` omits `"/.vibe"` suffix):
  `test-y16-git-pager-off.sh` rc 1, 22 `ok|pass` lines (21 real `PASS:` + 1 dumped `OK`
  line), 1 fail (`FAIL: 8. vibe-push-guard`).
- `m2c` (`_spl_user_step_install` in `spl-git-pager-off-install.func.sh` skips dedup):
  `test-y16-git-pager-off.sh` rc 1, 22 `ok|pass` lines (20 real `PASS:` + 2 dumped `OK`
  lines), 2 fail (`FAIL: 8. dedup`, `FAIL: 8. box.env`).

The tests that name the sites (R2): `git grep -lE` over `*tst.sh`, `features/*/tests/*`,
`csi-spl-iac/src/bash/tests/`, and `csi-spl-api/` on `e5af88d93`:
- Row 01 (`cron-tagged-line|cron_refuse_linked_worktree|install-box-crons|do_install_box_crons|spl-agent-hooks-install|do_spl_agent_hooks_install|spl-agent-identity-install|do_spl_agent_identity_install`) ->
  **`orc:src/bash/tests/cron-tagged-line.tst.sh`** (edited),
  `orc:src/bash/tests/install-box-crons.tst.sh` (which runs `box-crons-desk-reach.py`),
  `orc:src/bash/features/spawn-agents/tests/test-agent-hook.sh`,
  `orc:src/bash/features/spawn-agents/tests/test-agent-identity-reconcile.sh`,
  `orc:src/bash/tests/boot-cron-gate.tst.sh`, `orc:src/bash/tests/cron-no-stack.tst.sh`,
  `orc:src/bash/tests/od-pool-replace.tst.sh`,
  `orc:src/bash/tests/reliability-checks-cron.tst.sh`,
  `orc:src/bash/tests/spl-box-deploy.tst.sh`,
  `orc:src/bash/tests/spl-box-update-install-cron.tst.sh`,
  **`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`**, and
  **`iac:src/bash/tests/satellite-ansible.tst.sh`** (`:405,410` names
  `spl-agent-identity-install.func.sh`; 0 hits in `csi-spl-api/`).
- Row 02 (`spl-git-pager-off-install|do_spl_git_pager_off_install|spl-vibe-output-cap-install|do_spl_vibe_output_cap_install|spl-vibe-push-guard-install|do_spl_vibe_push_guard_install|_spl_user_step_install`) ->
  **`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`** (edited), plus
  the sibling step suites
  `orc:src/bash/features/spool-install/tests/test-y15-vibe-output-cap.sh` (also wrapped by
  `spool-install-y15-vibe-output-cap.tst.sh`) and
  `orc:src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh` (also wrapped by
  `spool-install-y12-vibe-push-guard.tst.sh`; 0 hits in `csi-spl-iac/` or `csi-spl-api/`).
- 30-char comment grep across all edited sites (+/- 3 lines): only
  `test-agent-identity-reconcile.sh:180`, `cron-tagged-line.tst.sh:88,115,144`, and
  `spl-cost-labels-translate-install-cron.tst.sh:182,197` (all already in row 01's test
  column). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r08-01-orc-worktree-guard-plural)` | one fact, one copy (developer guide 2.2.4) | `install-box-crons.func.sh:65-70`, `spl-agent-hooks-install.func.sh:33-40`, and `spl-agent-identity-install.func.sh:38-45` are the last 3 non-secret linked-worktree guards in `orc:src/bash/run/`, differing from `cron_refuse_linked_worktree` (`orc:lib/bash/funcs/cron-tagged-line.func.sh:45-56`) only in optional plural/verb wording (1.3, r07 section 7 #1); also updates `cron-tagged-line.tst.sh:6-11` header (r07-01 R7 N1) | `orc:lib/bash/funcs/cron-tagged-line.func.sh:42-56`<br>`orc:src/bash/run/install-box-crons.func.sh:55,65-70`<br>`orc:src/bash/run/spl-agent-hooks-install.func.sh:30-40`<br>`orc:src/bash/run/spl-agent-identity-install.func.sh:35,38-45`<br>`orc:src/bash/tests/cron-tagged-line.tst.sh:11,94,167` | copies of the non-secret linked-worktree guard across these 3 installers 3 -> 0 (delegating to `cron_refuse_linked_worktree`; completes 13/13 non-secret linked-worktree installers in `orc:src/bash/run/`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `cron-tagged-line.tst.sh` on parent FAILs 6 checks (`rc1`, rc 1, 40 pass, 6 fail: host one copy, 2 custom wording checks, 3 caller one-copy checks naming `:66`, `:34`, `:39`; all 9 standalone caller checks pass on base), then GREEN (`0/46/0`); mutations `m1a` (`install-box-crons` `allow=1`, rc 1 `46*/2`), `m1b` (`spl-agent-hooks-install` `allow=1`, rc 1 `43/3`), and `m1c` (`spl-agent-identity-install` `allow=1`, rc 1 `46*/3`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 15 new checks in `cron-tagged-line.tst.sh`. Tests: **`orc:.../cron-tagged-line.tst.sh`**, `orc:.../install-box-crons.tst.sh`, `orc:.../features/spawn-agents/tests/test-agent-hook.sh`, `orc:.../features/spawn-agents/tests/test-agent-identity-reconcile.sh`, `orc:.../boot-cron-gate.tst.sh`, `orc:.../cron-no-stack.tst.sh`, `orc:.../od-pool-replace.tst.sh`, `orc:.../reliability-checks-cron.tst.sh`, `orc:.../spl-box-deploy.tst.sh`, `orc:.../spl-box-update-install-cron.tst.sh`, **`orc:.../spl-cost-labels-translate-install-cron.tst.sh`**, **`iac:.../satellite-ansible.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r08-02-orc-spool-install-user-loop)` | one fact, one copy (developer guide 2.2.4) | `spl-git-pager-off-install.func.sh:20-42`, `spl-vibe-output-cap-install.func.sh:21-43`, and `spl-vibe-push-guard-install.func.sh:22-44` duplicate the identical ~22-line per-user `spool-install` step dispatch loop (`SPOOL_AGENT_USER`/`box.env`, dedup, `getent passwd`, `bash -c` vs `sudo -n -u`, `INFO`/`OK` logs) (1.4) | `orc:src/bash/run/spl-git-pager-off-install.func.sh:16-43`<br>`orc:src/bash/run/spl-vibe-output-cap-install.func.sh:17-44`<br>`orc:src/bash/run/spl-vibe-push-guard-install.func.sh:18-45`<br>`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh:16,102` | copies of the per-user `spool-install` step loop across these 3 actions 3 -> 1 (hosted once as `_spl_user_step_install`; 3/5 per-user `spool-install` actions consolidated, wave-2 ready for `r09`) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `test-y16-git-pager-off.sh` on parent FAILs 9 checks (`rc2`, rc 1, 13 pass, 9 fail: 6 `_spl_user_step_install` checks, host one copy, 2 caller one-copy checks naming `:27`, `:28`; both standalone vibe dry-run checks pass on base), then GREEN (`0/22/0`); mutations `m2a` (`vibe-output-cap` drops `"/.vibe"`, rc 1 `22*/1`), `m2b` (`vibe-push-guard` drops `"/.vibe"`, rc 1 `22*/1`), and `m2c` (`_spl_user_step_install` skips dedup, rc 1 `22*/2`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 11 new checks in `test-y16-git-pager-off.sh`. Tests: **`orc:.../features/spool-install/tests/test-y16-git-pager-off.sh`**, `orc:.../features/spool-install/tests/test-y15-vibe-output-cap.sh`, `orc:.../features/spool-install/tests/test-y12-vibe-push-guard.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r08-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r08-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows consolidate internal shell helper copies with zero change to any
output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper consolidation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  (row 01: `cron-tagged-line.func.sh`, `install-box-crons.func.sh`,
  `spl-agent-hooks-install.func.sh`, `spl-agent-identity-install.func.sh`,
  `cron-tagged-line.tst.sh`; row 02: `spl-git-pager-off-install.func.sh`,
  `spl-vibe-output-cap-install.func.sh`, `spl-vibe-push-guard-install.func.sh`,
  `test-y16-git-pager-off.sh`).
- Neither row edits `orc:src/bash/run/spl-grok-memory-install.func.sh`,
  `orc:src/bash/run/spl-agy-memory-install.func.sh`,
  `orc:src/bash/run/spl-private-overlay-install-cron.func.sh`,
  `orc:src/bash/run/box-peer-ssh-grant.func.sh`, `orc:src/bash/run/spl-box-deploy.func.sh`,
  `orc:src/bash/run/spl-review-go.func.sh`, `orc:src/bash/tests/spl-review-go.tst.sh`,
  `orc:src/bash/run/spl-unanswered-sweep.func.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/`,
  `csi-spl-iac/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9 edited + 15 sibling regression-run / step-test files = 24 checked across two
`lane-map.sh --check` calls at 15:04:28Z and 15:06:11Z, plus 3 wave-2 candidate paths
checked at 15:04:28Z):
`orc:lib/bash/funcs/cron-tagged-line.func.sh`,
`orc:src/bash/run/install-box-crons.func.sh`,
`orc:src/bash/run/spl-agent-hooks-install.func.sh`,
`orc:src/bash/run/spl-agent-identity-install.func.sh`,
`orc:src/bash/tests/cron-tagged-line.tst.sh`,
`orc:src/bash/tests/install-box-crons.tst.sh`,
`orc:src/bash/features/spawn-agents/tests/test-agent-hook.sh`,
`orc:src/bash/features/spawn-agents/tests/test-agent-identity-reconcile.sh`,
`orc:src/bash/tests/boot-cron-gate.tst.sh`,
`orc:src/bash/tests/cron-no-stack.tst.sh`,
`orc:src/bash/tests/od-pool-replace.tst.sh`,
`orc:src/bash/tests/reliability-checks-cron.tst.sh`,
`orc:src/bash/tests/spl-box-deploy.tst.sh`,
`orc:src/bash/tests/spl-box-update-install-cron.tst.sh`,
`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`,
`iac:src/bash/tests/satellite-ansible.tst.sh`;
`orc:src/bash/run/spl-git-pager-off-install.func.sh`,
`orc:src/bash/run/spl-vibe-output-cap-install.func.sh`,
`orc:src/bash/run/spl-vibe-push-guard-install.func.sh`,
`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`,
`orc:src/bash/features/spool-install/tests/test-y15-vibe-output-cap.sh`,
`orc:src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh`,
`orc:src/bash/tests/spool-install-y15-vibe-output-cap.tst.sh`,
`orc:src/bash/tests/spool-install-y12-vibe-push-guard.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <paths> --agent a-121`, n=1, at
  2026-11-26T15:04:28Z and 15:06:11Z: **exit 4** ("no live lane lists <paths>, but 19 live
  lane(s) record no files", 0 owned). All 19 `unknown:` live lanes are on the other box
  (14 channel/workspace/other-repo seats `c-029`, `c-041`, `c-079`, `c-086`, `c-146`,
  `c-187`, `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`, `c-971`, plus
  `c-068` WUI loops dialog, `c-141` WUI multicast composer, `c-904` s187 S1 rdb+store,
  and `c-957`/`c-965` spec 125 doc/R7 seats). Verified via `do_spl_lane_map` at
  15:00:57Z — live lanes on this box (`a-121`, `a-071`/`c-073`/`a-115` r07 close/R7,
  `a-104`/`c-092` b51-03 `spl-review-go`, `c-119` WUI sorted window, `a-099` WUI loops,
  `a-113` s153 Q3 hub/store, `a-934` s182 planner) touch none of our 24 paths. No live
  lane owns any of the 24 paths; the holder re-reads at placement per R3.
- **Bug round 52 beside us:** `git ls-remote origin 'refs/heads/*bug-round-52*' 'refs/heads/review/b52-*'`
  at 15:05:17Z -> empty (not opened yet); its candidates-file inputs (lines 153-163:
  SPL-5254 WUI, seat rotation poke, `spl-review-go`) have **0 overlap** with our 24 paths.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T15:01:00Z):
  24 queued, 0 placing (`d7095240` s150 B14, `795601c1` s150 B15a, `5b1b7d82`/`f7fc5d63`
  s186 M9, `31e5b40d`/`ddd4341f` s186 M8, `5bfe6fb5` s186 M7, `b21c97dd` s181 B14,
  `a46d7902` this round's claude panel seat, `49357202`/`e43a7b02` other-repo
  heartbeat/loop, `e1b5cc30`/`646c3169` s185 planner/panel, `2f0b0279` s192 L3,
  `9d46cd51` s150 B17, `5a432cc3` Qto PDF export, `8ccf6c03` SPL-5883 store tags,
  `a371d84c` blog draft, `6929f8d4` SPL-5309 costs share,
  `0bac0950`/`a2f1f200`/`f7985ac2` s039 T017a/d/e, `4a4e4f2d` s177 B1, `682c5529` s177 B3).
  None touches any of our 24 paths.
- **Unlanded rows from r07:** **0** (`r07-01` landed `bab949a92`, `r07-02` landed
  `e5af88d93`).
- **Briefs on this box** modified in the last 24 h matching any of the 9 edited paths
  (at 15:05:17Z): only already-landed r06/r07 briefs, `b51` planner, and this r08 planner
  brief; **0 live overlapping briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 15:05:17Z):
  `git diff --name-only $(git merge-base e5af88d93 <b>) <b> -- <the 9 edited paths>` ->
  only `origin/review/r06-02` (landed `984b6d70d`) and `origin/review/r07-01` (landed
  `bab949a92`); **0 unlanded branches**.
- **Commits in the last 24 h** on the 9 edited paths (`git log e5af88d93 --since='24 hours ago'`,
  at 15:05:17Z) -> 2 landed commits (`bab949a92` r07-01, `984b6d70d` r06-02); 0 unlanded
  churn.

## 3. Per row: what the lane does

- **r08-01:** `orc:lib/bash/funcs/cron-tagged-line.func.sh` adds optional `fatal_verb`
  (default `"install"`) and `warn_noun` (default `"the path below"`) parameters to
  `cron_refuse_linked_worktree`. `orc:src/bash/run/install-box-crons.func.sh`,
  `orc:src/bash/run/spl-agent-hooks-install.func.sh`, and
  `orc:src/bash/run/spl-agent-identity-install.func.sh` each drop unused `gd cd` locals
  and their inline `git-dir`/`git-common-dir` guards, lazy-load `cron-tagged-line.func.sh`,
  and call `cron_refuse_linked_worktree` with their exact verb/noun and uninstall/action
  semantics. `orc:src/bash/tests/cron-tagged-line.tst.sh` updates its header comment
  (`:11`) and host grep (`:94`) and appends section `9` (3 custom-wording helper checks,
  3 one-copy checks, and 9 standalone plural-caller linked-worktree checks).
- **r08-02:** `orc:src/bash/run/spl-git-pager-off-install.func.sh` extracts
  `_spl_user_step_install` (with optional `home_suffix` and `repo` args) and calls it from
  `do_spl_git_pager_off_install`. `orc:src/bash/run/spl-vibe-output-cap-install.func.sh`
  and `orc:src/bash/run/spl-vibe-push-guard-install.func.sh` each drop their duplicated
  24-line user loop, lazy-load `spl-git-pager-off-install.func.sh`, and call
  `_spl_user_step_install` with `"/.vibe"`.
  `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh` updates its header
  comment (`:16`) and inserts section `8` before `:102` (6 helper checks, 3 one-copy
  checks, and 2 standalone dry-run checks for the vibe actions).

## 4. Panel and reviewers (R7)

- Editor: **a-121** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat (`c002-refactor-round-08-claude-panel-seat`,
  queued as ask `a46d7902` at 15:01:00Z). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T15:01:57Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 15:01:55Z (`pick=agy`, `main=agy`, `backup=claude`; mistral sits on no review), R7
    review of a claude coding row goes to an **agy seat** per row (claude waiver backup
    only while agy is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 15:02:08Z picked this box (166% < 180%
    overflow, `agy weekly unknown`, placed anyway); the holder re-checks agy capacity at
    row placement and uses the claude waiver backup only if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

### 4.1 Consensus table (rulebook 3.1 / 3.2)

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `a-121` | agy | editor | v0.1 (this commit) | draft | submitted to cross-vendor panel |
| claude panel seat (`a46d7902`) | claude | panel | pending | pending | queued as `c002-refactor-round-08-claude-panel-seat` |

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r08-01 | `c002-r08-01-orc-worktree-guard-plural` | `refactor(r08-01-orc-worktree-guard-plural, SPL-<row issue>): ...` | `review/r08-01` | 1 |
| r08-02 | `c002-r08-02-orc-spool-install-user-loop` | `refactor(r08-02-orc-spool-install-user-loop, SPL-<row issue>): ...` | `review/r08-02` | 1 |

**r08-01 brief, Files: ONLY**
`csi-spl-orc/lib/bash/funcs/cron-tagged-line.func.sh` (replace `:42-56` to add optional
`fatal_verb` and `warn_noun` args to `cron_refuse_linked_worktree`),
`csi-spl-orc/src/bash/run/install-box-crons.func.sh` (drop `gd cd` at `:55`, replace
`:65-70` with lazy-load + `cron_refuse_linked_worktree` call on `$act == install`),
`csi-spl-orc/src/bash/run/spl-agent-hooks-install.func.sh` (drop `local gd cd` at `:30`,
replace `:33-40` with lazy-load + `cron_refuse_linked_worktree` call),
`csi-spl-orc/src/bash/run/spl-agent-identity-install.func.sh` (drop `gd cd` at `:35`,
replace `:38-45` with lazy-load + `cron_refuse_linked_worktree` call), and
`csi-spl-orc/src/bash/tests/cron-tagged-line.tst.sh` (header `:11`, host grep `:94`,
insert section `9` before `:167`). NOT `spl-private-overlay-install-cron.func.sh`, NOT
`box-peer-ssh-grant.func.sh`, NOT `spl-box-deploy.func.sh`, NOT
`spl-git-pager-off-install.func.sh`, NOT `spl-vibe-output-cap-install.func.sh`, NOT
`spl-vibe-push-guard-install.func.sh`, NOT `test-y16-git-pager-off.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01 verbatim,
1.3's shape (verbatim blocks in 1.3); red control (`rc1`, head1's
`cron-tagged-line.tst.sh` on parent) RED then GREEN in the body; mutations `m1a`/`m1b`/`m1c`
caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota, valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

**r08-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-git-pager-off-install.func.sh` (replace `:16-43` with thin
`do_spl_git_pager_off_install` + `_spl_user_step_install`),
`csi-spl-orc/src/bash/run/spl-vibe-output-cap-install.func.sh` (replace `:17-44` with
lazy-load + `_spl_user_step_install` call),
`csi-spl-orc/src/bash/run/spl-vibe-push-guard-install.func.sh` (replace `:18-45` with
lazy-load + `_spl_user_step_install` call), and
`csi-spl-orc/src/bash/features/spool-install/tests/test-y16-git-pager-off.sh` (header
`:16`, insert section `8` before `:102`). NOT `spl-grok-memory-install.func.sh`, NOT
`spl-agy-memory-install.func.sh`, NOT `cron-tagged-line.func.sh`, NOT
`install-box-crons.func.sh`, NOT `spl-agent-hooks-install.func.sh`, NOT
`spl-agent-identity-install.func.sh`, NOT `cron-tagged-line.tst.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02 verbatim,
1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head2's
`test-y16-git-pager-off.sh` on parent) RED then GREEN in the body; mutations
`m2a`/`m2b`/`m2c` caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the
worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota, valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the non-secret linked-worktree guard across row 01's 3 plural/verb callers (1.3) | 3 on `e5af88d93` (`install-box-crons`, `spl-agent-hooks-install`, `spl-agent-identity-install`) -> 0 (delegating to `cron_refuse_linked_worktree`; **13/13** non-secret linked-worktree installers in `orc:src/bash/run/` consolidated) |
| copies of the per-user `spool-install` step loop across row 02's 3 wave-1 actions (1.4) | 3 on `e5af88d93` (`spl-git-pager-off-install`, `spl-vibe-output-cap-install`, `spl-vibe-push-guard-install`) -> 1 (hosted once as `_spl_user_step_install`; 3/5 per-user `spool-install` actions consolidated) |
| lines (`git diff --numstat` of each head) | row 01: `cron-tagged-line.func.sh` +8 -6, `install-box-crons.func.sh` +4 -6, `spl-agent-hooks-install.func.sh` +2 -9, `spl-agent-identity-install.func.sh` +3 -9, `cron-tagged-line.tst.sh` +81 -1; row 02: `spl-git-pager-off-install.func.sh` +30 -11, `spl-vibe-output-cap-install.func.sh` +6 -24, `spl-vibe-push-guard-install.func.sh` +6 -24, `test-y16-git-pager-off.sh` +56 -0 |
| measured on | `e5af88d93`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `_spl_user_step_install` wave 2 (first candidate for `r09`, 3 files): `orc:src/bash/run/spl-grok-memory-install.func.sh:29-49` (50 lines) and `orc:src/bash/run/spl-agy-memory-install.func.sh:31-51` (52 lines), plus `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh` (or `test-y20-agy-memory.sh`) | depends on `r08-02` landing `_spl_user_step_install` (which already supports the optional 7th `repo` arg), and rulebook 5.1 aims at 2 rows per round; also carries a small shared 5-line `git-common-dir` -> `dirname` repo-derivation block | `git grep -n "s/\^SPOOL_AGENT_USER=//p" e5af88d93 -- csi-spl-orc/src/bash/run/` (5 matching `spool-install` actions: 3 taken in r08-02, 2 here) (n=1) |
| `orc:src/bash/run/wui-{build,dev,test}.func.sh` (3 files, identical 7-line `pnpm` + `$APP_PATH/csi-spl-wui` + `node_modules` install preamble; candidate for `r09`) | left for `r09` (rulebook 5.1 aims at 2 rows; r08 already has 2 disjoint Batch 1 rows) | duplicate block scan on `e5af88d93` (`wui-build.func.sh:11-17`, `wui-dev.func.sh:12-18`, `wui-test.func.sh:7-13`) (n=1) |
| Remaining 3 `is a linked worktree:` sites in `orc:src/bash/run/`: `spl-private-overlay-install-cron.func.sh:70-71` (names `RESERVE_GH_TOKEN_FILE`, secret-class), `box-peer-ssh-grant.func.sh:53` (one-off `"grant from..."`, no WARN branch), and `spl-box-deploy.func.sh:151` (prereq collector `"PREREQ checkout missing"`) | `spl-private-overlay-install-cron` stays out per the brief's secret-class exclusion; the other two have distinct control flow and wording | `git grep -n "is a linked worktree:" e5af88d93 -- csi-spl-orc/src/bash/run/` (10 lines across 6 files: 3 taken in r08-01, 3 here) (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` (`brc:91-96` vs `oq:62-68`) and `*_apply` (`brc:136-161` vs `oq:111-137`) scaffolding (r04-r07 section 7) | semantic differences in `*_apply` (`chmod 600`, `2>/dev/null` vs `2>&1`, status predicate, log/undo headers) and `do_spl_cloud_cnf` placement in `*_read` | r07 section 7; re-read on `e5af88d93` (n=1) |
| Remaining non-matching cron installers (`spl-dispatch-rotate`, `spl-agent-boot-restore`, `spl-box-restart`, `spl-peer-crons`), secret-class 5 probe actions (`spl-*-probe.func.sh`), secret-class `gcp-*alert*` and `spl-{domain-verify,lb-absent-check,wait-for-firebase-domain,wait-for-mapping-cert}.func.sh` (`--key-file`), PG-heavy `spl-msg-{dedup,wipe}` and `spl-channel-agent-*` | each is secret-class, pulls PostgreSQL into R2, or has non-matching cron semantics | r07 section 7; duplicate block scan on `e5af88d93` (n=1) |
| Candidates-file open items: `_ppe_keys` exact-key in `iac:src/bash/run/check-pre-push-e2e.func.sh:121` (line 113), `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` saying `Lang-review: a-NNN` (line 115), WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125), other-box process churn (lines 147-148), and `b52` bug inputs (lines 153-163) | `_ppe_keys` is gate-design input; `i18n-lang-review-exempt.json:2` is a 1-line JSON doc comment; entry-chunk headroom and process churn are perf-shaped; lines 153-163 are bug-shaped for `b52` | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (1.2 (c), n=1) |
| Spec 011 deferred/owner-decision tasks (`T001`-`T008`, `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) | each is wider than one row or awaits an owner decision | `git log 34d67a385..e5af88d93 --oneline -- csi-spl-doc/specs/011-spool-project-refactor` (0 commits; 1.2 (d), n=1) |

## 8. Changes

- v0.1 (a-121): the rows and every read on `e5af88d93`; both heads built in scratch
  clones; the 24-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; both red controls
  (`rc1`, `rc2`) and all 6 mutation checks (`m1a`, `m1b`, `m1c`, `m2a`, `m2b`, `m2c`) run
  in fresh scratch clones and verified RED; all helper, caller, and test hunks included
  verbatim in 1.3 and 1.4. Pushed to `review/c002-refactor-round-08-planner`.
