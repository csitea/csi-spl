# Refactoring round 09 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6632  
Topic: ea4cd052-d639-4f7a-a3eb-26e1c6a65b87  
Discussion: ea4cd052-d639-4f7a-a3eb-26e1c6a65b87 (t1 #refactoring, "Refactor round 09", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r09**, plan `refactor-round-09-plan.md` (free: 0 `refactor-round-09` files on
  `origin/master`, so no date suffix; `refactor-round-9*` are from an older single-digit
  cycle), rows `r09-<NN>`, scope `docs(r09-plan, SPL-6632)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
  `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 22:52:59Z reported
  `main=claude`, `backup=agy`, `pick=agy` (`agy` 5/11 = 45% vs 56% effective weight,
  `claude` 5/11 = 45% vs 44%); per R14 (established vendor for coding rows) and the brief
  (cross-vendor `agy` R7 for `claude` code rows), both rows are assigned **vendor claude**
  with **agy R7** (the holder may swap a row to `agy` with `claude` R7 at placement if
  preferred).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 08 ([refactor-round-08-plan.md](refactor-round-08-plan.md),
editor `a-121`) is closed (`26c6b91ed`, SPL-6604): both rows landed on `origin/master`
with cross-vendor agy R7 PASS (`r08-01` `761e1275f`, SPL-6618; `r08-02` `48431f0f5`,
SPL-6621); nothing of r08 remains unlanded. The perf floor (rulebook 4.4), re-measured on
`ecc05e480` at 2026-11-26T22:52:55Z (14 days):
`perf 36 refactor 114 perf-share 24.0% floor-met` (5 x 36 = 180 >= 150), so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), with zero behaviour change:
- **Row 01 (`_spl_memory_step_install` and `_spl_user_step_install` wave 2 — 3 files):**
  `orc:src/bash/run/spl-grok-memory-install.func.sh:18-50` extracts
  `_spl_memory_step_install` (shared `DRY_RUN` validation, step readability check, and
  `git-common-dir` -> `dirname` main-worktree repo derivation) and delegates the per-user
  dispatch loop to `_spl_user_step_install` (landed in `r08-02` `48431f0f5` with the
  optional 7th `repo` arg; closes r08 panel N2 and r08-02 R7 N1), and
  `orc:src/bash/run/spl-agy-memory-install.func.sh:20-52` lazy-loads and calls
  `_spl_memory_step_install` (bringing per-user `spool-install` actions in
  `orc:src/bash/run/` from 3/5 to **5/5**, and memory repo derivation from 2 to 1),
  guarded by section `10` in
  `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh`.
- **Row 02 (`_wui_prepare` WUI pnpm/directory preamble — 4 files):**
  `orc:src/bash/run/wui-dev.func.sh:10-25` extracts `_wui_prepare` (verifying `pnpm` and
  `$APP_PATH/csi-spl-wui`, running `pnpm install` when `node_modules` is absent, and
  setting caller-scoped `WUI_DIR`; hosted in `wui-dev.func.sh` so existing
  `wui-actions.tst.sh:18` `csi-spl-wui` check stays green unchanged), and
  `orc:src/bash/run/wui-build.func.sh:10-22` and
  `orc:src/bash/run/wui-test.func.sh:6-16` lazy-load `wui-dev.func.sh` and delegate to
  `_wui_prepare` (3/3 WUI local `pnpm` actions consolidated), guarded by new helper,
  one-copy, and standalone checks in `orc:src/bash/tests/wui-actions.tst.sh`.

The two rows share no file: both are **Batch 1**.

**Status: closed.** Both rows landed on `origin/master` with cross-vendor agy R7 PASS
(`r09-01` `2305d56ec` SPL-6640, `r09-02` `a1db1addf` SPL-6641; section 8). Editor:
**a-260** (agy). Plan v1.0 (`861ad6d57`) was signed by cross-vendor claude panel seat
**c-342** (`0c05b9703265e99a4676421edf6af5ea7aeeaba1`, seat commit `11960d121`, msg
`e0eebeaa` / holder `46cbe558`; `do_spl_review_line_check` rc 0 on panel box,
`REVIEW_LINE_SYNTAX=1` rc 0 on planner box; dispatch holder `c-002` GO LAND `b1c5f03e`).
Zero drift on all 7 row files from `ecc05e480` to `origin/master` `39bb380f8` at plan
v1.0, and zero drift on all 7 edited files from their landed shas (`2305d56ec`,
`a1db1addf`) to `origin/master` `dd3588e4d` at close.

**One sha:** every count is measured on **`ecc05e480`**
(`ecc05e480b429bb9385725a257bc15f7d21a79de`, `origin/master` at 2026-11-26T22:52:26Z),
n=1 per command unless stated. Reads are on `ecc05e480` with `git show` / `git grep`. The
tests of 1.5 ran in scratch clones checked out at `ecc05e480` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a fresh scratch clone of its own. All helper, caller, and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 7 mutation checks byte-for-byte on `ecc05e480` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T22:52:31Z-22:53:01Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-27T00:36:21+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r08-plan'`:
  `26c6b91eddaa182cb36b2390950fa560a9618033`
  (`docs(r08-plan, SPL-6604): refactor round 08 closed: r08-01 761e1275f and r08-02 48431f0f5 landed, agy R7 PASS each`),
  read once at the start as 5.3 says. All later R4, R6, 2.7.5, and `PRUNE_SINCE` reads
  for r09 use `W=2026-11-27T00:36:21+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'` ->
  `perf 36 refactor 114 perf-share 24.0% floor-met` (5 x 36 = 180 >= 150; re-measured by
  panel at 23:18:03Z -> `perf 36 refactor 113 perf-share 24.2% floor-met`).
