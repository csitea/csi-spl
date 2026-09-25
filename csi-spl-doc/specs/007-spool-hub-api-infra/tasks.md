# Tasks: spool hub cloud estate (iac)

**Feature**: `specs/007-spool-hub-api-infra` · **Spec**: `./spec.md` ·
**Order**: `./contracts/provisioning-order.md`

Status per task: `[x]` Implemented (verified, citation given) · `[~]`
Partial · `[ ]` Planned · `[-]` Superseded. Every apply below needs an
explicit owner go. Verified 2026-09-18 ~19:15Z on trunk `bbc41e7` (spec §1.1);
synced against the repo 2026-09-25 on trunk `e795f61f` (no GCP query).

**Superseded 2026-09-19: LB removed.** The `031-gcp-hub-ingress` load
balancer was deprovisioned in dev + prd and its step removed (`70b84824`); the
hub is reached on `032` Cloud Run domain mappings (`510c0b2d`). Tasks that
only served the LB are marked `[-]` and kept as the audit trail.

## Phase 0: lde (US1)

- [x] T001 Compose `docker-compose-{api,infra,rdb,tf-infra,wui}.yaml` + hub
      Dockerfile in `csi-spl-orc/src/docker/` — FR-016 (`ls csi-spl-orc/src/docker`)
- [x] T002 `do_gen_docker_env`, `make do-setup-app-inf`, teardown —
      FR-016 (`lde-stack.tst.sh` green; orc suite green, 56 test files)
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
- [-] T011 `031` writes records into the `025` zone — **Superseded**
      (`70b84824`). Now: `025/04-cloud-run-mapping-records.tf` writes the
      `032` mapping records; dev has its own subzone `spool-hub-dev`,
      delegated from the apex zone (`025/03-dns-zone.tf:44,55`) — FR-004
- [x] T012 prd plan of `025` shows 1 import, 0 add, 0 destroy; owner applies;
      `terraform state list` shows the zone; NS unchanged — FR-004 (applied
      19:14Z by the apply lane: 1 in state, NS unchanged; code `9ed50ac`)
- [x] T013 **Owner decision: option A** (hand off), confirmed 2026-09-18
      ~19:46Z; the owner set the registrar NS. The **apex points at the hub
      LB**, not Gandi parking — FR-005
- [x] T020a NS -> `ns-cloud-e1..e4` (`dig +norec NS … @v0n1.nic.ai` ->
      ns-cloud-e*, ~19:45Z); `do_gandi_set_nameservers` accepts ns-cloud-* and
      applies with `CONFIRM=yes` (`1b78621`, `gandi-livedns.tst.sh`) — FR-005
- [-] T020c prd apex `A` -> prd LB — **Superseded** (`70b84824`): the apex
      is now the `019` Firebase custom domain (`bind_custom_domain: true`)
- [-] T020d named extra hosts on the LB — **Superseded**: `api.<domain>` /
      `dev.api.<domain>` are `032` domain mappings of `env.dns.api_fqdn`
      (`510c0b2d`) — FR-034
- ~~T020b (if B) Gandi-written records~~ — superseded by option A

## Phase 3: data + registry + image (steps 4–8, US4, US6)

- [x] T030 `040-cloud-sql-postgres` dev (3 resources in state;
      `csi-spl-dev-pg` RUNNABLE db-f1-micro) — FR-006
- [x] T031 `050-gcs-files` dev (bucket `csi-spl-dev-files`) — FR-007
- [x] T032 `028-gcp-artifact-registry` dev (`csi-spl-dev-hub`) — FR-008
- [x] T033 `do_build_push_hub_image` dev (first `spool-hub:0.1.0`,
      `43b9296`; cnf `hub.image.tag: "0.5.7"` dev + prd today) — FR-009
- [x] T034 `do_spl_db_bootstrap` dev (DSN secret v1 enabled; `9f8f492`) — FR-010
- [x] T035 rdb pointer: `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_*.sql`
      (43 files, last `0043_…`) bundled into the image and applied by
      `spool migrate` — US6
- [x] T036 prd: 040, 050, 028 applied (state 19:43Z); image and DB bootstrap
      done — FR-006..FR-010. Restamped 2026-09-19 (C7): the prd hub runs the
      image and answers, which it cannot without its DSN. Check: `curl -s
      https://spool-hub.ai/version` -> `{"commit":"c972f24…"}` (n=1, 05:44Z)

## Phase 4: Cloud Run + ingress (US3, US4)

- [x] T040 `030-cloud-run-hub` dev (6 resources; min = max = 1, cloudsql
      socket) — FR-011
