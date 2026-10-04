# 072 research 14: the open-source export (spec 044), what is left

Contributor: c-173. Brief: spec 072 section 9, sub-brief "14 oss-export".
Tree: `origin/master` @ `25eff27ca`, 2026-10-04 (n = 1 per command). Read-only:
no setting was changed, no GCP call was made, no key was read. `do_oss_export`
ran into a scratch dir outside the checkout and pushed nothing.
`<org>/<repo>` is the public repo, `<runner group>` the org runner group.

The question: spec 044 planned a gated export into a NEW public repo. What
of 044 still applies now the repo is public, what is still open (licence,
history hygiene, a public mirror, the contribution model), and what blocks a
stranger from contributing or self-hosting? The section 2 ranking of spec 072
(usability and DevEx first) orders the actions.

## 1. Today

### 1.1 Spec 044 was overtaken on 2026-09-28; its files do not say so

The owner chose **one repo, everything public, full history** (044 option A,
which 044 section 5 rejected) and the repo was flipped that morning. The
split was built and then reverted:
`git log -1 --format='%h %s' c33c08c9a` -> `revert(oss, SPL-61): drop the
ops-repo split - the owner (2026-09-28): one repo, everything public`.

| what 044 still says | check | the truth |
|---|---|---|
| status "In progress", option C a NEW public repo | `sed -n 3p csi-spl-doc/specs/044-spool-open-source/spec.md` | the existing repo is public: `gh repo view --json visibility` -> `PUBLIC` |
| the flip is a task | `grep -c '^- \[x\]' .../044-spool-open-source/checklist.md` -> 0 | done; only section 8 records it: `grep -n 'one repo' .../spec.md` -> line 185 |
| specs index row: "a gated one-time export into a NEW public repo" | `grep -n '044-spool-open-source' csi-spl-doc/specs/README.md` -> line 134 | stale |

A reader of 044 today plans work that is moot (T033, T040, T050, T052, D1, D8).

### 1.2 The public repo, measured

GitHub reads used `gh api repos/{owner}/{repo}/...` (read only); the settings
check is `OSS_PUBLIC_REPO=<org>/<repo> OSS_RUNNER_GROUP=<runner group>
DRY_RUN=1 ./run -a do_oss_public_settings` -> 9 x `OK`, exit 0.

| area | check | result |
|---|---|---|
| licence | `head -2 LICENSE`; `gh repo view --json licenseInfo` | AGPL-3.0, detected by GitHub as `agpl-3.0` |
| WUI manifest | `grep -n license csi-spl-wui/package.json` | `"AGPL-3.0-only"` (line 5), still `"private": true` (line 4) |
| Go SPDX headers | `git grep -l SPDX-License-Identifier origin/master -- 'csi-spl-api/*.go' \| wc -l` | **1 of 669** `.go` files |
| third-party notices | gate class `licence` (1.4) | `THIRD-PARTY-NOTICES.md` missing; the icon set's notice (044 3.3) still absent |
| asset licence | `cat csi-spl-orc/cnf/oss/licensed-assets.txt` (comments only); `ls LICENSE-ASSETS.md TRADEMARK.md` | no asset licence, no trademark file; 16 images in the WUI |
| community files | `gh api .../community/profile` | health **75 %**: README, LICENSE, CONTRIBUTING, CODE_OF_CONDUCT present; `issue_template` and `pull_request_template` null |
| security reporting | `gh api .../private-vulnerability-reporting` | `{"enabled":true}`; `SECURITY.md` points at it |
| prompt allow-list limitation (044 D10) | `grep -ciE 'allow\|prompt\|agent' SECURITY.md` | **0**: the limitation 044 promised to state is not stated |
| secret scanning | `gh api .../secret-scanning/alerts --jq '.[]\|{state,secret_type,created_at}'` | **1 open** since `2026-09-28T07:44:19Z`, 21 s after the flip: a `linkedin_client_secret` pattern at `csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh:36` (commit `3c388d94f`). Read with values truncated: a synthetic `WPL_AP...$RANDOM` test value, a false positive nobody triaged in 6 days |
| branch protection | `gh api .../branches/master/protection`; `.../rulesets --jq length` | `404 Branch not protected`; **0** rulesets |
| fork PR CI | `do_oss_public_settings` | fork runs wait for approval (`all_external_contributors`); no PR-triggered job reaches a self-hosted runner; token read-only |
| workflows by runner | `grep -cE '^\s*runs-on:.*self-hosted'` per file | wf 10: 10 jobs, wf 99: 1, all others hosted; wf 11 (the PR CI) has `pull_request` and 0 self-hosted |
| wf 11 verdicts | `gh run list --workflow 11_ci-public.yml --limit 40` | 25 success, 4 failure, 11 in progress |
| standalone stack | `gh run list --workflow 50_oss-standalone.yml --limit 3` | 3 x success (compose up on `ubuntu-latest`, no GCP) |
| outside contributions | `gh pr list --state all`; `gh api repos/{owner}/{repo} --jq .forks_count` | 0 forks, 0 stars; 1 human PR (closed at the flip, unmerged); **15 dependabot PRs open since 2026-09-30**, none merged (github_actions, go_modules, npm) |
| dependabot | `security_and_analysis.dependabot_security_updates` | `disabled` (version updates on via `.github/dependabot.yml`) |

