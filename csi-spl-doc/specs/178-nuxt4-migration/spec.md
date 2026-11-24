# Spec 178: move the WUI from Nuxt 3 to Nuxt 4

Version **0.3.0** (2026-11-24; 0.3.0 adds section 6, the move as built by SPL-5070; 0.2.1 the 30-day renewal; 0.2.0 folds R7 grok g-390 W1, N1..N3). Lane `c-385`, placement slug
`ci50-05-nuxt4-migration-spec`. Epic **SPL-2402**, issue **SPL-5661**, kind
`specs_and_docs`. Parent spec: `csi-spl-doc/specs/011-spool-project-refactor`.
Source: `csi-spl-doc/doc/md/ci-failures-50-2026-11-15.md` (SPL-5587) section 7
row 5, theme T4, urgency 53, due 2026-11-27. Plan: [plan.md](plan.md).

Measured on `origin/master` `d28c444f4` unless a line says otherwise.

## 1. The problem

Nuxt 3 is end of life: `npm view nuxt dist-tags` -> `3x: 3.21.11`,
`latest: 4.6.4`. The WUI is on the last 3.x
(`grep -n '^  nuxt@' csi-spl-wui/pnpm-lock.yaml` -> `nuxt@3.21.11`). A new
advisory against nuxt 3 gets no 3.x fix, so each one has been answered with an
osv-scanner ignore that carries an expiry. When nobody re-checks the ignore in
time, the expiry turns workflow 70 red: the 2026-11-05 expiry kept it red
until 2026-11-08 (`git show -s d5c183668`). That is theme T4 of the CI failure
study: 10 of the last 50 red runs.

Today `osv-scanner.toml` holds 8 ignores:

| id | package | until | issue | reason ends "Real fix: nuxt 4 migration" |
|---|---|---|---|---|
| GHSA-vjh5-4x84-xrqp | nuxt / @nuxt/nitro-server 3.21.11 | 2026-11-27 | SPL-2908 | yes |
| GHSA-xfq5-w38q-pc2x | nuxt 3.21.11 | 2026-11-27 | SPL-2908 | yes |
| GHSA-jjm6-p2m9-9w4x | nuxt 3.21.11 | 2026-11-27 | SPL-2908 | yes |
| GHSA-gcqx-w48m-w2h4 | deepmerge 4.3.1 | 2026-11-27 | SPL-3972 | no (no fixed release at all) |
| GHSA-g3hv-75wg-m249 | minimatch 5/9/10 | 2026-11-30 | SPL-4508 | no (its block comment names nuxt 4) |
| GHSA-3g3m-2fjr-6pw4 | glob 10/13 | 2026-11-30 | SPL-4508 | no (its block comment names nuxt 4) |
| GHSA-648h-gw55-m2g7 | @nuxt/vite-builder 3.21.11 | 2026-11-30 | SPL-4508 | yes |
| GHSA-mjrq-cffv-q4qc | @nuxt/schema 3.21.11 | 2026-11-30 | SPL-5474 | yes |

Checks: `grep -c 'Real fix: nuxt 4 migration' osv-scanner.toml` -> 5;
`grep -c '^ignoreUntil = 2026-11-27' osv-scanner.toml` -> 4;
`grep -c '^ignoreUntil = 2026-11-30' osv-scanner.toml` -> 4.

The pnpm audit leg (workflow 15) keeps its own list in
`csi-spl-wui/package.json` under `pnpm.auditConfig.ignoreGhsas`: 7 ids. They are
vjh5, xfq5, g3hv, 3g3m, 648h, mjrq and braces `GHSA-vfj7-8cjw-p6xm`. That list
has no date field, so it never expires on its own. For the config, this
answers open question 4 of the study: wf 15 does not read the osv dates. I did
not run wf 15 to see whether it reddens on 11-27 for some other reason.

Before this spec, master had no nuxt 4 plan:
`git grep -il 'nuxt 4 migration' d28c444f4 -- csi-spl-doc` -> 1 file, the study
itself.

## 2. Goal

- G1. The WUI builds, tests and deploys on Nuxt 4 (4.6.4 or later) on dev and
  prd. The output stays the same: `nuxt generate` static files on Firebase
  Hosting.
- G2. The 5 ignores whose reason names the nuxt 4 move leave
  `osv-scanner.toml`, and their ids leave `pnpm.auditConfig.ignoreGhsas`, in the
  same commit as the move. The other 3 (gcqx, g3hv, 3g3m) are measured after the
  move. Each is removed when osv-scanner names it unused; otherwise it keeps
  its own re-check (section 4).
- G3. Until G1 lands, no ignore reaches its date unless a named lane has
  re-checked it (section 4). Workflow 70 going red on an expiry date is the
  failure this spec exists to prevent. It must not be the reminder.