- `git log origin/master --since="$W" --oneline -E --grep='\(r09-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r09-*' 'refs/heads/*-r09-*' 'refs/heads/*refactor-round-09*' 'refs/heads/wip/*r09*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r09-[0-9]{2}|refactor-round-09'` (local to
  this planner/holder box only) -> **2** briefs only: this planner's brief and the panel
  seat's brief (`c002-refactor-round-09-claude-panel-seat.md`); 0 `r09-NN` row briefs
  (unrelated briefs carrying `-r09-` for other round names, such as animation or restart
  rounds, are not refactor rows).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-09`
  -> **0** (`refactor-round-09-plan.md` is free with no date suffix per rulebook 5.3;
  `refactor-round-9*` belong to the earlier single-digit cycle).

### 1.2 The brief's inputs, re-measured

- **(a) r08 section 7:** re-read on `ecc05e480`:
  - `_spl_user_step_install` wave 2: `git grep -l "spool-install/steps/" ecc05e480 -- csi-spl-orc/src/bash/run/ | sed 's/^ecc05e480://' | xargs -r git grep -n "s/\^SPOOL_AGENT_USER=//p" ecc05e480 --`
    returns **3 files**: the host `spl-git-pager-off-install.func.sh:39` (from `r08-02`
    `48431f0f5`) and the exact 2 remaining memory actions
    `spl-grok-memory-install.func.sh:33` (50 lines) and
    `spl-agy-memory-install.func.sh:35` (52 lines), which also duplicate the 6-line
    `git-common-dir` -> `dirname` repo-derivation block (`:23-28` and `:25-30`) -> **row 01** (1.3).
  - `orc:src/bash/run/wui-{build,dev,test}.func.sh`: `git grep -n "pnpm install" ecc05e480 -- csi-spl-orc/src/bash/run/ csi-spl-iac/src/bash/run/`
    confirms these exact 3 files carry the identical 7-line `do_require_bin pnpm` +
    `$APP_PATH/csi-spl-wui` + `node_modules` `pnpm install` preamble
    (`wui-build.func.sh:11-17`, `wui-dev.func.sh:12-18`, `wui-test.func.sh:7-13`);
    other `pnpm install` callers (`deploy-wui`, `deploy-hosted-site`, `wui-up`,
    `check-pre-push*`) use `--frozen-lockfile` or container installs -> **row 02** (1.4).
  - Remaining r08 section 7 items (the 3 kept-out `is a linked worktree:` files including
    secret-class `spl-private-overlay-install-cron.func.sh`, `spl-issue-blocker-rca-close`
    / `spl-issue-owner-question-diss`, non-matching cron installers, secret-class probe /
    `gcp-*` actions, PG-heavy actions, and earlier unserved r07 items) remain accounted
    for in section 7.
  - Broad scan of `orc:src/bash/run/install-*.func.sh` on `ecc05e480` surfaced a clean,
    non-secret 3-file candidate for `r10`: `install-agy-cli.func.sh` (57 lines),
    `install-mistral-vibe.func.sh` (53 lines), and `install-openai-codex.func.sh` (56
    lines), duplicating the ~25-line `org_app` / `cnf` / `yq` semver pin / `DRY_RUN` /
    `spool_env_resolve` / `getent passwd` / `sudo -n -u` `install.sh --cli` wrapper
    (recorded in section 7 for `r10`).
- **(b) R7 notes of r08-01, r08-02, and r08 panel notes N1-N6:**
  - `r08-01` (`761e1275f`, SPL-6618, agy R7 `a-230` PASS): N1 cosmetic parent sha fixed
    before landing; N2 box-dependent `test-agent-hook.sh` and `gcloud-account-pinned.tst.sh`
    counts equal on parent and head. No refactor follow-up.
  - `r08-02` (`48431f0f5`, SPL-6621, agy R7 `a-242` PASS) and r08 panel N2: optional 7th
    `repo` arg on `_spl_user_step_install` had no wave-1 caller -> now exercised by **row 01** (1.3).
  - r08 panel N1/N3/N4/N5/N6: folded or informational (`N4` box-dependent
    `gcloud-account-pinned.tst.sh` count: 48 on this box, equal on base and heads).
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to this planner/holder
  box only; 167 lines, read 22:52Z):
  - New entries since r08 (lines 165-167): both bug-shaped for `b52` (`MessageCard.vue`
    M3 select box, `spawn-remote.sh handle()` race).
  - Earlier open refactor-labelled entries (lines 113 `_ppe_keys`, 115
    `i18n-lang-review-exempt.json:2`, 125 WUI entry-chunk headroom) remain accounted for in
    section 7.
- **(d) spec 011 tasks:**
  `git log 26c6b91ed..ecc05e480 --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r08; remaining open/partial tasks (`T001`-`T008` owner-deferred,
  `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `_spl_memory_step_install` and `_spl_user_step_install` wave 2 (`spl-grok-memory-install`, `spl-agy-memory-install`)

`orc:` = `csi-spl-orc/`. On `ecc05e480`:

- `orc:src/bash/run/spl-git-pager-off-install.func.sh:29-62` already hosts
  `_spl_user_step_install` (landed in `r08-02` `48431f0f5`), including the optional 7th
  `repo` parameter (`INFO $label: $u ($target), repo $repo, DRY_RUN=$dry` and passing
  `$repo` as the 3rd arg to `<fn>`). It needs **zero edits** in this row.
- The two remaining per-user `spool-install` actions in `orc:src/bash/run/` duplicate both
  the 21-line user loop (now hosted in `_spl_user_step_install`) and the 10-line `DRY_RUN`
  / step-readability / `git-common-dir` -> `dirname` main-worktree repo derivation:
  1. `orc:src/bash/run/spl-grok-memory-install.func.sh:18-50` (50 lines; step
     `y18-grok-memory.sh`, fn `spool_install_grok_memory`, label `"grok memory"`,
     `GROK_MEMORY_USERS`, `GROK_MEMORY_REPO`).
  2. `orc:src/bash/run/spl-agy-memory-install.func.sh:20-52` (52 lines; step
     `y20-agy-memory.sh`, fn `spool_install_agy_memory`, label `"agy memory"`,
     `AGY_MEMORY_USERS`, `AGY_MEMORY_REPO`).
- Extracting `_spl_memory_step_install` in `spl-grok-memory-install.func.sh` (which
  preserves exact validation ordering: `DRY_RUN` -> `[[ -r "$step" ]]` -> `git-common-dir`
  repo derivation -> lazy-load `_spl_user_step_install`) eliminates both duplicates at once
  with zero new files and zero eager loads, completing **5/5** per-user `spool-install`
  action consolidation (`spl-git-pager-off-install`, `spl-vibe-output-cap-install`,
  `spl-vibe-push-guard-install`, `spl-grok-memory-install`, `spl-agy-memory-install`).
- None of the 3 edited files handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_spl_grok_memory_install` 33 -> 6 lines, `_spl_memory_step_install` 14 lines;
  `do_spl_agy_memory_install` 33 -> 8 lines.
  None of the 3 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/spl-grok-memory-install.func.sh`: replace `:18-50` with thin
  `do_spl_grok_memory_install` + `_spl_memory_step_install` (lazy-sourcing
  `spl-git-pager-off-install.func.sh` and delegating to `_spl_user_step_install`).
  50 -> 41 lines (`+16 -25`).
- `orc:src/bash/run/spl-agy-memory-install.func.sh`: replace `:20-52` with lazy-source of
  `spl-grok-memory-install.func.sh` + `_spl_memory_step_install` call.
  52 -> 27 lines (`+6 -31`).
- `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh`: add section `10` to
  the header after `:19`; insert section `10` immediately before the summary `echo` at
  `:127` (5 direct `_spl_memory_step_install` checks covering invalid `DRY_RUN`, unreadable
  step, non-git `PROJ_PATH` naming `repo_var`, main-worktree derivation from a linked
  worktree, and explicit `repo` override; 3 one-copy checks covering both memory files and
  all 5/5 per-user `spool-install` actions; and 2 standalone linked-worktree dry-run checks
  for `do_spl_grok_memory_install` and `do_spl_agy_memory_install` with `*_MEMORY_REPO`
  unset and stubbed `getent`). 128 -> 193 lines (`+65 -0`). Total edited files: **3**
  (within rulebook 3.1's max 5).
- head1's files, sha256 (12 chars): `spl-grok-memory-install.func.sh` `50391c1df5bb`,
  `spl-agy-memory-install.func.sh` `60f5071ab943`,
  `test-y18-grok-memory.sh` `4c0375ed42ea`.

Verbatim helper, caller, and test hunks (head1 on `ecc05e480`):

`orc:src/bash/run/spl-grok-memory-install.func.sh` (replace `:18-50`):
```bash
do_spl_grok_memory_install() {
  _spl_memory_step_install "grok memory" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y18-grok-memory.sh" \
    spool_install_grok_memory "${GROK_MEMORY_USERS:-}" "${DRY_RUN:-1}" \
    "${GROK_MEMORY_REPO:-}" "GROK_MEMORY_REPO"
}

# _spl_memory_step_install <label> <step_file> <fn> <users_override> <dry> <repo_override> <repo_var>
# Validates DRY_RUN and <step_file>, derives the main worktree root when
# <repo_override> is empty, then delegates the per-user loop to
# _spl_user_step_install.
_spl_memory_step_install() {
  local label="$1" step="$2" fn="$3" users="$4" dry="$5" repo="$6" repo_var="$7"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  if [[ -z "$repo" ]]; then
    repo="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
      { do_log "FATAL cannot tell the repo of $PROJ_PATH (set $repo_var)"; return 1; }
    repo="$(dirname "$repo")"
  fi
  # shellcheck source=spl-git-pager-off-install.func.sh
  declare -F _spl_user_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-git-pager-off-install.func.sh" || return 1
  _spl_user_step_install "$label" "$step" "$fn" "$users" "$dry" "" "$repo"
}
```

`orc:src/bash/run/spl-agy-memory-install.func.sh` (replace `:20-52`):
```bash
do_spl_agy_memory_install() {
  # shellcheck source=spl-grok-memory-install.func.sh
  declare -F _spl_memory_step_install >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-grok-memory-install.func.sh" || return 1
  _spl_memory_step_install "agy memory" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y20-agy-memory.sh" \
    spool_install_agy_memory "${AGY_MEMORY_USERS:-}" "${DRY_RUN:-1}" \
    "${AGY_MEMORY_REPO:-}" "AGY_MEMORY_REPO"
}
```

`orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh` (append to header after
`:19`; insert section `10` immediately before
`echo "--- y18 grok memory: $((n - fails))/$n passed, $notrun grok checks not run"` at
`:127`, followed by one blank line; `:126` is already blank):
```bash
#  10. _spl_memory_step_install and wave-2 delegation to _spl_user_step_install (r09-01)
```
```bash
# 10. _spl_memory_step_install and wave-2 delegation to _spl_user_step_install (r09-01 one copy)
me="$(id -un)"
printf 'fake_mem_step() { echo "CALL:$*"; }\n' >"$T/fake-mem-step.sh"
mkdir -p "$T/nogit"
git -C "$R" -c user.name=t -c user.email=t@example.com commit --allow-empty -qm init
git -C "$R" worktree add -q --detach "$T/wt-mem"
mkdir -p "$T/wt-mem/csi-spl-orc/src/bash/features/spool-install/steps" "$T/wt-mem/csi-spl-orc/lib/bash/funcs"
cp "$FEAT/steps/claude-memory.inc.sh" "$FEAT/steps/y18-grok-memory.sh" "$FEAT/steps/y20-agy-memory.sh" \
  "$T/wt-mem/csi-spl-orc/src/bash/features/spool-install/steps/"
cp "$ORC/lib/bash/funcs/spl-claude-project-slug.func.sh" "$T/wt-mem/csi-spl-orc/lib/bash/funcs/"
mem_run() {
  local pp="$1"; shift
  PROJ_PATH="$pp" T_MH="$T/mh" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    getent() { printf "x:x:0:0::%s:/bin/sh\n" "$T_MH"; }
    . "$1/src/bash/run/spl-grok-memory-install.func.sh" && _spl_memory_step_install "${@:2}"' _ "$ORC" "$@" 2>&1
}
out="$(mem_run "$ORC" "demo" "$T/fake-mem-step.sh" fake_mem_step "$me" 2 "$R" DEMO_REPO)"; rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"FATAL DRY_RUN must be 0 or 1, got: '2'"* ]]
then pass "10. _spl_memory_step_install refuses invalid DRY_RUN"; else fail "10. bad dry ($rc: $out)"; fi
out="$(mem_run "$ORC" "demo" "$T/no-such-step.sh" fake_mem_step "$me" 1 "$R" DEMO_REPO)"; rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"FATAL the step $T/no-such-step.sh is not readable"* ]]
then pass "10. _spl_memory_step_install refuses an unreadable step"; else fail "10. unreadable step ($rc: $out)"; fi
out="$(mem_run "$T/nogit" "demo" "$T/fake-mem-step.sh" fake_mem_step "$me" 1 "" DEMO_REPO)"; rc=$?
if [ "$rc" = 1 ] && [[ "$out" == *"FATAL cannot tell the repo of $T/nogit (set DEMO_REPO)"* ]]
then pass "10. _spl_memory_step_install names repo_var when PROJ_PATH is not a git repo"; else fail "10. nogit ($rc: $out)"; fi
out="$(mem_run "$T/wt-mem/csi-spl-orc" "demo" "$T/fake-mem-step.sh" fake_mem_step "$me" 1 "" DEMO_REPO)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"CALL:$T/mh 1 $R"* ]] && [[ "$out" == *"INFO demo: $me ($T/mh), repo $R, DRY_RUN=1"* ]]
then pass "10. _spl_memory_step_install derives main worktree root from a linked worktree"; else fail "10. wt derive ($rc: $out)"; fi
out="$(mem_run "$T/nogit" "demo" "$T/fake-mem-step.sh" fake_mem_step "$me" 1 "$R" DEMO_REPO)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"CALL:$T/mh 1 $R"* ]] && [[ "$out" == *"OK demo: $me (DRY_RUN=1)"* ]]
then pass "10. _spl_memory_step_install honours explicit repo override"; else fail "10. repo override ($rc: $out)"; fi

