# Contract: the GitHub Actions pipeline (M1)

**Feature**: `008-spool-cicd-logs`, User Story 2 · **Spec**: ../spec.md ·
**Authority for**: pipeline jobs, gates and the deploy matrix
(`specs/README.md` §5). The WIF deploy identity is 007's (tf step `017`);
this contract only **consumes** the repo variables 017 exports.

Artifacts: `.github/workflows/10_ci-quality.yml`,
`.github/workflows/20_hub-build-deploy.yml`, both landed in `3596991`
(`git log --format=%h -- .github/workflows -> 3596991`).

## 1. Triggers

| Workflow | `push` | `workflow_dispatch` | `pull_request` |
|---|---|---|---|
| `10 ci: quality gate` | `master`, **no `paths:` filter** | yes, no inputs | **none** (trunk-based) |
| `20 ci-cd: spool hub build + deploy` | `master`, `paths:` allow-list (1.1) | `environment` = `dev` \| `prd` \| `all` (default `dev`) | **none** |

### 1.1 The deploy allow-list

`csi-spl-api/**`, `csi-spl-rdb/**`, `csi-spl-cnf/**`, `csi-spl-iac/**`,
`csi-spl-orc/**`, `.github/workflows/20_hub-build-deploy.yml`, `.version`.
One entry per tree the build, the test suite or the cnf resolve step reads.
`paths-ignore` is never added beside `paths` (GitHub rejects the file). A new
build input is a new entry here, in the same commit.

The quality gate deliberately has no filter: a wrong allow-list fails
silently (no run, green checks), and the suites are cheap.

## 2. Jobs

### 2.1 `10 ci: quality gate` — hermetic, no GCP identity (network: Go proxy, npm registry, one emulator image)

| Job | Runs | Pass condition |
|---|---|---|
| `hub-suite` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (gofmt, vet, test, smoke, Postgres gate, fake-gcs gate) | exit 0 **and** no `^skip - no (Postgres server binaries\|cached )` line in the log — a skipped gate is a failure in CI |
| `wui-suite` | in `csi-spl-wui`: `pnpm install --frozen-lockfile`, `pnpm run test:unit`, `pnpm run typecheck` (pnpm version from `packageManager`) | all three exit 0; the browser e2e (`test:e2e`) is not run in CI |
| `no-ysg-box-ref` | `csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` | exit 0 |
| `distribution-hygiene` | 5 grep sweeps (org/bank, personal name, OS user/box/AD id, `/home/<user>/`, owner mail domain) | no hit; prints `file:line` only, never the matched value (a CI log is a distribution channel). A sweep that finds **nothing** is a pass, never an abort (see spec FR-P07). |

Permissions: `contents: read`. Network: the Go module proxy and one emulator
image pull (`fsouza/fake-gcs-server:1.52.2`).

### 2.2 `20 ci-cd: spool hub build + deploy`

```
test ──► prepare-deploy ──► deploy (matrix: envs from prepare-deploy, fail-fast: false)
```

| Job | Contract |
|---|---|
| `test` | Same suite as 2.1 `hub-suite`. A deploy never ships a red tree. |
| `prepare-deploy` | Wanted envs: a dispatch naming one env → that env, **unguarded**; a push or `all` → `dev` + `prd`, **guarded**. An env is **ready** only when both repo variables of §3 are non-empty; a not-ready env is **skipped with a `::notice::`**, not failed. Outputs `envs` (JSON list), `any`, `guard_event`. |
| `deploy` | Per env, in order: resolve cnf (2.3) → forward-only guard (2.4) → WIF auth → image-exists probe → build + push **only if absent** → roll the existing service → verify (2.5) → step summary. |

Permissions: `contents: read`, `id-token: write` (WIF only).

### 2.3 Names come from cnf, never from the workflow

