# Tasks: spool hub cloud estate (iac)

**Feature**: `specs/007-spool-hub-api-infra` · **Spec**: `./spec.md` ·
**Order**: `./contracts/provisioning-order.md`

Status per task: `[x]` Implemented (verified, citation given) · `[~]`
Partial · `[ ]` Planned. Every apply below needs an explicit owner go.
Verified 2026-09-18 ~19:15Z on trunk `bbc41e7` (spec §1.1).

## Phase 0: lde (US1)

- [x] T001 Compose `docker-compose-{api,infra,rdb}.yaml` + hub Dockerfile in
      `csi-spl-orc/src/docker/` — FR-016 (`ls csi-spl-orc/src/docker`)
- [x] T002 `do_gen_docker_env`, `do_setup_app_inf`, `do_teardown_app_inf` —
      FR-016 (`lde-stack.tst.sh` green, orc suite 6/6)
- [x] T003 lde smoke: pg, gcs, migrate, serve, hello PASS — FR-016 (action
      header: measured n=3, exit 0)

## Phase 1: state + services (steps 1–2)

- [x] T004 `000-gcp-remote-bucket` applied dev + prd — FR-002 (tfstate:
      1 resource each)
- [~] T005 `001-enable-gcp-services`: dev enabled; **prd re-apply** with the
      current cnf list (run, sqladmin, compute, secretmanager,
      artifactregistry, certificatemanager missing; iamcredentials + sts
      added by `2a7888c`, re-apply dev too) — FR-003

## Phase 2: DNS zone — the gap (step 3, US3)

- [x] T010 Land `025-gcp-dns-zone` on trunk: `import` of the prd
      `spool-hub` zone, `prevent_destroy`, cnf `steps.025-gcp-dns-zone.zone_name`,
      tpl + render test — FR-004 (`9ed50ac`; `dns-zone-025.tst.sh` green)
- [x] T011 `031` writes records into the `025` zone, dev records into the
      prd zone across projects (`dns_zone_project`); cnf `dns_managed_zone:
      spool-hub` — FR-004, FR-012 (`9ed50ac`)
- [x] T012 prd plan of `025` shows 1 import, 0 add, 0 destroy; owner applies;
      `terraform state list` shows the zone; NS unchanged — FR-004 (applied
      19:14Z by the apply lane: 1 in state, NS unchanged; code `9ed50ac`)
- [x] T013 **Owner decision: option A** (hand off), confirmed 2026-09-18
      ~19:46Z; the owner set the registrar NS. The **apex points at the hub
      LB**, not Gandi parking — FR-005
- [x] T020a NS -> `ns-cloud-e1..e4` (`dig +norec NS … @v0n1.nic.ai` ->
      ns-cloud-e*, ~19:45Z); `do_gandi_set_nameservers` accepts ns-cloud-* and
      applies with `CONFIRM=yes` (`1b78621`, `gandi-livedns.tst.sh`) — FR-005
- [ ] T020c prd apex `A` -> prd LB (written by `031` in prd, `<fqdn>` = apex),
      after prd `030`; until then the apex resolves to nothing (measured
      ~19:45Z) — FR-005, FR-012
- [ ] T020d named extra hosts: prd `api.<domain>`, dev `dev.api.<domain>`,
      each its own DNS authorization + certificate + HOSTNAME cert-map entry
      + ACME CNAME + A record, primary certificate untouched; authored and
      applied by the apply lane (owner assignment 2026-09-18) — FR-012
- ~~T020b (if B) Gandi-written records~~ — superseded by option A

## Phase 3: data + registry + image (steps 4–8, US4, US6)

- [x] T030 `040-cloud-sql-postgres` dev (3 resources in state;
      `csi-spl-dev-pg` RUNNABLE db-f1-micro) — FR-006
- [x] T031 `050-gcs-files` dev (bucket `csi-spl-dev-files`) — FR-007
- [x] T032 `028-gcp-artifact-registry` dev (`csi-spl-dev-hub`) — FR-008
- [x] T033 `do_build_push_hub_image` dev (`spool-hub:0.1.0` running;
      `43b9296`) — FR-009
- [x] T034 `do_spl_db_bootstrap` dev (DSN secret v1 enabled; `9f8f492`) — FR-010
- [x] T035 rdb pointer: `csi-spl-rdb/src/sql/postgres/spool-hub/000{1,2,3}_*.sql`
      bundled into the image and applied by `spool migrate` — US6
- [~] T036 prd: 040, 050, 028 applied (state 19:43Z); image, DB bootstrap, after T005 and T012 —
      FR-006..FR-010

## Phase 4: Cloud Run + ingress (steps 9–10, US3, US4)

- [x] T040 `030-cloud-run-hub` dev (6 resources; min = max = 1, cloudsql
      socket) — FR-011