grok_f="$ORC/src/bash/run/spl-grok-memory-install.func.sh"
agy_f="$ORC/src/bash/run/spl-agy-memory-install.func.sh"
own_g="$(grep -nE 's/\^SPOOL_AGENT_USER=|getent passwd|sudo -n -u' "$grok_f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -z "$own_g" ] && grep -q '^_spl_memory_step_install()' "$grok_f" && [ "$(grep -c -- '--git-common-dir' "$grok_f")" -eq 1 ] && grep -q '_spl_user_step_install ' "$grok_f"
then pass "10. one copy: spl-grok-memory-install.func.sh hosts _spl_memory_step_install and delegates user loop"; else fail "10. grok host: own=[$own_g]"; fi
own_a="$(grep -nE 's/\^SPOOL_AGENT_USER=|getent passwd|sudo -n -u|--git-common-dir' "$agy_f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -z "$own_a" ] && grep -q '_spl_memory_step_install ' "$agy_f"
then pass "10. one copy: spl-agy-memory-install.func.sh delegates to _spl_memory_step_install"; else fail "10. agy delegate: own=[$own_a]"; fi
loop_hosts="$(grep -l 's/\^SPOOL_AGENT_USER=//p' \
  "$ORC/src/bash/run/spl-git-pager-off-install.func.sh" \
  "$ORC/src/bash/run/spl-vibe-output-cap-install.func.sh" \
  "$ORC/src/bash/run/spl-vibe-push-guard-install.func.sh" \
  "$grok_f" "$agy_f" | xargs -r -n1 basename | tr '\n' ' ')"
if [ "$loop_hosts" = "spl-git-pager-off-install.func.sh " ]
then pass "10. one copy: all 5 per-user spool-install actions share _spl_user_step_install"; else fail "10. 5/5 loop hosts: [$loop_hosts]"; fi

H10="$T/home10"; mk_home "$H10"; mkdir -p "$H10/.gemini"
bash -c '. "$1" && spool_install_agy_memory_row "$2" probe-fact.md' _ \
  "$FEAT/steps/y20-agy-memory.sh" "$H10/.claude/projects/$slug/memory" \
  >"$H10/.claude/projects/$slug/memory/agy-allow.list"
out="$(env -u GROK_MEMORY_REPO PROJ_PATH="$T/wt-mem/csi-spl-orc" GROK_MEMORY_USERS="$me" DRY_RUN=1 H10="$H10" bash -c '
  do_log() { echo "$*"; }; getent() { printf "x:x:0:0::%s:/bin/sh\n" "$H10"; }
  . "$1/src/bash/run/spl-grok-memory-install.func.sh" && do_spl_grok_memory_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"INFO grok memory: $me ($H10), repo $R, DRY_RUN=1"* ]] && [[ "$out" == *"would: write $H10/.grok/rules/fleet-memory-0-where.md"* ]] && [[ "$out" == *"OK grok memory: $me (DRY_RUN=1)"* ]] && [ ! -e "$H10/.grok/rules" ]
then pass "10. spl-grok-memory-install sourced alone derives repo and plans dry run"; else fail "10. grok standalone ($rc: $out)"; fi
out="$(env -u AGY_MEMORY_REPO PROJ_PATH="$T/wt-mem/csi-spl-orc" AGY_MEMORY_USERS="$me" DRY_RUN=1 H10="$H10" bash -c '
  do_log() { echo "$*"; }; getent() { printf "x:x:0:0::%s:/bin/sh\n" "$H10"; }
  . "$1/src/bash/run/spl-agy-memory-install.func.sh" && do_spl_agy_memory_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"INFO agy memory: $me ($H10), repo $R, DRY_RUN=1"* ]] && [[ "$out" == *"would: write $H10/.gemini/config/rules/fleet-memory-0-where.md"* ]] && [[ "$out" == *"OK agy memory: $me (DRY_RUN=1)"* ]] && [ ! -e "$H10/.gemini/config/rules" ]
then pass "10. spl-agy-memory-install sourced alone derives repo and plans dry run"; else fail "10. agy standalone ($rc: $out)"; fi
```

**Behaviour:** zero behaviour change. Both actions preserve exact validation order
(`DRY_RUN`, step readability, `git-common-dir` repo derivation), exact `FATAL`, `ERROR`,
`INFO`, and `OK` messages, user deduplication, `SPOOL_AGENT_USER`/`box.env` fallback,
`sudo -n -u` dispatch, and return codes (both standalone linked-worktree dry-run checks
pass on unmodified `base` too).

### 1.4 Row 02's site: `_wui_prepare` WUI pnpm/directory preamble (`wui-dev`, `wui-build`, `wui-test`)

`orc:` = `csi-spl-orc/`. On `ecc05e480`:

- Three local WUI `pnpm` actions in `orc:src/bash/run/` duplicate the identical 7-line
  preamble (`do_require_bin pnpm`, `wui="$APP_PATH/csi-spl-wui"`, `[[ -d "$wui" ]]`, and
  `if [[ ! -d "$wui/node_modules" ]]; then do_log "INFO pnpm install in $wui"; ( cd "$wui" && pnpm install ) || return 1; fi`):
  1. `orc:src/bash/run/wui-dev.func.sh:10-25` (25 lines; calls `do_lde_cnf || return 1`
     first, then preamble `:12-18`, then `pnpm dev`).
  2. `orc:src/bash/run/wui-build.func.sh:10-22` (22 lines; preamble `:11-17`, then
     `pnpm generate` and `.output/public` check).
  3. `orc:src/bash/run/wui-test.func.sh:6-16` (16 lines; preamble `:7-13`, then
     `pnpm test:unit` and `pnpm typecheck`).
- Hosting `_wui_prepare` in `wui-dev.func.sh` (adding no new file and no eager load) keeps
  `csi-spl-wui` in `wui-dev.func.sh`, so existing `wui-actions.tst.sh:18`
  (`grep -q 'csi-spl-wui' "$PROJ_ROOT/src/bash/run/wui-dev.func.sh"`) continues to pass
  unchanged alongside `:21` (`pnpm generate` in `wui-build`) and `:22` (`pnpm test:unit`
  in `wui-test`). Each caller declares `local WUI_DIR=""` so `_wui_prepare` sets the
  caller-scoped variable without leaking a global or capturing stdout.
- None of the 4 edited files handles any token, credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_wui_dev` 16 -> 11 lines, `_wui_prepare` 9 lines; `do_wui_build` 13 -> 10 lines;
  `do_wui_test` 11 -> 8 lines.
  None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/wui-dev.func.sh`: replace `:10-25` with `do_wui_dev` (calling it) +
  `_wui_prepare`. 25 -> 32 lines (`+15 -8`).
- `orc:src/bash/run/wui-build.func.sh`: replace `:10-22` with lazy-source of
  `wui-dev.func.sh` + `_wui_prepare`. 22 -> 19 lines (`+8 -11`).
- `orc:src/bash/run/wui-test.func.sh`: replace `:6-16` with lazy-source of
  `wui-dev.func.sh` + `_wui_prepare`. 16 -> 13 lines (`+6 -9`).
- `orc:src/bash/tests/wui-actions.tst.sh`: insert `_wui_prepare` helper checks (4),
  one-copy checks (3), and standalone stubbed runtime checks for `do_wui_dev` (incl.
  `do_lde_cnf` failure before `_wui_prepare`), `do_wui_build`, and `do_wui_test` (4)
  immediately before `[[ "$fails" -eq 0 ]]` at `:140`.
  141 -> 214 lines (`+73 -0`). Total edited files: **4** (within rulebook 3.1's max 5).
- head2's files, sha256 (12 chars): `wui-dev.func.sh` `d863b23a49f1`,
  `wui-build.func.sh` `04930c0f2976`, `wui-test.func.sh` `97d8fa671ff3`,
  `wui-actions.tst.sh` `58549a27df33`.

Verbatim helper, caller, and test hunks (head2 on `ecc05e480`):

`orc:src/bash/run/wui-dev.func.sh` (replace `:10-25`):
```bash
do_wui_dev() {
  do_lde_cnf || return 1
  local WUI_DIR=""
  _wui_prepare || return 1
  # a {tenant} template: the hub answers 404 unknown_tenant on a bare host
  : "${NUXT_PUBLIC_API_BASE:=http://{tenant}.localhost:${LDE_HUB_PORT}}"
  : "${NUXT_PUBLIC_USE_MOCK:=1}"
  export NUXT_PUBLIC_API_BASE NUXT_PUBLIC_USE_MOCK
  do_log "INFO WUI lde on 0.0.0.0:${LDE_WUI_PORT} api=$NUXT_PUBLIC_API_BASE mock=$NUXT_PUBLIC_USE_MOCK"
  ( cd "$WUI_DIR" && pnpm dev --host 0.0.0.0 --port "$LDE_WUI_PORT" )
}

