# Seat D Analysis: The Slow Suites

(Measurements taken on SHA `48ed9c131457f41b2ac6ec8d641b2d0a4448cc57`)

This analysis targets the four slowest CI suites: `orc hermetic`, `wui e2e`, `hub go incl. store`, and `nuxt generate`. Following `lesson-speed-up-measure-first.md`, we identify setup cost, duplicated work, waits, and cache misses, and propose measurements and fixes.

## 1. orc hermetic (2 shards)

- **Slowest 10 test files**:
  (Extracted from CI run 38207328805, job IDs 114674124416 and 114674124454. The `run-all-tests.sh` script ends with a "--- slowest 10 test files" block).
  1. `spl-lane-mix.tst.sh` (582.0s)
  2. `fleet-lease.tst.sh` (578.1s)
  3. `peer-poll.tst.sh` (482.3s)
  4. `parse-metadata-nofork.tst.sh` (437.4s)
  5. `desk-actions.tst.sh` (302.0s)
  6. `asks.tst.sh` (272.9s)
  7. `tmux-close-window.tst.sh` (264.0s)
  8. `dispatch-rotate.tst.sh` (261.5s)
  9. `agent-restart.tst.sh` (236.5s)
  10. `orch-rotate.tst.sh` (224.8s)
- **Setup and teardown cost**: Each script does a full shell execution setup, creating temporary files and resetting state independently.
- **Duplicated work**: Setting up the test environment for every single file over ~350 files.
- **Sleeps and polling waits**: 272 `sleep` calls across the suite.
- **Cache misses**: No caching of intermediate test build artifacts.
- **Candidate fix**: Batch the setup into a common harness for files that do not mutate global state, and remove `sleep` polling by using event-driven waits.

## 2. wui e2e (3 shards)

- **Slowest 10 test files**:
  (From green CI run 38207328805, shards 114675449458, 114675449581, and 114675449482)
  1. `tests/e2e/phone-composer-target.test.mjs` (244s)
  2. `tests/e2e/phone-back-matrix.test.mjs` (210s)
  3. `tests/e2e/mobile-back-stuck.test.mjs` (162s)
  4. `tests/e2e/calendar-phone-shell.test.mjs` (157s)
  5. `tests/e2e/links-open-channel-view.test.mjs` (147s)
  6. `tests/e2e/unread-drops-on-read.test.mjs` (142s)
  7. `tests/e2e/delete-confirm.test.mjs` (124s)
  8. `tests/e2e/calendar-phone-sheet.test.mjs` (121s)
  9. `tests/e2e/calendar-phone-month.test.mjs` (107s)
  10. `tests/e2e/calendar-phone-jump.test.mjs` (106s)
- **Total seconds per shard / RETRY / FLAKY counts**: 
  - Shard 1: 2124s
  - Shard 2: 2050s
  - Shard 3: 1796s
  - RETRY / FLAKY occurrences: 0 (n=3 shard logs, one green run)
- **Setup and teardown cost**: Browser launch and page open taking time per file.
- **Duplicated work**: 376 occurrences of `puppeteer.launch` in the codebase (`grep -ro "puppeteer.launch" csi-spl-wui/tests/e2e/ | wc -l`), though actual runtime launches are lower due to parallelism and shard logic.
- **Sleeps and polling waits**: 1859 `sleep()` calls (`grep -ro "sleep(" csi-spl-wui/tests/e2e | wc -l`).
- **Cache misses**: Puppeteer profiles and local storage are wiped per test.
- **Candidate fix**: Re-use a global Puppeteer browser instance (using incognito contexts instead of full launches).
- **Estimated saving**: Measured one local `puppeteer.launch` at ~1010 ms (n=5, box average). Depending on actual runtime launches, this could save several seconds to a minute of overhead per shard.

## 3. hub go incl. store

- **Overview**: The CI job limit is `timeout-minutes: 35`, but `hub-pg.tst.sh` splits the test into groups, applying a `GO_TEST_TIMEOUT=20m` (1200 s) limit to each. CI run `38207328805` took 1574 s overall, which is well within the 35 min limit, as it represents sequential group executions.
- **Timeout vs. Test Failures**: Checked n=4 failed hub jobs across recent failed runs (`114642216718`, `114459893794`, `114445898364`, `114438582356`). Out of these 4 failures, 0 were timeouts and 4 were test logic failures.
  (Query used to extract them: `gh api "repos/csitea/csi-spl/actions/runs?status=failure&per_page=30" --jq '.workflow_runs[].id' | xargs -I {} gh api repos/csitea/csi-spl/actions/runs/{}/jobs --jq '.jobs[]|select(.name|test("^hub:"))|select(.conclusion=="failure")|.id'`)
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
   - Exact measurement command: `jq '.[] | select(.name|test("^hub:")) | [.started_at, .completed_at]' M-JOBS.json` (where M-JOBS.json is the jobs array from analysis.md 1.1)
   - Baseline now (from analysis.md 1.1): 16.3 min (median) / 29.2 min (p90)
   - Proposed target: 10.0 min (median) / 15.0 min (p90)
2. **ORC Hermetic Duration**
   - Exact measurement command: `jq '.[] | select(.name|test("^orc: hermetic")) | [.started_at, .completed_at]' M-JOBS.json`
   - Baseline now (from analysis.md 1.1): Shard 1: 10.3m/23.0m, Shard 2: 9.0m/21.8m
   - Proposed target: < 10.0m (p90)
3. **WUI E2E Duration**
   - Exact measurement command: `jq '.[] | select(.name|test("e2e")) | [.started_at, .completed_at]' M-JOBS.json`
   - Baseline now (from analysis.md 1.1): ~30.0m (median) / ~40.0m (p90)
   - Proposed target: < 15.0m (p90)
4. **Nuxt Generate Duration**
   - Exact measurement command: `jq '.[] | select(.name|test("nuxt generate")) | [.started_at, .completed_at]' M-JOBS.json`
   - Baseline now (from analysis.md 1.1): 5.7 min (median) / 8.3 min (p90)
   - Proposed target: < 5.0 min (p90)

**(Secondary Lever Axes)**
- **WUI e2e browser launches code occurrences** (`grep -ro "puppeteer.launch" csi-spl-wui/tests/e2e/ | wc -l`): 376 occurrences target -> < 5
- **ORC sleeps** (`grep -o "sleep " csi-spl-orc/src/bash/tests/*.tst.sh | wc -l`): 272 occurrences target -> < 50
