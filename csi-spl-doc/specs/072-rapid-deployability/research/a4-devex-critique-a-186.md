# 072 research a4: DevEx critique — `./run` surface, naming, errors, and deploy UX

Status: **research a4-devex-critique**, lane `a-186`, for 072 lead (c-165).
Tree: `origin/master` @ `948740213`, 2026-10-04. Scope: `./run` action surface, naming conventions, error messages, deploy steps/env-vars count across P1/P2/P3, one-command target UX, and dead code deletion.
Ranking rule (spec §2, owner prd t1 `6410e374`): usability and DevEx over financial cost. Every claim cites its command (n=1).

## 1. Today, measured

### 1.1 The `./run` action surface and discovery
- **Catalogue sprawl**: `cd csi-spl-iac && ./run --help | grep -c "\./run -a do_"` -> 96 actions; `cd csi-spl-orc && ./run --help | grep -c "\./run -a do_"` -> 241 actions. Total: **337 actions** in a single flat alphabetical list with 0 functional groups and 0 "start here" guidance.
- **Missing front doors**: Only 2 modules have `./run` (`csi-spl-iac`, `csi-spl-orc`). Modules `api`, `wui`, `cnf`, `rdb`, and `doc` have no `./run` wrapper.
- **Heavy sourcing on every invocation**: `do_load_functions` (`csi-spl-iac/run:459`, `csi-spl-orc/run:459`) sources all 372 `*.func.sh` files (`find ... -name "*.func.sh" | wc -l` -> 372) on *every single invocation*, taking ~3.2 s (`iac`) and ~3.7 s (`orc`) just to evaluate `--help`.
- **Phantom action in help footer**: `print-help.func.sh:78` tells users `Tip: Use ./run -a do_help_with --search <keyword>`, but `grep -rn 'do_help_with()' .` -> 0. The recommended help tool literally does not exist.
- **Unsanitized metadata**: Descriptions carry truncated fragments (e.g. `... so a`), name-echo tautologies (`do_gcp_delete_service_account` -> "Gcp delete service account."), and historical owner quotes instead of clear functional summaries.

### 1.2 Naming conventions and parameter handling
- **Prefix fragmentation**: 11 distinct prefixes (`do_spl_*`: 180+, `do_gcp_*`: 36, `do_tf_*`: 19, `do_sec_*`: 10, `do_check_*`: 11, `do_gandi_*`: 6, `do_satellite_*`: 5, `do_oss_*`: 4, etc.) plus un-prefixed actions (`divest`, `tpl-gen`, `build-push-hub-image`, `setup-app-inf`).
- **Inconsistent verb-noun order**: Numbered steps (`do_gcp_001_create_project`) mix with verb-first (`do_check_deploy_lag`, `do_build_push_hub_image`) and noun-first (`do_spl_deploy_lag_alarm`, `do_satellite_verify`).
- **Hidden flag support**: Only 19 `@arg` annotations exist across 372 functions (`grep -rn "@arg" ... | wc -l` -> 19). The remaining 318 functions rely on ambient environment variables (`ENV`, `ORG`, `APP`, `STEP`, `GCP_ACCOUNT`, `DRY_RUN`).
- **Directory layout tyranny**: `resolve-oap.func.sh:13` derives `ORG` and `APP` via `basename "$PROJ_PATH" | cut -d'-' -f"$1"`, breaking any checkout not matching `<org>-<app>-<proj>`.

### 1.3 Error messages and failure reporting
- **Blind fatal stops**: 1,712 `FATAL` / `quit_on` calls across bash scripts (`grep -rnE 'quit_on|do_log "FATAL"' ... | wc -l` -> 1712). Only 24 (1.4%) state an actionable command or fix (`grep -ciE '\./run -a|run:|fix:|next:'` -> 24).
- **Vague variable errors**: `require-var.func.sh:21-23` reports `FATAL The environment variable "<var>" does not have a value !!! In the calling shell do "export <var>=your-<var>-value"`, stating no valid options, defaults, or origin.
- **Trap masking root causes**: `set -E` and `trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR` (`run:102,125`) regularly report internal shell tests (e.g. `FATAL Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 359`) when subshell directory creations fail silently.
- **No typo tolerance**: Invoking an unknown action gives `FATAL action(s) requested: "xyz" NOT found !!!` with zero Levenshtein distance "did you mean" suggestions.

