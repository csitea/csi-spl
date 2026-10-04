# 072 research 17: local all-in-one, the no-GCP self-host mode

Author: c-166. Tree: `origin/master` @ `79a10ef4`, 2026-10-04. Docs only.
Scope: can the whole spool run with no GCP account, on docker compose or one
VM; which GCP services are hard dependencies (Cloud Run, the GCS relay,
Firebase, Secret Manager, Cloud SQL, ...) and what replaces each. This is P1
of spec 072 section 3, and the evidence for the section 3.1 claim that the
hub is cloud-neutral. Ranked by the section 2 rule (time to first deploy,
manual steps, clarity of errors); cost as numbers only.

**Verdict: feasible today, and already shipped.** `docker-compose.yml` runs
Postgres + hub + WUI with no cloud account, and CI proves it on every trunk
push. No GCP service is a hard dependency of the hub. What is missing is not
a substitute for GCP but the last mile: a feature pass-through, a non-GCP
remote file store for more than one node, one hub image, and backups.

## 1. Today

### 1.1 What the hub actually imports from GCP

| check (run on `79a10ef4`, n=1 each) | result |
|---|---|
| `git grep -l '"cloud.google.com' -- '*.go' \| grep -v _test` | **1 file**: `csi-spl-api/src/go/spool-hub-api/internal/blob/blob.go` (the GCS file store) |
| `git grep -il secretmanager -- '*.go' \| wc -l` | **0**: no Secret Manager SDK; secrets arrive as env vars |
| `git grep -l storage.googleapis -- '*.go' \| grep -v _test` | 0 |
| `git grep -liE 'SignedURL\|signed_url' -- '*.go' \| grep -v _test` | 0: the hub signs no GCS URLs |
| `grep -c firebase csi-spl-wui/package.json` | **0**: no Firebase SDK in the WUI; Firebase is hosting only |
| `git grep -lE 'google_cloud_scheduler\|google_pubsub\|google_cloud_tasks\|google_cloudfunctions' -- csi-spl-iac/src/terraform` | 0: no queue, scheduler or function service |
| `git grep -lE 'K_SERVICE\|K_REVISION' -- '*.go' \| grep -v _test` | 3 files, all optional: `cmd/spool/hub.go:214` `os.Getenv("K_REVISION") // Cloud Run sets it; "" = a per-process id` |

The blob store is a choice, not a dependency: `cmd/spool/hub.go:226-232`
`openBlobStore`: `FilesBucket == ""` -> `blob.Dir{Root: hc.FilesDir}`, else
GCS; `internal/config/config.go:471-472` demands exactly one of
`SPOOL_HUB_FILES_BUCKET` / `SPOOL_HUB_FILES_DIR`. Both backends pass one
shared contract (`blob_test.go:30-38`, `testStore` + `testUploaded`).

### 1.2 Every GCP service of the hosted estate, and its local substitute

From `ls csi-spl-iac/src/terraform` (18 steps) and the hub config.

| GCP service (step) | role | hard dep? | substitute in compose today | check |
|---|---|---|---|---|
| Cloud Run (030) | runs `spool serve` | no | the `hub` container, same Go binary | `docker-compose.yml:78-134` |
| Cloud SQL (040) | Postgres 16 via the `/cloudsql` socket | no: a plain DSN | `postgres:16-alpine` + `pg-init.sh` | `docker-compose.yml:26-46`; 030 `02-variables.tf:133-135` |
| GCS files (050) | uploads | no | `blob.Dir` on volume `hub-files` | `docker-compose.yml` `SPOOL_HUB_FILES_DIR` |
| Secret Manager (030 `secret_key_ref`) | 13 secret env vars (DB DSN, session key, SMTP, 5 social IdPs, 3 payment, WUI key, release-note bans) | no: plain env | `.env` values interpolated into compose (only DSN, SMTP, DB passwords wired) | 030 `04-cloud-run-service.tf:96-106`; cnf `*.secret_env` keys of `prd.env.json` -> 13 names |
| Firebase Hosting (016, 019) | serves the generated WUI, headers, i18n root | no | Caddy in `web`: `/srv` + a same-origin proxy of `/v1/* /api/* /healthz /version` to the hub | `csi-spl-wui/src/docker/Caddyfile` |
| Cloud DNS, domain mapping, certs (005, 025, 032) | names and TLS | no | Caddy ACME when `SPOOL_SITE_ADDRESS` is a domain | `docker-compose.yml:147` |
| Artifact Registry (028) | hub image | no | local `build:`; no published image (spec F1, A1) | `grep -nE '^\s+build:' docker-compose.yml` -> 49, 79, 137 |
| GCS DB backups (045, 046) | dumps, off-project copy | no | README `pg_dump` one-liner, by hand | README "Backup, restore and upgrade" |
| GCS relay bucket (020) | git-rel's signed-URL relay | **not used by the hub** | none needed; git-rel owns that contract | `git grep -l relay_bucket -- ':!*.md'` -> cnf, tfvars, 2 iac audit/backup actions; 0 `.go` |
| WIF + GitHub secrets (017, 120) | CI deploy identity | no | nothing: compose has no CI deploy | - |
| Satellite VM + budget (059, 060) | our second box | no | out of scope (spec A12) | - |
| Cloud Monitoring | - | no | `cloud.google.com/go/monitoring` is `// indirect` (pulled by the storage SDK) | `grep monitoring csi-spl-api/src/go/spool-hub-api/go.mod` |

