# Tasks: CI/CD — pipeline (US2, M1) and CI logs in spool chat (US1, later)

**Feature**: `specs/008-spool-cicd-logs`  |  **Spec**: ./spec.md  |  **Plan**: ./plan.md  |  **Contracts**: ./contracts/pipeline.md (US2), ./contracts/fetch-deliver.md (US1)

Two blocks. **Phases 1–4 below are US1** (CI logs in chat, M1 flagged-off
stub; its `[US1]` tags are unchanged). **Phase 5 is US2** (the GitHub Actions
pipeline), after the US1 traceability. Every task's status (Implemented /
Partial / Planned, `specs/README.md` §2.3) is in the **Status** section at the
end; a checkbox is ticked only when that status is Implemented.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [x] T001 Contract `contracts/fetch-deliver.md`: hub-side fetch+deliver,
      flag default off, prd fail-closed, per-tenant allowlist, 32 MiB file,
      no `gh` in M1.
- [ ] T002 [P] Publish `SPOOL_HUB_CICD_LOGS_ENABLED=false` in
      `csi-spl-cnf/csi-spl/all.env.yaml` `hub.env` (names only; token is a
      secret, never a value). Do not tpl-gen / rewrite other steps.

## Phase 2: Foundational

- [x] T003 `internal/cicdlogs`: parse allowlist + tokens, placeholder
      detect, prd fail-closed, URL/`owner`+`repo`+`run_id` parse.
      (`csi-spl-api/src/go/spool-hub-api/internal/cicdlogs`)
- [x] T004 [P] HTTP fetcher (configurable API base, strip `Authorization`
      on redirect, scrub token from errors). No `gh`, no baked host.
- [x] T005 Fetch+deliver: blob put, `kind=note` + file, 32 MiB truncate +
      body line, `CI not configured` when no tenant token, empty allowlist
      denies. Memory bus in unit tests.

## Phase 3: User Story 1 — hub bus (stub) 🎯

- [x] T006 [US1] `config.LoadHub` reads the 008 env names; fail-closed in
      prd when enabled and the token is missing/placeholder.
      (`internal/config`)
- [x] T007 [US1] `POST /v1/cicd-logs` registered only when enabled; upload
      token; `to_box` = token box; commit on the existing envelope path;
      404 when the flag is off. (`internal/hub`)
- [x] T008 [US1] Hub tests: flag off → 404; unconfigured note; allowlist
      403; fake GitHub → note+file on the bus; cross-tenant isolation;
      token absent from body and error detail. (`internal/hub/hub_test.go`)
- [x] T009 [P] M1 Dockerfile still has no `gh`
      (`csi-spl-orc/src/docker/spool-hub-api/Dockerfile` — assert only).

## Phase 4: Polish

- [x] T010 `go test ./...` and `bash csi-spl-api/src/bash/tests/run-all-tests.sh`
      green. No wui, no 031, no token in git.

## Out of this stub (later)

T011 `gh` in the Cloud Run image (FR-001 after M3). T012 Secret Manager
slot + 029. T013 MCP/CLI. T014 WUI. T015 streaming tail.

## Traceability

| FR | Tasks |
|---|---|
| FR-001 (no gh in M1) | T009 |
| FR-002 token / optional / secret | T003, T006, T008 |
| FR-003 per-tenant allowlist | T003, T005, T008 |
| FR-004 v:1 note + file | T005, T007, T008 |
| FR-005 no token leak | T004, T008, T010 |
| FR-006 flag off, prd fail-closed, 32 MiB | T002, T005, T006 |

---

## Phase 5: User Story 2 — the GitHub Actions pipeline (M1) 🎯

Owner lane per task in brackets. The owner widened the redo to code
(2026-09-18T19:08Z): **008 owns the pipeline code** (`.github/workflows/`) and
its deploy check; terraform and applies stay 007's / the owner's.

- [x] T101 [US2] Both workflows on trunk: `10_ci-quality.yml` (hub-suite,
      no-ysg-box-ref, distribution-hygiene) and `20_hub-build-deploy.yml`
      (test → prepare-deploy → dev/prd matrix, WIF, forward-only guard,
      per-env concurrency, control-plane verify). (`.github/workflows/`)
- [x] T102 [P] [US2] `contracts/pipeline.md`: triggers, allow-list, jobs,
      the terraform-owns-the-image deploy rule, the repo variables consumed,
      the deploy SA grants, the pipeline's place after provisioning step 9.
- [x] T103 [US2] [007] `017-github-wif-deploy`: the default impersonated SA
      `<project>@<project>.iam.gserviceaccount.com` exists in neither project
      — use a dedicated deploy SA (created by 017 or named in cnf) and land
      017 on trunk. Plan only; apply needs the owner.
- [x] T104 [US2] [007] Grant the deploy SA the four roles in
      `contracts/pipeline.md` §3 (`workloadIdentityUser` is already in 017;
      add `artifactregistry.reader`+`writer` on the 028 repo, `run.developer`
      on the 030 service, `iam.serviceAccountUser` on the hub runtime SA).
- [ ] T105 [US2] [owner go] dev: apply 017, then export its outputs:
      `gh variable set GCP_WIF_PROVIDER_DEV` / `GCP_DEPLOY_SA_EMAIL_DEV`
      from `terraform output -raw wif_provider_name` / `deploy_sa_email`.