# _wui_prepare: check pnpm and $APP_PATH/csi-spl-wui exist, run pnpm install
# when node_modules is absent, and set WUI_DIR for the caller.
_wui_prepare() {
  do_require_bin pnpm || return 1
  WUI_DIR="$APP_PATH/csi-spl-wui"
  [[ -d "$WUI_DIR" ]] || { do_log "FATAL missing $WUI_DIR"; return 1; }
  if [[ ! -d "$WUI_DIR/node_modules" ]]; then
    do_log "INFO pnpm install in $WUI_DIR"
    ( cd "$WUI_DIR" && pnpm install ) || return 1
  fi
}
```

`orc:src/bash/run/wui-build.func.sh` (replace `:10-22`):
```bash
do_wui_build() {
  local WUI_DIR=""
  # shellcheck source=wui-dev.func.sh
  declare -F _wui_prepare >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/wui-dev.func.sh" || return 1
  _wui_prepare || return 1
  do_log "INFO pnpm generate in $WUI_DIR"
  ( cd "$WUI_DIR" && pnpm generate ) || return 1
  [[ -d "$WUI_DIR/.output/public" ]] || { do_log "FATAL generate did not write .output/public"; return 1; }
  do_log "INFO generated $WUI_DIR/.output/public"
}
```

`orc:src/bash/run/wui-test.func.sh` (replace `:6-16`):
```bash
do_wui_test() {
  local WUI_DIR=""
  # shellcheck source=wui-dev.func.sh
  declare -F _wui_prepare >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/wui-dev.func.sh" || return 1
  _wui_prepare || return 1
  ( cd "$WUI_DIR" && pnpm test:unit ) || return 1
  ( cd "$WUI_DIR" && pnpm typecheck ) || return 1
}
```

`orc:src/bash/tests/wui-actions.tst.sh` (insert immediately before
`[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }` at
`:140`, followed by one blank line; `:139` is already blank):
```bash
# _wui_prepare helper and one-copy delegation across wui-{dev,build,test} (r09-02)
WUI_T=$(mktemp -d)
trap 'rm -rf "$WUI_T"' EXIT
wui_prep_run() {
  local app="$1" bin_rc="${2:-0}"
  APP_PATH="$app" WUI_BIN_RC="$bin_rc" bash -c '
    set -uo pipefail
    do_require_bin() { echo "REQ:$*"; return "$WUI_BIN_RC"; }
    do_log() { echo "$*"; }
    pnpm() { echo "PNPM:$PWD:$*"; }
    WUI_DIR=""
    . "$1/src/bash/run/wui-dev.func.sh"
    _wui_prepare || exit $?
    echo "DIR:$WUI_DIR"' _ "$PROJ_ROOT" 2>&1
}
out="$(wui_prep_run "$WUI_T/missing-app" 0)"; rc=$?
[[ "$rc" = 1 && "$out" == *"FATAL missing $WUI_T/missing-app/csi-spl-wui"* ]] \
  && pass "wui-prepare: refuses missing csi-spl-wui dir" || fail "wui-prepare missing ($rc: $out)"
mkdir -p "$WUI_T/no-nm/csi-spl-wui"
out="$(wui_prep_run "$WUI_T/no-nm" 0)"; rc=$?
[[ "$rc" = 0 && "$out" == *"INFO pnpm install in $WUI_T/no-nm/csi-spl-wui"* && "$out" == *"PNPM:$WUI_T/no-nm/csi-spl-wui:install"* && "$out" == *"DIR:$WUI_T/no-nm/csi-spl-wui"* ]] \
  && pass "wui-prepare: installs when node_modules is absent and sets WUI_DIR" || fail "wui-prepare no-nm ($rc: $out)"
mkdir -p "$WUI_T/has-nm/csi-spl-wui/node_modules"
out="$(wui_prep_run "$WUI_T/has-nm" 0)"; rc=$?
[[ "$rc" = 0 && "$out" != *"PNPM:"* && "$out" == *"DIR:$WUI_T/has-nm/csi-spl-wui"* ]] \
  && pass "wui-prepare: skips pnpm install when node_modules exists" || fail "wui-prepare has-nm ($rc: $out)"
out="$(wui_prep_run "$WUI_T/has-nm" 1)"; rc=$?
[[ "$rc" = 1 && "$out" == *"REQ:pnpm"* && "$out" != *"DIR:"* ]] \
  && pass "wui-prepare: fails fast when pnpm is missing" || fail "wui-prepare no-pnpm ($rc: $out)"

wui_host="$PROJ_ROOT/src/bash/run/wui-dev.func.sh"
[[ "$(grep -c '&& pnpm install )' "$wui_host")" -eq 1 ]] && grep -q '^_wui_prepare()' "$wui_host" \
  && pass "one copy: wui-dev.func.sh hosts _wui_prepare" || fail "one copy: wui-dev host"
for wf in wui-build.func.sh wui-test.func.sh; do
  wfp="$PROJ_ROOT/src/bash/run/$wf"
  own="$(grep -nE 'pnpm install|FATAL missing' "$wfp" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [[ -z "$own" ]] && grep -q '_wui_prepare ' "$wfp" \
    && pass "one copy: $wf delegates WUI preamble to _wui_prepare" \
    || fail "one copy $wf: own=[$own]"
done

mkdir -p "$WUI_T/st-dev/csi-spl-wui" "$WUI_T/st-build/csi-spl-wui" "$WUI_T/st-test/csi-spl-wui/node_modules"
out="$(APP_PATH="$WUI_T/st-dev" bash -c '
  set -uo pipefail
  do_lde_cnf() { LDE_HUB_PORT=8080; LDE_WUI_PORT=3123; }
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-dev.func.sh" && do_wui_dev' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" == *"PNPM:$WUI_T/st-dev/csi-spl-wui:install"* && "$out" == *"PNPM:$WUI_T/st-dev/csi-spl-wui:dev --host 0.0.0.0 --port 3123"* ]] \
  && pass "standalone: do_wui_dev installs and starts dev server" || fail "standalone wui-dev ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-dev" bash -c '
  set -uo pipefail
  do_lde_cnf() { return 1; }
  do_require_bin() { echo "REQ:$*"; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-dev.func.sh" && do_wui_dev' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 1 && "$out" != *"REQ:pnpm"* && "$out" != *"PNPM:"* ]] \
  && pass "standalone: do_wui_dev runs do_lde_cnf before _wui_prepare" || fail "standalone wui-dev order ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-build" bash -c '
  set -uo pipefail
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; [[ "$1" == generate ]] && mkdir -p .output/public || true; }
  . "$1/src/bash/run/wui-build.func.sh" && do_wui_build' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" == *"PNPM:$WUI_T/st-build/csi-spl-wui:install"* && "$out" == *"PNPM:$WUI_T/st-build/csi-spl-wui:generate"* && "$out" == *"INFO generated $WUI_T/st-build/csi-spl-wui/.output/public"* ]] \
  && pass "standalone: do_wui_build installs, generates, and logs output dir" || fail "standalone wui-build ($rc: $out)"
out="$(APP_PATH="$WUI_T/st-test" bash -c '
  set -uo pipefail
  do_require_bin() { :; }; do_log() { echo "$*"; }
  pnpm() { echo "PNPM:$PWD:$*"; }
  . "$1/src/bash/run/wui-test.func.sh" && do_wui_test' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ "$rc" = 0 && "$out" != *":install"* && "$out" == *"PNPM:$WUI_T/st-test/csi-spl-wui:test:unit"* && "$out" == *"PNPM:$WUI_T/st-test/csi-spl-wui:typecheck"* ]] \
  && pass "standalone: do_wui_test skips install and runs test:unit + typecheck" || fail "standalone wui-test ($rc: $out)"
```

**Behaviour:** zero behaviour change. All three WUI actions keep exact check order
(`do_lde_cnf` first in `do_wui_dev`, guarded by the `standalone wui-dev order` check and
mutation `m2d`), exact `FATAL`/`INFO` messages, `pnpm install` triggering only when
`node_modules` is absent, and return codes (all 4 standalone action checks pass on
unmodified `base` too).

### 1.5 Before and on the rows' heads

2026-11-26T23:01:45Z-23:03:54Z (and Row 02 W1 re-verification 23:24:18Z-23:24:35Z), n=1,
as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG`
and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts; "-" means that row's head does not touch the suite's
tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh` | 01 | 0 / 13 / 0 | 0 / 23 / 0 (+10 new checks) | - |
| `orc:src/bash/features/spool-install/tests/test-y20-agy-memory.sh` | 01 | 0 / 68 / 0 | = | - |
| `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh` | 01 | 0 / 22 / 0 | = | - |
| `orc:src/bash/tests/wui-actions.tst.sh` | 02 | 0 / 28 / 0 | - | 0 / 39 / 0 (+11 new checks) |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |

Note (\*): on mutation checks `m1a`, `m1b`, and `m1c`, multi-line `$out` dumped inside a
`FAIL:` message includes raw `OK ...` log lines on their own lines, which
`grep -ciE '^ *(ok|pass)'` counts alongside real `PASS:` checks (broken down per mutation
below). On `wui-actions.tst.sh`, rc 0 prints one summary `PASS: all wui-actions.tst.sh assertions`
line (28 base, 39 head2), and rc 1 prints one summary `FAIL: N assertion(s)` line.
`test-y18-grok-memory.sh` and `test-y20-agy-memory.sh` skip live CLI checks when `grok` /
`agy` is not on the push user's `PATH`: on a box with `grok` on `PATH` (panel N1), `test-y18-grok-memory.sh`
reads base `15/0`, `rc1` `17/8`, head1 `25/0` (+2 live checks; identical rc and fail
sets); counts are equal on base and head on the same box.
`gcloud-account-pinned.tst.sh` counts are box-dependent (48 on this box; equal on base and
heads). Run `no-literal-paths.tst.sh` in a git checkout owned by the user running git.

`shellcheck 0.10.0 -S warning -x` on all 7 edited files (head1: 3 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own scratch clone of `ecc05e480`, reconstructed
from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `test-y18-grok-memory.sh` on base): rc 1, 8 fail
  (15 pass without `grok` on `PATH` / 17 pass with `grok`: base + both standalone
  linked-worktree dry-run checks passing on base, proving equivalence; 5 `FAIL: 10.`
  `_spl_memory_step_install: command not found` checks, `FAIL: 10. grok host` naming `:33`,
  `FAIL: 10. agy delegate` naming `:27`, and `FAIL: 10. 5/5 loop hosts` listing 3 files);
  head1: rc 0, 0 fail (23 pass without `grok` / 25 pass with `grok`).
- Row 02 red control (`rc2`, head2's `wui-actions.tst.sh` on base): rc 1, 31 pass
  (27 base assertions + all 4 standalone action checks passing on base, proving
  equivalence), 8 fail lines (7 `FAIL:` assertions: 4 `_wui_prepare: command not found`
  checks, `FAIL: one copy: wui-dev host`, `FAIL: one copy wui-build.func.sh` naming `:13`,
  `FAIL: one copy wui-test.func.sh` naming `:9`, plus 1 summary `FAIL: 7 assertion(s)`);
  head2: rc 0, 39 pass, 0 fail.

**Mutation checks** (n=1 each, fresh scratch clones of `ecc05e480` with head1/head2
applied, then one defect planted):
- `m1a` (`spl-agy-memory-install.func.sh` passes `"/wrong"` instead of
  `"${AGY_MEMORY_REPO:-}"`): `test-y18-grok-memory.sh` rc 1, `23*` `ok|pass` lines
  (22 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 10. agy standalone`).
