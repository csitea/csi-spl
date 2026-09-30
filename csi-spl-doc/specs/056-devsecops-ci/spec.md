# Feature Specification: DevSecOps security tooling in CI/CD

**Feature ID**: `056-devsecops-ci` · **Milestone**: M3 · **Status**: Draft — awaiting owner "go"
**Created**: 2026-09-30 · **Lanes**: CLE-77790 (security testing), CLE-77789 (supply chain + hardening) · **Issue**: TBD (owner topic `875651f8-12bf-4335-ac7e-f410b5dbf324`)
**Authority**: this file. It extends the existing sec gate `.github/workflows/15_sec-deps-secrets.yml`
(`do_sec_scan`: govulncheck, pnpm audit, gitleaks, trivy — each with a negative control) and reuses
its pattern for every new tool.

> **Public repo, live multi-tenant product.** Round `875651f8`. The owner DECIDED (in `875651f8`):
> *"ok, let's do specs first and a smaller scope."* This spec is a **numbered list of at most 20 changes,
> highest value first** — the well-known tools the owner named — each proven with a control. Build NOTHING
> until the owner says "go".

## 1. The owner's decision, verbatim

prd t1 topic `875651f8` (HUM-10), in order:

> "list 30 DevSecOps best practices and start working on them"
> "at least 60 small changes needed with no more than 2 agents in parallel working"
> "in the CICD" · "some of the MOST well knows tools SAST etc. MUST be used"
> "Also at the end suggest how can we improve the whole DevSecOps setup on the project"
> "ok, let's do specs first and a smaller scope"

So: **spec first**, at most **20 CI/CD changes**, the best-known tools, each small (one commit + one
issue), each proven with a control, no regression, live in CI on dev and prd.

## 2. Definitions — what "done" means

A change is **done** only when ALL of:
1. **Merged** to `master` (fast-forward, linear), authored with the canonical committer identity named in `/opt/csi/csi-spl/CLAUDE.md`, no AI trailer.
2. **Fleet gate green** on that sha — full `run-all-tests.sh` + `gofmt -l` (+ WUI unit/e2e/typecheck for WUI-touching); no regression.
3. **Negative control** — the acceptance test plants the exact thing the check must catch and asserts it is caught; a silent/green tool must NOT pass. A missing tool fails closed (never a silent skip).
4. **Triaged baseline** — the current tree is clean at the chosen severity (passes-after), so the gate is green today and reddens only on a NEW finding. Never weaken a guard to make a check pass.
5. **Live in CI** — runs on the self-hosted runner (or SARIF to GitHub code scanning, free for this public repo), confirmed green on a real run, not just locally.

## 3. Rules (apply to every item)

- One item = **one commit** (explicit pathspec) **= one issue** (label `security`), under one epic per lane.
- Every shell/test command runs **under a timeout** (`timeout 90 …` / job `timeout-minutes`); a hang is a failure (the fleet gate once hung 5 h with no timeout).
- Fetch + rebase onto `origin/master`, **re-test**, push; decide "landed" from repo state (`git merge-base --is-ancestor`), never from push output.
- New workflow files are **SHA-pinned** from the start and carry top-level `permissions:` + per-job `timeout-minutes` (enforced by `workflow-actions-sha-pinned.tst.sh`).
- File ownership: new files `60–69` = CLE-77790; `70/80/85` = CLE-77789. The 12 existing workflows and `15_…` are edited only by CLE-77789 (route requests via agent-send).
- Heavy tools (CodeQL, Semgrep, ZAP) run on **schedule + workflow_dispatch + path-scoped push**, not every fleet push, to spare the shared runner.
- **Owner-go** required (prepared as a blocker, not applied): anything hitting a live environment (OWASP ZAP against dev), terraform apply, IAM, secret rotation.
- **Hourly status** to CLE-001; secrets never printed; GCP only via SA key + `--account` in a throwaway `CLOUDSDK_CONFIG`; never export `GIT_WORK_TREE`/`GIT_DIR` (it poisons the shared git config).

