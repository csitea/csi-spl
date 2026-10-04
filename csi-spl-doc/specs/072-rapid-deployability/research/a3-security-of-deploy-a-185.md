# 072 research a3: security review of the deploy path for outsiders

Status: **research draft**. Author lane: a-185. Tree: `origin/master` @ `b849b5cbe`, 2026-10-04, n = 1 per command.
Docs only: no GCP mutation, no terraform apply, DRY_RUN=1, no credential read or printed.
Placeholders: `<org>`, `<app>`, `<env>`, `<project>`, `<tenant>`, `<fqdn>`, `<box>`.
Scope: cross-cutting security review of deploy paths P1 (compose), P2 (GCP estate), and P3/P3+ (agent boxes / contributors):
key handling, IAM breadth, secrets in CI, default-open endpoints, supply chain, and non-negotiable security invariants.
Ranked by 072 section 2: DevEx and usability first, with hard security boundaries.

## 1. Today (the walk, measured)

### 1.1 Key handling & identities

| identity / key | location & format | permissions | how created | check |
|---|---|---|---|---|
| Project SA key | `$HOME/.gcp/.<org>/key-<project>.json` (mode 600) | **`roles/owner`** | `gcp-002` + `gcp-003` | `grep -n 'role="roles/owner"' csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh` -> 34 |
| CI Deploy key | GitHub secret `GCP_KEY_CSI_SPL_<ENV>` | **`roles/owner`** | step 120 (`gh secret set < "$KEY_PATH"`) | `120-github-general-secrets/03-github-actions-secrets.tf:31` |
| Tenant root key | JSON / key string on operator disk | signs / revokes all pins | `POST /api/v1/checkout/claim` or `tenants` API | `internal/hub/rest.go:436` `verify(t.RootPubKey, payload, req.Sig)` |
| Agent box key | `~/.local/share/spool-agent/keys/<box>.key` | 1 Ed25519 per box | `spool keygen` | `install.sh:456-467`; 002 `trust-modes.md` |

Key distribution findings:
1. **72 lines across 41 files rebuild `.gcp/.<org>` key paths**: `git grep -rnE '\.gcp/\.' csi-spl-iac/src/bash/run/*.sh csi-spl-iac/lib/bash/funcs/*.sh csi-spl-orc/src/bash/run/*.sh | wc -l` -> 72.
2. **Seating an agent box requires the master tenant root key** (`install.sh:456-467`, `spl-desk-pin.func.sh:55-61`). A contributor either receives full root authority over the tenant or waits on manual admin intervention (037 T005 OPEN).
3. **Local mode is completely unsigned**: `grep -n 'unsigned' csi-spl-doc/specs/002-box-agent-messaging/contracts/trust-modes.md` -> line 3.

### 1.2 IAM breadth (P2 GCP estate)

- **`roles/owner` granted to IaC SA**: `gcp-003:34` grants full project ownership to the bootstrap SA, bypassing least privilege.
- **Org-level policy manipulation**: `gcp-002:38` requires `GCP_ORG_ID` (`do_require_var GCP_ORG_ID`), lifts `iam.disableServiceAccountKeyCreation`, and leaves org policy admin bindings permanent. Outsiders without an org cannot bootstrap.
- **Terraform state is keyless** (`csi-spl-iac/src/bash/tests/no-keys-in-tf.tst.sh`), and runtime SAs (Cloud Run, Cloud SQL) are narrow (`030-cloud-run-hub/03-runtime-sa.tf`), but the deploying identity retains owner breadth.

### 1.3 Secrets in CI & fork PRs

- **Static JSON keys are PRIMARY in CI**: `20_hub-build-deploy.yml:24` ("key -- PRIMARY"), while WIF (016/017) is fallback. 35 lines across 5 workflows (`00`, `20`, `30`, `40`, `45`) reference literal `GCP_KEY_CSI_SPL`: `grep -rn 'GCP_KEY_CSI_SPL' .github/workflows/*.yml | wc -l` -> 35.
- **Fork PR isolation**: `pull_request` triggers only `11_ci-public.yml` (`grep -n 'pull_request:' .github/workflows/*.yml` -> 1 hit). `11` runs on `ubuntu-latest` without secrets (`persist-credentials: false`), but **skips all security scans** (no trivy, checkov, gitleaks, or hygiene sweep).
- **7 disjoint secret seed scripts**: `ls csi-spl-orc/src/bash/run/*seed*.sh csi-spl-iac/src/bash/run/*seed*.sh | wc -l` -> 6 scripts + db bootstrap. No preflight verifies secret version presence before Cloud Run rollout.

### 1.4 Default-open endpoints & networking