The deploy job sources `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` and
calls `do_spl_cloud_cnf` — the same resolver the operator's cloud actions use
— and reads `SPL_IMAGE_REF`, `SPL_PROJECT`, `SPL_REGION` and
`env.hub.service_name`. An empty service name fails the job. The workflow
file carries no project id, region, image path or host.

### 2.4 Terraform owns the image — a deploy is a cnf tag bump

- `030-cloud-run-hub` runs `var.image` = cnf `env.hub.image.ref` =
  `<region>-docker.pkg.dev/<project>/<028 repo>/<hub.image.name>:<hub.image.tag>`.
  028 tags are **immutable**. To ship new hub code: bump `hub.image.tag` in
  `csi-spl-cnf/csi-spl/<env>.env.yaml`.
- The pipeline deploys **exactly** that reference: it builds + pushes it with
  `DRY_RUN=0 GCP_ACCOUNT=<deploy SA> ./csi-spl-orc/run -a do_build_push_hub_image`
  only when the registry does not hold it, then rolls the service to it.
  It **never** pushes a per-sha tag.
- A hub code change without a tag bump runs the tests, then deploys nothing
  and says so (`::notice::… already in the registry`).
- It **never creates, resizes or re-permissions** anything. A missing
  registry or service fails the run ("apply 028 / 030 first").
- **Forward-only guard** (guarded runs only): if `origin/master` has moved
  past `GITHUB_SHA` **and** trunk head resolves a different image ref, the
  older run stands down with a `::warning::`. A dispatch naming one env is an
  operator action and may roll back.
- **Serialisation**: `concurrency: deploy-hub-<env>-<ref>`,
  `cancel-in-progress: false` on the deploy job only — an in-flight rollout
  is never killed. No workflow-level concurrency.

### 2.5 Verification is through the control plane

The hub sits behind 031's IP-allowlisted load balancer (ingress
`internal-and-cloud-load-balancing`), so a runner cannot probe `/healthz`.
The job instead requires, from `gcloud run services describe`:
template image == the cnf ref, `Ready == True`, and
`latestCreatedRevisionName == latestReadyRevisionName`.

## 3. Inputs the pipeline consumes (owned by 007)

| Repo variable | Value (from 017 output) | Used by |
|---|---|---|
| `GCP_WIF_PROVIDER_DEV` / `_PRD` | `wif_provider_name` | `google-github-actions/auth@v2` `workload_identity_provider` |
| `GCP_DEPLOY_SA_EMAIL_DEV` / `_PRD` | `deploy_sa_email` | `auth@v2` `service_account`; `GCP_ACCOUNT` for the push |

Variables, not secrets: neither value is a credential. **No JSON key**
exists anywhere in the pipeline.

The deploy SA needs, per env (the grants are 007's to write):

| Grant | Why |
|---|---|
| `roles/iam.workloadIdentityUser` for the repo principalSet | WIF impersonation |
| `roles/artifactregistry.reader` + `.writer` on the 028 repo | image-exists probe, push |
| `roles/run.developer` on the 030 service | `services describe` / `update --image` |
| `roles/iam.serviceAccountUser` on the hub runtime SA | a revision runs as that SA |

GitHub environments `dev` / `prd` are referenced by the deploy job and carry
**no required reviewers**: dev and prd deploy on the same push without a
second approval (owner standing order).

## 4. Where the pipeline sits in the provisioning order

`specs/README.md` §6 is the order; the pipeline is **not a step of it**. It
takes over **after** step 9 (Cloud Run hub) exists and 017 is applied with
its outputs exported as repo variables. Step 7 (the first image) is the
operator's `do_build_push_hub_image`; every later tag bump is the pipeline's.
Before that, the deploy job is skipped (§3) or fails fast (2.4) — it never
provisions.

## 5. Out of contract

WUI deploy (Firebase, tf `016`/`019`, M3 — 005's), `terraform apply` of any
step (owner-gated, never from CI), per-sha tags, pull-request builds.

<!-- version: 1.0.1 · updated: 2026-09-18 · last-edit: 2026-09-18T19:33:50Z -->
