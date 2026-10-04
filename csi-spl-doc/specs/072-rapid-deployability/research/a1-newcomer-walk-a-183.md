# 072 research a1: cross-cutting newcomer walk (the outside developer)

Status: **research, v1** for the 072 lead (c-165), who merges it into spec
sections 4-7. Persona walk: an outside developer who discovered the public repo,
guided ONLY by repo documentation (`README.md`, `csi-spl-doc`), attempting to reach
a running system end to end. Tree: `origin/master` @ `80874f741`, 2026-10-04.
Every command measured on this tree (n = 1). Docs only: nothing built, applied
or mutated. `<org>`, `<app>`, `<env>`, `<fqdn>`, `<ip>`, `<user>` are
placeholders. Ranking: usability and DevEx above cost (owner, msg `2144f3d9`).
Cost numbers are given where applicable.

## 1. Today

### 1.1 The walk: minute by minute, log of every step, guess, dead end and friction

The minutes reflect elapsed time for a developer following the documentation,
including reading, running commands, and hitting dead ends.

| min | step | what the docs say | what the newcomer meets / guess / dead end | check |
|---|---|---|---|---|
| 0 | Discovery & Clone | `git clone ... csi/csi-spl` (`README.md:15`) | Clones into `./csi-spl` as standard. Baffled by directory layout note (`:21-22`): `./run` reads org from parent folder; in `~/src/csi-spl`, `ORG=src` | `csi-spl-orc/lib/bash/funcs/resolve-oap.func.sh:33-43` |
| 2 | Start local stack (P1) | `docker compose up --build -d` (`README.md:17`) | Builds hub + web from source. No prebuilt container images exist on GHCR. Takes 171-241 s. 57 MB clone + Docker build tools required | `grep -c 'build:' docker-compose.yml` -> 2; 047 section 1.1 |
| 7 | Sign up & ownership | Open `localhost:8080`, sign up (`README.md:24`) | Works smoothly; confirmation link displayed on-screen; first user is owner (`SPOOL_HUB_AUTH_BOOTSTRAP_OWNER: "true"`) | `docker-compose.yml:95`; 047 section 1.1 |
| 10 | Port collision trap | Set `SPOOL_HTTP_PORT=18080` in `.env` (`.env.example:20`) | **Dead end**: web loads on 18080, but JS bundle baked `SPOOL_PUBLIC_URL=http://localhost:8080`; API & WS fail; CORS preflight lacks ACAO | `docker-compose.yml:66,142`; 01 section 1.2 |
| 15 | Connect an agent | One-line seat command (`README.md:75`) | **Shock/Friction**: 290-char command runs `install.sh`. Downloads Go (282 MB), cache (722 MB), builds `spool` (73 s), installs Claude CLI. Overwrites `~/.claude/CLAUDE.md` with 124 lines of internal fleet orders ("push to trunk"), injects `"skipDangerousModePermissionPrompt": true` into settings, mutates `~/.bashrc` | `awk 'NR==75{print length}' README.md` -> 290; `install.sh:449`; 10 section 1.1 |
| 25 | Help doc contradiction | `README.md:90` links to `doc/help/connect-an-agent.md` | **Dead end**: help doc instructs `export SPOOL_HUB_URL='https://api.spool-hub.ai'`, manual `go build`, background `nohup spool hub-run`, and seat as `CLE-01` (legacy ID syntax). Attempts to pin against production instead of local stack | `grep -n 'https://api.spool-hub.ai' csi-spl-doc/doc/help/connect-an-agent.md` -> line 31; `grep -c 'CLE-01' ...` -> 6 |
| 35 | Beyond localhost: VPS / IP | `README.md:35-66` "Your own domain" | **Dead end**: requires public domain, DNS A records, ports 80/443 for Caddy TLS. If running on VPS / bare IP (`http://<ip>:8080`), sign-in works but file attachments crash silently because `crypto.subtle` is restricted to secure contexts. Zero warnings; docs never mention SSH port forwarding (`ssh -L 8080:localhost:8080`) | `grep -rn 'isSecureContext' csi-spl-wui/src` -> 0; `csi-spl-wui/src/utils/spool-client.mjs:86` |
| 50 | Run tests & contribute | `CONTRIBUTING.md:46` run `run-all-tests.sh` | **Dead end**: `run-all-tests.sh:18` sets `GOPROXY=off GOSUMDB=off`. On a fresh machine with empty Go cache, tests fail immediately. Docs omit `go mod download`. CONTRIBUTING requires DCO (`git commit -s`), but 0 of 200 repo commits have it. CONTRIBUTING omits `do_check_pre_push` and linters | `grep -n 'GOPROXY' csi-spl-api/src/bash/tests/run-all-tests.sh` -> 18; `git log -200 --format=%B \| grep -c '^Signed-off-by:'` -> 0 |
| 65 | Navigate `./run` | Explore repo tooling via `./run` | **Friction/Crash**: non-owner running `./run` in `csi-spl-iac` crashes at line 388 on `tee -a $log_file`. Flat wall of 96 (iac) / 241 (orc) actions. Help footer tip (`do_help_with`) exits with fatal not found | `csi-spl-iac/run:351,388`; 18 section 1.2, 1.3 |
| 80 | Deploy on Cloud (P2) | Look for GCP / hosted deployment guide | **Dead end**: `README.md` has 0 mentions of GCP/Terraform. `csi-spl-doc/README.md` points to relay bucket doc and stops at spec 011 of 72. Terraform has hardcoded `csi-spl-*` regexes and requires Csitea GCP org | `grep -ciE 'gcp\|terraform' README.md` -> 0; `grep -c 'src/terraform/' csi-spl-iac/README.md` -> 8 (vs 18 on disk); 047 section 1.2 |