## 4. The numbered list (20, highest value first)

Legend — Lane: **B** = CLE-77790 (security testing), **S** = CLE-77789 (supply chain). Est: S≈1–3 h, M≈3–5 h.

| # | Change (tool) | What it catches (1 line) | File(s) | Acceptance check (fails-before / passes-after) | Lane | Est | Done? |
|---|---|---|---|---|---|---|---|
| 1 | **CodeQL (Go)** SAST → SARIF code scanning | injection, path traversal, unsafe crypto in hub Go | `60_codeql.yml` (+ `codeql-config.yml`) | control: seeded taint flow appears in SARIF / trunk baseline triaged → 0 new | B | M | no |
| 2 | **CodeQL (JS/TS)** SAST → SARIF | XSS, prototype-pollution, unsafe DOM in WUI | `60_codeql.yml` | control: seeded XSS in SARIF / triaged → 0 new | B | M | no |
| 3 | **Semgrep** (OWASP + golang + typescript) | broad SAST patterns across Go + TS | `61_semgrep.yml`, `sec-semgrep.func.sh`+test, `.semgrepignore` | control: planted `eval`/hardcoded-secret rule fires / tree → 0 | B | M | no |
| 4 | **gosec** (Go SAST) | Go insecure patterns (weak rand, sql concat, file perms) | `62_gosec.yml`, `sec-gosec.func.sh`+test | control: planted `math/rand` flagged / hub → 0 (triaged) | B | M | no |
| 5 | **TruffleHog** verified-secret scan (2nd opinion) | *live* credentials gitleaks' regexes miss (provider-verified) | `64_trufflehog.yml`, `sec-trufflehog.func.sh`+test | control: planted verifiable token detected / tree → 0 | B | M | no |
| 6 | **Checkov** (terraform IaC) | insecure GCP terraform (public buckets, open IAM) | `65_iac.yml`, `sec-checkov.func.sh`+test, `.checkov.yaml` | control: planted public bucket flagged / `src/terraform/**` → 0 | B | M | no |
| 7 | **tfsec** (terraform IaC, 2nd opinion) | terraform rules tfsec covers | `65_iac.yml`, `sec-tfsec.func.sh`+test | control: planted rule fires / terraform → 0 (triaged) | B | S | no |
| 8 | **shellcheck** (bash actions) | quoting/glob/logic bugs in `*.func.sh` (error level) | `67_shellcheck.yml`, `sec-shellcheck.func.sh`+test | control: planted SC2144 flagged / iac+orc+cnf bash → 0 error (4 shebang fixes precede) | B | M | partial |
| 9 | **hadolint** (Dockerfiles) | insecure/broken Dockerfile instructions (error level) | `66_hadolint.yml`, `sec-hadolint.func.sh`+test, `.hadolint.yaml` | control: planted bad Dockerfile flagged / 6 Dockerfiles → 0 error | B | — | **DONE** (81016b84) |
| 10 | **ESLint security plugin** (WUI) | insecure JS/TS (eval, non-literal fs, regex DoS) | `63_eslint-security.yml`, `csi-spl-wui/eslint.config.*` | control: planted `eval` flagged / WUI src → 0 (triaged) | B | M | no |
| 11 | **OWASP ZAP baseline** DAST + security-headers vs **dev** (read-only, rate-limited, never prd) | runtime web vulns + missing HSTS/CSP/X-CTO/Referrer-Policy on the live dev app | `68_dast-zap.yml`, `.zap/rules.tsv`, `sec-headers.func.sh`+test | control: ZAP flags a seeded header gap / dev baseline → 0 above threshold | B | M | no (**owner-go**) |
| 12 | **SHA-pin** every workflow `uses:` | a re-pointed action tag (tj-actions 2025) injecting CI code | `.github/workflows/*`, `workflow-actions-sha-pinned.tst.sh` | control: an unpinned `@v4` detected / all workflows pinned → 0 | S | — | **DONE** (8bd175f9) |
| 13 | **Least-privilege `GITHUB_TOKEN`** per workflow/job | a compromised step using a write-default token to push/publish | `.github/workflows/*` (top-level + per-job `permissions:`), `workflow-permissions-declared.tst.sh` | control: a workflow with no `permissions:` flagged / all scoped → 0 | S | S | partly (99 held; top-level 11/12) |
| 14 | **Per-job `timeout-minutes`** everywhere | a hung job holding a runner (measured 5-h hang) | `.github/workflows/*`, `workflow-job-timeouts.tst.sh` | control: a job with no `timeout-minutes` flagged / all set → 0 | S | S | partial |
| 15 | **OSV-Scanner** (multi-ecosystem lockfile vulns) | known-vuln deps (npm + Go, lockfile-level) beyond govulncheck reachability | `70_supply-chain.yml`, `sec-scan.func.sh` `osv` mode | control: planted vulnerable lock entry → non-zero / clean → 0 | S | M | no |
| 16 | **Trivy fs + IaC misconfig** scan | tree CVEs + terraform/Dockerfile misconfig (image scan already live) | `sec-scan.func.sh` `fs`/`iac`, `15`/`70` | control: planted CVE + planted tf misconfig → non-zero / clean → 0 | S | M | partly (image done, `15:111`) |
| 17 | **Checksum-verify** every downloaded CI tool | a MITM/registry swap of a tool binary (gitleaks not yet verified) | `15_sec-deps-secrets.yml` (gitleaks step) | control: a wrong sha256 fails the install step | S | S | partly (trivy done `15:103`) |
| 18 | **`go mod verify`** in CI | a tampered Go module vs `go.sum` | `10_ci-quality.yml` Go job + control | test asserts CI runs `go mod verify`; control: mutated dep fails | S | S | no |
| 19 | **actionlint** on the workflows | broken/insecure workflow YAML (bad `run:`, injection) | `85_actionlint.yml` + action | control: a planted workflow error → actionlint non-zero | S | S | no |
| 20 | **Dependabot** config (gomod + npm + actions) | deps/actions silently drifting behind security releases | `.github/dependabot.yml` | test asserts all three ecosystems present | S | S | no |