- `m1b` (`_spl_memory_step_install` passes `"" ""` instead of `"" "$repo"` to
  `_spl_user_step_install`): `test-y18-grok-memory.sh` rc 1, `23*` `ok|pass` lines
  (19 real `PASS:` + 4 dumped `OK` lines), 4 fail (`FAIL: 10. wt derive`,
  `FAIL: 10. repo override`, `FAIL: 10. grok standalone`, `FAIL: 10. agy standalone`).
- `m1c` (`_spl_memory_step_install` omits `repo="$(dirname "$repo")"`):
  `test-y18-grok-memory.sh` rc 1, `23*` `ok|pass` lines (20 real `PASS:` + 3 dumped `OK`
  lines), 3 fail (`FAIL: 10. wt derive`, `FAIL: 10. grok standalone`,
  `FAIL: 10. agy standalone`).
- `m2a` (`_wui_prepare` in `wui-dev.func.sh` skips `pnpm install` via `if false; then`):
  `wui-actions.tst.sh` rc 1, 35 pass, 4 fail lines (3 `FAIL:` assertions:
  `FAIL: wui-prepare no-nm`, `FAIL: standalone wui-dev`, `FAIL: standalone wui-build`,
  plus 1 summary `FAIL: 3 assertion(s)`).
- `m2b` (`wui-build.func.sh` replaces `_wui_prepare || return 1` with
  `WUI_DIR="$APP_PATH/csi-spl-wui"`): `wui-actions.tst.sh` rc 1, 37 pass, 2 fail lines
  (1 `FAIL:` assertion: `FAIL: standalone wui-build`, plus 1 summary
  `FAIL: 1 assertion(s)`).
- `m2c` (`wui-test.func.sh` replaces `_wui_prepare || return 1` with `:`):
  `wui-actions.tst.sh` rc 1, 37 pass, 2 fail lines (1 `FAIL:` assertion:
  `FAIL: standalone wui-test`, plus 1 summary `FAIL: 1 assertion(s)`).
- `m2d` (`wui-dev.func.sh` moves `_wui_prepare || return 1` above `do_lde_cnf || return 1`;
  panel W1 / `x2d`): `wui-actions.tst.sh` rc 1, 37 pass, 2 fail lines (1 `FAIL:`
  assertion: `FAIL: standalone wui-dev order`, plus 1 summary `FAIL: 1 assertion(s)`).

The tests that name the sites (R2): `git grep -nE` over `orc/src/bash/tests/*`,
`orc/src/bash/features/*/tests/*`, `iac/src/bash/tests/*`, and `csi-spl-api/*` on
`ecc05e480`:
- Row 01 (`spl-grok-memory-install|do_spl_grok_memory_install|spl-agy-memory-install|do_spl_agy_memory_install|spl-git-pager-off-install|_spl_user_step_install`) ->
  **`orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh`** (edited; also
  wrapped by `spool-install-y18-grok-memory.tst.sh`),
  `orc:src/bash/features/spool-install/tests/test-y20-agy-memory.sh` (also wrapped by
  `spool-install-y20-agy-memory.tst.sh`), and
  **`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`** (also wrapped
  by `spool-install-y16-git-pager-off.tst.sh`; 0 hits in `csi-spl-iac/` or `csi-spl-api/`).
- Row 02 (`wui-build\.func|do_wui_build|wui-dev\.func|do_wui_dev|wui-test\.func|do_wui_test`) ->
  **`orc:src/bash/tests/wui-actions.tst.sh`** (edited; 0 hits in `features/*/tests/`,
  `csi-spl-iac/`, or `csi-spl-api/`).
- 30-char comment/string grep across all edited sites (+/- 3 lines): only
  `test-y18-grok-memory.sh` and `test-y20-agy-memory.sh` (both already in row 01's test
  column). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r09-01-orc-spool-install-memory-step)` | one fact, one copy (developer guide 2.2.4) | `spl-grok-memory-install.func.sh:18-50` and `spl-agy-memory-install.func.sh:20-52` are the last 2 per-user `spool-install` actions duplicating the user dispatch loop already hosted in `_spl_user_step_install` (`spl-git-pager-off-install.func.sh:29-62`, `r08-02` `48431f0f5`), and also duplicate the `DRY_RUN` / step-readability / `git-common-dir` repo-derivation block (1.3, r08 section 7 #1; closes r08 panel N2 and r08-02 R7 N1) | `orc:src/bash/run/spl-grok-memory-install.func.sh:18-50`<br>`orc:src/bash/run/spl-agy-memory-install.func.sh:20-52`<br>`orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh:19,127` | copies of the per-user `spool-install` loop across these 2 actions 2 -> 0 (delegated to `_spl_user_step_install`; completes 5/5 per-user `spool-install` actions in `orc:src/bash/run/`); copies of the `git-common-dir` memory repo derivation 2 -> 1 (`_spl_memory_step_install`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `test-y18-grok-memory.sh` on parent FAILs 8 checks (`rc1`, rc 1, 8 fail: 5 `_spl_memory_step_install` checks + 3 one-copy checks naming `:33`, `:27`, and 3 loop hosts; both standalone linked-worktree checks pass on base; pass count is box-dependent on `grok` on `PATH`, panel N1), then GREEN (rc 0, 0 fail, +10 new checks); mutations `m1a` (`agy-memory` wrong repo, rc 1, 1 fail), `m1b` (drop `$repo` arg, rc 1, 4 fail), and `m1c` (drop `dirname`, rc 1, 3 fail) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with equal per-box counts plus 10 new checks in `test-y18-grok-memory.sh`. Tests: **`orc:.../features/spool-install/tests/test-y18-grok-memory.sh`**, `orc:.../features/spool-install/tests/test-y20-agy-memory.sh`, **`orc:.../features/spool-install/tests/test-y16-git-pager-off.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r09-02-orc-wui-pnpm-prepare)` | one fact, one copy (developer guide 2.2.4) | `wui-dev.func.sh:12-18`, `wui-build.func.sh:11-17`, and `wui-test.func.sh:7-13` duplicate the identical 7-line `pnpm` + `$APP_PATH/csi-spl-wui` + `node_modules` `pnpm install` preamble (1.4, r08 section 7 #2) | `orc:src/bash/run/wui-dev.func.sh:10-25`<br>`orc:src/bash/run/wui-build.func.sh:10-22`<br>`orc:src/bash/run/wui-test.func.sh:6-16`<br>`orc:src/bash/tests/wui-actions.tst.sh:140` | copies of the WUI `pnpm` / `csi-spl-wui` / `node_modules` preamble across `wui-{dev,build,test}` 3 -> 1 (hosted once as `_wui_prepare` in `wui-dev.func.sh`; 3/3 local WUI `pnpm` actions consolidated) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `wui-actions.tst.sh` on parent FAILs 7 assertions (`rc2`, rc 1, 31 pass, 8 fail lines = 7 `FAIL:` + summary: 4 `_wui_prepare` checks + 3 one-copy checks naming `:13` and `:9`; all 4 standalone action checks pass on base), then GREEN (`0/39/0`); mutations `m2a` (`_wui_prepare` skips `pnpm install`, rc 1 `35/4`), `m2b` (`wui-build` omits `_wui_prepare`, rc 1 `37/2`), `m2c` (`wui-test` omits `_wui_prepare`, rc 1 `37/2`), and `m2d` (`wui-dev` moves `_wui_prepare` above `do_lde_cnf`, rc 1 `37/2`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 11 new checks in `wui-actions.tst.sh`. Tests: **`orc:.../wui-actions.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r09-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r09-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows consolidate internal shell helper copies with zero change to any
output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper consolidation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  (row 01: `spl-grok-memory-install.func.sh`, `spl-agy-memory-install.func.sh`,
  `test-y18-grok-memory.sh`; row 02: `wui-dev.func.sh`, `wui-build.func.sh`,
  `wui-test.func.sh`, `wui-actions.tst.sh`).
