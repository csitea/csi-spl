# Refactoring round 07 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6579  
Topic: 0fdff584-55f4-4a23-a568-134bd0374be7  
Discussion: 0fdff584-55f4-4a23-a568-134bd0374be7 (t1 #refactoring, "Refactor round 07", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, and **after 99 comes 01, never 00 or 100** (rulebook 5.3), so this round is
  **r07**, plan `refactor-round-07-plan.md` (free: 0 `refactor-round-07` files on
  `origin/master`, so no date suffix; `refactor-round-7*` are from an older single-digit
  cycle), rows `r07-<NN>`, scope `docs(r07-plan, SPL-6579)`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows; mistral sits on no
  review since 2026-11-25 (owner t1 91992830 msgs 65a45673, 591ca574). **Vendor claude
  for every row** (`LANE_MIX_KIND=simple_coding ./run -a do_spl_lane_mix` at 12:50:37Z:
  `pick=claude`, `main=claude`, `backup=agy`).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 06 ([refactor-round-06-plan.md](refactor-round-06-plan.md)
v1.0 `c28e628f2`, editor `a-942`) has both rows landed on `origin/master` with CI green
and ACCEPTED: `r06-01` (`8024dc0b5`, SPL-6575, agy R7 `a-041` PASS) and `r06-02`
(`984b6d70d`, SPL-6577, agy R7 `a-029` PASS); nothing of r06 remains to queue (`a-942`
writes r06's close record). The perf floor (rulebook 4.4), re-measured on `13293131f` at
2026-11-26T12:50:35Z (14 days): perf 36, refactor 117, 23.5%, 5 x 36 = 180 >= 153,
floor-met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), completing the
`cron_refuse_linked_worktree` consolidation started in `r06-02` (`984b6d70d`) across all
**7 remaining non-secret verbatim callers** in `orc:src/bash/run/` (bringing the fleet
from 3/10 to **10/10** non-secret verbatim cron installers sharing
`cron_refuse_linked_worktree` in `orc:lib/bash/funcs/cron-tagged-line.func.sh`, with zero
behaviour change: every log line, exit code, `*_ALLOW_WORKTREE` knob, and `remove`
bypass is byte-identical):
- **Row 01 (wave 2 — box housekeeping and agent-id reap, 4 installers + 1 test = 5 files):**
  `orc:src/bash/run/box-disk-sweep-install-cron.func.sh:30,41-46`,
  `orc:src/bash/run/prune-docker-images-install-cron.func.sh:30,42-47`,
  `orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh:28,41-46`, and
  `orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh:27,33-38` drop their duplicated
  6-line linked-worktree guard and unused `gd cd` locals and call
  `cron_refuse_linked_worktree "$dry" "${<ALLOW_VAR>:-0}" || return 1` on
  `[[ "$act" == install ]]`, guarded by section `8` in
  `orc:src/bash/tests/cron-tagged-line.tst.sh`.
- **Row 02 (wave 3 — OD pool, shadow feed, and cost-labels translate, 3 installers + 1 test = 4 files):**
  `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh:29,33-38`,
  `orc:src/bash/run/spl-shadow-feed-install-cron.func.sh:24,33-38`, and
  `orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh:42,76-81` drop their
  duplicated 6-line linked-worktree guard and unused `gd cd` locals and call
  `cron_refuse_linked_worktree "$dry" "${<ALLOW_VAR>:-0}" || return 1`, guarded by
  section `9` in `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`.
The two rows share no file: both are **Batch 1**.

**Status: v1.0 ready for final panel signature.** Editor: **a-071** (agy).
Cross-vendor claude panel seat: **c-073** (placed 12:54Z; reviewed v0.1 `21c3e6ce3`, seat
commit `10e6f8072`, msg `4159c478`; W1 and N1-N6 folded here, pending final v1.0
signature and `do_spl_review_line_check` rc 0).

**One sha:** every count is measured on **`13293131f`**
(`13293131fbed4e7c3f8ec5c8e689d203546fd4ea`, `origin/master` at 2026-11-26T12:50:08Z),
n=1 per command unless stated. Reads are on `13293131f` with `git show` / `git grep`. The
tests of 1.5 ran in detached scratch worktrees of `13293131f` (not committed, removed on
exit): "base" unmodified, "head1" = base with row 01 applied in 1.3's shape, "head2" =
base with row 02 applied in 1.4's shape; each red control and mutation check (1.5) ran in
a detached worktree of its own. All caller replacements and test hunks are reproduced
verbatim in 1.3 and 1.4 so any panel or R7 seat can reconstruct head1, head2, both red
controls, and all 7 mutation checks byte-for-byte on `13293131f` and verify every sha256.
Queue, lane map, brief, and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-26T12:50:08Z-12:50:39Z, n=1, after a fresh fetch (`git-fetch-fresh.sh`):

- **Window: W=2026-11-26T09:49:33+02:00**, from
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r06-plan'`:
  `c28e628f2a345f674ff363142a059fae21bc5f8c`
  (`docs(r06-plan, SPL-6566): refactor round 06 plan v1.0 (fold W1, record N1-N3; signed by c-917 PASS on badeda0c8)`),
  read once at the start as 5.3 says. Per rulebook 5.3, `W` stays fixed at this recorded
  date (`2026-11-26T09:49:33+02:00`, commit `c28e628f2`); even after `a-942` lands r06's
  close record, all later R4, R6, 2.7.5, and `PRUNE_SINCE` reads for r07 must use
  `W=2026-11-26T09:49:33+02:00`.
- **Perf floor (rulebook 4.4):** `git log origin/master --since='14 days ago' --format=%s | grep -oE '^(test|refactor|ci|fix|feat|perf)\((p[0-9]+|r[0-9]+)-[0-9]{2}-' | sed -E 's/^[a-z]+\(//; s/-$//' | sort -u | awk ...` ->
  `perf 36 refactor 117 perf-share 23.5% floor-met` (5 x 36 = 180 >= 153).
- `git log origin/master --since="$W" --oneline -E --grep='\(r07-' | wc -l` -> **0**.
- `git ls-remote origin 'refs/heads/review/r07-*' 'refs/heads/*-r07-*' 'refs/heads/*refactor-round-07*' 'refs/heads/wip/*r07*'`
  -> nothing (before this plan's review branch push).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r07-[0-9]{2}|refactor-round-07'` (local to
  this planner/holder box only) -> **2** briefs only: this planner's brief
  (`hand-sat-c002-refactor-round-07-planner.md`) and the panel seat's brief
  (`c002-refactor-round-07-claude-panel-seat.md`); 0 `r07-NN` row briefs.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-07`
  -> **0** (`refactor-round-07-plan.md` is free with no date suffix per rulebook 5.3;
  `refactor-round-7*` belong to the earlier single-digit cycle).

### 1.2 The brief's inputs, re-measured

- **(a) r06 section 7:** re-read on `13293131f`:
  - Remaining linked-worktree cron guard callers matching `cron_refuse_linked_worktree`:
    `r06-02` (`984b6d70d`) has now landed on `origin/master`, placing
    `cron_refuse_linked_worktree` in `orc:lib/bash/funcs/cron-tagged-line.func.sh:45-56`.
    `git grep -n "is a linked worktree: install from the main checkout" 13293131f -- csi-spl-orc/src/bash/run/`
    now returns **9** files:
    - 7 clean non-secret verbatim callers that already call `cron_drop_tagged_line`:
      `box-disk-sweep-install-cron.func.sh:44` (54 lines),
      `prune-docker-images-install-cron.func.sh:45` (52 lines),
      `tmp-scratch-sweep-install-cron.func.sh:44` (55 lines),
      `spl-agent-id-reap-install-cron.func.sh:36` (43 lines) -> **row 01** (1.3); and
      `spl-od-pool-supervise-install-cron.func.sh:36` (50 lines),
      `spl-shadow-feed-install-cron.func.sh:36` (43 lines),
      `spl-cost-labels-translate-install-cron.func.sh:79` (109 lines) -> **row 02** (1.4).
    - 2 remaining hits kept out of r07 (section 7):
      `spl-private-overlay-install-cron.func.sh:70` (89 lines; names
      `RESERVE_GH_TOKEN_FILE`, secret-class per brief) and
      `install-box-crons.func.sh:68` (278 lines; WARN at `:69` says `"the paths below"`
      plural rather than `"the path below"`, and it does not call `cron_drop_tagged_line`).
    - Broader scan `git grep -n "is a linked worktree:" 13293131f -- csi-spl-orc/src/bash/run/`
      surfaces 4 additional non-matching files (`spl-agent-hooks-install.func.sh:37,39`,
      `spl-agent-identity-install.func.sh:42,44`, `box-peer-ssh-grant.func.sh:53`,
      `spl-box-deploy.func.sh:151`), each with distinct wording (section 7).
  - All other r06 section 7 items (`brc`/`oq` `*_read` and `*_apply`, non-matching cron
    installers `spl-dispatch-rotate` / `spl-agent-boot-restore` / `spl-box-restart` /
    `spl-peer-crons`, secret-class 5 probe actions and `gcp-*alert*`, PG-heavy
    `spl-msg-{dedup,wipe}` and `spl-channel-agent-*`; `setup-gh-runner-cpu-budget-cron.tst.sh`
    now landed in `b50-02` `86ac09501`) remain accounted for in section 7.
- **(b) R7 notes of r06-01 and r06-02:**
  - `r06-01` (`8024dc0b5`, SPL-6575, agy R7 `a-041` PASS on `fea2e748c`): 0 W; N1 commit
    body cited pre-rebase parent `06bce3642` (verified identical on `984b6d70d`), N2 eager
    `$(id -un)` (planned, zero behaviour change), N3 header comment of
    `spl-spawn-fill.tst.sh:1-40` omits sections 11-12 (cosmetic). No refactor follow-up.
  - `r06-02` (`984b6d70d`, SPL-6577, agy R7 `a-029` PASS msg `78248b83` on `4047a14a0`,
    handoff report `a-029.md`): 0 W, 2 N (all 5 sha256s matched plan 1.4, 14/14 suites
    PASS, `rc2` and `m2a`..`m2d` matched plan 1.5). No blocking follow-up.
- **(c) The dispatcher's candidates file**
  (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, local to this planner/holder
  box only; 151 lines, read 12:49Z):
  - Two new entries since r06: lines 147-148 (other-box process churn from MCP/Playwright
    starts -> perf-shaped, belongs in a perf round) and lines 150-151 (`do_spl_review_go`
    sentence-initial `"Apply"` false hold -> bug-shaped, belongs in a bug round).
  - Re-verified the 3 open refactor-labelled entries from r06 on `13293131f`:
    - line 113 (`_ppe_keys` in `csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh:121`)
      -> still open; gate-design input (not a narrow zero-behaviour-change refactor).
    - line 115 (`csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` still names
      `'Lang-review: a-NNN <msg id>'`) -> still open; 1-line JSON doc comment
      (doc/bug-shaped).
    - line 125 (WUI entry-chunk `ci_initial_gzip_kb` headroom) -> perf-shaped.
  - All 6 previously served refactor entries (lines 1, 25, 48, 76, 104, 133) remain served
    and all other entries are bug, perf, doc, test-hardening, or other-repo items
    (section 7).
- **(d) spec 011 tasks:**
  `git log c28e628f2..13293131f --oneline -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> **0** commits since r06; remaining open/partial tasks (T001-T008 owner-deferred,
  T018-T021, T023, T025-T028, T031, T034) are each wider than one row or await an owner
  decision.

### 1.3 Row 01's site: `cron_refuse_linked_worktree` wave-2 delegation for `box-disk-sweep-install-cron`, `prune-docker-images-install-cron`, `tmp-scratch-sweep-install-cron`, and `spl-agent-id-reap-install-cron`

`orc:` = `csi-spl-orc/`. On `13293131f`:

- Four box-housekeeping / agent-id-reap cron installers in `orc:src/bash/run/` inline the
  exact 6-line linked-worktree guard now hosted once by `cron_refuse_linked_worktree` in
  `orc:lib/bash/funcs/cron-tagged-line.func.sh:45-56` (already loaded by `./run` and
  `in_orc`, and already used by all four for `cron_drop_tagged_line`):
  1. `orc:src/bash/run/box-disk-sweep-install-cron.func.sh:30,41-46` (54 lines; allow knob
     `BOX_SWEEP_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
  2. `orc:src/bash/run/prune-docker-images-install-cron.func.sh:30,42-47` (52 lines; allow
     knob `PRUNE_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
  3. `orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh:28,41-46` (55 lines; allow
     knob `SCRATCH_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
  4. `orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh:27,33-38` (43 lines; allow
     knob `REAP_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
- All four match `cron_refuse_linked_worktree` byte-for-byte on `FATAL`, `WARN`, exit
  codes, and `allow=1` skip (adding `|| true` inside `cron_refuse_linked_worktree:48-49`
  makes the 3 callers that omitted `|| true` strictly safer under `set -e` while identical
  under `set -uo pipefail` and `./run`). None of the four files handles any token,
  credential, or secret (non-secret).
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_box_disk_sweep_install_cron` 28 -> 23 lines;
  `do_prune_docker_images_install_cron` 27 -> 22 lines;
  `do_tmp_scratch_sweep_install_cron` 32 -> 27 lines;
  `do_spl_agent_id_reap_install_cron` 20 -> 15 lines.
  None of the 5 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head1 of 1.5):
- `orc:src/bash/run/box-disk-sweep-install-cron.func.sh`: drop unused `gd cd` from `local`
  at `:30`; replace `:41-46` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
  "$dry" "${BOX_SWEEP_ALLOW_WORKTREE:-0}" || return 1; }`. 54 -> 49 lines (`+2 -7`).
- `orc:src/bash/run/prune-docker-images-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:30`; replace `:42-47` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${PRUNE_ALLOW_WORKTREE:-0}" || return 1; }`.
  52 -> 47 lines (`+2 -7`).
- `orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:28`; replace `:41-46` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${SCRATCH_ALLOW_WORKTREE:-0}" || return 1; }`.
  55 -> 50 lines (`+2 -7`).
- `orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:27`; replace `:33-38` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${REAP_ALLOW_WORKTREE:-0}" || return 1; }`.
  43 -> 38 lines (`+2 -7`).
- `orc:src/bash/tests/cron-tagged-line.tst.sh`: insert section `8` immediately before
  `[ "$fails" -eq 0 ]` at `:123` (line `:122` is already blank, so inserting 43 lines + 1
  trailing blank line adds 44 lines): 4 wave-2 one-copy checks and 6 standalone installer
  linked-worktree checks (`box-disk-sweep` `DRY_RUN=0`, `DRY_RUN=1`, and `remove` bypass;
  `prune-docker-images` `DRY_RUN=0`; `tmp-scratch-sweep` `DRY_RUN=0`;
  `spl-agent-id-reap` `DRY_RUN=0`, reusing section 7's `$T/wt-linked` fixture).
  123 -> 167 lines (`+44 -0`). Total edited files: **5** (within rulebook 3.1's max 5;
  `cron-tagged-line.func.sh` is untouched).
- head1's files, sha256 (12 chars): `box-disk-sweep-install-cron.func.sh` `bad65d0ead26`,
  `prune-docker-images-install-cron.func.sh` `e606ca00b683`,
  `tmp-scratch-sweep-install-cron.func.sh` `21909802651d`,
  `spl-agent-id-reap-install-cron.func.sh` `ab9a944d995e`,
  `cron-tagged-line.tst.sh` `7fb8a154c186`.

Verbatim caller and test hunks (head1 on `13293131f`):

`orc:src/bash/run/box-disk-sweep-install-cron.func.sh` (drop `gd cd` from `local` at `:30`;
replace `:41-46`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${BOX_SWEEP_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/run/prune-docker-images-install-cron.func.sh` (drop `gd cd` from `local` at
`:30`; replace `:42-47`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${PRUNE_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh` (drop `gd cd` from `local` at
`:28`; replace `:41-46`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${SCRATCH_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh` (drop `gd cd` from `local` at
`:27`; replace `:33-38`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${REAP_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/tests/cron-tagged-line.tst.sh` section `8` (inserted immediately before
`[ "$fails" -eq 0 ]` at `:123`, followed by one blank line; `:122` is already blank):
```bash
# 8. cron_refuse_linked_worktree wave-2 delegation (r07-01 one copy)
for sib in \
  "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/prune-docker-images-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/tmp-scratch-sweep-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-id-reap-install-cron.func.sh"; do
  own="$(grep -nE 'is a linked worktree: install from the main checkout|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "8. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "8. one copy $(basename "$sib"): own=[$own]"
done

# standalone wave-2 installer linked-worktree checks (dry=0 refuses, dry=1 warns, remove skips)
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. box-disk-sweep refuses a linked worktree when DRY_RUN=0" || fail "8. box-disk-sweep dry=0 ($rc: $out)"
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "8. box-disk-sweep warns on a linked worktree when DRY_RUN=1" || fail "8. box-disk-sweep dry=1 ($rc: $out)"
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" BOX_SWEEP_CRON_ACTION=remove DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'linked worktree' <<<"$out" \
  && pass "8. box-disk-sweep remove skips worktree refusal" || fail "8. box-disk-sweep remove ($rc: $out)"
out="$(env -u PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" PRUNE_CRONTAB="$T/fake-crontab" PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_prune_docker_images_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/prune-docker-images-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. prune-docker-images refuses a linked worktree when DRY_RUN=0" || fail "8. prune-docker-images dry=0 ($rc: $out)"
out="$(env -u SCRATCH_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_AGENT_USER="$(id -un)" SCRATCH_CRONTAB="$T/fake-crontab" SCRATCH_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_tmp_scratch_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/tmp-scratch-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. tmp-scratch-sweep refuses a linked worktree when DRY_RUN=0" || fail "8. tmp-scratch-sweep dry=0 ($rc: $out)"
out="$(env -u REAP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/spool" REAP_CRONTAB="$T/fake-crontab" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_spl_agent_id_reap_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-agent-id-reap-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. spl-agent-id-reap refuses a linked worktree when DRY_RUN=0" || fail "8. spl-agent-id-reap dry=0 ($rc: $out)"
```

**Behaviour:** zero behaviour change. All four wave-2 installers emit their exact
linked-worktree `FATAL` (`DRY_RUN=0`) and `WARN` (`DRY_RUN=1`) messages, keep `remove`
bypassing the guard, and respect `*_ALLOW_WORKTREE=1` (all 6 standalone installer checks
pass on unmodified `base` too).

### 1.4 Row 02's site: `cron_refuse_linked_worktree` wave-3 delegation for `spl-od-pool-supervise-install-cron`, `spl-shadow-feed-install-cron`, and `spl-cost-labels-translate-install-cron` (completing 10/10)

`orc:` = `csi-spl-orc/`. On `13293131f`:

- The last three non-secret verbatim linked-worktree cron guard callers in
  `orc:src/bash/run/` also already call `cron_drop_tagged_line` from
  `orc:lib/bash/funcs/cron-tagged-line.func.sh`:
  1. `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh:29,33-38` (50 lines;
     allow knob `OD_CRON_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
  2. `orc:src/bash/run/spl-shadow-feed-install-cron.func.sh:24,33-38` (43 lines; allow
     knob `SHADOW_FEED_ALLOW_WORKTREE:-0`, guarded on `$act == install`).
  3. `orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh:42,76-81` (109
     lines; allow knob `COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0`, already inside
     `if [[ "$act" == install ]]; then` at `:75`).
- None of the three files handles any token, credential, or secret (non-secret). Placing
  row 02's tests in `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`
  (section `9`, with its own fixture `git worktree add` so linked-worktree refusal is
  tested deterministically on main checkouts and CI exports as well as linked worktrees)
  keeps rows 01 and 02 100% file-disjoint for Batch 1.
- Line-cap check (`bash-cleancode.tst.sh`, cap 75):
  `do_spl_od_pool_supervise_install_cron` 25 -> 20 lines;
  `do_spl_shadow_feed_install_cron` 23 -> 18 lines;
  `do_spl_cost_labels_translate_install_cron` 60 -> 55 lines;
  `spl_cost_labels_translate_cron_schedule` 7 lines (unchanged).
  None of the 4 edited files has any entry in `.shellcheck-warning-baseline.txt`,
  `no-literal-paths.baseline`, `action-header-tags-baseline.txt`, or
  `param-required-baseline.txt`.

Shape (built as head2 of 1.5):
- `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:29`; replace `:33-38` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${OD_CRON_ALLOW_WORKTREE:-0}" || return 1; }`.
  50 -> 45 lines (`+2 -7`).
- `orc:src/bash/run/spl-shadow-feed-install-cron.func.sh`: drop unused `gd cd` from
  `local` at `:24`; replace `:33-38` with `[[ "$act" == install ]] && {
  cron_refuse_linked_worktree "$dry" "${SHADOW_FEED_ALLOW_WORKTREE:-0}" || return 1; }`.
  43 -> 38 lines (`+2 -7`).
- `orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh`: drop unused `gd cd`
  from `local` at `:42`; replace `:76-81` with `    cron_refuse_linked_worktree "$dry"
  "${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}" || return 1`. 109 -> 104 lines (`+2 -7`).
- `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`: insert section `9`
  immediately before `echo "spl-cost-labels-translate-install-cron: ${fails} failure(s)"`
  at `:160` (line `:159` is already blank, so inserting 39 lines + 1 trailing blank line
  adds 40 lines): 3 wave-3 one-copy checks and 5 fixture-worktree standalone installer
  linked-worktree checks (`od-pool-supervise` `DRY_RUN=0`/`DRY_RUN=1`, `shadow-feed`
  `DRY_RUN=0`, `cost-labels-translate` `DRY_RUN=0`/`DRY_RUN=1`). 161 -> 201 lines
  (`+40 -0`). Total edited files: **4** (within rulebook 3.1's max 5;
  `cron-tagged-line.func.sh` and `cron-tagged-line.tst.sh` are untouched).
- head2's files, sha256 (12 chars): `spl-od-pool-supervise-install-cron.func.sh`
  `1e79cd6fde5e`, `spl-shadow-feed-install-cron.func.sh` `3eeef539533d`,
  `spl-cost-labels-translate-install-cron.func.sh` `c9fb79e3b2fb`,
  `spl-cost-labels-translate-install-cron.tst.sh` `6b7526acd24c`.

Verbatim caller and test hunks (head2 on `13293131f`):

`orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh` (drop `gd cd` from `local`
at `:29`; replace `:33-38`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${OD_CRON_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/run/spl-shadow-feed-install-cron.func.sh` (drop `gd cd` from `local` at
`:24`; replace `:33-38`):
```bash
  [[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${SHADOW_FEED_ALLOW_WORKTREE:-0}" || return 1; }
```

`orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh` (drop `gd cd` from
`local` at `:42`; replace `:76-81`):
```bash
    cron_refuse_linked_worktree "$dry" "${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}" || return 1
```

`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh` section `9` (inserted
immediately before `echo "spl-cost-labels-translate-install-cron: ${fails} failure(s)"`
at `:160`, followed by one blank line; `:159` is already blank):
```bash
# 9. cron_refuse_linked_worktree wave-3 delegation (r07-02 one copy)
for sib in \
  "$PROJ_ROOT/src/bash/run/spl-od-pool-supervise-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-shadow-feed-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-cost-labels-translate-install-cron.func.sh"; do
  own="$(grep -nE 'is a linked worktree: install from the main checkout|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "9. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "9. one copy $(basename "$sib"): own=[$own]"
done

git init -q -b master "$T/wt-main" && git -C "$T/wt-main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T/wt-main" worktree add -q --detach "$T/wt-linked"
mkdir -p "$T/wt-linked/csi-spl-orc" "$T/wt-spool"
out="$(env -u OD_CRON_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-spool" OD_CRONTAB="$T/fake-crontab" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_spl_od_pool_supervise_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-od-pool-supervise-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-od-pool-supervise refuses a linked worktree when DRY_RUN=0" || fail "9. od-pool dry=0 ($rc: $out)"
out="$(env -u OD_CRON_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-spool" OD_CRONTAB="$T/fake-crontab" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_spl_od_pool_supervise_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-od-pool-supervise-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-od-pool-supervise warns on a linked worktree when DRY_RUN=1" || fail "9. od-pool dry=1 ($rc: $out)"
out="$(env -u SHADOW_FEED_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SHADOW_FEED_CRONTAB="$T/fake-crontab" SHADOW_FEED_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_spl_shadow_feed_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-shadow-feed-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-shadow-feed refuses a linked worktree when DRY_RUN=0" || fail "9. shadow-feed dry=0 ($rc: $out)"
out="$(env -u COST_LABELS_TRANSLATE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" ENV=dev SPOOL_AGENT_USER="$(id -un)" COST_LABELS_TRANSLATE_SUDO=false COST_LABELS_TRANSLATE_CRON_SCHEDULE="0 3 * * *" COST_LABELS_TRANSLATE_CRONTAB="$T/fake-crontab" COST_LABELS_TRANSLATE_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; source "$3"; do_spl_cost_labels_translate_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-cost-labels-translate-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-cost-labels-translate refuses a linked worktree when DRY_RUN=0" || fail "9. cost-labels dry=0 ($rc: $out)"
out="$(env -u COST_LABELS_TRANSLATE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" ENV=dev SPOOL_AGENT_USER="$(id -un)" COST_LABELS_TRANSLATE_SUDO=false COST_LABELS_TRANSLATE_CRON_SCHEDULE="0 3 * * *" COST_LABELS_TRANSLATE_CRONTAB="$T/fake-crontab" COST_LABELS_TRANSLATE_CRON_LOG_DIR="$T/log" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; source "$3"; do_spl_cost_labels_translate_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-cost-labels-translate-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-cost-labels-translate warns on a linked worktree when DRY_RUN=1" || fail "9. cost-labels dry=1 ($rc: $out)"
```

**Behaviour:** zero behaviour change. All three wave-3 installers emit their exact
linked-worktree `FATAL` (`DRY_RUN=0`) and `WARN` (`DRY_RUN=1`) messages and exit codes,
and respect `*_ALLOW_WORKTREE=1` (all 5 standalone installer checks pass on unmodified
`base` too).

### 1.5 Before and on the rows' heads

2026-11-26T12:56Z-13:11Z, n=1, as the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset and stdin from `/dev/null`; pass lines `grep -ciE '^ *(ok|pass)'`,
fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means equal to base: same rc, pass and
fail counts; "-" means that row's head does not touch the suite's tree.

| suite | row | base rc / pass / fail | head1 | head2 |
|---|---|---|---|---|
| `orc:src/bash/tests/cron-tagged-line.tst.sh` | 01, 02 | 0 / 21 / 0 | 0 / 31 / 0 (+10 new checks) | = |
| `orc:src/bash/tests/box-disk-sweep.tst.sh` | 01 | 0 / 96 / 0 | = | - |
| `orc:src/bash/tests/prune-docker-images.tst.sh` | 01 | 0 / 50 / 0 | = | - |
| `orc:src/bash/tests/tmp-scratch-sweep.tst.sh` | 01 | 0 / 35 / 0 | = | - |
| `orc:src/bash/tests/agent-id-reap.tst.sh` | 01 | 0 / 14 / 0 | = | - |
| `orc:src/bash/tests/run-log-sweep.tst.sh` | 01 | 0 / 16 / 0 | = | - |
| `orc:src/bash/tests/spl-box-deploy.tst.sh` | 01 | 0 / 36 / 0 | = | - |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 01 | 0 / 96 / 0 | = | - |
| `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh` | 02 | 0 / 21 / 0 | - | 0 / 29 / 0 (+8 new checks) |
| `orc:src/bash/tests/od-pool-replace.tst.sh` | 02 | 0 / 9 / 0 | - | = |
| `orc:src/bash/tests/spl-shadow-feed.tst.sh` | 02 | 0 / 25 / 0 | - | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 01, 02 | 0 / 10 / 0 | = | = |
| `iac:src/bash/tests/action-header-tags.tst.sh` | 01, 02 | 0 / 6 / 0 | = | = |
| `iac:src/bash/tests/param-required.tst.sh` | 01, 02 | 0 / 17 / 0 | = | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = | = |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = | = |
| `iac:src/bash/tests/gcloud-account-pinned.tst.sh` | 01, 02 | 0 / 48 / 0 | = | = |

Note (\*): on mutation checks `m1a`-`m1d` and `m2a`-`m2c`, multi-line `$out` dumped inside
a `FAIL:` message includes raw `OK ...` log lines on their own lines, which
`grep -ciE '^ *(ok|pass)'` counts alongside real `PASS:` checks (broken down per mutation
below). Run every suite and control in a git worktree (not a plain `git archive` export):
outside a git tree, `no-literal-paths.tst.sh` reads `STALE` on base and heads alike.

`shellcheck 0.10.0 -S warning -x` on all 9 edited files (head1: 5 files, head2: 4 files):
**rc 0**, no findings (n=1 each). `do_sec_shellcheck` with newline-separated
`SEC_SHELLCHECK_FILES` set to each row's touched files: **rc 0**,
`no error-level findings`, `no new findings (baseline holds)` (n=1 each).

**Red controls** (n=1 each, each in its own detached worktree of `13293131f`,
reconstructed from the verbatim blocks in 1.3 and 1.4):
- Row 01 red control (`rc1`, head1's `cron-tagged-line.tst.sh` on base): rc 1, 27 pass
  (21 base + all 6 standalone wave-2 installer checks passing on base, proving
  equivalence), 4 fail (4 `FAIL:` one-copy checks naming `:42`/`:44` in
  `box-disk-sweep-install-cron`, `:43`/`:45` in `prune-docker-images-install-cron`,
  `:42`/`:44` in `tmp-scratch-sweep-install-cron`, and `:34`/`:36` in
  `spl-agent-id-reap-install-cron`); head1: rc 0, 31 pass, 0 fail.
- Row 02 red control (`rc2`, head2's `spl-cost-labels-translate-install-cron.tst.sh` on
  base): rc 1, 26 pass (21 base + all 5 standalone wave-3 installer checks passing on
  base, proving equivalence), 3 fail (3 `FAIL:` one-copy checks naming `:34`/`:36` in
  `spl-od-pool-supervise-install-cron`, `:34`/`:36` in `spl-shadow-feed-install-cron`,
  and `:77`/`:79` in `spl-cost-labels-translate-install-cron`); head2: rc 0, 29 pass,
  0 fail.

**Mutation checks** (n=1 each, detached worktrees of `13293131f` with head1/head2
applied, then one installer's allow arg replaced with `"1"`):
- `m1a` (`box-disk-sweep-install-cron.func.sh` passes `"1"` instead of
  `"${BOX_SWEEP_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 30 `ok|pass` lines
  (29 real `PASS:` + 1 dumped `OK` line), 2 fail (`FAIL: 8. box-disk-sweep dry=0`,
  `FAIL: 8. box-disk-sweep dry=1`).
- `m1b` (`prune-docker-images-install-cron.func.sh` passes `"1"` instead of
  `"${PRUNE_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 31 `ok|pass` lines
  (30 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 8. prune-docker-images dry=0`).
- `m1c` (`tmp-scratch-sweep-install-cron.func.sh` passes `"1"` instead of
  `"${SCRATCH_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 31 `ok|pass` lines
  (30 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 8. tmp-scratch-sweep dry=0`).
- `m1d` (`spl-agent-id-reap-install-cron.func.sh` passes `"1"` instead of
  `"${REAP_ALLOW_WORKTREE:-0}"`): `cron-tagged-line.tst.sh` rc 1, 31 `ok|pass` lines
  (30 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 8. spl-agent-id-reap dry=0`).
- `m2a` (`spl-od-pool-supervise-install-cron.func.sh` passes `"1"` instead of
  `"${OD_CRON_ALLOW_WORKTREE:-0}"`): `spl-cost-labels-translate-install-cron.tst.sh` rc 1,
  31 `ok|pass` lines (27 real `PASS:` + 4 dumped `OK` lines), 2 fail (`FAIL: 9. od-pool
  dry=0`, `FAIL: 9. od-pool dry=1`).
- `m2b` (`spl-shadow-feed-install-cron.func.sh` passes `"1"` instead of
  `"${SHADOW_FEED_ALLOW_WORKTREE:-0}"`): `spl-cost-labels-translate-install-cron.tst.sh`
  rc 1, 29 `ok|pass` lines (28 real `PASS:` + 1 dumped `OK` line), 1 fail (`FAIL: 9.
  shadow-feed dry=0`).
- `m2c` (`spl-cost-labels-translate-install-cron.func.sh` passes `"1"` instead of
  `"${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}"`):
  `spl-cost-labels-translate-install-cron.tst.sh` rc 1, 29 `ok|pass` lines (26 real
  `PASS:` + 3 dumped `OK` lines), 3 fail in a linked worktree (`FAIL: 6. worktree`,
  `FAIL: 9. cost-labels dry=0`, `FAIL: 9. cost-labels dry=1`; 2 fail on a main checkout
  where section 6 skips `:100`).

The tests that name the sites (R2): `git grep -lE` over `*tst.sh`, `features/*/tests/*`,
`csi-spl-iac/src/bash/tests/`, and `csi-spl-api/` on `13293131f`:
- Row 01 (`box-disk-sweep-install-cron|do_box_disk_sweep_install_cron|prune-docker-images-install-cron|do_prune_docker_images_install_cron|tmp-scratch-sweep-install-cron|do_tmp_scratch_sweep_install_cron|spl-agent-id-reap-install-cron|do_spl_agent_id_reap_install_cron`) ->
  `orc:src/bash/tests/box-disk-sweep.tst.sh`, `orc:src/bash/tests/prune-docker-images.tst.sh`,
  `orc:src/bash/tests/tmp-scratch-sweep.tst.sh`, `orc:src/bash/tests/agent-id-reap.tst.sh`,
  `orc:src/bash/tests/run-log-sweep.tst.sh` (`:89` calls `do_box_disk_sweep_install_cron`),
  `orc:src/bash/tests/spl-box-deploy.tst.sh` (`:60` names `do_spl_agent_id_reap_install_cron`,
  included per R2; measured 13:33Z-13:36Z on `13293131f` base and head1: `0 / 36 / 0`),
  and **`iac:src/bash/tests/satellite-ansible.tst.sh`** (`:458` greps
  `tag="csi-spl:tmp-scratch-sweep"` in `tmp-scratch-sweep-install-cron.func.sh`), plus the
  edited **`orc:src/bash/tests/cron-tagged-line.tst.sh`** (0 hits in `csi-spl-api/`).
- Row 02 (`spl-od-pool-supervise-install-cron|do_spl_od_pool_supervise_install_cron|spl-shadow-feed-install-cron|do_spl_shadow_feed_install_cron|spl-cost-labels-translate-install-cron|do_spl_cost_labels_translate_install_cron`) ->
  **`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`** (edited),
  `orc:src/bash/tests/od-pool-replace.tst.sh`, and
  `orc:src/bash/tests/spl-shadow-feed.tst.sh`, plus `orc:src/bash/tests/cron-tagged-line.tst.sh`
  (helper suite; 0 hits in `csi-spl-iac/` or `csi-spl-api/`).
- 30-char non-header comment grep across all 7 `.func.sh` files (+/- 3 lines of each
  guard): 0 inline comments at the guard sites (only header `@description`/`@param`
  comments and `:85`/`:101-102` in `spl-cost-labels-translate-install-cron.func.sh`, all
  untouched). No new test file is added, so `orc-shard-weights.txt` needs no line.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r07-01-orc-cron-worktree-guard-wave2)` | one fact, one copy (developer guide 2.2.4) | `box-disk-sweep-install-cron.func.sh:41-46`, `prune-docker-images-install-cron.func.sh:42-47`, `tmp-scratch-sweep-install-cron.func.sh:41-46`, and `spl-agent-id-reap-install-cron.func.sh:33-38` duplicate the exact 6-line linked-worktree refusal/warning guard now hosted in `cron_refuse_linked_worktree` (`orc:lib/bash/funcs/cron-tagged-line.func.sh:45-56`, landed in `r06-02` `984b6d70d`), while all four already call `cron_drop_tagged_line` (1.3, r06 section 7 #1) | `orc:src/bash/run/box-disk-sweep-install-cron.func.sh:30,41-46`<br>`orc:src/bash/run/prune-docker-images-install-cron.func.sh:30,42-47`<br>`orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh:28,41-46`<br>`orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh:27,33-38`<br>`orc:src/bash/tests/cron-tagged-line.tst.sh:123` | copies of the linked-worktree cron guard across these 4 wave-2 installers 4 -> 0 (delegating to `cron_refuse_linked_worktree`; 7/10 non-secret verbatim cron installers consolidated) | 1.3's shape (verbatim blocks in 1.3). **Red control:** head1's `cron-tagged-line.tst.sh` on parent FAILs 4 checks (`rc1`, rc 1, 27 pass, 4 fail: 4 one-copy checks naming `:42`/`:44`, `:43`/`:45`, `:42`/`:44`, `:34`/`:36`; all 6 standalone installer checks pass on base), then GREEN (`0/31/0`); mutations `m1a` (`box-disk-sweep` `allow=1`, rc 1 `30*/2`), `m1b` (`prune-docker-images` `allow=1`, rc 1 `31*/1`), `m1c` (`tmp-scratch-sweep` `allow=1`, rc 1 `31*/1`), and `m1d` (`spl-agent-id-reap` `allow=1`, rc 1 `31*/1`) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 10 new checks in `cron-tagged-line.tst.sh`. Tests: **`orc:.../cron-tagged-line.tst.sh`**, `orc:.../box-disk-sweep.tst.sh`, `orc:.../prune-docker-images.tst.sh`, `orc:.../tmp-scratch-sweep.tst.sh`, `orc:.../agent-id-reap.tst.sh`, `orc:.../run-log-sweep.tst.sh`, `orc:.../spl-box-deploy.tst.sh`, **`iac:.../satellite-ansible.tst.sh`**, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 5 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r07-02-orc-cron-worktree-guard-wave3)` | one fact, one copy (developer guide 2.2.4) | `spl-od-pool-supervise-install-cron.func.sh:33-38`, `spl-shadow-feed-install-cron.func.sh:33-38`, and `spl-cost-labels-translate-install-cron.func.sh:76-81` are the last 3 non-secret verbatim copies of the 6-line linked-worktree refusal/warning guard in `orc:src/bash/run/`, while all three already call `cron_drop_tagged_line` from `cron-tagged-line.func.sh` (1.4, r06 section 7 #1) | `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh:29,33-38`<br>`orc:src/bash/run/spl-shadow-feed-install-cron.func.sh:24,33-38`<br>`orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh:42,76-81`<br>`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh:160` | copies of the linked-worktree cron guard across these 3 wave-3 installers 3 -> 0 (delegating to `cron_refuse_linked_worktree`; completes 10/10 non-secret verbatim cron installers consolidated) | 1.4's shape (verbatim blocks in 1.4). **Red control:** head2's `spl-cost-labels-translate-install-cron.tst.sh` on parent FAILs 3 checks (`rc2`, rc 1, 26 pass, 3 fail: 3 one-copy checks naming `:34`/`:36`, `:34`/`:36`, `:77`/`:79`; all 5 standalone installer checks pass on base), then GREEN (`0/29/0`); mutations `m2a` (`od-pool-supervise` `allow=1`, rc 1 `31*/2`), `m2b` (`shadow-feed` `allow=1`, rc 1 `29*/1`), and `m2c` (`cost-labels-translate` `allow=1`, rc 1 `29*/3` in linked worktree) caught (1.5); outputs in the body. **Behaviour:** zero behaviour change; column passes on parent and head with identical counts plus 8 new checks in `spl-cost-labels-translate-install-cron.tst.sh`. Tests: **`orc:.../spl-cost-labels-translate-install-cron.tst.sh`**, `orc:.../od-pool-replace.tst.sh`, `orc:.../spl-shadow-feed.tst.sh`, `orc:.../cron-tagged-line.tst.sh`, `orc:.../run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `action-header-tags.tst.sh`, `param-required.tst.sh`, `run-lazy-loader.tst.sh`, `bash-cleancode.tst.sh`, `gcloud-account-pinned.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

`iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`.

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the guard lines and `gd cd` locals) on the `origin/master` it starts from, and says in
its result if the sites or counts moved.

**Subject** (R6 reads it): `<type>(r07-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r07-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** both rows delegate duplicated internal crontab-installer linked-worktree guards
to the existing `cron_refuse_linked_worktree` helper with zero change to any output, exit
code, env var, path, or file a caller sees (1.3, 1.4, 1.5) ->
`Docs: none (internal helper delegation; no behaviour changes)` (both rows). The
developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their edited file sets are completely disjoint
  (row 01: `box-disk-sweep-install-cron.func.sh`, `prune-docker-images-install-cron.func.sh`,
  `tmp-scratch-sweep-install-cron.func.sh`, `spl-agent-id-reap-install-cron.func.sh`,
  `cron-tagged-line.tst.sh`; row 02: `spl-od-pool-supervise-install-cron.func.sh`,
  `spl-shadow-feed-install-cron.func.sh`, `spl-cost-labels-translate-install-cron.func.sh`,
  `spl-cost-labels-translate-install-cron.tst.sh`).
- Neither row edits `orc:lib/bash/funcs/cron-tagged-line.func.sh`,
  `orc:src/bash/run/install-box-crons.func.sh`,
  `orc:src/bash/run/spl-private-overlay-install-cron.func.sh`,
  `orc:src/bash/run/spl-agent-hooks-install.func.sh`,
  `orc:src/bash/run/spl-agent-identity-install.func.sh`,
  `orc:src/bash/run/spl-review-go.func.sh`, `orc:src/bash/tests/spl-review-go.tst.sh`,
  `orc:src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`,
  `orc:src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh` (all in `b51`),
  `.shellcheck-warning-baseline.txt`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/`, `csi-spl-iac/`, `csi-spl-utl/`, or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (9 edited + 8 sibling regression-run / helper files = 17 checked;
`spl-box-deploy.tst.sh` added per panel W1 and checked separately at 13:33:27Z):
`orc:src/bash/run/box-disk-sweep-install-cron.func.sh`,
`orc:src/bash/run/prune-docker-images-install-cron.func.sh`,
`orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh`,
`orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh`,
`orc:src/bash/tests/cron-tagged-line.tst.sh`,
`orc:src/bash/tests/box-disk-sweep.tst.sh`,
`orc:src/bash/tests/prune-docker-images.tst.sh`,
`orc:src/bash/tests/tmp-scratch-sweep.tst.sh`,
`orc:src/bash/tests/agent-id-reap.tst.sh`,
`orc:src/bash/tests/spl-box-deploy.tst.sh`;
`orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh`,
`orc:src/bash/run/spl-shadow-feed-install-cron.func.sh`,
`orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh`,
`orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh`,
`orc:src/bash/tests/od-pool-replace.tst.sh`,
`orc:src/bash/tests/spl-shadow-feed.tst.sh`,
`orc:lib/bash/funcs/cron-tagged-line.func.sh`.

- **Lane map, every machine:** `lane-map.sh --check <all 16 paths> --agent a-071`, n=1, at
  2026-11-26T12:53:03Z: **exit 4** ("no live lane lists <the 16 paths>, but 20 live lane(s)
  record no files", 0 owned). All 20 `unknown:` live lanes are on the other box (14
  channel/workspace/other-repo seats `c-029`, `c-041`, `c-086`, `c-146`, `c-187`, `c-407`,
  `c-416`, `c-474`, `c-535`, `c-728`, `c-927`, `c-935`, `c-936`, `c-971`, plus `c-065`
  WUI Shift+L/Shift+C, `c-068` WUI loops dialog, `c-904` s187 S1 rdb+store, `c-907` s196
  T1 topic tags store, and `c-957`/`c-965` spec 125 doc/R7 seats). Verified via
  `do_spl_lane_map` at 12:50:58Z — live lanes on this box (`a-071`, `a-942` r06 close,
  `a-068` SPL-6590 WUI R7, `a-008` / `c-973` s186 M12 WUI, `a-006` s196 T1 R7, `c-060`
  WUI multi-file drop, `a-934` s182 planner, `a-056` / `c-936` s186 M2 hub, `a-048` /
  `c-052` b51 planner/panel) touch none of the 16 paths. At 13:33:27Z
  `lane-map.sh --check csi-spl-orc/src/bash/tests/spl-box-deploy.tst.sh --agent a-071`
  also returned **exit 4** (0 owned, 20 `unknown:` all on the other box; `c-079` in,
  `c-935` out). No live lane owns any of the 17 paths; the holder re-reads at placement
  per R3.
- **Bug round 51 beside us:** read `origin/review/c002-bug-round-51-planner` (`d065eb53b`)
  at 12:52:55Z: its 3 rows edit `y9-vendor-lane-rule.sh` + `test-agy-qwen-fleet-rules.sh`,
  `apply-gh-runner-cpu-budget.tst.sh`, and `spl-review-go.func.sh` + `spl-review-go.tst.sh`
  -> **0 overlap** with our 16 paths.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, at 2026-11-26T12:51:02Z):
  14 queued, 0 placing (`5b1b7d82` s186 M9 Qto sync, `8050c5fe` s153 Q3, `87dc6733` s153
  Q8, `617780a1` this round's claude panel seat — since placed as `c-073` at 12:54Z,
  `49357202` / `e43a7b02` other-repo heartbeat/loop, `e1b5cc30` / `646c3169` s185 build
  planner/panel, `5a432cc3` Qto PDF export, `8ccf6c03` SPL-5883 store tags, `6929f8d4`
  SPL-5309 costs share, `0bac0950` / `a2f1f200` / `f7985ac2` s039 T017a/d/e). None touches
  any of the 16 paths.
- **Unlanded rows from r06:** **0** (`r06-01` landed `8024dc0b5`, `r06-02` landed
  `984b6d70d`).
- **Briefs on this box** modified in the last 24 h matching any of the 7 `.func.sh` paths
  (at 12:54Z): only the already-landed `c002-r06-02-orc-cron-worktree-guard-wave1.md` (which
  listed them in its NOT list); **0 live briefs**.
- **Remote branches committed in the last 24 h** (`git for-each-ref`, at 12:54Z):
  `git diff --name-only $(git merge-base 13293131f <b>) <b> -- <the 16 paths>` -> only
  `origin/review/r06-02` (already landed as `984b6d70d`); **0 unlanded branches**.
- **Commits in the last 24 h** on the 16 paths (`git log 13293131f --since='24 hours ago'`,
  at 12:53Z) -> 1 landed commit (`984b6d70d` r06-02); 0 unlanded churn.

## 3. Per row: what the lane does

- **r07-01:** `orc:src/bash/run/box-disk-sweep-install-cron.func.sh`,
  `orc:src/bash/run/prune-docker-images-install-cron.func.sh`,
  `orc:src/bash/run/tmp-scratch-sweep-install-cron.func.sh`, and
  `orc:src/bash/run/spl-agent-id-reap-install-cron.func.sh` each drop unused `gd cd` from
  `local` and replace their inline 6-line linked-worktree guard with
  `[[ "$act" == install ]] && { cron_refuse_linked_worktree "$dry" "${<ALLOW_VAR>:-0}" || return 1; }`.
  `orc:src/bash/tests/cron-tagged-line.tst.sh` inserts section `8` before `:123` (4 wave-2
  one-copy checks and 6 standalone installer linked-worktree checks).
- **r07-02:** `orc:src/bash/run/spl-od-pool-supervise-install-cron.func.sh`,
  `orc:src/bash/run/spl-shadow-feed-install-cron.func.sh`, and
  `orc:src/bash/run/spl-cost-labels-translate-install-cron.func.sh` each drop unused
  `gd cd` from `local` and replace their inline 6-line linked-worktree guard with a call
  to `cron_refuse_linked_worktree "$dry" "${<ALLOW_VAR>:-0}" || return 1` (guarded on
  `[[ "$act" == install ]]` in the first two; already inside `if [[ "$act" == install ]];
  then` at `:75` in the third).
  `orc:src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh` inserts section `9`
  before `:160` (3 wave-3 one-copy checks and 5 fixture-worktree standalone installer
  linked-worktree checks).

## 4. Panel and reviewers (R7)

- Editor: **a-071** (agy). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat (rulebook 3.2; brief step 5; mistral sits
  on no review since 2026-11-25): claude panel seat **c-073** (placed 12:54Z on this box).
  Reviewed v0.1 (`21c3e6ce33a51d9a803543c87c6bbb2a9bc0b748`, seat commit `10e6f8072`, msg
  `4159c478`; W1 and N1-N6 folded in v1.0; pending final v1.0 signature and
  `do_spl_review_line_check` rc 0). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  - Checked `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-26T12:52:03Z ->
    `pick=hold` (`grok weekly >= 95% or unknown on both boxes`; `do_spl_lane_mix` also
    reports `grok off in instance settings`, `qwen off in instance settings`).
  - Per the 2026-11-24T15:52:44Z ruling (`c-001` msg `dc84300a`, re owner `c8ae22e5` in
    t1 `2d0270fe`, post `4e432858`) and `LANE_MIX_KIND=code_review ./run -a do_spl_lane_mix`
    at 12:52:24Z (`pick=agy`, `main=agy`, `backup=claude`; mistral sits on no review), R7
    review of a claude coding row goes to an **agy seat** per row (claude waiver backup
    only while agy is out of quota, citing ruling `dc84300a`; never mistral).
    `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` at 12:52:35Z picked an available box
    (this box, 141% < 180% overflow, `agy weekly unknown`, placed anyway); the holder
    re-checks agy capacity at row placement and uses the claude waiver backup only if agy
    is out of quota.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r07-01 | `c002-r07-01-orc-cron-worktree-guard-wave2` | `refactor(r07-01-orc-cron-worktree-guard-wave2, SPL-<row issue>): ...` | `review/r07-01` | 1 |
| r07-02 | `c002-r07-02-orc-cron-worktree-guard-wave3` | `refactor(r07-02-orc-cron-worktree-guard-wave3, SPL-<row issue>): ...` | `review/r07-02` | 1 |

**r07-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/box-disk-sweep-install-cron.func.sh` (drop unused `gd cd` at
`:30`, replace `:41-46` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${BOX_SWEEP_ALLOW_WORKTREE:-0}" || return 1; }`),
`csi-spl-orc/src/bash/run/prune-docker-images-install-cron.func.sh` (drop unused `gd cd`
at `:30`, replace `:42-47` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${PRUNE_ALLOW_WORKTREE:-0}" || return 1; }`),
`csi-spl-orc/src/bash/run/tmp-scratch-sweep-install-cron.func.sh` (drop unused `gd cd` at
`:28`, replace `:41-46` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${SCRATCH_ALLOW_WORKTREE:-0}" || return 1; }`),
`csi-spl-orc/src/bash/run/spl-agent-id-reap-install-cron.func.sh` (drop unused `gd cd` at
`:27`, replace `:33-38` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${REAP_ALLOW_WORKTREE:-0}" || return 1; }`), and
`csi-spl-orc/src/bash/tests/cron-tagged-line.tst.sh` (insert section `8` before `:123`: 4
wave-2 one-copy checks and 6 standalone installer linked-worktree checks). NOT
`cron-tagged-line.func.sh`, NOT `spl-od-pool-supervise-install-cron.func.sh`, NOT
`spl-shadow-feed-install-cron.func.sh`, NOT
`spl-cost-labels-translate-install-cron.func.sh`, NOT
`spl-cost-labels-translate-install-cron.tst.sh`, NOT `install-box-crons.func.sh`, NOT
`spl-private-overlay-install-cron.func.sh`, NOT `.shellcheck-warning-baseline.txt`, or
any other file. Do: plan section 2 row 01 verbatim, 1.3's shape (verbatim blocks in 1.3);
red control (`rc1`, head1's `cron-tagged-line.tst.sh` on parent) RED then GREEN in the
body; mutations `m1a`/`m1b`/`m1c`/`m1d` caught. Gates: the row's tests (section 2,
`SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 5 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper delegation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota,
valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the
claude backup is used; never mistral; re-checked at placement).

**r07-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-od-pool-supervise-install-cron.func.sh` (drop unused `gd cd`
at `:29`, replace `:33-38` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${OD_CRON_ALLOW_WORKTREE:-0}" || return 1; }`),
`csi-spl-orc/src/bash/run/spl-shadow-feed-install-cron.func.sh` (drop unused `gd cd` at
`:24`, replace `:33-38` with `[[ "$act" == install ]] && { cron_refuse_linked_worktree
"$dry" "${SHADOW_FEED_ALLOW_WORKTREE:-0}" || return 1; }`),
`csi-spl-orc/src/bash/run/spl-cost-labels-translate-install-cron.func.sh` (drop unused
`gd cd` at `:42`, replace `:76-81` with `    cron_refuse_linked_worktree "$dry"
"${COST_LABELS_TRANSLATE_ALLOW_WORKTREE:-0}" || return 1`), and
`csi-spl-orc/src/bash/tests/spl-cost-labels-translate-install-cron.tst.sh` (insert
section `9` before `:160`: 3 wave-3 one-copy checks and 5 fixture-worktree standalone
installer linked-worktree checks). NOT `cron-tagged-line.func.sh`, NOT
`cron-tagged-line.tst.sh`, NOT `box-disk-sweep-install-cron.func.sh`, NOT
`prune-docker-images-install-cron.func.sh`, NOT
`tmp-scratch-sweep-install-cron.func.sh`, NOT `spl-agent-id-reap-install-cron.func.sh`,
NOT `install-box-crons.func.sh`, NOT `spl-private-overlay-install-cron.func.sh`, NOT
`.shellcheck-warning-baseline.txt`, or any other file. Do: plan section 2 row 02
verbatim, 1.4's shape (verbatim blocks in 1.4); red control (`rc2`, head2's
`spl-cost-labels-translate-install-cron.tst.sh` on parent) RED then GREEN in the body;
mutations `m2a`/`m2b`/`m2c` caught. Gates: the row's tests (section 2, `SPOOL_TEST=1`, in
the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (internal helper delegation; no behaviour changes)`. Kind `simple_coding`,
vendor claude; R7 **agy seat** (claude waiver backup only while agy is out of quota,
valid only under ruling `dc84300a` — cite ruling `dc84300a` in the row brief if the
claude backup is used; never mistral; re-checked at placement).

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the linked-worktree cron guard across row 01's 4 wave-2 installers (1.3) | 4 on `13293131f` (`box-disk-sweep`, `prune-docker-images`, `tmp-scratch-sweep`, `spl-agent-id-reap`) -> 0 (delegating to `cron_refuse_linked_worktree`; 7/10 non-secret verbatim cron installers consolidated) |
| copies of the linked-worktree cron guard across row 02's 3 wave-3 installers (1.4) | 3 on `13293131f` (`spl-od-pool-supervise`, `spl-shadow-feed`, `spl-cost-labels-translate`) -> 0 (delegating to `cron_refuse_linked_worktree`; **10/10** non-secret verbatim cron installers consolidated) |
| lines (`git diff --numstat` of each head) | row 01: `box-disk-sweep-install-cron.func.sh` +2 -7, `prune-docker-images-install-cron.func.sh` +2 -7, `tmp-scratch-sweep-install-cron.func.sh` +2 -7, `spl-agent-id-reap-install-cron.func.sh` +2 -7, `cron-tagged-line.tst.sh` +44 -0; row 02: `spl-od-pool-supervise-install-cron.func.sh` +2 -7, `spl-shadow-feed-install-cron.func.sh` +2 -7, `spl-cost-labels-translate-install-cron.func.sh` +2 -7, `spl-cost-labels-translate-install-cron.tst.sh` +40 -0 |
| measured on | `13293131f`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Remaining linked-worktree guards in `orc:src/bash/run/` with different wording or secret-class adjacency (candidates for `r08`+): `orc:src/bash/run/install-box-crons.func.sh:65-70` (278 lines; WARN at `:69` says `"the paths below"` plural, does not call `cron_drop_tagged_line`), `orc:src/bash/run/spl-agent-hooks-install.func.sh:37-39` and `spl-agent-identity-install.func.sh:42-44` (FATAL says `"run the install from the main checkout"`, WARN says `"the paths below"` plural), `orc:src/bash/run/spl-private-overlay-install-cron.func.sh:65-72` (89 lines; names `RESERVE_GH_TOKEN_FILE` — secret-class, kept out per brief), plus distinct one-offs `box-peer-ssh-grant.func.sh:53` (`"grant from..."`) and `spl-box-deploy.func.sh:151` (`"PREREQ checkout missing..."`) | `install-box-crons` / `spl-agent-{hooks,identity}-install` need an optional plural/verb parameter on `cron_refuse_linked_worktree` to preserve exact wording (so they belong in a dedicated `r08` row, not mixed into wave 2-3); `spl-private-overlay-install-cron` stays out per the brief's secret-class exclusion | `git grep -n "is a linked worktree:" 13293131f -- csi-spl-orc/src/bash/run/` (24 lines across 13 files: 7 taken in r07, 6 here) (n=1) |
| `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh` and `spl-issue-owner-question-diss.func.sh` `*_read` (`brc:91-96` vs `oq:62-68`) and `*_apply` (`brc:136-161` vs `oq:111-137`) scaffolding (r04/r05/r06 section 7) | 15 differing lines in `*_apply` (`chmod 600`, stderr handling, status predicate, log/undo headers); left out while cleaner zero-behaviour-change cron worktree-guard duplicates remained (next `r08` candidate) | r06 section 7 |
| Remaining non-matching cron installers: `orc:src/bash/run/spl-dispatch-rotate-install-cron.func.sh` (134 lines, 2-line rotate+heal), `spl-agent-boot-restore-install-cron.func.sh` (177 lines, retire/removed markers and custom install wording), `spl-box-restart-install-cron.func.sh` (117 lines, `SPL_DESK_CRON_CREATE` + slot check), `spl-peer-crons.func.sh` (273 lines, `SPL_DESK_CRON_CREATE` + no `"the "` prefix) | none matches `_spl_simple_cron_apply` or `_spl_run_cron_apply` verbatim; each needs separate inspection or a distinct helper | r06 section 7 |
| `orc:src/bash/run/spl-{backfill,fallback,reply,reply-count,topic-reply}-probe.func.sh` (5 live probe sidecar setup/pin/detach/kill blocks) | touches 5+ files and passes `ROOT_KEY` / `MEMBER_PW_FILE` (secret-handling path; brief: secret-class sites stay out) | r06 section 7 |
| `orc:src/bash/run/spl-msg-dedup.func.sh:46-65` and `spl-msg-wipe.func.sh:36-55` (20-line preflight) | heavy PG R2 gate (`postgres:16-alpine` containers) | r06 section 7 |
| `iac:src/bash/run/gcp-{get-alert-incident,list-alert-incidents}.func.sh` (paged Monitoring v3 `timeSeries` curl loop) | passes `-K "${cfg}/auth.curl"` (secret-class); kept out per brief | r06 section 7 |
| Candidates-file open items: `_ppe_keys` exact-key in `iac:src/bash/run/check-pre-push-e2e.func.sh:121` (line 113), `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` saying `Lang-review: a-NNN` (line 115), WUI entry-chunk `ci_initial_gzip_kb` headroom (line 125), other-box process churn (lines 147-148), and `do_spl_review_go` sentence-initial `"Apply"` false hold (lines 150-151) | `_ppe_keys` is gate-design input; `i18n-lang-review-exempt.json:2` is a 1-line JSON doc comment (doc/bug-shaped); WUI entry-chunk headroom and process churn are perf-shaped; `review-go` `"Apply"` is bug-shaped. Lines 1, 25, 48, 76, 104, and 133 remain served on `13293131f` | `git show` / `git grep` on `13293131f` (1.2 (c), n=1) |
| `orc:src/bash/run/spl-channel-agent-{add,add-op,remove-op}.func.sh`, `spl-{accepted-close,desk-poll-ack,review-go}.func.sh` action bodies, `spl-hub-box-band.func.sh`, `spl-wui-perf-report.func.sh`, `csi-spl-utl/**`, `iac:sec-*.func.sh`, `orc:scripts/*-cron.sh`, Go/WUI duplicates, spec 011 deferred/owner-decision tasks, and remaining non-refactor candidates-file items | each pulls PostgreSQL or 30+ tests into R2, is secret-class, or stays out for its r06/r05 section 7 reason | 1.2 (a), (c), (d); r06 section 7 |

## 8. Changes

- v0.1 (a-071): the rows and every read on `13293131f`; both heads built in detached
  scratch worktrees; the 19-suite column of 1.5 run on base and each row's head;
  `shellcheck 0.10.0 -S warning -x` and `do_sec_shellcheck` rc 0; both red controls
  (`rc1`, `rc2`) and all 7 mutation checks (`m1a`, `m1b`, `m1c`, `m1d`, `m2a`, `m2b`,
  `m2c`) run on detached worktrees and verified RED; all caller and test hunks included
  verbatim in 1.3 and 1.4. Pushed to `review/c002-refactor-round-07-planner` (`21c3e6ce3`).
- v1.0 (a-071): folded cross-vendor claude panel (`c-073`, review on v0.1 `21c3e6ce3`,
  seat commit `10e6f8072`, msg `4159c478`) W1 and recorded N1-N6 (no row change; all 9
  fenced `bash` blocks **byte-identical** to v0.1 `21c3e6ce3`; zero drift across all 9
  row files + `cron-tagged-line.func.sh` from `13293131f` to `origin/master` `444c80979`):
  - **W1 (R2):** added `orc:src/bash/tests/spl-box-deploy.tst.sh` (`:60` names
    `do_spl_agent_id_reap_install_cron`) to row 01's `Tests:` column (section 2),
    section 1.5's table (now 20 suites; measured `0 / 36 / 0` on base and head1 at
    13:33Z-13:36Z, n=1), and section 2.2's checked paths (`lane-map.sh --check` exit 4,
    0 owned, 20 `unknown:` on the other box at 13:33:27Z).
  - **N1:** fixed section 7's `git grep -n "is a linked worktree:"` line count from
    `25` to `24` lines across 13 files.
  - **N2:** recorded that the 20 `unknown:` other-box lanes shifted (`c-079` in, `c-935`
    out; still 0 owned); the holder re-reads at placement per R3.
  - **N3:** recorded that r06's close record (`444c80979`, `docs(r06-plan, SPL-6566)`)
    landed after r07 started; per rulebook 5.3, all r07 checks and row briefs keep the
    recorded `W=2026-11-26T09:49:33+02:00` (`c28e628f2`).
  - **N4:** recorded panel verification that `|| true` holds (neither `./run` nor
    `spl-box-deploy.func.sh:336` uses `set -e`).
  - **N5:** recorded that the `remove` bypass is test-pinned for `box-disk-sweep` and
    visible in the verbatim `[[ "$act" == install ]] && ...` lines of the other wave-2/3
    callers (non-blocking).
  - **N6:** recorded that row 02's test column runs `cron-tagged-line.tst.sh`, which row
    01 edits; R1 holds (edited files are disjoint), and the second row to land re-runs
    `cron-tagged-line.tst.sh` after its rebase onto `origin/master`.
  Pushed fast-forward to `review/c002-refactor-round-07-planner`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: a-071 (agy): v1.0 (W1 and N1-N6 folded; pending final v1.0 panel
  signature and `do_spl_review_line_check` rc 0).
- Panel reviewer seat: c-073 (claude): reviewed v0.1
  (`21c3e6ce33a51d9a803543c87c6bbb2a9bc0b748`, seat commit `10e6f8072`, msg `4159c478`;
  W1 and N1-N6 folded in v1.0; pending final v1.0 signature and
  `do_spl_review_line_check` rc 0).
- Row R7 seats: section 4 (agy per row, claude waiver backup only under ruling `dc84300a`;
  never mistral).