**Already live (context, not counted):** Gitleaks secrets + full history (`15`), govulncheck (`15`), Trivy image (`15:111`), pnpm audit moderate+ (`15`).

## 5. Sequencing (once the owner says "go")

1. **Fast control-testable CLI tools first** (breadth + green quickly): #8 shellcheck, #4 gosec, #5 TruffleHog, #6 Checkov, #7 tfsec, #10 ESLint. (#9 hadolint done.)
2. **SARIF/native SAST** (heavier, schedule+dispatch): #1/#2 CodeQL, #3 Semgrep.
3. **Supply chain (S)**: #13 permissions, #14 timeouts, #17 checksum, #18 go-mod-verify, #15 OSV, #16 Trivy-fs/IaC, #19 actionlint, #20 Dependabot.
4. **Owner-go, live-dev**: #11 ZAP + headers — prepared as a blocker (exact URL, rate-limit, dev-only proof), applied only on the owner's go.

## 6. Iteration 2+ (backlog, not in this ≤20)

Syft SBOM (hub image + WUI build); OpenSSF Scorecard (SARIF); step-security/harden-runner egress policy; zizmor (workflow SAST beyond actionlint); lockfile-integrity assertion; license-compliance check; release integrity (checksums + SBOM on `55`, cosign signing — owner-go); SLSA provenance (owner-go); cache-poisoning guards; WIF instead of long-lived JSON SA keys (identity lane).

## 7. Open points

- **§7.1** Issues: are the per-item "issues (label security)" GitHub issues or product-spool issues? (default: GitHub, one epic per lane).
- **§7.2** ZAP/headers dev target URL + confirmation dev is rate-limited and isolated from prd (owner-go, item #11).
- **§7.3** Final deliverable (owner asked): a "how to improve the whole DevSecOps setup" section (identity, runtime, process) — CLE-77790 merges both lanes' inputs into one proposal.