Out of scope: any WUI feature change, a change of hosting, `ssr: false`, the
hub (`csi-spl-api`).

## 3. What the move touches

Facts read from the registry on 2026-11-16 (`npm view <pkg> ...`). Each one
becomes a step in the plan:

| # | fact | command | consequence |
|---|---|---|---|
| F1 | nuxt 4.6.4 needs node `^22.22.3 \|\| ^24.15.0 \|\| >=26.0.0` | `npm view nuxt@4.6.4 engines` | CI runs node 20 (`grep -rn node-version .github/workflows/*.yml` -> 9 lines, all `20`). The box runs node 20 too (`node --version` -> v20.19.2), and `csi-spl-wui/package.json` says `"node": ">=20.0.0"`. All three move to 22 first. |
| F2 | nuxt 4.6.4 depends on `vue-router ^5.4.0` | `npm view nuxt@4.6.4 dependencies` | Our package.json pins `vue-router ^4.5.0`: bump it or drop it. Re-check `src/app/router.options.ts`, the one router file. |
| F3 | nuxt 4.6.4 depends on `unhead` / `@unhead/vue ^3.4.3` | same | `grep -rnE '__NUXT__\|useHead\|useSeoMeta' csi-spl-wui/src` -> 16 lines; one is a comment in `src/public/sw.js`, so 15 call sites. `public-seo.mjs` also injects head tags. Re-check each one. |
| F4 | `@nuxt/vite-builder@4.6.4` depends on `vite ^8.3.5` | `npm view @nuxt/vite-builder@4.6.4 dependencies` | Our `pnpm.overrides` forces `vite ^7.3.7`. The override goes (or moves to 8) in the same commit, and `tests/unit/override-dependents-link.test.mjs` proves it links. Re-check the Rollup-shaped code in `nuxt.config.ts` (`manualChunks`, `import type { Rollup } from "vite"`) against vite 8. |
| F5 | `@nuxtjs/i18n@10.2.3` depends on `@nuxt/kit ^4.1.2` and `vue-router ^4.6.3`; `@nuxtjs/i18n@10.6.0` (latest) on `@nuxt/kit ^4.5.1` and `vue-router ^5.2.0`; `@pinia/nuxt@0.11.3` on `@nuxt/kit ^4.2.0` | `npm view <pkg> dependencies` | pinia needs no bump. i18n does: its 10.2.3 `vue-router ^4.6.3` does not overlap nuxt 4.6.4's `^5.4.0` (F2), so the exact pin `@nuxtjs/i18n 10.2.3` moves to 10.6.0 or later. 10.6.0 wants vue-router 5, which nuxt 3 does not take, so the i18n bump lands in P4 with nuxt, not in P3. |
| F6 | the config already pins the nuxt 4 directory settings | `grep -nE 'srcDir\|workspaceDir' csi-spl-wui/nuxt.config.ts` -> `srcDir: "src/"`, `workspaceDir: "."` | Nuxt 4's new default srcDir (`app/`) does not apply, and `~/` still means `src/`. |
| F7 | 2 files call `useAsyncData` (`grep -rlE 'useAsyncData\|useFetch' csi-spl-wui/src` -> `components/LoginFeatures.vue`, `pages/blog.vue`) | | Nuxt 4 changes data fetching (`data` becomes a shallow ref, its default becomes `undefined`), so those 2 files are re-checked. The `experimental.payloadExtraction` comment in `nuxt.config.ts` ("no page uses useAsyncData/useFetch") is stale and gets corrected in P3. |
| F8 | the config loads 10 modules, 8 of them local (`modules:` line of `nuxt.config.ts`), and uses nuxt hooks such as `modules:done` | | Each local module is rebuilt and its output compared (plan P3). |

Not measured yet, left to plan P1: whether nuxt 4 drops minimatch, glob and
deepmerge from the tree (`pnpm why` on the migration branch).

## 4. Until the move lands, a named lane re-checks each ignore

For each expiry date, the dispatcher places one re-check lane two days ahead,
kind `simple_coding`. The lane re-runs the reason written in the toml against
the current tree: the advisory text, the fixed version, and whether our code
reaches the bug. It then does one of three things:

- removes the ignore;
- moves its date by at most 14 days and writes the new check into the reason;
- reports that the ignore cannot hold.

The lane owns `osv-scanner.toml` and `csi-spl-wui/package.json`
`pnpm.auditConfig.ignoreGhsas`, for its own ids only.

