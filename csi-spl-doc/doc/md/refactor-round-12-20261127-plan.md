# Refactoring round 12 (2026-11-27) - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6696  
Topic: c369e8ca-c04d-4ecb-812e-0d01d1915fe9  
Discussion: c369e8ca-c04d-4ecb-812e-0d01d1915fe9 (t1 #refactoring, "Refactor round 12", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3). Because the older
  cycle already created `refactor-round-12-plan.md`, `refactor-round-12-retro.md`, and
  `refactor-round-12/` on `origin/master`, this round carries its open date per rulebook
  5.3: plan `refactor-round-12-20261127-plan.md`, retro
  `refactor-round-12-20261127-retro.md`, seat dir `refactor-round-12-20261127/`, Qto doc
  title the same, rows `r12-<NN>`, commit scope `docs(r12-plan, SPL-6696)`. Unlike r11,
  zero old-cycle `r12` remote heads exist on `origin`, so no `e79facef`-style branch
  carve-out is needed.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574).
  `LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 17:06:20Z reported
  `main=claude`, `backup=agy`, `pick=claude` (`claude` 2/11 = 18% vs 44% effective
  weight; `agy` 7/11 = 64% vs 56% effective weight; `grok` and `qwen` off in instance
  settings, `paused none`, `codex` not signed in). Per R14 and the brief (cross-vendor
  `agy` R7 for `claude` code rows), both rows are assigned **vendor claude** with
  **agy R7** (claude waiver backup only while agy is out of quota or paused, under ruling
  `dc84300a`; never mistral; re-checked at placement).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 11 ([refactor-round-11-20261127-plan.md](refactor-round-11-20261127-plan.md),
editor `a-629`, SPL-6676) has served both rows on `origin/master` with cross-vendor agy
R7 PASS (`r11-01` `fa3981e0a`, SPL-6687, agy R7 `a-715` PASS; `r11-02` `5db7cef92`,
SPL-6689, agy R7 `a-716` PASS; both Bash-only, live on dev and prd per brief; its close
record `Closes: SPL-6676` has not landed yet). The rulebook 5.2 serve gate is met, so r11
does not hold r12 rows once this plan is signed and landed. The perf floor (rulebook 4.4),
re-measured on `3308d118f` at 2026-11-27T17:06:00Z (14 days):
`perf 37 refactor 115 perf-share 24.3% floor-met` (5 x 37 = 185 >= 152), so this is a
refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), pure `csi-spl-orc/` (narrow
CI `orc iac cnf hub` — zero `parts=all` CI penalty), non-secret, zero-PG, with zero
functional behaviour change:
- **Row 01 (`_spl_hub_run_describe` Cloud Run service describe preamble — 3 files):**
  `orc:src/bash/run/check-hub-deploy.func.sh:41-58` extracts `_spl_hub_run_describe`
  (shared `do_require_bin yq`, `do_spl_cloud_cnf`, `do_gcp_pin_account "$SPL_CNF"`,
  `gcloud` check, `do_gcp_require_live_account`, `env.hub.service_name` read + empty
  `FATAL`, and read-only `gcloud run services describe --format=json` + failure `FATAL`,
  setting caller-scoped `svc` and `json`) and delegates `do_hub_deploy_verify_gcp` to it;
  `orc:src/bash/run/check-hub-image-regress.func.sh:39-55` lazy-loads
  `check-hub-deploy.func.sh` and delegates its identical 16-line describe preamble to
  `_spl_hub_run_describe`, guarded by section `8` in
  `orc:src/bash/tests/check-hub-deploy.tst.sh`.
- **Row 02 (`_spl_desk_args_split` and `_spl_desk_in_file` desk doc input helpers — 3 files):**
  `orc:src/bash/run/spl-desk-doctree.func.sh:137-173` extracts `_spl_desk_args_split`
  (shared `python3` `shlex.split` -> `mapfile -d '' -t` + blank/unbalanced/empty `FATAL`)
  and `_spl_desk_in_file` (shared `realpath -e`, `-f && -r`, desk-state `SPL_STATE_DIR`
  guard, allowed-roots loop over `APP_PATH`, `/tmp`, `/var/spool-hub/dispatch`, and
  optional vs required empty handling) and delegates `_spl_desk_doctree_split` and
  `_spl_desk_doctree_in` to them; `orc:src/bash/run/spl-desk-wsdoc.func.sh:102-113,143-166`
  (which already lazy-sources `spl-desk-doctree.func.sh` for seated/caller checks)
  lazy-loads `spl-desk-doctree.func.sh` inside `_spl_desk_wsdoc_split` and
  `_spl_desk_wsdoc_in` and delegates both 9-line and 20-line duplicates to
  `_spl_desk_args_split` and `_spl_desk_in_file`, guarded by section `11` in
  `orc:src/bash/tests/desk-doctree.tst.sh`.

The two rows touch completely disjoint file sets inside `csi-spl-orc/` and share no file:
both are **Batch 1**.

**Status: v0.1 draft for cross-vendor panel review.** Editor: **a-731** (agy). Cross-vendor
claude panel seat **c-999** (`c002-refactor-round-12-claude-panel-seat`, placed per holder
msg `f06f190d`) will review this plan sha on `review/c002-refactor-round-12-planner`.

**One sha:** every count is measured on **`3308d118f`**
(`3308d118f5516427b8c1b29b91e61e43899d0f8f`, `origin/master` at 2026-11-27T17:06:00Z;
zero drift on all 10 checked paths up to `origin/master` `6d3b1bf86` at 17:34:21Z), n=1
per command unless stated. Reads are on `3308d118f` with `git show` / `git grep`. The
tests of 1.5 ran in scratch clones checked out at `3308d118f` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a fresh scratch clone of its own. All helper, caller, and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 6 mutation checks byte-for-byte on `3308d118f` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window, slug proof, and existing old-cycle leftovers (rulebook 5.3)

2026-11-27T17:06:00Z-17:06:25Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-27T14:35:12+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r11-(plan|close)'`:
  `09907e7860ce8fcec5effc92e636ff53c599d587`
  (`docs(r11-plan, SPL-6676): refactor round 11 plan v1.0 (fold panel W1 and N1-N7; signed by c-862 PASS on f2b9c27ef)`),
  read once at the start as 5.3 says (re-checked at 17:34:21Z: r11's close record has not
  landed yet, so `09907e786` remains W). All later R4, R6, 2.7.5, and `PRUNE_SINCE` reads
  for r12 use `W=2026-11-27T14:35:12+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk '/^p/{p++} /^r/{r++} END{t=p+r; printf "perf %d refactor %d perf-share %s %s\n", p, r, (t ? sprintf("%.1f%%", 100*p/t) : "n/a"), (t == 0 ? "no-rows" : (5*p >= t ? "floor-met" : "under-20"))}'` ->
  `perf 37 refactor 115 perf-share 24.3% floor-met` (5 x 37 = 185 >= 152).
- **Slug proof since `W`:**
  `git log origin/master --since="2026-11-27T14:35:12+02:00" --oneline -E --grep='\(r12-' | wc -l` -> **0**.
