# Implementation Plan: CI/CD — pipeline (US2, M1) and CI logs in chat (US1, later)

**Feature**: `008-spool-cicd-logs` · **Spec**: ./spec.md · **Tasks**: ./tasks.md

## 1. Summary

**2026-09-25**: the pipeline deploys dev and prd on the project SA key (first
roll `77e071fb`, 2026-09-19; run `36170413419` both envs `success`). Left: T108
(no-diff 030 plan proof), T111 (sha-pinned actions, owner question), T115. The
M1 CI-logs stub is on trunk (`internal/hub/server.go` `POST /v1/cicd-logs`,
flag off). The rest of this plan is the 2026-09-18 critical path, kept as
history.

*2026-09-18:* The pipeline code is on trunk (`3596991`), but has **never deployed**: every
deploy job so far was skipped because WIF does not exist yet. The work left is
mostly **other lanes' prerequisites** (007's `017`), **owner-gated applies**,
one **broken gate** (the hygiene sweep) and one read-only **deployed-state
check**. CI logs in chat stays a later feature; its M1 stub is written on
another lane's branch.

## 2. Critical path to a green, deploying pipeline

| # | Step | Owner | Tasks | Blocks |
|---|---|---|---|---|
| 1 | ~~Make the gate green~~ — **done** `4839514`, run `35385087709` | 008 | T107 | — |
| 2 | ~~017 lands on trunk with a deploy SA and the grants~~ — **done** `2a7888c`; apply is 007 T050 | 007 | T103, T104 | 3 |
| 3 | dev: apply 017, export the two `…_DEV` repo variables | owner go | T105 | 4 |
| 4 | First dev deploy through a tag bump, then a 030 plan with no diff | 008 verifies, 007 fixes 030 if needed | T106, T108 | 5 |
| 5 | prd: provisioning steps 1–9 (`specs/README.md` §6), then 017, variables and the first deploy | 007 / owner go | T109 | — |
| 6 | ~~Deployed-state check~~ — **done**: `do_check_hub_deploy` | 008 | T110 | — |
| 7 | ~~Post-deploy smoke reads 200~~ — **done**: run `35390460157`, 4/4 hosts 200; post-M1 allowlist rule stays open (T115) | 008 / 007 | T113–T116 | — |

Dev goes all the way through before prd, as README §6 says.

## 3. Design decisions (kept from `3596991`, recorded here)

- **The pipeline is not a provisioning step.** It never creates or
  re-permissions anything; it takes over the image roll only after step 9.
  So `terraform apply` stays with the owner, and a missing resource fails loudly.
- **One deploy contract: terraform owns the image.** The deploy rolls to
  exactly cnf `hub.image.ref`, the same value 030's `var.image` holds, so the
  pipeline and terraform cannot disagree about what should run. Per-sha tags
  would split that authority, so there are none.
- **Skip, don't fail, an env without WIF variables.** That let the workflow
  land before 017 without turning trunk red. The cost: a green `20 ci-cd` run
  says **nothing** about deployment until T105. Whether an env really
  deployed comes from the deploy job's conclusion (`success` vs `skipped`)
  and from `do_check_hub_deploy` (T110) — never from the
  run's colour.
- **Verification uses the control plane**, because 031's IP allowlist keeps
  runners away from `/healthz`.
- **No required reviewers** on the `dev` / `prd` environments (owner standing
  order: both deploy on the same push).

## 4. Risks

| Risk | Mitigation |
|---|---|
| `gcloud run services update` leaves fields that 030 then plans to revert | T108: plan after the first roll; `ignore_changes` only on the exact fields shown |
| prd push runs fail once the `…_PRD` variables exist but prd 028/030 do not | Set the prd variables only after prd step 9 (T109) |
| Actions pinned by major tag | T111 (later): pin by sha |
| A broken gate trains readers to ignore red | Fixed (T107); a sweep grep error now fails the gate instead of passing it |

## 5. US1 — CI logs in chat

Unchanged: `contracts/fetch-deliver.md`, tasks T001–T015. After M3 in the
dependency order (`specs/README.md` §4). The M1 flagged-off stub is on trunk
(landed from `c9ed24e`).

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:30:11Z -->
