# Implementation Plan: Spool testability

**Feature ID**: `016-spool-testability` · **Status**: Partial · **Date**: 2026-09-19

**Spec**: `./spec.md` · **Layers**: `./contracts/test-layers.md`
**Pipeline owner**: `../008-spool-cicd-logs/` (YAML). This plan only names the jobs 016 needs 008 to add.

## Summary

Keep the hub + WUI unit gate. Add iac/orc/cnf to `10_ci-quality.yml` so template and action regressions cannot land green. Put `-race` on the hub `go test`. Do not add live-interop or spawn-agents to CI.

## Technical context

- Hub runner: `csi-spl-api/src/bash/tests/run-all-tests.sh` (`GOPROXY=off` after `go mod download` in the workflow).
- WUI runner: `csi-spl-wui/src/node/test/run-unit-tests.mjs` (discovers `tests/unit/*.test.mjs`).
- IAC/ORC runners: `run-all-tests.sh` looping `*.tst.sh` next to the file.
- Terraform for T070: `hashicorp/setup-terraform` 1.9.x; tpl-gen from in-repo `tpl-gen/`.
- Race: `go test -race ./...` needs CGO; ubuntu-latest is fine.

## Order of work

1. T001 document layers (this dir) — docs only.
2. T002 `-race` in `run-all-tests.sh` (api).
3. T003–T005 CI jobs (008 YAML): iac, orc, cnf.
4. T006 live-interop fail-closed when `CI=true` and `HUB_URL` unset (wui), so a future CI add cannot skip-pass.
5. T007 index 014/015/016 in `specs/README.md` (integrator).

## Risks

- IAC suite needs terraform + a tpl-gen venv on the runner; first job may need `poetry install` in `tpl-gen`. Fail the job rather than `SPL_TF_ALLOW_SKIP=1`.
- ORC `lde-stack.tst.sh` may need docker compose; if it cannot run hermetically, split the orc job into “hermetic *.tst.sh” vs “lde (optional)” rather than skip-pass the whole directory.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T12:55:31Z -->