### 1.4 How many commands and env vars a deploy needs today
- **P1 (Docker Compose)**:
  - Commands: 4 (`git clone`, `cp .env.example .env`, edit `.env` + generate 3 passwords via `openssl rand -hex 24`, `docker compose up --build -d`), 241 s build from source (047 §1.1), plus 1 complex 290-char `docker exec` command to extract root key and seat an agent (`README.md:75`).
  - Environment variables: 21 variables for an own-domain profile (`.env.example:68-91`), with domain duplicated across 3 separate keys (`SPOOL_PUBLIC_URL`, `SPOOL_SITE_ADDRESS`, `SPOOL_DOMAIN`).
- **P2 (GCP Estate)**:
  - Commands: 20 to 130 commands (gcp-000 bootstrap with 4 sub-actions, `make do-setup-app-inf`, 18 terraform steps x render/plan/apply x 2 envs = 108 invocations, 7 secret seeds x 2 envs = 14 commands, db bootstrap, 6 `gh variable set` commands, 10-25 min cert wait).
  - Environment variables: ~65 estate variables across 1,435 YAML lines (`csi-spl-cnf/csi-spl/*.yaml`), plus ~12 runtime variables (`ENV`, `ORG`, `APP`, `GCP_ACCOUNT`, `GCP_ORG_ID`, `GCP_FOLDER_ID`, `GCP_BILLING_ACCOUNT_ID`, `DRY_RUN`, `GITHUB_TOKEN`, `STEP`, `PROJ_PATH`).
  - Code edits required: 9 Terraform regex validations enforcing `^csi-spl-` (`grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform | wc -l` -> 9), and `contains(["dev", "prd"], var.env)` in 14 Terraform files.
- **P3 (Agent Box)**:
  - Commands: Git clone (37 MB), Go toolchain install, `install.sh --env <env> --tenant <tenant>`, manual distribution of high-privilege `tenant-root.key` (`README.md:75`).

### 1.5 Target UX: The one-command deploy
- **P1 Compose Target**:
  - Exact command: `./spool-up` (or `curl -fsSL https://<domain>/install.sh | bash` / `./run -a do_spl_self_host_up`).
  - Target UX: Pulls prebuilt public GHCR images (`spool-hub:stable`, `spool-wui:stable`) in < 20 s (no build, no clone); interactive wizard prompts for domain/email/SMTP if `.env` absent; auto-generates DB passwords; runs preflight (DNS, ports 80/443, SMTP, Docker); starts `docker compose up -d --wait`; prints clickable one-time owner confirmation link.
- **P2 GCP Estate Target**:
  - Exact command: `ENV=dev ./run -a do_spl_estate_up` (dry-run default: `DRY_RUN=1 ./run -a do_spl_estate_up ENV=dev`).
  - Target UX: Driven by single 8-key `estate.yaml` template; keyless bootstrap (`BOOTSTRAP_AUTH=impersonate`); automated preflight of IAM and billing; automated state bucket creation; runs terraform sweep with saved plan locks; auto-seeds secrets; auto-wires GitHub variables via `gh`; deploys hub/WUI. Resumable, idempotent.
- **P3 Agent Target**:
  - Exact command: `curl -fsSL https://<domain>/agent-install.sh | bash -s -- --join <TOKEN>`
  - Target UX: Prebuilt `spool` binary download from release assets (< 30 s, no Go, no clone); join token (single-use, 1h TTL, scoped to tenant and agent id minted in WUI); zero root key distribution; configures tmux harness and MCP tools.

