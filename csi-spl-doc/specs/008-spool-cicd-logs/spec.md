# Feature Specification: CI/CD — the GitHub Actions pipeline, and CI logs in spool chat

**Feature ID**: `008-spool-cicd-logs` (dir name kept, scope widened —
`specs/README.md` §4)

**Created**: 2026-09-18 · **Redone**: 2026-09-18 (git-spec redo, area 008)

**Status**: US2 pipeline — **Implemented** (deploys dev and prd on the project
SA key since `77e071fb`, 2026-09-19; open: T108 no-diff 030 plan proof, T111
sha-pinned actions, T115). US1 CI logs in chat — **Partial** (M1 flagged-off
stub implemented; the feature is later, after M3).

**Synced 2026-09-25** (trunk `bbe04d26`, n=1 each): run `36170413419` of
`20_hub-build-deploy.yml` on `ea35f7c4` → `success`, jobs "Deploy hub to dev"
/ "Deploy hub to prd" / both post-deploy smokes `success`
(`gh run view 36170413419 --json jobs`). The FR table below keeps its
2026-09-18 evidence; the rows re-stated here win where they disagree.

**Contracts**: `contracts/pipeline.md` (US2), `contracts/fetch-deliver.md` (US1)

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-cicd-logs.md` (US1)

Ground rules, status vocabulary and seams: `specs/README.md`. This spec owns
the **pipeline jobs, gates and deploy matrix**; the WIF deploy identity
(tf `017`), every terraform step and the provisioning order are **007's** and
are cited, not restated (README §5, §6).

## User Story 2 (P1, M1) — every trunk push is gated, and a cnf tag bump deploys dev and prd

The owner pushes to `master`. The quality gate proves the tree (tests, gates,
hygiene) with no GCP identity. When the push touches a hub build input, the
pipeline runs the suite again, then — for each env with a deploy identity
(key secret, else WIF variables) — pushes the cnf-named image if the registry lacks it and rolls the
existing Cloud Run service to it, in dev and prd on the same push, without a
second approval.

**Acceptance**:

1. A push to `master` runs `10 ci: quality gate`; all its jobs green on a
   clean tree (9 jobs at `bbe04d26`: hub-suite, wui-suite, wui-e2e,
   iac-suite, orc-suite, cnf-suite, no-ysg-box-ref, gate-health,
   distribution-hygiene).
2. A push that bumps `hub.image.tag` in `<env>.env.yaml` builds, pushes and
   rolls that env; the service then runs exactly cnf `hub.image.ref`, is
   Ready, and its latest revision is the ready one. A later `030` plan shows
   no image drift.
3. A push that changes hub code without a tag bump deploys nothing and says so.
4. An env without a deploy identity (neither key secret nor WIF variables) is skipped with a notice, never failed and
   never provisioned; a missing registry or service fails the run.
5. No key material, secret value or owner identity appears in a workflow file or
   a run log (the key is referenced only as `secrets.GCP_KEY_CSI_SPL_<ENV>`).

## User Story 1 (P3, later) — CI logs in chat

A pinned human or agent in a tenant thread asks for a GitHub Actions run.
The hub fetches the log with `gh` and posts a `note` + file on that
`task_id`.

**Acceptance**: token never appears in the message or Cloud Run logs; wrong
tenant cannot read another tenant’s repos.

## Requirements — US2 pipeline (M1)

| FR | Requirement | Status (verified 2026-09-18, trunk `bbc41e7`; FR-P07, FR-P09, FR-P12 re-verified after) |
|---|---|---|
| **FR-P01** | Two workflows: `10_ci-quality.yml` (hermetic gate) and `20_hub-build-deploy.yml` (test → prepare-deploy → matrix deploy). Push to `master` + `workflow_dispatch`; **no `pull_request`** (trunk-based). | **Implemented** — `3596991`; `gh run list -L 100` → 11 gate runs, 8 deploy runs since, all `push`. |
| **FR-P02** | The quality gate has **no `paths:` filter**; the deploy workflow has an **allow-list** of every build input (`contracts/pipeline.md` §1.1). | **Implemented** — `grep -cE '^\s+paths:' .github/workflows/10_ci-quality.yml` → 0; same on `20_hub-build-deploy.yml` → 1. |
| **FR-P03** | The gate runs `run-all-tests.sh` and **fails on a skipped** Postgres / GCS gate; `no-ysg-box-ref` is its own job. | **Implemented** — run `35382695327` (sha `9f8f492`): `hub-suite` success, `no-ysg-box-ref` success. |
| **FR-P04** | Deploy auth (**amended 2026-09-19, owner key rule**, `f8721dde`): the per-env project SA key secret `GCP_KEY_CSI_SPL_<ENV>` (published by tf `120`) first; WIF from repo variables `GCP_WIF_PROVIDER_<ENV>` / `GCP_DEPLOY_SA_EMAIL_<ENV>` (007 `017`) is the alternative. The key is only ever a secret reference. | **Implemented** (key path) — 2026-09-25: `grep -c credentials_json .github/workflows/*.yml` → 1 each in `00`, `20`, `30`; run `36170413419` deployed both envs. WIF variables are still unset, so the alternative is untested. Owner question: keep or retire WIF (017). *Superseded 2026-09-18 evidence:* **Partial** — workflow side implemented (`grep -c 'credentials_json' .github/workflows/*.yml` → 0). Inputs absent: `gh variable list -R csitea/csi-spl` → empty; `017-github-wif-deploy` is on trunk (`2a7888c`) but **not applied**; `gcloud iam workload-identity-pools list --location=global --project=csi-spl-{dev,prd} --account=$GCP_ACCOUNT` → none. |
| **FR-P05** | **Terraform owns the image.** A deploy is a cnf `hub.image.tag` bump; the pipeline pushes exactly cnf `hub.image.ref` when absent (via `do_build_push_hub_image`), rolls the existing 030 service to it, never pushes a per-sha tag, never creates or re-permissions anything. | **Implemented** — first pipeline roll `77e071fb` (hub 0.1.3), latest run `36170413419` (both envs `success`); `curl -s https://{,dev.}api.<BASE_DOMAIN>/version` → `0.5.7` both (2026-09-25). The no-diff 030 plan proof is T108. *2026-09-18 evidence:* **Partial** — logic implemented in `3596991`; **never executed**: the deploy job is `skipped` in 8 of 8 runs (`gh run view <id> --json jobs`), because FR-P04's inputs are absent. |
| **FR-P06** | Deploy matrix **dev + prd on one push**, `fail-fast: false`, per-env `concurrency` with `cancel-in-progress: false`, **forward-only guard** on push runs; a dispatch naming one env is unguarded (rollback path). No required reviewers on the GitHub environments. | **Implemented** — run `36170413419`: dev and prd deploy jobs both `success` on one push; `gh api repos/csitea/csi-spl/environments` → `dev`, `prd`, 0 protection rules each. *2026-09-18 evidence:* **Partial** — in the workflow (`3596991`); untested live (same cause). `gh api repos/csitea/csi-spl/environments` → no environments yet (GitHub creates them on first use). |
| **FR-P07** | The hygiene sweep passes on a clean tree and fails only on a hit, printing `file:line`, never the value. | **Implemented** — fixed in `4839514`; run `35385087709` → all three gate jobs success. Before the fix it failed in 9 of 9 runs on a clean tree: a clean `grep` returns 1, `pipefail` carries it into `hits="$(…)"`, and the step's `bash -e` aborted the script. Now rc 1 = clean and rc > 1 (bad pattern) fails the gate. |
| **FR-P08** | Deploy verification through the control plane (image == cnf ref, Ready, latest revision ready). (Written when 031's allowlist kept runners off `/healthz`; 031 is gone, `70b84824`, and the HTTPS smoke FR-P12 now also runs.) | **Implemented** — executed in every deploy job since `77e071fb`; run `36170413419` both envs `success`. |
| **FR-P09** | A deployed-state check an operator (or agent) can run: cnf `hub.image.ref` vs the live service image, per env, reporting `current` or `lagging`. | **Implemented** — `ENV=<env> GCP_ACCOUNT=$GCP_ACCOUNT ./csi-spl-orc/run -a do_check_hub_deploy`, read-only (describe only), exit 0 current / 3 lagging / 4 unhealthy / 1 cannot tell; tests `csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh` (9 assertions). Live 2026-09-18T19:21Z (n=1): dev → `dev current … spool-hub:0.1.0`, rc 0; prd → rc 1 (no service yet). **Second half (CLE-3424, 2026-09-20)**: image-vs-cnf is green while cnf still names the old tag, so `ENV=<env> SHA=<sha> ./csi-spl-orc/run -a do_check_deploy_lag` answers commit-vs-trunk instead — hub `/version` and WUI `build.json`, per env, exit 0 current/pending / 3 lagging / 1 cannot tell; tests `check-deploy-lag.tst.sh` (21 assertions); wired as the `lag` job of `00_deploy-lag-watch.yml`. Evidence that the first half could not see it: 8 consecutive green `00` runs 35463951071..35484293822 while both envs served `af8c6db` and trunk carried `f2c024a` + `a228c92`; first `lag` run 35486669128 red on both envs.**Third half (CLE-3355, 2026-09-21)**: both checks above DESCRIBE; neither stops a bad apply. The tf-runner renders tfvars from the tree it mounts, so a stale checkout makes 030 propose `~ image = <live> -> <older>` — on 2026-09-21 `/opt/csi/csi-spl` sat on an unpushed doc commit, 18 behind trunk, and both plans proposed `0.1.17 -> 0.1.16` (ORC freeze 08:0xZ, clear 08:05Z). `do_check_hub_image_regress` is the PRE-APPLY precondition, wired into `make do-provision` for `STEP=030-cloud-run-hub` only: exit 0 `current`/`forward`, 3 `regress`/`diverged`, 1 cannot tell; `ALLOW_IMAGE_REGRESS=1` permits a deliberate rollback and still prints the verdict; tests `check-hub-image-regress.tst.sh` (11 assertions) plus an end-to-end control (planted `0.1.16` against live `0.1.17` → `REFUSED` + `make: Error 1` before any `docker exec`). It is a SEPARATE action rather than a reuse of `do_check_hub_deploy` on purpose: that one compares with `!=`, which is direction-blind, and cnf NEWER than live is the documented roll path (a tag bump applied through 030 instead of the 20 pipeline) — reusing it would refuse a legitimate roll. Trunk `6db0738`. |
| **FR-P10** | Names (project, region, image ref, service) come from cnf through `do_spl_cloud_cnf`, never from the workflow file. | **Implemented** — `grep -cE 'csi-spl-(dev\|prd)\b' .github/workflows/20_hub-build-deploy.yml` → 0. |
| **FR-P11** | The gate also proves the WUI: `csi-spl-wui` unit tests and `nuxt typecheck`, with a frozen pnpm lockfile, plus browser e2e against a generated mock-tenant bundle. | **Implemented** — unit+typecheck `18a19dc` (run `35386487700`). Browser e2e in CI: 016 T021 `wui-e2e` (`05aaaa7`); viewport guard `4153561` (GRK-3381). Check: `command grep -c wui-e2e .github/workflows/10_ci-quality.yml` → 6. |
| **FR-P12** | Post-deploy smoke (`22_deploy-verify.yml`): per env, `GET https://<fqdn>/` → 200 and `GET https://[<sub>.]api.<BASE_DOMAIN>/version` → 200 + `{version, commit, built_at}`. Not reachable yet = warning; wrong answer = red (`contracts/pipeline.md` §2.6). | **Implemented** — `0d2155d` (script + job), called from 20 since `6d1643e`. Run `35390460157` (sha `869e6d9`), from a GitHub runner, attempt 1, all **200**: `https://spool-hub.ai/`, `https://api.spool-hub.ai/version` → `{"version":"0.1.0-dev","commit":"c972f24…","built_at":"2026-09-18T20:00:01Z"}`, `https://dev.spool-hub.ai/`, `https://dev.api.spool-hub.ai/version` (same shape). |

| **FR-P13** | The quality gate also runs the iac, orc and cnf bash suites and a `gate-health` job (added after the redo; 016 owns the gate-health design). The deploy-lag watch (`00_deploy-lag-watch.yml`) and `do_report_ci_gate` (per-JOB red summary) read the pipeline's state. | **Implemented** — `grep -E '^  [a-z0-9-]+:$' .github/workflows/10_ci-quality.yml` → 9 jobs; `csi-spl-iac/src/bash/run/report-ci-gate.func.sh` present. `99_runner-smoke.yml` (runner smoke, dispatch) is listed here for coverage; no FR asserts on it. |

### Live estate the pipeline lands on — HISTORICAL (measured 2026-09-18 ~19:00Z, n=1; superseded: 031 is removed, `70b84824`, and both envs are deployed by the pipeline, FR-P05)

Cited from 007 / README §6; measured here for the pipeline's preconditions.

| Env | Registry (028) | Cloud Run hub (030) | WIF pool (017) | deploy SA `csi-spl-deploy-<env>` (017) | Pipeline outcome today |
|---|---|---|---|---|---|
| dev | `csi-spl-dev-hub` | `csi-spl-hub-dev` Ready, `spool-hub:0.1.0` | none | not created (017 not applied) | skipped (no vars) |
| prd | API `SERVICE_DISABLED` | API `SERVICE_DISABLED` | none | not created (017 not applied) | skipped; with vars would fail fast "apply 028 / 030 first" — correct |

The earlier gap (017's first draft defaulted to an SA that exists in neither
project and granted no roles) is closed on trunk: `2a7888c` creates
`csi-spl-deploy-<env>` with `artifactregistry.writer` on the 028 repo,
`run.developer` on the 030 service, `iam.serviceAccountUser` on the hub runtime
SA and the WIF `workloadIdentityUser` binding (T103, T104). What is left is the
owner-gated apply (007 T050), then T105–T109.

## Requirements — US1 CI logs in chat (later)

- **FR-001**: Cloud Run image contains `gh` **after M3**. M1 image MUST NOT
  include `gh` (distroless static binary only).
- **FR-002**: Token from Secret Manager, per tenant, optional.
- **FR-003**: Repo allowlist per tenant (cnf).
- **FR-004**: Delivery is `v:1` `note` + file on the existing bus.
- **FR-005**: No token in git, image layers, chat, or application logs.
- **FR-006**: M1 stub is hub-side fetch+deliver (`internal/cicdlogs`),
  **flagged off by default**. Fail-closed in `prd` if the feature is enabled
  and the GitHub token secret is missing or a placeholder. Empty allowlist
  allows no repos (not an open proxy). Prefer a file attachment; cap one log
  at 32 MiB and say so in the body when truncated.

**Status**: FR-001 **Implemented** for M1 (`grep -c 'gh' csi-spl-orc/src/docker/spool-hub-api/Dockerfile` → 0). FR-002..006 **Implemented as the M1 flagged-off stub** (`internal/cicdlogs`, `POST /v1/cicd-logs` only when `SPOOL_HUB_CICD_LOGS_ENABLED=true`; code default `false` (`internal/config/config.go:244`); the key is still not in cnf — `git grep -c CICD_LOGS -- csi-spl-cnf` → 0 on 2026-09-25 although 030 has been re-rendered many times since — task T002): landed from GRK-3354's `c9ed24e` onto trunk by the 008 lane, with the hub suite green. **Not live anywhere**: the flag is off in every env, and the Secret Manager slot (T012) and `gh` in the image (T011) stay later.

## Out of Scope

- **US2**: `terraform apply` from CI (owner-gated; never automated); the WIF
  pool, provider, deploy SA and its IAM (007, tf `017`); the WUI deploy
  (Firebase `016`/`019`, M3 — 005; seam: `30_wui-build-deploy.yml` shares
  this spec's key-auth pattern and dev/prd matrix); the DB backup workflow
  `45_db-backup.yml` (029); the retired `40_tenant-host-reconcile.yml` (024);
  pull-request builds; per-sha tags.
- **US1**: M1 image need not include `gh`. M2 checkout. Store logic. WUI.
  Baking tokens. Box-side `gh` / tokens on a box.

## Open owner questions (sync 2026-09-25)

1. **FR-P04**: key-first auth is what runs. Keep WIF (017) as the alternative,
   or retire it?
2. **T002**: publish `SPOOL_HUB_CICD_LOGS_ENABLED: "false"` in cnf (a no-op
   value, but it re-renders 030 tfvars and so needs an owner-gated 030 apply to
   leave no drift), or accept the code default and close T002?
3. **T111**: pin third-party actions by commit sha — yes or no? (Today by
   major tag: `grep -c '@v[0-9]' .github/workflows/*.yml` → 45 across 8 files.)

<!-- version: 0.3.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:30:11Z -->