### 1.3 History hygiene

| class | check | result |
|---|---|---|
| live credentials, whole history | `gitleaks git --redact --config .gitleaks.toml --log-opts=origin/master .` | **0 leaks, 3210 commits**, 3.4 s |
| live credentials, working tree | `gitleaks dir --redact --config .gitleaks.toml .` | 0 leaks |
| commit identity | `git log origin/master --no-mailmap --format='%ae %ce' \| sort -u \| wc -l` | **1** identity on every commit; no `.mailmap` needed |
| AI trailers (anchored grep, CLAUDE.md 5.1) | the loop over `git log --format=%H` with `grep -qiE '^(Co-Authored-By:\|Claude-Session:)'` | **0** |
| DCO sign-offs on our own commits | `git log origin/master -300 --format=%B \| grep -c '^Signed-off-by:'` | **0**, while CONTRIBUTING line 40 says "a pull request with an unsigned commit is not merged" |

The history needs no rewrite. Identifying data (owner quotes, fleet ids,
estate values in cnf) is public by the owner's choice, not a leak.

### 1.4 The export gate on today's trunk

`OUT_DIR=/var/tmp/<scratch>/spool OSS_REF=origin/master ./run -a do_oss_export`
(from `csi-spl-orc`) -> `exported 2053 file(s) of 11 allow-list path(s) at
25eff27ca`, then the gate: **exit 2, TOTAL 1608**.

| class | hits | where (report: class, path, line, never the value) |
|---|---|---|
| fleet-id (3+ digit ids) | 1587 | wui 951, api 583, rdb 48, `.github` 4, compose 1 |
| image-unlicensed | 16 | `csi-spl-wui/src/public/**` (wallpapers, emblem, icons) |
| gcp-sa | 2 | `internal/hub/operator_test.go:19,65` |
| private-host | 1 | `internal/store/flow_mentions_test.go:134` |
| tenant-data | 1 | `internal/hub/replay_unsigned.go:19` (non-test code) |
| licence | 1 | `THIRD-PARTY-NOTICES.md` missing |
| secret, other-org, hygiene, box-path, gcp-org, ci-runner | 0 each | - |
| dep-licence npm | **not measured** | `ERROR no node_modules matching the exported pnpm-lock.yaml`: the gate fails closed when the worktree has no install |

Two defects of the gate itself: the report's `# src=` line stamps the
checkout's HEAD (`oss-gate.func.sh:178` `git -C "$APP_PATH" rev-parse HEAD`),
not `OSS_REF` (this run: `src=e3b1627ef` for an export of `25eff27ca`); and no
workflow runs it: `git grep -c do_oss_ origin/master -- .github` -> 0. With the
repo public as a whole, the export is no longer the publishing path, but its
classes are still the best "is product code estate-neutral" measure that P1/P2
strangers need (spec 072 G9). Drift since 044 3.2, with 044's own pattern:
`git grep -lE '(CLE|HUM|AGY|GRK)-[0-9]+' origin/master -- csi-spl-api csi-spl-wui csi-spl-rdb | wc -l`
-> **947** files (044: 472).