- [ ] T106 [US2] First live dev deploy: bump dev `hub.image.tag`, push;
      record the run id; require the deploy job `success` (not `skipped`),
      image == cnf ref, Ready, latest revision ready. Closes FR-P05/P06/P08
      for dev.
- [x] T107 [US2] [008] Fix the hygiene sweep (FR-P07): a
      clean `grep` must not abort the step under GitHub's `bash -e` — e.g.
      `hits="$(grep … | cut … | sort -u || true)"`. Proof: the extracted
      sweep script under `bash -e` prints five `ok -` lines and exits 0 on
      trunk, and a planted hit exits 1. (`.github/workflows/10_ci-quality.yml`)
- [ ] T108 [US2] [007] After T106: `030-cloud-run-hub` plan in dev shows **no
      diff**. 030 has no `lifecycle.ignore_changes`
      (`grep -c ignore_changes csi-spl-iac/src/terraform/030-cloud-run-hub/*.tf`
      → 0 each), and `gcloud run services update` may stamp client
      annotations; if the plan shows them, 030 ignores exactly those.
- [ ] T109 [US2] [owner go] prd, after prd provisioning steps 1–9
      (`specs/README.md` §6): apply 017 prd, export `…_PRD`, first prd deploy
      as in T106.
- [x] T110 [P] [US2] [008] FR-P09 deployed-state check `do_check_hub_deploy`: an orc action
      comparing cnf `hub.image.ref` with the live service image per env
      (`gcloud … --account=$GCP_ACCOUNT`), printing `current` / `lagging`
      and exiting non-zero when lagging. Read-only.
- [x] T112 [P] [US2] [008] WUI job in the gate: frozen-lockfile install,
      unit tests, typecheck (FR-P11). (`.github/workflows/10_ci-quality.yml`)
- [ ] T111 [P] [US2] (later) Pin third-party actions (`actions/*`,
      `google-github-actions/*`) by commit sha instead of major tag.

## Status (verified 2026-09-18, trunk `bbc41e7`)

| Task | Status | Evidence |
|---|---|---|
| T001 | Implemented | `ls contracts/fetch-deliver.md` → present |
| T002 | Partial | the code default is off (`envDefault:"false"` in `internal/config`), so unset = off everywhere. Writing the key into cnf is held back on purpose: hub env renders into the 030 tfvars (`grep -l SPOOL_HUB_ENABLE_FAKE_PAY csi-spl-cnf/csi-spl/*/tf/*` → both envs), so it would mean a re-render plus an owner-gated 030 apply mid-provisioning. It rides the next 030 re-render. |
| T003–T010 | Implemented (M1 stub, flag off) | this commit: GRK-3354's `c9ed24e` re-applied on trunk (one test conflict resolved, one `PutPin` call updated to trunk's signature); `go vet ./...` → 0, `go test ./...` → all ok, `bash csi-spl-api/src/bash/tests/run-all-tests.sh` → ALL PASSED, no gate skipped; `grep -c 'gh' …/Dockerfile` → 0 |
| T011–T015 | Planned (later) | — |
| T101 | Implemented | `git log --format=%h -- .github/workflows` → `3596991` |
| T102 | Implemented | this commit |
| T103, T104 | Implemented (code; not applied) | `2a7888c`: `git grep -c 'google_service_account" "deploy"\|deploy_writer\|deploy_developer\|deploy_acts_as_hub' origin/master -- csi-spl-iac/src/terraform/017-github-wif-deploy` → `03-github-wif.tf:4` (the SA + three grants). `artifactregistry.writer` includes read. Applying is 007 T050 (owner go). |
| T105, T109 | Planned | 2026-09-18T19:40Z: `gh variable list -R csitea/csi-spl` → empty; `gcloud iam workload-identity-pools list --location=global --project=csi-spl-{dev,prd} --account=$GCP_ACCOUNT` → 0 in both; blocked on 007 T050 |
| T106 | Planned | deploy job `skipped` in 8 of 8 runs of `20 ci-cd` |
| T107 | Implemented | `4839514`; run `35385087709` → `distribution-hygiene` success (first green gate since `3596991`) |
| T108, T111 | Planned | — |
| T112 | Implemented | `18a19dc`; run `35386487700` → wui job success, 30/30 |
| T110 | Implemented | `csi-spl-orc/src/bash/run/check-hub-deploy.func.sh`; `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` → 8/8; live dev → `current`, rc 0 |

## Traceability — US2

| FR | Tasks |
|---|---|
| FR-P01 two workflows, push + dispatch, no PR | T101 |
| FR-P02 gate unfiltered, deploy allow-list | T101, T102 |
| FR-P03 suite, skip = fail | T101 |
| FR-P04 WIF only, repo variables | T103, T104, T105, T109 |
| FR-P05 terraform owns the image | T101, T106, T108 |
| FR-P06 dev + prd matrix, guard, concurrency | T101, T106, T109 |
| FR-P07 hygiene sweep passes clean | T107 |
| FR-P08 control-plane verify | T101, T106 |
| FR-P09 deployed-state check | T110 |
| FR-P10 names from cnf | T101 |
| FR-P11 WUI tests in the gate | T112 |

<!-- version: 0.2.5 · updated: 2026-09-18 · last-edit: 2026-09-18T19:37:01Z -->