### 1.6 What to delete
- **Dead AWS / WordPress / pas-psf remnants** (8 scripts / targets):
  1. `csi-spl-iac/src/bash/run/divest.func.sh`: 28 lines of dead AWS code referencing 2022 agreements and echoing destroy commands.
  2. `csi-spl-iac/src/bash/run/gcp-sync-local-to-s3.func.sh`: WordPress rsync script referencing `wp-config.php`.
  3. `csi-spl-iac/src/bash/run/gcp-sync-s3-to-local.func.sh`: WordPress s3 sync script referencing `wp-config.php`.
  4. `csi-spl-iac/src/bash/run/gcp-sync-src-s3-to-tgt-s3.func.sh`: WordPress s3 sync script.
  5. `csi-spl-iac/src/bash/run/gcp-sync-src-s3-to-tgt-s3-silent.func.sh`: WordPress s3 sync referencing `wp-content/plugins`.
  6. `csi-spl-iac/src/bash/run/gcp-s3-download-all.func.sh`: Legacy S3 download script.
  7. `csi-spl-iac/src/bash/run/tf-apply-local-step-bucket.func.sh`: Reads `.env.aws`, exports `AWS_PROFILE` and `AWS_REGION`.
  8. `csi-spl-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh`: Reads `.env.aws`, exports `AWS_PROFILE` and `AWS_REGION`.
  9. `csi-spl-orc/src/make/tf-tasks.func.mk:27,36`: Demands `AWS_PROFILE` and passes `-e AWS_PROFILE=$(AWS_PROFILE)`.
- **Dead spec 024 tenant-host actions** (superseded by spec 026 single-host `api.<domain>`):
  1. `csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh` (255 lines).
  2. `csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh` (166 lines).
  3. `csi-spl-orc/src/bash/run/spl-tenant-host-deprovision.func.sh` (150 lines).
  4. `.github/workflows/40_tenant-host-reconcile.yml` (disabled workflow).
- **Redundant Dockerfile**:
  1. `csi-spl-orc/src/docker/spool-hub-api/Dockerfile` (distroless build needing host Go; unify into `csi-spl-api/src/docker/hub.Dockerfile`).
- **Dead help references**:
  1. Drop `do_help_with` references in `print-help.func.sh:70,78`, `validate-params.func.sh:59`, and `make-help.func.mk:63`.

## 2. Blockers

1. **Unnavigable 337-action flat list in `./run --help`**: `csi-spl-iac/src/bash/run/help/print-help.func.sh:8-81` outputs all actions indiscriminately; newcomers cannot find entry points.
2. **Missing `do_help_with` command**: `print-help.func.sh:78` advertises a non-existent action (`grep -rn 'do_help_with()' .` -> 0).
3. **Log directory failure triggers misleading trap error**: `csi-spl-iac/run:351` fails on unprivileged directories and blames line 359 `[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]`.
4. **98.6% of fatal exits omit remediation**: 1,712 `FATAL` lines exist; only 24 provide the next command to execute.
5. **No Levenshtein / fuzzy suggestions on typos**: `csi-spl-iac/run:245-249` reports NOT found and dumps the user back to the 337-line `--help` list.
6. **Hardcoded estate naming regexes**: `csi-spl-iac/src/terraform/*/02-variables.tf` has 9 checks requiring `csi-spl-*`, blocking third-party deployments.
7. **Rigid directory name derivation**: `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh:13` forces `<org>-<app>-<proj>` directory layout.
8. **Dead AWS and WordPress scripts in GCP tree**: 8 scripts clutter the catalogue and risk accidental execution.
9. **Superseded spec 024 scripts remain active in catalogue**: 3 scripts (571 lines) remain from disabled tenant-host architecture.
10. **290-char agent connect line requiring root key distribution**: `README.md:75` requires root key on every agent box; high operational and security friction.

## 3. Actions