### 1.5 Checklist 044, row by row, against the one-repo reality

Status words per `csi-spl-doc/specs/README.md` section 2.3.

| row (044 `checklist.md`) | status | proof |
|---|---|---|
| 1.1 decisions D1-D8 recorded | **Partial** | D0, D11 in spec 6.1; the one-repo choice only in section 8; D2 is AGPL de facto (LICENSE), D3 DCO de facto (CONTRIBUTING:28) |
| 1.2 export from an allow-list | Implemented | `do_oss_export` above; list `csi-spl-orc/cnf/oss/export-allow-list.txt` |
| 1.3 gate exit 0, negative control exit 1 | **Partial** | gate exit 2 (1608); control: `csi-spl-orc/src/bash/tests/oss-export-gate.tst.sh` |
| 1.4 gitleaks 0 on the export | Implemented | 0 over history and tree (1.3) |
| 1.5 fleet ids scrubbed (T027) | **Planned** | 1587 hits; `git grep -lP '\b(CLE\|HUM\|AGY\|GRK)-[0-9]{3,}\b' origin/master -- csi-spl-api csi-spl-wui csi-spl-rdb \| wc -l` -> 628 files |
| 1.6 SA / org-id / fleet / `/opt/` grep -> 0 | **Partial** | gcp-sa 2, fleet 1587, box-path 0, gcp-org 0 |
| 1.7 no other-org, personal names, owner e-mail | Implemented (export) | other-org 0, hygiene 0 |
| 1.8 no cnf / CLAUDE.md / specs in the export | Moot | the whole repo is public (owner) |
| 1.9 LICENSE, `package.json`, SPDX, notices | **Partial** | LICENSE + manifest yes; SPDX 1/669; notices missing |
| 1.10 README, CONTRIBUTING, SECURITY, CoC, templates | **Partial** | templates missing (community profile) |
| 1.11 no self-hosted for PRs, read-only token | Implemented | `do_oss_public_settings` 9 x OK |
| 1.12 `docker compose up` with no GCP | Implemented | wf 50, 3/3 success |
| 1.13 untrusted-input rule (T025) | **Planned** | `git grep -li untrusted origin/master -- SECURITY.md CONTRIBUTING.md csi-spl-doc/doc` -> 1 file, the identity-routing spec, not the rule |
| 1.14 target repo PRIVATE | Moot | flipped public |
| 2.1 stranger test | **Partial** | 047 1.1: one agent run, 6 min 26 s (n=1); 0 outside testers |
| 2.2 `asOperator` review (T026) | **Planned** | 044 `tasks.md` T026 `[ ]` |
| 2.3 DB tier review (T042) | **Planned** | T042 `[ ]` |
| 2.4 CLA/DCO chosen, bot configured | **Partial** | DCO in CONTRIBUTING; no check: `git grep -li 'signed-off\|dco' origin/master -- .github` -> 0 |
| 2.5 policy in CONTRIBUTING, branch protection | **Partial** | policy lines 14-16; protection 404, rulesets 0 |
| 2.6 SECURITY.md states the allow-list gap | **Planned** | 0 hits (1.2) |
| 3.x the flip | Implemented | 2026-09-28; ops-by-ref (D8) moot |

## 2. Blockers

1. **044 misleads its readers.** Header, checklist and README index row still
   describe a private repo and a new export repo (1.1). A lane that reads it
   plans moot work. `sed -n 3p .../044-spool-open-source/spec.md`.
2. **No branch protection on a public trunk.** `gh api .../branches/master/protection`
   -> 404, rulesets 0. Only GitHub write permission stops a bad push; any
   collaborator token, or a leaked token with write, lands on master
   unreviewed. Contingency (044 `contingency.md`) assumes trunk is trustworthy.
3. **An open secret-scanning alert, untriaged for 6 days** (1.2). It is a
   synthetic test value, but an open alert on a public repo reads as a leak to
   every visitor, and it hides a real one: alert triage is contingency 1.1.5,
   still GAP T070.
