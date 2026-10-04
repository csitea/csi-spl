# 072 research 12: CI portability (GitHub Actions on a fork)

Status: **research v0.1**, input to [spec 072](../spec.md) gap G14 / action
A13. Author: c-172. Tree: `origin/master` @ `474b940a8`, 2026-10-04. Docs
only. Every claim about the tree carries the command that shows it, run from
`.github/workflows/` on that tree, n = 1 per command.

The question: of the 25 workflows, which are bound to our org (secrets,
self-hosted runners, project ids, our live hosts), what does a fork see red or
stuck, and what makes CI pass on a fork with **zero secrets**. Ranked by DevEx
(owner, msg `2144f3d9`): a contributor's first push must end in a verdict, not
a queue and not a red they cannot fix.

## 1. Today

### 1.1 The inventory

`ls *.yml | wc -l` -> 25. Per workflow (`grep -cE 'runs-on:.*self-hosted'`,
`grep -oE 'secrets\.[A-Z_]+' | sort -u`, `grep -c 'cron:'`):

| wf | what | runner | org binding | on a fork with zero secrets |
|---|---|---|---|---|
| 10 quality gate | hub, wui, iac, orc, cnf suites, hygiene, gate health | **self-hosted** x10 | runner label `[self-hosted, spool-ci]` | **queues, never runs** (no runner has the label) |
| 11 public gate | hub suite, wui unit + typecheck, wui e2e | ubuntu x3 | none | green (runs only while the repo is public: `if: !github.event.repository.private`) |
| 15 deps + secrets | govulncheck, gitleaks, pnpm audit, trivy | ubuntu | none | runs; header line 2 still says self-hosted (stale) |
| 20 hub build/deploy | test, then deploy dev/prd | ubuntu | secret `GCP_KEY_CSI_SPL_<ENV>` or vars `GCP_WIF_PROVIDER_<ENV>` + `GCP_DEPLOY_SA_EMAIL_<ENV>` | test runs; deploy **skips with a notice** (`prepare-deploy`, lines 158-165) |
| 21 deploy catch-up | probes the live envs every 15 min, dispatches 20/30 | ubuntu | **our hosts from cnf** | if enabled: probes our hubs, finds the fork's sha unserved, dispatches 20/30, which skip |
| 22 deploy verify | post-deploy smoke | ubuntu | our hosts from cnf | called by 20 only after a deploy, else dispatch: not on a fork push |
| 30 wui build/deploy | test, then Firebase deploy | ubuntu | cnf `steps.019...wui_deploy` + same key/WIF pair | test runs; deploy **skips with a notice** (lines 134-147) |
| 31 edge warm | after 30 | ubuntu | our hosts | plans `[]`, skips |
| 40 tenant host reconcile | 019 + 025 apply | ubuntu | secret key | skips (`go=0`, line 88) |
| 45 db backup | dump to GCS | ubuntu | secret key | skips (`go=0`, line 119) |
| 50 oss standalone | compose on a clean runner, real Chrome | ubuntu | none | green (public only) |
| 55 stable release | tags the commit **our prd hub runs** | ubuntu | our prd host from cnf | if enabled: I believe, unchecked, it tags our prd sha in the fork |
| 60-67, 70, 85 | CodeQL, semgrep, gosec, eslint, trufflehog, checkov, hadolint, shellcheck, supply chain, actionlint | ubuntu | none | green |
| 68 DAST | headers + ZAP baseline | ubuntu | **our dev host** from cnf (lines 56-58) | if enabled: **scans our dev from the fork** |
| 99 runner smoke | dispatch only | **self-hosted** x1 | runner label | queues |
| 00 deploy lag watch | hourly | ubuntu | key / WIF vars | `targets` gives `any=false`, skips |

Counts behind the table:

- `grep -nE '^\s+runs-on:.*self-hosted' *.yml | wc -l` -> **11** (10 in wf 10,
  1 in wf 99). **Correction to spec 072 4.3 #13**: it says "14 jobs";
  `grep -c self-hosted 10_ci-quality.yml` -> 14 counts the header comments.
  Jobs: `awk '/^jobs:/{f=1;next} f&&/^  [a-z-]+:/' 10_ci-quality.yml` -> 10
  (hub-suite, wui-suite, wui-generate, wui-e2e, iac-suite, orc-suite,
  cnf-suite, the box-reference gate, gate-health, distribution-hygiene).
- `grep -lE 'GCP_KEY_CSI_SPL_' *.yml | wc -l` -> 5 (00, 20, 30, 40, 45). The
  secret name carries `<org>_<app>_<ENV>`.
- `grep -nE 'wanted=\(dev prd\)|for e in dev prd' *.yml | wc -l` -> 4: the env
  list is a literal.
- `grep -lE 'csi-spl-cnf/csi-spl/' *.yml | wc -l` -> 4: the cnf path carries
  `<org>-<app>`.