- [~] T041 `031-gcp-hub-ingress` dev apply (applied: 15 in state, cert ACTIVE; `0.0.0.0/0` since `37e2e58`, the documented M1 exception, so `/v1/health` 200 from any IP) after T011 + T013; cnf
      `allowed_ip_ranges` set by the owner; `do_wait_for_cert` ACTIVE;
      `/v1/health` 200 (M1: any IP; from M2: 403 for a non-allowlisted IP) (003 FR-023; a serverless NEG takes no LB health check) — FR-012, SC-004
- [ ] T042 prd `030` + `031` (no apex A record without owner go) — FR-011,
      FR-012

## Phase 5: CI identity (US5)

- [x] T049 Land `017-github-wif-deploy` with a deploy SA it creates and scoped
      grants (`2a7888c`; iac suite 6/6, `validate 017-github-wif-deploy` PASS) — FR-013
- [ ] T050 Apply `017` per env after `028` + `030` (owner go, apply lane); export `GCP_WIF_PROVIDER_<ENV>` /
      `GCP_DEPLOY_SA_EMAIL_<ENV>` as repo variables for `008` — FR-013, SC-005

## Phase 6: remaining copies + hygiene

- [ ] T060 `029-create-gcp-secrets` (no captcha/BIN; M2 payment slots
      empty or omitted) — FR-014
- [ ] T061 `005-gcp-domain-verification` (branch
      `GRK-3341-007-tf-005-domain`, unmerged) — FR-015
- [ ] T062 `003-gcp-iam-users` (not started) — FR-015
- [x] T063 DNS ops `do_export_all_dns_settings`, `do_flush_dns`,
      `do_wait_for_cert`, `do_gandi_*` — FR-017 (`f68affe`, `04f7dca`;
      `dns-ops.tst.sh`, `gandi-livedns.tst.sh` green)
- [x] T064 Hygiene gates: no keys in tf, no store entities in rdb, no baked
      hostname in Go, each with planted-hit controls (`6646f41`; iac + api
      suites green) — FR-018
- [x] T065 Domain single source (`domain-single-source.tst.sh` green) — FR-019

## Phase 7: hub sign-in hooks (from spec `010`, owner of the feature)

Auth stays off until registration (`SPOOL_HUB_AUTH_PROVIDERS` is `""`), so
none of these blocks M1. The feature text is `../010-spool-social-auth/`.

- [ ] T066 (010 T020) render cnf `env.auth.social.env` into `030`
      `environment_variables` and `.secret_env` into
      `secret_environment_variables`
- [ ] T067 (010 T021) empty Secret Manager slots for the auth session key and
      the two client secrets + secretAccessor for the hub runtime SA, per env;
      no version resource (fold into `029`, T060)
- [ ] T068 (010 T022) derive `SPOOL_HUB_AUTH_APP_URL` and the redirect URIs
      from `env.dns.fqdn` in `do_spl_merged_cnf`

## Phase 8: tooling defects found in the audit

- [x] T069 `do_resolve_oap` derives ORG/APP from the directory layout, so
      `do_tpl_gen` and `do_tf_plan` cannot run from a `csi-spl-wt/<ID>`
      worktree even with ORG/APP exported (measured 2026-09-18: `missing
      …/csi-spl-wt-3344-cnf/…/all.env.yaml`); workaround: render in a copy
      laid out as `csi/csi-spl/` — fixed `8dded98`: derives from the project dir's
      own name; `resolve-oap-worktree.tst.sh` asserts both layouts
- [ ] T070 `tf-steps-render-and-validate.tst.sh` SKIPs render drift and
      validate unless tpl-gen and terraform sit under the runner's own
      `$HOME`; the suite reads green without having validated anything

## Phase 9: WUI Hosting seam (from spec `005`, M3)

Routed here by the 005 lane; the script is WUI-hosting code, so it waits for
the WUI code owner to be confirmed before anyone edits it.

- [ ] T071 `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` lacks the
      spec 010 T016 rewrite `/api/v1/auth/**` -> the hub service, before the
      `**` fallback (`grep -c api/v1/auth` on the script -> 0; the checked-in
      lde `csi-spl-wui/firebase.json` has it, `1c4e1a6`)
- [ ] T072 **Decision (007 with 003 / 006), before 005 T009 dev Hosting**: the
      WUI -> hub read path. Same-origin `/v1/**` rewrites through Firebase
      Hosting meet two unverified obstacles: the hub resolves the tenant from
      `Host` (006), and a Hosting rewrite is believed (unchecked) not to
      deliver the tenant host; and the hub's Cloud Run ingress is
      `internal-and-cloud-load-balancing` (FR-011), which is believed
      (unchecked) to refuse Hosting-rewrite traffic. The alternative,
      cross-origin reads from `<tenant>.<fqdn>` via the `031` LB, needs the
      rendered CSP `connect-src` widened and CORS on the hub. Measure both
      before choosing.

## Out of this task list

M2 payment drivers, M3 WUI hosting (`005`), pipeline job design (`008`).

<!-- version: 1.5.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:24:15Z -->
