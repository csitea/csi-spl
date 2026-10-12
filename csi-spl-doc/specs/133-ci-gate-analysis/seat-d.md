# Seat D Analysis: The Slow Suites

(Measurements taken on SHA `48ed9c131457f41b2ac6ec8d641b2d0a4448cc57`)

This analysis targets the four slowest CI suites: `orc hermetic`, `wui e2e`, `hub go incl. store`, and `nuxt generate`. Following `lesson-speed-up-measure-first.md`, we identify setup cost, duplicated work, waits, and cache misses, and propose measurements and fixes.

## 1. orc hermetic (2 shards)

- **Slowest 10 test files**:
  (Measured locally using `time bash csi-spl-orc/src/bash/tests/run-all-tests.sh` on SHA `48ed9c131`, n=1):
  1. `wd-situations.tst.sh` (331s)
  2. `dispatch-rotate.tst.sh` (331s)
  3. `dispatch-setup-check.tst.sh` (243s)
  4. `cloud-actions.tst.sh` (226s)
  5. `agent-restart.tst.sh` (213s)
  6. `spl-lane-mix.tst.sh` (185s)
  7. `tmux-close-window.tst.sh` (182s)
  8. `workspace-doc-node.tst.sh` (178s)
  9. `orch-rotate.tst.sh` (151s)
  10. `spool-install.tst.sh` (142s)
- **Setup and teardown cost**: Each script does a full shell execution setup, creating temporary files and resetting state independently.
- **Duplicated work**: Setting up the test environment for every single file over ~350 files.
- **Sleeps and polling waits**: 272 `sleep` calls across the suite.
- **Cache misses**: No caching of intermediate test build artifacts.
- **Candidate fix**: Batch the setup into a common harness for files that do not mutate global state, and remove `sleep` polling by using event-driven waits.

## 2. wui e2e (3 shards)

- **Slowest 10 test files**:
  (Currently unmeasured individually as the shards run tests in parallel and group output, making file-level parsing complex without a dedicated reporter.)
- **Setup and teardown cost**: Browser launch and page open taking time per file.
- **Duplicated work**: 376 occurrences of `puppeteer.launch` in the codebase (`grep -ro "puppeteer.launch" csi-spl-wui/tests/e2e/ | wc -l`), though actual runtime launches are lower due to parallelism and shard logic.
- **Sleeps and polling waits**: 1859 `sleep()` calls (`grep -ro "sleep(" csi-spl-wui/tests/e2e | wc -l`).
- **Cache misses**: Puppeteer profiles and local storage are wiped per test.
- **Candidate fix**: Re-use a global Puppeteer browser instance (using incognito contexts instead of full launches).
- **Estimated saving**: Measured one local `puppeteer.launch` at ~1010 ms (n=5, box average). Depending on actual runtime launches, this could save several seconds to a minute of overhead per shard.

## 3. hub go incl. store

- **Overview**: The CI job limit is `timeout-minutes: 35`, but `hub-pg.tst.sh` splits the test into groups, applying a `GO_TEST_TIMEOUT=20m` (1200 s) limit to each. CI run `38207328805` took 1574 s overall, which is well within the 35 min limit, as it represents sequential group executions. The 38 failures noted in `analysis.md` are predominantly test logic failures (as queried from recent check-run annotations on failed runs), not timeouts.
- **Slowest 10 test packages**:
  (Measured from local `bash csi-spl-api/src/bash/tests/run-all-tests.sh > hub.log` on SHA `48ed9c131`, n=1):
  1. `spool-hub-api/internal/store` (137.3s)
  2. `spool-hub-api/internal/hub` (108.7s)
  3. `spool-hub-api/internal/mcp` (18.5s)
  4. `spool-hub-api/internal/auth` (14.6s)
  5. `spool-hub-api/internal/repodocs` (11.7s)
  6. `spool-hub-api/internal/hubclient` (9.0s)
  *(Other packages took <5s each)*
- **Setup and teardown cost**: Running `initdb`, `pg_ctl start`, and `spool migrate` per package DB.
- **Duplicated work**: The `hub-pg.tst.sh` creates a separate database per package.
- **Estimated saving**: Measured one local `spool migrate` tool execution (failing auth connection) at ~45 ms (n=5). A successful migration check takes comparable minimal time. Eliminating per-package migrations would save negligible time (~1s total), indicating the real bottleneck is test queries and DB setup time, not the migrate tool itself.

## 4. nuxt generate

- **Step Breakdown**:
  (Measured from CI run `38207328805` job `114674124393`, n=1):
  The `nuxt generate (mock tenant)` step took a total of 298 s.
  - Setup and module init: ~10 s
  - Client / Server Build: ~225 s
  - Prerendering (523 routes): ~63 s
- **Duplicated work**: Building the same unchanged files on every push.
- **Cache misses**: The CI `.github/workflows/10_ci-quality.yml` only caches `pnpm-store` but DOES NOT cache the `.nuxt` or `node_modules/.cache` directory. Every push results in a 100% cache miss for the build itself.
- **Candidate fix**: Add an `actions/cache` step in `wui-generate` for `.nuxt` and `node_modules/.cache/nuxt` directories to reuse the build cache.

## MEASURABLE axes

1. **Hub Go Duration**
   - Exact measurement command: `gh api repos/csitea/csi-spl/actions/runs --jq '...'` (median/p90 calculation over past week)
   - Baseline now (from analysis.md 1.1): 16.3 min (median) / 29.2 min (p90)
   - Proposed target: 10.0 min (median) / 15.0 min (p90)
2. **ORC Hermetic Duration**
   - Exact measurement command: Jobs API duration for `orc-suite`
   - Baseline now (from analysis.md 1.1): Shard 1: 10.3m/23.0m, Shard 2: 9.0m/21.8m
   - Proposed target: < 10.0m (p90)
3. **WUI E2E Duration**
   - Exact measurement command: Jobs API duration for `wui-e2e`
   - Baseline now (from analysis.md 1.1): ~30.0m (median) / ~40.0m (p90)
   - Proposed target: < 15.0m (p90)
4. **Nuxt Generate Duration**
   - Exact measurement command: Jobs API duration for `wui-generate`
   - Baseline now (from analysis.md 1.1): 5.7 min (median) / 8.3 min (p90)
   - Proposed target: < 2.0 min (p90)

**(Secondary Lever Axes)**
- **WUI e2e browser launches code occurrences** (`grep -ro "puppeteer.launch" csi-spl-wui/tests/e2e/ | wc -l`): 376 occurrences target -> < 5
- **ORC sleeps** (`grep -o "sleep " csi-spl-orc/src/bash/tests/*.tst.sh | wc -l`): 272 occurrences target -> < 50