- **Remote branches on `origin`:**
  `git ls-remote origin 'refs/heads/review/r12-*' 'refs/heads/wip/*r12*' 'refs/heads/*-r12-*' 'refs/heads/*refactor-round-12*'`
  -> **0 lines** (before this plan's review branch push).
- **Pre-prune DRY check:**
  `cd csi-spl-orc && ROUND=12 PRUNE_SINCE="2026-11-27T14:35:12+02:00" DRY_RUN=1 ./run -a do_git_prune_round_branches`
  (run at 17:06:25Z, n=1) printed:
  `OK round r12: no review/r12-*, wip/*r12* or [review/]<id>-r12-* branch on origin`.
- **Existing old-cycle `refactor-round-12` files:**
  `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep refactor-round-12`
  returns **3** old-cycle entries: `refactor-round-12-plan.md`,
  `refactor-round-12-retro.md`, and `refactor-round-12/`. Therefore this round uses the
  dated paths `refactor-round-12-20261127-plan.md`, `refactor-round-12-20261127-retro.md`,
  and `refactor-round-12-20261127/` (0 existing hits on `origin/master`).
- **Briefs on the planner/holder box:**
  `ls /var/spool-hub/dispatch/briefs | grep -E 'r12-[0-9]{2}|r12-retro|r12-seat|r11-retro-r12|refactor-round-12'`
  (local to the planner/holder box only, run at 17:34:22Z) shows, beyond this planner's
  brief and the panel seat's brief (`c002-refactor-round-12-claude-panel-seat.md`),
  exactly **16** known before-window old-cycle leftovers (all dated 2026-11-18, before `W`):
  - `c002-r12-01-review-line-check-agy-support.md` through
    `c002-r12-10-no-box-path-source-expand-dirs.md` (10 row briefs),
  - 1 handoff copy of old-cycle `c002-r12-05-wui-small-create-spool-client.md`,
  - `c002-r12-seat-agy-reviewer.md`, `c002-r12-seat-claude.md`,
    `c002-r12-seat-mistral.md` (3 old seat briefs),
  - `c002-r11-retro-r12-plan.md` and `c002-r12-retro-r13-plan.md` (2 old retro/plan briefs).
  Zero other `r12` heads, files, or briefs exist for this cycle.

### 1.2 The brief's inputs, re-measured

- **(a) r11 section 7 (`refactor-round-11-20261127-plan.md`):** re-read on `3308d118f`:
  - Two `csi-spl-utl` sender families (`_utl_send_spool_note` Family A vs
    `_utl_send_throttled_alert` Family B): intentionally distinct contracts (W1 of r11),
    kept separate.
  - Remaining 4 `utl:src/bash/run/` `*_SEND_CMD` actions re-measured with
    `shellcheck -S warning -x` on `3308d118f`:
    - `orphan-process-reap.func.sh:208` still carries `SC2071 (error): > is for string comparisons. Use -gt instead` (cannot touch without mixing in a separate lint fix);
    - `gh-runner-health.func.sh` remains secret-class (`gh-box-token.func.sh`);
    - `net-cert-expiry-check.func.sh:184-196` (no `timeout -k 2`, no `--no-poke`) and
      `box-beat-telemetry.func.sh:217-229` (`rm -f "$pending"`) keep distinct delivery
      semantics.
  - `systemd-unit-health.func.sh:148-181` + `cloud-sql-backup-verify.func.sh:226-245`:
    re-checked with `shellcheck -S warning -x` on `3308d118f`;
    `cloud-sql-backup-verify.func.sh:125` still carries `SC2155 (warning)` (`export CLOUDSDK_CONFIG="$(...)"`).
  - NM keyfile writers (`net-usb-tether-profiles.func.sh`, `net-wired-priority.func.sh`),
    remaining 3 `is a linked worktree:` sites, `spl-issue-*`, and secret-class / PG-heavy
    actions remain accounted for in section 7.
  - Broad duplicate-block scan across `orc:src/bash/run/*.func.sh`,
    `iac:src/bash/run/*.func.sh`, and `utl:src/bash/run/*.func.sh` on `3308d118f`
    surfaced two clean, shellcheck-clean, non-secret, zero-PG, narrow-CI (`csi-spl-orc/`
    only) one-fact-one-copy pairs:
    1. `orc:src/bash/run/check-hub-deploy.func.sh:43-58` and
       `check-hub-image-regress.func.sh:40-55`: 16-line byte-for-byte identical Cloud Run
       service describe preamble (`do_require_bin yq`, `do_spl_cloud_cnf`,
       `do_gcp_pin_account`, `gcloud` check, `do_gcp_require_live_account`,
       `env.hub.service_name` read, and read-only `gcloud run services describe --format=json`)
       -> **row 01** (1.3).
    2. `orc:src/bash/run/spl-desk-doctree.func.sh:140-173` and
       `spl-desk-wsdoc.func.sh:105-113,147-166`: two verbatim duplicated helpers
       (`*_split` `python3 shlex.split` 9 lines + `*_in` `realpath` + desk-state +
       allowed-roots 20 lines) across files where `spl-desk-wsdoc.func.sh` already
       lazy-sources `spl-desk-doctree.func.sh` for seated/caller checks -> **row 02** (1.4).
    The scan also surfaced two measured `r13` candidates recorded in section 7:
    `spl-uplink-probe.func.sh:184-194` + `external-api-health.func.sh:142-152`
    (byte-identical 11-line TSV trim + 1-line ms clock; touches `csi-spl-utl/`, triggering
    `parts=all`) and `spl-peer-restart.func.sh:102-120` + `spl-rotate-lib.func.sh:832-850`
    (`spl_peer_pids` / `spl_rotate_pids`, deferred because queued ask `aa377e76`
    `c001-s179-b5-paused-seats-free` names `spl-rotate-lib`).
- **(b) R7 notes of r11-01 (`a-715` PASS `63ff4846`), r11-02 (`a-716` PASS `d185b420`), and r11 panel (`c-862`):**
  Read from the landed commit bodies (`fa3981e0a` and `5db7cef92`) and r11 plan v1.0
  (`09907e786`):
  - `r11-01` (`fa3981e0a`, SPL-6687, R7 `a-715` PASS on `8e405994e`): commit body carries
    zero refactor follow-up notes.
  - `r11-02` (`5db7cef92`, SPL-6689, R7 `a-716` PASS on `499d93a5e`): commit body carries
    zero refactor follow-up notes.
  - r11 panel (`c-862`) W1 and N1-N7 were all folded into r11 v1.0 (`09907e786`); W1's
    distinction between Family A (`_utl_send_spool_note`) and Family B
    (`_utl_send_throttled_alert`) is carried forward in 1.2 (a) and section 7.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to the planner/holder
  box only; 173 lines, unchanged since r11): re-measured every refactor-labelled item on
  `3308d118f`:
  - **Already served on `3308d118f` (6 items):**
    - line 25 `reverse-tunnel-cron.sh`: line 27 already uses `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`;
    - line 48 `agent-boot-restore` dir: both `spl-agent-boot-restore-install-cron.func.sh:60` and `spl-watchdog.func.sh:541` already use `spl_var_app_subdir ... agent-boot-restore`;
    - line 76 `spl-desk-reply.sh:9,19`: usage text already lists all 12 kinds (`note|result|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs`);
    - line 104 `spl-lane-mix.func.sh`: `git grep -nE 'needs_agy_review|agy has the final|waits for an agy'` -> **0** hits;
    - line 115 `i18n-lang-review-exempt.json`: `git grep -n 'Lang-review a-NNN'` -> **0** hits;
    - line 133 `spl-unanswered-sweep.func.sh`: `git grep -n 'send_to_peers_on'` -> **0** hits.
  - **Out of scope for a refactor round (accounted for in section 7):** line 113 `_ppe_keys`
    (gate-design input), line 125 WUI entry-chunk `ci_initial_gzip_kb` headroom (perf-shaped),
    and all bug-shaped / test-shaped / perf-shaped entries (lines 1-23, 28-46, 50-75,
    78-102, 105-111, 114, 117-123, 127-130, 135-173).
- **(d) spec 011 tasks:**
  `git log 992866d69..3308d118f --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r11; remaining open/partial tasks (`T001`-`T008` owner-deferred,
  `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) are each wider than one row or
  await an owner decision.

### 1.3 Row 01's site: `_spl_hub_run_describe` Cloud Run service describe preamble (`check-hub-deploy`, `check-hub-image-regress`)

`orc:` = `csi-spl-orc/`. On `3308d118f`:

- Two read-only Cloud Run hub verification actions in `orc:src/bash/run/` duplicate the
  exact same 16-line preamble (`do_require_bin yq`, `do_spl_cloud_cnf`,
  `do_gcp_pin_account "$SPL_CNF"`, `command -v gcloud`, `do_gcp_require_live_account`,
  `yq` read of `.env.hub.service_name` with empty `FATAL`, and read-only
  `gcloud run services describe "$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" --format=json`
  with failure `FATAL`):
  1. `orc:src/bash/run/check-hub-deploy.func.sh:41-58` (`do_hub_deploy_verify_gcp`,
     177 lines total; lines `:43-58` are the 16-line preamble).
  2. `orc:src/bash/run/check-hub-image-regress.func.sh:39-55` (`do_check_hub_image_regress`,
     92 lines total; lines `:40-55` are byte-for-byte identical to `:43-58` above).
- Why only these 2 of the 9 `gcloud run services describe` files on `3308d118f`:
  - `canary-hub-deploy.func.sh:96` uses pre-resolved `$CHD_SVC` and a different `FATAL` wording;
  - `deploy-hub.func.sh:115`, `heal-hub-deploy.func.sh:42`, and `hub-rollback.func.sh:57,141`
    use `--format='value(...)'` (not `--format=json`) with distinct preambles;
  - `iac:src/bash/run/{gcp-hub-restart,spl-secret-rotate,spl-secret-version-disable-old}.func.sh`
    are in `csi-spl-iac/` and secret-class or use distinct flags/variables.
- Hosting `_spl_hub_run_describe` in `check-hub-deploy.func.sh` adds zero new files and
  zero eager loads. `check-hub-image-regress.func.sh` lazy-sources
  `check-hub-deploy.func.sh` inside `do_check_hub_image_regress` only when
  `_spl_hub_run_describe` is not yet defined. `_spl_hub_run_describe` sets caller-scoped
  `svc` and `json` and returns `1` on any missing prerequisite or describe failure.