- **Cloud Run hub is open to the public internet**: `030-cloud-run-hub/04-cloud-run-service.tf:40` sets `ingress = INGRESS_TRAFFIC_ALL`; lines 164-165 bind `roles/run.invoker` to `allUsers`. No Cloud Armor, WAF, or IP allowlist protects REST endpoints.
- **Unauthenticated endpoints**: `/healthz`, `/version`, `/api/v1/checkout/*`, and native auth `/api/v1/auth/*` (`register`, `login`, `password/forgot`, `email/verify`) in `csi-spl-api/src/go/spool-hub-api/internal/auth/native.go:101-106`.
- **P1 compose networking**: Postgres port 5432 is **not exposed** to host interfaces (`grep -n '5432:' docker-compose.yml | wc -l` -> 0, good). Web proxies 8080/8443 on `${SPOOL_BIND:-127.0.0.1}`. Default DB passwords are encrypted or refused off localhost (`config.go`).

### 1.5 Supply chain & script integrity

- **Zero digest-pinned container base images**: 8 `FROM` lines in 6 Dockerfiles; 0 use `@sha256:` digests (`git grep -cE 'FROM.*@sha256' -- '*Dockerfile*'` -> 0 hits). All use mutable tags (`golang:1.25-alpine`, `alpine:3.22`, `node:20-alpine`, `caddy:2-alpine`, `postgres:16-alpine`).
- **Unverified binaries & scripts in `install.sh`**:
  1. Vendor CLI installers fetched over HTTPS and piped to `bash` with only a 2-byte `#!` check (`install.sh:224-229`).
  2. `yq` binary fetched from GitHub `/releases/latest/download` with no hash verification (`install.sh:241-245`).
  3. Go tarball fetched from `go.dev/dl/` with no checksum verification (`install.sh:279-282`).
- **Dangerous settings rewrite**: `install.sh:449` writes `skipDangerousModePermissionPrompt: true` into `~/.claude/settings.json` (`assets/claude/settings/00-fleet.json:2`) and 124 lines of `~/.claude/CLAUDE.md` without prompting the user (`grep -c SPOOL_INSTALL_CLAUDE_CONFIG install.sh` -> 0).
- **Zero signed release artifacts**: `gh release view stable-2026-09-29 --json assets --jq '.assets|length'` -> 0 assets, 0 public container images on GHCR, no `cosign` signatures or SBOMs.

### 1.6 What a fast deploy must NOT trade away (the 6 security boundaries)

In optimizing for 1-command deployment and DevEx, the following 6 security boundaries are non-negotiable:
1. **Never distribute root signing authority**: Worker agents only need permission to join a workspace, never the tenant root private key.
2. **Never default to full admin/owner IAM**: A fast setup script must not grant `roles/owner` or bypass IAM boundaries to make execution "just work".
3. **Never pipe untrusted or unchecksummed network streams to bash**: Remote downloads must verify cryptographic hashes or signatures.
4. **Never disable agent sandboxes or confirmation prompts automatically**: Speed cannot justify silently rewriting host security guardrails (`skipDangerousModePermissionPrompt`).
5. **Never expose internal persistence to public networks**: Postgres and internal APIs must remain bound to localhost or isolated container networks.
6. **Never allow external pull requests access to secrets or production runners**: Fork PRs must run completely keyless and sandboxed.

## 2. Blockers

1. **B1: IaC service account holds `roles/owner` in GCP bootstrap.**
   `csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh:34`. Third parties cannot accept deploying via full project owner; any leaked key compromises the entire GCP project.
2. **B2: Static owner key in GitHub Actions is PRIMARY auth over WIF.**
   `20_hub-build-deploy.yml:24`, 35 lines across 5 workflows. Secrets carry literal `<org>` names and keep long-lived cloud keys in CI.
3. **B3: Seating an agent box requires the master tenant root key.**
   `csi-spl-orc/src/bash/features/spool-install/install.sh:456-467`, `spl-desk-pin.func.sh:55-61`. Outsiders must be given root tenant keys (037 T005 OPEN).
4. **B4: `install.sh` pipes unverified scripts to bash and downloads binaries without checksums.**
   `install.sh:224-229` (curl to bash with `#!` check only), `install.sh:241-245` (unverified yq), `install.sh:279-282` (unverified Go).
5. **B5: All Dockerfile base images use floating mutable tags without SHA256 digests.**
   `git grep -cE 'FROM.*@sha256' -- '*Dockerfile*'` -> 0 hits across 6 Dockerfiles. Upstream tag re-pointing can inject untrusted code.
6. **B6: Installer disables AI safety prompts and overrides global agent config by default.**
   `assets/claude/settings/00-fleet.json:2` (`skipDangerousModePermissionPrompt: true`), `install.sh:449`. Overrides host security settings without consent.
7. **B7: Public Cloud Run hub exposes all endpoints without edge rate limiting or WAF.**
   `030-cloud-run-hub/04-cloud-run-service.tf:40,165` (`INGRESS_TRAFFIC_ALL`, `allUsers` invoker). Unauthenticated routes are vulnerable to abuse.
