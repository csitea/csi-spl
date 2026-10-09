# Feature Specification: Spool testability — what can be proven, and where a skip looks like a pass

**Feature ID**: `016-spool-testability` · **Milestone**: cross-cutting (M1–M4) · **Status**: Partial — CI holes from 2026-09-19 are closed; FR-008 checkout e2e and FR-009's cloud demo remain
**Created**: 2026-09-19 · **Lane**: integrator
**Ground rules**: `../README.md` (status vocabulary §2.3, seams §5)
**Pipeline jobs**: `../008-spool-cicd-logs/contracts/pipeline.md` (008 owns the YAML; this spec inventories what the tree can prove)

A change is **testable** when a machine can fail it without live GCP, without a human, and without a skip that prints PASS. This spec records the measured layers, what CI actually runs, and the remaining gaps.

Status words follow `../README.md` §2.3.

---

## 0. Measured inventory (trunk `4ae33835`, 2026-09-25)

Re-measured on that tree, n=1 per count. The 2026-09-19 inventory at `35ed54c` is history; its counts (36 Go files, 199 `func Test`, 20 WUI unit files, 25 iac / 14 orc testers, iac/orc/cnf "not in CI") are no longer true.

| Layer | Artifact | Count | In `10 ci: quality gate`? |
|---|---|---|---|
| Go unit / contract | `csi-spl-api/src/go/spool-hub-api/**/*_test.go` | 135 files, 488 `func Test` | **yes** — `go test -race ./...` inside `run-all-tests.sh` (`hub-suite`) |
| Go fmt/vet | same module | — | **yes** |
| Store dual-driver | `internal/store` `drivers()`: Memory always; Postgres when `$SPOOL_TEST_PG_DSN` | — | **yes** — `hub-pg.tst.sh` sets the DSN; CI fails a skip |
| Auth / hub / store on Postgres | `hub-pg.tst.sh` runs `go test -race ./internal/{store,hub,auth}/` | — | **yes** |
| Local CLI smoke | `spool-smoke.tst.sh` (002 unsigned send/recv/mcp) | 1 | **yes** |
| Hub binary e2e | `hub-e2e.tst.sh` (called from `hub-pg.tst.sh`) | 1 | **yes** |
| Fake-GCS blob | `hub-gcs.tst.sh` | 1 | **yes** — skip is a CI failure |
| Distribution hygiene | `10_ci-quality.yml` sweeps | — | **yes** |
| WUI unit | `csi-spl-wui/tests/unit/*.test.mjs` | 87 files | **yes** — `wui-suite` |
| WUI typecheck | `pnpm run typecheck` | — | **yes** |
| WUI browser e2e | job `wui-e2e` runs `pnpm run test:e2e` (`run-e2e-tests.mjs`: every `tests/e2e/*.test.mjs`, minus the files `tests/e2e/ci-skip.txt` names with a reason) | every discovered file | **yes** — T021, since widened |
| WUI live-interop | `tests/e2e/live-interop.test.mjs` | 1 | **no** — not a job. `CI=1` and unset `HUB_URL` exits 1 (T006) |
| IAC bash | `csi-spl-iac/src/bash/tests/*.tst.sh` (one directory) | 36 | **yes** — `iac-suite` |
| ORC bash | `csi-spl-orc/src/bash/tests/*.tst.sh` (one directory) | 56 | **yes** — `orc-suite` |
| CNF validator | `conf-validator-exit-codes.tst.sh` | 1 | **yes** — `cnf-suite` |
| Spawn-agents | `csi-spl-orc/src/bash/features/*/tests/test-*.sh` | every discovered file | **yes** — job `orc-features` (`csi-spl-orc/src/bash/features/run-ci-tests.sh`, skips by name in `features/ci-skip.txt`); FR-011 reversed 2026-10-09 |
| `-race` | `go test -race` | hub gate | **yes** — `run-all-tests.sh` line 26 |

Commands (tree `4ae33835`):

