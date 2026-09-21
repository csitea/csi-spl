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
| `22 ci-cd: spool hub deploy verify` | none — **called** by 20's `verify` job (`workflow_call`) | `environment` = `all` \| `dev` \| `prd` (default `all`) | **none** |
| `00 ops: spool hub deploy lag watch` | none — `schedule` hourly (`17 * * * *`) | `reconcile` = `auto` \| `never` | **none** |

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
| `iac-suite` | terraform 1.9.8, `./run -a do_setup_tpl_gen` (tpl-gen at `cnf/tpl-gen.ref`), then `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` without `SPL_TF_ALLOW_SKIP` (016 T003) | exit 0, no `^(SKIP\|PARTIAL):` line, `PASS: all tf-steps-render-and-validate` present, gcloud/gsutil/bq trap log empty |
| `orc-suite` | checkout at `csi/csi-spl` (orc derives ORG/APP from the parent dirs), Go modules, `postgres:16-alpine` pulled, then `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` (016 T004) | exit 0, no `^SKIP:` line, gcloud/gsutil/bq trap log empty |
| `cnf-suite` | Python 3.12, `poetry install --no-root` in conf-validator, then `bash csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` (016 T005) | exit 0 (the test exits 2 rather than skip) |
| `no-ysg-box-ref` | `csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` | exit 0 |
| `distribution-hygiene` | 5 grep sweeps (org/bank, personal name, OS user/box/AD id, `/home/<user>/`, owner mail domain) | no hit; prints `file:line` only, never the matched value (a CI log is a distribution channel). A sweep that finds **nothing** is a pass, never an abort (see spec FR-P07). |
| `gate-health` | `if: failure()` only: `cd csi-spl-iac && ./run -a do_report_ci_gate` (failures per JOB over the last 40 runs) into the job log and the run summary | **none — a report, not a gate.** `continue-on-error: true`, so it cannot redden a run, and correspondingly it proves nothing. Adds `actions: read` for this job alone. Verified by dispatching the workflow on a throwaway branch with one job forced to fail (CLE-3442); it cannot be proved by a green run, because a green run skips it. |

Permissions: `contents: read`, plus `actions: read` on `gate-health` alone. Network: the Go module proxy, the emulator
and Postgres image pulls, GitHub (tpl-gen), PyPI and registry.terraform.io
(providers for `init -backend=false`). No GCP identity in any job.

### 2.2 `20 ci-cd: spool hub build + deploy`

```
test ──► prepare-deploy ──► deploy (matrix: envs from prepare-deploy, fail-fast: false)
                                   └──► verify (uses 22; runs whatever deploy did, not after red tests)
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
The job instead runs `./csi-spl-orc/run -a do_check_hub_deploy` (FR-P09), the
same action operators and the lag watch use. It requires template image ==
the cnf ref, the **Ready condition (by type)** True, and
`latestCreatedRevisionName == latestReadyRevisionName`. "Unhealthy" (rc 4) is
asked again up to 6 times, 10 s apart, while a rollout settles. Before
`9a34a0a` this step was inline and read `status.conditions[0]` by position.

### 2.5.1 `00 ops: spool hub deploy lag watch` — hourly (csi-rel model)

Per env that has the WIF repo variables (others are skipped with a notice, as
in 20): authenticate over WIF and run `do_check_hub_deploy` at trunk head. The
run goes **red** on lagging (3), unhealthy (4) or cannot tell (1); a red
scheduled run is the notification. Only for **lagging** does it dispatch 20
with `environment=all`. "all" is forward-guarded, so a reconcile cannot roll
an env back. It does not dispatch when a 20 run for trunk head is already in
flight, or when 20's last verdict was a failure (the deploy is broken, not
starved). The unit is the cnf image **tag**, not the commit, because
terraform owns the image.

### 2.5.2 `00 ops` job `lag` — is trunk HEAD actually SERVED? (FR-P09, second half)

§2.5.1 compares the live image with the image **cnf names**, and that question
is green for as long as nobody bumps `env.hub.image.tag`. A lane lands hub
source, 20 runs the tests and (§2.4) "deploys nothing new", cnf still names the
old tag, the service still runs it — every gate green, trunk's code not live.
Measured on this workflow: **success on 8 consecutive runs**, `35463951071`
(2026-09-19T19:18Z) through `35484293822` (2026-09-20T02:33Z), while dev and prd
both served `af8c6db` and trunk `13e70d0` already carried hub source `f2c024a`
and `a228c92`. The 20 deploy job says it plainly in its own summary on
`031fa36`: `ROLLED: false`, `IMAGE_REF: …/spool-hub:0.1.16`.

So the `lag` job asks **commit vs trunk**, per env and per component, through
`ENV=<env> SHA=<sha> ./csi-spl-orc/run -a do_check_deploy_lag`, reading what
each env publishes about itself:

| component | probe | from |
|---|---|---|
| hub | `GET https://<env.dns.api_fqdn>/version` → `.commit` | 22's `/version` contract |
| wui | `GET https://<env.dns.fqdn>/build.json` → `.commit` | 30's `build.json` stamp |