4. **The DCO rule is stated and not enforced, and our own commits break it.**
   CONTRIBUTING:40 refuses unsigned PRs; 0 of the last 300 trunk commits are
   signed off; no check exists. A contributor reads it as arbitrary.
5. **SECURITY.md does not state the prompt allow-list gap** that 044 D10 made
   the condition for shipping without FR-OS-017 (`grep -ci allow SECURITY.md` -> 0).
6. **Licence hygiene incomplete**: no `THIRD-PARTY-NOTICES.md` (the ISC icon
   notice, `csi-spl-wui/src/utils/uiIcons.ts:1`), no asset licence or
   `TRADEMARK.md` for 16 images and the name, SPDX on 1 of 669 Go files.
7. **No issue or PR templates** (community profile 75 %): an outside report
   arrives without version, path (P1/P2/P3) or tree, which spec 072 needs.
8. **15 dependabot PRs open for 4 days, 0 merged** (1.2). On a public repo
   that is the most visible maintenance signal, and the first thing a
   prospective self-hoster checks.
9. **The gate is not in CI, its npm leg needs a local install, and it stamps
   the wrong sha** (1.4, `oss-gate.func.sh:178`). Product code drifts back
   toward the estate unseen: 472 -> 947 files citing a fleet id since 044 3.2.

## 3. Actions

Effort: XS < 0.5 day, S <= 1 day, M 2-5 days. Ranked by spec 072 section 2:
what a stranger or contributor meets first. Cost: every action is $0 in
cloud spend; GitHub-hosted minutes for a public repo are free under GitHub's
public-repo terms (their terms, not measured here). The only cost is lane time.