- Neither file reads or writes any secret, key, or credential (both call `do_gcp_pin_account`
  for read-only `gcloud run services describe` only; all tests are 100% hermetic with a
  stub `gcloud` and `HOME="$T/nosa_home"`; non-secret; `check-hub-deploy.func.sh` was
  similarly edited by non-secret refactor row `r81-02`).
- **Narrow CI:** all 3 edited files live under `csi-spl-orc/src/bash/`, so
  `ci-doc-only.sh:122` selects narrow CI (`orc iac cnf hub`), zero `parts=all` penalty.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `_spl_hub_run_describe` 15 lines, `do_hub_deploy_verify_gcp` 68 -> 55 lines,
  `do_check_hub_image_regress` 54 -> 42 lines.
  None of the 3 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/check-hub-deploy.func.sh`: replace `:41-58` with
  `_spl_hub_run_describe` + delegated `do_hub_deploy_verify_gcp` header.
  177 -> 182 lines (`+10 -5`).
- `orc:src/bash/run/check-hub-image-regress.func.sh`: replace `:39-55` with lazy-source of
  `check-hub-deploy.func.sh` + `_spl_hub_run_describe || return 1`.
  92 -> 80 lines (`+4 -16`).
- `orc:src/bash/tests/check-hub-deploy.tst.sh`: add section `8` to header after `:26`;
  insert section `8` immediately before `[[ $fails -eq 0 ]] && echo "PASS: all check-hub-deploy assertions" || { echo "FAILED: $fails"; exit 1; }`
  at `:255` (followed by one blank line; `:254` is already blank): 3 direct
  `_spl_hub_run_describe` checks (ok JSON + svc, describe failure `FATAL`, empty
  `env.hub.service_name` `FATAL`), 2 one-copy checks across both files, and 2 standalone
  `check-hub-image-regress.func.sh` lazy-load checks (current + describe failure).
  255 -> 314 lines (`+59 -0`). Total edited files: **3** (within rulebook 3.1's max 5).
- head1's files, sha256 (12 chars): `check-hub-deploy.func.sh` `93d035e70cfa`,
  `check-hub-image-regress.func.sh` `740f45d9af0d`,
  `check-hub-deploy.tst.sh` `6bc080c88cb0`.

Verbatim helper, caller, and test hunks (head1 on `3308d118f`):

`orc:src/bash/run/check-hub-deploy.func.sh` (replace `:41-58`):
```bash
# _spl_hub_run_describe: validate yq/cnf/gcloud/account, read env.hub.service_name,
# and run read-only `gcloud run services describe --format=json`; sets caller-scoped
# svc and json. Returns 1 with FATAL on any missing prerequisite or describe error.
_spl_hub_run_describe() {
  do_require_bin yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  if declare -f do_gcp_require_live_account >/dev/null; then
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  json="$(gcloud run services describe "$svc" --project="$SPL_PROJECT" --region="$SPL_REGION" \
            --account="$GCP_ACCOUNT" --format=json 2>&1)" || {
    do_log "FATAL cannot describe $svc in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT: $(tail -1 <<<"$json")"
    return 1; }
}