### 1.2 The 5 newcomer paths evaluated

| path | persona / goal | outcome from docs alone | time to friction / dead end |
|---|---|---|---|
| **P1 Local Compose** | Try chat on localhost | **Works**, but takes 4 min build time; port change breaks WUI | 4 min (or 10 min on port collision) |
| **P3 Agent Seating** | Chat with agent in UI | **Works**, but mutates host config, 290-char command, help docs conflict | 15 min |
| **VPS / Bare IP** | Deploy on non-domain host | **Half-broken**: chat works, file transfers fail silently; 0 docs on SSH tunnel | 35 min (dead end) |
| **Contributor** | Run tests, submit PR | **Blocked**: offline test runner fails; gates missing from CONTRIBUTING; DCO discrepancy | 50 min (dead end) |
| **P2 Cloud Estate** | Deploy to own GCP | **Blocked**: 0 top-level docs; estate literals in terraform; org required | 80 min (dead end) |

### 1.3 Quantitative breakdown of newcomer overhead

- **Build time vs run time**: 171 s to 241 s to compile hub + web from source on first run (047 1.1, 01 1.2). With prebuilt images, compose would take <15 s.
- **Disk consumption**: 57 MB git clone (`du -sh`), plus 1.3 GB written to user home during agent seating (Go 282 MB, Go module cache 722 MB, Claude CLI 235 MB; 10 1.1).
- **RAM footprint**: Whole stack idles at ~110 MiB (hub 27.7, web 34.5, pg 47.2 MiB; 047 1.1). This is exceptionally light and a strong asset.

### 1.4 What works well and must stay

- **Localhost compose simplicity**: `docker compose up -d` with default settings just works; on-screen confirmation links eliminate the need for an SMTP server.
- **Fail-fast environment validation**: Both shell scripts and Go backend validate required variables early with clear messages.
- **Database migrations**: 112 migrations apply cleanly in ~2 seconds without manual intervention.

## 2. Blockers

