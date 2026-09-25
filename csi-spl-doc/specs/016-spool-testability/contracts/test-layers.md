# Contract: test layers (what proves what, and where it runs)

**Feature**: `016-spool-testability` · **Spec**: `../spec.md`
**Pipeline YAML**: 008 `contracts/pipeline.md` (jobs, triggers). This file is the **coverage map**.

## 1. Layers

| Layer | Command | Proves | Must not skip-pass in CI |
|---|---|---|---|
| A. Go unit | `cd csi-spl-api/src/go/spool-hub-api && go test ./...` | packages, Memory store, fake IdP, billing map, MCP, msg schema | no skip path |
| B. Hub Postgres | `bash csi-spl-api/src/bash/tests/hub-pg.tst.sh` | migrate, store/hub/auth vs Postgres, `hub-e2e.tst.sh` two-box binary | skip → CI fail (008 FR-P03) |
| C. Fake GCS | `bash csi-spl-api/src/bash/tests/hub-gcs.tst.sh` | `internal/blob` | skip → CI fail |
| D. Local CLI | `bash csi-spl-api/src/bash/tests/spool-smoke.tst.sh` | 002 unsigned send/recv/files/mcp | no skip |
| E. WUI unit | `cd csi-spl-wui && pnpm run test:unit` | view-v1 client, avatars, live-ws fakes, auth-client | empty dir → fail |
| F. WUI typecheck | `pnpm run typecheck` | TS | no skip |
| G. WUI browser | `pnpm run test:e2e` plus `test:e2e:console-errors`, `test:e2e:topic-pane`, `test:e2e:msg-edit`, `test:e2e:dm-remove`, `test:e2e:display-name`, `test:e2e:typed-by` | no-x-scroll at 390×844 / 1280×800; viewport must apply or the harness fails (`harness: viewport not applied`) | in CI (`wui-e2e`, 016 T021, widened by later jobs). Missing Chrome fails the job. |
| H. WUI live | `HUB_URL=… pnpm run test:live` | two sockets vs a real hub | local unset `HUB_URL` exits 0. `CI=1` with `HUB_URL` unset exits 1 (T006). Still not a CI job |
| I. IAC bash | `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` | tfvars parity, 025/028/030/031/017/019/120, hygiene, no keys in tf | missing terraform = FAIL unless `SPL_TF_ALLOW_SKIP=1` |
| J. ORC bash | `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` | lde stack, tenant-create, wui-actions, deploy-check, DNS helpers | skip → CI fail; needs a cached `postgres:16-alpine` + the `<ORG>/<ORG>-<APP>` checkout layout |
| K. CNF | `bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` | validator 0/1/2; refuses to skip | in CI (`cnf-suite`); no skip path |
| L. Spawn-agents | `csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` | tmux window spawn | **never in product CI** (needs tmux) |
| M. Hygiene sweep | `10_ci-quality.yml` `distribution-hygiene` | no personal names / hosts in the tree | a clean grep is a pass (008 FR-P07) |

## 2. CI today (`10_ci-quality.yml`)

Runs **A–F** (via hub-suite + wui-suite), **G** (`wui-e2e`: generate mock tenant, serve `.output/public`, then the scripts in row G), **I** (`iac-suite`), **J** (`orc-suite`, all files; checked out as `csi/csi-spl`), **K** (`cnf-suite`) and **M**. Does not run **H**, **L**. In I and J a `SKIP:` line fails the job and gcloud/gsutil/bq are traps (any call fails the job).

`20_hub-build-deploy.yml` `test` job = A–D again. `30_wui-build-deploy.yml` `test` job = E–F again. Browser e2e is the `10` `wui-e2e` job, not `30`.

## 3. Dual-driver rule (store)

`internal/store` tests call `drivers(t)`: Memory always; Postgres only when `$SPOOL_TEST_PG_DSN` is set. `hub-pg.tst.sh` uses **one database per package** (`store`, `hub`, `auth`) so `Sweep` in store cannot purge hub rows (comment in `hub-pg.tst.sh`, CI 35436333578). New store tests MUST use `drivers(t)`, not Memory only.

## 4. Skip policy

| Suite | Local missing dep | CI |
|---|---|---|
| hub-pg / hub-gcs | exit 0 skip | **red** if the skip line appears |
| iac tf validate | FAIL, or PARTIAL if `SPL_TF_ALLOW_SKIP=1` | runs without that env; `SKIP:`/`PARTIAL:` → red |
| live-interop | exit 0 when `CI` is unset | fail-closed when `CI` is set (T006); still not a CI job |
| spawn-agents | local | never CI |

<!-- version: 0.2.4 · updated: 2026-09-25 · last-edit: 2026-09-25T18:18:58Z -->