- `grep -n TPL_GEN_REPO_URL 10_ci-quality.yml` -> line 447, a literal GitHub
  URL. Public today (`curl -s https://api.github.com/repos/<org>/tpl-gen`
  -> `visibility: public`), so a fork clones it with no token.
- `grep -c 'cron:' *.yml | grep -v ':0' | wc -l` -> 8 scheduled workflows
  (00, 15, 21, 40, 45, 55, 60, 68).
- Forks today: `curl -s https://api.github.com/repos/<org>/<org>-<app>` ->
  `forks_count: 0`, `visibility: public`. **Nobody has run CI on a fork**; the
  table's last column is read from the YAML, not measured.

### 1.2 What is already right

The deploy-shaped workflows were written to degrade: 00, 20, 30, 40, 45 decide
their targets from **booleans** of the secret (`secrets.X != ''`) and the WIF
vars, and print a `::notice::... skipped: neither secret ... nor repo
variables ... are set` that names the missing thing. A fork pushing to its
`master` gets green test jobs and skipped deploy legs. 11 and 50 were built
for outside contributors (no secret, read-only token). The org runner group
admits only named workflows at `refs/heads/master` (wf 11 header lines 10-12),
so a pull request can never reach our self-hosted boxes.

### 1.3 What a fork owner actually sees (GitHub's behaviour, not measured)

1. Actions are off in a new fork until the owner enables them, and scheduled
   workflows stay off in a fork until enabled.
2. After enabling, a push to the fork's `master`: wf 10 shows ten jobs
   "Waiting for a runner to pick up this job" with no error, until GitHub
   cancels them (I believe, unchecked, after 24 h). This is the only **stuck**
   item, and it is the gate a contributor most needs.
3. A push to any other branch of the fork runs **nothing** of 10 or 11 (both
   trigger on `push: master` only, plus 11 on `pull_request`). The contributor
   learns the verdict only after opening a pull request upstream, and then
   only for 3 of the 10 suites (wf 11 lacks iac, orc, cnf, hygiene, the
   box-reference gate).

## 2. Blockers

1. **wf 10 is hard-wired to our runner label.**
   `10_ci-quality.yml:64,139,191,268,371,512,645,683,710,757`
   `runs-on: [self-hosted, spool-ci]`. A fork's gate queues with no error. The
   escape hatch is a hand `sed` (header line 18). Measure hurt: errors (a
   silent queue).
2. **A contributor's pull request is not gated on iac, orc, cnf or hygiene.**
   `awk '/^jobs:/{f=1;next} f&&/^  [a-z-]+:/' 11_ci-public.yml` -> hub-suite,
   wui-suite, wui-e2e. The bash suites and the distribution-hygiene sweep run
   only in wf 10 after the merge, so a red they cause lands on trunk.
3. **Live-estate workflows act on OUR hosts from any repo.** 21 (probe +
   dispatch), 55 (tags from our prd `/version`), 68 (ZAP against our dev,
   `68_dast.yml:56-58`) read hosts from our cnf and need no secret, so an
   enabled fork runs them against our estate. 68 matters most: a third
   party's schedule would scan our dev under our 5 req/s cap.
   `grep -nE 'github\.repository ==|vars\.SPOOL_' *.yml | wc -l` -> 0: no
   workflow has an "is this our estate" guard.
4. **Deploy identity is named after us.** Secret `GCP_KEY_CSI_SPL_<ENV>` (5
   files), env list `dev prd` (4 places), cnf path `csi-spl-cnf/csi-spl/`
   (4 files). A fork that wants its own GCP deploy (path P2) must use our
   names or edit 9+ lines. Same root as 072 G9 (estate names in code).
5. **Stale runner headers.** `sed -n 2p 15_sec-deps-secrets.yml 85_actionlint.yml`
   both say "self-hosted (spool-ci)" while `grep -n runs-on` shows
   `ubuntu-latest`. A reader porting CI believes 2 more workflows need a box.

None of these is red on a fork's test jobs: blocker 1 is stuck, 2 is late, 3 is
unsafe for us, 4 and 5 cost edits.

## 3. Actions

Each is one lane. Effort: S < 2 h, M < 1 day.

