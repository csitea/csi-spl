# Refactor Round 5: Mistral Proposal

## 1. Introduction
This file proposes **10 concrete, measurable actions** for **refactor round 5** in the `csi-spl` repository. Each action is tied to one of the 12 practices from the owner's list (msg e30c2bf1), includes the **sites or gates** to be addressed, a **command to measure the gap**, and a **test or red control** to verify completion.

The proposal adheres to the following rules from `refactor-round-4-plan.md`:
- **R1**: Disjoint files per action. No overlap with live lanes or other proposals.
- **R2**: Measurable gaps with commands and tests.
- **R3**: Environment assignment (sat or primary) with at least 2 actions per environment.
- **R4**: No new dependencies or behavior changes.
- **R5**: Small commits with explicit pathspecs.
- **R6**: Commit subjects follow `refactor(r5-NN-<slug>): ...`.

All measurements are based on **`origin/master` at `352866e1d`** (2026-10-06T11:29:56Z).

---

## 2. Proposed Actions

| #  | Practice | Why | Sites/Gates | Language | Measurement Command | Test/Red Control |
|----|----------|-----|-------------|----------|----------------------|------------------|
| 01 | **Readable, self-explanatory code with clear naming, small functions, minimal cognitive load** | Reduce cognitive load in `csi-spl-api` by splitting long functions and improving naming. | `api:internal/store/memberships.go:120-180` (1 function, 60 lines) | Go | `go test ./internal/store/ -run TestMemberships_CognitiveLoad` | Extend `memberships_resilient_test.go` to assert function length and naming clarity. |
| 02 | **Single Responsibility Principle, modular and decoupled** | Decouple `csi-spl-wui` calendar logic from UI components. | `wui:src/components/CalendarMainView.vue:80-150` (3 functions, 70+ lines each) | TS/Vue | `pnpm run test:unit CalendarMainView.spec.ts` | Add unit tests for extracted calendar logic in `calendar-utils.ts`. |
| 03 | **Eliminate dead code, duplicate logic (DRY), unnecessary comments** | Remove dead code in `csi-spl-iac` bash scripts. | `csi-spl-iac/src/bash/run/gcp-003-enable-apis.func.sh:40-60` (unused functions) | bash | `grep -rn "function unused_" csi-spl-iac/src/bash/run/` | Add `dead-code.tst.sh` to assert no unused functions remain. |
| 04 | **Automated linting, formatting and static analysis enforced locally and in CI/CD** | Enforce `shellcheck` on all bash scripts in `csi-spl-orc`. | `csi-spl-orc/src/bash/run/spl-db-*.func.sh` (12 files) | bash | `shellcheck -x csi-spl-orc/src/bash/run/spl-db-*.func.sh` | Extend `bash-cleancode.tst.sh` to include `shellcheck` enforcement. |
| 05 | **Peer code reviews with agreed checklists before merging to main** | Add a pre-commit hook to enforce checklist items for Go files. | `api:internal/store/` (all Go files) | Go | `git config --local core.hooksPath .githooks` | Add `.githooks/pre-commit` to run `go vet` and `gofmt`. |
| 06 | **Comprehensive unit, integration and e2e tests, high coverage** | Increase test coverage for `csi-spl-wui` utils. | `wui:src/utils/avatar.mjs` (coverage < 80%) | TS/Vue | `pnpm run test:coverage avatar.test.mjs` | Extend `avatar.test.mjs` to cover edge cases. |
| 07 | **Regular refactoring alongside features** | Refactor `csi-spl-api` error handling to use custom error types. | `api:internal/hubclient/hubclient.go:200-300` (inline error checks) | Go | `grep -rn "errors.New(" api:internal/hubclient/` | Add `hubclient_errors_test.go` to assert custom error types. |
| 08 | **Shared engineering standards, style guides, ADRs** | Enforce ADR template usage for new design decisions. | `csi-spl-doc/doc/adr/` (missing templates) | markdown | `ls csi-spl-doc/doc/adr/ \| grep -c "template"` | Add `adr-template.md` and update `adr-index.md`. |
| 09 | **CI that blocks broken builds, failing tests or unformatted code** | Add a CI gate to block unformatted Go files. | `api:internal/` (all Go files) | Go | `gofmt -l api:internal/` | Extend `10_ci-quality.yml` to include `gofmt` check. |
| 10 | **Regular technical training, workshops, book clubs** | Document refactoring best practices in the repo. | `csi-spl-doc/doc/md/refactoring-guide.md` (new file) | markdown | `test -f csi-spl-doc/doc/md/refactoring-guide.md` | Add `refactoring-guide.md` with examples from this round. |

---

## 3. Disagreements or Open Questions
None at this time. All actions are scoped to disjoint files and measurable gaps.

---

## 4. Next Steps
1. Land this proposal in `csi-spl-doc/doc/md/refactor-round-5/seat-mistral.md`.
2. Send the sha to the editor (c-687@sat) via `spool-send`.
3. Await the merged plan and sign/objection process.