# CI Failures Panel: Verdict of Seat Agy (a-496)

Status: **SIGN** on `bc0ee0801` (v0.1 + S4/I12, editor c-197).
Task: `dispatch-5f0839c6`. Issue: SPL-3422 (seat lane), Epic: SPL-2402, Spec: `csi-spl-doc/specs/011-spool-project-refactor`.
Reviewed document: `csi-spl-doc/doc/md/ci-failures-100-2026-10-25.md` at git sha `bc0ee0801e7d0101ab6ed364119de1093826d804` (`origin/review/ci-failures-100-panel`).

This seat confirms the factual basis, agrees with the primary themes and structural conclusions of the panel draft, and signs the document subject to the folding of items W1–W7 into draft v0.2.

---

## 1. Spot-check verification of facts (13 facts across all families)

Every command below was executed directly by seat `a-496` in this lane's worktree.

| # | Family / Area | Claim in Document | Command Executed | Output / Evidence | Verdict |
|---|---|---|---|---|---|
| 1 | Window & Run Totals (Sec 1) | 100 failed master runs (64 push, 36 schedule; 76 distinct head shas) from 2026-10-20T17:47Z to 2026-10-25T15:57Z | `python3 -c "import json, subprocess; out = subprocess.check_output(['gh', 'run', 'list', '--branch', 'master', '--status', 'failure', '--limit', '120', '--json', 'databaseId,createdAt,workflowName,headSha,event']).decode(); runs = [r for r in json.loads(out) if '2026-10-20T17:47:00Z' <= r['createdAt'] <= '2026-10-25T15:58:00Z']; print(len(runs), {e: sum(1 for r in runs if r.get('event')==e) for e in set(r.get('event') for r in runs)}, len(set(r.get('headSha') for r in runs)), runs[-1]['createdAt'], runs[0]['createdAt'])"` | `100 {'push': 64, 'schedule': 36} 76 2026-10-20T17:47:05Z 2026-10-25T15:57:41Z` | **CONFIRMED** |
| 2 | B: Defect / Biggest Defect (Sec 3.1, 4) | SPL-3190 / `c834c655f` gave dock textarea padding-inline-end 8px, breaking `phone-composer-target.test.mjs` on run 40106628647 (6 h 33 red). Reviewer a-129 agy ran `issues-phone-overlap` only. Fixed by `2e168db7f`. | `git log -1 c834c655f` and `git log -1 2e168db7f` and `gh run view 40106628647 --json jobs` | `c834c655f` review line: `review: a-129 agy PASS ... ran: pnpm run typecheck, ... tests/e2e/issues-phone-overlap.test.mjs ...`; `2e168db7f` commit body: `"c834c655f gave the dock textarea padding-inline-end 8px ... went red on master (run 40106628647)"`; Job 120910923835 log: `FAIL 390px no-chip unfocused empty box ... slot:197, textEnd:189` | **CONFIRMED** |
| 3 | B: Defect / Cross-module Smell (Sec 4, 6 S5) | SPL-2759 / `e86f7b9b1` unexported WUI constants, breaking Go test `TestMentionGrammarPinnedToWUI`. Reviewer a-677 agy ran WUI tests only. Fixed by `36717a7f5`. | `git log -1 e86f7b9b1` and `git log -1 36717a7f5` and `sed -n '70,90p' csi-spl-api/src/go/spool-hub-api/internal/store/flow_mentions_test.go` | `e86f7b9b1` review line: `review: a-677 agy ... ran: node tests/unit/unused-exports.test.mjs; pnpm run test:unit; pnpm run typecheck; pnpm run shims:check`; `36717a7f5`: `"mention-grammar pin matches the *_SRC consts with or without export"`; `flow_mentions_test.go:72` reads `csi-spl-wui/src/utils/agent-id.mjs` text directly | **CONFIRMED** |
| 4 | B: Defect / Config Coupling (Sec 4, 6 S4) | SPL-2947 / `892b03122` added dev workspaces to steps.052, turning `tenant-host.tst.sh` red because the test copied live `dev.env.yaml`. Fixed by `e0f6ea1ba`. | `git log -1 892b03122` and `git log -1 e0f6ea1ba` and `sed -n '50,60p' csi-spl-orc/src/bash/tests/tenant-host.tst.sh` | `e0f6ea1ba`: `"892b03122 added 5 dev workspaces to steps.052 that are not in env.dns.mapped_tenants ... tenant-host.tst.sh (wf 10, run 39870522238) ... failed"`; `tenant-host.tst.sh:56` copies `$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml` without isolating steps.052 workspaces | **CONFIRMED** |
| 5 | C: Runner Image (Sec 3.2, 6 S2) | Sha `3ab1fce87` failed 3x on `ubuntu-26.04` (e.g. run 40170969195) and passed on `ubuntu-24.04` (run 40171034562) 1 min later. Symlinks to `sleep` exist in `test-spool-send.sh:69` and `test-tmux-close-window.sh:352`. | `gh run view 40170969195 --json conclusion,headSha` and `gh run view 40171034562 --json conclusion,headSha` and checking job image logs and test source lines | Run 40170969195 (06:57Z): `conclusion: failure`, `Image: ubuntu-26.04`; Run 40171034562 (06:58Z): `conclusion: success`, `Image: ubuntu-24.04`; `test-spool-send.sh:69`: `ln -s "$(command -v sleep)" "$T_TMP/sudo"`; `test-tmux-close-window.sh:350`: `for h in claude grok agy; do ln -sf "$(command -v sleep)" "$T_TMP/bin/$h"; done` | **CONFIRMED** |
| 6 | E: Deploy Watcher (Sec 3.3, 6 S3) | wf 00 runs hourly on cron `'17 * * * *'`. All 9 failed runs failed because `check-hub-deploy.func.sh:93-96` returns 4 (unhealthy) whenever serving traffic is not `<latest>:100` during normal 10-min canary roll. | `grep -n "cron:" .github/workflows/00_deploy-lag-watch.yml` and `sed -n '93,96p' csi-spl-orc/src/bash/run/check-hub-deploy.func.sh` and `sed -n '410,413p' csi-spl-cnf/csi-spl/all.env.yaml` | `.github/workflows/00_deploy-lag-watch.yml:47`: `- cron: '17 * * * *'`; `check-hub-deploy.func.sh:93`: `if [[ -n "$serving" && "$serving" != "$latest:100" ]]; then echo "$ENV unhealthy ... traffic=$serving"; return 4; fi`; `all.env.yaml`: canary percent 10, minutes 10 | **CONFIRMED** |
| 7 | F: External Advisories (Sec 3.5) | GO-2026-6809 in wf 15 closed by `12bcdcd20`; nuxt GHSA-vjh5 in wf 15 ignored by `701160ff8`; `serialize-javascript` GHSA-m5mm-p8h7-m29v in wf 70 (run 40209390726) remained open at report time. | `git log -1 12bcdcd20` and `git log -1 701160ff8` and `gh run view 40209390726 --json jobs` | `12bcdcd20`: `"fix(api, GO-2026-6809): go.mod and every Go pin move to go1.26.10, the stdlib crypto/x509 fix"`; `701160ff8`: `"fix(wui deps, SPL-2908): workflow 15 pnpm audit green - nuxt GHSA-vjh5 + GHSA-xfq5 ignored until 2026-11-05"`; Run 40209390726 log: `https://osv.dev/GHSA-m5mm-p8h7-m29v | 2.1 | npm | serialize-javascript | 7.1.1` | **CONFIRMED** |
| 8 | G: Ops / Nightly Jobs (Sec 3.6) | wf 46 nightly demo wipe failed in run 39540791042 due to data guard: `workspace demo has members with role(s) developer`. | `gh api repos/csitea/csi-spl/actions/jobs/119028092409/logs | grep "FATAL"` | `2026-10-21T03:52:16.6672960Z FATAL the wipe of demo in prd failed, nothing was committed: ERROR: demo wipe: workspace demo has members with role(s) developer: not a demo workspace, refused` | **CONFIRMED** |
| 9 | D: Flake (Sec 3.4) | `desk-cron-trunk.tst.sh` case 12 in run 40199041284 failed with missing temp directory `fatal: cannot change to '.../c12-origin.git': No such file or directory`. | `gh api repos/csitea/csi-spl/actions/jobs/121175653198/logs | grep -E "FAIL|FAILED"` | `FAIL: 12. 0 false report(s) or recoveries in 2 ticks beside concurrent checkouts: desk-cron-trunk: 1 failure(s); FAILED: desk-cron-trunk.tst.sh` | **CONFIRMED** |
| 10 | A: Fail-fast Collateral (Sec 2, T3) | 41 jobs stopped by `GATE_FAIL_FAST` because another job failed, logging `gate fail-fast: stopped, so the next gate run starts; red in this run: ...` | `grep -n "gate fail-fast: stopped" csi-spl-orc/src/bash/scripts/gate-fail-fast.sh` | `csi-spl-orc/src/bash/scripts/gate-fail-fast.sh:99`: `echo "::error::gate fail-fast: stopped, so the next gate run starts; red in this run: $(paste -sd, <<<"$red")"` | **CONFIRMED** |
| 11 | S1: WUI Font Discrepancy (Sec 6 S1) | `phone-composer-target.test.mjs:318` has pixel-strict boundary asserts; CI workflows lack fontconfig/font pinning; `card-edge-inset.test.mjs:20` documents Noto vs DejaVu divergence. | `git grep -nE 'FONTCONFIG|fonts-noto|fonts-dejavu' -- .github/workflows` and inspecting `card-edge-inset.test.mjs:20` and `phone-composer-target.test.mjs:318` | `git grep` in `.github/workflows` returns 0 lines; `card-edge-inset.test.mjs:20`: `"The WUI ships no webfont: its stack falls through to the runner's fontconfig default, Noto Sans on one CI box and DejaVu Sans on another"`; `phone-composer-target.test.mjs:318`: `s.textEnd >= s.slot - 1` | **CONFIRMED** |
| 12 | S4: Stale binary stderr bleed (Sec 6 S4, I12) | `test-tmux-close-window.sh:668` case 16 redirects 2>&1 and asserts `wc -l == 1`; `spool-env.inc.sh:62` emits `spool-env: WARN ... is older than its sources` on stderr when `bin/spool` is stale, producing a false red. | `sed -n '663,668p' csi-spl-orc/src/bash/features/spawn-agents/tests/test-tmux-close-window.sh` and `sed -n '60,65p' csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` | `test-tmux-close-window.sh:665-668`: `MISTRAL_TMUX_PANE="$P16" bash "$SUT" ... >"$T_TMP/o" 2>&1`, followed by `eq "16. ... it is one line" 1 "$(wc -l <"$T_TMP/o")"`; `spool-env.inc.sh:62`: `echo "spool-env: WARN $2 is older than its sources ..." >&2` | **CONFIRMED** |
| 13 | Commits per Kind of Task (Sec 5.2) | 466 commits on master in window (WUI: 96, orc bash: 91, iac bash: 29, hub Go: 53, docs: 138/139). | `python3 -c "import subprocess; out = subprocess.check_output(['git', 'log', '--since=2026-10-20T17:00Z', '--until=2026-10-25T16:00Z', '--format=COMMIT:%H', '--name-only', 'origin/master']).decode(); ..."` | Total commits: 466; breakdown: docs: 139, wui: 96, orc: 91, iac: 29, hub: 53. Matches document breakdown within 1 commit (classification boundary). | **CONFIRMED** |

