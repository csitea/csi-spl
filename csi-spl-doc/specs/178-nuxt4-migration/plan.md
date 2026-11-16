# Plan 178: the Nuxt 4 move in steps that each land

Version **0.1.0** (2026-11-16). Spec: [spec.md](spec.md). Issue SPL-5661,
epic SPL-2402. Each phase is its own lane with its own issue, and the
dispatcher places them in order. Each phase lands green on its own, and the
WUI keeps working on nuxt 3 until P4.

## P0. Re-check lanes for the ignores (now, blocked by nothing)

Place `osv-recheck-20261127` by 2026-11-25 and `osv-recheck-20261130` by
2026-11-28 (spec section 4). They run whether or not the move has started.
If P4 lands first, the lane only confirms the ids are gone, then ends.

## P1. Measure on a branch (one lane, `specs_and_docs` or `simple_coding`)

On a throwaway branch, run `pnpm add nuxt@^4.6.4` in `csi-spl-wui`. Nothing
from this phase is committed to master. Record each result with the command
that produced it:

1. `pnpm why minimatch glob deepmerge`: which of gcqx, g3hv and 3g3m leave
   the tree.
2. The osv-scanner and `pnpm audit` results on the branch lockfile.
3. `pnpm run typecheck`, `test:unit`, `lint` and `generate` on node 22: the
   failures, grouped by cause.
4. The size of the generated bundle compared with master's (the first-screen
   budget test numbers).

Output: a table appended to this plan, with a version bump. It sets the size
of P3.

## P2. Node 22 everywhere (one lane, `simple_coding`)

This phase stays on nuxt 3, which runs on node 22. Three things move together:

- every `node-version: 20` in `.github/workflows/*.yml` (9 lines today) to 22;
- `csi-spl-wui/package.json` `engines.node` to `>=22.22.3`;
- the box node, through `do_box_pkg_install` where the owner can see it,
  never by hand.

Gate: the WUI suite and workflows 10, 15 and 30 are green on node 22. Landing
this alone keeps a node failure separate from a nuxt failure.

## P3. Code changes that work on both 3 and 4 (one or more lanes, `complex_coding`)

From the P1 failure list, land every fix that also runs on nuxt 3, so that P4
is only the version bump. The areas to expect (spec section 3):

- `router.options.ts` (vue-router 5);
- the head calls (unhead 3);
- the 2 files that call `useAsyncData`;
- the `manualChunks` split and the Rollup types in `nuxt.config.ts` (vite 8);
- the 7 local modules in `nuxt.config.ts`.

## P4. The bump (one lane, `complex_coding`)

One commit holds all of it:

- `nuxt ^4.6.4`, `vue-router` per F2 and the `vite` override per F4, with the
  lockfile;
- the 5 ignores removed from `osv-scanner.toml`, and their ids removed from
  `pnpm.auditConfig.ignoreGhsas`, plus any id P1 showed unused;
- the WUI README and the package `description`.

The lane runs the full WUI gate, including `test:e2e` against the generated
bundle, then lands. It then watches workflows 15, 30 and 70 and the dev and
prd deploys (spec A1..A5).

Rollback: revert the P4 commit. P2 and P3 stay.

## Risks

- R1. Vite 8 is built on rolldown (`@nuxt/vite-builder@4.6.4` lists
  `rolldown-string`). The `manualChunks` vendor split and the circular-import
  guard in `nuxt.config.ts` may behave differently. P1 item 4 measures this.
- R2. A new nuxt 3 advisory may arrive before P4. It is answered as today:
  an ignore with a date, plus a row in spec section 4 in the same commit.
- R3. The box node upgrade affects every lane that runs the WUI suite on the
  box. P2 tells the orchestrator before it lands.

<!-- version: 0.1.0 · updated: 2026-11-16 -->
