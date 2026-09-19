# Spec 024: per-tenant hosts, automated (no wildcard)

**Feature**: `specs/024-spool-tenant-hosts` · **Created**: 2026-09-19 · **Lane**: CLE-3404

> Numbering note: the commits of this lane before this spec landed, and the
> header of `csi-spl-rdb/.../0015_tenant_hosts.sql`, say "specs/022". Two other
> lanes took 022 (WUI top bar search) and 023 (user settings keys) at the same
> time. 022 in those places means THIS spec. 0015 is forward-only and
> sha-checked by `spool migrate`, so its comment stays as applied.

## 1. Why

The M1 hub load balancer (step 031) carried a wildcard `*.<fqdn>`. The owner
removed it on 2026-09-19 ("exactly csi-rel: no load balancer"). The hub is now
served only by Cloud Run domain mappings (step 032), and a domain mapping
cannot take a wildcard. So every tenant host `<tenant>.<fqdn>` needs:

- its own Cloud Run domain mapping (032, `cloud_run_additional_domains`),
- its own `ghs.googlehosted.com.` CNAME (025, `cloud_run_mapping_records`),
- its own Google-managed certificate (issued after the DNS is live:
  ~9-11 min, then ~5-8 min of edge propagation, measured n=1 per host by
  CLE-3382).

Tenants are created continuously by self-serve checkout, so without this a
paid tenant's host stays dark until someone edits cnf and applies. CLE-3382
measured 7 dark dev tenants on 2026-09-19.

**Owner decision (2026-09-19)**: of (a) operator step, (b) tenant-in-path
redesign and (c) automate, the owner chose **"Automate per tenant"**. No
hub/box/WUI redesign. For the trigger, the owner chose **option 2, "GitHub
Actions schedule"**, and gave a standing go for these applies.

## 2. Requirements

- **FR-001** A tenant host is provisioned ONLY through terraform (032 + 025)
  run by the make / tf-runner path, as the per-env project SA. The hub never
  runs terraform and never calls GCP for this.
- **FR-002** Every creation path queues the host in the same transaction as
  the tenant row: the paid webhook, fake-pay, `CreateTenant`, and `spool
  hub-tenant` / `do_spl_tenant_create`. A deleted tenant marks its host for
  removal. (rdb 0015: `tenant_hosts` plus triggers on `tenants`.)
- **FR-003** Terraform reads the tenant list from ONE committed source:
  cnf `env.dns.mapped_tenants`, rendered into the 032 and 025 tfvars. Adding a
  tenant appends to that list, so a re-apply keeps every existing mapping.
- **FR-004** The checkout status (§1.3) and claim (§1.4) responses carry
  `tenant_host` and `host_status` (`pending` | `ready` | `unknown`). The
  success and claim pages say "your address <host> is being prepared" while
  the status is pending, and poll until it is ready.
- **FR-005** A plan that would replace anything, or destroy anything other
  than a deprovisioned tenant's own mapping + CNAME, is refused before any
  apply.
- **FR-006** One apply per env at a time: a `flock` per env on a machine, and
  a concurrency group per env in CI. Dev runs before prd.
- **FR-007** Idempotent: a tenant that is already mapped re-runs as a no-op
  plan, a cert check and a probe.
- **FR-008** Nothing ad hoc: every step is a named action with a test.

## 3. Design

### 3.1 Status model (`tenant_hosts`, rdb 0015)

| status | set by | meaning |
|---|---|---|
| `pending` | trigger on `tenants` INSERT (also a re-created slug) | the tenant exists; its host is not provisioned yet |
| `ready` | reconcile, after the cert and the probe | mapping + record applied, cert provisioned, host answers |
| `failed` | reconcile | the last attempt failed (`detail`); retried on the next run; the buyer still sees `pending` |
| `removing` | trigger on `tenants` DELETE | the reconcile takes the host down |
| `removed` | reconcile | deprovisioned |

There is no FK to `tenants`, because the row must outlive a deleted tenant.
RLS works as in 0014 (enable + force, tenant scope + operator scope).
Existing tenants were queued once by the migration.

### 3.2 Named actions (csi-spl-orc)