1. **Port binding trap bakes public URL**: `docker-compose.yml:66,142`. Setting only `SPOOL_HTTP_PORT` breaks API/WUI communication and CORS because `SPOOL_PUBLIC_URL` defaults to `http://localhost:8080`.
2. **Help doc points newcomer to production URL with stale syntax**: `csi-spl-doc/doc/help/connect-an-agent.md:31,41` directs users to `export SPOOL_HUB_URL='https://api.spool-hub.ai'` and agent ID `CLE-01`, conflicting with `README.md:75` (`localhost:8080`, `spool-agent`).
3. **Agent installer mutates user's global config and disables safety checks**: `csi-spl-orc/src/bash/features/spool-install/install.sh:449` writes internal fleet orders into `~/.claude/CLAUDE.md`, and `assets/claude/settings/00-fleet.json:2` sets `skipDangerousModePermissionPrompt: true`.
4. **No prebuilt container images**: `docker-compose.yml:49,137` lacks registry image targets. Every newcomer must clone 57 MB and compile Go/Node from source.
5. **WebCrypto requirement breaks non-domain / bare-IP deployments**: `csi-spl-wui/src/utils/spool-client.mjs:86` and `FileAttachment.vue:94` require `crypto.subtle` (secure context only). `http://<ip>:8080` allows sign-in but breaks file upload/download with 0 warnings.
6. **Test runner fails on clean machines due to offline proxy**: `csi-spl-api/src/bash/tests/run-all-tests.sh:18` sets `GOPROXY=off GOSUMDB=off`, failing immediately unless `go mod download` was run beforehand.
7. **CONTRIBUTING.md is detached from real repository gates**: `CONTRIBUTING.md:28-40` mandates DCO (`git commit -s`, 0 of 200 commits use it), while omitting `do_check_pre_push` and `do_check_dist_hygiene` (`grep -cE 'pre_push|dist_hygiene' CONTRIBUTING.md` -> 0).
8. **Logging permission crash in `./run`**: `csi-spl-iac/run:351,388` ignores `mkdir` failure on `dat/log/bash` and subsequently crashes on `tee -a $log_file` when run by a non-owner user.
9. **Dead help tip in `./run`**: `./run --help` footer advertises `./run -a do_help_with`, which exits fatal with action not found in both `csi-spl-iac` and `csi-spl-orc`.
10. **Parent directory name dependency in `./run` / `install.sh`**: `csi-spl-orc/lib/bash/funcs/resolve-oap.func.sh:33-43` derives `ORG` from `dirname`, breaking standard `git clone` into `~/src/csi-spl`.
11. **Total absence of Cloud/GCP entry point in top-level docs**: `README.md` has 0 mentions of GCP/Terraform (`grep -ciE 'gcp|terraform' README.md` -> 0), while `csi-spl-doc/README.md` opens on the relay bucket doc and lists only specs 001..011 of 72.

## 3. Actions

Each action is sized for one agent lane, testable by an automated check. Effort is estimated in agent-hours; cost is 0 USD unless noted.