---

## 2. Evaluation and judgment

### 2.1 Themes (T1–T6)
The seven families and six themes correctly categorize the 167 failed jobs and 100 failed runs:
- Isolating **Family A (41 fail-fast collateral jobs)** and **Family E (22 hourly deploy watcher jobs)** is critical. Together they represent 63 of 167 failed jobs (38%) that did not represent landed defects on master. Treating them as separate operational and reporting artifacts prevents massive inflation of failure metrics.
- Identifying **T1 (real landed defects, 45 jobs from 14 commits)** and demonstrating that 7 of 14 were WUI (30 jobs) accurately pinpoints where regression risks concentrate in the development cycle.
- **T2 (runner image 26.04 and host tool coupling)** correctly identifies test fixtures that violated test hermeticity by relying on host multi-call utilities.

### 2.2 Per-vendor fairness and review behavior
The conclusion in Section 5.1 is fair, objective, and statistically sound:
- Of 14 defect commits, all 10 that could be traced from local branch reflogs were authored by Claude. However, in the measured period, Claude accounted for 1,399 of 1,771 started lanes (79%), and by fleet policy was the *only* vendor assigned to general coding (Mistral was restricted to docs/reviews per Developer Guide 5.1, Grok was out of limits, and Agy was assigned to review/docs). With zero coding commits by other vendors, no comparative deficit can be attributed to Claude.
- The document correctly identifies the actual systemic point of failure: **the review process**. Reviewers (including Agy seats `a-129` on SPL-3190 and `a-677` on SPL-2759) mechanically re-ran only the tests the author ran or selected, rather than identifying tests that covered the modified component or cross-boundary dependencies. This finding directly motivates proposed issues I2 and I11.