### 1.3 Measured

| measure | value | check |
|---|---|---|
| CI proof of the compose path, trunk | **20 of 20 green**, 2026-10-03 19:23 .. 10-04 01:26 UTC, ~2.5-3 min each (build, up, browser proof on `ubuntu-latest`) | `gh run list --workflow 50_oss-standalone.yml --branch master --limit 20 --json conclusion,createdAt,updatedAt` |
| first human message from a clone | 6 min 26 s, 241 s of it the build (047 1.1, tree `4dc8df91`, n=1, a loaded box: an upper bound) | 047 `deployability-analysis.md` 1.1 |
| idle RAM, whole stack | ~110 MiB (hub 27.7, web 34.5, pg 47.2) (047 1.1, n=1) | `docker stats --no-stream` |
| image sizes | hub 79.5 MB, web 98.1 MB (047 1.1) | `docker image ls` |
| distinct `SPOOL_*` env names: cloud cnf vs compose | **116 vs 60; 95 cloud-only**, among them every social sign-in, payment, operator, quota, retention name and `SPOOL_HUB_WUI_KEY` | set diff of `SPOOL_*` keys in `csi-spl-cnf/csi-spl/prd.env.json` against `grep -oE '\bSPOOL_[A-Z0-9_]+:' docker-compose.yml \| sort -u` (-> 60) |
| pass-through for extra hub vars | **none** | `grep -c env_file docker-compose.yml` -> 0 |

Cost, one VM (an estimate, not measured): the stack idles at ~110 MiB, so a
1 vCPU / 2 GB VM serves a small team; that size lists at about USD 5-15 a
month at common VM providers, plus a domain. It changes none of the section 2
measures.

### 1.4 What the compose mode cannot do today