```
find csi-spl-api/src/go/spool-hub-api -name '*_test.go' | wc -l
grep -h '^func Test' -r csi-spl-api/src/go/spool-hub-api --include='*_test.go' | wc -l
find csi-spl-wui/tests/unit -name '*.test.mjs' | wc -l
find csi-spl-iac/src/bash/tests -maxdepth 1 -name '*.tst.sh' | wc -l
find csi-spl-orc/src/bash/tests -maxdepth 1 -name '*.tst.sh' | wc -l
grep -c wui-e2e .github/workflows/10_ci-quality.yml
grep -n -- -race csi-spl-api/src/bash/tests/run-all-tests.sh
```

`30_wui-build-deploy.yml` re-runs WUI unit + typecheck before generate. `20_hub-build-deploy.yml` re-runs the hub suite before deploy.

## 1. User stories

### US1 — A hub/WUI regression cannot hide behind a skip (P1) 🎯

The quality gate on `master` runs the hub suite and the WUI unit suite. A skipped Postgres or fake-GCS gate is a **failure** in CI. A new WUI unit file is discovered; it cannot sit on disk unrun.

**Independent Test**: push a tree that would skip `hub-pg` without Postgres; CI red. Add `tests/unit/foo.test.mjs`; `pnpm run test:unit` runs it with no `package.json` edit.

**Status**: **Implemented** for hub + WUI unit (008 FR-P03, FR-P11; WUI runner comment in `run-unit-tests.mjs`).

### US2 — IAC, ORC, and CNF regressions are gated the same way (P1)

A terraform template drift, a `do_*` action break, or a conf-validator exit-code lie must fail `10 ci: quality gate`, not only a local `run-all-tests.sh` an agent remembered to run.

**Independent Test**: plant an undeclared terraform reference (007 T070 control); the new CI job fails. Today that suite is local-only.

**Status**: **Implemented** (T003–T005, `5cf1a56`). Re-measured 2026-09-25, tree `4ae33835`: `grep -c csi-spl-iac/src/bash/tests .github/workflows/10_ci-quality.yml` → 3, the orc path → 3, and jobs `iac-suite` / `orc-suite` / `cnf-suite` are present. Top-level testers: iac 36, orc 56, cnf 1.

### US3 — A skip never prints all-green (P1)

Any suite that cannot run (missing terraform, missing `HUB_URL`, missing tpl-gen) either fails or says `PARTIAL`, never `PASS: all` / exit 0 that CI would treat as proof.

**Independent Test**: `SPL_TF_ALLOW_SKIP=1` on the iac validate suite prints PARTIAL; without the flag a missing terraform is FAIL (007 T070). `live-interop` with `HUB_URL` unset still exits 0 — that is the remaining hole if it is ever added to CI as-is.

**Status**: **Implemented** for the CI skip-pass holes. T070 fails a missing terraform. T006: `live-interop.test.mjs` exits 1 when `CI` is set and `HUB_URL` is unset (local unset still exits 0, and the script is not a CI job). Spawn-agents tests joined the gate on 2026-10-09 (FR-011 reversed).

### US4 — Races and browser behaviour have a named home (P2)

`-race` is documented for `internal/auth` and `wui_test.go` but is not in `run-all-tests.sh`. Browser e2e (no-x-scroll, console-errors) needs a browser and is local. Live two-tab chat needs a hub.

**Status**: **Implemented** for `-race` (T002, `run-all-tests.sh` line 26) and for the browser scripts the `wui-e2e` job names. Live two-tab chat stays out of CI; wiring `test:live` without `HUB_URL` fails closed (T006).

---

## 2. Functional requirements

