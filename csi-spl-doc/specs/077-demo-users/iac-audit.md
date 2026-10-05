# 077 demo users: infra-step audit

Owner go (t1 topic `4979bb24`, msg `fe7b67be`): "if all of the iac code from
this discussion is not in the terraform, fix it". Repo rule (CLAUDE.md, owner
2026-09-19): nothing ad hoc; every infra step is a named `./run` action, and
where terraform can run it, terraform runs it.

Tree: origin/master `96f6efb6`. Source: `spool tail --task
4979bb24-579f-412c-869f-c44ca173a381` (2026-10-04T17:50Z .. 2026-10-05T11:29Z)
and this spec's `tasks.md`.

## 1. Every infra step in the topic

| # | step | how it ran | in terraform? | fix |
|---|---|---|---|---|
| 1 | hub env `SPOOL_HUB_DEMO_ENABLED`, `_WORKSPACE`, `_PROVIDERS`, `_MAX_LIVE` (T023, `b23e40d8`) | cnf `env.demo.*` -> tpl-gen -> `030-cloud-run-hub.vars.tfvars` -> `make do-provision` (dev by c-310, prd by the owner) | **yes**: step 030, `google_cloud_run_v2_service.hub` env | none |
| 2 | demo ON in prd (T024, `2aea515b`) | cnf flip, re-rendered tfvars, 030 prd apply by the owner | **yes**: step 030 (same resource as 1) | none |
| 3 | 052 workspace-docs buckets, dev + prd | `make do-provision` by the owner (one-liners 1, 2) | **yes**: step 052 | none (052 prd is the owner's, topic `199cafc7`) |
| 4 | 055 KMS key re-run, dev + prd | `make do-provision` by the owner (one-liners 3, 4); the first run failed because the KMS API that step 001 enables was not live yet | **yes**: steps 001 + 055 | none in terraform; see section 2.2 |
| 5 | 030 hub, dev + prd | `make do-provision` (one-liners 5, 6) | **yes**: step 030 | none |
| 6 | demo workspace create: tenant row + root key (T023 dev by c-310, T024 prd by the owner 11:26Z) | named action `do_spl_demo_workspace_create` (wraps `do_spl_tenant_create`, `TENANT_HOST=0`), idempotent, read first | **no** -> **yes**: step 036 | section 3 |
| 7 | box-wui pin under `demo` (SPL-1290) | inside 6: `do_spl_cloud_pin_box_wui`, signed with the root key while in hand | **no** -> **yes**: step 036, inside 6 | section 3 |
| 8 | nightly demo wipe (T017, `7243b464`) | named action `do_spl_demo_wipe`, scheduled by wf 46 | no: a data operation (deletes rows), not infra | none: stays a named action on a schedule |
| 9 | tf-runner and desk containers restarted after the power loss | `make do-setup-app-inf`, `do_spl_desk_up_all` | no: local tooling, not GCP infra | none |

Read-only checks in the topic (prd seat counts, `/v1/demo`, `/version`,
`do_check_deploy_lag`) change nothing and are not listed.

## 2. What is not in terraform, and why

### 2.1 Demo workspace create + box-wui pin (rows 6, 7)

It is a named, idempotent action today. Terraform runs steps only in the
tf-runner container, and the action cannot run there as the image stands
(`csi-spl-orc/src/docker/tf-runner/Dockerfile`,
`docker-compose-tf-infra.yaml`):

- the read and the insert go through the Cloud SQL proxy and `psql`: the image
  has neither, and the proxy's docker fallback needs a docker socket it lacks;
- the insert and the pin call the `spool` CLI, built from `csi-spl-api` with
  Go: the image has no Go;
- the create writes the tenant root PRIVATE key to
  `$HOME/.spool-hub/tenants/<env>-<ws>.json` (0600). In the container that
  home is not a mount, so the key would be lost when the container is
  recreated. The key must never reach state or a log, so terraform may only
  call the action, never carry the key;
- the hub's own path (`POST /v1/operator/workspaces`) takes only an
  operator-admin browser session, not the env SA, until 074 T007.

### 2.2 055 after 001 (row 4)

Not an ad hoc step: both are terraform. The failure was API propagation
between two steps with separate state. A wait for the KMS API before 055's
first resource is a possible follow-up, offered to the owner in topic
`f0c3927e`; not built here.

## 3. Fix for 2.1: step 036-spl-demo-workspace

Decision: c-001 and c-002, task `4979bb24` (option 1, the owner's
`fe7b67be`). Each gap of 2.1, closed:

| gap | closed by |
|---|---|
| terraform does not run it | `036-spl-demo-workspace`: one `terraform_data` whose local-exec runs `./run -a do_spl_demo_workspace_create` (`DRY_RUN=0`). It re-runs only when the env, the project or the workspace id changes. |
| inputs | `demo_enabled` / `demo_workspace` are cnf `env.demo.{enabled,workspace}`, derived by `do_spl_merged_cnf` (one key per fact). The demo off: nothing runs. |
| no `psql`, no proxy | tf-runner image: Debian `postgresql-client`; `cloud-sql-proxy` pinned by version (= cnf `cloud_sql_proxy_image`) and sha256 |
| no `spool` CLI | `make do-provision` with `STEP=036-...` builds it on the host first (`csi-spl-api/src/bash/build.sh`), into the mounted tree; no Go in the image |
| the root key | tf-runner mounts `~/.spool-hub`, which the `do-setup-app-inf*` targets create as 0700 first. The key is no input, output or trigger: it is in neither state nor plan nor log |
| an existing workspace | the action reads first and prints `"created":false`: the first apply on dev and prd is a no-op |

Test: `csi-spl-iac/src/bash/tests/demo-workspace-036.tst.sh` (the step
applied against a stub action, plus the image, mount and make checks); the
action's read-first behaviour stays covered by
`csi-spl-orc/src/bash/tests/demo-workspace-create.tst.sh`.