| action | does |
|---|---|
| `do_spl_tenant_host_provision TENANT_ID= ENV= [DRY_RUN=1]` | add the slug to `mapped_tenants` → render 032 + 025 (`make do-generate-config-for-step`) → per step `make do-tf-plan` + gate + `make do-provision` → `do_spl_wait_for_mapping_cert` → `do_spl_probe_hub_host` until it passes → `tenant_hosts` ready |
| `do_spl_tenant_host_deprovision TENANT_ID= ENV= [DRY_RUN=1] [FORCE=1]` | the twin. The gate admits ONLY `google_cloud_run_domain_mapping.additional["<host>"]` and `google_dns_record_set.cloud_run_mapping["<tenant>/CNAME"]`. Refuses while the tenant row exists. |
| `do_spl_tenant_host_reconcile ENV= [DRY_RUN=1] [CNF_PUSH=1]` | reads the open rows as the env SA: pending/failed → add, removing → remove, an unpaid tenant is held. With CNF_PUSH=1 it commits + pushes the cnf change **before** the apply, so a run that dies mid-apply leaves trunk declaring the host and the next run completes it. Then one gated apply, per tenant cert + probe → ready/failed. Nothing open → exit 0 with no terraform. Prints `open=<n>`. |

The cnf edit changes only the one flow-style `mapped_tenants: [..]` line.
`yq -i` would drop every blank line of the file. The cnf commit carries the
identity that the trunk's own cnf history carries: no literal in the tree, no
AI trailer. Whether it landed is read from `merge-base`, never from the push
output.

### 3.3 Trigger (owner option 2): `40_tenant-host-reconcile.yml`

Every 10 min, plus `workflow_dispatch` (environment, dry_run). Per env, dev
then prd (`max-parallel: 1`), concurrency group `tenant-host-<env>`, never
cancelled:

1. The existing key secret `GCP_KEY_CSI_SPL_<ENV>` (iac 120) is written to
   the key path the actions resolve. dev also gets the prd key for 025's
   delegation record in the prd apex zone. No new credential.
2. `do_spl_tenant_host_reconcile` read-only → `open=<n>`. Zero ends the job.
3. Otherwise: tpl-gen at the pin, `make do-setup-app-inf`, then the reconcile
   with `DRY_RUN=0 CNF_PUSH=1`.
4. A pushed cnf change dispatches `30_wui-build-deploy.yml` for that env,
   because the WUI CSP lists the tenant hosts from `env.json`, and a
   GITHUB_TOKEN push starts no workflow.

Why this trigger (the owner picked it from three options):

- The hub stays out of GCP IAM. It writes one row, and a compromised hub
  cannot map arbitrary hosts, because the reconcile maps only DB tenants,
  refuses reserved labels, and gates destroys.
- It reuses the credential and the path that already exist (the per-env key
  secret, the make / tf-runner stack), and it does not depend on the operator
  box being up.
- Declaring before applying, plus the destroy gate, makes a crash
  self-healing and a lost cnf line loud, not destructive.

Rejected: (1) a systemd timer on the operator box, which depends on that box
being up; (3) a human go per tenant, where latency is a human.

## 4. Checks and controls

- `csi-spl-orc/src/bash/tests/tenant-host.tst.sh`. **CONTROL (brief)**: a
  re-apply with a new tenant keeps the old mappings. The rendered 032 lists t1
  next to the new tenant, and a plan that drops t1's mapping is refused before
  any `do-provision`, with the tenant marked failed. The same destroy passes
  only when it is on the allow list. Also covered: the cnf add + del
  round-trips byte for byte; a tagged-row parser that ignores the proxy log
  line (regression de06bd7); and a cnf push onto a local bare trunk (author =
  history's, no trailer, only the env's cnf paths, refused on a dirty tree).
- `csi-spl-iac/src/bash/tests/tenant-host-workflow-40.tst.sh`: schedule,
  concurrency per env, dev → prd, key secrets only, no host terraform, and
  the apply is the gated named action. CONTROL: a planted secret and a host
  terraform step are both reported.
- Go: `TestTenantHostQueue` (memory + Postgres), `TestTenantHostTriggers`
  (delete → removing, re-create → pending, a no-op re-insert keeps ready),
  `TestCheckoutHostStatus` (CONTROL: ready flips the same read), and
  `TestRLSCoversEveryTenantTable` covering `tenant_hosts`.
- WUI: `pollHostReady` tests (pending → network error → ready; unknown stops;
  CONTROL: stays pending until maxPolls).

## 5. Out of scope / open

- A "delete tenant" action does not exist yet. The DELETE trigger and the
  deprovision twin are ready for it.
- The M2 claim mail still says "Tenant URL" with no "being prepared" note
  (the mail lane can add one; the page covers the buyer meanwhile).