- Neither row edits `orc:src/bash/run/spl-git-pager-off-install.func.sh`,
  `orc:src/bash/run/spl-vibe-output-cap-install.func.sh`,
  `orc:src/bash/run/spl-vibe-push-guard-install.func.sh`,
  `orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`,
  `orc:src/bash/features/spool-install/tests/test-y20-agy-memory.sh`,
  `orc:src/bash/run/wui-up.func.sh`, `orc:src/bash/run/wui-down.func.sh`,
  `orc:src/bash/run/wui-rollback.func.sh`, `orc:src/bash/run/install-agy-cli.func.sh`,
  `orc:src/bash/run/install-mistral-vibe.func.sh`,
  `orc:src/bash/run/install-openai-codex.func.sh`,
  `orc:src/bash/run/spl-private-overlay-install-cron.func.sh`,
  `orc:src/bash/run/spl-spawn-place.func.sh`, `orc:src/bash/run/spl-review-go.func.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7 edited + 3 sibling regression-run files = 10 checked via `lane-map.sh --check`
at 2026-11-26T22:54:20Z):
`orc:src/bash/run/spl-grok-memory-install.func.sh`,
`orc:src/bash/run/spl-agy-memory-install.func.sh`,
`orc:src/bash/run/spl-git-pager-off-install.func.sh`,
`orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh`,
`orc:src/bash/features/spool-install/tests/test-y20-agy-memory.sh`,
`orc:src/bash/features/spool-install/tests/test-y16-git-pager-off.sh`,
`orc:src/bash/run/wui-build.func.sh`,
`orc:src/bash/run/wui-dev.func.sh`,
`orc:src/bash/run/wui-test.func.sh`,
`orc:src/bash/tests/wui-actions.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <paths> --agent a-260`, n=1, at
  2026-11-26T22:54:20Z: **exit 4** ("no live lane lists `<paths>`, but 22 live lane(s)
  record no files", 0 owned). All 22 `unknown:` live lanes are on the other box (14
  channel/workspace/other-repo seats `c-029`, `c-041`, `c-079`, `c-086`, `c-146`, `c-187`,
  `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`, `c-971`, plus `c-068` WUI
  loops dialog, `c-211` SPL-4632 GCP page, `c-251` landed r08-01 awaiting close, `c-259`
  blog picture check bug, `c-264` s158 P2 pin sweep, `c-342` this round's claude panel
  seat, `c-904` s187 S1 rdb+store, and `c-957` spec 125 doc amendment). Verified via
  `do_spl_lane_map` at 22:53:02Z — live lanes on this box (`a-260`, `a-121` r08 editor
  awaiting close, `c-129` b52 panel seat, `c-195`/`c-197`/`a-240` s150 B14/B15a, `c-171`
  CI A6 workflows, `c-119` WUI sorted window, `a-934` s182 planner) touch none of our 10
  paths. No live lane owns any of the 10 paths; the holder re-reads at placement per R3.
- **Bug round 52 beside us:** `git ls-remote origin 'refs/heads/*bug-round-52*' 'refs/heads/review/b52-*'`
  at 22:54:17Z -> empty (planner queued, panel seat `c-129` live); its candidates-file
  inputs (lines 153-167: SPL-5254 WUI, seat rotation poke, `spl-review-go`,
  `MessageCard.vue`, `spawn-remote.sh`) have **0 overlap** with our 10 paths.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T22:53:05Z):
  80 queued, 0 placing (including CI A1b/A2/A3 refactor rows, `b52` planner, SPL-6615/6616
  rotation fixes, SPL-6617 `spl-spawn-place`, s166 reflection bugs, Qto-sync row, s107/s150/
  s162/s169/s173/s174/s177/s181/s185/s186/s190/s192/s195/s196/s039 feature rows). None
  touches any of our 10 paths.
- **Unlanded rows from r08:** **0** (`r08-01` landed `761e1275f`, `r08-02` landed
  `48431f0f5`, close record `26c6b91ed`).
- **Briefs on this box** modified in the last 24 h matching any of the 7 edited paths
  (at 22:54:17Z): only already-landed `c002-r08-02-orc-spool-install-user-loop.md`; **0
  live overlapping briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 22:54:17Z):
  `git diff --name-only $(git merge-base ecc05e480 <b>) <b> -- <the 10 checked paths>` ->
  only `origin/review/r08-02` (landed `48431f0f5`, touching `spl-git-pager-off-install`
  and `test-y16-git-pager-off`); **0 unlanded branches**.
- **Commits in the last 24 h** on the 10 checked paths (`git log ecc05e480 --since='24 hours ago'`,
  at 22:54:17Z) -> 1 landed commit (`48431f0f5` r08-02); 0 unlanded churn.

## 3. Per row: what the lane does

- **r09-01:** `orc:src/bash/run/spl-grok-memory-install.func.sh` extracts
  `_spl_memory_step_install` (shared `DRY_RUN`, step readability, and `git-common-dir`
  main-worktree repo derivation, then lazy-sourcing `spl-git-pager-off-install.func.sh`
  and calling `_spl_user_step_install`) and delegates `do_spl_grok_memory_install` to it.
  `orc:src/bash/run/spl-agy-memory-install.func.sh` drops its duplicated validation,
  repo-derivation, and user-loop body, lazy-loads `spl-grok-memory-install.func.sh`, and
  calls `_spl_memory_step_install`.
  `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh` adds section `10` to
  the header (`:19`) and inserts section `10` before `:127` (5 helper checks, 3 one-copy
  checks proving 5/5 per-user `spool-install` consolidation, and 2 standalone
  linked-worktree dry-run checks).
- **r09-02:** `orc:src/bash/run/wui-dev.func.sh` extracts `_wui_prepare` (verifying `pnpm`
  and `$APP_PATH/csi-spl-wui`, running `pnpm install` when `node_modules` is absent, and
  setting caller-scoped `WUI_DIR`) and calls it from `do_wui_dev` after `do_lde_cnf`.
  `orc:src/bash/run/wui-build.func.sh` and `orc:src/bash/run/wui-test.func.sh` drop their
  duplicated 7-line preambles, declare `local WUI_DIR=""`, lazy-load `wui-dev.func.sh`,
  and call `_wui_prepare`. `orc:src/bash/tests/wui-actions.tst.sh` inserts 4 `_wui_prepare`
  helper checks, 3 one-copy checks, and 4 standalone stubbed runtime checks (including
  `do_lde_cnf` failure before `_wui_prepare`) before `:140`.

## 4. Panel and reviewers (R7)

- Editor: **a-260** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat **c-342**
  (`c002-refactor-round-09-claude-panel-seat`, seat branch
  `review/c002-refactor-round-09-claude-seat`). Reviewed v0.1
  (`feb3c1917bb2b27788ae1de13c32a6cb080e3149`, seat commit
  `27ea94e2fca980e35b1690077429c476c9f2b72a`, msg `567f5081` / holder `bbaa6d1f`; W1-W2
  and N1/N4/N6 folded in v1.0, N2-N3/N5 recorded) and signed v1.0
  (`0c05b9703265e99a4676421edf6af5ea7aeeaba1`, seat commit
  `11960d121805f13027f2a11acd3347ad92373e14`, msg `e0eebeaa` / holder `46cbe558`,
  `do_spl_review_line_check` rc 0 on panel box, `REVIEW_LINE_SYNTAX=1` rc 0 on planner
  box, holder `c-002` GO LAND `b1c5f03e`). The seat reviewed this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T22:53:44Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 22:53:33Z (`pick=agy`, `main=agy`, `backup=claude`; mistral sits on no review), R7
    review of a claude coding row goes to an **agy seat** per row (claude waiver backup
    only while agy is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 22:53:37Z picked this box (149% < 180%
    overflow, `agy weekly unknown`, placed anyway; `BOX_PICK_KIND=claude` at 22:53:40Z
    picked this box with `claude weekly 91%`); the holder re-checks capacity at row
    placement and uses the claude waiver backup only if agy is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

### 4.1 Consensus table (rulebook 3.1 / 3.2)

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `a-260` | agy | editor | `feb3c1917` (v0.1) -> `0c05b9703` (v1.0, landed `861ad6d57`) -> closed | closed | W1-W2 and N1/N4/N6 folded; N2-N3/N5 recorded; both rows landed, close record written |
| `c-342` | claude | panel | `feb3c1917` (v0.1) -> `0c05b9703` (v1.0) | PASS | v0.1 PASS with W1-W2 `27ea94e2f` (msg `567f5081`); v1.0 **PASS** `11960d121` (msg `e0eebeaa` / holder `46cbe558`, `REVIEW_LINE_SYNTAX=1` rc 0, holder `c-002` GO LAND `b1c5f03e`) |

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r09-01 | `c002-r09-01-orc-spool-install-memory-step` | `refactor(r09-01-orc-spool-install-memory-step, SPL-<row issue>): ...` | `review/r09-01` | 1 |
| r09-02 | `c002-r09-02-orc-wui-pnpm-prepare` | `refactor(r09-02-orc-wui-pnpm-prepare, SPL-<row issue>): ...` | `review/r09-02` | 1 |

**r09-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-grok-memory-install.func.sh` (replace `:18-50` with thin
`do_spl_grok_memory_install` + `_spl_memory_step_install` delegating to
`_spl_user_step_install`),
`csi-spl-orc/src/bash/run/spl-agy-memory-install.func.sh` (replace `:20-52` with
lazy-load + `_spl_memory_step_install` call), and
`csi-spl-orc/src/bash/features/spool-install/tests/test-y18-grok-memory.sh` (header `:19`,
insert section `10` before `:127`). NOT `spl-git-pager-off-install.func.sh`, NOT
`spl-vibe-output-cap-install.func.sh`, NOT `spl-vibe-push-guard-install.func.sh`, NOT
`test-y16-git-pager-off.sh`, NOT `test-y20-agy-memory.sh`, NOT `wui-dev.func.sh`, NOT
`wui-build.func.sh`, NOT `wui-test.func.sh`, NOT `wui-actions.tst.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 01 verbatim,
1.3's shape (verbatim blocks in 1.3); red control (`rc1`, head1's
`test-y18-grok-memory.sh` on parent: rc 1, 8 fail — 5 `_spl_memory_step_install` + 3
one-copy checks; pass count depends on `grok` on `PATH`) RED then GREEN (rc 0, 0 fail) in
the body; mutations `m1a` (rc 1, 1 fail), `m1b` (rc 1, 4 fail), and `m1c` (rc 1, 3 fail)
caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota, valid
only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the claude
backup is used; never mistral; re-checked at placement).

**r09-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/wui-dev.func.sh` (replace `:10-25` with `do_wui_dev` (calling
it) + `_wui_prepare`),
`csi-spl-orc/src/bash/run/wui-build.func.sh` (replace `:10-22` with lazy-load +
`_wui_prepare`),
`csi-spl-orc/src/bash/run/wui-test.func.sh` (replace `:6-16` with lazy-load +
`_wui_prepare`), and
`csi-spl-orc/src/bash/tests/wui-actions.tst.sh` (insert `_wui_prepare` helper, one-copy,
and 4 standalone checks incl. `do_lde_cnf` order before `:140`). NOT `wui-up.func.sh`, NOT `wui-down.func.sh`, NOT
`wui-rollback.func.sh`, NOT `spl-grok-memory-install.func.sh`, NOT
`spl-agy-memory-install.func.sh`, NOT `test-y18-grok-memory.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02 verbatim,
1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head2's `wui-actions.tst.sh` on
parent) RED then GREEN in the body; mutations `m2a`/`m2b`/`m2c`/`m2d` caught. Gates: the
row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on
the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
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
| copies of the per-user `spool-install` loop across row 01's 2 memory actions (1.3) | 2 on `ecc05e480` (`spl-grok-memory-install`, `spl-agy-memory-install`) -> 0 (delegated to `_spl_user_step_install`; **5/5** per-user `spool-install` actions in `orc:src/bash/run/` consolidated); copies of `git-common-dir` memory repo derivation 2 -> 1 (`_spl_memory_step_install`) |
| copies of the WUI `pnpm` / `csi-spl-wui` / `node_modules` preamble across row 02's 3 actions (1.4) | 3 on `ecc05e480` (`wui-dev`, `wui-build`, `wui-test`) -> 1 (hosted once as `_wui_prepare` in `wui-dev.func.sh`; **3/3** local WUI `pnpm` actions consolidated) |
| lines (`git diff --numstat` of each head) | row 01: `spl-grok-memory-install.func.sh` +16 -25, `spl-agy-memory-install.func.sh` +6 -31, `test-y18-grok-memory.sh` +65 -0; row 02: `wui-dev.func.sh` +15 -8, `wui-build.func.sh` +8 -11, `wui-test.func.sh` +6 -9, `wui-actions.tst.sh` +73 -0 |
| measured on | `ecc05e480`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Agent CLI installer wrappers (first candidate for `r10`, 3 action files + test): `orc:src/bash/run/install-agy-cli.func.sh:23-50` (57 lines), `orc:src/bash/run/install-mistral-vibe.func.sh:25-52` (53 lines), and `orc:src/bash/run/install-openai-codex.func.sh:28-53` (56 lines) duplicate the ~25-line `org_app` / `cnf` / `yq` semver pin check / `DRY_RUN` / `spool_env_resolve` / `getent passwd` / `sudo -n -u` `install.sh --cli <name> --cli-only` preamble | left for `r10` (rulebook 5.1 aims at 2 rows; r09 already has 2 disjoint Batch 1 rows) | `git show ecc05e480:csi-spl-orc/src/bash/run/install-{agy-cli,mistral-vibe,openai-codex}.func.sh` (non-secret; exact 3 wrappers over `install.sh --cli`) (n=1) |
| Remaining 3 `is a linked worktree:` sites in `orc:src/bash/run/`: `spl-private-overlay-install-cron.func.sh:70-71` (names `RESERVE_GH_TOKEN_FILE`, secret-class), `box-peer-ssh-grant.func.sh:53` (one-off `"grant from..."`, no WARN branch), and `spl-box-deploy.func.sh:151` (prereq collector `"PREREQ checkout missing"`) | `spl-private-overlay-install-cron` stays out per secret-class exclusion; the other two have distinct control flow and wording | r08 section 7; unchanged since `26c6b91ed` (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` and `*_apply` scaffolding (r04-r08 section 7) | semantic differences in `*_apply` (`chmod 600`, `2>/dev/null` vs `2>&1`, status predicate, log/undo headers) and `do_spl_cloud_cnf` placement in `*_read` | r08 section 7 (n=1) |
| Remaining non-matching cron installers (`spl-dispatch-rotate`, `spl-agent-boot-restore`, `spl-box-restart`, `spl-peer-crons`), secret-class 5 probe actions (`spl-*-probe.func.sh`), secret-class `gcp-*alert*` and `spl-{domain-verify,lb-absent-check,wait-for-firebase-domain,wait-for-mapping-cert}.func.sh`, PG-heavy `spl-msg-{dedup,wipe}` and `spl-channel-agent-{add,add-op,remove-op}.func.sh` | each is secret-class, pulls PostgreSQL into R2, or has non-matching cron semantics | r08 section 7 (n=1) |
| Remaining unserved r07/r08 section 7 inputs: `orc:src/bash/run/spl-{accepted-close,desk-poll-ack,review-go}.func.sh` action bodies, `orc:src/bash/run/spl-hub-box-band.func.sh`, `orc:src/bash/run/spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, `iac:src/bash/run/sec-*.func.sh`, `orc:src/bash/scripts/*-cron.sh`, and Go/WUI duplicates | each pulls 30+ tests or PostgreSQL into R2, is secret-class / scanner-wrapper / distinct semantics, or stays out for its r07/r08 section 7 reason | r08 section 7 (n=1) |
| Candidates-file open items: `_ppe_keys` exact-key in `iac:src/bash/run/check-pre-push-e2e.func.sh:121` (line 113), `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` saying `Lang-review: a-NNN` (line 115), WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125), other-box process churn (lines 147-148), and `b52` bug inputs (lines 153-167) | `_ppe_keys` is gate-design input; `i18n-lang-review-exempt.json:2` is a 1-line JSON doc comment; entry-chunk headroom and process churn are perf-shaped; lines 153-167 are bug-shaped for `b52` | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (1.2 (c), n=1) |
| Spec 011 deferred/owner-decision tasks (`T001`-`T008`, `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) | each is wider than one row or awaits an owner decision | `git log 26c6b91ed..ecc05e480 --oneline -- csi-spl-doc/specs/011-spool-project-refactor` (0 commits; 1.2 (d), n=1) |

## 8. Changes

- v0.1 (a-260): the rows and every read on `ecc05e480`; both heads built in scratch
  clones; the 13-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; both red controls
  (`rc1`, `rc2`) and all 6 mutation checks (`m1a`, `m1b`, `m1c`, `m2a`, `m2b`, `m2c`) run
  in fresh scratch clones and verified RED; all helper, caller, and test hunks included
  verbatim in 1.3 and 1.4. Pushed to `review/c002-refactor-round-09-planner` (`feb3c1917`).
- v1.0 (a-260): folded cross-vendor claude panel (`c-342`, review on v0.1 `feb3c1917`,
  seat commit `27ea94e2fca980e35b1690077429c476c9f2b72a`, msg `567f5081` / holder
  `bbaa6d1f`) W1-W2 and N1/N4/N6, and recorded N2-N3/N5 (no row change; 7 of 8 fenced
  `bash` blocks byte-identical to v0.1 `feb3c1917`, only row 02's `wui-actions.tst.sh`
  block updated for W1; zero drift across all 7 row files from `ecc05e480` to
  `origin/master` `39bb380f8`; `lane-map.sh --check` on the 7 row files at 23:23:05Z exit
  4, 0 owned, 21 `unknown:` on the other box):
  - **W1 (1.4 / 1.5 / row 02 control):** added the standalone `do_wui_dev` ordering check
    where `do_lde_cnf` returns 1, asserting rc 1 with no `REQ:pnpm` and no `PNPM:` line.
    Updated head2's `wui-actions.tst.sh` sha256 (`30c31e86be17` -> `58549a27df33`, `+73 -0`,
    141 -> 214 lines; other 3 head2 files and all 3 head1 files unchanged). Re-verified in
    fresh scratch clones of `ecc05e480`: head2 `0/39/0`, `rc2` `1/31/8`, `m2a` `1/35/4`,
    `m2b` `1/37/2`, `m2c` `1/37/2`, `m2d` (swapping `_wui_prepare` above `do_lde_cnf`,
    panel `x2d`) `1/37/2` (`FAIL: standalone wui-dev order`); `shellcheck -S warning -x`
    and `do_sec_shellcheck` rc 0.
  - **W2 (1.4 shape & section 5):** reworded `do_wui_dev calling _wui_prepare + _wui_prepare`
    to `do_wui_dev (calling it) + _wui_prepare`.
  - **N1 (1.5, section 2, section 5):** recorded that `test-y18-grok-memory.sh` pass counts
    depend on whether `grok` is on `PATH` (13/15/23 without `grok`, 15/17/25 with `grok`;
    identical rc and fail sets); updated row 01 table and brief to quote rc and fail sets.
  - **N2:** recorded that `WUI_DIR` is a caller-scoped local and `git grep WUI_DIR -- csi-spl-wui/`
    returns 0 hits on `ecc05e480` (no effect even if exported).
  - **N3:** recorded that the dispatcher candidates file lives on the planner/holder box
    only and was not remotely readable by the panel seat.
  - **N4 (1.1):** spelled out the full rulebook 4.4 `awk` command and recorded panel's
    re-measure (`perf 36 refactor 113 perf-share 24.2% floor-met` at 23:18:03Z).
  - **N5:** recorded panel's lane-map check (exit 4, 9 `unknown:` on the planner box, 0
    owned) and 48 h branch check (0 of 36 moved branches touch the 7 row paths).
  - **N6 (section 7):** aligned the `r10` agent CLI wrapper entry to `3 action files + test`
    (matching 1.2 (a)'s 3 files).
  Pushed fast-forward to `review/c002-refactor-round-09-planner` (`0c05b9703`), signed by
  `c-342` (seat commit `11960d121`, msg `e0eebeaa` / holder `46cbe558`,
  `do_spl_review_line_check` rc 0 on panel box, `REVIEW_LINE_SYNTAX=1` rc 0 on planner
  box, holder `c-002` GO LAND `b1c5f03e`), and landed on `origin/master` at `861ad6d57`.
- closed (a-260): both rows landed on `origin/master`, cross-vendor agy R7 PASS, push
  scanners/ingest green (measured on `origin/master` `dd3588e4d` at `2026-11-27T01:02Z`,
  n=1):
  - r09-01 `2305d56ec` (`2305d56ecd62b1186186598a44de3788268780a0`, SPL-6640, author
    `c-290` claude, committed `2026-11-27T02:24:24+02:00`): R7 `a-294` agy **PASS** on
    `73cee5845` (`73cee584506460a1d41016f6d118cc55e0226d1f`; `do_spl_review_line_check`
    rc 0, `OK 12 of 12`, 12 commands read); `git patch-id --stable`
    `f8f2485c3003affa772b79182c1fd7d48171ca01` equal on both, `git diff 73cee5845
    2305d56ec -- <3 files>` empty (C7), zero drift to `dd3588e4d`. CI on `2305d56ec`: push
    workflows 16 (`45916632028`) and 67 (`45916632058`) **success** (1 skipped workflow 12
    `45916715714`); workflow 10 (`45916632027`) was cancelled by subsequent master push
    (`ce158c1fe`, cancelled by `a1db1addf` whose covering R11 workflow 10 run
    `45917082371` is `in_progress` with `distribution-hygiene`, `release-note`, `iac`,
    `orc: feature tests`, and `orc` shard `4/4` already **success**, and `dd3588e4d` run
    `45919396527` also `in_progress`). Diff (`git show --numstat`, exact 3 files):
    `orc:src/bash/run/spl-grok-memory-install.func.sh` `+16 -25` (sha256 `50391c1df5bb`),
    `orc:src/bash/run/spl-agy-memory-install.func.sh` `+6 -31` (sha256 `60f5071ab943`),
    `orc:src/bash/features/spool-install/tests/test-y18-grok-memory.sh` `+65 -0` (sha256
    `4c0375ed42ea`), matching plan 1.3 head1 / section 6 verbatim. R7 notes: N1
    informational (`test-y18-grok-memory.sh:104-112` 2 live `grok` checks skipped and
    `test-y20-agy-memory.sh` 2 live `agy` checks skipped, matching parent and plan 1.5).
  - r09-02 `a1db1addf` (`a1db1addf4bdba1fc61785568c377989dd863916`, SPL-6641, author
    `c-372` claude, committed `2026-11-27T01:29:22+01:00`): R7 `a-297` agy **PASS** on
    `44bd019b5` (`44bd019b5b2c952b820c43608a51b7f99c0dc7b3`; `do_spl_review_line_check`
    rc 0, `OK 10 of 10`, 13 commands read); `git patch-id --stable`
    `d9a77f2523432ee2db50a1d1f711c17acf0109cc` equal on both, `git diff 44bd019b5
    a1db1addf -- <4 files>` empty (C7), zero drift to `dd3588e4d`. CI on `a1db1addf`: push
    workflows 16 (`45917082448`) and 67 (`45917082283`) **success** (plus schedule 00
    `45917832681`, 21 `45917522612` & `45919206945`, 40 `45917665230` and workflow_run 12
    `45918635026` **success**; 2 skipped workflow 12 `45917090251`, `45917178864`);
    workflow 10 (`45917082371`, covering both `r09-01` and `r09-02`) is `in_progress` (and
    `dd3588e4d` run `45919396527` `in_progress`). Diff (`git show --numstat`, exact 4
    files): `orc:src/bash/run/wui-dev.func.sh` `+15 -8` (sha256 `d863b23a49f1`),
    `orc:src/bash/run/wui-build.func.sh` `+8 -11` (sha256 `04930c0f2976`),
    `orc:src/bash/run/wui-test.func.sh` `+6 -9` (sha256 `97d8fa671ff3`),
    `orc:src/bash/tests/wui-actions.tst.sh` `+73 -0` (sha256 `58549a27df33`), matching
    plan 1.4 head2 / section 6 verbatim. R7 notes: N1 `wui-actions.tst.sh:142` `trap` does
    not clobber any prior trap; N2 `do_check_pre_push` ran 13/13 PASS in detached worktree
    (all 4 row orc tests run directly on head and passed).
  - **R5, R6, 2.7.5, and post-land verification on `dd3588e4d`:** `git merge-base
    --is-ancestor <row> origin/master` rc 0 and box checkout (`dd3588e4d`) ancestry rc 0
    for both (both `csi-spl-orc` Bash only, no hub or WUI deploy required). R6 (`git log
    origin/master --since="2026-11-27T00:36:21+02:00" --format='%H %cI %s' -E
    --grep='\(r09-'`) returns both rows (`a1db1addf`, `2305d56ec`) and the 2 plan commits
    (`861ad6d57`, `f730e6806`). Review count (2.7.5): 2 of 2 row reviews
    (`review: a-294 agy PASS`, `review: a-297 agy PASS`; 3 total `^review: ` lines under
    `\(r09-` including plan signature `review: c-342 claude PASS`), both row reviews
    cross-vendor to their claude authors (`c-290`, `c-372`); no claude waiver seat was
    needed. Post-land `git grep` on `dd3588e4d`:
    - `git grep -l "spool-install/steps/" origin/master -- csi-spl-orc/src/bash/run/ | ... | git grep -n "s/\^SPOOL_AGENT_USER=//p"`
      returns **1 file only** (`csi-spl-orc/src/bash/run/spl-git-pager-off-install.func.sh:39`,
      down from 3 on `ecc05e480`; **5/5** per-user `spool-install` actions now share
      `_spl_user_step_install`). `_spl_memory_step_install` exists once at
      `csi-spl-orc/src/bash/run/spl-grok-memory-install.func.sh:29` with 1
      `--git-common-dir` derivation (`:34`), called by `spl-grok-memory-install` (`:19`)
      and `spl-agy-memory-install` (`:23`).
    - `_wui_prepare` exists once at `csi-spl-orc/src/bash/run/wui-dev.func.sh:24` with 1
      `pnpm install` (`:30`), called by all **3/3** local WUI `pnpm` actions
      (`wui-dev.func.sh:13`, `wui-build.func.sh:14`, `wui-test.func.sh:10`).
  - **Round close & teardown:** orchestrator GC (`c-001`, msg `7f6c9963`) confirmed both
    rows landed on `origin/master` and requested the close record with `Closes: SPL-6632`.
    `do_spl_lane_map --all` at `01:02Z` shows editor `a-260` and row authors `c-290`,
    `c-372` still live for r09 (`c-342`, `a-294`, `a-297` already gone). Remote branches
    remaining on `origin` for R8 prune (`PRUNE_SINCE=2026-11-27T00:36:21+02:00`):
    `review/c002-refactor-round-09-claude-seat` (`11960d121`);
    `review/c002-refactor-round-09-planner`, `review/r09-01`, and `review/r09-02` are
    already absent from `origin`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-260 (agy): v0.1 (`feb3c1917`), v1.0 (`0c05b9703`, landed `861ad6d57`),
  close record.
- Panel reviewer seat: c-342 (claude, seat `11960d121805f13027f2a11acd3347ad92373e14` on
  `review/c002-refactor-round-09-claude-seat`):
  - v0.1 `feb3c1917bb2b27788ae1de13c32a6cb080e3149`: PASS with W1-W2 (seat commit
    `27ea94e2f`, msg `567f5081` / holder `bbaa6d1f`; W1-W2 and N1/N4/N6 folded in v1.0,
    N2-N3/N5 recorded).
  - v1.0 `0c05b9703265e99a4676421edf6af5ea7aeeaba1`: **PASS** (seat commit
    `11960d121805f13027f2a11acd3347ad92373e14`, msg `e0eebeaa` / holder `46cbe558`;
    `do_spl_review_line_check` rc 0 on panel box, `REVIEW_LINE_SYNTAX=1` rc 0 on planner
    box; holder `c-002` GO LAND `b1c5f03e`; 7 of 8 fenced `bash` blocks byte-identical to
    v0.1, W1 verified with `m2d`, zero open W).
- Row R7 seats: section 4; both agy: a-294 (r09-01), a-297 (r09-02) (section 8, round
  closed).