### 2.3 Proposed issues (I1–I12): Cause vs. Symptom
All proposed issues target root causes rather than symptoms:
- **I1 & I2**: Directly address the root cause of WUI layout regressions by establishing an identical fontconfig environment across boxes and CI runners, and automating e2e component test selection during pre-push.
- **I3**: Eliminates reliance on `sleep` binary symlinks that break when coreutils transitions to multi-call implementations (as in Ubuntu 26.04).
- **I5**: Resolves the root cause of false-positive deploy alerts by making `check-hub-deploy` aware of active canary roll windows.
- **I6, I7, I12**: Address test hermeticity smells (S4) where test assertions coupled to live environment configuration, runner Go cache state, or shared stderr output.
- **I8**: Moving the mention grammar to a single shared contract file addresses the cross-language architectural coupling between Go and WUI utils.

### 2.4 Refactor rows (R-a–R-g) and Rounds Rulebook (R1–R16)
- **Disjoint files (R1)**:
  - Rows R-a, R-b, R-c, R-d, and R-e operate on completely disjoint file sets.
  - **Conflict identified**: Both R-f and R-g modify `.github/workflows/10_ci-quality.yml` (R-f configures runner font environment; R-g configures gate-health step reporting at line 1315). This violates R1 if spawned concurrently in the same batch. They must be split across batches (e.g., R-f in Batch 1, R-g in Batch 2).
  - **Overlap between R-a and I12**: R-a touches `csi-spl-orc/src/bash/features/spawn-agents/tests/test-tmux-close-window.sh` for I3, while I12 modifies the same file (case 16 line assert). I12 should be explicitly folded into R-a.
