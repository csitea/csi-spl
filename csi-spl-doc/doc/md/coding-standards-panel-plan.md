# Coding standards panel - plan (developer guide + spec-kit constitution)

Epic: SPL-2402
Issue: SPL-2537
Spec: csi-spl-doc/specs/135-work-process
Kind: specs_and_docs

Status: **v0.1, DRAFT** (awaiting panel review by claude and mistral seats).
Editor seat: **a-330** (agy).
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16).
Baseline commit: **`4453459bbde498b0c88c2a9fcf899e37acc28889`** (`origin/master` at lane start, 2026-10-19T09:41Z).

## 0. Context and owner orders

Owner HUM-10, t1 topic `2402f33e-5ab4-46bf-83ab-ee7e8f603806`:
- msg ad01a506 (2026-10-19T09:2xZ): *"let's reviit the consitution of the git-spec and combine it with oour Developer Guide and improve on the overall Coding Standards which each CODING agents must follow"*
- msg 477b0565 (2026-10-19T09:2xZ): *"the primary work should go into the Coding Standards section of the Developer Guide , and than exported as part of the constition of the git-spec"*

**Core architectural requirement:**
1. The developer guide (`csi-spl-doc/doc/md/developer-guide.md`, export of Qto doc `c65bbfbd-bc33-4ac6-9d66-dc36a71bf948`) becomes the primary single source of truth for all coding standards and rules governing human and agent coders.
2. The spec-kit constitution (`csi-spl-doc/.specify/memory/constitution.md`) carries that Coding Standards section by automated export (via a named `./run` action), eliminating hand-maintained duplication and drift.
3. A drift check ensures the constitution's exported section never diverges from the developer guide.

---

## 1. Inventory of current coding rules (measured on `4453459bbde498b0c88c2a9fcf899e37acc28889`)