| # | action | files | done when (a test can check) | effort |
|---|---|---|---|---|
| **C1** | **Runner from a repo variable** (refines 072 A13): every `runs-on` in 10 and 99 becomes `${{ vars.SPOOL_CI_RUNNER && fromJSON(vars.SPOOL_CI_RUNNER) \|\| 'ubuntu-latest' }}`; this repo sets `SPOOL_CI_RUNNER='["self-hosted","spool-ci"]'` once, through a named action `do_gh_set_ci_vars` (no hand `gh variable set`) | `10_ci-quality.yml`, `99_runner-smoke.yml`, one iac action + test | `grep -cE 'runs-on:.*self-hosted' .github/workflows/*.yml` -> 0 in every file; actionlint (wf 85) green; on this repo the next wf 10 run lists the same self-hosted runner names as before | S |
| **C2** | **Estate guard on live-estate workflows**: 00, 21, 22, 31, 40, 45, 55, 68 get a job-level `if: vars.SPOOL_ESTATE == 'true'` on their first job; this repo sets the var through the same action as C1 | 8 workflows + test | a new `csi-spl-iac/src/bash/tests/ci-estate-guard.tst.sh` fails when a workflow with `cron:` or a cnf-host read lacks the guard; a fork with no vars shows those workflows as **skipped**, not run | S |
| **C3** | **One hermetic gate for push and pull request**: move the 10 job bodies into a reusable `12_ci-suites.yml` (`workflow_call`, input `runner`); 10 calls it on `push: master` with the var runner, 11 calls it on `pull_request` and on `push` to any branch when `github.event.repository.fork` | 10, 11, new 12 | a pull request's checks list iac, orc, cnf and hygiene; the job names of 10 and 11 are the same set; wf 85 green | M |
| **C4** | **A static fork-portability test**: per workflow, assert (a) no literal self-hosted `runs-on`, (b) every job that reads `secrets.*` or `vars.GCP_*` has a skip path that prints `::notice::`, (c) C2's guard where needed | `csi-spl-iac/src/bash/tests/ci-fork-portable.tst.sh` | in `run-all-tests.sh` and green; a planted `runs-on: [self-hosted, x]` on a throwaway branch turns it red | S |
| **C5** | **Measure it once on a real fork** (closes "nobody has run CI on a fork"): a throwaway fork under a second account, Actions enabled, one push to `master` and one to a branch; record every workflow's verdict and wall time | a measurement file under spec 072 | a 25-row table with run ids, `n = 1`, tree sha; zero workflows queued or touching our hosts | S (after C1-C3) |
| **C6** | **Org-neutral deploy names**: secret `GCP_KEY_<ENV>` (the old name as fallback for one release), env list from cnf instead of `dev prd`, cnf path from `vars.SPOOL_CNF_DIR` defaulting to `csi-spl-cnf/<org>-<app>` | 00, 20, 30, 40, 45 | `grep -c 'GCP_KEY_CSI_SPL_' .github/workflows/*.yml` -> only the fallback lines; a fork deploying a third env edits no workflow | M; with 072 A8 |
| **C7** | **"CI on your fork" section** in `CONTRIBUTING.md`: what runs, what skips and why, the vars (`SPOOL_CI_RUNNER`, `SPOOL_ESTATE`, the WIF pair) and the one action that sets them; fix the stale headers of 15 and 85 in the same commit | `CONTRIBUTING.md`, 2 headers | `grep -c SPOOL_CI_RUNNER CONTRIBUTING.md` >= 1; `sed -n 2p 15_*.yml 85_*.yml` no longer says self-hosted | S |

### 3.1 The top three

1. **C1**, runner from a variable: the only thing that makes a fork's gate
   **stuck**; one line per job, zero behaviour change here.
2. **C3**, one gate for push and PR: a contributor gets all ten suites before
   merge instead of three, and 10 and 11 can no longer drift.
3. **C2**, estate guard: stops a fork from probing, tagging or scanning our
   estate, and makes the fork's Actions tab quiet (skipped, not run).

### 3.2 Cost, in numbers (ranked after DevEx, per the owner)

- GitHub-hosted standard runners are free for public repositories (GitHub's
  published policy; not measured here). C1 changes nothing on this repo: wf 10
  stays on our self-hosted runners through the variable, so the 2026-09-23
  spending-limit stop (wf 10 header lines 3-9: 76 runs that day) cannot recur
  from this change.
- C3 adds the bash suites to every pull request on hosted runners: $0 while
  the repo is public; 0 forks exist today (`forks_count: 0`).
- A fork pays nothing unless it is private; a private fork on hosted runners
  pays its own minutes, never ours.

## 4. Questions for the owner

1. **May wf 10 default to `ubuntu-latest` when the variable is unset?** This
   repo keeps the self-hosted runners through the variable. *Recommended: yes*
   (C1); a fork must never queue for ever.
2. **Should a contributor's pull request run the full gate (iac, orc, cnf,
   hygiene), not just hub and WUI?** *Recommended: yes* (C3), still behind the
   existing "approve outside contributors" setting.
3. **May a lane create one throwaway fork under a second GitHub account to
   measure C5?** It is outward-facing (a public fork). *Recommended: yes,
   once, deleted after the measurement*; without it every fork claim above
   stays "read from the YAML, not measured".
4. **Rename the deploy secret to an org-neutral `GCP_KEY_<ENV>` (C6)?**
   *Recommended: yes, with a one-release fallback*, sequenced with 072 A8, not
   before.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T07:16:00Z -->