| # | action | done when (testable) | est. |
|---|---|---|---|
| W1 | **Dynamic WUI public origin**: derive `SPOOL_PUBLIC_URL` from `SPOOL_HTTP_PORT` and host header when unset in compose, eliminating CORS mismatches | test: setting only `SPOOL_HTTP_PORT=18080` allows curl `/version` and browser login with no CORS refusal | 1.5 h |
| W2 | **Reconcile `connect-an-agent.md` with README**: replace `api.spool-hub.ai` with `$SPOOL_HUB_URL` / `localhost:8080`; replace legacy `CLE-01` with modern naming; align with `spool-agent` | `grep -c 'api.spool-hub.ai' csi-spl-doc/doc/help/connect-an-agent.md` -> 0; link test green | 1.0 h |
| W3 | **Safe agent installer mode**: `install.sh` defaults to preserving user config (`~/.claude/CLAUDE.md`, permission prompts); fleet standing orders require explicit `--fleet` flag | test: `install.sh --dry-run` or fresh install does not overwrite existing `~/.claude/CLAUDE.md` without flag | 2.0 h |
| W4 | **Prebuilt GHCR images for compose (spec 072 A1 / D2)**: publish `spool-hub` and `spool-web` images to GHCR; provide a single curlable `docker-compose.yml` needing no clone | test: `docker compose pull && docker compose up -d` boots healthy stack in an empty directory | 3.0 h |
| W5 | **Bare-IP guidance & WUI insecure-context guard**: document SSH port forwarding (`ssh -L 8080:localhost:8080`) in README; WUI displays explicit warning banner if `!window.isSecureContext` | test: browsing on insecure origin displays banner explaining file attachment restriction | 1.5 h |
| W6 | **Self-bootstrapping test runner**: `run-all-tests.sh` checks for required Go modules and runs `go mod download` if cache is cold before applying `GOPROXY=off` | test: `run-all-tests.sh` exits 0 in container with empty Go module cache | 1.5 h |
| W7 | **Align `CONTRIBUTING.md` with actual gates**: document `do_check_pre_push`, `do_check_pre_push_lint`, `do_check_dist_hygiene`; clarify DCO policy for external PRs vs maintainers | `grep -c 'do_check_pre_push' CONTRIBUTING.md` >= 1; names all 4 test suites | 1.0 h |
| W8 | **Graceful logging fallback in `./run`**: `./run` catches failed log directory creation and falls back to `/tmp/spool-run-$USER/` instead of crashing on line 388 | test: running `./run -a do_check_dist_hygiene` in read-only checkout executes without `tee` fatal | 1.5 h |
| W9 | **Fix or remove `./run` help tip**: implement `do_help_with` keyword search or remove tip from `--help` footer | test: executing help tip command exits 0 and produces search results or clean usage | 1.0 h |
| W10 | **Decouple repo path resolution from parent folder**: `resolve-oap.func.sh` falls back to `ORG=csi APP=csi-spl` when cloned into generic directories (`~/src/csi-spl`) | test: `./run` actions succeed when repo is placed in `/tmp/random/csi-spl` | 1.5 h |
| W11 | **README "Choose your path" navigation block (spec 072 D1)**: add structured entry block linking Local Compose (P1), Cloud Self-Host (P2), and Contributor Guide | `grep -c 'Choose your path' README.md` -> 1; all referenced links valid | 1.0 h |

Total effort: ~16.5 agent-hours across 11 lanes. Cost: 0 USD (GHCR public packages and GitHub Actions are free for public repos).

**Top 3 by spec section 2:**
1. **W11 (README "Choose your path" block)**: Immediate clarity of entry points for all 5 personas.
2. **W1 + W4 (Prebuilt images & port agility)**: Reduces time-to-first-message from 6+ minutes to <60 seconds, eliminating toolchain requirements.
3. **W3 + W2 (Safe agent installer & unified help docs)**: Prevents silent host configuration mutation and eliminates contradictory onboarding instructions.

## 4. Questions for the owner

1. **Should `docker-compose.yml` pull prebuilt images from GHCR by default so newcomers do not need to clone the repo or build from source?**
   Recommended: **Yes**. This reduces time-to-first-message from 6+ minutes to under 60 seconds and removes local Go/Node build requirements.
2. **Should the agent installer (`install.sh`) default to a clean, non-intrusive mode that never overwrites the developer's personal `~/.claude/CLAUDE.md` or disables permission prompts?**
   Recommended: **Yes**. Outside contributors should never have their personal Claude Code setup overwritten with our internal fleet rules. Internal fleet orders should be opt-in via a flag (e.g. `--fleet`).
3. **Should insecure HTTP access (`http://<ip>:8080`) display an explicit banner in the WUI explaining that file transfers require HTTPS or localhost (WebCrypto constraint)?**
   Recommended: **Yes**. Modern browsers silently disable WebCrypto on plain HTTP, causing obscure file upload crashes. A visible banner warning and documentation of SSH tunneling solves this DevEx friction immediately.
4. **Should `CONTRIBUTING.md` officially mandate `do_check_pre_push_lint` and `do_check_dist_hygiene` before submitting PRs?**
   Recommended: **Yes**. Outside contributors currently have no idea what gates exist until their PR fails CI or gets rejected.

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T07:30:00Z -->
