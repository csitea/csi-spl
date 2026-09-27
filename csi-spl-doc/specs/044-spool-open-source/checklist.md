# Go-public gate: 044 Open-Sourcing csi-spl

**Spec**: `spec.md` · **Tasks**: `tasks.md`
A box is ticked only with its evidence: the command and its result, or the sha. A stage starts only when the
previous section is all ticked.

## 1. Stage 0 -> Stage 1 (the export is fit for outsiders)

- [ ] Owner decisions D1-D8 recorded in `spec.md` §6 (answer + date)
- [ ] `do_oss_export` produced the tree from an allow-list (T002); the list is in the repo
- [ ] `do_oss_gate` exit 0 on that tree, and its negative control exit 1 (T003)
- [ ] gitleaks 8.30.1 on the exported tree: 0 leaks
- [ ] Fleet ids scrubbed from product code (T027)
- [ ] Exported tree: `grep -rE 'iam\.gserviceaccount\.com|gcp_org_id|(CLE|HUM|AGY|GRK)-[0-9]+|/opt/'` -> 0
- [ ] Exported tree: no other-org names, no personal names, no owner e-mail (the hygiene sweep + FR-OS-002 classes)
- [ ] Exported tree: no cnf values, no rendered tfvars, no CLAUDE.md / AGENTS.md / GEMINI.md, no specs (D6)
- [ ] LICENSE per D2; `package.json` `license`; SPDX in the Go module; THIRD-PARTY-NOTICES
- [ ] README, CONTRIBUTING, SECURITY.md, CODE_OF_CONDUCT, issue/PR templates present
- [ ] No workflow of the exported tree has `runs-on: self-hosted`; PR jobs have `permissions: contents: read`
- [ ] `docker compose up` on the exported tree brings up the stack with no GCP credential (T001)
- [ ] The untrusted-input rule is written (T025)
- [ ] The target repo is PRIVATE

## 2. Stage 1 -> Stage 2 (strangers succeeded)

- [ ] 3 or more outsiders completed T041 unaided; every blocking finding fixed and re-exported
- [ ] `asOperator` review done, SPL-35 closed (T026)
- [ ] DB tier / search cost review done (T042)
- [ ] CLA or DCO chosen (D3) and the bot configured, still off
- [ ] Contribution policy (D9) in CONTRIBUTING; branch protection: maintainers-only merge, required review
- [ ] Prompt allow-list (FR-OS-017, T034) live on the hub: a probe from a non-listed identity is refused

## 3. Stage 2: the flip (the owner only)

- [ ] Sections 1 and 2 all ticked
- [ ] The final export re-gated on the exact commit to be published
- [ ] The owner's explicit go, quoted with its date
- [ ] Visibility flipped by the owner; CLA/DCO bot on; ops pins the public repo by ref (D8)
