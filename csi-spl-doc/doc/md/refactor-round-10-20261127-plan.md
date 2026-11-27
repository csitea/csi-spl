# Refactoring round 10 (2026-11-27) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6649  
Topic: 4bed0606-1a32-402b-9bf9-9859f40a7eaa  
Discussion: 4bed0606-1a32-402b-9bf9-9859f40a7eaa (t1 #refactoring, "Refactor round 10", opened by c-003)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3). Because the older
  cycle already created `refactor-round-10-plan.md`, `refactor-round-10-retro.md`, and
  `refactor-round-10/` on `origin/master`, this round carries its open date per rulebook
  5.3 and orchestrator ruling `e79facef` (option B): plan
  `refactor-round-10-20261127-plan.md`, retro `refactor-round-10-20261127-retro.md`,
  seat dir `refactor-round-10-20261127/`, Qto doc title the same, rows `r10-<NN>`,
  commit scope `docs(r10-plan, SPL-6649)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
  `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 06:12:24Z reported
  `main=claude`, `backup=agy`, `pick=claude` (`claude` 6/16 = 38% vs 100% effective
  weight; `agy` paused in instance settings until 2026-11-27T08:05:25Z, `grok` and
  `qwen` off in instance settings, `codex` no CLI). Per R14 and the brief (cross-vendor
  `agy` R7 for `claude` code rows), both rows are assigned **vendor claude** with
  **agy R7** (claude waiver backup only while agy is out of quota, under ruling
  `dc84300a`; never mistral; re-checked at placement).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 09 ([refactor-round-09-plan.md](refactor-round-09-plan.md),
editor `a-260`) is closed (`e91066a01`, SPL-6632): both rows landed on `origin/master`
with cross-vendor agy R7 PASS (`r09-01` `2305d56ec`, SPL-6640; `r09-02` `a1db1addf`,
SPL-6641); nothing of r09 remains unlanded. The perf floor (rulebook 4.4), re-measured on
`84f86ab8c` at 2026-11-27T06:11:06Z (14 days):
`perf 36 refactor 113 perf-share 24.2% floor-met` (5 x 36 = 180 >= 149), so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), non-secret, with zero
behaviour change:
- **Row 01 (`_spl_agent_cli_prep` and `_spl_agent_cli_exec` agent CLI installer wrappers — 4 files):**
  `orc:src/bash/run/install-agy-cli.func.sh:23-57` extracts `_spl_agent_cli_prep`
  (shared `yq` check, `<org>-<app>` parse, cnf lookup and readability check, semver
  `X.Y.Z` pin validation returning exit 2, `DRY_RUN` validation, `spool-env.inc.sh`
  resolution, and agent user/home check) and `_spl_agent_cli_exec` (shared direct-user
  vs `sudo -n -u` execution with `HOME` and env pairs), and
  `orc:src/bash/run/install-mistral-vibe.func.sh:25-53` and
  `orc:src/bash/run/install-openai-codex.func.sh:28-56` lazy-load `install-agy-cli.func.sh`
  and delegate to both helpers (3/3 `install.sh --cli <name> --cli-only` wrappers in
  `orc:src/bash/run/` consolidated; closes r09 section 7 #1), guarded by section `9` in
  `orc:src/bash/tests/install-agy-cli.tst.sh`.
- **Row 02 (`_utl_send_spool_note` spool note sender — 3 files):**
  `utl:src/bash/run/reboot-required-check.func.sh:82-103` extracts `_utl_send_spool_note`
  (shared `spool-send.sh` override -> `PROJ_PATH` sibling -> `PATH` lookup, missing-sender
  `WARN` with caller's label, `SPOOL_ROOT` note send, and failure `WARN`) and delegates
  `_rrc_send` to it, and `utl:src/bash/run/cron-heartbeat-snitch.func.sh:201-222`
  lazy-loads `reboot-required-check.func.sh` inside `_chs_send` (zero load cost on
  `DRY_RUN=1` or `--wrap`/`--beat`) and delegates to `_utl_send_spool_note`, guarded by
  section `14` in `utl:src/bash/tests/reboot-required-check.tst.sh`.

The two rows touch different sub-projects (`csi-spl-orc/` vs `csi-spl-utl/`) and share no
file: both are **Batch 1**.

**Status: v1.0 for panel sign-off.** Editor: **a-546** (agy). Panel seat: cross-vendor
claude panel seat **c-420** (`c003-refactor-round-10-claude-panel-seat`, v0.1 FAIL
`33502ecbc` msg `e8c2c01e` / holder `35462d95`; W1-W3 and N1-N4 folded in v1.0; all 9
fenced `bash` blocks byte-identical to v0.1 `25212ee7f`; zero drift on all 10 checked
paths from `84f86ab8c` to `origin/master`).

**One sha:** every count is measured on **`84f86ab8c`**
(`84f86ab8c2f6daf774bef27ea34bbfb1aa1172fc`, `origin/master` at 2026-11-27T06:11:06Z),
n=1 per command unless stated. Reads are on `84f86ab8c` with `git show` / `git grep`. The
tests of 1.5 ran in scratch clones checked out at `84f86ab8c` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a fresh scratch clone of its own. All helper, caller, and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 6 mutation checks byte-for-byte on `84f86ab8c` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window, slug proof, and ruling `e79facef` conditions (rulebook 5.3)

2026-11-27T06:11:06Z-06:11:12Z, n=1, after a fresh fetch (`git-fetch-fresh.sh --force`):

- **Window: W=2026-11-27T03:05:11+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r09-plan'`:
  `e91066a01e7299076a3e81bc146038e09faab0cb`
  (`docs(r09-plan, SPL-6632): refactor round 09 closed: r09-01 2305d56ec and r09-02 a1db1addf landed, agy R7 PASS each`),
  read once at the start as 5.3 says. All later R4, R6, 2.7.5, and `PRUNE_SINCE` reads
  for r10 use `W=2026-11-27T03:05:11+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'` ->
  `perf 36 refactor 113 perf-share 24.2% floor-met` (5 x 36 = 180 >= 149).
- **Slug proof since `W`:**
  `git log origin/master --since="2026-11-27T03:05:11+02:00" --oneline -E --grep='\(r10-' | wc -l` -> **0**.
- **Ruling `e79facef` (option B) condition (i) — known before-window old-cycle heads:**
  `git ls-remote origin 'refs/heads/review/r10-*' 'refs/heads/wip/*r10*' 'refs/heads/*-r10-*' 'refs/heads/*refactor-round-10*'`
  returns exactly **3** old-cycle heads (all holding unlanded commits, all tips older than
  `W=2026-11-27T03:05:11+02:00`, never deleted):
  1. `refs/heads/review/c002-wui-con-r10-session-check-signed-out` —
     `30fa039da5c7e81e9983c094186e1f596c96a6a6`, tip `2026-10-31T03:49:36+02:00`
     (`fix(wui, SPL-4456): the session probe reads 200 {"signed_in":false} as signed out`)
  2. `refs/heads/wip/fix/r10-05-helper-path` —
     `b8d8c452830685d8b436bc1df192f7cf4a05fc83`, tip `2026-10-15T00:46:33+03:00`
     (`wip(m-135): 20261014T214633Z handoff`)
  3. `refs/heads/wip/m-524-r10-mistral-review-seat` —
     `0c6f50f9b3b40e1a1f0e730abbec278ee66fb5a3`, tip `2026-10-14T23:38:19+03:00`
     (`docs(refactor, SPL-1880): r10 mistral review row 04 PASS`)
  Zero other `r10` or `refactor-round-10` heads exist on `origin` (before this plan's
  review branch push).
- **Ruling `e79facef` (option B) condition (ii) — pre-prune DRY check:**
  `cd csi-spl-orc && ROUND=10 PRUNE_SINCE="2026-11-27T03:05:11+02:00" DRY_RUN=1 ./run -a do_git_prune_round_branches`
  (run at 06:11:09Z, n=1) printed:
  - `WINDOW r10 W=2026-11-27T03:05:11+02:00`
  - `KEEP wip/fix/r10-05-helper-path before-window 2026-11-27T03:05:11+02:00`
  - `KEEP wip/m-524-r10-mistral-review-seat before-window 2026-11-27T03:05:11+02:00`
  - `OK DRY_RUN round r10: 0 branch(es) listed, 0 kept unlanded, 2 before the window on origin, nothing deleted (DRY_RUN=0 deletes the listed)`
  **Note on head 1 (`review/c002-wui-con-r10-session-check-signed-out`):** it prints no
  `KEEP` line because `prune_round_match`
  (`orc:src/bash/run/git-prune-round-branches.func.sh:77-84`) matches only
  `review/r10-*`, `^(review/)?[acgmq]-[0-9]{3}-r10-`, and `^wip/(.*[^0-9A-Za-z])?r10([^0-9].*)?$`.
  `review/c002-wui-con-r10-session-check-signed-out` is completely unmatched, never enters
  the candidate list (`0 branch(es) listed`), and cannot be deleted by R8's prune. R8
  still runs this exact DRY check before `DRY_RUN=0` and stops to tell the holder if any
  of the 3 appears as a `REF` line.
- **Ruling `e79facef` (option B) condition (iii) — existing `refactor-round-10` files:**
  `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-10`
  returns **3** old-cycle entries: `refactor-round-10-plan.md`,
  `refactor-round-10-retro.md`, and `refactor-round-10/`. Therefore this round uses the
  dated paths `refactor-round-10-20261127-plan.md`, `refactor-round-10-20261127-retro.md`,
  and `refactor-round-10-20261127/` (0 existing hits on `origin/master`).
- **Briefs on the planner/holder box:**
  `ls /var/spool-hub/dispatch/briefs | grep -E 'r10-[0-9]{2}|refactor-round-10'` (local to
  the planner/holder box only) shows, beyond this planner's brief and the panel seat's
  brief (`c003-refactor-round-10-claude-panel-seat.md`):
  - 1 other-box handoff copy of this cycle's planner brief (from the 2026-11-27 01:50Z
    placement cycle; 0 `r10-NN` row briefs for this cycle);
  - 2 `refactor-round-100` briefs from 2026-11-25 (not r10);
  - 32 old-cycle r10 briefs/drafts (`c001-r10-01..10` plus `.bak-*`,
    `c002-refactor-round-10-planner.md`, `refactor-round-10-planner.md`,
    `refactor-round-10-planner.drafts/`, `r10-*`, `c119-r10-*`, `c002-*-r10-*`, all dated
    before `W`).

### 1.2 The brief's inputs, re-measured

- **(a) r09 section 7:** re-read on `84f86ab8c`:
  - Agent CLI installer wrappers (r09 section 7 #1):
    `git show 84f86ab8c:csi-spl-orc/src/bash/run/install-{agy-cli,mistral-vibe,openai-codex}.func.sh`
    confirms all 3 wrappers (`install-agy-cli.func.sh:23-57` 57L,
    `install-mistral-vibe.func.sh:25-53` 53L, `install-openai-codex.func.sh:28-56` 56L)
    are unchanged since r09, non-secret, and duplicate the ~24-line `yq` / `org_app` /
    `cnf` / semver pin / `DRY_RUN` / `spool-env.inc.sh` / `getent passwd` / `as_agent`
    wrapper over `install.sh --cli <name> --cli-only` -> **row 01** (1.3).
  - Remaining r09 section 7 items (3 kept-out `is a linked worktree:` files,
    `spl-issue-blocker-rca-close` / `spl-issue-owner-question-diss`, non-matching cron
    installers, secret-class probe / `gcp-*` actions, PG-heavy actions) remain accounted
    for in section 7.
  - Broad duplicate-block scan across `orc:src/bash/run/*.func.sh`,
    `iac:src/bash/run/*.func.sh`, and `utl:src/bash/run/*.func.sh` on `84f86ab8c`
    surfaced an exact 21-line byte-for-byte duplicate in `csi-spl-utl/src/bash/run/`:
    `_rrc_send` (`reboot-required-check.func.sh:82-103`) and `_chs_send`
    (`cron-heartbeat-snitch.func.sh:201-222`), both non-secret, zero-PG, fast hermetic
    tests (`reboot-required-check.tst.sh`, `cron-heartbeat-snitch.tst.sh`), differing only
    in the override env var and the missing-sender label -> **row 02** (1.4). Note (W2):
    this is the pair r98 (`:756`) and r99 (`:838`) left out because touching
    `csi-spl-utl/` has no narrow case in `ci-doc-only.sh:124` (`28ed98f7a` classifies as
    `parts=all`); we name and accept this one-time night-phase full-CI cost here. The scan
    also surfaced two clean `r11` follow-ups (`utl:src/bash/run/` 6 `*_SEND_CMD` spool
    note senders and `orc:src/bash/run/install-force-push-guard.func.sh` +
    `spl-cmd-guard-mode.func.sh` user-home resolution), recorded in section 7.
- **(b) R7 notes of r09-01 (`a-294` agy), r09-02 (`a-297` agy), and r09 panel (`c-342`):**
  Read from the r09 close record (`e91066a01`, `refactor-round-09-plan.md` section 8):
  - `r09-01` (`2305d56ec`, SPL-6640, R7 `a-294` PASS): N1 informational (2 live `grok` /
    2 live `agy` checks skipped when CLI absent, matching parent). No refactor follow-up.
  - `r09-02` (`a1db1addf`, SPL-6641, R7 `a-297` PASS): N1 `wui-actions.tst.sh:142` `trap`
    clobbers no prior trap; N2 `do_check_pre_push` 13/13 PASS. No refactor follow-up.
  - r09 panel (`c-342`) W1-W2 and N1/N4/N6 were folded in r09 v1.0; N2-N3/N5 were
    informational. No open r09 refactor follow-up.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to the planner/holder
  box only; 173 lines, read 06:10Z):
  - New entries since r09 (lines 169-173): both bug-shaped for `b53`
    (`dispatch-rotate.tst.sh` case 32 flake; stale `hours.md` help text waiting on T085
    SPL-6648).
  - Earlier open refactor-labelled entries (lines 113 `_ppe_keys`, 115
    `i18n-lang-review-exempt.json:2`, 125 WUI entry-chunk headroom) remain accounted for in
    section 7.
- **(d) spec 011 tasks:**
  `git log e91066a01..84f86ab8c --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r09; remaining open/partial tasks (`T001`-`T008` owner-deferred,
  `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `_spl_agent_cli_prep` and `_spl_agent_cli_exec` (`install-agy-cli`, `install-mistral-vibe`, `install-openai-codex`)

`orc:` = `csi-spl-orc/`. On `84f86ab8c`:

- Three agent CLI installer wrappers in `orc:src/bash/run/` wrap
  `spool-install/install.sh --cli <name> --cli-only` and duplicate the identical ~24-line
  setup and target-user execution block (`do_require_bin yq`, `PROJ_PATH` `<org>-<app>`
  regex, `all.env.yaml` lookup and `-r` check, `yq` semver `X.Y.Z` validation returning
  exit 2, `DRY_RUN` `0|1` validation, `spool-env.inc.sh` `spool_env_resolve`, `getent
  passwd` home check, and direct vs `sudo -n -u` invocation with `HOME` and env vars):
  1. `orc:src/bash/run/install-agy-cli.func.sh:23-57` (57 lines; cnf key `agy_cli`,
     default pin `"1.3.4"`, pin noun `"one X.Y.Z"`, default `DRY_RUN=1`, post-install
     `agy --version` read-back).
  2. `orc:src/bash/run/install-mistral-vibe.func.sh:25-53` (53 lines; cnf key
     `mistral_vibe`, default pin `""`, pin noun `"one pinned X.Y.Z"`, default
     `DRY_RUN=0`, extra `yq` read of `.env.box.mistral_vibe.model`).
  3. `orc:src/bash/run/install-openai-codex.func.sh:28-56` (56 lines; cnf key
     `openai_codex`, default pin `""`, pin noun `"one pinned X.Y.Z"`, default
     `DRY_RUN=1`).
- Hosting `_spl_agent_cli_prep` and `_spl_agent_cli_exec` in `install-agy-cli.func.sh`
  adds zero new files and zero eager loads; `install-mistral-vibe.func.sh` and
  `install-openai-codex.func.sh` lazy-source `install-agy-cli.func.sh` only when
  `_spl_agent_cli_prep` is not yet defined. `_spl_agent_cli_prep` sets caller-scoped
  locals `inst`, `cnf`, `pin`, `agent`, `home`, and `dry` (and preserves exit 2 on bad
  pin, exit 1 on all other setup errors); `_spl_agent_cli_exec` takes
  `<agent> <home> [K=V ...] -- <cmd...>`.
- None of the 4 edited files reads or writes any secret, key, or credential (each wrapper's
  header and test suite explicitly verifies keys/tokens are never read or leaked;
  non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_install_agy_cli` 35 -> 15 lines, `_spl_agent_cli_prep` 21 lines,
  `_spl_agent_cli_exec` 8 lines; `do_install_mistral_vibe` 29 -> 14 lines;
  `do_install_openai_codex` 29 -> 13 lines.
  None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/install-agy-cli.func.sh`: replace `:23-57` with thin
  `do_install_agy_cli` + `_spl_agent_cli_prep` + `_spl_agent_cli_exec`.
  57 -> 73 lines (`+38 -22`).
- `orc:src/bash/run/install-mistral-vibe.func.sh`: replace `:25-53` with lazy-source of
  `install-agy-cli.func.sh` + `_spl_agent_cli_prep` + `_spl_agent_cli_exec`.
  53 -> 38 lines (`+7 -22`).
- `orc:src/bash/run/install-openai-codex.func.sh`: replace `:28-56` with lazy-source of
  `install-agy-cli.func.sh` + `_spl_agent_cli_prep` + `_spl_agent_cli_exec`.
  56 -> 40 lines (`+6 -22`).
- `orc:src/bash/tests/install-agy-cli.tst.sh`: add section `9` to header after `:17`;
  insert section `9` immediately before `echo "---";` at `:122` (4 direct
  `_spl_agent_cli_prep` checks, 1 `_spl_agent_cli_exec` check, 3 one-copy checks across
  all 3 wrappers, and 2 standalone lazy-load checks for `do_install_mistral_vibe` and
  `do_install_openai_codex` verifying their `DRY_RUN` defaults and installer env vars).
  122 -> 188 lines (`+66 -0`). Total edited files: **4** (within rulebook 3.1's max 5).
- head1's files, sha256 (12 chars): `install-agy-cli.func.sh` `c4be5c07a861`,
  `install-mistral-vibe.func.sh` `9a20298cf130`,
  `install-openai-codex.func.sh` `31a4d618289f`,
  `install-agy-cli.tst.sh` `63e7a2d81d1d`.

Verbatim helper, caller, and test hunks (head1 on `84f86ab8c`):

`orc:src/bash/run/install-agy-cli.func.sh` (replace `:23-57`):
```bash
do_install_agy_cli() {
  local inst cnf pin agent home have cur rc=0 dry=()
  _spl_agent_cli_prep agy_cli "1.3.4" "one X.Y.Z" 1 \
    "${AGY_CLI_INSTALLER:-}" "${AGY_CLI_CNF:-}" "${AGY_CLI_AGENT_HOME:-}" || return $?
  do_log "INFO agy $pin or newer (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)"
  local args=(--cli agy --cli-only "${dry[@]}") envs=(SPOOL_INSTALL_AGY_VERSION="$pin")
  _spl_agent_cli_exec "$agent" "$home" "${envs[@]}" -- bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli agy exited $rc"; return "$rc"; }
  [[ "${DRY_RUN:-1}" == 1 ]] && { do_log "OK DRY_RUN=1: nothing changed"; return 0; }
  have="$home/.local/bin/agy"
  [[ -x "$have" ]] || have="$(_spl_agent_cli_exec "$agent" "$home" "${envs[@]}" -- bash -lc 'command -v agy' 2>/dev/null)"
  cur="$(_spl_agent_cli_exec "$agent" "$home" "${envs[@]}" -- "${have:-agy}" --version 2>/dev/null | sed -n 1p)"
  [[ -n "$cur" ]] || { do_log "FAIL agy --version as $agent printed nothing (${have:-no agy})"; return 4; }
  do_log "OK agy $cur for $agent ($have), pin $pin"
}

# _spl_agent_cli_prep <cnf_key> <def_pin> <pin_noun> <def_dry> <inst_ovr> <cnf_ovr> <home_ovr>
# Validates yq, <org>-<app>, cnf, X.Y.Z pin, DRY_RUN, agent user, and agent home;
# sets caller-scoped inst, cnf, pin, agent, home, and dry array.
_spl_agent_cli_prep() {
  local key="$1" def_pin="$2" pin_noun="$3" def_dry="$4" inst_ovr="$5" cnf_ovr="$6" home_ovr="$7" org_app
  do_require_bin yq || return 1
  inst="${inst_ovr:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  cnf="${cnf_ovr:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  pin="$(yq -r ".env.box.$key.version // \"$def_pin\"" "$cnf")"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    do_log "FATAL cnf env.box.$key.version must be $pin_noun, got '$pin': never latest ($cnf)"; return 2; }
  dry=()
  case "${DRY_RUN:-$def_dry}" in 0) ;; 1) dry=(--dry-run) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER"; return 1; }
  home="${home_ovr:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { do_log "FATAL no home for the agent user $agent: $home"; return 1; }
}

# _spl_agent_cli_exec <agent> <home> [K=V ...] -- <cmd...>
# Run <cmd...> as <agent> in <home> with the given env vars (itself: no sudo).
_spl_agent_cli_exec() {
  local agent="$1" home="$2" envs=()
  shift 2
  while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" env "${envs[@]}" "$@"
  else sudo -n -u "$agent" -H env "${envs[@]}" "$@"; fi
}
```

`orc:src/bash/run/install-mistral-vibe.func.sh` (replace `:25-53`):
```bash
do_install_mistral_vibe() {
  local inst="" cnf="" pin="" model agent="" home="" rc=0 dry=()
  # shellcheck source=install-agy-cli.func.sh
  declare -F _spl_agent_cli_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/install-agy-cli.func.sh" || return 1
  _spl_agent_cli_prep mistral_vibe "" "one pinned X.Y.Z" 0 \
    "${MISTRAL_VIBE_INSTALLER:-}" "${MISTRAL_VIBE_CNF:-}" "${MISTRAL_VIBE_AGENT_HOME:-}" || return $?
  model="$(yq -r '.env.box.mistral_vibe.model // ""' "$cnf")"
  do_log "INFO mistral-vibe $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)"
  local args=(--cli mistral --cli-only "${dry[@]}")
  _spl_agent_cli_exec "$agent" "$home" SPOOL_INSTALL_MISTRAL_VERSION="$pin" SPOOL_INSTALL_MISTRAL_MODEL="$model" \
    -- bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli mistral exited $rc"; return "$rc"; }
  do_log "OK mistral-vibe $pin for $agent"
}
```

`orc:src/bash/run/install-openai-codex.func.sh` (replace `:28-56`):
```bash
do_install_openai_codex() {
  local inst="" cnf="" pin="" agent="" home="" rc=0 dry=()
  # shellcheck source=install-agy-cli.func.sh
  declare -F _spl_agent_cli_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/install-agy-cli.func.sh" || return 1
  _spl_agent_cli_prep openai_codex "" "one pinned X.Y.Z" 1 \
    "${OPENAI_CODEX_INSTALLER:-}" "${OPENAI_CODEX_CNF:-}" "${OPENAI_CODEX_AGENT_HOME:-}" || return $?
  do_log "INFO @openai/codex $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)${dry:+, DRY RUN}"
  local args=(--cli codex --cli-only "${dry[@]}")
  _spl_agent_cli_exec "$agent" "$home" SPOOL_INSTALL_CODEX_VERSION="$pin" -- bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli codex exited $rc"; return "$rc"; }
  (( ${#dry[@]} )) && { do_log "OK dry run: nothing installed (DRY_RUN=0 installs)"; return 0; }
  do_log "OK @openai/codex $pin for $agent"
}
```

`orc:src/bash/tests/install-agy-cli.tst.sh` (append to header after `:17`; insert section
`9` immediately before `echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }` at `:122`, followed by one blank line; `:121` is already blank):
```bash
#   9. _spl_agent_cli_prep / _spl_agent_cli_exec helpers, one-copy across all
#      3 agent CLI wrappers, and standalone lazy-load checks (r10-01)
```
```bash
# --- 9. _spl_agent_cli_prep / _spl_agent_cli_exec and one-copy (r10-01) --------------------------------
cli_prep_run() {
  local dry_env="$1"; shift
  PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" DRY_RUN="$dry_env" bash -c '
    set -uo pipefail
    do_require_bin() { command -v "$1" >/dev/null; }
    do_log() { echo "$*"; }
    inst="" cnf="" pin="" agent="" home="" dry=()
    . "$1/src/bash/run/install-agy-cli.func.sh"
    _spl_agent_cli_prep "${@:2}" || exit $?
    printf "OK inst=%s cnf=%s pin=%s agent=%s home=%s dry=%s\n" "$inst" "$cnf" "$pin" "$agent" "$home" "${dry[*]:-none}"' _ "$PROJ_ROOT" "$@" 2>&1
}
out="$(cli_prep_run 1 agy_cli 1.3.4 "one X.Y.Z" 1 "$T/www/install.sh" "$T/cnf.yaml" "$H")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK inst=$T/www/install.sh cnf=$T/cnf.yaml pin=1.3.4 agent=$ME home=$H dry=--dry-run"* ]] &&
  pass "9: _spl_agent_cli_prep sets inst, cnf, pin, agent, home, and dry array" || fail "9: prep ok ($rc: $out)"
out="$(cli_prep_run 2 agy_cli 1.3.4 "one X.Y.Z" 1 "$T/www/install.sh" "$T/cnf.yaml" "$H")"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DRY_RUN must be 0 or 1"* ]] &&
  pass "9: _spl_agent_cli_prep refuses invalid DRY_RUN" || fail "9: prep dry ($rc: $out)"
out="$(cli_prep_run 1 agy_cli 1.3.4 "one X.Y.Z" 1 "$T/www/install.sh" "$T/no-such.yaml" "$H")"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no cnf $T/no-such.yaml"* ]] &&
  pass "9: _spl_agent_cli_prep refuses missing cnf" || fail "9: prep cnf ($rc: $out)"
out="$(cli_prep_run 1 agy_cli 1.3.4 "one X.Y.Z" 1 "$T/www/install.sh" "$T/cnf.yaml" "$T/no-home")"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no home for the agent user $ME: $T/no-home"* ]] &&
  pass "9: _spl_agent_cli_prep refuses missing agent home" || fail "9: prep home ($rc: $out)"
cat >"$T/exec-probe.sh" <<'EOF'
#!/usr/bin/env bash
printf 'H=%s F=%s B=%s\n' "$HOME" "${FOO:-}" "${BAZ:-}"
EOF
chmod +x "$T/exec-probe.sh"
out="$(bash -c 'set -uo pipefail; . "$1/src/bash/run/install-agy-cli.func.sh"
  _spl_agent_cli_exec "$2" "$3" FOO=bar BAZ=qux -- bash "$4"' _ "$PROJ_ROOT" "$ME" "$H" "$T/exec-probe.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "H=$H F=bar B=qux" ]] &&
  pass "9: _spl_agent_cli_exec sets HOME and env vars for the target agent" || fail "9: exec ($rc: $out)"

agy_f="$PROJ_ROOT/src/bash/run/install-agy-cli.func.sh"
vib_f="$PROJ_ROOT/src/bash/run/install-mistral-vibe.func.sh"
cdx_f="$PROJ_ROOT/src/bash/run/install-openai-codex.func.sh"
[[ "$(grep -c '^_spl_agent_cli_prep()' "$agy_f")" -eq 1 && "$(grep -c '^_spl_agent_cli_exec()' "$agy_f")" -eq 1 ]] &&
  pass "9: one copy: install-agy-cli.func.sh hosts _spl_agent_cli_prep and _spl_agent_cli_exec" || fail "9: host"
for wf in "$vib_f" "$cdx_f"; do
  own="$(grep -nE 'spool_env_resolve|getent passwd|sudo -n -u|cannot read <org>-<app>' "$wf" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [[ -z "$own" ]] && grep -q '_spl_agent_cli_prep ' "$wf" && grep -q '_spl_agent_cli_exec ' "$wf" &&
    pass "9: one copy: $(basename "$wf") delegates prep and exec to _spl_agent_cli_*" || fail "9: $(basename "$wf") own=[$own]"
done

cat >"$T/rec-inst.sh" <<'EOF'
#!/usr/bin/env bash
printf 'REC args=[%s] mv=%s mm=%s cv=%s home=%s\n' "$*" "${SPOOL_INSTALL_MISTRAL_VERSION:-}" "${SPOOL_INSTALL_MISTRAL_MODEL:-}" "${SPOOL_INSTALL_CODEX_VERSION:-}" "$HOME"
EOF
chmod +x "$T/rec-inst.sh"
printf 'env:\n  box:\n    mistral_vibe:\n      version: 2.26.0\n      model: m-test\n    openai_codex:\n      version: 0.166.0\n' >"$T/cli-cnf.yaml"
out="$(env -u DRY_RUN PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
  MISTRAL_VIBE_AGENT_HOME="$H" MISTRAL_VIBE_CNF="$T/cli-cnf.yaml" MISTRAL_VIBE_INSTALLER="$T/rec-inst.sh" bash -c '
  set -uo pipefail; do_require_bin() { command -v "$1" >/dev/null; }; do_log() { echo "$*"; }
  . "$1/src/bash/run/install-mistral-vibe.func.sh" && do_install_mistral_vibe' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"REC args=[--cli mistral --cli-only] mv=2.26.0 mm=m-test cv= home=$H"* && "$out" == *"OK mistral-vibe 2.26.0 for $ME"* ]] &&
  pass "9: standalone: install-mistral-vibe sourced alone defaults DRY_RUN=0 and runs installer" || fail "9: standalone vibe ($rc: $out)"
out="$(env -u DRY_RUN PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" \
  OPENAI_CODEX_AGENT_HOME="$H" OPENAI_CODEX_CNF="$T/cli-cnf.yaml" OPENAI_CODEX_INSTALLER="$T/rec-inst.sh" bash -c '
  set -uo pipefail; do_require_bin() { command -v "$1" >/dev/null; }; do_log() { echo "$*"; }
  . "$1/src/bash/run/install-openai-codex.func.sh" && do_install_openai_codex' _ "$PROJ_ROOT" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"REC args=[--cli codex --cli-only --dry-run] mv= mm= cv=0.166.0 home=$H"* && "$out" == *"OK dry run: nothing installed (DRY_RUN=0 installs)"* ]] &&
  pass "9: standalone: install-openai-codex sourced alone defaults DRY_RUN=1 and runs installer" || fail "9: standalone codex ($rc: $out)"
```

**Behaviour:** zero behaviour change. All three agent CLI wrappers preserve exact
validation ordering, exact `FATAL`/`INFO`/`FAIL`/`OK` messages, exact exit codes (`1`,
`2`, `4`), exact `DRY_RUN` defaults (`1` for agy and codex, `0` for mistral), exact cnf
pin defaults (`1.3.4` for agy, `""` for mistral and codex), and exact `HOME` + env
forwarding (both standalone checks pass on unmodified `base` too).

### 1.4 Row 02's site: `_utl_send_spool_note` spool note sender (`reboot-required-check`, `cron-heartbeat-snitch`)

`utl:` = `csi-spl-utl/`. On `84f86ab8c`:

- Two `csi-spl-utl` reliability checks duplicate the identical 21-line spool note sender
  (override env var -> `PROJ_PATH` sibling `spool-send.sh` -> `PATH` `spool-send.sh`,
  missing-sender `WARN`, `SPOOL_ROOT` note delivery via `bash "$send_bin" --from ... --to
  ... --kind note --task ... --body ...`, and failure `WARN`):
  1. `utl:src/bash/run/reboot-required-check.func.sh:82-103` (`_rrc_send`, 22 lines with
     comment; override `REBOOT_CHECK_ALERT_SEND_BIN`, missing label `"the reboot advice"`).
  2. `utl:src/bash/run/cron-heartbeat-snitch.func.sh:201-222` (`_chs_send`, 22 lines with
     comment; override `CRON_HB_ALERT_SEND_BIN`, missing label `"the cron alert"`).
- Hosting `_utl_send_spool_note` in `reboot-required-check.func.sh` adds zero new files
  and zero eager loads. `cron-heartbeat-snitch.func.sh` lazy-sources
  `reboot-required-check.func.sh` inside `_chs_send` only when `_utl_send_spool_note` is
  not yet defined, so normal `DRY_RUN=1` checks and `--wrap`/`--beat` runs incur zero
  extra sourcing cost (case 16 CPU budget in `cron-heartbeat-snitch.tst.sh` unchanged).
- None of the 3 edited files reads or writes any secret, key, or credential (non-secret).
- **CI cost (W2, accepted):** `ci-doc-only.sh:124` has no `csi-spl-utl/` narrow case
  (`28ed98f7a` classifies as `parts=all`), the reason r98 (`:756`) and r99 (`:838`) left
  this pair out. Landing row 02 triggers one full CI workflow 10 run (`parts=all`) during
  the night phase; this one-time CI cost is explicitly named and accepted to close the
  exact 21-line duplicate.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `_utl_send_spool_note` 20 lines, `_rrc_send` 3 lines; `_chs_send` 5 lines.
  None of the 3 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt` (`bash-cleancode.tst.sh:96` asserts
  `reboot-required-check.func.sh` is scanned by the clean-code gate and stays green).

Shape (built as head2 of 1.5):
- `utl:src/bash/run/reboot-required-check.func.sh`: replace `:82-103` with
  `_utl_send_spool_note` + thin `_rrc_send`. 229 -> 235 lines (`+11 -5`).
- `utl:src/bash/run/cron-heartbeat-snitch.func.sh`: replace `:201-222` with lazy-source of
  `reboot-required-check.func.sh` + `_utl_send_spool_note` call inside `_chs_send`.
  459 -> 443 lines (`+3 -19`).
- `utl:src/bash/tests/reboot-required-check.tst.sh`: add section `14` to header after
  `:18`; insert section `14` immediately before `echo "=========================================="`
  at `:205` (3 direct `_utl_send_spool_note` checks covering `PROJ_PATH` sibling
  discovery, missing sender with `<missing_label>`, and failing sender; 2 one-copy checks
  covering both files; and 2 standalone `_chs_send` lazy-load checks for delivery and
  missing-sender wording). 208 -> 273 lines (`+65 -0`). Total edited files: **3** (within
  rulebook 3.1's max 5).
- head2's files, sha256 (12 chars): `reboot-required-check.func.sh` `31c561a9057a`,
  `cron-heartbeat-snitch.func.sh` `ede6e55e8558`,
  `reboot-required-check.tst.sh` `42c0579ceea6`.

Verbatim helper, caller, and test hunks (head2 on `84f86ab8c`):

`utl:src/bash/run/reboot-required-check.func.sh` (replace `:82-103`):
```bash
# _utl_send_spool_note <from> <to> <task> <body> <send_bin_ovr> <missing_label>:
# resolve spool-send.sh (override > PROJ_PATH sibling > PATH) and send one
# spool note; return 0 on delivery, 1 on missing or failed sender.
_utl_send_spool_note() {
  local from="$1" to="$2" task="$3" body="$4" send_bin="$5" missing_label="$6"
  local orc_send="${PROJ_PATH:-}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  if [[ -z "$send_bin" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$orc_send" ]]; then
      send_bin="$orc_send"
    elif command -v spool-send.sh >/dev/null 2>&1; then
      send_bin="$(command -v spool-send.sh)"
    fi
  fi
  if [[ -z "$send_bin" || ! -f "$send_bin" ]]; then
    do_log "WARN no spool-send.sh found to send $missing_label"
    return 1
  fi
  if ! SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send_bin" \
    --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
    do_log "WARN failed to send spool note via $send_bin"
    return 1
  fi
}

# _rrc_send <from> <to> <task> <body>: one spool note; 0 when delivered.
_rrc_send() {
  _utl_send_spool_note "$1" "$2" "$3" "$4" "${REBOOT_CHECK_ALERT_SEND_BIN:-}" "the reboot advice"
}
```

`utl:src/bash/run/cron-heartbeat-snitch.func.sh` (replace `:201-222`):
```bash
# _chs_send <from> <to> <task> <body>: one spool note; 0 when delivered.
_chs_send() {
  # shellcheck source=reboot-required-check.func.sh
  declare -F _utl_send_spool_note >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/reboot-required-check.func.sh" || return 1
  _utl_send_spool_note "$1" "$2" "$3" "$4" "${CRON_HB_ALERT_SEND_BIN:-}" "the cron alert"
}
```

`utl:src/bash/tests/reboot-required-check.tst.sh` (append to header after `:18`; insert
section `14` immediately before `echo "=========================================="` at
`:205`, followed by one blank line; `:204` is already blank):
```bash
#  14. _utl_send_spool_note helper, one-copy across reboot-required-check and
#      cron-heartbeat-snitch, and standalone _chs_send lazy-load (r10-02)
```
```bash
# 14. _utl_send_spool_note helper and one-copy delegation (r10-02)
CHS_SH="$UTL_ROOT/src/bash/run/cron-heartbeat-snitch.func.sh"
mkdir -p "$T/fake-tree/csi-spl-utl" "$T/fake-tree/csi-spl-orc/src/bash/features/spawn-agents/scripts" "$T/empty-path" "$T/spool14"
cat > "$T/fake-tree/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" << 'S14_EOF'
#!/bin/bash
printf 'SIBLING SPOOL_ROOT=%s ARGS=%s\n' "$SPOOL_ROOT" "$*" >> "$S14_LOG"
S14_EOF
chmod +x "$T/fake-tree/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
S14_LOG="$T/s14.log"
: > "$S14_LOG"

out=$(S14_LOG="$S14_LOG" SPOOL_ROOT="$T/spool14" PROJ_PATH="$T/fake-tree/csi-spl-utl" bash -c '
  source "$1"; _utl_send_spool_note "from-a" "orchestrator" "task-a" "hello-a" "" "the demo alert"' _ "$FUNC_SH" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q -- "SIBLING SPOOL_ROOT=$T/spool14 ARGS=--from from-a --to orchestrator --kind note --task task-a --body hello-a" "$S14_LOG"; then
  pass "14. _utl_send_spool_note resolves PROJ_PATH sibling spool-send.sh and delivers note"
else
  fail "14. sibling send (rc=$rc, out=$out, log=$(cat "$S14_LOG"))"
fi

out=$(PATH="$T/empty-path:/usr/bin:/bin" SPOOL_ROOT="$T/spool14" PROJ_PATH="$T/no-such-tree" bash -c '
  source "$1"; _utl_send_spool_note "from-a" "orchestrator" "task-a" "hello-a" "" "the demo alert"' _ "$FUNC_SH" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"WARN no spool-send.sh found to send the demo alert"* ]]; then
  pass "14. _utl_send_spool_note logs missing_label and returns 1 when no sender exists"
else
  fail "14. missing sender (rc=$rc, out=$out)"
fi

out=$(SPOOL_ROOT="$T/spool14" bash -c '
  source "$1"; _utl_send_spool_note "from-a" "orchestrator" "task-a" "hello-a" "$2" "the demo alert"' _ "$FUNC_SH" "$BIN_DIR/failing-send.sh" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"WARN failed to send spool note via $BIN_DIR/failing-send.sh"* ]]; then
  pass "14. _utl_send_spool_note logs failure and returns 1 when sender fails"
else
  fail "14. failing sender (rc=$rc, out=$out)"
fi

if [[ "$(grep -c '^_utl_send_spool_note()' "$FUNC_SH")" -eq 1 ]] && grep -q '_utl_send_spool_note ' "$FUNC_SH"; then
  pass "14. one copy: reboot-required-check.func.sh hosts _utl_send_spool_note"
else
  fail "14. host check"
fi
own_c="$(grep -nE 'spool-send\.sh|failed to send spool note' "$CHS_SH" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$own_c" ]] && grep -q '_utl_send_spool_note ' "$CHS_SH"; then
  pass "14. one copy: cron-heartbeat-snitch.func.sh delegates _chs_send to _utl_send_spool_note"
else
  fail "14. chs delegate: own=[$own_c]"
fi

: > "$SEND_LOG"
out=$(SPOOL_ROOT="$T/spool14" CRON_HB_ALERT_SEND_BIN="$BIN_DIR/spool-send.sh" bash -c '
  source "$1"; _chs_send "chs@PC" "orchestrator" "cron-heartbeat-snitch" "body-14"' _ "$CHS_SH" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q -- "--from chs@PC --to orchestrator --kind note --task cron-heartbeat-snitch --body body-14" "$SEND_LOG"; then
  pass "14. standalone: cron-heartbeat-snitch.func.sh lazy-loads _utl_send_spool_note and sends"
else
  fail "14. standalone chs send (rc=$rc, out=$out, log=$(cat "$SEND_LOG"))"
fi
out=$(PATH="$T/empty-path:/usr/bin:/bin" SPOOL_ROOT="$T/spool14" PROJ_PATH="$T/no-such-tree" CRON_HB_ALERT_SEND_BIN="" bash -c '
  source "$1"; _chs_send "chs@PC" "orchestrator" "cron-heartbeat-snitch" "body-14"' _ "$CHS_SH" 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"WARN no spool-send.sh found to send the cron alert"* ]]; then
  pass "14. standalone: _chs_send keeps exact missing-sender wording for cron alert"
else
  fail "14. standalone chs missing (rc=$rc, out=$out)"
fi
```

**Behaviour:** zero behaviour change. Both `_rrc_send` and `_chs_send` keep exact sender
resolution precedence (override > `PROJ_PATH` sibling > `PATH`), exact `WARN` messages
(`"the reboot advice"` vs `"the cron alert"`, and `"WARN failed to send spool note via
$send_bin"`), exact `SPOOL_ROOT` default and `spool-send.sh` flags, and exact return
codes (both standalone `_chs_send` checks pass on unmodified `base` too).

### 1.5 Before and on the rows' heads

2026-11-27T06:23:39Z-06:31:18Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts; "-" means that row's head does not touch the suite's
tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/install-agy-cli.tst.sh` | 01 | 0 / 12 / 0 | 0 / 22 / 0 (+10 new checks) | - |
| `orc:src/bash/tests/install-mistral-vibe.tst.sh` | 01 | 0 / 26 / 0 | = | - |
| `orc:src/bash/tests/install-openai-codex.tst.sh` | 01 | 0 / 25 / 0 | = | - |
| `utl:src/bash/tests/reboot-required-check.tst.sh` | 02 | 0 / 13 / 0 | - | 0 / 20 / 0 (+7 new checks) |
| `utl:src/bash/tests/cron-heartbeat-snitch.tst.sh` | 02 | 0 / 17 / 0 | - | = |
| `utl:src/bash/tests/print-help.tst.sh` | 02 | 0 / 4 / 0 | - | = |
| `orc:src/bash/tests/reliability-checks-cron.tst.sh` | 02 | 0 / 9 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |

Note (\*): on Row 01 mutation checks `m1a`, `m1b`, and `m1c`, multi-line `$out` dumped
inside a `FAIL:` message includes raw `OK ...` log lines on their own lines, which
`grep -ciE '^ *(ok|pass)'` counts alongside real `PASS:` checks (broken down per mutation
below). `gcloud-account-pinned.tst.sh` counts are box-dependent (48 on this box; equal on
base and heads). Run `no-literal-paths.tst.sh` in a git checkout owned by the user
running git.

`shellcheck 0.10.0 -S warning -x` on all 7 edited files (head1: 4 files, head2: 3 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own scratch clone of `84f86ab8c`, reconstructed
from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `install-agy-cli.tst.sh` on base): rc 1, 14 pass
  (12 base + both standalone `mistral-vibe` and `openai-codex` checks passing on base,
  proving equivalence), 8 fail (4 `_spl_agent_cli_prep: command not found` checks, 1
  `_spl_agent_cli_exec: command not found` check, `FAIL: 9: host`,
  `FAIL: 9: install-mistral-vibe.func.sh` naming `:30`, and
  `FAIL: 9: install-openai-codex.func.sh` naming `:33`); head1: rc 0, 22 pass, 0 fail.
- Row 02 red control (`rc2`, head2's `reboot-required-check.tst.sh` on base): rc 1, 15
  pass (13 base + both standalone `_chs_send` checks passing on base, proving
  equivalence), 5 fail (3 `_utl_send_spool_note: command not found` checks,
  `FAIL: 14. host check`, and `FAIL: 14. chs delegate` naming `:205` and `:219`);
  head2: rc 0, 20 pass, 0 fail.

**Mutation checks** (n=1 each, fresh scratch clones of `84f86ab8c` with head1/head2
applied, then one defect planted; all hermetic, never touching `$HOME`):
- `m1a` (`install-mistral-vibe.func.sh` passes `def_dry=1` instead of `0` to
  `_spl_agent_cli_prep`): `install-agy-cli.tst.sh` rc 1, `22*` `ok|pass` lines (21 real
  `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 9: standalone vibe`).
- `m1b` (`install-openai-codex.func.sh` passes `SPOOL_INSTALL_CODEX_VERSION=""` instead
  of `"$pin"`): `install-agy-cli.tst.sh` rc 1, `22*` `ok|pass` lines (21 real `PASS:` + 1
  dumped `OK` line), 1 fail (`FAIL: 9: standalone codex`).
- `m1c` (`_spl_agent_cli_exec` in `install-agy-cli.func.sh` omits `"${envs[@]}"` on the
  direct-user branch while keeping `HOME="$home"`): `install-agy-cli.tst.sh` rc 1, `21*`
  `ok|pass` lines (14 real `PASS:` + 7 dumped `OK` lines), 8 fail (`FAIL: 1: dry`,
  `FAIL: 3: re-run`, `FAIL: 4: update`, `FAIL: 5: above`, `FAIL: 6: low vendor`,
  `FAIL: 9: exec`, `FAIL: 9: standalone vibe`, `FAIL: 9: standalone codex`).
- `m2a` (`_utl_send_spool_note` in `reboot-required-check.func.sh` skips the `PROJ_PATH`
  sibling check via `if false; then`): `reboot-required-check.tst.sh` rc 1, 19 pass, 1
  fail (`FAIL: 14. sibling send`).
- `m2b` (`_chs_send` in `cron-heartbeat-snitch.func.sh` passes `"the reboot advice"`
  instead of `"the cron alert"`): `reboot-required-check.tst.sh` rc 1, 19 pass, 1 fail
  (`FAIL: 14. standalone chs missing`).
- `m2c` (`_utl_send_spool_note` returns `0` instead of `1` after `WARN failed to send
  spool note via`): `reboot-required-check.tst.sh` rc 1, 18 pass, 2 fail
  (`FAIL: 11. failed send`, `FAIL: 14. failing sender`).

The tests that name the sites (R2): `git grep -nE` over `orc/src/bash/tests/*`,
`orc/src/bash/features/*/tests/*`, `iac/src/bash/tests/*`, `utl/src/bash/tests/*`, and
`csi-spl-api/*` on `84f86ab8c`:
- Row 01 (`install-agy-cli|install-mistral-vibe|install-openai-codex|do_install_agy_cli|do_install_mistral_vibe|do_install_openai_codex`) ->
  **`orc:src/bash/tests/install-agy-cli.tst.sh`** (edited),
  `orc:src/bash/tests/install-mistral-vibe.tst.sh`,
  `orc:src/bash/tests/install-openai-codex.tst.sh` (plus `set-codex-key.tst.sh` names only
  the string `no-codex-binary-run-do_install_openai_codex` from `set-codex-key.func.sh`;
  0 hits in `features/*/tests/`, `csi-spl-iac/`, or `csi-spl-api/`).
- Row 02 (`reboot-required-check|cron-heartbeat-snitch|do_os_reboot_required_check|do_cron_heartbeat_snitch|_rrc_send|_chs_send`) ->
  **`utl:src/bash/tests/reboot-required-check.tst.sh`** (edited),
  `utl:src/bash/tests/cron-heartbeat-snitch.tst.sh`,
  `utl:src/bash/tests/print-help.tst.sh`,
  `orc:src/bash/tests/reliability-checks-cron.tst.sh`, and
  `iac:src/bash/tests/bash-cleancode.tst.sh` (0 hits in `features/*/tests/` or
  `csi-spl-api/`).
- 30-char comment/string grep across all edited sites (+/- 3 lines): only generic
  `# shellcheck source=../features/` hits across unrelated tests; 0 domain comment hits.
  No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r10-01-orc-install-agent-cli-prep)` | one fact, one copy (developer guide 2.2.4) | `install-agy-cli.func.sh:23-57`, `install-mistral-vibe.func.sh:25-53`, and `install-openai-codex.func.sh:28-56` are the exact 3 wrappers over `install.sh --cli <name> --cli-only` in `orc:src/bash/run/`, duplicating the ~24-line `yq` / `org_app` / `cnf` / `X.Y.Z` pin / `DRY_RUN` / `spool-env` / agent home / `as_agent` execution preamble (1.3, r09 section 7 #1) | `orc:src/bash/run/install-agy-cli.func.sh:23-57`<br>`orc:src/bash/run/install-mistral-vibe.func.sh:25-53`<br>`orc:src/bash/run/install-openai-codex.func.sh:28-56`<br>`orc:src/bash/tests/install-agy-cli.tst.sh:17,122` | copies of the agent CLI wrapper prep and target-user exec preamble across `install-{agy-cli,mistral-vibe,openai-codex}` 3 -> 1 (hosted once as `_spl_agent_cli_prep` and `_spl_agent_cli_exec` in `install-agy-cli.func.sh`; 3/3 `install.sh --cli` wrappers consolidated) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `install-agy-cli.tst.sh` on parent FAILs 8 checks (`rc1`, rc 1, 14 pass, 8 fail: 4 `_spl_agent_cli_prep` + 1 `_spl_agent_cli_exec` + 3 one-copy checks naming `:30` and `:33`; both standalone vibe/codex checks pass on base), then GREEN (`0/22/0`, +10 new checks); hermetic mutations `m1a` (`mistral` `def_dry=1`, rc 1, 1 fail), `m1b` (`codex` empty pin env, rc 1, 1 fail), and `m1c` (`_spl_agent_cli_exec` drops `${envs[@]}`, rc 1, 8 fail) caught (1.5); outputs in the body. **Behaviour:** zero functional change (accepted deviation W3 in 1.3: `mistral-vibe` malformed cnf prints `yq` stderr once instead of twice; same rc 2 and `FATAL`); column passes on parent and head with equal counts plus 10 new checks in `install-agy-cli.tst.sh`. Tests: **`orc:.../install-agy-cli.tst.sh`**, `orc:.../install-mistral-vibe.tst.sh`, `orc:.../install-openai-codex.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r10-02-utl-spool-note-send)` | one fact, one copy (developer guide 2.2.4) | `reboot-required-check.func.sh:82-103` (`_rrc_send`) and `cron-heartbeat-snitch.func.sh:201-222` (`_chs_send`) duplicate the exact 21-line `spool-send.sh` override / `PROJ_PATH` sibling / `PATH` resolution, missing-sender `WARN`, `SPOOL_ROOT` note send, and failure `WARN` (1.4) | `utl:src/bash/run/reboot-required-check.func.sh:82-103`<br>`utl:src/bash/run/cron-heartbeat-snitch.func.sh:201-222`<br>`utl:src/bash/tests/reboot-required-check.tst.sh:18,205` | copies of the 21-line `spool-send.sh` note sender across `reboot-required-check` and `cron-heartbeat-snitch` 2 -> 1 (hosted once as `_utl_send_spool_note` in `reboot-required-check.func.sh`, lazy-loaded inside `_chs_send`) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `reboot-required-check.tst.sh` on parent FAILs 5 checks (`rc2`, rc 1, 15 pass, 5 fail: 3 `_utl_send_spool_note` + 2 one-copy checks naming `:205` and `:219`; both standalone `_chs_send` checks pass on base), then GREEN (`0/20/0`, +7 new checks); mutations `m2a` (skip `PROJ_PATH` sibling, rc 1, 1 fail), `m2b` (`_chs_send` wrong missing label, rc 1, 1 fail), and `m2c` (return 0 on failed send, rc 1, 2 fail) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change (CI cost W2 accepted: `csi-spl-utl/` runs `parts=all` once at night, 1.4); column passes on parent and head with equal counts plus 7 new checks in `reboot-required-check.tst.sh`. Tests: **`utl:.../reboot-required-check.tst.sh`**, `utl:.../cron-heartbeat-snitch.tst.sh`, `utl:.../print-help.tst.sh`, `orc:.../reliability-checks-cron.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`, `utl:` = `csi-spl-utl/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r10-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r10-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows consolidate internal shell helper copies with zero change to any
output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper consolidation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  across two sub-projects (row 01: `orc:src/bash/run/install-agy-cli.func.sh`,
  `install-mistral-vibe.func.sh`, `install-openai-codex.func.sh`,
  `orc:src/bash/tests/install-agy-cli.tst.sh`; row 02:
  `utl:src/bash/run/reboot-required-check.func.sh`, `cron-heartbeat-snitch.func.sh`,
  `utl:src/bash/tests/reboot-required-check.tst.sh`).
- Neither row edits `orc:src/bash/features/spool-install/install.sh`,
  `orc:src/bash/tests/install-mistral-vibe.tst.sh`,
  `orc:src/bash/tests/install-openai-codex.tst.sh`,
  `utl:src/bash/tests/cron-heartbeat-snitch.tst.sh`,
  `utl:src/bash/run/systemd-unit-health.func.sh`,
  `utl:src/bash/run/cloud-sql-backup-verify.func.sh`,
  `orc:src/bash/run/spl-spawn-place.func.sh`, `orc:src/bash/run/spl-review-go.func.sh`,
  `orc:src/bash/run/spl-dispatch-rotate.func.sh`,
  `orc:src/bash/features/spawn-agents/scripts/spawn-remote.sh`,
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (7 edited + 3 sibling regression-run files = 10 checked via `lane-map.sh --check`
at 2026-11-27T06:30:04Z):
`orc:src/bash/run/install-agy-cli.func.sh`,
`orc:src/bash/run/install-mistral-vibe.func.sh`,
`orc:src/bash/run/install-openai-codex.func.sh`,
`orc:src/bash/tests/install-agy-cli.tst.sh`,
`orc:src/bash/tests/install-mistral-vibe.tst.sh`,
`orc:src/bash/tests/install-openai-codex.tst.sh`,
`utl:src/bash/run/reboot-required-check.func.sh`,
`utl:src/bash/run/cron-heartbeat-snitch.func.sh`,
`utl:src/bash/tests/reboot-required-check.tst.sh`,
`utl:src/bash/tests/cron-heartbeat-snitch.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <paths> --agent a-546`, n=1, at
  2026-11-27T06:30:04Z: **exit 4** ("no live lane lists `<paths>`, but 24 live lane(s)
  record no files", 0 owned). All 24 `unknown:` live lanes are on the other box (14
  channel/workspace/other-repo seats `c-029`, `c-041`, `c-079`, `c-086`, `c-146`, `c-187`,
  `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-936`, `c-971`, plus `c-068` WUI
  loops dialog, `c-211` SPL-4632 GCP page, `c-264` s158 P2 pin sweep, `c-391` b52-02
  `spl-review-go.func.sh`, `c-420` this round's claude panel seat, `c-422` rotated lane,
  `c-707` p19-02 WUI composer wrap, `c-904` s187 S1 rdb+store, `c-935` rotated lane, and
  `c-957` netvisor spec). Verified via `do_spl_lane_map` at 06:11:14Z — live lanes on this
  box (`a-546`, `a-544` b52-03 `spawn-remote.sh`, `a-542` SPL-6588 WUI loops R7, `a-264`
  b52 planner, `a-537` b52-02 R7, `a-934` s182 planner, `a-292` SPL-6636/6617 reviewer,
  `a-445` b52-01 R7) touch none of our 10 paths. No live lane owns any of the 10 paths (also re-checked by panel `c-420` at 06:55Z on
  the 7 row paths: exit 4, 8 `unknown:` on the planner box, 0 owned; N3); the holder
  re-reads at placement per R3.
- **Bug round 52 beside us:** `b52-01` (SPL-5254 WUI popstate, landed `84f86ab8c`),
  `b52-02` (`spl-review-go.func.sh`, `c-391` / `a-537`), `b52-03` (`spawn-remote.sh`,
  `a-544`) have **0 overlap** with our 10 paths.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-27T06:11:18Z):
  65 queued, 0 placing (including CI A1b/A2/A3 refactor rows, s185/s173/s195/s112
  planners, s192/s150/s169/s107/s196/s162/s039/s177/s190/SPL-6318/SPL-5020 feature rows).
  None touches any of our 10 paths.
- **Unlanded rows from r09:** **0** (`r09-01` landed `2305d56ec`, `r09-02` landed
  `a1db1addf`, close record `e91066a01`).
- **Briefs on this box** modified in the last 48 h matching any of our 10 paths (at
  06:15:44Z): **0 live overlapping briefs**.
- **Remote branches committed in the last 48 h** (`git for-each-ref`, at 06:16:27Z):
  178 branches checked with `git diff --name-only $(git merge-base 84f86ab8c <b>) <b> -- <10 paths>` ->
  **0 hits**.
- **Commits in the last 48 h** on the 10 checked paths (`git log 84f86ab8c --since='48 hours ago'`,
  at 06:15:44Z) -> **0**.

## 3. Per row: what the lane does

- **r10-01:** `orc:src/bash/run/install-agy-cli.func.sh` extracts `_spl_agent_cli_prep`
  and `_spl_agent_cli_exec` and delegates `do_install_agy_cli` to them.
  `orc:src/bash/run/install-mistral-vibe.func.sh` and
  `orc:src/bash/run/install-openai-codex.func.sh` drop their duplicated prep and
  `sudo -n -u` blocks, lazy-load `install-agy-cli.func.sh`, and delegate to
  `_spl_agent_cli_prep` and `_spl_agent_cli_exec`.
  `orc:src/bash/tests/install-agy-cli.tst.sh` adds section `9` to the header (`:17`) and
  inserts section `9` before `:122` (4 `_spl_agent_cli_prep` checks, 1 `_spl_agent_cli_exec`
  check, 3 one-copy checks across all 3 wrappers, and 2 standalone lazy-load checks for
  `install-mistral-vibe` and `install-openai-codex`).
- **r10-02:** `utl:src/bash/run/reboot-required-check.func.sh` extracts
  `_utl_send_spool_note` and delegates `_rrc_send` to it.
  `utl:src/bash/run/cron-heartbeat-snitch.func.sh` replaces `_chs_send`'s 21-line body with
  lazy-load of `reboot-required-check.func.sh` and a call to `_utl_send_spool_note`.
  `utl:src/bash/tests/reboot-required-check.tst.sh` adds section `14` to the header (`:18`)
  and inserts section `14` before `:205` (3 `_utl_send_spool_note` checks, 2 one-copy
  checks, and 2 standalone `_chs_send` lazy-load checks).

## 4. Panel and reviewers (R7)

- Editor: **a-546** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat **c-420**
  (`c003-refactor-round-10-claude-panel-seat`, live per `do_spl_lane_map` at 06:11:14Z).
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-27T06:12:54Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`), `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 06:12:30Z reported `main=agy`, `backup=claude` (at that minute `agy` was paused
    until 08:05:25Z, so `pick=claude`; mistral sits on no review). Because rows run by
    night (after the pause lifts), R7 review of a claude coding row goes to an **agy
    seat** per row (claude waiver backup only while agy is out of quota or paused, citing
    ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 06:12:36Z picked the other box (91% vs
    144% on this box, `agy weekly unknown`, placed anyway); `BOX_PICK_KIND=claude` at
    06:12:47Z picked the other box (`claude weekly 3%`, this box `unknown`). The holder
    re-checks capacity at row placement.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

### 4.1 Consensus table (rulebook 3.1 / 3.2)

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `a-546` | agy | editor | `25212ee7f` (v0.1) -> v1.0 | v1.0 | W1-W3 and N1-N4 folded; all 9 fenced `bash` blocks byte-identical to v0.1 `25212ee7f` |
| `c-420` | claude | panel | `25212ee7f` (v0.1) -> v1.0 pending | FAIL (v0.1) / pending (v1.0) | v0.1 FAIL `33502ecbc` (msg `e8c2c01e` / holder `35462d95`, W1-W3 + N1-N4); re-review of v1.0 requested |

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r10-01 | `c002-r10-01-orc-install-agent-cli-prep` | `refactor(r10-01-orc-install-agent-cli-prep, SPL-<row issue>): ...` | `review/r10-01` | 1 |
| r10-02 | `c002-r10-02-utl-spool-note-send` | `refactor(r10-02-utl-spool-note-send, SPL-<row issue>): ...` | `review/r10-02` | 1 |

**r10-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/install-agy-cli.func.sh` (replace `:23-57` with thin
`do_install_agy_cli` + `_spl_agent_cli_prep` + `_spl_agent_cli_exec`),
`csi-spl-orc/src/bash/run/install-mistral-vibe.func.sh` (replace `:25-53` with lazy-load
+ `_spl_agent_cli_prep` + `_spl_agent_cli_exec`),
`csi-spl-orc/src/bash/run/install-openai-codex.func.sh` (replace `:28-56` with lazy-load
+ `_spl_agent_cli_prep` + `_spl_agent_cli_exec`), and
`csi-spl-orc/src/bash/tests/install-agy-cli.tst.sh` (header `:17`, insert section `9`
before `:122`). NOT `install.sh`, NOT `install-mistral-vibe.tst.sh`, NOT
`install-openai-codex.tst.sh`, NOT `csi-spl-utl/`, NOT `.shellcheck-warning-baseline.txt`,
or any other file. Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in
1.3); red control (`rc1`, head1's `install-agy-cli.tst.sh` on parent: rc 1, 14 pass, 8
fail) RED then GREEN (`0/22/0`) in the body; hermetic mutations `m1a` (rc 1, 1 fail),
`m1b` (rc 1, 1 fail), and `m1c` (rc 1, 8 fail, keeping `HOME="$home"`) caught. Gates: the
row's tests (section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on
the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota or
paused, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if
the claude backup is used; never mistral; re-checked at placement).

**r10-02 brief, Files: ONLY**
`csi-spl-utl/src/bash/run/reboot-required-check.func.sh` (replace `:82-103` with
`_utl_send_spool_note` + thin `_rrc_send`),
`csi-spl-utl/src/bash/run/cron-heartbeat-snitch.func.sh` (replace `:201-222` with
lazy-load + `_utl_send_spool_note`), and
`csi-spl-utl/src/bash/tests/reboot-required-check.tst.sh` (header `:18`, insert section
`14` before `:205`). NOT `cron-heartbeat-snitch.tst.sh`, NOT `systemd-unit-health.func.sh`,
NOT `cloud-sql-backup-verify.func.sh`, NOT `csi-spl-orc/`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02 verbatim,
1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head2's
`reboot-required-check.tst.sh` on parent: rc 1, 15 pass, 5 fail) RED then GREEN (`0/20/0`)
in the body; mutations `m2a` (rc 1, 1 fail), `m2b` (rc 1, 1 fail), and `m2c` (rc 1, 2
fail) caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
Note (W2, accepted): touching `csi-spl-utl/` runs `parts=all` in CI once (`ci-doc-only.sh:124`).
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
| copies of the agent CLI wrapper prep and target-user exec preamble across row 01's 3 actions (1.3) | 3 on `84f86ab8c` (`install-agy-cli`, `install-mistral-vibe`, `install-openai-codex`) -> 1 (hosted once as `_spl_agent_cli_prep` + `_spl_agent_cli_exec` in `install-agy-cli.func.sh`; **3/3** `install.sh --cli` wrappers consolidated) |
| copies of the 21-line `spool-send.sh` note sender across row 02's 2 actions (1.4) | 2 on `84f86ab8c` (`reboot-required-check`, `cron-heartbeat-snitch`) -> 1 (hosted once as `_utl_send_spool_note` in `reboot-required-check.func.sh`) |
| lines (`git diff --numstat` of each head) | row 01: `install-agy-cli.func.sh` +38 -22, `install-mistral-vibe.func.sh` +7 -22, `install-openai-codex.func.sh` +6 -22, `install-agy-cli.tst.sh` +66 -0; row 02: `reboot-required-check.func.sh` +11 -5, `cron-heartbeat-snitch.func.sh` +3 -19, `reboot-required-check.tst.sh` +65 -0 |
| measured on | `84f86ab8c`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `utl:src/bash/run/` `*_SEND_CMD` spool note senders (first candidate for `r11`, 6 non-secret actions in 2 batches of <= 4 files + test): `clock-sync-check.func.sh:205`, `docker-test-container-prune.func.sh:148`, `gh-runner-health.func.sh:295`, `net-cert-expiry-check.func.sh:186`, `orphan-process-reap.func.sh:143`, `tmux-health-guard.func.sh:154` duplicate the `send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/.../spool-send.sh")` + `[[ -f "${send[1]}" ]]` pattern | left for `r11` (rulebook 5.1 aims at 2 rows; r10 already has 2 disjoint Batch 1 rows; note W2: `csi-spl-utl/` runs `parts=all` in CI until `ci-doc-only.sh:124` gains a `utl` case) | `git grep -n 'spool-send.sh' 84f86ab8c -- csi-spl-utl/src/bash/run/` (n=1) |
| `utl:src/bash/run/systemd-unit-health.func.sh:148-181` (`_unit_health_send`) and `cloud-sql-backup-verify.func.sh:226-245` (`_csq_send_spool`) | distinct semantics from row 02: both require `-x "$send_bin"` (not `-f`) and fall back to `command -v spool` (`spool send`); `systemd-unit-health` also writes its stamp file inside `_unit_health_send`; candidate for `r11` | `git show 84f86ab8c:csi-spl-utl/src/bash/run/{systemd-unit-health,cloud-sql-backup-verify}.func.sh` (n=1) |
| `orc:src/bash/run/install-force-push-guard.func.sh:29-42` and `spl-cmd-guard-mode.func.sh:50-64` (`_scg_homes`) user/home resolution | left for `r11`; note subtle difference (`FAIL; rc=1; continue` vs `FATAL; return 1` on missing home) that an `r11` helper must preserve | `git show 84f86ab8c:csi-spl-orc/src/bash/run/{install-force-push-guard,spl-cmd-guard-mode}.func.sh` (n=1) |
| `orc:src/bash/run/net-usb-tether-profiles.func.sh` and `net-wired-priority.func.sh` NM keyfile writer | both test suites (`net-usb-tether-profiles.tst.sh:201`, `net-wired-priority.tst.sh:172`) mutate `install -D -m 0600` in copied `$T/red2.func.sh` files; moving the writer out of one file requires re-designing its existing red control | `git show 84f86ab8c:csi-spl-orc/src/bash/tests/net-{usb-tether-profiles,wired-priority}.tst.sh` (n=1) |
| Remaining 3 `is a linked worktree:` sites in `orc:src/bash/run/`: `spl-private-overlay-install-cron.func.sh:70-71` (secret-class), `box-peer-ssh-grant.func.sh:53`, and `spl-box-deploy.func.sh:151` | secret-class exclusion or distinct control flow and wording | r09 section 7 (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` / `*_apply`, non-matching cron installers, secret-class probe / `gcp-*` / `build-push-*` / `spl-search-*-probe` actions, PG-heavy actions, and earlier unserved r07-r09 section 7 items | secret-class, pulls PostgreSQL into R2, or distinct semantics | r09 section 7; `git show` on `84f86ab8c` (n=1) |
| Candidates-file open items: `_ppe_keys` (`check-pre-push-e2e.func.sh:121`, line 113), `i18n-lang-review-exempt.json:2` `_doc` (line 115), WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125), process churn (lines 147-148), and `b52`/`b53` bug inputs (lines 153-173) | gate-design, 1-line JSON comment, perf-shaped, or bug-shaped | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (1.2 (c), n=1) |
| Spec 011 deferred/owner-decision tasks (`T001`-`T008`, `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) | each is wider than one row or awaits an owner decision | `git log e91066a01..84f86ab8c --oneline -- csi-spl-doc/specs/011-spool-project-refactor` (0 commits; 1.2 (d), n=1) |

## 8. Changes

- v0.1 (a-546): the rows and every read on `84f86ab8c`; both heads built in scratch
  clones; the 16-suite column of 1.5 run on base and each row's head (all 16 base, 12
  head1, and 13 head2 suites green); `shellcheck 0.10.0 -S warning -x` and
  `do_sec_shellcheck` rc 0; both red controls (`rc1`, `rc2`) and all 6 hermetic mutation
  checks (`m1a`, `m1b`, `m1c`, `m2a`, `m2b`, `m2c`) run in fresh scratch clones and
  verified RED; all helper, caller, and test hunks included verbatim in 1.3 and 1.4.
  Pushed to `review/c003-refactor-round-10-planner` (`25212ee7f`).
- v1.0 (a-546): folded cross-vendor claude panel (`c-420`, v0.1 FAIL on `25212ee7f`, seat
  commit `33502ecbc311398b8bf60d1d1912f4328bba0fdf`, msg `e8c2c01e` / holder `35462d95`)
  W1-W3 and N1-N4 (zero row change; all 9 fenced `bash` blocks byte-identical to v0.1
  `25212ee7f`; zero drift across all 10 checked paths from `84f86ab8c` to
  `origin/master`):
  - **W1 (1.4, section 6):** fixed `reboot-required-check.tst.sh` line count and sha256
    to match verbatim-block reconstruction with one trailing blank line (`208 -> 273`,
    `+65 -0`, sha256 `42c0579ceea6`; our scratch generator had inserted a second blank
    line giving 274 / `280ed77bd391`).
  - **W2 (1.2 (a), 1.4, section 2, section 5, section 7):** explicitly named that
    touching `csi-spl-utl/` triggers `parts=all` in CI (`ci-doc-only.sh:124`, `28ed98f7a`,
    the reason r98 `:756` and r99 `:838` left this pair out) and explicitly accepted this
    one-time night-phase CI cost to keep row 02.
  - **W3 (1.3, section 2):** stated the accepted `install-mistral-vibe` malformed-cnf
    deviation (1 `yq` stderr line on `head1` instead of 2 on `base`, same rc 2 and
    `FATAL`; 16/240 panel sweep cases, other 224/240 identical).
  - **N1 (1.2 (a)):** unified line citations to `:82-103` and `:201-222`.
  - **N2 / N4 (1.3):** noted stopping the global `as_agent` leak (no caller relies on it)
    and that the `sudo -n -u` branch stays untested hermetically as on base.
  - **N3 (2.2):** recorded panel's 06:55Z lane-map check (exit 4, 8 `unknown:` on planner
    box, 0 owned).
  Pushed fast-forward to `review/c003-refactor-round-10-planner` for panel sign-off.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-546 (agy): v0.1 (`25212ee7f`), v1.0.
- Panel reviewer seat: c-420 (claude, `c003-refactor-round-10-claude-panel-seat`, seat
  branch `review/c003-refactor-round-10-claude-seat`):
  - v0.1 `25212ee7fcdfd8749290f1479bbefb232de8af48`: FAIL with W1-W3 + N1-N4 (seat commit
    `33502ecbc311398b8bf60d1d1912f4328bba0fdf`, msg `e8c2c01e` / holder `35462d95`; all
    folded in v1.0).
  - v1.0: pending sign-off.
- Row R7 seats: section 4; agy per row (claude waiver backup only under ruling `dc84300a`;
  never mistral).
