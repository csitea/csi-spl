# Feature Specification: spool-hub-api infrastructure (copy csi-rel / pas-psf)

**Feature ID**: `007-spool-hub-api-infra`

**Created**: 2026-09-18

**Status**: Draft

**Input**: Implement spool-hub-api with the **same infra and DNS** as csi-rel
and pas-psf: local dev, terraform, docker, Cloud Run, Cloud SQL, secrets,
WIF. Exclude online-store business logic and store tables.

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-hub-api-infra.md`

**Depends on**: M1 protocol (`002`/`006` wire). This feature is **how the
hub process is hosted**, not the mail schema.
M1 is not done until this infra is **applied on both `dev` and `prd`**.
prd DNS: **wildcard `*.spool-hub.ai` from M1** (`https://<tenant>.spool-hub.ai`).
dev: **wildcard `*.dev.spool-hub.ai`**. M1 Cloud Run ingress is **IAP and/or
IP allowlist**; remove for M2. Tenant create is owner-only; **several**
manual tenants (not one). New tenant = new Host name, **no new DNS record**.

## User Story 1 - lde matches pas-psf/csi-rel (Priority: P1) 🎯

Operator runs compose (rdb + api) from `csi-spl-orc` the same way as
`pas-psf-orc` / `csi-rel-orc`. Hub listens locally; 002 still works with
`$SPOOL_HUB_URL` unset.

**Acceptance**: `docker compose` files exist for api/rdb/infra; no wui/shop
compose required for M1.

## User Story 2 - terraform steps with the same numbers (Priority: P1)

`csi-spl-iac` grows the copied steps (`003`,`005`,`007-dns`,`017`,`028`,
`029`,`030`,`031`,`040`, files bucket). `000`/`001`/`020` already exist.
`tf-plan` works; apply needs owner go.

**Acceptance**: `ls csi-spl-iac/src/terraform` includes those step dirs;
cnf tfvars templates exist; no store-only steps.

## User Story 3 - DNS + Cloud Run mapping like csi-rel 033/031 (Priority: P1)

Zone for product DNS; domain mapping to Cloud Run; `do_wait_for_cert`. Host
from cnf (`<tenant>.spool-hub.ai`).

## User Story 4 - Postgres is spool tables only (Priority: P1)

Cloud SQL + lde Postgres run migrations from `csi-spl-rdb` that create
`tenants`/`pins`/`messages`/… — **zero** catalogue/order/customer tables.

## Requirements

- **FR-001**: Copy/adapt listed TF steps from csi-rel-iac and pas-psf-iac;
  same numbers; morph then strip shop.
- **FR-002**: Copy lde docker (api, rdb, infra) from pas-psf-orc; no shop
  WUI/WordPress/stripe-mock in M1.
- **FR-003**: Copy DNS ops (`007-dns`, export, flush, wait-for-cert).
- **FR-004**: Copy Cloud Run (`030`) + domain mapping (`031`) + WIF (`017`).
- **FR-005**: Copy Cloud SQL (`040`); schema is spool-only.
- **FR-006**: Do not copy store biz logic or store SQL.
- **FR-007**: Secrets pattern from `029` + Secret Manager; no keys in git.
- **FR-008**: `tf-plan` never apply; apply is owner go.

## Success Criteria

- **SC-001**: lde api+rdb up; local 002 tests green without hub; hub tests
  against localhost hub.
- **SC-002**: `terraform validate` on each copied step with spool cnf.
- **SC-003**: `csi-spl-rdb` SQL has no product/order/customer identifiers.

## Out of Scope

Shop, Firebase hosting for a storefront, recaptcha, BIN, stock janitor,
WordPress VMs, M2 payment slots (empty or omitted until M2), M3 WUI hosting
(Firebase/Cloud Run for `csi-spl-wui` later).

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:10:00Z -->