8. **B8: Contributor pull requests bypass security and hygiene scanners.**
   `11_ci-public.yml:30-100` runs only hub/wui suites, omitting trivy, checkov, gitleaks, and distribution hygiene checks.

## 3. Actions

Effort: XS (< 0.5 d), S (<= 1 d), M (2-5 d). One lane each.

| # | action | ties | owner | effort | done-criterion (testable) |
|---|---|---|---|---|---|
| **S1** | **Scoped box join tokens with TTL (replaces root key in seating)**: Hub issues expiring join tokens (`claims: {tenant, expiry, max_boxes}`); `spool hub-pin` verifies join token without root key; `install.sh --token <tok>` seats cleanly | 072 A5, G7; B3 | api | S-M | `install.sh --token <tok>` pins successfully with `ROOT_KEY_JSON=""`; test proves join token cannot revoke pins or mint tokens |
| **S2** | **Mandatory WIF in CI, retire static JSON keys**: Workflows 00, 20, 30, 40, 45 make WIF mandatory; remove `credentials_json` fallback for external forks; generalize secret names to `GCP_KEY_<ENV>` | 072 A11, 09 K3; B2 | CI | S | `grep -c GCP_KEY_CSI_SPL .github/workflows/*.yml` -> 0; workflow test passes using WIF only |
| **S3** | **Supply-chain integrity: checksum verification & digest pinning**: Pin sha256 checksums for Go and `yq` in `install.sh`; pin all Dockerfile base images to `@sha256:<digest>` | 072 A1, A4, 15 C6; B4, B5 | orc+api | S | `install.sh` fails closed on corrupt tarball; `git grep -cE '^FROM.*@sha256:' -- '*Dockerfile*'` equals total base images |
| **S4** | **Opt-in agent configuration without disabling safety prompts**: Default `SPOOL_INSTALL_CLAUDE_CONFIG=0` for external installs; require explicit `--force-dangerous-mode` before setting `skipDangerousModePermissionPrompt` | 072 A28, 10 B1; B6 | orc | XS | `test-claude-config.sh` proves default install leaves `skipDangerousModePermissionPrompt` absent/false |
| **S5** | **Least-privilege project SA roles (narrowing `roles/owner`)**: Audit roles via `do_gcp_audit_iam`; replace `roles/owner` in `gcp-003` with exact permissions needed for terraform resources | 072 A10, 09 K8; B1 | iac | M | Full terraform plan/apply runs in throwaway project without `roles/owner`; `grep -c roles/owner gcp-003*.sh` -> 0 |
| **S6** | **Public PR security scan gate**: Add read-only security scans (gitleaks, trivy config, checkov, dist hygiene) to `11_ci-public.yml` so vulnerabilities are caught before merging | 072 A13, F22; B8 | CI | S | PR with planted secret or misconfigured IaC fails `11_ci-public.yml` on GitHub-hosted runner |
| **S7** | **Automated secret generation and preflight check**: `spool-up` generates random passwords via `/dev/urandom`; `do_spl_secrets_check` verifies all required Cloud Run secret slots have enabled versions | 072 A2, 09 K1, K2; B7 | orc+iac | S | `.env` generated without manual openssl commands; `do_spl_secrets_check` exits 1 if any mapped secret slot is empty |
| **S8** | **Edge rate limiting and route protection for Cloud Run**: Add rate limiting middleware to unauthenticated routes (`/api/v1/auth/*`, `/api/v1/checkout/*`) to prevent brute force and resource exhaustion | 072 A9; B7 | api | S-M | Load test against `/api/v1/auth/register` returns HTTP 429 after threshold |

Sequence by 072 section 2 (DevEx and error clarity): **S1, S3, S4** first (fixes outsider box install and seating without risk), then **S2, S6, S7** (CI and secret generation), followed by **S5, S8** (IAM narrowing and rate limiting).

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Replace tenant root key seating with scoped, expiring join tokens (S1)? | **yes**: Outsiders must never hold tenant master keys; join tokens isolate worker agent seating from administrative control. |
| Q2 | Retire static `roles/owner` keys from GitHub secrets and enforce keyless WIF in CI (S2)? | **yes**: WIF is already built; dropping static JSON keys eliminates credential theft risks and decouples repo forks from estate naming. |
| Q3 | Preserve agent safety prompts (`skipDangerousModePermissionPrompt: false`) in `install.sh` by default (S4)? | **yes**: Silently disabling permission prompts in user environments violates the principle of least surprise and creates severe supply-chain liability. |
| Q4 | Pin all container base images and installer tool downloads by SHA256 digest (S3)? | **yes**: Fast deployment must guarantee repeatable, tamper-proof builds without relying on mutable third-party registry tags. |
