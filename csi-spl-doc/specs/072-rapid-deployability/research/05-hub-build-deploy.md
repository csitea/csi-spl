# 072 research 05: hub build, image, registry and Cloud Run deploy

Author: c-160. Tree: `origin/master` @ `474b940a`, 2026-10-04. Docs only.
Scope: how the hub (Go) is built, versioned, imaged, pushed and rolled onto
Cloud Run (workflow 20 and the actions it calls, `do_release_version`), what an
outsider needs to do the same, and every place it is bound to our registry,
project or env names. P2 of spec 072 section 3; A1 (images) touches P1 too.
Ranked by the spec's section 2 rule: time to first deploy, manual steps,
clarity of errors. Cost is given as a number only where it exists.

## 1. Today

### 1.1 The walk, one hub deploy (wf 20, push to trunk)

| # | stage | where | check |
|---|---|---|---|
| 1 | trigger: a hub input changed (Go module, `build.sh`, hub DDL, the cloud Dockerfile, the 3 cnf files) | `.github/workflows/20_hub-build-deploy.yml:47-59` | `sed -n 47,59p` |
| 2 | targets: `dev prd` fixed; an env deploys when secret `GCP_KEY_CSI_SPL_<ENV>` or vars `GCP_WIF_PROVIDER_<ENV>` + `GCP_DEPLOY_SA_EMAIL_<ENV>` exist, else it is skipped with a notice | wf 20:154-165 | `grep -n 'wanted=(dev prd)'` -> 154 |
| 3 | test: the hub suite on `ubuntu-latest` | wf 20 job `test`, line 121 | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` |
| 4 | prebuild beside the suite: predict the version (`do_release_version` dry run), build 4 candidate images, push them as `ci-<sha>-v<candidate>` | wf 20:199-340 | commit `73706a65` message |
| 5 | deploy (per env, serialised per env): read names from cnf (`do_spl_cloud_cnf`), forward-only guard, **mint** the version, promote or build + push the image, migrate the DB, roll Cloud Run, verify, ingest release notes | wf 20:349-706 | `grep -n 'do_' wf 20` |
| 6 | mint: the commit's own `v<X.Y.Z>` tag, else one odometer step past the highest remote v-tag, claimed by pushing the tag (the remote is the lock) | `csi-spl-orc/lib/bash/funcs/spl-release-version.func.sh:172-192` | `release-version.tst.sh` |
| 7 | build: `build.sh` compiles a static `spool` **on the host** (Go, `GOPROXY=off`, module cache pre-filled), copies it and the DDL into a context, `docker build` of a distroless image | `csi-spl-orc/src/bash/run/build-push-hub-image.func.sh:42-52`; `csi-spl-api/src/bash/build.sh:6` | |
| 8 | push: to Artifact Registry `<region>-docker.pkg.dev/<project>/<repo>/spool-hub:<version>`, tags immutable, throwaway `DOCKER_CONFIG` | same file, lines 63-72; ref built in `csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh:44-46` | |
| 9 | migrate: `do_spl_db_bootstrap` (idempotent) before the roll | wf 20:591-607 | |
| 10 | roll: `gcloud run services update --image` **inline in the workflow**, refuses when 030 has not created the service | wf 20:621-631 | `grep -rln 'run services update' csi-spl-orc/src csi-spl-iac/src .github/workflows` -> wf 20 only |
| 11 | verify: `do_check_hub_deploy` (template image = minted ref, Ready) | wf 20:639-650 | |

Terraform owns the registry (step 028) and the service (030); 030 sets the
image at create time and then ignores it
(`030-cloud-run-hub/04-cloud-run-service.tf:150-153`, `ignore_changes`), so an
apply never rolls the hub back.

### 1.2 Measured

| measure | value | check |
|---|---|---|
| wf 20, created -> done, successful trunk runs | **median 469 s**, min 318 s, max 502 s (n=20, 2026-10-03..04, newest `3703c480`) | `gh run list --workflow 20_hub-build-deploy.yml --branch master --status success --limit 20 --json createdAt,updatedAt` |
| version tags on the remote | 728, highest **v8.4.0** | `git ls-remote --tags origin 'v*' \| wc -l`; `... \| sort -V \| tail -1` |
| versions minted per day | 106, 55, 118, 154, 154, 130 (2026-09-28..10-03, n=6 days) | `git for-each-ref 'refs/tags/v*' --format='%(creatordate:short)' \| grep -c <day>` |
| odometer steps left before `9.9.9` | **159**, about 1.2 days at 130/day | `spl_version_step` rc 1 at 9.9.9 (`spl-release-version.func.sh:27`), mint FATAL at line 192 |
| hub Dockerfiles | **2**: compose `csi-spl-api/src/docker/hub.Dockerfile` (multi-stage, alpine, entrypoint, builds in Docker) and cloud `csi-spl-orc/src/docker/spool-hub-api/Dockerfile` (distroless, needs a host-built binary) | `grep -cE '^FROM' <both>` -> 2, 1 |
| host tools for a cloud build | docker, yq, git, gcloud, a Go toolchain with a filled module cache | `build-push-hub-image.func.sh:27,33`; `build.sh:6` `GOPROXY=off` |

### 1.3 Where the path is bound to our estate

| # | binding | file:line | an outsider must |
|---|---|---|---|
| B1 | project id must equal `<org>-<app>-<env>`, else refused. GCP project ids are global, so `csi-spl-dev` / `csi-spl-prd` are ours and unavailable to anyone else | `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:111` | rename the 9 top dirs to a new `<org>-<app>` (the orc dir is parsed at line 28) |
| B2 | the registry repository id must match `^csi-spl-(dev\|prd)-hub$` | `csi-spl-iac/src/terraform/028-gcp-artifact-registry/02-variables.tf:37` | edit terraform (also listed in spec 4.3 #4) |
| B3 | env names `dev` / `prd` only: the matrix, the secret lookup, the cnf resolver | wf 20:154, 372-373, 515, 521; `spl-cloud-cnf.func.sh:21`; 028/030/017/120 `02-variables.tf:16` | edit the workflow, the resolver and 4 terraform steps |
| B4 | the GitHub secret is spelled `GCP_KEY_CSI_SPL_<ENV>` in the workflow (12 refs) while step 120 writes `GCP_KEY_<ORG>_<APP>_<ENV>` | `grep -c CSI_SPL wf 20` -> 12; `120-github-general-secrets/03-github-actions-secrets.tf:20` | after B1's rename, edit 12 lines or every env is skipped with a notice (silent: the run is green) |
| B5 | the registry is Artifact Registry in the env's own project; nothing else can be named | `spl-merged-cnf.func.sh:44-46` | create 028 even when an image already exists elsewhere |
| B6 | `.version` floor 1.1.3 vs 728 tags: a fork inherits our tags, so its first mint is ours + 1 | `cat .version` -> 1.1.3 | nothing, but its numbers mean nothing to it |

Not a binding: the region (`europe-north1`) is a cnf value with a default in
030 `02-variables.tf:28`; the service name and image name are cnf
(`hub.service_name`, `hub.image.name`).

### 1.4 Stale text an outsider will follow

The mint (owner rule 2026-09-27) replaced "bump the tag and apply", but these
still teach the old way:
`csi-spl-cnf/csi-spl/dev.env.yaml:176-178` and `prd.env.yaml:183-185`
("to deploy, bump hub.image.tag, re-render, do_build_push_hub_image, plan +
apply"); `030-cloud-run-hub/02-variables.tf:44` ("a deploy is a new tag +
apply"); `build-push-hub-image.func.sh:15-16` ("a new build means a new
hub.image.tag ... then 030 plan + apply") and its last line (`next: ...
do_tf_plan`).

## 2. Blockers

1. **The odometer is about a day from full.** At 9.9.9 every hub and WUI
   deploy fails at the mint (`spl-release-version.func.sh:192`). Measured
   above: 159 steps left, ~130 mints a day. Reported to c-001 on task
   `6410e374` (msg `1af8a098`). Not ours to fix; an owner decision (Q1).
2. **No outsider can pass B1**: the project-id convention plus global project
   ids force a rename of the whole tree, and the rename then breaks B4.
3. **Two hub images.** Compose ships the alpine image with the entrypoint
   (owner seating, default-password refusal); Cloud Run ships a distroless
   one built from a host binary. A1's published image would be the compose
   one, so the GCP path cannot use it, and a P2 deploy needs a Go toolchain.
4. **The roll is not an action.** Build, migrate, roll and verify exist only
   as wf 20 steps (roll inline at wf 20:631); without GitHub Actions there is
   no named command that deploys the hub (repo rule "nothing ad hoc").
5. **B4 fails silently**: a wrong secret name makes `prepare-deploy` skip the
   env with a `::notice::` and the run is green with nothing deployed
   (wf 20:164).
6. The CI installs `yq` from `releases/latest`, unpinned (wf 20:599): a new
   yq release can change a deploy with no commit.

## 3. Actions

Effort as spec 072 section 6 (XS < 0.5 day, S <= 1 day, M 2-5 days).
Each names the A or G id it changes; H-numbers are new.

| # | action | changes | owner | effort | done when (a test can check) |
|---|---|---|---|---|---|
| **H1** | Odometer past 9.9.9: per Q1, allow 1-2 digit parts (`9.9.9 -> 10.0.0`) and/or mint only when the deployed image would change | new (deploy is down otherwise) | orc | XS-S | `release-version.tst.sh` has a case `9.9.9 -> 10.0.0`; `hub-version-digits.tst.sh` accepts it; a WUI-only commit does not change the hub version if Q1 says so |
| **H2** | One hub image: `do_build_push_hub_image` builds `csi-spl-api/src/docker/hub.Dockerfile` with `SPOOL_VERSION=<minted>` (no host Go); the cloud Dockerfile goes | A1 prerequisite, G1 | api + orc | S-M | `ls csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> absent; `check-hub-deploy.tst.sh` green; dev `/version` = the minted tag after one wf 20 run |
| **H3** | `do_hub_deploy ENV=<env>`: mint (or `SPL_HUB_IMAGE_TAG`), build/promote + push, `do_spl_db_bootstrap`, roll, `do_check_hub_deploy`, dry run by default; wf 20's deploy job calls it | G11, A9 (its last step) | orc | S | `grep -c 'run services update' .github/workflows/20_*.yml` -> 0; `ENV=dev ./run -a do_hub_deploy` (dry) prints the 5 steps and the image ref; a test with a stubbed gcloud |
| **H4** | Project id and repository id from cnf only: drop the `<org>-<app>-<env>` refusal (keep a warning) and the 028 `^csi-spl-` regex | A8, G9 | iac + orc | S | `grep -nF 'the convention says' csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` -> 0 FATAL; `grep -rnF 'regex("^csi-spl' csi-spl-iac/src/terraform/028*` -> 0; `ENV=dev do_spl_cloud_cnf` with `gcp_project: acme-x-dev` in a test cnf passes |
| **H5** | Envs and secret names from cnf: wf 20's matrix comes from the cnf env list; the auth secret is `GCP_KEY_<ENV>` (or read from cnf), matching step 120 | A17, G12, B3, B4 | CI + iac | S | `grep -cE "CSI_SPL\|wanted=\(dev prd\)\|'DEV' \|\| 'PRD'" .github/workflows/20_*.yml` -> 0; an env with no auth still skips, and `prepare-deploy` **fails** (not notices) when a cnf env has neither |
| **H6** | Registry as cnf: `hub.image.registry` names any registry; with a published image (A1) a P2 estate pulls it through an Artifact Registry remote repository and builds nothing | A1, A9, G1 | iac + CI | M | a cnf with `registry: <remote repo>` renders a `hub.image.ref` on it; 030 plan in a throwaway project runs the published image; I believe, unchecked, that Cloud Run cannot pull a GHCR image directly, hence the remote repository |
| **H7** | Fix the stale text of 1.4 to the mint flow | A15 | docs + cnf | XS | `grep -rn 'bump hub.image.tag' csi-spl-cnf csi-spl-iac/src/terraform/030* csi-spl-orc/src/bash/run/build-push-hub-image.func.sh` -> 0 |
| **H8** | Pin `yq` in wf 20 (a version and its sha256) | G14 sibling | CI | XS | `grep -c 'releases/latest' .github/workflows/20_*.yml` -> 0 |

