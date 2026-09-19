# Feature Specification: Spool testability — what can be proven, and where a skip looks like a pass

**Feature ID**: `016-spool-testability` · **Milestone**: cross-cutting (M1–M4) · **Status**: Partial
**Created**: 2026-09-19 · **Lane**: integrator
**Ground rules**: `../README.md` (status vocabulary §2.3, seams §5)
**Pipeline jobs**: `../008-spool-cicd-logs/contracts/pipeline.md` (008 owns the YAML; this spec inventories what the tree can prove)

A change is **testable** when a machine can fail it without live GCP, without a human, and without a skip that prints PASS. This spec records the measured layers, what CI actually runs, and the remaining gaps.

Status words follow `../README.md` §2.3.

---

## 0. Measured inventory (trunk `35ed54c`, 2026-09-19)

| Layer | Artifact | Count | In `10 ci: quality gate`? |
|---|---|---|---|
| Go unit / contract | `csi-spl-api/src/go/spool-hub-api/**/*_test.go` | 36 files, 199 `func Test` | **yes** — `go test ./...` inside `run-all-tests.sh` (`hub-suite`) |
| Go fmt/vet | same module | — | **yes** |
| Store dual-driver | `internal/store` `drivers()`: Memory always; Postgres when `$SPOOL_TEST_PG_DSN` | — | **yes** — `hub-pg.tst.sh` sets the DSN; CI fails a skip |
| Auth / hub / store on Postgres | `hub-pg.tst.sh` runs `go test ./internal/{store,hub,auth}/` | — | **yes** |
| Local CLI smoke | `spool-smoke.tst.sh` (002 unsigned send/recv/mcp) | 1 | **yes** |
| Hub binary e2e | `hub-e2e.tst.sh` (called from `hub-pg.tst.sh`) | 1 | **yes** |
| Fake-GCS blob | `hub-gcs.tst.sh` | 1 | **yes** — skip is a CI failure |
| Hygiene (Go tree) | `no-ysg-box-ref`, `no-baked-host`, `no-baked-hostname`, `no-payment-vendor-wui` | 4 | **yes** (ysg-box also its own job) |
| Distribution hygiene | `10_ci-quality.yml` sweeps | 5 patterns | **yes** |
| WUI unit | `csi-spl-wui/tests/unit/*.test.mjs` via `src/node/test/run-unit-tests.mjs` discovery | 20 files | **yes** — `wui-suite` |
| WUI typecheck | `pnpm run typecheck` | — | **yes** |
| WUI browser e2e | `tests/e2e/no-x-scroll.test.mjs`, `console-errors.test.mjs` | 2 | **no** — 008 FR-P11: local only |
| WUI live-interop | `tests/e2e/live-interop.test.mjs` | 1 | **no** — exits 0 if `HUB_URL` unset |
| IAC bash | `csi-spl-iac/src/bash/tests/*.tst.sh` | 25 | **no** |
| ORC bash | `csi-spl-orc/src/bash/tests/*.tst.sh` | 14 | **no** |
| CNF validator | `csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` | 1 | **no** |
| Spawn-agents | `csi-spl-orc/src/bash/features/spawn-agents/tests/` | 6 scripts | **no** |
| `-race` | `go test -race` | hub gate (`run-all-tests.sh`, hub-pg, hub-gcs) | **yes** — T002 `bed8732` |

`30_wui-build-deploy.yml` re-runs WUI unit + typecheck before generate. `20_hub-build-deploy.yml` re-runs the hub suite before deploy. Neither runs iac/orc/cnf suites.

---

## 1. User stories

### US1 — A hub/WUI regression cannot hide behind a skip (P1) 🎯

The quality gate on `master` runs the hub suite and the WUI unit suite. A skipped Postgres or fake-GCS gate is a **failure** in CI. A new WUI unit file is discovered; it cannot sit on disk unrun.

**Independent Test**: push a tree that would skip `hub-pg` without Postgres; CI red. Add `tests/unit/foo.test.mjs`; `pnpm run test:unit` runs it with no `package.json` edit.

**Status**: **Implemented** for hub + WUI unit (008 FR-P03, FR-P11; WUI runner comment in `run-unit-tests.mjs`).

### US2 — IAC, ORC, and CNF regressions are gated the same way (P1)

A terraform template drift, a `do_*` action break, or a conf-validator exit-code lie must fail `10 ci: quality gate`, not only a local `run-all-tests.sh` an agent remembered to run.

**Independent Test**: plant an undeclared terraform reference (007 T070 control); the new CI job fails. Today that suite is local-only.

**Status**: **Planned** (T003–T005). 25 iac + 14 orc + 1 cnf testers exist and are not jobs in `10_ci-quality.yml`
(`grep -c csi-spl-iac/src/bash/tests .github/workflows/10_ci-quality.yml` → 0).

### US3 — A skip never prints all-green (P1)

Any suite that cannot run (missing terraform, missing `HUB_URL`, missing tpl-gen) either fails or says `PARTIAL`, never `PASS: all` / exit 0 that CI would treat as proof.

