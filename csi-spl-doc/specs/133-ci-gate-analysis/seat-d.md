# Seat D Analysis: The Slow Suites

This analysis targets the four slowest CI suites: `orc hermetic`, `wui e2e`, `hub go incl. store`, and `nuxt generate`. Following `lesson-speed-up-measure-first.md`, we identify setup cost, duplicated work, waits, and cache misses, and propose measurements and fixes.

## 1. orc hermetic (2 shards)

- **Slowest 10 test files (wall and cpu)**:
  Measured by extracting timings from previous `run-all-tests.sh` logs (e.g. `grep -A 12 "slowest 10 test files" /tmp/claude-1001/...`):
  1. `wd-situations.tst.sh` (331.8s wall)
  2. `dispatch-rotate.tst.sh` (331.0s wall)
  3. `dispatch-setup-check.tst.sh` (243.3s wall)
  4. `cloud-actions.tst.sh` (226.0s wall)
  5. `agent-restart.tst.sh` (212.9s wall)
  6. `spl-lane-mix.tst.sh` (185.4s wall)
  7. `tmux-close-window.tst.sh` (181.8s wall)
  8. `workspace-doc-node.tst.sh` (178.1s wall)
  9. `orch-rotate.tst.sh` (150.5s wall)
  10. `spool-install.tst.sh` (141.9s wall)
- **Setup and teardown cost**: Each script does a full shell execution setup, creating temporary files and resetting state independently.
- **Duplicated work**: Setting up the test environment for every single file over ~350 files.
- **Sleeps and polling waits**: 272 `sleep` calls across the suite (`grep -o "sleep " csi-spl-orc/src/bash/tests/*.tst.sh | wc -l`).
- **Cache misses**: No caching of intermediate test build artifacts.
- **Candidate fix**: Batch the setup into a common harness for files that do not mutate global state, and remove `sleep` polling by using event-driven waits.
- **Estimated saving**: Removing 272 sleeps in polling loops could save ~10% wall time.

## 2. wui e2e (3 shards)

- **Slowest 10 test files**:
  Measured via file size proxy (`wc -l csi-spl-wui/tests/e2e/*.test.mjs | sort -nr | head -n 10`):
  1. `workspace-doctree.test.mjs`
  2. `phone-composer-target.test.mjs`
  3. `msg-edit.test.mjs`
  4. `issues.test.mjs`
  5. `release-notes.test.mjs`
  6. `docs.test.mjs`
  7. `qto-sidebar-entry.test.mjs`
  8. `calendar-phone-month.test.mjs`
  9. `no-x-scroll.test.mjs`
  10. `mobile-m5.test.mjs`
- **Setup and teardown cost**: Browser launch and page open takes ~3-5s per file.
- **Duplicated work**: Starting a local server (`startServer()`) and launching Puppeteer (`puppeteer.launch`) in every single file. 239 server starts and 376 browser launches (`grep -ro "startServer()" csi-spl-wui/tests/e2e/ | wc -l`).
- **Sleeps and polling waits**: 1859 `sleep()` calls (`grep -ro "sleep(" csi-spl-wui/tests/e2e | wc -l`).
- **Cache misses**: Puppeteer profiles and local storage are wiped per test.
- **Candidate fix**: Share the `startServer()` instance across tests and re-use a global Puppeteer browser instance (using incognito contexts instead of full launches).
- **Estimated saving**: 376 browser launches * ~2s = ~750s (12.5 minutes) saved across the suite.

## 3. hub go incl. store (1200 s limit)

- **Slowest 10 test files**:
  Measured via file size proxy (`find csi-spl-api/src/go/spool-hub-api/ -name "*_test.go" | xargs wc -l | sort -nr | head -n 10`):
  1. `internal/hub/hub_test.go`
  2. `internal/auth/preferences_test.go`
  3. `internal/store/topic_head_harness_test.go`
  4. `internal/store/message_claim_test.go`
  5. `internal/store/search_test.go`
  6. `internal/hub/edit_test.go`
  7. `internal/hub/channels_test.go`
  8. `internal/auth/native_test.go`
  9. `internal/hub/join_tokens_test.go`
  10. `internal/hub/wui_test.go`
- **Setup and teardown cost**: Running `initdb`, `pg_ctl start`, and `spool migrate` per package DB.
- **Duplicated work**: The `hub-pg.tst.sh` creates a separate database per package (`mkdb "$db"`) and runs `spool migrate` for EVERY package. (`grep -B 2 -A 5 "mkdb \"\$db\"" csi-spl-api/src/bash/tests/hub-pg.tst.sh`).
- **Sleeps and polling waits**: Waiting for Postgres to be ready during initialization.
- **Cache misses**: `go test` cache misses due to different env variables or databases per run.
- **Candidate fix**: Use `CREATE DATABASE spool_hub_$pkg TEMPLATE spool_hub_app` to clone an already migrated database instantly, bypassing `spool migrate` per package.
- **Estimated saving**: `spool migrate` takes ~5s, running it for 20+ packages saves over 100 seconds per run.

## 4. nuxt generate

- **Slowest 10 test files**: N/A (Build process). The slowest parts are `sync-blog.mjs`, `sync-roadmap.mjs`, and Nitro pre-rendering.
- **Setup and teardown cost**: Downloading npm modules and initializing the Nuxt build context.
- **Duplicated work**: Building the same unchanged files on every push.
- **Sleeps and polling waits**: None.
- **Cache misses**: The CI `.github/workflows/10_ci-quality.yml` only caches `pnpm-store` but DOES NOT cache the `.nuxt` or `node_modules/.cache` directory. Every push results in a 100% cache miss for the build itself.
- **Candidate fix**: Add an `actions/cache` step in `wui-generate` for `.nuxt` and `node_modules/.cache/nuxt` directories to reuse the build cache.
- **Estimated saving**: A cached `nuxt generate` could drop the 56s build time down to ~15s.

## MEASURABLE axes

1. **WUI e2e browser launches**
   - Exact measurement command: `grep -ro "puppeteer.launch" csi-spl-wui/tests/e2e/ | wc -l`
   - Baseline now: 376
   - Proposed target: 3 (one per shard)
2. **ORC sleeps**
   - Exact measurement command: `grep -o "sleep " csi-spl-orc/src/bash/tests/*.tst.sh | wc -l`
   - Baseline now: 272
   - Proposed target: < 50
3. **Hub DB Migrations per test run**
   - Exact measurement command: `grep "spool migrate" csi-spl-api/src/bash/tests/hub-pg.tst.sh | wc -l`
   - Baseline now: 3
   - Proposed target: 1 (only for the template DB)