Order: H1 now (the deploys stop otherwise), then H2 and H3 (they make A1 and
A9 possible), then H4/H5 (with A8), H6 (with A1), H7/H8 any time.

Cost, as numbers: the build runs on GitHub-hosted runners (free for a public
repo); Artifact Registry storage is per GB a month, and 028's cleanup policy
(`03-docker-repository.tf:23`) bounds it. Neither changes the ranking.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | The odometer hits 9.9.9 in about a day. Allow two-digit parts (`10.0.0`), and/or mint a version only when a deploy changes the hub or WUI image? | **Both**: two-digit parts now (one-line rule change, H1); minting only on a real change keeps the numbers meaningful for outsiders |
| Q2 | Drop the `<org>-<app>-<env>` project-id rule so a fork can deploy without renaming the tree (H4)? | **Yes**: GCP project ids are global, so the rule makes P2 impossible for anyone but us |
| Q3 | One hub image for compose, Cloud Run and the published release (H2)? | **Yes**: one Dockerfile, built in Docker, no Go on the deploying machine |
| Q4 | For an outsider, document WIF (step 017) as the default deploy auth and the project-SA key as the alternative? Our estate keeps the key (owner rule 2026-09-19) | **Yes for outsiders**: WIF has no key to export or rotate, so one fewer manual step and no secret to leak |