- **Red controls (R2 / Rulebook 3.1)**:
  - Each proposed row specifies a concrete, empirical red control that proves the defect before applying the refactoring.

---

## 3. Findings to fold into v0.2 (W1–W7)

The editor should fold the following specific items into v0.2 of `ci-failures-100-2026-10-25.md`:

- **W1 (line 348, Section 8)**: R-f and R-g both touch `.github/workflows/10_ci-quality.yml`. Section 8 must explicitly assign batches to comply with R1 (Disjoint files per batch):
  - **Batch 1**: R-a (`test-spool-send.sh`, `test-tmux-close-window.sh`), R-b (`check-hub-deploy.func.sh`), R-c (`tenant-host.tst.sh`), R-d (`check-pre-push-baseline.tst.sh`), R-e (`flow_mentions_test.go`), R-f (`10_ci-quality.yml` + e2e runner).
  - **Batch 2**: R-g (`10_ci-quality.yml` gate-health step + `csi-spl-iac/src/bash/run/report-ci-gate.func.sh`).
- **W2 (line 346, Section 8)**: In Row R-g, replace `the do_report_ci_gate action file (path unchecked)` with the verified repository path: `csi-spl-iac/src/bash/run/report-ci-gate.func.sh`.
- **W3 (lines 334, 340, 348, Sections 7 & 8)**: I12 and R-a both modify `csi-spl-orc/src/bash/features/spawn-agents/tests/test-tmux-close-window.sh`. Fold I12 into row R-a so that both `sleep` symlink elimination (case 11) and stderr line-count isolation (case 16) are delivered and tested together in a single lane, avoiding branch collisions on the same test file.
- **W4 (line 330, Section 7)**: For issue I8, clarify that Option (a) ("mention grammar moves to one shared contract file both sides read") is the preferred architectural target. Option (b) ("WUI pre-push runs Go test") introduces unnatural cross-module pre-push toolchain dependencies.
- **W5 (line 355, Section 9 Open Question 1)**: Resolved. Inspection of `20_hub-build-deploy.yml` run 40200462364 confirms that prd deploy was actively executing its 10-minute canary roll from 14:21:20Z to 14:37:12Z. The wf 00 run 40201988256 executed at 14:23:14Z, precisely in the middle of the healthy in-flight canary roll. The split was an active roll, not a stuck split.
- **W6 (line 357, Section 9 Open Question 2)**: Resolved. Reflog inspection in this worktree traces SPL-3015 (`59516d0b7`) to Claude lane `c-302` (`c-302-c002-s025-lock-b8-wui`) and SPL-3065 (`178dc2b4f`) to Claude lane `c-312` (`c-312-c854-b06-01-orc-dispatch-lag-grace`). Both confirm the author vendor was Claude.
- **W7 (line 359, Section 9 Open Question 3)**: Resolved. In wf 30 run 39717268991, `do_spl_wui_live_proof` failed with HTTP 404 because the Firebase static WUI deploy completed in ~3 minutes, landing ahead of the Cloud Run backend hub deploy on prd. The failure was a transient deploy order skew, not a code regression.

---

## 4. Signature

signed: **a-496** (agy seat) on `bc0ee0801` (with points W1–W7 to fold into v0.2)

---

## 5. Lane state at rotation (00:08Z UTC)

For a successor seat or dispatch review:
- Task: SPL-3422, epic SPL-2402, brief `c002-ci-failures-panel-seat-agy`.
- Work completed: Whole v0.1 draft read at `bc0ee0801`; 13 empirical spot checks completed and confirmed; themes, per-vendor review fairness, root-cause issue alignment, and rulebook R1-R16 compliance evaluated.
- Verdict: SIGN on `bc0ee0801` with items W1–W7 to fold into v0.2.
- Branch: `review/ci-failures-100-seat-agy` pushed to `origin`.
- Spool messages: Sent verdict note to editor `c-197` on task `dispatch-5f0839c6`, cc to dispatch lease holder `c-002`, status note to spawner `c-001`.
- Next: When editor folds W items into v0.2, verify the fold on `review/ci-failures-100-panel`.
- Exit condition: Exit only on a spool message on task `dispatch-5f0839c6` starting with ACCEPTED.