- [-] T041 **Superseded** (`70b84824`, LB removed). Was: `031-gcp-hub-ingress` dev apply (applied: 15 in state, cert ACTIVE; `0.0.0.0/0` since `37e2e58`, the documented M1 exception, so `/v1/health` 200 from any IP) after T011 + T013; cnf
      `allowed_ip_ranges` set by the owner; `do_wait_for_cert` ACTIVE;
      `/v1/health` 200 (M1: any IP; from M2: 403 for a non-allowlisted IP) (003 FR-023; a serverless NEG takes no LB health check) — FR-012, SC-004
- [x] T042 prd `030` applied — FR-011 (restamped 2026-09-19, C7: prd
      `/version` answered). The `031` half is **Superseded** (`70b84824`)
- [x] T043 `005-gcp-domain-verification` + `032-gcp-cloud-run-domain-mapping`
      (csi-rel's steps unchanged), `ingress: all`, `do_spl_domain_verify`,
      `do_spl_wait_for_mapping_cert`, `do_spl_lb_absent_check` — FR-034
      (`510c0b2d`, `70b84824`: "lists 0 of 13 LB kinds in dev and prd")

## Phase 5: CI identity (US5)

- [x] T049 Land `017-github-wif-deploy` with a deploy SA it creates and scoped
      grants (`2a7888c`; `validate 017-github-wif-deploy` PASS) — FR-013
- [~] T050 Apply `017` per env after `028` + `030` — FR-013, SC-005. **Applied** dev + prd 2026-09-19 through
      `make do-provision` on the project key (7 added each; CLE-3355). The WIF variable export is superseded:
      the owner chose project-key auth for CI (GitHub secret `GCP_KEY_CSI_SPL_<ENV>`, tf 120); WIF stays the
      alternative. Check: `ENV=dev STEP=017-github-wif-deploy make do-tf-plan` -> No changes.

## Phase 6: remaining copies + hygiene

- [x] T060 Secret Manager slots — FR-014. Implemented inside `030`
      (`030/06-auth-secret-slots.tf`, `19914c18`): empty slots, no version
      resource; no separate `029-create-gcp-secrets` step is needed
- [x] T061 `005-gcp-domain-verification` on trunk (`510c0b2d`) — FR-015
- [ ] T062 `003-gcp-iam-users` (not started; no dir) — FR-015
- [x] T063 DNS ops `do_export_all_dns_settings`, `do_flush_dns`,
      `do_wait_for_cert` (031-era, see T090), `do_gandi_*` — FR-017 (`f68affe`, `04f7dca`;
      `dns-ops.tst.sh`, `gandi-livedns.tst.sh` green)
- [x] T064 Hygiene gates: no keys in tf, no store entities in rdb, no baked
      hostname in Go, each with planted-hit controls (`6646f41`; iac + api
      suites green) — FR-018
- [x] T065 Domain single source (`domain-single-source.tst.sh` green) — FR-019

## Phase 7: hub sign-in hooks (from spec `010`, owner of the feature)

Auth stays off until registration (`SPOOL_HUB_AUTH_PROVIDERS` is `""`), so
none of these blocks M1. The feature text is `../010-spool-social-auth/`.

- [x] T066 (010 T020) cnf auth env rendered into `030`: `dynamic "env"` +
      `secret_key_ref` (`030/04-cloud-run-service.tf:82-95`, `19914c18`)
- [x] T067 (010 T021) empty auth secret slots + per-secret accessor for the
      hub runtime SA, no version resource (`030/06-auth-secret-slots.tf`,
      `19914c18`)
- [x] T068 (010 T022) derive `SPOOL_HUB_AUTH_APP_URL` and the redirect URIs
      from `env.dns.fqdn` in `do_spl_merged_cnf` — Implemented (`86759b2`);
      check: `bash csi-spl-iac/src/bash/tests/auth-urls-from-fqdn.tst.sh`

## Phase 8: tooling defects found in the audit

- [x] T069 `do_resolve_oap` derives ORG/APP from the directory layout, so
      `do_tpl_gen` and `do_tf_plan` cannot run from a `csi-spl-wt/<ID>`
      worktree even with ORG/APP exported (measured 2026-09-18: `missing
      …/csi-spl-wt-3344-cnf/…/all.env.yaml`); workaround: render in a copy
      laid out as `csi/csi-spl/` — fixed `8dded98`: derives from the project dir's
      own name; `resolve-oap-worktree.tst.sh` asserts both layouts
- [x] T070 `tf-steps-render-and-validate.tst.sh` SKIPped render drift and
      validate unless tpl-gen and terraform sat under the runner's own
      `$HOME`; the suite read green without having validated anything
      (measured 2026-09-19 from a worktree: `SKIP: no tpl-gen venv` +
      `PASS: all`). Fixed: tpl-gen is also found beside the main checkout
      (`--git-common-dir`), terraform via `TF_BIN` / `$HOME` / PATH, a SKIP
      is a FAIL unless `SPL_TF_ALLOW_SKIP=1` (then `PARTIAL`, never `all`),
      and a planted undeclared reference in a copy of 016 MUST fail validate.
      Check: `bash csi-spl-iac/src/bash/tests/tf-steps-render-and-validate.tst.sh`
      (box user) -> `24 files rendered` x2, `PASS: control: validate rejects a
      planted undeclared reference`; control of the control:
      `TF_BIN=/bin/true bash …` -> `FAIL: control: validate accepted`

## Phase 9: WUI Hosting seam (from spec `005`, M3)

Routed here by the 005 lane; the script is WUI-hosting code, so it waits for
the WUI code owner to be confirmed before anyone edits it.

- [x] T071 `csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` lacked the
      spec 010 T016 rewrite `/api/v1/auth/**` -> the hub service — fixed by
      `1dbc29a` (the task was stale, C7). Since the LB removal (`70b84824`) this
      rewrite is the live path for `/api/v1/auth/**` on the `019` custom
      domain (spec §3). Check: `command grep -c api/v1/auth
      csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh` -> `2`
- [-] T072 **Superseded** (`70b84824`; OQ-H1 closure is an owner question,
      spec §7). Was: **Decided as OQ-H1 (spec §3), default (a) implemented on dev:** the
      `031` LB path matcher (hub paths -> hub, the rest -> the `019` site via an
      internet NEG); Hosting rewrites rejected (no WebSocket, no tenant Host,
      no wildcard custom domain, ingress). Open only for the owner's answer
      and the prd flag. Check: `bash csi-spl-iac/src/bash/tests/wui-hosting-019-031.tst.sh`
      -> `PASS: all`. The question as first written: the
      WUI -> hub read path. Same-origin `/v1/**` rewrites through Firebase
      Hosting meet two unverified obstacles: the hub resolves the tenant from
      `Host` (006), and a Hosting rewrite is believed (unchecked) not to
      deliver the tenant host; and the hub's Cloud Run ingress is
      `internal-and-cloud-load-balancing` (FR-011), which is believed
      (unchecked) to refuse Hosting-rewrite traffic. The alternative,
      cross-origin reads from `<tenant>.<fqdn>` via the `031` LB, needs the
      rendered CSP `connect-src` widened and CORS on the hub. Measure both
      before choosing.

## Phase 10: WUI Hosting estate (M3 HOSTING lane, spec §3)

Every apply here waits on an owner GCP re-auth (2026-09-19: `gcloud …
--account=<owner>` -> "Reauthentication failed", ADC expired, no
`firebase login`).

- [x] T073 `30_wui-build-deploy.yml`: WUI unit + typecheck, `nuxt generate`
      per env with cnf values, render `firebase.json`, WIF auth as the `016`
      SA, `firebase deploy --only hosting`, probe `build.json` commit on
      `<site>.web.app` and (route on) `https://<fqdn>/` + the hub `/version`;
      deploy jobs skip while `GCP_WIF_PROVIDER_<ENV>` /
      `GCP_FIREBASE_DEPLOY_SA_EMAIL_<ENV>` are unset — FR-024. Check:
      `command grep -lE 'firebase|nuxt generate' .github/workflows/*.yml` ->
      `30_wui-build-deploy.yml`
- [x] T074a Code: `016` WIF binding behind `bind_github_wif`, `019` custom
      domain behind `bind_custom_domain`, `031` WUI route behind
      `wui_origin_host` and L7 rules behind `l7_narrowing`, cnf dev on / prd
      off, tfvars rendered — FR-020..FR-023. Check at the
      time: iac suite `12/12`. The `031` halves are **Superseded**
      (`70b84824`); `019 bind_custom_domain` is now `true` in both envs
- [x] T074 dev `016` then `019` (owner go 2026-09-19, relayed by the WUI
      orchestrator), through `make do-tf-plan` / `do-provision` (tf-runner,
      project key, `3bb310c`), then a local WUI deploy on the key
      (`firebase deploy --only hosting`, trunk `1f7329d`), 2026-09-19 ~09:02Z, n=1:
      016 plan `4 to add, 0 to change, 0 to destroy` -> `Apply complete! Resources:
      4 added` (`csi-spl-dev-fb-deploy@…`); 019 plan `4 to add` (services x2,
      firebase_project, site; 0 custom domains) -> `4 added`. Check:
      `curl -sI https://csi-spl-dev-site.web.app/ | head -1` -> `HTTP/2 200`
      (was 404); `curl -s https://csi-spl-dev-site.web.app/build.json` ->
      `{"commit":"1f7329d…"}`
- [ ] T075 (no owner go for prd yet) Apply `016` then `019` on prd; same probe on `csi-spl-prd-site`
- [-] T076 **Superseded** (`70b84824`). Was: dev `031` apply (WUI route + stage-1 Armor); verify
      `https://dev.<domain>/` and `https://t1.dev.<domain>/` -> `200` (WUI),
      `/version` -> `200` (hub), a WS upgrade to `/v1/ws` -> `101`, and the §4
      controls -> `403`
- [-] T077 **Superseded** (`70b84824`; OQ-H2 closure is spec §7). Was: prd Cloud Armor stage 1
- [ ] T078 (WIF alternative only; the key path of T080 does not need it) After `017` is applied per env: `bind_github_wif: true`, re-apply
      `016`, set repo variables `GCP_FIREBASE_DEPLOY_SA_EMAIL_<ENV>` (016 output
      `firebase_deploy_sa_email`) beside 017's `GCP_WIF_PROVIDER_<ENV>`
- [x] T080 Owner direction 2026-09-19: `30_wui-build-deploy.yml` authenticates
      with `credentials_json` from secret `GCP_KEY_CSI_SPL_<ENV>` (iac `120`,
      never `gh secret set` by hand), WIF kept as the alternative; `plan` reads
      only a boolean of the secret; no other secret is read — FR-024. Check:
      `bash csi-spl-iac/src/bash/tests/wui-hosting-019-031.tst.sh` -> `PASS:
      workflow reads no secret but GCP_KEY_CSI_SPL_<ENV>`; control: a planted
      `${{ secrets.FOO }}` in a copy -> reported as `secrets.FOO`
- [-] T079 **Superseded** (`70b84824`). Was: prd WUI route (OQ-H1, owner): `wui_origin_host:
      csi-spl-prd-site.web.app`, render, plan (`031`: NEG + backend + url map),
      apply

- [x] T081 (CLE-3400, owner 2026-09-19) `do_gcp_list_secrets` really lists:
      each env as its own project SA (key via
      `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` in a throwaway `CLOUDSDK_CONFIG`,
      `--account` + `--project`), names and metadata only. Same file in csi-rel
      (adc94650). Check: `bash csi-spl-iac/src/bash/tests/gcp-list-secrets.tst.sh`
      -> `PASS: all`; control: no key -> refused, gcloud never called
- [x] T082 (CLE-3400) `do_tf_state_remove`: `state pull` to a timestamped 0600
      backup under `TF_STATE_BACKUP_DIR` (default `csi-spl-iac/dat/tf-state-backup`)
      first, lock kept unless `FORCE=1`, dry run unless `DRY_RUN=0` (both pass
      through `make do-tf-state-remove`). Check:
      `bash csi-spl-iac/src/bash/tests/tf-state-remove-backup.tst.sh` -> `PASS: all`;
      control: a failing or empty pull aborts before any `state rm`

## Phase 11: sync 2026-09-25 (repo audit, no GCP query)

- [x] T083 `045-gcs-db-backups` + daily `45_db-backup.yml` (spec `029`) —
      FR-035 (`802e26fe`, `4ba27507`)
- [x] T084 `22_deploy-verify.yml` post-deploy HTTPS smoke (spec `008`
      FR-P12) — FR-036 (`0d2155d0`)
- [x] T085 `00_deploy-lag-watch.yml`: hourly, flags an env that runs other
      than the cnf image — FR-030 (`9a34a0ae`)
- [-] T086 `40_tenant-host-reconcile.yml` (spec `024`) — **Superseded** by
      `026`; header: "PAUSED … the workflow is disabled"; deletion is spec §7 Q1 — FR-037
- [x] T087 R1/R8 per-env SA only: `do_gcp_pin_account`
      (`csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh`),
      `gcloud-account-pinned.tst.sh`, `tf-init-project-key.tst.sh` — FR-025, FR-032
- [x] T088 R3 make + tf-runner path (`csi-spl-orc/src/make/tf-tasks.func.mk:10,45,87`,
      `docker-compose-tf-infra.yaml`) — FR-027
- [x] T089 R7 ordered teardown `do_tf_deprovision_steps`
      (`csi-spl-orc/src/bash/run/tf-deprovision-steps.func.sh`); R9 harvest
      (`adhoc-harvest-gcp-actions.tst.sh`) — FR-031, FR-033
- [ ] T090 Retire or rewrite the 031-era `do_wait_for_cert`: it still polls
      the removed Certificate Manager cert (`grep -c certificate-manager
      csi-spl-orc/src/bash/run/wait-for-cert.func.sh` -> 2);
      `do_spl_wait_for_mapping_cert` is its `032` replacement. orc code
      change, owner of `csi-spl-orc` — FR-017. **Planned**
- [ ] T091 Re-measure per-step state on dev + prd as the env SA
      (`make do-tf-plan` per step -> "No changes") — SC-003. **Planned**

## Out of this task list

M2 payment drivers, the WUI app (`005`; its hosting is Phase 10), hub pipeline job design (`008`).

<!-- version: 1.7.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:24:52Z -->
