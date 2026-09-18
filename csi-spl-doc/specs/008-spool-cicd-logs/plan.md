# Implementation Plan: CI/CD — pipeline (US2, M1) and CI logs in chat (US1, later)

**Feature**: `008-spool-cicd-logs` · **Spec**: ./spec.md · **Tasks**: ./tasks.md

## 1. Summary

The pipeline code is on trunk (`3596991`), but has **never deployed**: every
deploy job so far was skipped because WIF does not exist yet. The work left is
mostly **other lanes' prerequisites** (007's `017`), **owner-gated applies**,
one **broken gate** (the hygiene sweep) and one read-only **deployed-state
check**. CI logs in chat stays a later feature; its M1 stub is written on
another lane's branch.

## 2. Critical path to a green, deploying pipeline

| # | Step | Owner | Tasks | Blocks |
|---|---|---|---|---|
| 1 | Make the gate green: the hygiene sweep must pass a clean tree | workflow author lane | T107 | nothing — do it first |
| 2 | 017 lands on trunk with a deploy SA that exists, plus the grants in `contracts/pipeline.md` §3 | 007 | T103, T104 | 3 |
| 3 | dev: apply 017, export the two `…_DEV` repo variables | owner go | T105 | 4 |
| 4 | First dev deploy through a tag bump, then a 030 plan with no diff | 008 verifies, 007 fixes 030 if needed | T106, T108 | 5 |
| 5 | prd: provisioning steps 1–9 (`specs/README.md` §6), then 017, variables and the first deploy | 007 / owner go | T109 | — |
| 6 | Deployed-state check | orc lane | T110 | — (parallel) |

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
  and, once T110 exists, from the deployed-state check — never from the
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
| A broken gate trains readers to ignore red | T107 first; the gate has been red on every run since it landed |

## 5. US1 — CI logs in chat

Unchanged: `contracts/fetch-deliver.md`, tasks T001–T015. After M3 in the
dependency order (`specs/README.md` §4). The M1 flagged-off stub is being
built on branch `GRK-3354-008-cicd-logs-stub`.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:02:27Z -->
