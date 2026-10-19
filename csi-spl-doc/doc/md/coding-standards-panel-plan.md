# Coding standards panel - plan (developer guide + spec-kit constitution)

Epic: SPL-2402
Issue: SPL-2537
Spec: csi-spl-doc/specs/135-work-process
Kind: specs_and_docs

Status: **v1.1, SIGNED (consensus)** (Claude seat c-337 signed v1.1 at a82a2069f; Mistral seat m-353 signed v1.1 at 9e7aef4cb/d303b8857).
Editor seat: **a-330** (agy).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16).
Baseline commit: **`4453459bbde498b0c88c2a9fcf899e37acc28889`** (`origin/master` at lane start, 2026-10-19T09:41Z).
Reviewed v0.1 commit: **`ea33f0ed268e33029d0feef89b4cd0a357c64abe`**.
Reviewed v0.2 commit: **`b776859b91e3b6ef068fa21fcfd52dc15bfc79e8`**.

## 0. Context and owner orders

Owner HUM-10, t1 topic `2402f33e-5ab4-46bf-83ab-ee7e8f603806`:
- msg ad01a506 (2026-10-19T09:2xZ): *"let's reviit the consitution of the git-spec and combine it with oour Developer Guide and improve on the overall Coding Standards which each CODING agents must follow"*
- msg 477b0565 (2026-10-19T09:2xZ): *"the primary work should go into the Coding Standards section of the Developer Guide , and than exported as part of the constition of the git-spec"*

**Core architectural requirement:**
1. The developer guide (`csi-spl-doc/doc/md/developer-guide.md`, export of Qto doc `c65bbfbd-bc33-4ac6-9d66-dc36a71bf948`) becomes the primary single source of truth for all coding standards and rules governing human and agent coders.
2. The spec-kit constitution (`csi-spl-doc/.specify/memory/constitution.md`) carries that Coding Standards section by automated export (via a named `./run` action), eliminating hand-maintained duplication and drift.
3. The export chain is explicit and linear:
   - Step 1: Qto doc `c65bbfbd` -> `developer-guide.md`, written by `do_spl_doctree_export_md` and checked by `check-qto-doc-drift`.
   - Step 2: `developer-guide.md` -> the constitution block, written by `do_spl_export_constitution_coding_standards` and checked by drift fact 8.
   - Coders edit only the Qto doc; derived markdown files are updated exclusively by automated export actions.
4. A drift check ensures the constitution's exported section never diverges from the developer guide.

---

## 1. Inventory of current coding rules (measured on `4453459bbde498b0c88c2a9fcf899e37acc28889`)

