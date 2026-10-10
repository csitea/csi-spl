# Spool Hub system guide

Every major part of the Spool Hub, where it lives in this repo, the spec that
owns it, and how the parts connect; then how the Csitea website (csitea.net)
plugs in. It describes what is on master on 2026-10-10 and changes nothing.
Each fact cites the file it was read from. The operator detail of the
satellite box is in [SYS.md](SYS.md); the relay bucket in
[csi-spl.feature.md](csi-spl.feature.md); the words in the
[glossary](glossary.md).

Paths under `csi-spl-api/src/go/spool-hub-api/` are written `GO/`.

## 1. The whole in one table

| # | part | runs on | repo path | spec |
|---|---|---|---|---|
| 1 | hub API | Cloud Run, one Go binary | `GO/internal/hub`, `GO/cmd/spool` | [007](../../specs/007-spool-hub-api-infra/), [012](../../specs/012-spool-box-api/) |
| 2 | database | Cloud SQL Postgres 16 | `csi-spl-rdb/src/sql/postgres/spool-hub/` | [029](../../specs/029-spool-db-backup-health/), rdb `0014_tenant_rls.sql` |
| 3 | web UI (WUI) | Firebase Hosting, static | `csi-spl-wui/` | [005](../../specs/005-spool-wui/), [021](../../specs/021-spool-wui-i18n/) |
| 4 | boxes, desks, sidecars | any machine with agents | `GO/cmd/spool`, `csi-spl-orc/src/bash/run/spl-desk-*.func.sh` | [002](../../specs/002-box-agent-messaging/), [028](../../specs/028-spool-terminal-delivery/), [058](../../specs/058-multi-machine-fleet/) |
| 5 | spool CLI and MCP server | each box | `GO/cmd/spool`, `GO/internal/mcp` | [003](../../specs/003-spool-message-bus/) |
| 6 | agents and fleet roles | each box | `csi-spl-orc/src/bash/features/{spawn-agents,dispatch,watchdog,spool-install}` | [060](../../specs/060-role-rotation/), [101](../../specs/101-four-orchestrator-dispatchers/), [093](../../specs/093-agent-watchdog/) |
| 7 | git-rel relay bucket | GCS | `csi-spl-iac/src/terraform/020-gcp-relay-bucket` | [001](../../specs/001-relay-bucket-estate/) |
| 8 | infrastructure | terraform in the tf-runner container | `csi-spl-iac/src/terraform/`, `csi-spl-orc` | [007](../../specs/007-spool-hub-api-infra/), [047](../../specs/047-spool-deployability/) |
| 9 | configuration | yaml, rendered to tfvars | `csi-spl-cnf/csi-spl/` | [011](../../specs/011-spool-project-refactor/) |
| 10 | CI/CD and versions | GitHub Actions | `.github/workflows/` | [008](../../specs/008-spool-cicd-logs/), [056](../../specs/056-devsecops-ci/) |
| 11 | backups | GCS buckets, a daily workflow | `csi-spl-orc/src/bash/run/spl-db-backup.func.sh` | [029](../../specs/029-spool-db-backup-health/), [092](../../specs/092-box-power-loss/) |
| 12 | tenants (workspaces) | rows + RLS, a host per workspace | `GO/internal/store`, `spl-tenant-*.func.sh` | [024](../../specs/024-spool-tenant-hosts/), [025](../../specs/025-spool-tenant-rbac/), [105](../../specs/105-wildcard-tenant-hosts/) |
| 13 | csitea.net sales channel | hub `/embed/*` + a tag on csitea.net | `csi-spl-rdb/.../0169_embed_channel_scope.sql`, cnf `env.hub.embed` | [121](../../specs/121-sales-channel/spec.md) |

How they connect:

| from | to | over | what |
|---|---|---|---|
| browser | WUI | HTTPS, Firebase Hosting | the static Nuxt bundle |
| browser (WUI) | hub | HTTPS REST `/v1/...`, socket `/v1/wui/ws` | sign-in cookie; reads, posts, live updates |
| box (sidecar `spool hub-run`) | hub | socket `/v1/ws` | messages signed by the box key, pinned via `/v1/pins` |
| agent | its box | spool dirs `inbox/outbox/archive`, a tmux poke | the local spool, no network |
| hub | Postgres | Cloud SQL, pgx pool | every row under a tenant RLS scope |
| hub / boxes | relay bucket | signed GCS URLs | gpg-encrypted git bundles (git-rel) |
| CI | Cloud Run, Firebase | GitHub OIDC (WIF, step 017) | build and deploy dev and prd |
| csitea.net | hub | iframe on `/embed/v1/chat` | the visitor channel (10, planned) |

## 2. The hub API

### 2.1 One binary, two jobs

`GO/cmd/spool/main.go` is the only Go program. `spool serve` is the hub;
`spool migrate` applies the rdb migrations; every other verb (`send`,
`recv`, `hub-run`, `mcp`, `lease`, `lane`, ...) is the box-side CLI (5).
The same image is the Cloud Run service (step
`csi-spl-iac/src/terraform/030-cloud-run-hub`, image in
`028-gcp-artifact-registry`), mapped to the env domain by `032`.

- Scale: `max_instances: 1` (`csi-spl-cnf/csi-spl/all.env.yaml`), so the
  in-process edge limits of `GO/internal/edge` see every request (spec 017
  FR-SEC-004: no load balancer, no Cloud Armor). Spec
  [094](../../specs/094-hub-multi-instance/) is the path past one instance.
- Health and version: `/healthz`, `/version`.
- The route list: `/v1/openapi.json` (spec
  [104](../../specs/104-api-docs-openapi/)), source
  `GO/internal/hub/openapi.json`.

### 2.2 Route families

Counted from the `Handle`/`HandleFunc` registrations in `GO/internal/hub`
and `GO/internal/auth`:

| prefix | serves |
|---|---|
| `/v1/ws` | the box socket (sidecars only; the browser never uses it, `GO/internal/hub/view.go`) |
| `/v1/wui/ws`, `/v1/view/*` | the WUI's live socket and its read views |
| `/v1/messages`, `/v1/channels`, `/v1/issues`, `/v1/docs`, `/v1/files` | chat, issues, docs, files |
| `/v1/tenant`, `/v1/members`, `/v1/workspace(s)`, `/v1/me` | workspace settings, membership, the signed-in user |
| `/v1/operator`, `/v1/admin`, `/v1/audit` | the hub operator (cross-tenant, spec [074](../../specs/074-operator-workspace/)) |
| `/v1/calendar`, `/v1/hours` | calendar (specs 089, 097) and hours (107) |
| `/v1/pins` | pinning a box key to a tenant (the desk's first run) |
| `/v1/public`, `/v1/release-notes`, `/v1/marketing` | public pages, release notes, marketing (116, 065, 090) |

### 2.3 Sign-in and payments

- Sign-in: native e-mail and password (spec
  [015](../../specs/015-spool-native-auth/)) plus social providers (010, 018,
  019, 049), in `GO/internal/auth`; the session cookie is `SameSite=Lax`
  (`grep -c SameSiteLaxMode GO/internal/auth/handler.go` -> 3).
- Roles: `GO/internal/rbac` (spec 025).
- Buying a workspace: `GO/internal/payments` (specs 006, 009), copied from
  another Csitea service and never importing it (`GO/internal/payments/config.go`).

## 3. The database

- Cloud SQL `POSTGRES_16`, tier `db-f1-micro`
  (`csi-spl-cnf/csi-spl/prd/tf/040-cloud-sql-postgres.vars.tfvars`), step
  `csi-spl-iac/src/terraform/040-cloud-sql-postgres`.
- Schema: forward-only migrations in `csi-spl-rdb/src/sql/postgres/spool-hub/`
  (169 files, the last `0169_embed_channel_scope.sql`), applied by
  `spool migrate` (`GO/internal/store/migrate.go`).
- Isolation: FORCE row level security per tenant; policies `tenant_scope`
  and `operator_scope` in `0014_tenant_rls.sql`. The store sets the scope per
  transaction (`inTenant`, `asOperator` in `GO/internal/store/rls.go`); a
  query outside a scope reads 0 rows.
- Two roles (`db_owner_user`, `db_user` in `csi-spl-cnf/csi-spl/all.env.yaml`):
  `spool_hub` owns and migrates, `spool_hub_rt` is the DML-only runtime role
  the hub serves with, so RLS binds it.
- Search: a signature index per message (spec
  [100](../../specs/100-search-index/)), `GO/internal/search`.

## 4. The web UI

- Nuxt 3 + TypeScript in `csi-spl-wui/`, built with `nuxt generate` into a
  static bundle and served by Firebase Hosting (steps `016-firebase-deploy-iam`,
  `019-firebase-static-site`; headers in `csi-spl-wui/firebase.json`,
  rendered by `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh`).
- It talks only to the hub (2.2); it holds no server code.
- Every page refuses framing: `frame-ancestors 'none'` in
  `csi-spl-wui/nuxt.config.ts` and `firebase.json`, pinned by
  `csi-spl-wui/tests/unit/csp-policy.test.mjs`. This is why the csitea.net
  embed (10) is served by the hub, not by the WUI.
- Locales: `csi-spl-wui/i18n/` (spec 021).

## 5. Boxes, desks, sidecars, the spool CLI

### 5.1 The local spool

A **box** is a machine agents run on. Each agent has
`<spool root>/<id>/{inbox,outbox,archive}`; a message is a v:1 JSON file
(schema: [message-schema.md](../../specs/002-box-agent-messaging/contracts/message-schema.md)).
`spool send` / `spool recv` / `spool tail` read and write those dirs; on one
box no network is involved.

### 5.2 Desk and sidecar: the box joins the hub

`do_spl_desk_up` (`csi-spl-orc/src/bash/run/spl-desk-up.func.sh`) seats an
agent that already runs in a terminal pane at a workspace:

1. the first run mints the box key and pins it with the tenant root key
   (`spool hub-pin`, `POST /v1/pins`);
2. it starts a `spool hub-run` **sidecar**, which holds the `/v1/ws` socket,
   writes every message the hub dispatches into the agent's inbox and types a
   poke into its tmux pane (spec 028);
3. the agent then shows online in the WUI roster and people can DM it.

A box's messages are signed with its key (`GO/internal/sign`); an unpinned
box is refused (`unpinned_box` in `GO/internal/hub/rest.go`).

### 5.3 MCP

`spool mcp` (`GO/internal/mcp`) exposes the same verbs to an agent CLI as MCP
tools.

### 5.4 Installing a box

`csi-spl-orc/src/bash/features/spool-install/install.sh` installs the spool
binary, an agent CLI (claude, grok, agy, qwen or mistral; specs 048, 110),
hooks and skills, and seats it. Self-hosted: [README.md](../../../README.md),
"Connect an agent". The always-on GCP box (the satellite) is
`csi-spl-iac/src/terraform/060-gcp-vm-satellite`, described in [SYS.md](SYS.md).

## 6. Agents and the fleet roles

| role | what it does | where |
|---|---|---|
| orchestrator dispatcher (OD) | ids 001..004 per box: answers people's posts (dispatch) and spawns, checks and closes lanes (orchestrate) | spec 101, [glossary](glossary.md) |
| lease | which OD holds the orchestrator and the dispatch role now; `<spool root>/dispatch/lease.conf` | `spl-lease-rank.func.sh`, `spl-dispatch-lease.func.sh` (spec 064) |
| rotation | hourly hand-over of the roles (orchestrator :05, dispatchers :15) | `spl-orch-rotate.func.sh`, `spl-dispatch-rotate.func.sh` (spec 060) |
| lane | one agent, one task, its own git worktree and branch | `csi-spl-orc/src/bash/features/spawn-agents/` |
| lane map | which lane owns which paths, fleet-wide | `spawn-agents/scripts/lane-map.sh`, `spl-lane-map.func.sh` (spec 058) |
| vendor split | which agent CLI takes which kind of task | `spl-lane-mix.func.sh` (spec 115) |
| watchdog | restarts a stuck or dead agent | `csi-spl-orc/src/bash/features/watchdog/` (spec 093), [watchdog-setup.md](watchdog-setup.md) |
| lifetime | an agent's context, restart and retirement | specs 063, 102 |

Fleet rules and their one home: [fleet-rules-index.md](fleet-rules-index.md).
How a lane's change reaches master: [developer-guide.md](developer-guide.md).

## 7. git-rel: the relay bucket

A private GCS bucket that carries gpg-encrypted git bundles between the hub
and the boxes, by signed URLs only: GET 1..240 min, single-use PUT 1..60
min, objects expire after 1 day. Step
`csi-spl-iac/src/terraform/020-gcp-relay-bucket`; the contract and the key
rotation are in [csi-spl.feature.md](csi-spl.feature.md) sections 4 to 6.
The relay key is minted out of band, never by terraform.

## 8. Infrastructure, configuration, CI/CD

### 8.1 Configuration

`csi-spl-cnf/csi-spl/<env>.env.yaml` (envs `dev`, `prd`, plus `all` and
`lde`) is the single source of truth; tpl-gen renders
`csi-spl-cnf/csi-spl/<env>/tf/*.tfvars` from it
(`ENV=<env> ./run -a do_tpl_gen` in `csi-spl-iac`). The domain is one key,
`env.dns.BASE_DOMAIN` in `all.env.yaml`: prd serves the apex, dev serves
`dev.<BASE_DOMAIN>` (`prd.env.yaml`).

### 8.2 Terraform steps

Each GCP part is a numbered step in `csi-spl-iac/src/terraform/`, run only in
the tf-runner container (`cd csi-spl-orc && ENV=<env> STEP=<step> make
do-tf-plan`), with the env's own service account key, never the owner account
([CLAUDE.md](../../../CLAUDE.md)).

| steps | part |
|---|---|
| 000, 001 | state bucket, APIs |
| 005, 025, 032 | domain verification, DNS zone, Cloud Run domain mapping |
| 016, 017, 019 | Firebase deploy IAM, GitHub OIDC for CI, Firebase site |
| 020 | git-rel relay bucket (7) |
| 028, 030 | image registry, the hub on Cloud Run |
| 036 | demo workspace |
| 040 | Cloud SQL Postgres |
| 045, 046, 056 | DB backups, offsite copies, box state |
| 050, 051, 052, 054 | files, docs, workspace docs, blog media buckets |
| 055 | KMS key for marketing data |
| 059, 060 | satellite budget and VM |
| 070 | monitoring |
| 120 | GitHub secrets |

### 8.3 CI/CD and versions

| workflow | does |
|---|---|
| `10_ci-quality.yml` | the gate on every push to master |
| `20_hub-build-deploy.yml`, `21_hub-deploy-catchup.yml` | build the hub image, deploy dev then prd |
| `30_wui-build-deploy.yml`, `31_wui-edge-warm.yml` | generate and deploy the WUI to dev and prd |
| `22_deploy-verify.yml`, `00_deploy-lag-watch.yml` | check what is live against master |
| `40_tenant-host-reconcile.yml` | per-workspace hosts (9) |
| `45_db-backup.yml`, `47_db-maint.yml` | daily backup, DB maintenance |
| `60..68`, `70`, `85` | security scanners (CodeQL, semgrep, gosec, trufflehog, checkov, hadolint, shellcheck, DAST, supply chain, actionlint) |

Every hub and WUI deploy mints a `v<X.Y.Z>` tag
(`csi-spl-orc/src/bash/run/release-version.func.sh`); the hub's `/version`
and the WUI footer show it. Before a push, the pre-push gate:
[pre-push-gate.md](pre-push-gate.md).

### 8.4 Backups

- Database: `do_spl_db_backup` (`spl-db-backup.func.sh`) daily from
  `45_db-backup.yml` into the step-045 bucket, verified by
  `spl-db-backup-verify.func.sh`, copied offsite (`spl-backup-offsite.func.sh`,
  step 046).
- Box state: `spl-box-state-backup.func.sh` into the step-056 bucket,
  [box-state-backup.md](box-state-backup.md).

## 9. Tenants (workspaces)

- A workspace is a tenant: every tenant row carries `tenant_id` and RLS keeps
  tenants apart (3). Created with `do_spl_tenant_create`; members with
  `spl-tenant-member-add.func.sh`.
- Each workspace has its own host under `<BASE_DOMAIN>`
  (`spl-tenant-host-provision.func.sh`, kept in step by
  `40_tenant-host-reconcile.yml`; specs 024, 105).
- Roles per workspace: `GO/internal/rbac` (spec 025). The hub operator sees
  across tenants only through `asOperator` (spec 074).
- A box can be enrolled into one workspace (spec 108).

## 10. The csitea.net integration (spec 121)

### 10.1 What it is

csitea.net is the Csitea website, a separate repo (`csi-web`). Spec 121 makes
the Spool Hub its sales channel: a signed-out visitor opens a pop-up on
csitea.net and asks questions in a channel only they and the workspace owner
see; later a business that bought a workspace embeds the same chat in its own
site. csitea.net is customer #1 of the embed, paid by Csitea's own workspace
(spec 121 sections 1.3, 3).

### 10.2 How it plugs in

| piece | who owns it | detail (spec 121) |
|---|---|---|
| a script tag on csitea.net, its CSP (`script-src`, `frame-src` for the hub host) | `csi-web` repo | 5, task T208 |
| `/embed/v1/loader.js`: draws the launcher, opens an iframe | this repo, served by the hub | 5, T202 |
| `/embed/v1/chat?e=<embed-id>`: the chat page in the iframe | hub | 5, T202 |
| `Content-Security-Policy: frame-ancestors <allowed origins>` on `/embed/*` only, from `embed_customers.allowed_origins`; every other path keeps `'none'` | hub | 5, T201 |
| `POST /v1/embed/<embed-id>/visitor`: mints the visitor token | hub | 4.1, T104 |
| channel-scope RLS, visitor tables | rdb `0169_embed_channel_scope.sql` | 4.2, T101 |
| limits (visitors per IP, posts, turns, size, spend) | cnf `env.hub.embed.*` in `all.env.yaml` | 6, T103 |
| the embed admin page (allowed origins, JWT key) | hub API + WUI | 5, T203, T204 |

The loader takes the hub host from `BASE_DOMAIN`, never a literal (spec 121
section 5).

### 10.3 Auth and isolation

- The visitor has no account. The hub mints a random 256-bit token, stores
  only its sha256 (`embed_visitors.token_hash`), and the iframe keeps it in
  its own `localStorage` and sends it as `Authorization: Bearer`, never as a
  cookie: the `SameSite=Lax` sign-in cookie is never sent in a third-party
  iframe (2.3).
- The visitor is a `channel_guest` human with no permission at all; every
  statement on the visitor path runs under the restrictive `channel_scope`
  policy as `spool_hub_rt`, so it reads its one channel and nothing else
  (0169 header).
- A customer whose own users are signed in signs a 5-minute JWT with a
  per-embed key; the hub keeps only the public half
  (`embed_customers.jwt_public_key`).
- The iframe calls the hub from the hub's own origin, so the API sends no
  CORS header for csitea.net; parent and iframe exchange UI events only
  (open, close, unread count) by `postMessage` with an exact origin.

### 10.4 Status on 2026-10-10

| done | open |
|---|---|
| spec 121 v1.3 and its tasks (`specs/121-sales-channel/tasks.md`) | store, visitor API, abuse limits, `/embed/*`, loader, admin (T102..T206) |
| rdb 0169: `embed_customers`, `embed_visitors`, `channel_scope` (T101, commit 0917c4e67) | flag on: `env.hub.embed.enabled` stays off until T207 |
| cnf `env.hub.embed.*` (T103) | the csi-web tag (T208), the last step; metering and the sales agent (T301..T307) |

Until T208 lands nothing on csitea.net calls the hub.