- **FR-001** — Implemented: `hub-suite` runs `csi-spl-api/src/bash/tests/run-all-tests.sh` and fails if the log contains a Postgres/GCS skip line (`10_ci-quality.yml` “The Postgres and GCS gates really ran”).
- **FR-002** — Implemented: WUI unit discovery (`csi-spl-wui/src/node/test/run-unit-tests.mjs`); empty discovery is exit 1; CI calls `pnpm run test:unit`.
- **FR-003** — Implemented (T003–T005, `5cf1a56`): `10 ci: quality gate` jobs `iac-suite`, `orc-suite` and `cnf-suite` run those three suites. 008 owns the YAML. A skip of terraform validate is a failure unless `SPL_TF_ALLOW_SKIP=1` is **not** set in CI. Re-measured on `4ae33835`: the three job names are in `.github/workflows/10_ci-quality.yml`.
- **FR-004** — Implemented (T002, `bed8732`): `run-all-tests.sh` runs `go test -race ./...`, and the Postgres and GCS gates run their suites with `-race`. Check: `grep -n -- -race csi-spl-api/src/bash/tests/run-all-tests.sh` → line 26.
- **FR-005** — Implemented (T006 `a798b07`, T021 `05aaaa7`). `wui-e2e` runs the browser scripts named in §0. `live-interop.test.mjs` exits 1 when `CI` is set and `HUB_URL` is unset, so a skip cannot pass a job. It is still not itself a CI job.
- **FR-006** — Implemented: store contract suite is driver-parameterised (`drivers()` in `store_test.go` / `humans_test.go`); Memory always, Postgres when the hub-pg gate sets `$SPOOL_TEST_PG_DSN`.
- **FR-007** — Implemented: hermetic fixtures via `internal/testkit` (temp `$SPOOL_ROOT` / keys / pins); no private key in git. Hygiene tests exist for baked hosts and ysg-box refs.
- **FR-008** — Partial: payment seam has `internal/payments/payments_test.go` and `store/payments_test.go`. M2 checkout page and live rails are not an e2e in CI (spec 006). Seat tests now exist (`internal/store/seats_test.go` on `4ae33835`); whether spec 009's seat row is closed is that spec's, not this one's. The checkout e2e is still missing here.
- **FR-009** — Partial: two-box hub mail is `hub-e2e.tst.sh` on throwaway Postgres (M1 local). Cloud two-machine demo (006 T011c) is still Planned — not a unit-test gap.
- **FR-010** — Implemented (007 T070): `tf-steps-render-and-validate.tst.sh` fails when tpl-gen or terraform is missing, unless `SPL_TF_ALLOW_SKIP=1`. **Not** in CI (blocked on FR-003).
- **FR-011** — **Reversed 2026-10-09.** Was: spawn-agents tests stay out of the gate (they need tmux). Two of them then stayed red on master unnoticed (fixed `9fb5f0a54`, `2645bc5de`). Now every `features/*/tests/test-*.sh` runs in job `orc-features` (`csi-spl-orc/src/bash/features/run-ci-tests.sh`, skips by name in `features/ci-skip.txt`); the runner has tmux and each test uses a private tmux server and a throwaway `SPOOL_ROOT`.

---

## 3. Success criteria

- **SC-001**: `grep -c 'csi-spl-iac/src/bash/tests' .github/workflows/10_ci-quality.yml` ≥ 1 and the job fails a planted validate error.
- **SC-002**: `grep -n -- '-race' csi-spl-api/src/bash/tests/run-all-tests.sh` is non-empty, or a named CI job runs `go test -race ./...`.
- **SC-003**: `live-interop.test.mjs` either is not in CI, or CI sets `HUB_URL` / fails closed when it is unset (exit ≠ 0).
- **SC-004**: FR-001 and FR-002 stay green on trunk (hub skip-fail, WUI discovery).

---

## 4. Out of scope

Rewriting 002 tests. Terraform apply in CI. Live Google/Meta IdP. The M2 checkout e2e (FR-008, spec 006). Changing 008’s “no `pull_request`” trunk-based rule.

---

## 5. Open questions

- **OQ-016-1** — Answered (T003, `5cf1a56`). IAC validate runs on the GitHub runner: terraform 1.9.8 and tpl-gen at `cnf/tpl-gen.ref`, `SPL_TF_ALLOW_SKIP` unset. The 2026-09-19 recommendation was the path that shipped.
- **OQ-016-2** — Answered for the browser scripts (T021, `05aaaa7`): `wui-e2e` runs them and a missing Chrome fails the job. Live-interop is fail-closed under `CI` (T006) and is still not a job, because it needs a hub.

<!-- version: 0.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