| placement slug | placed by | ids | issue to cite |
|---|---|---|---|
| `osv-recheck-20261127` | 2026-11-25 | vjh5, xfq5, jjm6, gcqx | SPL-2908, SPL-3972 |
| `osv-recheck-20261130` | 2026-11-28 | g3hv, 3g3m, 648h, mjrq | SPL-4508, SPL-5474 |
| `osv-recheck-20261227` | 2026-12-25 | vjh5, xfq5, jjm6 | SPL-2908, SPL-5070 |
| `osv-recheck-20261230` | 2026-12-28 | 648h, mjrq, f3x9, hf59, 96x6 | SPL-4508, SPL-5474, SPL-5804, SPL-5070 |

The commit that sets any later expiry adds its row to this table.

On 2026-11-24 the owner chose a 30-day renewal over the 14-day cap above
(HUM-10, t1 80e54ed8, msg 8fca4dfc, answer C: "renew the ignores now, and
resume SPL-5070"). Lane `c002-nuxt3-ignores-renew-30d` re-checked the 8 nuxt 3
ignores and moved 2026-11-27 to 2026-12-27 and 2026-11-30 to 2026-12-30; the
two tooling ignores (g3hv, 3g3m) keep 2026-11-30. The deepmerge ignore (gcqx)
left the toml on 2026-11-17 (SPL-5816).

The date is the control. With today's tree, workflow 70 reads 4 expired ids
on 2026-11-27 and 8 on 2026-11-30. If wf 70 is green on those dates and the
move has not landed, the re-check lane ran.

## 5. Acceptance

- A1. `csi-spl-wui/pnpm-lock.yaml` has `nuxt@4.` and no `nuxt@3.`.
- A2. `pnpm run typecheck`, `pnpm run test:unit`, `pnpm run lint` and
  `pnpm run generate` pass on node 22 in CI.
- A3. `BASE_URL=<generated bundle> pnpm run test:e2e` passes, and the
  first-screen and JS budget tests keep their numbers. Any change is measured
  and written down with its cause.
- A4. The 5 "Real fix: nuxt 4 migration" ignores are gone from both lists, and
  osv-scanner (workflow 70) and pnpm audit (workflow 15) are green on the
  landing sha.
- A5. dev and prd serve the new build (`ENV=<env> ./run -a do_check_deploy_lag`).
- A6. The WUI README (line 19 says `Nuxt 3` today) and the
  `csi-spl-wui/package.json` `description` both say Nuxt 4.

## 6. The move as built (SPL-5070, 2026-11-24)

Lanes c-137, then c-980. Measured on the bump's tree, rebased on origin/master
`3eec1eb89`, unless a line says otherwise.

- Versions: nuxt 4.6.4, vue-router 5, @nuxtjs/i18n 10.6.0, vite 8 (rolldown).
  P3 and P4 landed as one bump: the vite 8 chunking, the i18n settings and
  the nuxt 4 types do not build on nuxt 3. P2 (node 22) is its own commit
  ahead of it.
- Chunking: `manualChunks` became rolldown `codeSplitting` groups, and
  `checks.circularDependency` is on, so the app-cycle guard still fires
  (c-137, a planted cycle failed the build, n=1). Component islands are off
  (nuxt 4 `auto` registered the island plugin).
- i18n 10.6 turns `experimental.optimizeMessageBundling` on by default; it is
  off, or the prerendered pages show raw `{placeholders}`
  (`tests/unit/i18n-runtime-only.test.mjs` pins it).
- Budgets (box generate, node 22.23.5, n=1): `ci_initial_gzip_kb` 153.1
  (ceiling 155; master's CI on `c4000b25b`: 151.9), home 334.4, costs route
  11.5. Rolldown inlines imported constants, so the costs route marker moved
  from the mock key to `"ai_share_from"`
  (`csi-spl-orc/src/bash/scripts/perf-budget.py`).
- Node 20: the nuxt 4 tree still installs (an engines warning), typechecks
  and generates on the box's node 20.19.2. CI runs 22.
- A4 holds only in part. Of the 8 nuxt 3 ignores, osv-scanner 2.6.0 with no
  ignores lists none of xfq5, jjm6, 648h and mjrq on the 4.6.4 lockfile, so
  they left the toml. vjh5, f3x9, hf59 and 96x6 still match 4.6.4. This is a
  false positive. GitHub's record (`gh api /advisories/<id>`) bounds the
  unpatched 3.x range at `< 4.0.0`. The OSV record keeps only
  `introduced: 3.0.0` and drops that bound. The 4 entries therefore stay with
  that reason and their renewed dates, until osv-scanner names them unused.
  `pnpm audit` lists none of the 8 nuxt ids, nor braces (vfj7), so
  `ignoreGhsas` now holds only the 2 tooling ids, g3hv and 3g3m.
  osv-scanner also named picomatch (fc5q) unused on this lockfile, so it left
  the toml.

<!-- version: 0.3.0 · updated: 2026-11-24 -->