# do_hub_deploy_verify_gcp - the Cloud Run check (today's body, unchanged)
do_hub_deploy_verify_gcp() {
  local svc="" json="" image ready created latest
  _spl_hub_run_describe || return 1
```

`orc:src/bash/run/check-hub-image-regress.func.sh` (replace `:39-55`):
```bash
do_check_hub_image_regress() {
  local svc="" json="" live cnf_tag live_tag newest
  # shellcheck source=check-hub-deploy.func.sh
  declare -F _spl_hub_run_describe >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/check-hub-deploy.func.sh" || return 1
  _spl_hub_run_describe || return 1
```

`orc:src/bash/tests/check-hub-deploy.tst.sh` (append to header after `:26`; insert
section `8` immediately before `[[ $fails -eq 0 ]] && echo "PASS: all check-hub-deploy assertions" || { echo "FAILED: $fails"; exit 1; }`
at `:255`, followed by one blank line; `:254` is already blank):
```bash
#   8. _spl_hub_run_describe helper, one-copy across check-hub-deploy and
#      check-hub-image-regress, and standalone lazy-load checks (r12-01)
```
```bash
# --- 8. _spl_hub_run_describe helper and one-copy delegation (r12-01) --------
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls8.log" \
  PATH="$T/stub:$PATH" GCP_ACCOUNT=op@example.com FIXTURE="$T/current.json" bash -c '
  set -uo pipefail; do_log() { echo "$*" >&2; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  source "$PROJ_PATH/src/bash/run/check-hub-deploy.func.sh"
  svc="" json=""; _spl_hub_run_describe || exit $?
  printf "SVC=%s HAS_IMG=%s\n" "$svc" "$(yq -p json -r ".spec.template.spec.containers[0].image // \"\"" <<<"$json")"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"SVC="* && "$out" == *"HAS_IMG=$ref"* ]] &&
  pass "8: _spl_hub_run_describe resolves svc and returns describe JSON" || fail "8: describe ok (rc=$rc out=$out)"

out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls8.log" \
  PATH="$T/stub:$PATH" GCP_ACCOUNT=op@example.com FIXTURE="" bash -c '
  set -uo pipefail; do_log() { echo "$*" >&2; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  source "$PROJ_PATH/src/bash/run/check-hub-deploy.func.sh"
  svc="" json=""; _spl_hub_run_describe' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL cannot describe "* && "$out" == *"NOT_FOUND"* ]] &&
  pass "8: _spl_hub_run_describe logs FATAL and returns 1 on describe error" || fail "8: describe fail (rc=$rc out=$out)"

printf 'env:\n  hub:\n    service_name: ""\n' >"$T/empty-svc.yaml"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls8.log" \
  PATH="$T/stub:$PATH" GCP_ACCOUNT=op@example.com FIXTURE="$T/current.json" EMPTY_CNF="$T/empty-svc.yaml" bash -c '
  set -uo pipefail; do_log() { echo "$*" >&2; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  source "$PROJ_PATH/src/bash/run/check-hub-deploy.func.sh"
  do_spl_cloud_cnf() { SPL_CNF="$EMPTY_CNF"; SPL_PROJECT=p; SPL_REGION=r; }
  svc="" json=""; _spl_hub_run_describe' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL cnf env.hub.service_name is empty for dev"* ]] &&
  pass "8: _spl_hub_run_describe refuses empty env.hub.service_name with rc 1" || fail "8: empty svc (rc=$rc out=$out)"

chd_f="$PROJ_ROOT/src/bash/run/check-hub-deploy.func.sh"
chir_f="$PROJ_ROOT/src/bash/run/check-hub-image-regress.func.sh"
[[ "$(grep -c '^_spl_hub_run_describe()' "$chd_f")" -eq 1 ]] && grep -q '_spl_hub_run_describe ' "$chd_f" &&
  pass "8: one copy: check-hub-deploy.func.sh hosts _spl_hub_run_describe" || fail "8: host check"
own_chir="$(grep -nE 'gcloud run services describe|env\.hub\.service_name|do_gcp_pin_account|cannot describe \$svc' "$chir_f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$own_chir" ]] && grep -q '_spl_hub_run_describe ' "$chir_f" &&
  pass "8: one copy: check-hub-image-regress.func.sh delegates to _spl_hub_run_describe" || fail "8: chir own=[$own_chir]"

out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls8-reg.log" \
  PATH="$T/stub:$PATH" GCP_ACCOUNT=op@example.com FIXTURE="$T/current.json" bash -c '
  set -uo pipefail; do_log() { echo "$*" >&2; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  source "$PROJ_PATH/src/bash/run/check-hub-image-regress.func.sh"
  do_check_hub_image_regress' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"dev current service="* && "$out" == *"image=$ref"* ]] &&
  pass "8: standalone: check-hub-image-regress lazy-loads _spl_hub_run_describe (current)" || fail "8: standalone chir ok (rc=$rc out=$out)"

out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls8-reg.log" \
  PATH="$T/stub:$PATH" GCP_ACCOUNT=op@example.com FIXTURE="" bash -c '
  set -uo pipefail; do_log() { echo "$*" >&2; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  source "$PROJ_PATH/src/bash/run/check-hub-image-regress.func.sh"
  do_check_hub_image_regress' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL cannot describe "* && "$out" == *"NOT_FOUND"* ]] &&
  pass "8: standalone: check-hub-image-regress preserves FATAL on describe failure" || fail "8: standalone chir fail (rc=$rc out=$out)"
```

**Behaviour:** zero functional behaviour change. Both `do_hub_deploy_verify_gcp` and
`do_check_hub_image_regress` preserve exact stdout verdict lines, exact exit codes
(`0`, `1`, `3`, `4`), exact `FATAL` messages, exact `gcloud --account="$GCP_ACCOUNT"`
invocations, and exact refusal of missing SA key / empty `env.hub.service_name` (both
standalone `check-hub-image-regress` checks pass on unmodified `base` too, proving
equivalence).
- **One accepted stderr audit-log note:** `do_gcp_pin_account`
  (`iac:lib/bash/funcs/gcp-account-pin.func.sh:275`) logs `${FUNCNAME[2]}` in its stderr
  `INFO gcloud project=... account=... (<caller>)` line, which now prints
  `(_spl_hub_run_describe)` instead of `(do_hub_deploy_verify_gcp)` or
  `(do_check_hub_image_regress)`. No caller or test parses that parenthesized tag.

### 1.4 Row 02's site: `_spl_desk_args_split` and `_spl_desk_in_file` desk doc input helpers (`spl-desk-doctree`, `spl-desk-wsdoc`)

`orc:` = `csi-spl-orc/`. On `3308d118f`:

- `orc:src/bash/run/spl-desk-wsdoc.func.sh` is the documented twin of
  `orc:src/bash/run/spl-desk-doctree.func.sh` and already lazy-sources
  `spl-desk-doctree.func.sh` (`:64-65`) to reuse `_spl_desk_doctree_seated` and
  `_spl_desk_doctree_caller_ok`. Yet it still duplicates two whole input-validation helpers
  verbatim from `spl-desk-doctree.func.sh`:
  1. Shell-style arg splitting (`python3` `shlex.split` -> `mapfile -d '' -t`, refusing
     blank, unbalanced quotes, or empty result):
     - `orc:src/bash/run/spl-desk-doctree.func.sh:137-148` (`_spl_desk_doctree_split`,
       9-line function; env var `DOCTREE_ARGS`, usage hint
       `"the doctree verb and its flags, e.g. DOCTREE_ARGS=list"`).
     - `orc:src/bash/run/spl-desk-wsdoc.func.sh:102-113` (`_spl_desk_wsdoc_split`,
       9-line function; env var `WSDOC_ARGS`, usage hint
       `"the verb and its path, e.g. WSDOC_ARGS='list ws/'"`).
  2. Input file path resolution and containment guard (`realpath -e`, `-f && -r`,
     desk-state `SPL_STATE_DIR` refusal, allowed-roots loop over `APP_PATH`, `/tmp`,
     `/var/spool-hub/dispatch`):
     - `orc:src/bash/run/spl-desk-doctree.func.sh:150-173` (`_spl_desk_doctree_in`,
       20-line function; env var `DOCTREE_IN`, empty allowed -> rc 0).
     - `orc:src/bash/run/spl-desk-wsdoc.func.sh:143-166` (`_spl_desk_wsdoc_in`,
       20-line function; env var `WSDOC_IN`, empty refused -> `FATAL write needs WSDOC_IN: the body file`, rc 1).
- Hosting `_spl_desk_args_split` and `_spl_desk_in_file` in `spl-desk-doctree.func.sh`
  adds zero new files and zero eager loads. Both `_spl_desk_doctree_split` /
  `_spl_desk_doctree_in` and `_spl_desk_wsdoc_split` / `_spl_desk_wsdoc_in` remain intact
  as thin wrappers (forwarding `"$1"` directly without nested `local -n` nameref aliasing)
  so any caller or test invoking them by name continues to work; `_spl_desk_wsdoc_split`
  and `_spl_desk_wsdoc_in` lazy-source `spl-desk-doctree.func.sh` on demand so standalone
  sourcing of `spl-desk-wsdoc.func.sh` alone works identically to base.
- Neither helper reads or writes any secret, key, or desk credential (pure `shlex` +
  `realpath` path validation; all tests stub `spool` and run hermetically; non-secret).
- **Narrow CI:** all 3 edited files live under `csi-spl-orc/src/bash/`, so
  `ci-doc-only.sh:122` selects narrow CI (`orc iac cnf hub`), zero `parts=all` penalty.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `_spl_desk_args_split` 10 lines, `_spl_desk_doctree_split` 9 -> 3 lines,
  `_spl_desk_in_file` 22 lines, `_spl_desk_doctree_in` 20 -> 3 lines,
  `_spl_desk_wsdoc_split` 9 -> 5 lines, `_spl_desk_wsdoc_in` 20 -> 5 lines.
  None of the 3 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-desk-doctree.func.sh`: replace `:137-173` with
  `_spl_desk_args_split`, thin `_spl_desk_doctree_split`, `_spl_desk_in_file`, and thin
  `_spl_desk_doctree_in`. 295 -> 309 lines (`+37 -23`).
- `orc:src/bash/run/spl-desk-wsdoc.func.sh`: replace `:102-113` (`_spl_desk_wsdoc_split`)
  and `:143-166` (`_spl_desk_wsdoc_in`) with lazy-source + delegation to
  `_spl_desk_args_split` and `_spl_desk_in_file` (`_spl_desk_wsdoc_check` `:115-141`
  untouched). 166 -> 142 lines (`+8 -32`).
- `orc:src/bash/tests/desk-doctree.tst.sh`: add section `11` to header after `:32`;
  insert section `11` immediately before `echo "desk-doctree: $fails failure(s)"` at
  `:207` (followed by one blank line; `:206` is already blank): 3 direct
  `_spl_desk_args_split` checks, 5 direct `_spl_desk_in_file` checks (valid, optional
  empty, required empty, desk-state symlink refusal, outside-roots refusal), 2 one-copy
  checks across both files, and 3 standalone `spl-desk-wsdoc.func.sh` lazy-load checks.
  208 -> 291 lines (`+83 -0`). Total edited files: **3** (within rulebook 3.1's max 5).
- head2's files, sha256 (12 chars): `spl-desk-doctree.func.sh` `81e07447278c`,
  `spl-desk-wsdoc.func.sh` `7570f316a395`,
  `desk-doctree.tst.sh` `71736fd8a0dc`.

Verbatim helper, caller, and test hunks (head2 on `3308d118f`):

`orc:src/bash/run/spl-desk-doctree.func.sh` (replace `:137-173`):
```bash
# _spl_desk_args_split <array name> <env var> <usage hint>: split the named
# env var shell-style (quotes kept, nothing expanded or run) into the named
# array. 1 with the FATAL when it is empty or does not parse.
_spl_desk_args_split() {
  local -n _da_out="$1"
  local var="$2" hint="$3" raw="${!2:-}"
  local split='import shlex,sys; sys.stdout.write("".join(w + "\0" for w in shlex.split(sys.argv[1])))'
  [[ -n "${raw//[[:space:]]/}" ]] || { do_log "FATAL $var must carry $hint"; return 1; }
  python3 -c "$split" "$raw" >/dev/null 2>&1 ||
    { do_log "FATAL $var does not parse (an unbalanced quote?): $raw"; return 1; }
  mapfile -d '' -t _da_out < <(python3 -c "$split" "$raw")
  (( ${#_da_out[@]} > 0 )) || { do_log "FATAL $var is empty"; return 1; }
}

# _spl_desk_doctree_split <array name>: DOCTREE_ARGS split shell-style into the named array.
_spl_desk_doctree_split() {
  _spl_desk_args_split "$1" DOCTREE_ARGS "the doctree verb and its flags, e.g. DOCTREE_ARGS=list"
}

# _spl_desk_in_file <var name> <env var> [required msg]: resolve the named
# input file env var (symlinks followed) into the named var; empty returns 0
# unless required_msg is given (FATAL + rc 1). Refused: not a readable regular
# file, inside the desk state, or outside APP_PATH, /tmp and /var/spool-hub/dispatch.
_spl_desk_in_file() {
  local -n _di_out="$1"
  local var="$2" req="${3:-}" raw="${!2:-}" real root ok=0
  _di_out=""
  if [[ -z "$raw" ]]; then
    [[ -z "$req" ]] && return 0
    do_log "FATAL $req"; return 1
  fi
  real="$(realpath -e -- "$raw" 2>/dev/null)" || real=""
  if [[ ! -f "$real" || ! -r "$real" ]]; then
    do_log "FATAL $var is not a readable file: $raw"; return 1
  fi
  if [[ "$real" == "$(realpath -m -- "$SPL_STATE_DIR")/"* ]]; then
    do_log "FATAL $var lies in the desk state, which never leaves this action"; return 1
  fi
  for root in "${APP_PATH:-}" /tmp /var/spool-hub/dispatch; do
    [[ -n "$root" ]] || continue
    root="$(realpath -m -- "$root")"
    [[ "$real" == "$root/"* ]] && { ok=1; break; }
  done
  (( ok )) || { do_log "FATAL $var must lie in the caller's worktree (${APP_PATH:-unset}), /tmp or /var/spool-hub/dispatch: $raw"; return 1; }
  _di_out="$real"
}

# _spl_desk_doctree_in <var name>: DOCTREE_IN resolved (symlinks followed) into the named var.
_spl_desk_doctree_in() {
  _spl_desk_in_file "$1" DOCTREE_IN
}
```

`orc:src/bash/run/spl-desk-wsdoc.func.sh` (replace `:102-113`):
```bash
# _spl_desk_wsdoc_split <array name>: WSDOC_ARGS split shell-style into the named array.
_spl_desk_wsdoc_split() {
  # shellcheck source=spl-desk-doctree.func.sh
  declare -F _spl_desk_args_split >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-doctree.func.sh" || return 1
  _spl_desk_args_split "$1" WSDOC_ARGS "the verb and its path, e.g. WSDOC_ARGS='list ws/'"
}
```

`orc:src/bash/run/spl-desk-wsdoc.func.sh` (replace `:143-166`):
```bash
# _spl_desk_wsdoc_in <var name>: WSDOC_IN resolved (symlinks followed) into the named var.
_spl_desk_wsdoc_in() {
  # shellcheck source=spl-desk-doctree.func.sh
  declare -F _spl_desk_in_file >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-doctree.func.sh" || return 1
  _spl_desk_in_file "$1" WSDOC_IN "write needs WSDOC_IN: the body file"
}
```

`orc:src/bash/tests/desk-doctree.tst.sh` (append to header after `:32`; insert section
`11` immediately before `echo "desk-doctree: $fails failure(s)"` at `:207`, followed by
one blank line; `:206` is already blank):
```bash
#  11. _spl_desk_args_split / _spl_desk_in_file helpers, one-copy across
#      spl-desk-doctree and spl-desk-wsdoc, and standalone lazy-load (r12-02)
```
```bash
# --- 11. _spl_desk_args_split / _spl_desk_in_file and one-copy (r12-02) -------------------
dt_f="$PROJ_ROOT/src/bash/run/spl-desk-doctree.func.sh"
ws_f="$PROJ_ROOT/src/bash/run/spl-desk-wsdoc.func.sh"

out="$(DEMO_ARGS='edit "a b" c' bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; arr=(); _spl_desk_args_split arr DEMO_ARGS "demo hint" || exit $?
  printf "N=%d 0=%s 1=%s 2=%s\n" "${#arr[@]}" "${arr[0]}" "${arr[1]}" "${arr[2]}"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "N=3 0=edit 1=a b 2=c" ]] &&
  pass "11: _spl_desk_args_split splits quoted shell args into caller array" || fail "11: split ok ($rc: $out)"

out="$(DEMO_ARGS='   ' bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; arr=(); _spl_desk_args_split arr DEMO_ARGS "demo hint"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DEMO_ARGS must carry demo hint"* ]] &&
  pass "11: _spl_desk_args_split refuses blank var with caller hint" || fail "11: split empty ($rc: $out)"

out="$(DEMO_ARGS='edit "unclosed' bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; arr=(); _spl_desk_args_split arr DEMO_ARGS "demo hint"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DEMO_ARGS does not parse (an unbalanced quote?):"* ]] &&
  pass "11: _spl_desk_args_split refuses unbalanced quotes" || fail "11: split bad ($rc: $out)"

out="$(DEMO_IN="$IN/body.md" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_in_file v DEMO_IN || exit $?
  printf "V=%s\n" "$v"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "V=$IN/body.md" ]] &&
  pass "11: _spl_desk_in_file resolves readable file under /tmp" || fail "11: in ok ($rc: $out)"

out="$(DEMO_IN="" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v="keep"; _spl_desk_in_file v DEMO_IN || exit $?
  printf "V=[%s]\n" "$v"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "V=[]" ]] &&
  pass "11: _spl_desk_in_file allows empty when optional" || fail "11: in opt ($rc: $out)"

out="$(DEMO_IN="" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_in_file v DEMO_IN "write needs DEMO_IN"' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL write needs DEMO_IN"* ]] &&
  pass "11: _spl_desk_in_file logs required message and returns 1 when empty" || fail "11: in req ($rc: $out)"

out="$(DEMO_IN="$IN/link" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_in_file v DEMO_IN' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DEMO_IN lies in the desk state, which never leaves this action"* ]] &&
  pass "11: _spl_desk_in_file refuses symlink into desk state" || fail "11: in link ($rc: $out)"

out="$(DEMO_IN=/etc/hostname APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_in_file v DEMO_IN' _ "$dt_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL DEMO_IN must lie in the caller's worktree"* ]] &&
  pass "11: _spl_desk_in_file refuses file outside allowed roots" || fail "11: in outside ($rc: $out)"

[[ "$(grep -c '^_spl_desk_args_split()' "$dt_f")" -eq 1 && "$(grep -c '^_spl_desk_in_file()' "$dt_f")" -eq 1 ]] &&
  pass "11: one copy: spl-desk-doctree.func.sh hosts _spl_desk_args_split and _spl_desk_in_file" || fail "11: host"
own_ws="$(grep -nE 'shlex\.split|realpath -e|lies in the desk state|must lie in the caller' "$ws_f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[[ -z "$own_ws" ]] && grep -q '_spl_desk_args_split ' "$ws_f" && grep -q '_spl_desk_in_file ' "$ws_f" &&
  pass "11: one copy: spl-desk-wsdoc.func.sh delegates split and in-file to _spl_desk_*" || fail "11: wsdoc own=[$own_ws]"

out="$(WSDOC_ARGS='read ws/agents/a.md' bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; a=(); _spl_desk_wsdoc_split a || exit $?
  printf "A=%s|%s\n" "${a[0]}" "${a[1]}"' _ "$ws_f" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "A=read|ws/agents/a.md" ]] &&
  pass "11: standalone: spl-desk-wsdoc lazy-loads _spl_desk_args_split" || fail "11: standalone ws split ($rc: $out)"

out="$(WSDOC_IN="" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_wsdoc_in v' _ "$ws_f" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL write needs WSDOC_IN: the body file"* ]] &&
  pass "11: standalone: spl-desk-wsdoc lazy-loads _spl_desk_in_file and preserves required msg" || fail "11: standalone ws req ($rc: $out)"

out="$(WSDOC_IN="$IN/body.md" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" bash -c '
  set -uo pipefail; do_log() { echo "$*"; }
  . "$1"; v=""; _spl_desk_wsdoc_in v || exit $?
  printf "V=%s\n" "$v"' _ "$ws_f" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == "V=$IN/body.md" ]] &&
  pass "11: standalone: spl-desk-wsdoc resolves valid WSDOC_IN via _spl_desk_in_file" || fail "11: standalone ws ok ($rc: $out)"
```

**Behaviour:** zero behaviour change. Both `do_spl_desk_doctree` and `do_spl_desk_wsdoc`
(and their helper entry points `_spl_desk_doctree_split`, `_spl_desk_doctree_in`,
`_spl_desk_wsdoc_split`, `_spl_desk_wsdoc_in`) preserve exact `FATAL` messages, exact
allowed roots (`APP_PATH`, `/tmp`, `/var/spool-hub/dispatch`), exact desk-state refusal,
exact optional-empty vs required-empty handling, and exact exit codes (all 3 standalone
`spl-desk-wsdoc` checks pass on unmodified `base` too, proving equivalence).

### 1.5 Before and on the rows' heads

2026-11-27T17:14:15Z-17:33:59Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to
base: same rc, pass and fail counts; "-" means that row's head does not touch the suite's
tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/check-hub-deploy.tst.sh` | 01 | 0 / 56 / 0 | 0 / 63 / 0 (+7 new checks) | - |
| `orc:src/bash/tests/check-hub-image-regress.tst.sh` | 01 | 0 / 15 / 0 | = | - |
| `orc:src/bash/tests/run-loader-convention.tst.sh` | 01 | 0 / 9 / 0 | = | - |
| `orc:src/bash/tests/rollback.tst.sh` | 01 | 0 / 44 / 0 | = | - |
| `orc:src/bash/tests/desk-doctree.tst.sh` | 02 | 0 / 36 / 0 | - | 0 / 49 / 0 (+13 new checks) |
| `orc:src/bash/tests/desk-wsdoc.tst.sh` | 02 | 0 / 28 / 0 | - | = |
| `orc:src/bash/tests/doctree-folder-delete-verb.tst.sh` | 02 | 0 / 3 / 0 | - | = |
| `orc:src/bash/tests/doctree-move-node-verb.tst.sh` | 02 | 0 / 2 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |

Note (\*): `check-hub-deploy.tst.sh` prints a final `PASS: all check-hub-deploy assertions`
on success (included in the 56 / 63 pass counts) and `FAILED: <N>` on failure (matched
by `grep -ciE '^ *(not ok|fail)'`, so `rc1` and `m1a`-`m1c` fail-line counts are `N + 1`
while the `FAILED: <N>` footer states the exact real `FAIL:` count; both are stated below).
`gcloud-account-pinned.tst.sh` counts are box-dependent (48 on this box; equal on base and
heads). Run `no-literal-paths.tst.sh` in a git checkout owned by the user running git.

`shellcheck 0.10.0 -S warning -x` on all 6 edited files (head1: 3 files, head2: 3 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own scratch clone of `3308d118f`, reconstructed
from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `check-hub-deploy.tst.sh` on base): rc 1, 57 pass
  (55 base individual + both standalone `check-hub-image-regress` checks passing on base,
  proving equivalence), `6*` fail lines (`FAILED: 5`: 3 `_spl_hub_run_describe: command not found`,
  `FAIL: 8: host check`, and `FAIL: 8: chir own=[42: ...]` naming
  `check-hub-image-regress.func.sh:42,50,54`); head1: rc 0, 63 pass, 0 fail.
- Row 02 red control (`rc2`, head2's `desk-doctree.tst.sh` on base): rc 1, 39 pass
  (36 base + all 3 standalone `spl-desk-wsdoc` checks passing on base, proving
  equivalence), 10 fail (3 `_spl_desk_args_split: command not found`, 5
  `_spl_desk_in_file: command not found`, `FAIL: 11: host`, and `FAIL: 11: wsdoc own=[...]`
  naming `spl-desk-wsdoc.func.sh:107,152,157,164`); head2: rc 0, 49 pass, 0 fail.

**Mutation checks** (n=1 each, fresh scratch clones of `3308d118f` with head1/head2
applied, then one defect planted; all hermetic, never touching `$HOME`):
- `m1a` (`_spl_hub_run_describe` drops `--account="$GCP_ACCOUNT"`): `check-hub-deploy.tst.sh`
  rc 1, 60 pass, `3*` fail lines (`FAILED: 2`: `revisions describe call` and
  `a gcloud call without --account`).
- `m1b` (`_spl_hub_run_describe` bypasses empty `env.hub.service_name` check):
  `check-hub-deploy.tst.sh` rc 1, 61 pass, `2*` fail lines (`FAILED: 1`: `8: empty svc`).
- `m1c` (`check-hub-image-regress.func.sh` drops lazy-source of `check-hub-deploy.func.sh`):
  `check-hub-deploy.tst.sh` rc 1, 60 pass, `3*` fail lines (`FAILED: 2`:
  `8: standalone chir ok` and `8: standalone chir fail`).
- `m2a` (`_spl_desk_wsdoc_in` drops the required-empty message): `desk-doctree.tst.sh`
  rc 1, 48 pass, 1 fail (`11: standalone ws req`).
- `m2b` (`_spl_desk_in_file` disables the `SPL_STATE_DIR` desk-state symlink guard):
  `desk-doctree.tst.sh` rc 1, 47 pass, 2 fail
  (`a /tmp symlink into the desk state is refused` and `11: in link`).
- `m2c` (`_spl_desk_wsdoc_split` drops lazy-source of `spl-desk-doctree.func.sh`):
  `desk-doctree.tst.sh` rc 1, 48 pass, 1 fail (`11: standalone ws split`).

The tests that name the sites (R2): `git grep -lE` over `*/tests/*` on `3308d118f`:
- Row 01 (`check-hub-deploy|do_check_hub_deploy|do_hub_deploy_verify_gcp|check-hub-image-regress|do_check_hub_image_regress`) ->
  **`orc:src/bash/tests/check-hub-deploy.tst.sh`** (edited),
  `orc:src/bash/tests/check-hub-image-regress.tst.sh`,
  `orc:src/bash/tests/run-loader-convention.tst.sh`, and
  `orc:src/bash/tests/rollback.tst.sh` (stubs `do_check_hub_deploy`). Other grep hits
  (`check-deploy-lag.tst.sh`, `hub-image-key-wf20.tst.sh`, `lane-map.tst.sh`) are
  comments or negative string assertions only; `changed-tests.sh` and
  `orc-shard-weights.txt` are runner/shard tables. Zero hits in `csi-spl-iac/` or
  `csi-spl-utl/`.
- Row 02 (`spl-desk-doctree|do_spl_desk_doctree|_spl_desk_doctree_|spl-desk-wsdoc|do_spl_desk_wsdoc|_spl_desk_wsdoc_`) ->
  **`orc:src/bash/tests/desk-doctree.tst.sh`** (edited),
  `orc:src/bash/tests/desk-wsdoc.tst.sh`,
  `orc:src/bash/tests/doctree-folder-delete-verb.tst.sh`, and
  `orc:src/bash/tests/doctree-move-node-verb.tst.sh`. Other grep hits
  (`check-qto-doc-drift.tst.sh`, `desk-cron-write-guard.tst.sh`,
  `doctree-export-private-repo.tst.sh`, `doctree-export-tenant-allow.tst.sh`,
  `qto-private-index.tst.sh`) stub `do_spl_desk_doctree` directly. Zero hits in
  `csi-spl-iac/` or `csi-spl-utl/`.
- 30-char comment/string grep across edited sites (+/- 3 lines): only generic
  `do_gcp_require_live_account` stubs across unrelated tests and the exact `FATAL`
  assertions already covered by `desk-doctree.tst.sh` and `desk-wsdoc.tst.sh`. No new
  test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r12-01-orc-hub-run-describe)` | one fact, one copy (developer guide 2.2.4) | `check-hub-deploy.func.sh:43-58` and `check-hub-image-regress.func.sh:40-55` duplicate the exact 16-line Cloud Run describe preamble (`do_require_bin yq`, `do_spl_cloud_cnf`, `do_gcp_pin_account`, `gcloud` check, `do_gcp_require_live_account`, `env.hub.service_name` read + empty `FATAL`, and read-only `gcloud run services describe --format=json` + error `FATAL`; 1.3) | `orc:src/bash/run/check-hub-deploy.func.sh:41-58`<br>`orc:src/bash/run/check-hub-image-regress.func.sh:39-55`<br>`orc:src/bash/tests/check-hub-deploy.tst.sh:26,255` | copies of the 16-line Cloud Run JSON describe preamble across `check-hub-deploy` and `check-hub-image-regress` 2 -> 1 (hosted once as `_spl_hub_run_describe` in `check-hub-deploy.func.sh`) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `check-hub-deploy.tst.sh` on parent FAILs 5 checks (`rc1`, rc 1, 57 pass, `FAILED: 5` / `6*` fail lines: 3 helper-missing + 2 one-copy checks naming `check-hub-image-regress.func.sh:42,50,54`; both standalone checks pass on base), then GREEN (`0/63/0`, +7 new checks); hermetic mutations `m1a` (drop `--account`, rc 1, `FAILED: 2`), `m1b` (bypass empty `service_name` check, rc 1, `FAILED: 1`), and `m1c` (drop lazy-source, rc 1, `FAILED: 2`) caught (1.5); outputs in the body. **Behaviour:** zero functional behaviour change (one accepted stderr audit-log tag change: `do_gcp_pin_account` logs `(_spl_hub_run_describe)` via `${FUNCNAME[2]}`, 1.3). Tests: **`orc:.../check-hub-deploy.tst.sh`**, `orc:.../check-hub-image-regress.tst.sh`, `orc:.../run-loader-convention.tst.sh`, `orc:.../rollback.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r12-02-orc-desk-doc-input-helpers)` | one fact, one copy (developer guide 2.2.4) | `spl-desk-doctree.func.sh:137-173` and `spl-desk-wsdoc.func.sh:102-113,143-166` duplicate both the 9-line `python3 shlex.split` arg-splitter and the 20-line `realpath` + desk-state + allowed-roots input-file guard, even though `spl-desk-wsdoc` already lazy-sources `spl-desk-doctree` for seated/caller checks (1.4) | `orc:src/bash/run/spl-desk-doctree.func.sh:137-173`<br>`orc:src/bash/run/spl-desk-wsdoc.func.sh:102-113,143-166`<br>`orc:src/bash/tests/desk-doctree.tst.sh:32,207` | copies of the desk doc `shlex` arg-splitter and `realpath` input-file guard across `spl-desk-doctree` and `spl-desk-wsdoc` 2 -> 1 each (hosted once as `_spl_desk_args_split` and `_spl_desk_in_file` in `spl-desk-doctree.func.sh`) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `desk-doctree.tst.sh` on parent FAILs 10 checks (`rc2`, rc 1, 39 pass, 10 fail: 8 helper-missing + 2 one-copy checks naming `spl-desk-wsdoc.func.sh:107,152,157,164`; all 3 standalone checks pass on base), then GREEN (`0/49/0`, +13 new checks); hermetic mutations `m2a` (`_spl_desk_wsdoc_in` drops required msg, rc 1, 1 fail), `m2b` (`_spl_desk_in_file` drops desk-state symlink guard, rc 1, 2 fail), and `m2c` (`_spl_desk_wsdoc_split` drops lazy-source, rc 1, 1 fail) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change. Tests: **`orc:.../desk-doctree.tst.sh`**, `orc:.../desk-wsdoc.tst.sh`, `orc:.../doctree-folder-delete-verb.tst.sh`, `orc:.../doctree-move-node-verb.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4) on the
`origin/master` it starts from, and says in its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r12-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r12-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows consolidate internal shell helper copies with zero change to any
output, exit code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper consolidation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  (row 01: `orc:src/bash/run/check-hub-deploy.func.sh`,
  `orc:src/bash/run/check-hub-image-regress.func.sh`,
  `orc:src/bash/tests/check-hub-deploy.tst.sh`; row 02:
  `orc:src/bash/run/spl-desk-doctree.func.sh`,
  `orc:src/bash/run/spl-desk-wsdoc.func.sh`,
  `orc:src/bash/tests/desk-doctree.tst.sh`).
- Neither row edits `check-hub-image-regress.tst.sh`, `desk-wsdoc.tst.sh`,
  `canary-hub-deploy.func.sh`, `deploy-hub.func.sh`, `heal-hub-deploy.func.sh`,
  `hub-rollback.func.sh`, `spl-rotate-lib.func.sh`, `.shellcheck-warning-baseline.txt`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform, `csi-spl-api/`,
  `csi-spl-iac/`, `csi-spl-utl/`, or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (6 edited + 4 sibling regression-run files = 10 checked via `lane-map.sh --check`
at 2026-11-27T17:13:40Z):
`orc:src/bash/run/check-hub-deploy.func.sh`,
`orc:src/bash/run/check-hub-image-regress.func.sh`,
`orc:src/bash/tests/check-hub-deploy.tst.sh`,
`orc:src/bash/tests/check-hub-image-regress.tst.sh`,
`orc:src/bash/run/spl-desk-doctree.func.sh`,
`orc:src/bash/run/spl-desk-wsdoc.func.sh`,
`orc:src/bash/tests/desk-doctree.tst.sh`,
`orc:src/bash/tests/desk-wsdoc.tst.sh`,
`orc:src/bash/tests/doctree-folder-delete-verb.tst.sh`,
`orc:src/bash/tests/doctree-move-node-verb.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <10 paths> --agent a-731`, n=1, at
  2026-11-27T17:13:40Z: **exit 4** ("no live lane lists `<paths>`, but 25 live lane(s)
  record no files", 0 owned). All 25 `unknown:` live lanes are on the other box (15
  channel/workspace/other-repo/blog seats `c-029`, `c-079`, `c-086`, `c-146`, `c-187`,
  `c-407`, `c-416`, `c-474`, `c-535`, `c-728`, `c-855`, `c-927`, `c-936`, `c-971`,
  `c-995`, plus `c-264` s158 P2 pin sweep, `c-749` b53 panel seat, `c-832` SPL-6675 WUI
  search panel, `c-879` s187 text fixes, `c-943` r11-01 landed, `c-966` SPL-6385 CI A1b,
  `c-982` SPL-6692 s187 channel move scope_query, `c-985` SPL-6694 s184 L2 launch model,
  `c-987` SPL-6695 s184 L3 restore rotation repick, and `c-999` this round's claude panel
  seat). Verified via `do_spl_lane_map` at 17:06:26Z — live lanes on this box (`a-731`,
  `c-651` SPL-6680 laptop-box, `c-722` SPL-6635 `dispatch-rotate.tst.sh`, `a-719` b53
  planner, `a-725` CI A1b R7, `a-672` SPL-6683 R7, `a-670` SPL-6675 R7, `a-694` SPL-6682
  R7, `m-674` style panel) and `c-876` (SPL-6682 hub move status) touch none of our 10
  paths. No live lane owns any of the 10 paths; the holder re-reads at placement per R3.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-27T17:06:30Z):
  107 queued, 0 placing (including `de7ac1ab` this round's claude panel seat since placed
  as `c-999`, CI A2/A3 refactor rows, bug lanes `e9ab1a9d` / `033fef08` / `1bd2e837`,
  WUI asks `6dc9ea07` / `449cef39` / `f7b4d754` / `2b4f6cee` / `a338e1e9`, and
  s039/s107/s112/s150/s162/s167/s169/s173/s174/s177/s179/s182/s184/s185/s186/s187/s190/s193/s195/s196
  feature rows). None touches any of our 10 paths.
- **Briefs on this box** modified in the last 48 h matching any of our 10 paths (at
  17:13:43Z): **0 live overlapping briefs**.
- **Remote branches committed in the last 48 h** (`git for-each-ref`, at 17:13:44Z):
  162 branches checked with `git diff --name-only $(git merge-base 3308d118f <b>) <b> -- <10 paths>` ->
  **0 hits**.
- **Commits in the last 48 h** on the 10 checked paths (`git log origin/master --since='48 hours ago'`,
  at 17:13:43Z) -> **0** (and 0 commits on the 10 paths from `3308d118f` to `origin/master`
  `6d3b1bf86` at 17:34:21Z).

## 3. Per row: what the lane does

- **r12-01:** `orc:src/bash/run/check-hub-deploy.func.sh` replaces `:41-58` with
  `_spl_hub_run_describe` and delegates `do_hub_deploy_verify_gcp` to it.
  `orc:src/bash/run/check-hub-image-regress.func.sh` replaces `:39-55` with lazy-load of
  `check-hub-deploy.func.sh` and `_spl_hub_run_describe || return 1`.
  `orc:src/bash/tests/check-hub-deploy.tst.sh` adds section `8` to the header (`:26`)
  and inserts section `8` before `:255` (3 helper checks, 2 one-copy checks, and 2
  standalone lazy-load checks).
- **r12-02:** `orc:src/bash/run/spl-desk-doctree.func.sh` replaces `:137-173` with
  `_spl_desk_args_split`, thin `_spl_desk_doctree_split`, `_spl_desk_in_file`, and thin
  `_spl_desk_doctree_in`.
  `orc:src/bash/run/spl-desk-wsdoc.func.sh` replaces `:102-113` and `:143-166` with
  lazy-load of `spl-desk-doctree.func.sh` and delegation to `_spl_desk_args_split` and
  `_spl_desk_in_file`.
  `orc:src/bash/tests/desk-doctree.tst.sh` adds section `11` to the header (`:32`) and
  inserts section `11` before `:207` (8 helper checks, 2 one-copy checks, and 3
  standalone lazy-load checks).

## 4. Panel and reviewers (R7)

- Editor: **a-731** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat **c-999**
  (`c002-refactor-round-12-claude-panel-seat`, placed per holder msg `f06f190d`).
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-27T17:07:51Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix` at 17:07:20Z reported
    `main=agy`, `backup=claude`, `pick=agy` (`paused none`, mistral skipped on review).
    R7 review of each claude coding row goes to an **agy seat** per row (claude waiver
    backup only while agy is out of quota or paused, citing ruling `dc84300a`; never
    mistral).
  - `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 17:07:25Z picked the less-loaded box
    (111% vs 183% on this box; note agy on the other box is out of quota until 12-03 per
    brief, so agy runs on this box); `BOX_PICK_KIND=claude` at 17:07:39Z picked the other
    box (111%, `claude weekly 42%` vs `43%` on this box). The holder re-checks capacity at
    row placement.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

### 4.1 Consensus table (rulebook 3.1 / 3.2)

| seat | vendor | role | plan sha | verdict | review line / note |
|---|---|---|---|---|---|
| `a-731` | agy | editor | v0.1 | draft | all 17 base/head suites green; shellcheck 0.10.0 + `do_sec_shellcheck` rc 0; `rc1`/`rc2` + 6 mutations verified RED on `3308d118f` |
| `c-999` | claude | panel | pending | pending | awaiting panel review on `review/c002-refactor-round-12-planner` |

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r12-01 | `c002-r12-01-orc-hub-run-describe` | `refactor(r12-01-orc-hub-run-describe, SPL-<row issue>): ...` | `review/r12-01` | 1 |
| r12-02 | `c002-r12-02-orc-desk-doc-input-helpers` | `refactor(r12-02-orc-desk-doc-input-helpers, SPL-<row issue>): ...` | `review/r12-02` | 1 |

**r12-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` (replace `:41-58` with
`_spl_hub_run_describe` + delegated `do_hub_deploy_verify_gcp` header),
`csi-spl-orc/src/bash/run/check-hub-image-regress.func.sh` (replace `:39-55` with
lazy-load + `_spl_hub_run_describe || return 1`), and
`csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh` (header `:26`, insert section `8`
before `:255`). NOT `check-hub-image-regress.tst.sh`, NOT `canary-hub-deploy.func.sh`,
NOT `deploy-hub.func.sh`, NOT `heal-hub-deploy.func.sh`, NOT `hub-rollback.func.sh`, NOT
`csi-spl-iac/`, NOT `.shellcheck-warning-baseline.txt`, or any other file. Do: plan
section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3); red control (`rc1`,
head1's `check-hub-deploy.tst.sh` on parent: rc 1, 57 pass, `FAILED: 5` / `6*` fail lines)
RED then GREEN (`0/63/0`) in the body; hermetic mutations `m1a` (rc 1, `FAILED: 2`), `m1b`
(rc 1, `FAILED: 1`), and `m1c` (rc 1, `FAILED: 2`) caught. Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 3 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota or
paused, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if
the claude backup is used; never mistral; re-checked at placement).

**r12-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-desk-doctree.func.sh` (replace `:137-173` with
`_spl_desk_args_split`, thin `_spl_desk_doctree_split`, `_spl_desk_in_file`, and thin
`_spl_desk_doctree_in`),
`csi-spl-orc/src/bash/run/spl-desk-wsdoc.func.sh` (replace `:102-113` and `:143-166`
with lazy-load + `_spl_desk_args_split` / `_spl_desk_in_file`), and
`csi-spl-orc/src/bash/tests/desk-doctree.tst.sh` (header `:32`, insert section `11`
before `:207`). NOT `desk-wsdoc.tst.sh`, NOT `doctree-folder-delete-verb.tst.sh`, NOT
`doctree-move-node-verb.tst.sh`, NOT `csi-spl-utl/`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02
verbatim, 1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head2's
`desk-doctree.tst.sh` on parent: rc 1, 39 pass, 10 fail) RED then GREEN (`0/49/0`) in
the body; hermetic mutations `m2a` (rc 1, 1 fail), `m2b` (rc 1, 2 fail), and `m2c` (rc 1,
1 fail) caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 3 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper consolidation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota or
paused, valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if
the claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`, both pure `csi-spl-orc/` narrow CI) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the 16-line Cloud Run JSON describe preamble across row 01's 2 actions (1.3) | 2 on `3308d118f` (`check-hub-deploy`, `check-hub-image-regress`) -> 1 (hosted once as `_spl_hub_run_describe` in `check-hub-deploy.func.sh`) |
| copies of the desk doc `shlex` arg-splitter and `realpath` input-file guard across row 02's 2 actions (1.4) | 2 each on `3308d118f` (`spl-desk-doctree`, `spl-desk-wsdoc`) -> 1 each (hosted once as `_spl_desk_args_split` and `_spl_desk_in_file` in `spl-desk-doctree.func.sh`) |
| lines (`git diff --numstat` of each head) | row 01: `check-hub-deploy.func.sh` +10 -5, `check-hub-image-regress.func.sh` +4 -16, `check-hub-deploy.tst.sh` +59 -0; row 02: `spl-desk-doctree.func.sh` +37 -23, `spl-desk-wsdoc.func.sh` +8 -32, `desk-doctree.tst.sh` +83 -0 |
| measured on | `3308d118f`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-uplink-probe.func.sh:95,184-194` (`spl_uplink_ms`, `spl_uplink_trim`) and `utl:src/bash/run/external-api-health.func.sh:109,142-152` (`ext_api_ms`, `ext_api_trim`) | byte-for-byte identical 11-line TSV trim and 1-line ms clock (`external-api-health.func.sh:65` already lazy-sources `spl-uplink-probe.func.sh`); shellcheck-clean, non-secret, zero-PG; deferred to `r13` because rulebook 5.1 aims at 2 rows and both r12 rows stay in narrow `csi-spl-orc/` CI without `csi-spl-utl/` `parts=all` cost | `git show 3308d118f:csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh` vs `external-api-health.func.sh`; `shellcheck -S warning -x` rc 0 (n=1) |
| `orc:src/bash/run/spl-peer-restart.func.sh:102-120` (`spl_peer_pids`) and `orc:src/bash/run/spl-rotate-lib.func.sh:832-850` (`spl_rotate_pids`) | identical 19-line `/proc` PID scan differing only in matcher (`spl_peer_harness_comm` vs `spl_rotate_cli`); deferred to `r13` because queued ask `aa377e76` (`c001-s179-b5-paused-seats-free`) names `spl-rotate-lib` (R3) | `git show 3308d118f:csi-spl-orc/src/bash/run/{spl-peer-restart,spl-rotate-lib}.func.sh`; 48h brief grep (n=1) |
| `utl:src/bash/run/` two distinct spool note-sender families (`_utl_send_spool_note` vs `_utl_send_throttled_alert`) | Family A (`reboot-required-check.func.sh`, `r10-02`) and Family B (`clock-sync-check.func.sh`, `r11-02`) have intentionally different contracts; kept separate per r11 W1 | r11 plan section 7 (n=1) |
| Remaining 4 `utl:src/bash/run/` `*_SEND_CMD` actions (`orphan-process-reap.func.sh:141-155`, `gh-runner-health.func.sh:293-306`, `net-cert-expiry-check.func.sh:184-196`, `box-beat-telemetry.func.sh:217-229`) and `systemd-unit-health.func.sh:148-181` + `cloud-sql-backup-verify.func.sh:226-245` | `orphan-process-reap.func.sh:208` still has `SC2071 (error)` and `cloud-sql-backup-verify.func.sh:125` still has `SC2155 (warning)` (cannot touch without mixing in separate lint fixes); `gh-runner-health` is secret-class; `net-cert-expiry-check` and `box-beat-telemetry` have distinct delivery semantics | `shellcheck -S warning -x` on `3308d118f` (n=1) |
| `orc:src/bash/run/net-usb-tether-profiles.func.sh` and `net-wired-priority.func.sh` NM keyfile writer; remaining 3 `is a linked worktree:` sites; `spl-issue-blocker-rca-close` / `spl-issue-owner-question-diss`; secret-class probe / `gcp-*` / `build-push-*` / `spl-lane-handover*` / PG-heavy actions | secret-class exclusion, PG dependency, test-mutation redesign, or distinct semantics | r11 section 7; duplicate-block scan on `3308d118f` (n=1) |
| `iac:src/bash/run/provision-firebase-dns.func.sh` (`do_provision_firebase_dns`, 169 lines — last `LONG` entry in `bash-cleancode.tst.sh`) | reads `$HOME/.gcp/.${ORG}/key-${fb_proj}.json` and mints GCP access tokens for Firebase REST API / Cloud DNS writes (secret-class, excluded) | `git show 3308d118f:csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh:66-80` (n=1) |
| Candidates-file items: 6 refactor-labelled items ALREADY SERVED on `3308d118f` (`reverse-tunnel-cron.sh:27`, `agent-boot-restore` dir, `spl-desk-reply.sh:9,19`, `spl-lane-mix.func.sh`, `i18n-lang-review-exempt.json:2`, `spl-unanswered-sweep.func.sh:196`); remaining open items (`_ppe_keys` line 113, WUI `ci_initial_gzip_kb` headroom line 125, process churn lines 147-148, and all bug/test inputs) | 6 already landed on trunk; remaining open entries are gate-design, perf-shaped, bug-shaped, or test-shaped (not refactor rows) | `/var/spool-hub/dispatch/c002-next-round-candidates.md`; `git grep` on `3308d118f` (1.2 (c), n=1) |
| Spec 011 deferred/owner-decision tasks (`T001`-`T008`, `T018`-`T021`, `T023`, `T025`-`T028`, `T031`, `T034`) | each is wider than one row or awaits an owner decision | `git log 992866d69..3308d118f --oneline -- csi-spl-doc/specs/011-spool-project-refactor` (0 commits; 1.2 (d), n=1) |

## 8. Changes

- v0.1 (a-731): the rows and every read on `3308d118f`; both heads built in scratch
  clones; the 17-suite column of 1.5 run on base and each row's head (all 17 base, 13
  head1, and 13 head2 suites green); `shellcheck 0.10.0 -S warning -x` and
  `do_sec_shellcheck` rc 0; both red controls (`rc1`, `rc2`) and all 6 hermetic mutation
  checks (`m1a`, `m1b`, `m1c`, `m2a`, `m2b`, `m2c`) run in fresh scratch clones and
  verified RED; all helper, caller, and test hunks included verbatim in 1.3 and 1.4.
  Pushed to `review/c002-refactor-round-12-planner` for cross-vendor panel review (`c-999`).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-731 (agy): v0.1.
- Panel reviewer seat: c-999 (claude, `c002-refactor-round-12-claude-panel-seat`): pending
  review and sign-off on v0.1 sha.
- Row R7 seats: section 4; agy per row (claude waiver backup only under ruling `dc84300a`;
  never mistral).
