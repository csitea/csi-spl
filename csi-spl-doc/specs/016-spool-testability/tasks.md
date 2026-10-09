# Tasks: Spool testability

**Feature**: `specs/016-spool-testability` · **Spec**: `./spec.md`

`[x]` Implemented (cited) · `[~]` Partial (missing part named) · `[ ]` Planned
(`../README.md` §2.3). YAML changes are **008's**; named here so the gap is not lost.

## Already true (measured `35ed54c`)

- [x] T010 Implemented — hub quality gate: `run-all-tests.sh` + skip-fail for Postgres/GCS (`10_ci-quality.yml` hub-suite). FR-001.
- [x] T011 Implemented — WUI unit discovery + typecheck in `wui-suite`. FR-002.
- [x] T012 Implemented — store `drivers()` Memory + Postgres; hub-pg one DB per package. FR-006.
- [x] T013 Implemented — `internal/testkit` temp dirs; baked-host / ysg-box hygiene. FR-007.
- [x] T014 Implemented — 007 T070: missing terraform/tpl-gen is FAIL (not silent PASS). FR-010. In CI since T003.

## Phase 1 — Docs (016)

- [x] T001 Implemented (this dir) — `spec.md`, `plan.md`, `contracts/test-layers.md`. FR-001–FR-011 inventory.

## Phase 2 — Close skip-pass and CI holes

- [x] T002 Implemented (api) — `bed8732`: `csi-spl-api/src/bash/tests/run-all-tests.sh` runs `go test -race ./...`; `hub-pg.tst.sh` (store, hub, auth on Postgres) and `hub-gcs.tst.sh` (blob) run `-race` too, so the 10 hub-suite and the 20 pre-deploy suite both gate on it. No race found (`go test -race -count=5 ./...` green on 776eec1, and on Postgres). Check: `grep -n -- -race csi-spl-api/src/bash/tests/run-all-tests.sh` → line 26. Control: a two-goroutine counter test in `internal/store` passes without `-race` and turns `run-all-tests.sh` and `hub-pg.tst.sh` red (`WARNING: DATA RACE`). Cost (cold test cache, one box): 53 s → 64 s. FR-004. SC-002.
- [x] T003 Implemented `5cf1a56` (+ `1311b4f` `do_setup_tpl_gen`) — `10_ci-quality.yml` job `iac-suite`: `run-all-tests.sh` with terraform 1.9.8 and tpl-gen at `cnf/tpl-gen.ref` (`./run -a do_setup_tpl_gen`); `SPL_TF_ALLOW_SKIP` unset, any `SKIP:`/`PARTIAL:` line fails the job; gcloud/gsutil/bq trapped (trap log empty = no GCP). Check: run 35447312122 green on `75fa7cd`; CONTROL run 35447535287 (020 template broken) red on `tf-steps-render-and-validate` + parity. FR-003. SC-001.
- [x] T004 Implemented `5cf1a56` + `75fa7cd` — job `orc-suite`: ALL orc `*.tst.sh` (20 at `75fa7cd`); none needs a split: `lde-stack` uses only `docker compose config` + `sudo -n`, `checkout-fake-buy` a pulled `postgres:16-alpine`, the rest stub gcloud/curl/docker. Checked out as `csi/csi-spl` because orc `do_resolve_oap` derives ORG/APP from the parent dirs (runner default gave `con-csi-spl-csi-spl-tf-runner`). `SKIP:` fails; gcloud trapped. Check: run 35447312122 green; CONTROL run 35447535287 (`wui-up` compose line removed) red on `wui-actions`. FR-003.
- [x] T005 Implemented `5cf1a56` — job `cnf-suite`: Python 3.12, `poetry install --no-root` from the lock, then `conf-validator-exit-codes.tst.sh` (refuses to skip: exit 2 without deps). Check: run 35447312122 green; CONTROL run 35447535287 (validator `EXIT_INVALID` -> `EXIT_OK`) red, 2 cases `exit 0, want 1`. FR-003.
- [x] T006 Implemented `a798b07` (GRK-3372) — `tests/e2e/live-interop.test.mjs`: if `CI` is set and `HUB_URL` is unset, exit 1 (not 0). Check: `CI=1` unset `HUB_URL` → exit 1; `CI` unset → exit 0. FR-005. SC-003.
- [x] T007 Implemented — `specs/README.md` §4 lists 014, 015, 016 (this dir) and 017; seam “Test layers” → `016 contracts/test-layers.md`.

## Phase 3 — Out of the product gate (document only)

- [x] T020 Reversed 2026-10-09 — the feature tests (spawn-agents included) run in `10_ci-quality.yml` job `orc-features` (`csi-spl-orc/src/bash/features/run-ci-tests.sh`, skips by name in `features/ci-skip.txt`).
- [x] T021 Implemented `05aaaa7` (GRK-3379) — `10_ci-quality.yml` job `wui-e2e`: `nuxt generate` with `NUXT_PUBLIC_USE_MOCK=1`, serve via `serve-generated.mjs`, then `pnpm test:e2e` + `test:e2e:console-errors` + `test:e2e:topic-pane` (the script was named `thread-pane` in this sentence; `package.json` has `test:e2e:topic-pane` and the workflow calls that). Missing Chrome fails the job. Left out: `test:live` (needs `HUB_URL`), `test:e2e:csp` (Hosting CSP), `*.proof.mjs` (live sites or credentials). Check at landing: `command grep -c wui-e2e .github/workflows/10_ci-quality.yml` → 5. Re-measured 2026-09-25, tree `4ae33835`: the same grep → 7, and the job also runs `test:e2e:msg-edit`, `test:e2e:dm-remove`, `test:e2e:display-name`, `test:e2e:typed-by`. CONTROL red run 35605305098 (job 106350815619, `scrollWidth=9999`); green run 35604599982 (job 106348514551, 56/56 + zero console + 34/34) and 35605772205 (job 106352358451) after revert. Viewport guard `4153561` (GRK-3381): after setViewport, read innerWidth/innerHeight back, retry once, else fail `harness: viewport not applied`. Check: `command grep -c "harness: viewport not applied" csi-spl-wui/tests/e2e/lib/viewport.mjs` → 2. Control: `E2E_VIEWPORT_NOOP=1` exits 1 with that phrase. CI 10 run 35614054020 / 30 run 35614054219 on `4153561`; both apexes served that sha. FR-005.

## FR → task

| FR | Tasks | Status |
|---|---|---|
| FR-001 | T010 | Implemented |
| FR-002 | T011 | Implemented |
| FR-003 | T003, T004, T005 | Implemented |
| FR-004 | T002 | Implemented |
| FR-005 | T006, T021 | Implemented |
| FR-006 | T012 | Implemented |
| FR-007 | T013 | Implemented |
| FR-008 | (009/006 when those features grow tests) | Partial |
| FR-009 | hub-e2e via T010; cloud demo stays 006 T011c | Partial |
| FR-010 | T014, T003 | Implemented (local and CI) |
| FR-011 | T020 | Implemented |

<!-- version: 0.2.3 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