| # | gap | check |
|---|---|---|
| L1 | A hub feature the cloud turns on by env var is unreachable without editing `docker-compose.yml`: social sign-in (5 IdPs), payments, operator emails, quotas, retention, WUI dispatch | 1.3 "95 cloud-only"; `grep -c env_file docker-compose.yml` -> 0 |
| L2 | WUI-to-box dispatch (spec 014) is off: no `SPOOL_HUB_WUI_KEY`, and the ephemeral key is refused outside lde/dev | `internal/config/config.go:538`, `:545-546` |
| L3 | One node only: files live on a local volume; a second hub needs a shared filesystem, and the only remote store is GCS (no S3-compatible one) | `internal/blob/blob.go:249-261`; `cmd/spool/hub.go:228-232` |
| L4 | No scheduled or off-host backup action: Cloud SQL backups (045) and the off-project copy (046) have no compose counterpart | `ls csi-spl-orc/src/bash/run csi-spl-iac/src/bash/run \| grep -ciE 'self.?host'` -> 0 |
| L5 | Firebase's i18n root (`firebase-language-override` cookie at the edge) has no Caddy rule; `/` falls back to `/200.html` and the client picks the locale | `grep -c i18n csi-spl-wui/src/docker/Caddyfile` -> 0; `csi-spl-wui/src/utils/rootLocaleRedirect.mjs:4-30` |
| L6 | Two hub images: compose builds `csi-spl-api/src/docker/hub.Dockerfile` (alpine, `init`/`serve` entrypoint), Cloud Run ships the distroless one; an entrypoint fix in one does not reach the other (research 05, 1.2) | `grep -cE '^FROM' csi-spl-api/src/docker/hub.Dockerfile csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> 2, 1 |
| L7 | The server-side box runtime (desks, lease, crons; spec 071) accepts only `dev` or `prd`, not a self-hosted hub | `spl-box-deploy.func.sh` header `@param ENV - required: dev or prd` (spec F9) |

L1 to L7 are product gaps; none is a GCP dependency.

## 2. Blockers

None blocks the mode itself (1.3: 20/20 green). These keep it from being the
*same product* as the hosted estate:

1. **No feature pass-through (L1).** 95 settings the hosted hub uses have no
   route into the compose hub; a self-hoster who wants Google sign-in edits
   a tracked file and then merges it on every upgrade.
   `grep -c env_file docker-compose.yml` -> 0.
2. **No S3-compatible blob store (L3).** The only remote store is GCS
   (`internal/blob/blob.go:18` imports `cloud.google.com/go/storage`), so
   "no GCP" also means "one node". P2-on-AWS (spec 3.1) needs the same seam.
3. **No prebuilt images** (spec F1, A1): every self-host deploy compiles Go
   and Nuxt (241 s of 268 s, 047 1.1).
4. **Two hub Dockerfiles (L6)**: the compose path is a second product to keep
   green, guarded today by wf 50 alone.

## 3. Actions

Effort: XS < 0.5 day, S <= 1 day, M 2-5 days, L > 1 week, one lane each.
Each names the spec 072 id it serves, or is new (N17.x, section 6 shape).

| # | action | spec id | owner | effort | done-criterion a test checks |
|---|---|---|---|---|---|
| **N17.1** | Compose `hub` gets `env_file: [{path: .env.hub, required: false}]` plus a commented `.env.hub.example` listing every optional `SPOOL_HUB_*` the cloud cnf uses (IdPs, payments, operator, quotas, retention, WUI key) | new, G3 | orc | S | `grep -c env_file docker-compose.yml` >= 1; a wf 50 step writes `SPOOL_HUB_AUTH_PROVIDERS` into `.env.hub` and `GET /api/v1/auth/providers` lists it; with no `.env.hub` wf 50 stays green |
| **N17.2** | An S3-compatible blob store (`SPOOL_HUB_FILES_S3_*`: endpoint, bucket, region, path-style), chosen like GCS; config demands exactly one of dir / GCS / S3 | new, 3.1 seam | api | M | `TestS3` runs the shared `testStore` + `testUploaded` (`blob_test.go:30-38`) green against MinIO; an optional compose profile `s3` uploads and reads a file in wf 50; the config error names all three |
| **N17.3** | One hub image for both paths (the `init` / `serve` entrypoint kept; base chosen once) | new, A1 | api + CI | M | `grep -cE '^FROM' csi-spl-orc/src/docker/spool-hub-api/Dockerfile` -> file gone or the compose file points at it; wf 20 and wf 50 build the same Dockerfile path |
| **N17.4** | `do_spl_self_host_backup`: the README one-liner as an action, with a retention count and an optional off-host copy command, plus a cron line in the README | A6, G5 | orc | S | its test writes `db.dump`, `state.tgz`, `files.tgz` mode 0600; a restore test into a fresh compose project brings `/healthz` up with the same tenant |
| **N17.5** | Caddy i18n root: `/` with no locale path redirects by the same cookie then `Accept-Language` rule as Firebase | new, L5 | WUI | XS-S | in wf 50: `curl -sI -H 'Accept-Language: <non-default>' localhost:8080/` -> 302 to `/<code>`; with the cookie set -> its locale |
| **N17.6** | wf 50 also runs the own-domain profile (`SPOOL_HUB_ENV=prd`, Secure cookie, a throwaway SMTP sink container) | A16, G4 | CI | S | the job green with `SPOOL_PUBLIC_URL=https://<fqdn>`; its control (a default DB password) turns it red on a throwaway branch only |
| **N17.7** | `ENV=self` for `do_spl_box_deploy` / `do_spl_pool_ctl` against a compose hub | A17 | orc | S | spec A17's check |

### 3.1 Top three

| rank | action | why first (section 2) |
|---|---|---|
| 1 | **N17.1** feature pass-through | sign-in providers and the WUI key without editing a tracked file: fewer steps, painless upgrades |
| 2 | **N17.2** S3-compatible blobs | the hub's last GCP-only choice gets a neutral twin: multi-node self-host, and the AWS seam of spec 3.1 |
| 3 | **N17.3** one hub image | compose and hosted stop drifting; A1 publishes one image, not two |

Spec A1 (prebuilt images) and A2 (`spool-up` with preflight) already carry
time-to-first-deploy for this mode; not repeated here.

## 4. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Is compose on one VM a **supported production** mode or a trial mode? It decides whether N17.4 (backups) and N17.6 (prd profile in CI) are must-haves | **supported**: the fastest path to a first deploy, already 20/20 green; ranked first by section 2 |
| Q2 | Multi-node self-host: S3-compatible blobs (N17.2) now, or one node until a user asks? | **now**: it is the seam AWS needs anyway (3.1), not extra work |
| Q3 | Social sign-in and payments reachable in self-host (N17.1), or hosted-only? | **reachable**: usability over business value (msg `2144f3d9`); payments stay off by default |
| Q4 | A Kubernetes / Helm chart as a third shape? | **not in v1**: compose on one VM covers the stranger test; revisit after A16 |
