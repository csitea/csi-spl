# WUI typecheck heap (SPL-4831, 2026-11-05)

wf 30 run 41920703912 (ce769cf93), attempt 1: the job "WUI unit tests +
typecheck" died in `pnpm run typecheck` with `FATAL ERROR: Ineffective
mark-compacts near heap limit ... JavaScript heap out of memory`; its rerun
passed on the same sha. Typecheck sits at the heap edge of the hosted runner.

## 1. Measured

Local box: 16 cores, 62 GB, node v20.20.2, tree 76ce2e9b7, n = 3 per row.
The peak RSS (`VmHWM`) and the heap at exit were read by a `--require`
preload in `NODE_OPTIONS`, which reaches the vue-tsc child of
`nuxt typecheck`; `/usr/bin/time` is not on the box.

| `--max-old-space-size` | result | vue-tsc heap used at exit | peak RSS |
|---|---|---|---|
| default (4144 MB here) | 3/3 pass, 42..70 s | 2545..2547 MB | 2724..2725 MB |
| 2048 | 3/3 OOM | n/a | n/a |
| 2560 | 3/3 pass, 149..188 s | 2449..2450 MB (94% of 2608) | 2629..2633 MB |
| 3072 | 3/3 pass, 140..154 s | 2449..2475 MB (80% of 3120) | 2647..2682 MB |
| 4096 (the fix) | 3/3 pass, 39..42 s | not read | not read |

The live set at the end of the check is ~2450 MB. The same runs with
`tests/**` excluded reach the same live heap (largest live heap after a
mark-compact 1698..1752 MB, against 1720..2342 MB with the tests in), so the
972 test `.mjs` files that tsc parses are not the cause. The size comes from
the app's own type program.

CI, wf 10 and wf 30, 2026-10-29..2026-11-05 (138 wf 30 runs, 670 wf 10 runs):
every failed typecheck job's log was read. 3 died with the OOM, all on hosted
`ubuntu-latest` (wf 10 also runs there: repo variable `SPOOL_CI_RUNNER`, see
[ci-disk-full-prevention-2026-11-04.md](ci-disk-full-prevention-2026-11-04.md)):

| run | workflow | heap at death |
|---|---|---|
| 41920703912 | wf 30 | Scavenge 2042.5 (2083.1) MB |
| 41761114293 | wf 30 | Scavenge 2041.6 (2087.1) MB |
| 41544796875 | wf 10 | Mark-Compact 2044.3 (2084.5) MB |

So the hosted runner gives vue-tsc a ~2048 MB default heap, under the
~2450 MB it needs. The other 7 typecheck failures in the window were not
OOM. No peak RSS was read on the runner itself: the logs do not print it.

## 2. The fix

Every caller runs `pnpm run typecheck`: wf 10 job `wui-suite`, wf 30 job
`test` and the deploy leg's fallback suite, the pre-push gate
(`check-pre-push.func.sh`), `do_wui_test` and `do_deploy_wui`. So the heap
lives once, in `csi-spl-wui/package.json`, in the form `generate` already
uses (SPL-4793):

`"typecheck": "NODE_OPTIONS=\"${NODE_OPTIONS:---max-old-space-size=4096}\" nuxt typecheck"`

4096 MB leaves ~40% over the measured live set. A caller that sets
`NODE_OPTIONS` keeps its own value. Proof that the value reaches vue-tsc:
the same script at 1500 MB OOMs.

## 3. The guard

`csi-spl-wui/tests/unit/typecheck-heap.test.mjs` (unit suite, so wf 10, wf 30
and the pre-push gate run it) fails when:

1. the typecheck script has no heap option, or one under 3072 MB;
2. a workflow or a `./run` action of iac or orc calls `nuxt typecheck`,
   `nuxi typecheck` or `vue-tsc` itself, on the default heap;
3. one of them sets `NODE_OPTIONS` with no heap option, which would replace
   the script's default.

Red controls: with the old `"nuxt typecheck"` script the test fails on 1, and
with `npx nuxt typecheck` planted in wf 30 it fails on 2.