Every coding rule currently binding a coding agent in this repository was inventoried across the primary sources:
1. Spec-kit constitution (`csi-spl-doc/.specify/memory/constitution.md:1-218`)
2. Developer guide (`csi-spl-doc/doc/md/developer-guide.md:1-271`)
3. Repo instructions (`CLAUDE.md:1-153` / `AGENTS.md:1-17`)
4. Fleet rules index (`csi-spl-doc/doc/md/fleet-rules-index.md:1-79`)
5. Lane seed prompt templates (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:273-356,527`)
6. Distribution hygiene workflow & action (`.github/workflows/10_ci-quality.yml:1349-1460`, `csi-spl-iac/src/bash/run/check-dist-hygiene.func.sh:24-64`)
7. Quality and lint gates (`csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:1-100`, cleancode tests, i18n gates)

### 1.1 The inventory table

| # | Rule name & category | What it requires | Primary home today | Duplicates & references | Contradictions, drift & gaps | Enforcing gate or status |
|---|---|---|---|---|---|---|
| 01 | **Truth first** | Speak the truth 100% of the time. Verify every statement empirically before making it. Never report done before it is true. | `csi-spl-orc/src/bash/features/spawn-agents/assets/seed-truth-rule.txt:1` | `fleet-rules-index.md:31` (`grep -c`: 1); rendered into every agent seed (`spawn-core.inc.sh:527`). | Missing entirely from both `constitution.md` and `developer-guide.md`. | Guard: `test-seed-truth-first.sh`. Not automated in code review. |
| 02 | **Canonical path layout** | Sub-projects live at `/opt/csi/csi-spl/<APP>-<KIND>`. Paths derived from filesystem location, no hard-coded paths. Kinds: `api`, `wui`, `iac`, `cnf`, `utl`, `orc`, `dat`, `doc`. | `csi-spl-doc/.specify/memory/constitution.md:33-49` (Principle I) | `CLAUDE.md:7-17` (`grep -c`: 1). | `constitution.md:38` describes `csi-spl-wui` as "lightweight task and thread viewer web app" (now Nuxt 3 full WUI). | Gate: `no-box-path-source.tst.sh`. |
| 03 | **Environment fail-fast configurability** | External URLs, hosts, buckets, GCP accounts overridable via env vars. Shell actions fail fast if missing (`: "${VAR:?error}"`). No default hostnames in code. | `csi-spl-doc/.specify/memory/constitution.md:50-64` (Principle II) | `CLAUDE.md:20-26` (`grep -c`: 1). | Placeholder `<<run-time>>.csitea.net` used in constitution, while `all.env.yaml` defines `BASE_DOMAIN`. | Code review; shell action parameter validation. |
| 04 | **run-bsh action convention** | Operator behaviour exposed as `do_<verb>_<noun>` Bash functions in `src/bash/run/<name>.func.sh`, dispatched via `./run -a do_<name>`. Metadata tags `@description`, `@param`, etc. | `csi-spl-doc/.specify/memory/constitution.md:65-71` (Principle III) | `CLAUDE.md:47-63` (`grep -c`: 2). | Constitution cites `csi-spl-iac/src/bash/run/<group>/<name>.func.sh`, while actual layout places groups flat in `src/bash/run/` across `iac`, `orc`, `utl`. | Framework `run.sh` action loader; `bash-cleancode.tst.sh`. |
| 05 | **Spec-driven development** | No runtime code written without corresponding artifact under `csi-spl-doc/specs/<NNN-slug>/`: specify, clarify, plan, tasks, analyze, implement. | `csi-spl-doc/.specify/memory/constitution.md:72-81` (Principle IV) | `lane-issue-and-docs.md:89-150` (SPL-2355) (`grep -c`: 1). | Constitution does not mention the mandatory Epic + Git Spec link required by SPL-2355 / HUM-10 order. | Gate: `do_spl_spawn_enqueue` & `spawn-window.sh` (exit 12). |
| 06 | **Distribution hygiene** | Public repository: org-neutral (`csi`/`csitea`/`csitea.net` only). No non-Csitea org or bank references, no personal names, no literal developer/agent OS usernames, no machine/box identifiers, no personal home directory paths. Authorised carve-out: git commit metadata. | `.github/workflows/10_ci-quality.yml:1349-1460` | `constitution.md:82-104` (Principle V); `check-dist-hygiene.func.sh:24-64`; `spawn-core.inc.sh:527`. | Minor drift: `constitution.md:94-96` suggests `<CONFLUENCE-SPACE>` and `<JIRA-PROJ-CODE>`, which are unused (all issues are `SPL-n`). | Gate: `do_check_dist_hygiene`, CI job `distribution-hygiene`. |
| 07 | **Cnf single source of truth** | No hardcoded runtime configuration in code. Author in `csi-spl-cnf/csi-spl/<env>.env.yaml`. Generated twins (`.env.json`, `*.tfvars`) re-rendered in same commit via `do_tpl_gen`. | `csi-spl-doc/.specify/memory/constitution.md:105-113` (Principle VI) | `CLAUDE.md:13,103`; `plan-template.md:45-48`. | In `plan-template.md:46`, stale copy says `csi-rel-cnf/csi-rel/<env>.env.yaml` instead of `csi-spl-cnf`. | Gate: `git diff --exit-code` after `do_tpl_gen`; `check-qto-doc-drift`. |
| 08 | **Secrets, SA keys & GCP authentication** | Service accounts only per env. SA keys minted out-of-band, chmod 600, under `$HOME/.gcp/.csi/key-csi-spl-<env>.json`. No keys in git, TF state, or logs. Every gcloud call carries `--account` or throwaway `CLOUDSDK_CONFIG`. | `CLAUDE.md:28-46,88-92` | `constitution.md:114-125` (Principle VII); `fleet-rules-index.md:34`. | Constitution refers to "relay SA key", which was retired in SPL-1910; current setup uses env project keys `key-csi-spl-<env>.json`. | Gates: `gcloud-account-pinned.tst.sh`, `lint-gitleaks`, `lint-trufflehog`. |
| 09 | **Uniform box API & agent ID grammar** | All agents talk through same verbs, tool names, JSON v:1, and schema. No per-vendor endpoints. Agent ID grammar: `^[acgmq]-[0-9]{3}$`. | `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:100` (`SPOOL_AGENT_ID_NEW_RX`) | `constitution.md:126-133` (Principle VIII); `fleet-rules-index.md:33`; spec 061 §0. | **Direct contradiction:** `constitution.md:127` lists obsolete format `CLE-*`, `GRK-*`, `AGY-*`. Spec 061 and current fleet use `c-`, `g-`, `a-`, `q-`, `m-`. | Gate: `do_check_fleet_rules_drift` (fact 1: `_frd_id_letters`). |
| 10 | **Clean code & function limits (80 lines, depth 4)** | Functions capped at 80 lines; maximum nesting depth 4; parameter caps (Go: 8, WUI: 6); no `SELECT *` in SQL queries; folded singletons (UUID minting, JSON wire encoding). | `csi-spl-api/.../cleancode/cleancode_test.go:17-41` | `csi-spl-iac/.../bash-cleancode.tst.sh:15-30`; `csi-spl-wui/.../cleancode.test.mjs:27-37`. | **Major gap:** This binding standard is enforced across Bash, Go, and TypeScript/Vue, but is **completely missing** from `constitution.md`, `CLAUDE.md`, and `developer-guide.md`. | Gates: `bash-cleancode.tst.sh`, Go `TestCleanCodeGate`, WUI `cleancode.test.mjs`. |
| 11 | **UI text and internationalization (i18n)** | No literal hardcoded text in UI templates, dialogs, or user-facing attributes. Use translation keys `t('key')` / `$t('key')`. Key parity across all locales. Untranslated and raw text baseline ratchets. | `csi-spl-doc/doc/md/developer-guide.md:130-155` (Section 2.4) | `csi-spl-wui/src/node/i18n/i18n-gates.mjs`; `fleet-rules-index.md:36`. | Missing from `constitution.md`. Mentioned only in Developer Guide. | Gates: `i18n-untranslated.test.mjs`, `i18n-no-raw-text.test.mjs`, `i18n-parity.test.mjs`. |
| 12 | **Pre-push lint suite** | Touched files must pass scanner suite before pushing: syntax (bash/YAML/JSON/make), migrations (PG16 parse, unique prefix, immutable history), compose, shellcheck, actionlint, hadolint, eslint, ruff, terraform fmt, mdlinks, typos, semgrep, sigpipe, tmp-path. | `csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh:1-100` | `CLAUDE.md:94-117`; `developer-guide.md:122-128`; `pre-push-gate.md`. | `developer-guide.md:122` names `do_check_pre_push` but does not itemize the 18 lint tools and their specific rules. | Gate: `do_check_pre_push_lint` (hooked into `do_check_pre_push`). |
| 13 | **Trunk-based workflow & small commits** | Single trunk `master`. Linear history via rebase, no PRs in fleet. Small commits with explicit pathspecs on `add` (`git add <path>...`, `git commit` with no pathspec). Never `git add -A` / `commit -a`. Executables require both `chmod +x` and `git add --chmod=+x`. | `csi-spl-doc/doc/md/developer-guide.md:19-35,95-104` | `constitution.md:181-190`; `spawn-core.inc.sh:301`; `lane-integration-rules.md:16-53`. | None; well-aligned across sources. | Gate: pre-push hook; code review. |
| 14 | **Rebase before push & background push** | Rebase onto latest `origin/master` before every push (`git fetch`, `git rebase origin/master`, re-test). Push using background action `do_spl_push_master` and poll `PUSH_CMD=status`; never foreground push. | `csi-spl-doc/doc/md/developer-guide.md:106-120` | `spawn-core.inc.sh:301` (`grep -c`: 1); `lane-integration-rules.md:55-83,119-155`; `fleet-rules-index.md:43`. | None. | Gate: pre-push hook; `do_spl_push_master`. |
| 15 | **Never force-push or delete master** | No force-push (`--force`, `--force-with-lease`, `+ref`) or deletion of master without explicit owner approval for that one push. `SPL_PREPUSH_OVERRIDE` never bypasses a refused push. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:282` (`NO_FORCE`) | `developer-guide.md:166-185` (Section 3); `lane-integration-rules.md:97-117`; `fleet-rules-index.md:44`. | None. | Gates: GitHub ruleset `master-no-force`, pre-push hook, `force-push-guard.inc.sh`. |
| 16 | **Commit identity & no AI trailers** | Commits carry author's real identity matching repo `CLAUDE.md` matching repo CLAUDE.md "Commits:" line. Pass identity to commit AND rebase. No `Co-Authored-By:`, `Generated with`, or AI session links. | `CLAUDE.md:139-140` | `developer-guide.md:157-164` (Section 2.5); `spawn-core.inc.sh:301`; `lane-integration-rules.md:173-211`. | **Contradiction:** `constitution.md:186` cites placeholder `FirstName LastName <dev@csitea.net>`, whereas real identity is canonical in `CLAUDE.md`. | Gate: pre-push hook `%ae %ce` check (`_sp_leak_gate`). |
| 17 | **Issue tracking and docs coupling** | Every change rides an issue. Cite key in commit subject scope (`feat(<area>, SPL-n): ...`) or `Closes: SPL-n`. Code behaviour changes must land with `csi-spl-doc/` update or `Docs: none (<why>)`. | `csi-spl-doc/doc/md/lane-issue-and-docs.md:1-232` | `developer-guide.md:57-90` (Section 1.4); `fleet-rules-index.md:41`; `spawn-core.inc.sh:327-340`. | None. | Gate: `kill-your-self-report.sh --gate` (`li_gate`). |
| 18 | **Release version minting** | Release version is minted by `do_release_version` (`v<X.Y.Z>` tag), never edited by hand. Base `.version` raised only for major milestone jumps. | `csi-spl-doc/doc/md/developer-guide.md:48-55` (Section 1.3) | `CLAUDE.md:131-138` (`grep -c`: 1); `release-version.func.sh:1-40`. | None. | Gate: CI release pipeline; release version action. |
| 19 | **Dev always equals or leads prd** | Infrastructure and code changes apply/deploy to dev first, proven on dev, then prd. Prd apply refused if dev has pending changes. | `csi-spl-doc/doc/md/fleet-rules-index.md:54` | `CLAUDE.md:78-81`; `check-dev-leads-prd.func.sh`; `check-env-order.func.sh`. | Missing from `constitution.md` and `developer-guide.md`. | Gate: `do_tf_plan_pending` (exit 3), cron `do_check_env_order`. |
| 20 | **Stay in your own lane & scope control** | Work strictly within brief scope. Blocker outside scope: fetch fresh, check lane map (`lane-map.sh --check`). If unowned, fix in separate narrow commit. | `csi-spl-orc/.../claude-md/25-stay-in-your-lane.md` | `fleet-rules-index.md:40`; `spawn-core.inc.sh:302`; `lane-integration-rules.md:229-237`. | Missing from `constitution.md`. | Gate: `lane-map.sh --check` (exit 3/4). |
| 21 | **Package installation via named action** | Agents install packages only via `cd csi-spl-iac && BOX_PKG=<pkg> BOX_PKG_REASON="<why>" AGENT_ID=<id> ./run -a do_box_pkg_install`. Action records all installs. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:287` (`SEED_BOX_PKG`) | `fleet-rules-index.md:45`; spec 142 §5. | Missing from `constitution.md` and `developer-guide.md`. | Guard: `test-seed-box-pkg.sh`; action logging. |
| 22 | **Rounds rulebook standards (R1–R16)** | Refactoring and bug rounds capped at 10 items; 1–3 pushes per item (max 5); disjoint files per batch (R1); cross-vendor review evidence (R7); red controls for gates. | `csi-spl-doc/doc/md/rounds-rulebook.md:1-168` | `fleet-rules-index.md:47`; `SPEC-spool-project-refactor.md`. | Missing from `constitution.md`. | Review evidence gate `do_spl_review_line_check`. |

---

## 2. Draft outline of the new "Coding Standards" section of the Developer Guide

The new section will be authored in Qto doc `c65bbfbd-bc33-4ac6-9d66-dc36a71bf948` as **Section 2. Coding Standards for Human and Agent Coders** (renumbering current Sections 2–7 accordingly, or structuring as Section 3). It provides the single canonical home for every rule, with explicit enforcement mechanisms documented:

### Section 2 Outline

- **2.1 Core Engineering Principles**
  - *2.1.1 Truth First:* Mandatory empirical verification before reporting done (`seed-truth-rule.txt`). Enforcing gate: code review / audit.
  - *2.1.2 Stay in Your Own Lane:* Scope containment, lane-map checking (`lane-map.sh --check`). Enforcing gate: `do_spl_lane_map`.
  - *2.1.3 Continuous Integration and Deployment:* Master pushes deploy dev and prd; change complete only when verified served. Enforcing gate: `do_check_deploy_lag`.
  - *2.1.4 Dev Leads Prd:* Dev must equal or lead production in version and infrastructure state. Enforcing gate: `check-dev-leads-prd.func.sh` (exit 3).

- **2.2 Code Structure and Clean Code Limits**
  - *2.2.1 Small Functions (80-line cap):* Functions in Bash, Go, and TypeScript/Vue capped at 80 lines. Enforcing gate: `bash-cleancode.tst.sh`, `cleancode_test.go`, `cleancode.test.mjs`.
  - *2.2.2 Nesting Depth and Parameter Limits:* Maximum nesting depth 4; parameter caps (Go: 8, WUI: 6). Enforcing gate: cleancode AST test runners.
  - *2.2.3 SQL Query Standards:* Explicit column projections; `SELECT *` strictly forbidden in runtime queries. Enforcing gate: `cleancode_test.go`.
  - *2.2.4 Folded Singletons:* Common utilities (UUID minting, JSON HTTP wire serialization) centralized in canonical packages. Enforcing gate: AST grep checks in unit tests.

- **2.3 Architecture, Paths, and Environment**
  - *2.3.1 Canonical Path Layout:* Subprojects follow `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`; derive paths from tree. Enforcing gate: `no-box-path-source.tst.sh`.
  - *2.3.2 Environment Fail-Fast:* Missing required environment variables must fail fast (`: "${VAR:?error}"`). Enforcing gate: shell action parser.
  - *2.3.3 Single Source of Truth (`cnf`):* All runtime settings authored in `csi-spl-cnf/csi-spl/<env>.env.yaml`. Generated twins updated synchronously via `do_tpl_gen`. Enforcing gate: `git diff --exit-code`.

- **2.4 Shell Scripting and run-bsh Conventions**
  - *2.4.1 Action Naming and Dispatch:* Named actions follow `<verb>-<noun>.func.sh` exposing `do_<verb>_<noun>`, dispatched through `./run -a`. Enforcing gate: action loader registration.
  - *2.4.2 Metadata Tags:* Required run-bsh tags (`@description`, `@param`, `@example`). Enforcing gate: framework validator.
  - *2.4.3 POSIX & Bash Cleanliness:* Safe error handling (`set -uo pipefail`), return codes instead of subshell `exit`, local variables declared before assignment. Enforcing gate: `lint-shellcheck`, `lint-sigpipe`.
  - *2.4.4 Package Installation:* Host packages installed only via named action `do_box_pkg_install`. Enforcing gate: action log audit.

- **2.5 Public Distribution Hygiene and Anonymity**
  - *2.5.1 Permitted Organization References:* `csi`, `csitea`, `csitea.net` only. Strict ban on external client, bank, or vendor names. Enforcing gate: `do_check_dist_hygiene`.
  - *2.5.2 Identity Protection:* No personal names, literal developer or agent OS usernames, machine hostnames, or `/home/<user>` paths. Enforcing gate: `do_check_dist_hygiene` sweep step.
  - *2.5.3 Authorized Git Carve-Out:* Git authorship metadata (`user.name`, `user.email`) carries canonical identity; exempt from repository tree sweep. Enforcing gate: `_sp_leak_gate`.

- **2.6 Security, Secrets, and Cloud Authentication**
  - *2.6.1 Service Account Keys:* Keys stored outside git and TF state (`~/.gcp/.csi/key-csi-spl-<env>.json`), chmod 600. Enforcing gate: `gcloud-account-pinned.tst.sh`.
  - *2.6.2 No Secrets in Code:* Hardcoded credentials, private keys, signed URLs strictly banned. Enforcing gate: `lint-gitleaks`, `lint-trufflehog`.
  - *2.6.3 GCP Invocation Isolation:* Every `gcloud` call carries explicit `--account` or isolated `CLOUDSDK_CONFIG`. Enforcing gate: pre-push gate.

- **2.7 User Interface Text and Internationalization (i18n)**
  - *2.7.1 Mandatory Translation Keys:* All user-visible strings rendered via `t('key')` / `$t('key')`. No literal strings in templates or attributes. Enforcing gate: `i18n-no-raw-text.test.mjs`.
  - *2.7.2 Locale Parity:* Every key must exist across all locale dictionaries (`en.json`, `bg.json`, etc.). Enforcing gate: `i18n-parity.test.mjs`.
  - *2.7.3 Untranslated Baseline Ratchet:* Fallback English strings tracked against baseline; counts may only decrease. Enforcing gate: `i18n-untranslated.test.mjs`.

- **2.8 Linting Tools and Quality Gates**
  - *2.8.1 Pre-Push Suite (18 Fast Linters):* Syntax, migrations, compose, shellcheck, actionlint, hadolint, eslint, ruff, terraform fmt, mdlinks, typos, semgrep, sigpipe, tmp-path. Enforcing gate: `do_check_pre_push_lint`.
  - *2.8.2 Slow Linters (Full Tier):* Checkov, gosec. Enforcing gate: `PRE_PUSH_TIER=full`.

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

---

## 3. The export design: Qto doc c65bbfbd to spec-kit constitution

### 3.1 Architectural data flow

```text
[Qto Doc c65bbfbd] (Developer Guide single source of truth in Qto)
       │
       ▼ (cd csi-spl-orc && ./run -a do_spl_doctree_export_md)
[csi-spl-doc/doc/md/developer-guide.md] (Developer Guide export)
       │
       ▼ (cd csi-spl-orc && ./run -a do_spl_export_constitution_coding_standards)
[csi-spl-doc/.specify/memory/constitution.md] (Constitution carrying exported standards)
       ▲
       │ (cd csi-spl-orc && ./run -a do_check_fleet_rules_drift)
[Drift Check] (Refuses commit if constitution diverges from developer guide)
```

### 3.2 Slicing and synchronization mechanism

1. **Section boundary delimiters in `developer-guide.md`:**
   The export script identifies the start of the Coding Standards section via anchor / heading:
   `## 2. Coding standards` (or the corresponding Qto heading `## Coding Standards for Human and Agent Coders`).
   It extracts content until the next major section heading (`## 3.` or `## Never force-push`).

2. **Constitution envelope preservation:**
   `csi-spl-doc/.specify/memory/constitution.md` maintains spec-kit compatibility:
   - Header comments: Sync Impact Report (`<!-- Sync Impact Report ... -->`).
   - Front matter: Document title and project metadata token table.
   - Bounded replacement block:
     ```markdown
     <!-- BEGIN CODING STANDARDS (exported from developer-guide.md; DO NOT EDIT DIRECTLY) -->
     ... [Exported Content] ...
     <!-- END CODING STANDARDS -->
     ```
   - Trailing sections: Project-specific Additional Constraints, Development Workflow, Governance, and version marker comments.

3. **Named export action:**
   `csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh`:
   - Exposes `do_spl_export_constitution_coding_standards`.
   - Dispatched via `cd csi-spl-orc && ./run -a do_spl_export_constitution_coding_standards`.
   - Options:
     - `DEV_GUIDE_MD` (default: `csi-spl-doc/doc/md/developer-guide.md`).
     - `CONSTITUTION_MD` (default: `csi-spl-doc/.specify/memory/constitution.md`).
     - `DRY_RUN=1` (default 0): prints diff without modifying file.
   - Idempotent and byte-stable: rewrites only if content has changed.

4. **Associated test:**
   `csi-spl-orc/src/bash/tests/export-constitution-coding-standards.tst.sh`:
   - Validates that extracted markdown matches the developer guide section.
   - Validates that constitution header, version block, and footer are preserved intact.
   - Red control: modifying a rule in `developer-guide.md` causes test to detect diff against unexported constitution.

5. **Drift check integration:**
   Add fact 8 (`constitution-coding-standards`) to `do_check_fleet_rules_drift` (`csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh`):
   - Extracts the section from `developer-guide.md` and the bounded block from `constitution.md`.
   - Exits 1 with clear diagnostic if any character differs:
     `FAIL constitution-coding-standards: constitution.md differs from developer-guide.md Coding Standards section. Run: cd csi-spl-orc && ./run -a do_spl_export_constitution_coding_standards`
   - Added to pre-push hygiene checks so drift can never land on master.

---

## 4. Pointer rationalization: which existing copies become pointers

To eliminate drift across the codebase, duplicated rules will be converted to concise one-line pointers to the developer guide's new Coding Standards section:

1. **Repo `CLAUDE.md` / `AGENTS.md`:**
   - Replace the cheap-gate table (lines 94–117) and action conventions (lines 47–63) with a direct link:
     `Coding standards, clean-code limits (80 lines, depth 4), and pre-push gates: [Developer Guide](csi-spl-doc/doc/md/developer-guide.md#2-coding-standards).`
   - Retain only repo-specific infrastructure requirements (GCP environments, tf-runner container execution, commit identity).

2. **Spec-kit constitution (`csi-spl-doc/.specify/memory/constitution.md`):**
   - The Core Principles section (lines 31–133) is replaced entirely by the automated export block.
   - Fix historical bugs in non-exported sections:
     - Update agent ID examples from `CLE-*` to current `c-`, `g-`, `a-`, `q-`, `m-` (`constitution.md:127`).
     - Align commit identity wording with repo `CLAUDE.md` (`constitution.md:186`).

3. **Fleet rules index (`csi-spl-doc/doc/md/fleet-rules-index.md`):**
   - Update Section 2 ("One home per rule") to designate the Developer Guide Coding Standards section as the canonical home for:
     - Clean code limits (80-line cap, depth 4, parameter limits, SQL `SELECT *` ban).
     - UI translation key rules and raw text ratchets.
     - run-bsh action conventions.
     - Pre-push lint scanner suite.

4. **Spec-kit plan template (`csi-spl-doc/.specify/templates/plan-template.md`):**
   - Line 46: Fix stale `csi-rel-cnf/csi-rel/<env>.env.yaml` to `csi-spl-cnf/csi-spl/<env>.env.yaml`.
   - Align Constitution Check checkboxes (lines 43–50) with the numbered subsections of the Developer Guide Coding Standards.

5. **Agent seed prompt builder (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`):**
   - Keep seed prompts concise and actionable; ensure the STEP 0 developer guide ack continues to point agents directly to `developer-guide.md`.

---

## 5. Build rows (10 actions, rounds-rulebook R1–R16)

Every row adheres to rounds-rulebook R1–R16: at most 10 items, push caps (aim 1, max 3), continuous execution, disjoint files per batch (R1), and explicit vendor matching (Qto text = agy, Bash code & tests = claude).

| # | Slug & commit subject | Practice | Why | Sites file:line (max 5) | n | Test or red control | Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `doc(c002-01-qto-dev-guide-coding-standards)` | Qto authoring, docs | Primary home for coding standards must live in Qto doc c65bbfbd and export to developer-guide.md | Qto doc `c65bbfbd`<br>`csi-spl-doc/doc/md/developer-guide.md` | 1 Qto doc | Author new Coding Standards section in Qto doc c65bbfbd; run `do_spl_doctree_export_md`. **Red control:** verify git diff on `developer-guide.md` contains the new section and valid markdown structure. | sat | agy | specs_and_docs | 1 |
| 02 | `feat(c002-02-orc-export-constitution-action)` | Shell action, automation | Automated export of Coding Standards section from developer guide into constitution | `csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh` | 1 new action | Implement `do_spl_export_constitution_coding_standards`. Test via dry run. Smoke test: `./run -a do_check_dist_hygiene`. | sat | claude | simple_coding | 1 |
| 03 | `test(c002-03-orc-export-constitution-test)` | Unit test, coverage | Guard export action against slicing regressions and formatting corruption | `csi-spl-orc/src/bash/tests/export-constitution-coding-standards.tst.sh` | 1 test script | Implement test verifying extraction, replacement block, and envelope preservation. **Red control:** corrupted delimiter fails test (rc 1); clean input passes (rc 0). | sat | claude | tests | 2 (after 02) |
| 04 | `feat(c002-04-orc-drift-check-constitution)` | Drift detection, gate | Prevent constitution from diverging from developer guide | `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh:37-55` | 1 drift fact | Add fact 8 (`constitution-coding-standards`) comparing developer-guide section with constitution block. Smoke test: `do_check_fleet_rules_drift`. | sat | claude | simple_coding | 1 |
| 05 | `test(c002-05-orc-drift-check-constitution-test)` | Regression test | Prove drift check fails when constitution is edited out of sync | `csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh` | 1 test case | Add test case planting mismatch between developer-guide and constitution. **Red control:** mismatch exits 1; synced files exit 0. | sat | claude | tests | 2 (after 04) |
| 06 | `doc(c002-06-sync-spec-kit-constitution)` | Spec-kit sync, constitution | Sync constitution from developer guide; fix obsolete agent IDs and placeholders | `csi-spl-doc/.specify/memory/constitution.md:1-218` | 1 file | Run `do_spl_export_constitution_coding_standards`. Update header Sync Impact Report to v0.3.0. Verify with `do_check_fleet_rules_drift`. | sat | claude | specs_and_docs | 3 (after 01, 02, 03) |
| 07 | `doc(c002-07-repo-claude-md-pointers)` | Pointer rationalization | Eliminate duplicated rules in CLAUDE.md / AGENTS.md in favor of developer-guide pointers | `CLAUDE.md:47-63,94-117,139-140`<br>`AGENTS.md:1-17` | 2 files | Replace redundant text with links to `developer-guide.md#2-coding-standards`. Verify `do_check_dist_hygiene` clean. | sat | agy | specs_and_docs | 1 |
| 08 | `doc(c002-08-fleet-rules-index-update)` | Index update | Designate Developer Guide Coding Standards as one home for coding rules in fleet index | Qto doc `9d7d5428`<br>`csi-spl-doc/doc/md/fleet-rules-index.md:27-56` | 1 Qto doc | Update Qto doc `9d7d5428` Section 2; run `do_spl_doctree_export_md`. Verify no broken links. | sat | agy | specs_and_docs | 2 (after 01) |
| 09 | `doc(c002-09-spec-kit-template-fix)` | Template hygiene | Fix stale csi-rel remnant in plan-template.md and align Constitution Check | `csi-spl-doc/.specify/templates/plan-template.md:40-50` | 1 template | Fix line 46 (`csi-rel-cnf` -> `csi-spl-cnf`); align Constitution Check list. Verify `do_check_dist_hygiene`. | sat | agy | specs_and_docs | 1 |
| 10 | `test(c002-10-dev-guide-ack-hygiene-gate)` | Gate verification | Re-stamp developer guide ack blob sha and verify full pre-push test suite | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-dev-guide.sh` | 1 test | Re-ack updated developer-guide.md blob sha; run `do_check_pre_push` under `PRE_PUSH_TIER=full`. Pass: all gates green. | sat | claude | tests | 4 (after 01, 06, 07, 08) |

### 5.1 Disjoint files per batch (R1 verification)

- **Batch 1:**
  - Row 01: Qto doc `c65bbfbd`, `csi-spl-doc/doc/md/developer-guide.md`
  - Row 02: `csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh`
  - Row 04: `csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh`
  - Row 07: `CLAUDE.md`, `AGENTS.md`
  - Row 09: `csi-spl-doc/.specify/templates/plan-template.md`
  *Zero overlap across Batch 1 files.*

- **Batch 2:**
  - Row 03: `csi-spl-orc/src/bash/tests/export-constitution-coding-standards.tst.sh` (tests Row 02)
  - Row 05: `csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh` (tests Row 04)
  - Row 08: Qto doc `9d7d5428`, `csi-spl-doc/doc/md/fleet-rules-index.md` (updates pointers to Row 01)
  *Zero overlap across Batch 2 files.*

- **Batch 3:**
  - Row 06: `csi-spl-doc/.specify/memory/constitution.md` (syncs using Rows 01 & 02)
  *Zero overlap with prerequisite batches.*

- **Batch 4:**
  - Row 10: `csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-dev-guide.sh`
  *Final verification batch after all markdown and code edits have landed.*

### 5.2 Off every live lane (R3 verification)

Lane map verification (`bash lane-map.sh --check <paths>`) confirms that none of the target paths for any of the 10 rows are owned by another active lane on any fleet machine.

---

## 6. Panel consensus and signatures

The draft v0.1 plan is submitted to the cross-vendor panel. Reviewer seats verify the inventory, draft outline, export design, and build rows against criteria C1–C7 and R1–R16. Both verdicts are folded into v1.0, signed in each reviewer's seat file, and presented to the owner by the dispatch lease holder before row execution commences.

| Seat | Role | Vendor | Status | Signature (v1.0 SHA) |
|---|---|---|---|---|
| `a-330` | Editor | agy | v0.1 ready | *Pending panel review* |
| `c002-coding-standards-panel-seat-claude` | Reviewer | claude | Awaiting v0.1 | *Pending* |
| `c002-coding-standards-panel-seat-mistral` | Reviewer | mistral | Awaiting v0.1 | *Pending* |