| # | action | lane owns | effort | done when (a test or command can check it) | changes |
|---|---|---|---|---|---|
| **O1** | Restate 044 for the one-repo reality: header status, a "superseded by the owner, 2026-09-28" note on section 5 and D1/D8, checklist rows 1.8/1.14/3.x marked moot, T033/T040/T050/T052 closed as moot, the README index row | `csi-spl-doc/specs/044-*/`, one row of `specs/README.md` | XS | `grep -c 'NEW public repo' csi-spl-doc/specs/README.md` -> 0; the checklist has a ticked flip row citing `c33c08c9a` | blocker 1 |
| **O2** | `do_oss_public_settings` also checks and (DRY_RUN=0, owner's go) sets a master ruleset: no force-push, no deletion, required status = wf 11, PRs need 1 maintainer review, the fleet's push identity may bypass (it pushes to trunk directly) | `oss-public-settings.func.sh` + its test | S | the action prints `OK master ruleset ...`; its test stubs a repo with no ruleset and reads `FAIL` | blocker 2 |
| **O3** | Triage the alert: close it as `false_positive` with a reason, and make the fixture not match the provider pattern (assemble the value at runtime); add the open-alert count to `do_oss_public_settings` (folds the 1.1.5 part of T070) | the test file, `oss-public-settings.func.sh` | XS | `gh api .../secret-scanning/alerts --jq '[.[]\|select(.state=="open")]\|length'` -> 0, and the action reads it | blocker 3 |
| **O4** | Make the DCO honest: a hosted DCO check on `pull_request` in wf 11 for fork commits, or CONTRIBUTING drops the rule (owner Q2) | `11_ci-public.yml` or `CONTRIBUTING.md` | XS-S | a fork PR with an unsigned commit fails wf 11 with "add Signed-off-by"; a signed one passes | blocker 4 |
| **O5** | SECURITY.md: one "Known limitation" paragraph (any tenant member can prompt any agent of that tenant until FR-OS-017; outside text never reaches an agent, FR-OS-015) | `SECURITY.md` | XS | `grep -cE 'FR-OS-017\|prompt allow-list' SECURITY.md` >= 1 | blocker 5 |
| **O6** | Licence completion: `THIRD-PARTY-NOTICES.md` (icon set ISC + the Go/npm list from the gate's dep-licence leg), `LICENSE-ASSETS.md` + `TRADEMARK.md` (owner Q3), fill `licensed-assets.txt`, an SPDX header on every Go file with a test | root files, `csi-spl-orc/cnf/oss/licensed-assets.txt`, a Go header test | S | gate classes `licence` and `image-unlicensed` -> 0; `git grep -L SPDX-License-Identifier -- 'csi-spl-api/*.go' \| wc -l` -> 0 | blocker 6 |
| **O7** | Issue templates (bug: path P1/P2/P3, `/version`, tree, OS; feature) and a PR template (DCO line, test run, which cheap gate) | `.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md` | XS | `gh api .../community/profile --jq .health_percentage` -> 100 | blocker 7 |
| **O8** | Dependabot cadence: group updates per ecosystem in `.github/dependabot.yml`, turn on security updates, a weekly lane merges or closes bot PRs | `.github/dependabot.yml` | XS + weekly | `gh pr list --author app/dependabot --json createdAt` -> none older than 7 days | blocker 8 |
| **O9** | The gate as a hosted job in wf 11 on product paths, in **ratchet** mode (fail when a class count rises above a committed baseline, like the shellcheck ratchet), npm leg after `pnpm install --frozen-lockfile`; the `src=` stamp reads `OSS_REF` | `11_ci-public.yml`, `oss-gate.func.sh`, a baseline in `csi-spl-orc/cnf/oss/` | S | a PR adding one 4-digit fleet id in `csi-spl-api` fails wf 11 naming class + file + line; report `src=` equals the exported sha | blocker 9, 072 G9 |
| **O10** | T027 per package in waves (wui, api, rdb) driving the O9 baseline to 0; the 4 non-fleet hits first (2 SA e-mails, 1 host, 1 tenant slug in non-test code) | per-package lanes | M (1587 hits) | O9 baseline `fleet-id` -> 0, then the ratchet becomes a hard gate | 044 T027 |
| **O11** | The untrusted-input rule (T025) as a short doc in `csi-spl-doc/doc/md/`, linked from SECURITY.md and CONTRIBUTING, before any issue-to-fleet bridge (T060) | one new doc + 2 links | XS | `git grep -l 'FR-OS-015' -- SECURITY.md CONTRIBUTING.md \| wc -l` -> 2 | 044 T025 |

### 3.1 Top three

1. **O2** master ruleset: the one control a public repo lacks that GitHub
   gives for free; contingency's premise is that nobody else writes trunk.
2. **O3 + O5 + O7** (all XS, one lane): what every first visitor sees: an
   open "secret" alert, no stated limitation, no templates.
3. **O9** the gate in CI as a ratchet: stops estate names growing back into
   product code, which spec 072 A7-A9 (P2 for any org) depend on.

### 3.2 Public mirror: not recommended

A second, curated public repo (044 option C) is what the owner reverted
(`c33c08c9a`). The DevEx gain a mirror would bring (a product-only clone, no
fleet tooling) is better reached by spec 072 A1/A4 (prebuilt images and CLI):
a stranger then needs no clone at all. Recommend: no mirror, and 044 section
5 marked superseded (O1).

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Turn on a master ruleset (no force-push, no delete, wf 11 required, 1 review for PRs; the fleet's push identity may bypass)? | **yes** (O2). It changes nothing for the fleet's direct pushes and closes the unreviewed-merge path |
| Q2 | DCO: enforce it on outside PRs with a check, or drop the rule? | **enforce on outside PRs only** (O4): one identity holds every commit today, so a later relicence stays possible; a DCO keeps provenance once outsiders land code. A CLA (044 D3) only if dual licensing is ever wanted |
| Q3 | An asset licence for the logo and wallpapers, and a `TRADEMARK.md` for the name? | **yes**: assets under a no-derivatives licence (forks rebrand), the name reserved in `TRADEMARK.md` (044 D7) |
| Q4 | Who merges dependabot PRs: a weekly fleet lane, or the owner? | **a weekly fleet lane** (O8), grouped PRs, merged when wf 11 is green |
| Q5 | Close spec 044 as Implemented-with-exceptions and move its open tasks (T025, T026, T027, T042, T070-T079) into 072 or their own specs? | **yes** (O1): one owner per open item, no dead plan in the tree |
