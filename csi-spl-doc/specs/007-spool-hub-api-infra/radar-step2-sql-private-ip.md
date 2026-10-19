# Radar step 2: the hub DB's public IP (trivy GCP-0017), SPL-2161

Plan only. Nothing here is applied. Each apply waits for the owner's go,
dev first, prd only after dev is clean.

**Decision (owner HUM-10, t1 8f476aa8, msg 9505487e, 2026-10-21):** "ok,
choose the cheaper option for now we do not have proper financing on this
project , as soon as we get first paying customers than we switch". That is
option B (2.2) on dev: keep the public IP and require connectors. Option A
(private IP) is the later switch, after the first paying customers; nothing
of A is in the code. prd waits for its own go after a clean dev.

## 1. What is there today (measured 2026-10-19, read-only, per-env SA)

| | dev `csi-spl-dev-pg` | prd `csi-spl-prd-pg` |
|---|---|---|
| `ipv4Enabled` | true | true |
| authorized networks | none | none |
| `sslMode` | `ENCRYPTED_ONLY` | `ENCRYPTED_ONLY` |
| `connectorEnforcement` | `NOT_REQUIRED` | `NOT_REQUIRED` |
| private IP / PSA peering | none | none |
| `servicenetworking`, `vpcaccess` APIs | not enabled | not enabled |
| VPC networks | `default`, `csi-spl-dev-wine-box-vpc` | `default` |

Commands: `gcloud sql instances describe <env>-pg`, `gcloud compute networks
list`, `gcloud services list --enabled`, each with `--account` = the per-env SA.

Who connects to the DB, and how:

| client | runs where | path |
|---|---|---|
| hub (030) | Cloud Run | `/cloudsql` unix socket, Cloud Run's built-in connector, over the public IP |
| `do_spl_db_bootstrap` before every hub roll | wf 20, `ubuntu-latest` (GitHub-hosted) | Cloud SQL Auth Proxy, public IP |
| backup verify, restore check | wf 45, `ubuntu-latest` | Auth Proxy (`spl_via_proxy`) |
| restore drill | wf 49, `ubuntu-latest` | Auth Proxy |
| `do_spl_db_*`, tenant create, search probes (9 action files call `spl_sql_proxy_start`) | the boxes | Auth Proxy |
| daily export, import | inside Google (`gcloud sql export/import`) | no client connection |

So no raw Postgres client can connect today: with no authorized network, the
public IP admits only Cloud SQL connectors, which authenticate with IAM
(`roles/cloudsql.client`) and encrypt. GCP-0017 flags the IP itself.

The last 040 apply (SPL-2250, prd REGIONAL, 2026-10-18) restarted prd's
instance: `gcloud sql operations list` shows that UPDATE from 06:58:44Z to
07:11:23Z (12 min 39 s).

## 2. The options

### 2.1 A: private IP only (removes GCP-0017)

- Terraform: Private Services Access (an allocated range plus a
  `servicenetworking` peering on `default`), `private_network` on the
  instance, `ipv4_enabled = false`; 030 gets Direct VPC egress (or a
  Serverless VPC connector) and the hub's DSN secret gets a new version with
  TCP `host=<private ip>`, because Cloud Run reaches a private IP over TCP,
  not through the `/cloudsql` socket (Cloud SQL "Connect from Cloud Run").
- Every client outside Google loses the DB: wf 20 (the deploy would fail its
  migrate step), wf 45, wf 49 and every box action. Each needs a path into
  the VPC: a bastion VM with an IAP tunnel, or self-hosted runners inside the
  VPC, plus a change to `spl_sql_proxy_start` and 3 workflows.
- Cost per env per month: PSA and Direct VPC egress have no instance fee; a
  Serverless VPC connector is at least 2 instances (not priced here); a
  bastion is one small VM (not priced here). Not measured.
- Downtime: an `ip_configuration` change on the instance; count on a
  restart like the 10-18 one (12 min 39 s on prd). Not checked in the docs.
- Undo: re-enable `ipv4_enabled`, another restart; the PSA range stays.

### 2.2 B: keep the public IP, require connectors (recommended)

- Terraform: `settings.connector_enforcement = "REQUIRED"` (cnf
  `steps.040-cloud-sql-postgres.connector_enforcement`). Only the Auth Proxy
  and the language connectors may connect, even if someone adds an
  authorized network by hand later. No client changes: every client above
  already uses a connector.
- What stops working: `gcloud sql connect`, Cloud SQL Studio, read replicas
  (none exist; the docs forbid replicas with enforcement on).
- Cost: 0.
- GCP-0017 stays as a triaged finding in `.trivyignore.yaml` (it flags
  `ipv4_enabled`, which B keeps). Step 2 closes the open question that entry
  carried (accept or move to private IP) with "accept, connectors required".
- Downtime: not checked whether this setting restarts the instance; the dev
  apply measures it with `gcloud sql operations list`.
- Risk: the docs do not say that Cloud Run's built-in `/cloudsql` connection
  counts as a connector. If it did not, dev's hub would lose its DB on apply.
  That is why dev goes first and alone.
- Undo: delete the dev.env.yaml line, render, apply (`NOT_REQUIRED`).

### 2.3 Why B

A cuts off the deploy pipeline, the backups and every box action until a VPC
path exists for each, and it costs a restart. Today that buys nothing a raw
client could do, because none can connect. B costs nothing and changes no
client.

## 3. The change (connectors only; public IP kept)

- `csi-spl-iac/src/terraform/040-cloud-sql-postgres`: `connector_enforcement`
  variable (validated, default `NOT_REQUIRED`), set on `settings`.
- cnf: `all.env.yaml` `NOT_REQUIRED`; `dev.env.yaml` `REQUIRED`. prd is
  unchanged until the owner's go after a clean dev.
- Rendered tfvars (`do_tpl_gen` dev and prd): the 040 tfvars and the
  env.json change, nothing else.
- Test: `tf-steps-render-and-validate.tst.sh` checks dev `REQUIRED`, prd
  `NOT_REQUIRED`, the wiring, that the public IP is kept, and that there is no
  authorized network.

## 4. The dev plan

The tf-runner stack mounts the main checkout only (one stack per box), so it
plans master's code, not a branch. `ENV=dev STEP=040-cloud-sql-postgres make
do-tf-plan` on master `c52f92082`: `No changes.` That is the baseline. With
this branch on master the expected dev plan is one in-place update,
`settings.connector_enforcement: "NOT_REQUIRED" -> "REQUIRED"`. Not run, for
the reason above.

## 5. Apply steps, each after the owner's go

1. Land the branch. prd's plan stays empty (the test pins prd to
   `NOT_REQUIRED`).
2. dev plan, then dev apply. Then check: the hub's `/version` and a message
   round trip on dev, `do_spl_db_bootstrap` on dev through the proxy, and
   `gcloud sql operations list` for a restart.
3. Only when dev is clean: prd cnf `REQUIRED`, prd plan, and prd apply.
