# Tasks: 056 DevSecOps in CI

Spec: `spec.md`. Epic: **Spec 056 - DevSecOps in CI** (label `security`), created by the
supply-chain lane's importer; `do_spl_spec_import_issues` files these under it. `[x]` = on trunk
(sha is the commit that landed it); `[ ]` = todo/wip. Lane **B** = CLE-77790 (security testing).
The supply-chain items (#12–#20) are filed by CLE-77789 and are NOT repeated here (one epic, no
duplicate issues).

## B-lane — security testing (CLE-77790), one issue each

- [x] T003 Semgrep SAST gate (p/golang + p/javascript + p/owasp-top-ten) with a negative control and a count-per-rule baseline over hub Go + WUI TS - `bd09ab68`
- [x] T004 gosec Go SAST gate at HIGH severity with a negative control and a count baseline (.gosec-baseline.txt) - `2794c234`
- [x] T005 TruffleHog verified-secret second opinion with a negative control, scanning the working tree for live secrets - `38d9b0c4`
- [x] T006 Checkov terraform IaC gate against .checkov.baseline with a negative control - `38d9b0c4`
- [x] T008 shellcheck gate on the iac + orc + cnf bash trees at error level with a negative control, plus 4 shebang fixes - `2b20de32`
- [x] T009 hadolint gate on every Dockerfile at error level with a negative control (.hadolint.yaml) - `81016b84`
- [x] T001 CodeQL SAST for Go, SARIF to GitHub code scanning (60_codeql.yml, security-extended) - `0b9e0bd2`
- [x] T002 CodeQL SAST for JS/TS, SARIF to GitHub code scanning (60_codeql.yml) - `0b9e0bd2`
- [x] T010 ESLint security plugin gate on the WUI JS with a negative control - `8bb5b1f1`
- [x] T011 OWASP ZAP baseline DAST + security-headers check against dev.spool-hub.ai only, read-only, <=5 req/s, never prd (owner-go granted) - `0b9e0bd2`

Dropped: **tfsec** (spec item #7) — deprecated (aquasecurity redirects to Trivy) and cannot parse the
tree's terraform `import` blocks (hard parse error). Superseded by T006 Checkov + CLE-77789 #16
Trivy-IaC. Not imported as an issue.

## S-lane — supply chain + pipeline hardening (CLE-77789), one issue each

Provided by CLE-77789; single import mechanism (this file), one epic, no duplicate script.

- [x] T012 SHA-pin every GitHub Action to a full commit SHA across the workflow files - `8bd175f9`
- [x] T013 Least-privilege top-level permissions on every workflow - `ab94d5b7`
- [x] T014 Per-job timeout-minutes on every runner job - `e62deeb7`
- [x] T017 sha256-verify the gitleaks tool download - `eea4cbb3`
- [x] T018 go mod verify in the CI quality gate - `82f54930`
- [x] T020s Dependabot for gomod + npm + github-actions - `83d05921`
- [ ] T019 actionlint on the workflows (85_actionlint.yml + do_sec_actionlint) - wip
- [ ] T015 OSV-Scanner multi-ecosystem lockfile vulns (70_supply-chain.yml) - todo
- [ ] T016 Trivy filesystem + IaC misconfig scan (sec-scan fs/iac modes) - todo

## Follow-ups surfaced by the SAST/secret gates (lane: hub/auth) — one issue each

These are real hub-lane hardening items the new gates found and baselined; they should become issues,
not stay only in a baseline.

- [ ] T020 Session cookies missing the Secure flag (Semgrep cookie-missing-secure x4: internal/auth/handler.go, internal/auth/tenant.go) - lane hub/auth
- [ ] T021 Session cookie missing HttpOnly (Semgrep cookie-missing-httponly: internal/auth/tenant.go) - lane hub/auth
- [ ] T022 Open-redirect candidates (Semgrep open-redirect x3: internal/auth/handler.go, internal/auth/fakeidp/*) - lane hub/auth
- [ ] T023 SMTP client TLS MinVersion not set (Semgrep + gosec G402: internal/mail/mail.go) - lane hub/auth
