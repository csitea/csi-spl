# 072 research 06: WUI build and Firebase Hosting deploy

Status: **research, v1** for the 072 lead (c-165), who merges it into spec
sections 4-7. Section: the WUI build (`nuxt generate`) and its Firebase
Hosting deploy: terraform steps 016 and 019, workflow 30, the firebase.json
renderer, and what binds each of them to our estate. Tree: `origin/master` @
`474b940a8`, 2026-10-04. Every command below ran once on that tree (n = 1)
unless a row says otherwise. Docs only: nothing was built, applied or deployed.

`<org>`, `<app>`, `<env>`, `<fqdn>`, `<api_fqdn>` and `<site>` are
placeholders. Ranking follows spec section 2: time to first deploy, then
manual steps, then clarity of errors. Cost is given as numbers and ranks last.

## 1. Today

### 1.1 The walk, P2 (GCP estate): from an applied project to a served WUI

| # | step | who / where | check |
|---|---|---|---|
| 1 | Step **016** makes a Hosting deploy SA (`firebasehosting.admin`, `serviceUsageConsumer`, `run.viewer`), no key; `bind_github_wif` lets 017's pool impersonate it | terraform, owner go | `csi-spl-iac/src/terraform/016-firebase-deploy-iam/03-firebase-deploy-sa.tf:5-29` |
| 2 | Step **019** enables `firebase` + `firebasehosting`, adds Firebase to the GCP project (`google_firebase_project`), creates the Hosting site `site_id` with `prevent_destroy`, and optionally binds `<fqdn>` (+ redirect hosts) as custom domains | terraform, owner go | `019-firebase-static-site/03-firebase-site.tf:11-46`, `:48-101` |
| 3 | DNS records Firebase asks for: `do_provision_firebase_dns_env` (a copy of a sibling repo's action), then `do_spl_wait_for_firebase_domain` polls until `CERT_ACTIVE` | `./run` as the env SA | `ls csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run \| grep -ciE firebase` -> 3 |
| 4 | cnf turns the deploy on: `steps.019-firebase-static-site.wui_deploy: true` | hand edit + tpl-gen | `30_wui-build-deploy.yml:136` reads it |
| 5 | GitHub auth for CI: the secret `GCP_KEY_CSI_SPL_<ENV>` (step 120 publishes it) **or** the 2 repo vars `GCP_WIF_PROVIDER_<ENV>` + `GCP_FIREBASE_DEPLOY_SA_EMAIL_<ENV>` (by hand) | step 120 or `gh` | `30_wui-build-deploy.yml:119-125` |
| 6 | A push to master touching the WUI paths runs wf 30: unit tests + typecheck beside `nuxt generate` per env, mint `v<X.Y.Z>`, stamp `build.json`, render `firebase.json`, wait for the hub's `/version`, `firebase-tools@13 deploy --only hosting`, probe `<site>.web.app/build.json` | CI, `ubuntu-latest` | `30_wui-build-deploy.yml:169-475` |

There is **no local deploy action**: wf 30 is the only path from a tree to
Hosting. `git grep -c 'do_deploy_static_site()'` -> no match, although the
tf-runner image installs `firebase-tools@latest` "for csi-spl-orc deploy
actions" (`csi-spl-orc/src/docker/tf-runner/Dockerfile:121-127`). A third
party without GitHub Actions cannot ship the WUI at all.

### 1.2 Measured

| measure | value | check |
|---|---|---|
| wf 30 wall time, push to probed deploy (both envs) | median **120 s**, min 92, max 183; 60/60 success | `gh run list -w 30_wui-build-deploy.yml -L 60 --json conclusion,createdAt,updatedAt`, runs 2026-10-03T04:36Z..10-04T01:23Z, n = 60 |
| Firebase custom-domain certificate, first time | `CERT_PROPAGATING` for 60+ min while the edges already served it | `spl-wait-for-firebase-domain.func.sh` header, n = 3 (2026-09-26) |
| build-time inputs (`NUXT_PUBLIC_*`) wf 30 injects | **11** | `grep -oE 'NUXT_PUBLIC_[A-Z_]+' .github/workflows/30_wui-build-deploy.yml \| sort -u \| wc -l` -> 11 |
| cnf values the deploy job reads | 12 (project, site, fqdn, api_fqdn, tenant, auth_base, lb_route, default_locale, tenant_hosts, perf x2, `.version`) | `30_wui-build-deploy.yml:216-243` |
| one bundle per env | yes: "nuxt generate bakes NUXT_PUBLIC_* into the bundle, so dev and prd each build their own" | `30_wui-build-deploy.yml:15-16` |
| CSP script hashes depend on the env values | yes: the only inline script is `window.__NUXT__.config`; its bytes change with runtimeConfig | `render-wui-firebase-json.sh:56-63` |

### 1.3 How env values reach the bundle

`nuxt.config.ts:487-515` `runtimeConfig.public` reads `process.env` at
**generate** time; `nuxt generate` then freezes the values into the inline
`window.__NUXT__.config` of every prerendered page. Two further couplings:

- `nuxt.config.ts:91` reads `csi-spl-cnf/csi-spl/<env>.env.json` from disk
  during the build (the lobby task id), a path with our org and app in it.
- The P1 compose image does the same with Docker build args:
  `ARG SPOOL_PUBLIC_URL`, `SPOOL_TENANT`, `SPOOL_LOBBY_TASK_ID`,
  `SPOOL_DEFAULT_LOCALE` (`csi-spl-wui/src/docker/wui.Dockerfile:30-33`), then
  Caddy serves `/srv` (`:45-47`). Same mechanism, different carrier: both paths
  rebuild to change a URL (spec F2 / G2).

### 1.4 What binds it to us

| # | binding | check |
|---|---|---|
| T1 | Site id validation accepts only our two ids. Hosting site ids are **globally unique across all Firebase projects** and a deleted id can never be reused (019's own comment, `03-firebase-site.tf:40-42`), so nobody else can ever pass this validation | `019-firebase-static-site/02-variables.tf:41-44` `regex("^csi-spl-(dev\|prd)-site$")` |
| T2 | Env validation `dev` / `prd` in 016 and 019 | `016-.../02-variables.tf:15-18`, `019-.../02-variables.tf:15-18` |
| T3 | wf 30 hard-codes the secret name `GCP_KEY_CSI_SPL_<ENV>`, while step 120 writes `GCP_KEY_<ORG>_<APP>_<ENV>`: a fork with another org/app is SKIPPED with a notice, never deployed | `grep -c CSI_SPL .github/workflows/30_wui-build-deploy.yml` -> 8; `120-github-general-secrets/03-github-actions-secrets.tf:20` |
| T4 | wf 30 knows only two envs: `wanted=(dev prd)` and `matrix.environment == 'dev' && 'DEV' \|\| 'PRD'` (any third env silently takes PRD's secret) | `30_wui-build-deploy.yml:131`; `grep -cF "'DEV' \|\| 'PRD'" .github/workflows/30_wui-build-deploy.yml` -> 4 |
| T5 | The renderer and the DNS action refuse any env but dev/prd | `render-wui-firebase-json.sh:16`; `provision-firebase-dns-env.func.sh:23` |
| T6 | Our org/app in paths the build reads: cnf dir, wf 30 path filter, renderer `CNF=` | `nuxt.config.ts:91`; `30_wui-build-deploy.yml:37`; `render-wui-firebase-json.sh:19` |
| T7 | The hub's CORS list names the site's `.web.app` host: a new site id needs a hub cnf edit too | `grep -n VIEW_CORS_ORIGINS csi-spl-cnf/csi-spl/dev.env.yaml` -> line 275 |
| T8 | The deploy job needs the hub of the same estate (`/version` >= `.version`) and a Cloud Run service in the same project for the `run` rewrites | `30_wui-build-deploy.yml:419-425`; renderer `"run": {"serviceId": ..., "region": ...}` |
| T9 | The primary CI identity is the project SA, which "holds roles/owner"; the narrow 016 SA is only the fallback | `30_wui-build-deploy.yml:19-25` |
| T10 | Two firebase-tools versions: CI pins `@13`, tf-runner installs `@latest` | `30_wui-build-deploy.yml:433`; `tf-runner/Dockerfile:127` |

Not binding (checked): the committed `csi-spl-wui/firebase.json` has no site
key (`grep -c '"site"' csi-spl-wui/firebase.json` -> 0); the renderer writes
it from cnf. 016's `deploy_sa_account_id` uses a generic SA-id regex
(`016-.../02-variables.tf:36-39`). The CSP is computed, never written down.

### 1.5 Cost (ranked last, spec section 2)

047 puts Secret Manager + GCS + Firebase Hosting + logging at **~$1 / env /
month** (`deployability-analysis.md:278`). Hosting itself: I believe,
unchecked against the current price page, that a bundle of this size stays
inside the no-cost tier (10 GB stored, 360 MB/day served) and that the paid
rate is ~$0.026/GB stored and ~$0.15/GB served. wf 30 on `ubuntu-latest`:
~2 min per push, inside GitHub's free minutes for a public repo.

## 2. Blockers

1. **B1 the site id cannot be chosen by anyone else** (T1):
   `02-variables.tf:41-44`. A stranger's plan of 019 fails before anything is
   created. Hurts measure 1 (P2 impossible without a code edit).
2. **B2 CI never deploys a fork** (T3, T4): the secret name and the two-env
   ternary, `30_wui-build-deploy.yml:120-121,195,406,412-413`. The run is
   green with a `::notice::... skipped` line, so the failure is silent
   (measure 3).
3. **B3 no deploy outside GitHub Actions** (1.1, last paragraph): no `./run`
   action ships `.output/public` to Hosting; a GitLab or local user must
   reverse-engineer wf 30's deploy steps (measure 2).
4. **B4 one bundle per env, values baked at build** (1.3): a domain, tenant or
   locale change is a rebuild in P1 **and** P2, a release artefact cannot be
   shared between envs or estates, and the CSP hashes change with the values.
   Same root as spec G2 / A3, but A3 is scoped to compose only.
5. **B5 dev/prd-only envs** in 016, 019, the renderer and the DNS action (T2,
   T5). Spec G9's 14-file count includes 016 and 019; the two shell refusals
   are not in it.
6. **B6 the custom-domain certificate wait** (1.2): 10-60+ min of
   `PENDING` / `PROPAGATING` on the first bind is the longest single wait in
   the WUI path, and nothing tells the user it is normal unless they run
   `do_spl_wait_for_firebase_domain` by name.
7. **B7 the build reads our cnf path** (T6): `nuxt.config.ts:91` returns `""`
   when the path does not exist, so a renamed estate loses the lobby id with
   no error (measure 3).

## 3. Actions

Effort: XS < 0.5 d, S <= 1 d, M 2-5 d. Each names the spec gap it serves and
is one lane. Proposed ids `W1..W8`; the lead renumbers them into section 6.

| # | action | gap | effort | done when (a test can check) |
|---|---|---|---|---|
| **W1** | **Runtime WUI config for both carriers.** The bundle fetches `/config.json` (apiBase, authBase, tenant, siteUrl, tenantHosts, envName, defaultLocale, lobbyTaskId, perf) before the app mounts; `runtimeConfig` keeps build-time values only as lde defaults. Compose writes it from `.env` at container start (Caddy); wf 30 / W3 write it next to `build.json` per env. Widens A3 from compose to Hosting | G2, B4 | M | one `nuxt generate` with no `NUXT_PUBLIC_*` set, served twice with two `config.json`s, calls two different api hosts (unit + mock e2e); `grep -c NUXT_PUBLIC_API_BASE .github/workflows/30_wui-build-deploy.yml` -> 0 (today 2) |
| **W2** | **Site id from cnf, generic validation**: Hosting's own id rule (lowercase, digits, hyphens) plus a precondition message naming the global-uniqueness trap; cnf template default `<org>-<app>-<env>-site` | G9, B1 | XS | `grep -c 'csi-spl-(dev' csi-spl-iac/src/terraform/019-firebase-static-site/02-variables.tf` -> 0; `tf-steps-render-and-validate.tst.sh` validates 019 with a foreign id |
| **W3** | **`do_spl_wui_deploy ENV=<env>`**: one `./run` action = generate (or take a prebuilt bundle), write `config.json` + `build.json`, render firebase.json, `firebase deploy` as the env SA key in a throwaway config, probe. wf 30 calls it instead of inlining the steps | B3, G11 | S-M | `DRY_RUN=1 ENV=dev ./run -a do_spl_wui_deploy` prints the steps and the target site; a test stubs `firebase` and asserts the probe; wf 30's deploy job calls the action |
| **W4** | **wf 30 names its secret and envs from cnf**: the secret `GCP_KEY_<ORG>_<APP>_<ENV>` built with `format()` from the cnf org/app (as step 120 writes it); the env list from the cnf env files with `wui_deploy: true`; an env with `wui_deploy: true` and no auth **fails** instead of skipping | G9, G14, B2 | S | `grep -c CSI_SPL .github/workflows/30_wui-build-deploy.yml` -> 0 (today 8); `grep -cF "'DEV' \|\| 'PRD'"` on it -> 0 (today 4); a throwaway-branch dispatch with a third env plans it |
| **W5** | **One prebuilt WUI bundle per release**: after W1, `stable-*` / `v*` attach `wui-<ver>.tar.gz` (+ sha256) to the GitHub release; compose's web image (A1) and W3 both take it, so neither P1 nor P2 needs Node and pnpm | G1, A1 | S | `gh release view <tag> --json assets` lists the tarball; W3 with `WUI_BUNDLE=<url>` deploys without `pnpm install` |
| **W6** | **Env names free in the WUI path**: 016, 019, the renderer and `do_provision_firebase_dns_env` accept any env the cnf declares (A8's change, for these 4 files) | G9, B5 | XS-S | `grep -cF 'dev \|\| "$ENV" == prd' csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> 0 (today 1); same for the DNS action line 23 |
| **W7** | **The certificate wait, told up front**: W3 (and A9) print the expected wait (10-60 min, n = 3) when a custom domain is new, poll with `ACCEPT_PROPAGATING=1`, and point at `<site>.web.app` meanwhile | B6 | XS | the dry run on a new domain prints the wait line and the `.web.app` URL; a test greps both |
| **W8** | **No silent cnf read in the build**: the lobby id moves into W1's `config.json`; until then `cnfLobbyTaskId` takes the dir from `SPOOL_CNF_DIR` and a missing file is a build error when `envName` is set | B7 | XS | unit test: `envName=x`, no cnf file -> generate fails naming the path |

Not proposed: leaving Firebase for another static host. For P2, Firebase sits
in the same GCP project and IAM as the hub; after W1 + W3 the WUI is "a
directory plus a `config.json`", which any static host (P1's Caddy today)
serves, so the lock-in goes without a migration.

Order: W2, W4, W6 (XS-S; they unblock a fork's terraform and CI) -> W1 (the
root fix) -> W3 -> W5 -> W7, W8. **W1 and A3 should be one lane**, not two.

### 3.1 Top 3

1. **W1** a runtime `config.json` for compose and Hosting: one bundle, any
   domain, no rebuild (A3 widened).
2. **W2 + W4** a generic site id and a wf 30 that deploys a fork: the two
   edits that make P2's WUI possible at all (XS + S).
3. **W3** `do_spl_wui_deploy`: the WUI ships from any box, not only from
   GitHub Actions.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | May the deployed WUI read its api host and tenant from a served `config.json` (one extra ~1 KB request before mount) instead of baked values? | **Yes**: it removes a rebuild per domain for every deployer; the file is cached with the shell |
| Q2 | Should CI deploy the WUI as the narrow 016 Hosting SA (WIF) first, instead of the project SA that holds `roles/owner`? | **Yes, after W3**: a fork then needs only 016 + 017, and a leaked CI token can only touch Hosting. Not a blocker for 072 |
| Q3 | Keep Firebase Hosting as the P2 WUI host, given W1 + W3 make the host swappable? | **Yes**: same project, same IAM, ~$0 at this size; revisit only if the stranger test (A16) shows it as the slow step |