Every coding rule currently binding a coding agent in this repository was inventoried across the primary sources:
1. Spec-kit constitution (`csi-spl-doc/.specify/memory/constitution.md:1-217`)
2. Developer guide (`csi-spl-doc/doc/md/developer-guide.md:1-270`)
3. Repo instructions (`CLAUDE.md:1-152` / `AGENTS.md:1-11`)
4. Fleet rules index (`csi-spl-doc/doc/md/fleet-rules-index.md:1-78`)
5. Lane seed prompt templates (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:273-356,527`)
6. Distribution hygiene workflow & action (`.github/workflows/10_ci-quality.yml:1349-1460`, `csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh:24-64`)
7. Quality and lint gates (`csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:1-100`, cleancode tests, i18n gates)

*Note on constitution version:* The body of `constitution.md` currently reads `**Version**: 0.2.0` while the trailing footer metadata comment reads `version: 0.2.1`. Build row 06 resolves this inconsistency and establishes automated version bumping.

### 1.1 The primary inventory table (Rows 01–22)

| # | Rule name & category | What it requires | Primary home today | Duplicates & references | Contradictions, drift & gaps | Enforcing gate or status |
|---|---|---|---|---|---|---|
| 01 | **Truth first** | Speak the truth 100% of the time. Verify every statement empirically before making it. Never report done before it is true. | `csi-spl-orc/src/bash/features/spawn-agents/assets/seed-truth-rule.txt:1` | `fleet-rules-index.md:31` (`grep -c`: 1); rendered into every agent seed (`spawn-core.inc.sh:527`). | Missing entirely from both `constitution.md` and `developer-guide.md`. | Guard: `test-seed-truth-first.sh`. Not automated in code review. |
| 02 | **Canonical path layout** | Sub-projects live at `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`. Paths derived from filesystem location, no hard-coded paths. Kinds: `api`, `wui`, `iac`, `cnf`, `utl`, `orc`, `dat`, `doc`. | `csi-spl-doc/.specify/memory/constitution.md:33-49` (Principle I) | `CLAUDE.md:7-17` (`grep -c`: 1). | `constitution.md:38` describes `csi-spl-wui` as "lightweight task and thread viewer web app" (now Nuxt 3 full WUI). | Gate: `no-box-path-source.tst.sh`. |
| 03 | **Environment fail-fast configurability** | External URLs, hosts, buckets, GCP accounts overridable via env vars. Shell actions fail fast if missing (`: "${VAR:?error}"`). No default hostnames in code. | `csi-spl-doc/.specify/memory/constitution.md:50-64` (Principle II) | `CLAUDE.md:20-26` (`grep -c`: 1). | Placeholder `<<run-time>>.csitea.net` used in constitution, while `all.env.yaml` defines `BASE_DOMAIN`. | Code review; shell action parameter validation. |
| 04 | **run-bsh action convention** | Operator behaviour exposed as `do_<verb>_<noun>` Bash functions in `src/bash/run/<name>.func.sh`, dispatched via `./run -a do_<name>`. Metadata tags `@description`, `@param`, etc. | `csi-spl-doc/.specify/memory/constitution.md:65-71` (Principle III) | `CLAUDE.md:47-63` (`grep -c`: 2). | Constitution cites `csi-spl-iac/src/bash/run/<group>/<name>.func.sh`, while actual layout places groups flat in `src/bash/run/` across `iac`, `orc`, `utl`. | Framework `run.sh` action loader; `bash-cleancode.tst.sh`. |
| 05 | **Spec-driven development** | No runtime code written without corresponding artifact under `csi-spl-doc/specs/<NNN-slug>/`: specify, clarify, plan, tasks, analyze, implement. | `csi-spl-doc/.specify/memory/constitution.md:72-81` (Principle IV) | `lane-issue-and-docs.md:89-150` (SPL-2355) (`grep -c`: 1). | Constitution does not mention the mandatory Epic + Git Spec link required by SPL-2355 / HUM-10 order. | Gate: `do_spl_spawn_enqueue` & `spawn-window.sh` (exit 12). |
| 06 | **Distribution hygiene** | Public repository: org-neutral (`csi`/`csitea`/`csitea.net` only). No non-Csitea org or bank references, no personal names, no literal developer/agent OS usernames, no machine/box identifiers, no personal home directory paths. Authorised carve-out: git commit metadata. | `.github/workflows/10_ci-quality.yml:1349-1460` | `constitution.md:82-104` (Principle V); `check-dist-hygiene.func.sh:24-64`; `spawn-core.inc.sh:527`. | Minor drift: `constitution.md:94-96` suggests `<CONFLUENCE-SPACE>` and `<JIRA-PROJ-CODE>`, which are unused (all issues are `SPL-n`). | Gate: `do_check_dist_hygiene`, CI job `distribution-hygiene`. |
| 07 | **Cnf single source of truth** | No hardcoded runtime configuration in code. Author in `csi-spl-cnf/csi-spl/<env>.env.yaml`. Generated twins (`.env.json`, `*.tfvars`) re-rendered in same commit via `do_tpl_gen`. | `csi-spl-doc/.specify/memory/constitution.md:105-113` (Principle VI) | `CLAUDE.md:13,103`; `plan-template.md:45-48`. | In `plan-template.md:46`, stale copy says `csi-rel-cnf/csi-rel/<env>.env.yaml` instead of `csi-spl-cnf`. | Gate: `git diff --exit-code` after `do_tpl_gen`; `check-qto-doc-drift`. |
| 08 | **Secrets, SA keys & GCP authentication** | Service accounts only per env. SA keys minted out-of-band, chmod 600, under `$HOME/.gcp/.csi/key-csi-spl-<env>.json`. No keys in git, TF state, or logs. Every gcloud call carries `--account` or throwaway `CLOUDSDK_CONFIG`. | `CLAUDE.md:28-46,88-92` | `constitution.md:114-125` (Principle VII); `fleet-rules-index.md:34`. | Constitution refers to "the relay bucket + SA" (`constitution.md:40`) and "relay SA key" (`constitution.md:117`), which were retired in SPL-1910; current setup uses env project keys `key-csi-spl-<env>.json`. | Gates: `gcloud-account-pinned.tst.sh`, `lint-gitleaks`, `lint-trufflehog`. |
| 09 | **Uniform box API & agent ID grammar** | All agents talk through same verbs, tool names, JSON v:1, and schema. No per-vendor endpoints. Agent ID grammar: `^[acgmq]-[0-9]{3}$`. | `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:100` (`SPOOL_AGENT_ID_NEW_RX`) | `constitution.md:126-133` (Principle VIII); `fleet-rules-index.md:33`; spec 061 §0. | **Direct contradiction:** `constitution.md:127` lists obsolete format `CLE-*`, `GRK-*`, `AGY-*`. Spec 061 and current fleet use `c-`, `g-`, `a-`, `q-`, `m-`. Drift fact 1 does not read the constitution today; fact 1 must include `constitution.md` in `_frd_sources`. | Gate: `do_check_fleet_rules_drift` (fact 1: `_frd_id_letters`). |
| 10 | **Clean code & function limits (80 lines, depth 4)** | Language-specific limits: Go: `maxFuncLines = 80`, `maxDepth = 4`, `maxParams = 8`, `SELECT *` forbidden, folded singletons; WUI (TS/Vue): `maxFuncLines = 80`, `maxDepth = 4`, `maxParams = 6`; Bash: line cap only (`MAX_LINES=80` plus `LONG` ceiling list in `bash-cleancode.tst.sh`), no depth or parameter cap. | `csi-spl-api/.../cleancode/cleancode_test.go:17-41` | `csi-spl-iac/.../bash-cleancode.tst.sh:15-30`; `csi-spl-wui/.../cleancode.test.mjs:27-37`. | **Major gap:** This binding standard is enforced across Bash, Go, and TypeScript/Vue, but was **completely missing** from `constitution.md`, `CLAUDE.md`, and `developer-guide.md`. The guide must state what is measured per language without retyping lists. | Gates: `bash-cleancode.tst.sh`, Go `TestCleanCodeGate`, WUI `cleancode.test.mjs`. |
| 11 | **UI text and internationalization (i18n)** | No literal hardcoded text in UI templates, dialogs, or user-facing attributes. Use translation keys `t('key')` / `$t('key')`. Key parity across all locales. Untranslated and raw text baseline ratchets. | `csi-spl-doc/doc/md/developer-guide.md:130-155` (Section 2.4) | `csi-spl-wui/src/node/i18n/i18n-gates.mjs`; `fleet-rules-index.md:36`. | Missing from `constitution.md`. Mentioned only in Developer Guide. | Gates: `i18n-untranslated.test.mjs`, `i18n-no-raw-text.test.mjs`, `i18n-parity.test.mjs`. |
| 12 | **Pre-push lint suite** | Touched files must pass scanner suite before pushing: 19 fast linters (`check-pre-push-lint.func.sh:9-48`: syntax, migration, compose, gitleaks, py, tf, wui-syntax, wui-lock, shellcheck, actionlint, hadolint, eslint, trufflehog, mdlinks, typos, semgrep, gomod, sigpipe, tmp-path). `lint-typos` is WARN only. | `csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:1-100` | `CLAUDE.md:94-117`; `developer-guide.md:122-128`; `pre-push-gate.md`. | The guide must state the requirement and point to the gate file, rather than copying the 19-tool list which drifts from code. | Gate: `do_check_pre_push_lint` (hooked into `do_check_pre_push`). |
| 13 | **Trunk-based workflow & small commits** | Single trunk `master`. Linear history via rebase, no PRs in fleet. Small commits with explicit pathspecs on `add` (`git add <path>...`, `git commit` with no pathspec). Never `git add -A` / `commit -a`. Executables require both `chmod +x` and `git add --chmod=+x`. | `csi-spl-doc/doc/md/developer-guide.md:19-35,95-104` | `constitution.md:181-190`; `spawn-core.inc.sh:301`; `lane-integration-rules.md:16-53`. | None; well-aligned across sources. | Gate: pre-push hook; code review. |
| 14 | **Rebase before push & background push** | Rebase onto latest `origin/master` before every push (`git fetch`, `git rebase origin/master`, re-test). Push using background action `do_spl_push_master` and poll `PUSH_CMD=status`; never foreground push. | `csi-spl-doc/doc/md/developer-guide.md:106-120` | `spawn-core.inc.sh:301` (`grep -c`: 1); `lane-integration-rules.md:55-83,119-155`; `fleet-rules-index.md:43`. | None. | Gate: pre-push hook; `do_spl_push_master`. |
| 15 | **Never force-push or delete master** | No force-push (`--force`, `--force-with-lease`, `+ref`) or deletion of master without explicit owner approval for that one push. `SPL_PREPUSH_OVERRIDE` never bypasses a refused push. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:282` (`NO_FORCE`) | `developer-guide.md:166-185` (Section 3); `lane-integration-rules.md:97-117`; `fleet-rules-index.md:44`. | None. | Gates: GitHub ruleset `master-no-force`, pre-push hook, `force-push-guard.inc.sh`. |
| 16 | **Commit identity & no AI trailers** | Commits carry author's real identity matching repo `CLAUDE.md` "Commits:" line. Pass identity to commit AND rebase. No `Co-Authored-By:`, `Generated with`, or AI session links. | `CLAUDE.md:139-140` | `developer-guide.md:157-164` (Section 2.5); `spawn-core.inc.sh:301`; `lane-integration-rules.md:173-211`. | `constitution.md:186` uses a placeholder in shippable examples; the real identity lives in git metadata and `CLAUDE.md`. Point to `CLAUDE.md` "Commits:" line (pinned by drift fact 7 `_frd_commit_address`). | Gate: pre-push hook `%ae %ce` check (`_sp_leak_gate`), drift fact 7. |
| 17 | **Issue tracking and docs coupling** | Every change rides an issue. Cite key in commit subject scope (`feat(<area>, SPL-n): ...`) or `Closes: SPL-n`. Code behaviour changes must land with `csi-spl-doc/` update or `Docs: none (<why>)`. | `csi-spl-doc/doc/md/lane-issue-and-docs.md:1-232` | `developer-guide.md:57-90` (Section 1.4); `fleet-rules-index.md:41`; `spawn-core.inc.sh:327-340`. | None. | Gate: `kill-your-self-report.sh --gate` (`li_gate`). |
| 18 | **Release version minting** | Release version is minted by `do_release_version` (`v<X.Y.Z>` tag), never edited by hand. Base `.version` raised only for major milestone jumps. | `csi-spl-doc/doc/md/developer-guide.md:48-55` (Section 1.3) | `CLAUDE.md:131-138` (`grep -c`: 1); `release-version.func.sh:1-40`. | None. | Gate: CI release pipeline; release version action. |
| 19 | **Dev always equals or leads prd** | Infrastructure and code changes apply/deploy to dev first, proven on dev, then prd. Prd apply refused if dev has pending changes. | `csi-spl-doc/doc/md/fleet-rules-index.md:54` | `CLAUDE.md:78-81`; `check-dev-leads-prd.func.sh`; `check-env-order.func.sh`. | Missing from `constitution.md` and `developer-guide.md`. | Gate: `do_tf_plan_pending` (exit 3), cron `do_check_env_order`. |
| 20 | **Stay in your own lane & scope control** | Work strictly within brief scope. Blocker outside scope: fetch fresh, check lane map (`lane-map.sh --check`). If unowned, fix in separate narrow commit. | `csi-spl-orc/.../claude-md/25-stay-in-your-lane.md` | `fleet-rules-index.md:40`; `spawn-core.inc.sh:302`; `lane-integration-rules.md:229-237`. | Missing from `constitution.md`. | Gate: `lane-map.sh --check` (exit 3/4). |
| 21 | **Package installation via named action** | Agents install packages only via `cd csi-spl-iac && BOX_PKG=<pkg> BOX_PKG_REASON="<why>" AGENT_ID=<id> ./run -a do_box_pkg_install`. Action records all installs. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:287` (`SEED_BOX_PKG`) | `fleet-rules-index.md:45`; spec 142 §5. | Missing from `constitution.md` and `developer-guide.md`. | Guard: `test-seed-box-pkg.sh`; action logging. |
| 22 | **Rounds rulebook standards (R1–R16)** | Refactoring and bug rounds capped at 10 items; 1–3 pushes per item (max 5); disjoint files per batch (R1); cross-vendor review evidence (R7); red controls for gates. | `csi-spl-doc/doc/md/rounds-rulebook.md:1-168` | `fleet-rules-index.md:47`; `SPEC-spool-project-refactor.md`. | Missing from `constitution.md`. | Review evidence gate `do_spl_review_line_check`. |

---

### 1.2 Additional binding rules identified in panel review (M1–M8)

The following eight binding rules were identified by reviewer seat `c-337` (`seat-claude.md:58-68`). Each binds a coding agent today, has an existing test or owner rule, and was missing from the initial inventory. All are adopted into the Developer Guide:

| # | Rule name & scope | What it requires | Primary home today (checked) | Enforcing gate | Adoption in Developer Guide |
|---|---|---|---|---|---|
| M1 | **Tenant table RLS policies** | Every tenant table carries a Row-Level Security (RLS) policy; queries execute strictly inside the tenant scope. | `csi-spl-api/src/go/spool-hub-api/internal/store/rls.go` | `TestRLSCoversEveryTenantTable` (`rls_test.go:76`), `TestRLSControl` (`:111`), `rls_failclosed_test.go` | Adopted: Subsection 2.6.4 & 2.12.4 |
| M2 | **Forward-only PG16 migrations** | An applied migration is never edited, renamed, or deleted; a new migration continues the head (`<head+1>_<name>.sql`) and parses cleanly on PostgreSQL 16. | `check-pre-push-lint.func.sh:12-17` (`lint-migration`) | `lint-migration`; `PRE_PUSH_TIER=full` for store or migration changes | Adopted: Subsection 2.8.3 & 2.12.4 |
| M3 | **Named infra action plus test** | Every infra step is a named `./run` action (`do_<verb>_<noun>`) **plus its test in the same commit**; nothing ad hoc. | `CLAUDE.md:47-63` | Code review; pre-push test suites | Adopted: Subsection 2.4.5 |
| M4 | **Terraform container isolation & owner go** | Terraform runs exclusively within the `tf-runner` container. Nothing mutates GCP (create, billing, IAM, apply) without explicit owner go. | `CLAUDE.md:66-71` | `do_tf_init` container wrapper; owner approval | Adopted: Subsection 2.6.5 |
| M5 | **Red controls for tests and gates** | Every test or gate must ship with a demonstrated red control (seen RED, then GREEN). A control that would turn master red runs on a throwaway branch. | `rounds-rulebook.md:100` (C2), `CLAUDE.md:118` | Review evidence (`do_spl_review_line_check`) | Adopted: Subsection 2.12.1 |
| M6 | **Measure first for speed-ups** | A performance speed-up starts with a baseline measurement and lands with an automated counting or timing test. | `CLAUDE.md:125`, `lesson-speed-up-measure-first.md` | Code review; performance counting tests | Adopted: Subsection 2.1.5 |
| M7 | **Go coverage floor preservation** | Per-package Go coverage floors may not regress below established thresholds. | `csi-spl-api/src/bash/tests/go-coverage-floor.txt` | CI workflow 20 coverage step | Adopted: Subsection 2.12.5 |
| M8 | **WUI typography, focus ring & Chrome proof** | WUI font sizes are specified in `rem` across the five canonical levels; single unified focus-ring token. UI changes must be proven in Chrome (`test:e2e`); typecheck alone is not proof. | `CLAUDE.md` gate table (wui rows) | `font-size.test.mjs`, `focus-tokens.test.mjs`, `pnpm test:e2e` | Adopted: Subsection 2.7.4 |

**Fleet conduct rules cited as pointers:**
- *Process termination rule:* Never run `pkill -f`, `killall`, or pattern-based kill commands (`STOP_RULE`, `spawn-core.inc.sh:526`). Pointed to in Developer Guide Subsection 2.4.4.
- *Domain independence rule:* No literal domain or hostname in code; read `BASE_DOMAIN` or configuration (deploy-gate (c), constitution Principle II). Pointed to in Developer Guide Subsection 2.3.2.

---

## 2. Draft outline of the new "Coding Standards" section of the Developer Guide

The new section will be authored in Qto doc `c65bbfbd-bc33-4ac6-9d66-dc36a71bf948` as **Section 2. Coding Standards for Human and Agent Coders** (renumbering subsequent sections accordingly). It provides the single canonical home for every rule, with explicit enforcement mechanisms documented:

### Section 2 Outline

- **2.1 Core Engineering Principles**
  - *2.1.1 Truth First:* Mandatory empirical verification before reporting done (`seed-truth-rule.txt`). Enforcing gate: code review / audit.
  - *2.1.2 Stay in Your Own Lane:* Scope containment, lane-map checking (`lane-map.sh --check`). Enforcing gate: `do_spl_lane_map`.
  - *2.1.3 Continuous Integration and Deployment:* Master pushes deploy dev and prd; change complete only when verified served. Enforcing gate: `do_check_deploy_lag`.
  - *2.1.4 Dev Leads Prd:* Dev must equal or lead production in version and infrastructure state. Enforcing gate: `check-dev-leads-prd.func.sh` (exit 3).
  - *2.1.5 Measure First for Speed-ups:* Speed-ups require prior measurement and land with a counting test. Enforcing gate: code review (M6).

- **2.2 Code Structure and Clean Code Limits**
  - *2.2.1 Small Functions (80-line cap):* Functions capped at 80 lines across all languages: Go (`cleancode_test.go`), TypeScript/Vue (`cleancode.test.mjs`), Bash (`bash-cleancode.tst.sh` with `MAX_LINES=80` and `LONG` ceiling list).
  - *2.2.2 Nesting Depth and Parameter Limits:* Maximum nesting depth 4; parameter caps: Go: 8, WUI (TS/Vue): 6. (Bash has no depth/parameter cap). Enforcing gate: cleancode test runners.
  - *2.2.3 SQL Query Standards:* Explicit column projections; `SELECT *` strictly forbidden in runtime queries. Enforcing gate: `cleancode_test.go`.
  - *2.2.4 Folded Singletons:* Common utilities (UUID minting, JSON HTTP wire serialization) centralized in canonical packages. Enforcing gate: AST grep checks in unit tests.

- **2.3 Architecture, Paths, and Environment**
  - *2.3.1 Canonical Path Layout:* Subprojects follow `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`; derive paths from tree. Enforcing gate: `no-box-path-source.tst.sh`.
  - *2.3.2 Environment Fail-Fast:* Missing required environment variables must fail fast (`: "${VAR:?error}"`). External hosts derived from `BASE_DOMAIN`; no hardcoded URLs. Enforcing gate: shell action parser.
  - *2.3.3 Single Source of Truth (`cnf`):* All runtime settings authored in `csi-spl-cnf/csi-spl/<env>.env.yaml`. Generated twins updated synchronously via `do_tpl_gen`. Enforcing gate: `git diff --exit-code`.

- **2.4 Shell Scripting and run-bsh Conventions**
  - *2.4.1 Action Naming and Dispatch:* Named actions follow `<verb>-<noun>.func.sh` exposing `do_<verb>_<noun>`, dispatched through `./run -a`. Enforcing gate: action loader registration.
  - *2.4.2 Metadata Tags:* Required run-bsh tags (`@description`, `@param`, `@example`). Enforcing gate: framework validator.
  - *2.4.3 POSIX & Bash Cleanliness:* Safe error handling (`set -uo pipefail`), return codes instead of subshell `exit`, local variables declared before assignment. Enforcing gate: `lint-shellcheck`, `lint-sigpipe`.
  - *2.4.4 Host Package & Process Governance:* Host packages installed only via named action `do_box_pkg_install`. Never `pkill -f` or `killall` on patterns (`STOP_RULE`). Enforcing gate: action log audit.
  - *2.4.5 Named Action Plus Test in Same Commit (M3):* Every infra action ships with its corresponding test script in the same commit. Enforcing gate: code review.

- **2.5 Public Distribution Hygiene and Anonymity**
  - *2.5.1 Permitted Organization References:* `csi`, `csitea`, `csitea.net` only. Strict ban on external client, bank, or vendor names. Enforcing gate: `do_check_dist_hygiene`.
  - *2.5.2 Identity Protection:* No personal names, literal developer or agent OS usernames, machine hostnames, or `/home/<user>` paths. Enforcing gate: `do_check_dist_hygiene` sweep step.
  - *2.5.3 Authorized Git Carve-Out:* Git authorship metadata (`user.name`, `user.email`) carries canonical identity; exempt from repository tree sweep. Enforcing gate: `_sp_leak_gate`.

- **2.6 Security, Secrets, and Cloud Authentication**
  - *2.6.1 Service Account Keys:* Keys stored outside git and TF state (`~/.gcp/.csi/key-csi-spl-<env>.json`), chmod 600. Enforcing gate: `gcloud-account-pinned.tst.sh`.
  - *2.6.2 No Secrets in Code:* Hardcoded credentials, private keys, signed URLs strictly banned. Enforcing gate: `lint-gitleaks`, `lint-trufflehog`.
  - *2.6.3 GCP Invocation Isolation:* Every `gcloud` call carries explicit `--account` or isolated `CLOUDSDK_CONFIG`. Enforcing gate: pre-push gate.
  - *2.6.4 Tenant Table RLS Policies (M1):* Every tenant table carries an RLS policy; queries execute within tenant context. Enforcing gate: `TestRLSCoversEveryTenantTable`.
  - *2.6.5 Terraform Execution & Owner Approval (M4):* Terraform runs only in `tf-runner` container; no GCP mutation without owner go. Enforcing gate: `do_tf_init`.

- **2.7 User Interface Text, Typography, and Internationalization (i18n)**
  - *2.7.1 Mandatory Translation Keys:* All user-visible strings rendered via `t('key')` / `$t('key')`. No literal strings in templates or attributes. Enforcing gate: `i18n-no-raw-text.test.mjs`.
  - *2.7.2 Locale Parity:* Every key must exist across all locale dictionaries (`en.json`, `bg.json`, etc.). Enforcing gate: `i18n-parity.test.mjs`.
  - *2.7.3 Untranslated Baseline Ratchet:* Fallback English strings tracked against baseline; counts may only decrease. Enforcing gate: `i18n-untranslated.test.mjs`.
  - *2.7.4 Typography, Focus Rings, and Browser E2E Proof (M8):* Font sizes in `rem` across 5 levels, single focus ring token, UI changes proven in Chrome via `test:e2e`. Enforcing gate: `font-size.test.mjs`, `focus-tokens.test.mjs`, `test:e2e`.

- **2.8 Linting Tools and Quality Gates**
  - *2.8.1 Pre-Push Lint Suite:* Touched files must pass fast lint suite (`do_check_pre_push_lint` referencing the 19 tools in `check-pre-push-lint.func.sh`; `lint-typos` is WARN only).
  - *2.8.2 Slow Linters (Full Tier):* Checkov, gosec. Enforcing gate: `PRE_PUSH_TIER=full`.
  - *2.8.3 Forward-Only PG16 Migrations (M2):* Applied migrations are immutable (never edited, renamed, or deleted); head+1 parses on PG16. Enforcing gate: `lint-migration`.

- **2.9 Git Trunk Workflow and Integration Rules**
  - *2.9.1 Small Commits and Pathspecs:* Stage named files only (`git add <path>`), commit without pathspec. Never `git add -A`. Enforcing gate: pre-push hook.
  - *2.9.2 Executable Bit Parity:* New scripts require both `chmod +x` and `git add --chmod=+x`. Enforcing gate: git mode churn detector.
  - *2.9.3 Rebase and Background Push:* Fetch fresh, rebase on `origin/master`, push via `do_spl_push_master` background worker. Enforcing gate: `do_spl_push_master`.
  - *2.9.4 Never Force-Push:* Strict ban on `--force`, `--force-with-lease`, `+ref`. Enforcing gate: GitHub ruleset `master-no-force`, pre-push hook.
  - *2.9.5 Canonical Commit Identity:* Author and committer must match repo address; no AI co-authorship trailers. Enforcing gate: `%ae %ce` pre-push check.

- **2.10 Spec-Driven and Issue-Driven Delivery**
  - *2.10.1 Issue Riding:* Every change rides a tracked issue; commit subject scope must cite key (`feat(<area>, SPL-n): ...`). Enforcing gate: `issue-close-landed.py`, exit gate.
  - *2.10.2 Documentation Maintenance:* Behavior changes require doc update under `csi-spl-doc/` or explicit `Docs: none (<why>)` line. Enforcing gate: `kill-your-self-report.sh --gate`.

- **2.11 Box Agent Messaging and Protocol Uniformity**
  - *2.11.1 Uniform Verbs and Payloads:* All agent vendors use identical CLI verbs, parameters, and unsigned JSON v:1 schema. Enforcing gate: `spool` CLI, hub API schema.
  - *2.11.2 Agent Identifier Syntax:* Grammar `^[acgmq]-[0-9]{3}$`. Enforcing gate: `do_check_fleet_rules_drift`.

- **2.12 Testing Standards (M5, M7, isolation, databases)**
  - *2.12.1 Red Controls (M5):* Every test or gate ships with a demonstrated red control (seen RED, then GREEN). Throwaway branch for trunk-red controls. Enforcing gate: code review (`do_spl_review_line_check`).
  - *2.12.2 Isolated Per-Run Temp Dirs:* Tests write temporary files only under per-run temporary directories (`TMPDIR`), never hardcoded paths. Enforcing gate: `lint-tmp-path`.
  - *2.12.3 Spool Live-Root Guard:* Tests refuse to run against the live `/var/spool-hub` root (`SPOOL_TEST=1` safety guard). Enforcing gate: spool test harness init.
  - *2.12.4 PostgreSQL for Store Tests:* Store and migration tests must run against real PostgreSQL; mock store forbidden for integration gates. Enforcing gate: `PRE_PUSH_TIER=full`.
  - *2.12.5 Go Coverage Floor Preservation (M7):* Go per-package coverage floors may not regress. Enforcing gate: CI workflow 20 coverage step.

---

## 3. The export design: Qto doc c65bbfbd to spec-kit constitution

### 3.1 Architectural data flow and single home

```text
[Qto Doc c65bbfbd] (Developer Guide single source of truth in Qto)
       │
       ▼ (cd csi-spl-orc && ./run -a do_spl_doctree_export_md)
[csi-spl-doc/doc/md/developer-guide.md] (Developer Guide export)
       │
       ▼ (cd csi-spl-orc && ./run -a do_spl_export_constitution_coding_standards)
[csi-spl-doc/.specify/memory/constitution.md] (Constitution carrying exported standards)
       ▲
       │ (cd csi-spl-orc && ./run -a do_check_fleet_rules_drift [fact 8: DRY_RUN=1])
[Drift Check] (Refuses commit if constitution diverges from developer guide)
```

The Developer Guide is the single canonical home for all coding rules. Human and agent coders edit only the Qto doc `c65bbfbd`. The markdown files are derived artifacts produced by automated actions and verified by continuous drift checks.

### 3.2 Slicing by stable node anchor (resolving review item 3.2)

In Qto document export, section numbering changes dynamically whenever sections are inserted or reordered. Slicing on literal heading text like `## 2. Coding standards` is fragile and breaks on renumbering.

Instead, the export action slices by the section's stable Qto node anchor:
- Start delimiter: `<a id="ws-doc-<uuid>"></a>` corresponding to the Coding Standards section node.
- End delimiter: the next anchor `<a id="ws-doc-<uuid>"></a>` at the same heading level (`##`), or EOF.
- The node UUID is stored in exactly one place: within the export action `spl-export-constitution-coding-standards.func.sh`.

### 3.3 Single extractor architecture (resolving review item 3.3)

To prevent duplicate slicing logic from drifting, the codebase uses exactly ONE extractor:
- The named action `do_spl_export_constitution_coding_standards` extracts and synchronizes the block.
- Drift fact 8 in `check-fleet-rules-drift.func.sh` executes the export action with `DRY_RUN=1`. If any difference exists between the extracted guide content and the constitution block, the action exits 1 with a diff, causing drift detection to fail cleanly without maintaining a separate extractor.

### 3.4 Stating rules vs. duplicating lists (resolving review item 3.4)

Lists that already have a canonical machine-checked source in code (the 19 fast linter parts in `check-pre-push-lint.func.sh`, the cleancode limits in `cleancode_test.go` and `cleancode.test.mjs`, the i18n key baselines) will NOT be retyped in the Developer Guide. Retyped lists inevitably drift without automated detection. The Developer Guide states the rule conceptually and cites the authoritative gate file. Clean code limits (80 lines, depth 4, params 8/6) are cited specifically because they are pinned by automated cleancode tests.

### 3.5 Governance and versioning automation (resolving review item 3.5 & A2)

Per `constitution.md:209-212`, every amendment to the constitution must bump the version and `Last Amended` date. Because the constitution is updated via automated export from the Developer Guide:
- The export action `do_spl_export_constitution_coding_standards` bumps the patch version (+1, incrementing from the higher of the body and footer version numbers, currently `0.2.1`) and updates the `Last Amended` date in both the body and metadata footer of `constitution.md` **only when the exported block has changed**.
- If the exported block is identical to the current constitution block, the action makes no changes, ensuring `DRY_RUN=1` reporting does not trigger spurious diffs.
- Row 06's initial synchronization sets the version to `0.3.0` (as a one-time minor step).
- Drift fact 8 compares only the bounded `<!-- BEGIN CODING STANDARDS -->` block, ignoring the header version and date lines, allowing clean automated synchronization.

### 3.6 Developer Guide ack churn prevention (resolving review item 3.6)

Section 6 of the Developer Guide mandates that any change to `developer-guide.md` alters its blob hash and requires every active coder in the fleet to re-run the `do_dev_guide_ack` confirmation. To prevent multiple churn events across the build:
- Build row 01 lands ALL text changes to the Developer Guide in ONE single commit.
- Subsequent build rows (02–09) touch only scripts, tests, `CLAUDE.md`, `fleet-rules-index.md`, and `constitution.md`, ensuring no further developer guide blob churn occurs.

### 3.7 Spec-kit reference integrity (resolving review item 3.7 & A3)

The exported block is a verbatim slice of Developer Guide Section 2 (numbered subsections 2.1–2.12). Existing spec-kit templates (such as `plan-template.md:43-50`) that check core principles by Roman numeral are updated in Row 09 to align Constitution Check citations with the new 2.x subsection structure. Build row 09 is scheduled in Batch 2 alongside Row 06 (constitution sync), ensuring both land synchronously.

---

## 4. Pointer rationalization: which existing copies become pointers

To eliminate duplication while preserving critical agent orientation:

1. **Repo `CLAUDE.md` / `AGENTS.md` (Row 07):**
   - **Retain:** The cheap-gate table in `CLAUDE.md` (lines 94–117) is retained in place. Claude agents load `CLAUDE.md` automatically on startup; keeping the quick-reference gate table in `CLAUDE.md` provides immediate orientation without reading external files.
   - **Retain:** The "Commits:" author line is retained untouched, as drift fact 7 (`_frd_commit_address`) directly pins its formatting and value.
   - **Convert:** Prose rules that duplicate the Developer Guide (action conventions lines 47–63, commit rules lines 139–140, general hygiene prose) are replaced with concise markdown links to `developer-guide.md#2-coding-standards`.

2. **Spec-kit constitution `csi-spl-doc/.specify/memory/constitution.md` (Row 06):**
   - The Core Principles section (lines 31–133) is replaced entirely by the bounded export block:
     ```markdown
     <!-- BEGIN CODING STANDARDS (exported from developer-guide.md; DO NOT EDIT DIRECTLY) -->
     ... [Exported Content] ...
     <!-- END CODING STANDARDS -->
     ```
   - Historical defects fixed:
     - Update agent ID examples from obsolete `CLE-*`/`GRK-*`/`AGY-*` to `c-`, `g-`, `a-`, `q-`, `m-` (`constitution.md:127`).
     - Remove retired "relay bucket + SA" reference (`constitution.md:40`) and "relay SA key" (`constitution.md:117`).
     - Clarify hygiene carve-out for git metadata.

3. **Fleet rules index `csi-spl-doc/doc/md/fleet-rules-index.md` (Row 08):**
   - Update Section 2 ("One home per rule") to designate Developer Guide Section 2 as the single home for clean code limits, i18n rules, action conventions, and pre-push linters, with direct section anchor links.

4. **Spec-kit plan template `csi-spl-doc/.specify/templates/plan-template.md` (Row 09):**
   - Fix stale `csi-rel-cnf` reference at line 46 to `csi-spl-cnf`.
   - Align Constitution Check references with the exported Developer Guide subsections.

---

## 5. Build rows (7 consolidated actions, rounds-rulebook R1–R16)

Per reviewer recommendations and dispatcher guidance:
- Rows 02 and 03 are merged into a single build row (action plus test per rule M3).
- Rows 04 and 05 are merged into a single build row (drift check plus test per rule M3).
- Former Row 10 (re-ack gate) is dropped: pre-push execution is every developer's duty, not a separate build row.
- Rows 02 and 04 Kind is set to `complex_coding`, vendor `claude` (under HUM-10 `b61851fb`, Mistral is barred from coding and testing lanes).
- Row 04 is scheduled in Batch 3 (landing AFTER Row 06) per binding amendment A1, because `do_check_fleet_rules_drift` runs inside the pre-push hygiene suite and would fail if fact 8 or fact 1 were enabled before `constitution.md` carried the exported block and clean agent IDs.
- Total count: **7 consolidated rows** across 3 batches, comfortably under the 10-row ceiling.

| # | Slug & commit subject | Practice | Why | Sites file:line (max 5) | n | Test & concrete red control | Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `doc(c002-01-qto-dev-guide-coding-standards)` | Qto authoring, docs | Primary home for coding standards lives in Qto doc c65bbfbd and exports to developer-guide.md in ONE commit (no ack churn) | Qto doc `c65bbfbd`<br>`csi-spl-doc/doc/md/developer-guide.md` | 1 Qto doc | Author new Section 2 in Qto doc c65bbfbd; export via `do_spl_doctree_export_md`. Every rule has gate file or "review only". **Target:** `grep -c 'Enforced by'` equals rule count. **Red control:** `check-qto-doc-drift` exits 1 with hand-edited md and 0 after export. Record slice node id in commit body. | sat | agy | specs_and_docs | 1 |
| 02 | `feat(c002-02-orc-export-constitution-action)` | Shell action & test (M3) | Automated export action and test script in same commit per rule M3 | `csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh`<br>`csi-spl-orc/src/bash/tests/export-constitution-coding-standards.tst.sh` | 2 files | Implement `do_spl_export_constitution_coding_standards` and unit test. Slices by stable node anchor, preserves envelope, bumps version/date when block changes. **Target:** action exits 0, writes block. **Red control:** planted duplicate end anchor or missing begin marker makes action exit non-zero without modifying file; corrupted delimiter fails test (rc 1). | sat | claude | complex_coding | 1 |
| 07 | `doc(c002-07-repo-claude-md-pointers)` | Pointer rationalization | Convert prose rules to developer-guide links; retain cheap-gate table and Commits line | `CLAUDE.md:47-63,139-140`<br>`AGENTS.md:1-11` | 2 files | Replace redundant prose with links to `developer-guide.md#2-coding-standards`. Keep cheap-gate table (lines 94-117) and "Commits:" line intact. **Target:** `grep -c` of moved rules in `CLAUDE.md` drops by number moved; drift fact 7 (`_frd_commit_address`) passes green. **Red control:** syntax check clean, dist hygiene clean. | sat | agy | specs_and_docs | 1 |
| 08 | `doc(c002-08-fleet-rules-index-update)` | Index update | Designate Developer Guide Coding Standards as one home for coding rules in fleet index | Qto doc `9d7d5428`<br>`csi-spl-doc/doc/md/fleet-rules-index.md:27-56` | 1 Qto doc | Update Qto doc `9d7d5428` Section 2 with node anchor links to Row 01; run `do_spl_doctree_export_md`. **Target:** `check-qto-doc-drift` clean, all markdown links valid. **Red control (A4):** `check-qto-doc-drift` exits 1 with `fleet-rules-index.md` edited by hand and 0 after the export. | sat | agy | specs_and_docs | 2 (after 01) |
| 06 | `doc(c002-06-sync-spec-kit-constitution)` | Spec-kit sync, constitution | Sync constitution from developer guide; fix obsolete agent IDs and retired relay references | `csi-spl-doc/.specify/memory/constitution.md:1-217` | 1 file | Run `do_spl_export_constitution_coding_standards`. Update header Sync Impact Report to v0.3.0. Fix line 40 ("relay bucket") and retire `CLE-*`. **Target:** `do_check_fleet_rules_drift` exits 0. **Red control:** un-exported constitution fails fact 8; synced constitution passes fact 8 and fact 1. | sat | claude | specs_and_docs | 2 (after 01, 02) |
| 09 | `doc(c002-09-spec-kit-template-fix)` | Template hygiene | Fix stale csi-rel remnant in plan-template.md and align Constitution Check | `csi-spl-doc/.specify/templates/plan-template.md:40-50` | 1 template | Fix line 46 (`csi-rel-cnf` -> `csi-spl-cnf`); align Constitution Check list with Developer Guide subsections. **Target:** `do_check_dist_hygiene` clean; template citations match constitution. **Red control:** `grep csi-rel-cnf` drops to 0. | sat | agy | specs_and_docs | 2 (with 06) |
| 04 | `feat(c002-04-orc-drift-check-constitution)` | Drift detection & test (M3) | Fact 8 calling export action with DRY_RUN=1; constitution added to fact 1 sources (A1: lands after 06) | `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh`<br>`csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh` | 2 files | Add fact 8 to `do_check_fleet_rules_drift` executing action with `DRY_RUN=1`. Add `constitution.md` to `_frd_sources` so fact 1 checks agent ID syntax. **Target:** passes with 8 facts. **Red control:** planted mismatch between guide and constitution exits 1; synced files exit 0; planted `CLE-*` in constitution fails fact 1. | sat | claude | complex_coding | 3 (after 06) |

---

### 5.1 Disjoint files per batch (R1 verification)

Batch assignments guarantee zero file overlap across concurrent executions:

- **Batch 1 (Initial implementations and guide authoring):**
  - Row 01: Qto doc `c65bbfbd`, `csi-spl-doc/doc/md/developer-guide.md`
  - Row 02: `csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh`, `csi-spl-orc/src/bash/tests/export-constitution-coding-standards.tst.sh`
  - Row 07: `CLAUDE.md`, `AGENTS.md`
  *Zero file overlap across Batch 1 items.*

- **Batch 2 (Index update, constitution sync, and template alignment):**
  - Row 08: Qto doc `9d7d5428`, `csi-spl-doc/doc/md/fleet-rules-index.md` (updates pointers to Row 01 anchor)
  - Row 06: `csi-spl-doc/.specify/memory/constitution.md` (syncs using Rows 01 & 02)
  - Row 09: `csi-spl-doc/.specify/templates/plan-template.md` (aligns with Row 06)
  *Zero file overlap between Rows 08, 06, and 09, and zero overlap with earlier batches.*

- **Batch 3 (Drift check activation per binding amendment A1):**
  - Row 04: `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh`, `csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh`
  *Runs after Row 06 has populated the constitution block and cleaned agent IDs, ensuring pre-push hygiene passes across the fleet.*

### 5.2 Off every live lane (R3 verification)

Lane map verification (`bash lane-map.sh --check <paths>`) confirms that none of the target paths for any of the 7 rows are owned by another active lane on any fleet machine.

---

## 6. Panel consensus and signatures

The plan was reviewed independently by both reviewer seats across two review iterations:

1. **Claude reviewer seat (`c-337`):**
   - Reviewed v0.1 in `seat-claude.md` (landed at `d0bd4021c`). Verdict: **CHANGE**.
   - Signed v1.0 in `seat-claude.md` section 6 (landed at `2c70de6ca`). Verdict: **SIGNED, with amendment A1 binding**:
     - *Amendment A1 (binding):* Row 04 (drift fact 8 + fact 1 sources) must land AFTER Row 06 in Batch 3, because `do_check_fleet_rules_drift` runs inside the pre-push hygiene suite and would fail if fact 8 or fact 1 were enabled before `constitution.md` carried the exported block and clean agent IDs.
     - *Amendment A2:* Bump the version only when the block changes (`DRY_RUN=1` must not diff identically).
     - *Amendment A3:* Strike the Roman-numeral bullet in Section 3.7; Row 09 is the template fix.
     - *Amendment A4:* Row 08 red control: `check-qto-doc-drift` exits 1 with a hand edit and 0 after export.
   - All four amendments are folded directly into this v1.1 text.

2. **Mistral reviewer seat (`m-353`):**
   - Reviewed v0.2 (`b776859b9`) in `seat-mistral.md` (landed at `49560aeae`).
   - Verdict: **GOOD** (no defects found, all sections verified, ready for final sign-off).

3. **Dispatcher guidance (`c-002`):**
   - Rows 02 and 04 marked `complex_coding` / vendor `claude` (enforcing owner rule HUM-10 `b61851fb`: no Mistral coding or testing lanes).
   - Panel consensus protocol (msgs `8ab93221`, `f26e488e`): Both reviewer seats verify and sign the unified plan in their respective seat files before presentation to the repo owner.

### 6.1 Panel signature table

| Seat | Role | Vendor | Status | Signature (v1.1 SHA) |
|---|---|---|---|---|
| `a-330` | Editor | agy | v1.1 ready | Pending push |
| `c002-coding-standards-panel-seat-claude` | Reviewer | claude | v1.0 signed (2c70de6ca, A1 binding); awaiting v1.1 | Pending |
| `c002-coding-standards-panel-seat-mistral` | Reviewer | mistral | v0.2 reviewed GOOD (49560aeae); awaiting v1.1 | Pending |