**Independent Test**: `SPL_TF_ALLOW_SKIP=1` on the iac validate suite prints PARTIAL; without the flag a missing terraform is FAIL (007 T070). `live-interop` with `HUB_URL` unset still exits 0 — that is the remaining hole if it is ever added to CI as-is.

**Status**: **Partial** — T070 closed the iac validate skip; live-interop and spawn-agents still skip-pass.

### US4 — Races and browser behaviour have a named home (P2)

`-race` is documented for `internal/auth` and `wui_test.go` but is not in `run-all-tests.sh`. Browser e2e (no-x-scroll, console-errors) needs a browser and is local. Live two-tab chat needs a hub.

**Status**: **Partial** — tests exist; CI does not run them.

---

## 2. Functional requirements

- **FR-001** — Implemented: `hub-suite` runs `csi-spl-api/src/bash/tests/run-all-tests.sh` and fails if the log contains a Postgres/GCS skip line (`10_ci-quality.yml` “The Postgres and GCS gates really ran”).
- **FR-002** — Implemented: WUI unit discovery (`csi-spl-wui/src/node/test/run-unit-tests.mjs`); empty discovery is exit 1; CI calls `pnpm run test:unit`.
- **FR-003** — Planned: `10 ci: quality gate` grows jobs (or one job) that run `csi-spl-iac/src/bash/tests/run-all-tests.sh`, `csi-spl-orc/src/bash/tests/run-all-tests.sh`, and `csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh`. 008 owns the YAML. A skip of terraform validate is a failure unless `SPL_TF_ALLOW_SKIP=1` is **not** set in CI.
- **FR-004** — Implemented (T002, `bed8732`): `run-all-tests.sh` runs `go test -race ./...`, and the Postgres and GCS gates run their suites with `-race`. Check: `grep -n -- -race csi-spl-api/src/bash/tests/run-all-tests.sh` → line 26.
- **FR-005** — Planned: either run `pnpm run test:e2e` in CI with a cached browser, or keep it local and add a comment-plus-job that **fails** if someone wires `test:live` without `HUB_URL` (live-interop exit 0 on unset must not be a CI pass).
- **FR-006** — Implemented: store contract suite is driver-parameterised (`drivers()` in `store_test.go` / `humans_test.go`); Memory always, Postgres when the hub-pg gate sets `$SPOOL_TEST_PG_DSN`.
- **FR-007** — Implemented: hermetic fixtures via `internal/testkit` (temp `$SPOOL_ROOT` / keys / pins); no private key in git. Hygiene tests exist for baked hosts and ysg-box refs.
- **FR-008** — Partial: payment seam has `internal/payments/payments_test.go` and `store/payments_test.go`. M2 checkout page and live rails are not an e2e in CI. M4 seats have no tests because there is no seat schema (`specs/009` T002 Planned).
- **FR-009** — Partial: two-box hub mail is `hub-e2e.tst.sh` on throwaway Postgres (M1 local). Cloud two-machine demo (006 T011c) is still Planned — not a unit-test gap.
- **FR-010** — Implemented (007 T070): `tf-steps-render-and-validate.tst.sh` fails when tpl-gen or terraform is missing, unless `SPL_TF_ALLOW_SKIP=1`. **Not** in CI (blocked on FR-003).
- **FR-011** — Planned: spawn-agents tests stay out of the product quality gate (they need tmux). They must not be invoked from `10_ci-quality.yml`. Documented as local-only in `./contracts/test-layers.md`.

---

## 3. Success criteria

- **SC-001**: `grep -c 'csi-spl-iac/src/bash/tests' .github/workflows/10_ci-quality.yml` ≥ 1 and the job fails a planted validate error.
- **SC-002**: `grep -n -- '-race' csi-spl-api/src/bash/tests/run-all-tests.sh` is non-empty, or a named CI job runs `go test -race ./...`.
- **SC-003**: `live-interop.test.mjs` either is not in CI, or CI sets `HUB_URL` / fails closed when it is unset (exit ≠ 0).
- **SC-004**: FR-001 and FR-002 stay green on trunk (hub skip-fail, WUI discovery).

---

## 4. Out of scope

Rewriting 002 tests. Terraform apply in CI. Live Google/Meta IdP. M4 seat tests before 009 T002 schema. Changing 008’s “no `pull_request`” trunk-based rule.

---

## 5. Open questions

- **OQ-016-1**: Should iac validate run on the GitHub runner (needs terraform + tpl-gen venv in the job) or a thinner subset (hygiene + tfvars parity only)? Recommended: full `run-all-tests.sh` with terraform from `hashicorp/setup-terraform` and tpl-gen from the in-repo `tpl-gen/` clone.
- **OQ-016-2**: Browser e2e in CI vs documented local-only. Recommended: keep no-x-scroll local (puppeteer + display) until a runner image is budgeted; do **not** add live-interop to CI without a hub service container.

<!-- version: 0.1.0 · updated: 2026-09-19 · last-edit: 2026-09-19T12:55:31Z -->