| # | Action | Owner | Effort | Done criterion (testable) |
|---|---|---|---|---|
| **A-DEV1** | **Purge dead AWS, WordPress, and superseded tenant-host scripts**: Delete `divest.func.sh`, 5 `gcp-*-s3*.func.sh` scripts, 2 `tf-*-local-step-bucket.func.sh` scripts, and 3 `spl-tenant-host-*.func.sh` scripts; drop AWS flags from `tf-tasks.func.mk`. | iac + orc | S (3h) | `git grep -cE 'AWS_PROFILE\|wp-config\|tenant-host' csi-spl-iac csi-spl-orc` -> 0; `csi-spl-iac` catalogue drops from 96 to 88 actions. |
| **A-DEV2** | **Grouped `./run --help` and per-action help**: Add `# @group` metadata; default `--help` displays categorized groups (bootstrap, deploy, gates, dev) and 15 "start here" actions; full catalogue moves behind `--all`; implement `./run -a <act> --help` to show action docstring and arguments; drop `do_help_with` dead tip. | orc + iac | S (4h) | `./run --help` output contains `Start Here:`; `grep -c do_help_with print-help.func.sh` -> 0; `./run -a do_check_dist_hygiene --help` outputs < 25 lines. |
| **A-DEV3** | **Next-command remediation on all FATAL exits and fuzzy typo suggestion**: Update `error_handler`, `require-var.func.sh`, and `do_run_actions` in `run.sh` to output `NEXT: <command>` and suggest closest matching action on typos. | orc + iac | S (4h) | `./run -a do_check_dist_hygien` suggests `do_check_dist_hygiene`; missing `ENV` outputs `NEXT: set ENV=dev (or prd)`. |
| **A-DEV4** | **Unify action naming and argument passing**: Standardize on `do_<verb>_<noun>` naming; migrate 318 functions from ambient environment variables to structured `@arg --flag VAR` metadata tags. | orc + iac | M (5h) | `grep -rn "@arg" csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| wc -l` >= 100; `./run -a do_gcp_001_create_project --env dev --billing-account X` parses cleanly. |
| **A-DEV5** | **P1 one-command UX (`spool-up`)**: Script (or `./run -a do_spl_self_host_up`) that uses GHCR prebuilt images, runs interactive wizard for missing `.env`, validates preflights, runs `docker compose up -d --wait`, and prints owner sign-in link. | orc + docs | M (6h) | On a clean VM with Docker: `./spool-up` finishes in < 2 min; preflight fails before `up` if port 80/443 is blocked. |
| **A-DEV6** | **P2 one-command UX (`do_spl_estate_up`)**: Automated orchestrator reading `estate.yaml`; uses keyless impersonation (`BOOTSTRAP_AUTH=impersonate`); executes preflight, state bucket setup, terraform sweep, secret seeding, GitHub var wiring, and health probe in one resumable action. | iac + orc | M (8h) | `DRY_RUN=1 ENV=dev ./run -a do_spl_estate_up` prints planned execution phases without error; keyless bootstrap creates 0 service account keys. |
| **A-DEV7** | **P3 one-command UX (`agent-install.sh`)**: Installer downloads prebuilt `spool` CLI binary from release assets; authenticates via single-use join token minted in WUI; eliminates local Go build and root key distribution. | api + orc + wui | M (6h) | On a clean VM with no Go: `curl -fsSL ... | bash -s -- --join <tok>` seats agent in < 30 s; `grep -c 'tenant-root.key' install.sh` -> 0. |

## 4. Questions for the owner

1. **Delete all dead AWS, WordPress, and spec 024 tenant-host scripts immediately?**
   - *Recommended*: **Yes**. They clutter the action list (11 actions), contain obsolete references, and risk confusing operators.
2. **Hide internal fleet maintenance actions behind `./run --help --all`, showing only 15 core actions by default?**
   - *Recommended*: **Yes**. 241 orc actions overwhelm newcomers; showing only user-facing actions improves DevEx dramatically.
3. **Mandate that every error message must end with a concrete `NEXT: <command>` line?**
   - *Recommended*: **Yes**. Zero-friction error recovery is essential for open-source self-hosting and rapid deployment.
4. **Deprecate root key distribution to agent boxes in favor of expiring join tokens?**
   - *Recommended*: **Yes**. Distributing `tenant-root.key` (`README.md:75`) is an extreme security risk and bad UX; join tokens solve both.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T07:45:00Z -->