A commit counts as lag **only when it changed an input of that component**, so
a docs-only or iac-only trunk head is never red:

- **hub** — what the image is built from, as `do_build_push_hub_image` itself
  defines it: the Go module, its `build.sh`, the DDL dir cnf names
  (`env.hub.image.sql_src`), the hub `Dockerfile`, `.version`. Not the api test
  scripts and not `spool-hub-roles/`: neither is copied into the image.
- **wui** — workflow 30's push allow-list, verbatim.

The two lists differ **on purpose**: 30 deploys on every path it triggers on,
20 does not. `GRACE_MINUTES` (repo variable `DEPLOY_LAG_GRACE_MINUTES`, default
45) is measured from the **oldest** unserved input commit, so a roll in flight
reads `pending`, not `lagging`.

Verdicts, worst wins: `0` current / pending, `3` lagging, `1` cannot tell. SOFT
vs HARD as in §2.6: **3 fails** the run; **1 warns** and stays green — an
endpoint that answers *wrong* is 22's job and an unready revision is §2.5.1's,
so nothing is lost. Nothing is auto-dispatched: a WUI lag would be a 30
dispatch, but a hub lag needs a cnf image-tag bump — a change to the repo, and
not a cron's to make.

The job needs **no GCP identity** (one HTTPS GET per component plus local git),
so unlike §2.5.1 it runs for both envs unconditionally. Its checkout is
`fetch-depth: 0`: the check walks history between the served commit and the one
under test, and on the default depth 1 every verdict reads "cannot tell".

First run in CI, dispatch `35486669128` on `0cf7e2b`: both `lag` jobs **failed**
with `dev|prd hub lagging served=af8c6db6 n=2 oldest=f2c024a7 age=535m
grace=45m`, while the §2.5.1 jobs on the same commit were green. Tests:
`csi-spl-orc/src/bash/tests/check-deploy-lag.tst.sh`, hermetic (a synthetic git
repo — this repo is checked out at depth 1 in CI — and `file://` fixtures), 21
assertions including the control that an artificial lag older than the grace is
red and the same lag inside the grace is not.

### 2.6 `22 ci-cd: spool hub deploy verify` — post-deploy HTTPS smoke

Called by 20's `verify` job (`workflow_call`), and dispatchable by hand. It
was first wired as `workflow_run` on 20's completion, but that did not fire
for two completed 20 runs, so the call is explicit now. It has no
concurrency group: with `cancel-in-progress`, the next push's verify cancelled
this one and marked the calling 20 run `cancelled` (run `35389176239`).
Modelled on csi-rel's `verify-api-health.sh`: the work is in
`csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh` (also run by hand:
`ENV_NAME=<env> bash csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh`), and the
workflow is a matrix (`dev`, `prd`, `fail-fast: false`) that calls it. No GCP
identity: every probe is anonymous HTTPS.

| Probe | URL (derived from cnf) | Pass |
|---|---|---|
| site | `https://<env.dns.fqdn>/` | 200, non-empty body |
| api | `https://[<env_subdomain>.]api.<BASE_DOMAIN>/version` | 200 + JSON `{version, commit, built_at}`, each a non-empty string |

The hosts come from cnf `env.dns.BASE_DOMAIN` + `env_subdomain`. That gives
`dev.spool-hub.ai`, `dev.api.spool-hub.ai`, `spool-hub.ai` and
`api.spool-hub.ai`, the owner's literal goal hosts: keep `dev.api.…`, never
switch it to `api.dev.…` (owner, 2026-09-18). Each probe gets 6 attempts,
10 s apart, and the last attempt decides:

| Verdict | When | Script exit | Job |
|---|---|---|---|
| ok | as the table above | 0 | green |
| pending (UNKNOWN) | not reachable **yet**: no DNS (curl 6), nothing on 443 (curl 7), TLS / managed cert not ACTIVE (curl 35, 51, 58, 60), LB allowlist 403 | 2 | green + `::warning::` |
| fail | reachable but wrong: 5xx, 404, a bad `/version` body, an empty `/`, a timeout | 1 | **red** |

A failure outranks a pending. The job summary lists every probe's verdict.

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

<!-- version: 1.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:17:52Z -->
