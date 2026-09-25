# Ad-hoc infrastructure operations of 2026-09-19: harvested into actions

Lane ADHOC-HARVEST (CLE-3381). The owner's rule of 2026-09-19 (CLE-3377 writes
it into the repo CLAUDE.md):

> Nothing in the infrastructure should be run ad hoc. Whenever it is
> executable via Terraform or via some Bash script, we create a Bash script
> and we execute it via Terraform. ... For anything you provision ad hoc,
> there should be a shell action wrapper for that with a proper naming
> convention and the thing should stay in the source code so that next time,
> when we are using it, we will reuse it.

This file lists every infrastructure operation run by hand on 2026-09-19 and
the committed action or terraform step that now does it. Nothing in this lane
ran a mutating action. The agents' scratch files were not deleted; section 3
lists them.

## 1. How the list was made

Sources:

- The scratch scripts agents left outside the repo: `find
  /var/tmp/claude/msgs -maxdepth 4 \( -name '*.sh' -o -name '*.py' \)
  -newermt 2026-09-19`. `/var/tmp/*.sh|py` has nothing from 2026-09-19. The
  newest file there is from 2026-09-17.
- The agents' reports: every file modified on 2026-09-19 under
  `outbox/` and `archive/` of CLE-3338..CLE-3380 and GRK-3358..GRK-3364. I
  kept the reports that name gcloud, gsutil, terraform, psql, pg_dump,
  firebase, a mutating curl, a secret copy, a key mint or a `state rm`.

Evidence paths below are relative to `/var/tmp/claude/msgs/`. "make" means
the committed `make do-tf-plan` / `do-provision` / `do-deprovision` path in
the tf-runner container. That path is not ad hoc, so it is listed only where
a scratch script drove it.

### 1.1 Identity every new action uses

Every new action runs as the env's project service account. The key is
`$HOME/.gcp/.<org>/key-<project>.json`. It is activated in a private
`CLOUDSDK_CONFIG` that is removed afterwards, and every gcloud call passes
`--account`. The owner account is never used. The mechanism is cc7f79f
(CLE-3377's `do_gcp_sa_key_file` / `do_gcp_activate_sa_key` /
`do_gcp_pin_account`), reused here, not duplicated:

- iac: `_gcp_env_sa <project>`, in `gcp-copy-secret.func.sh`, activates
  `<project>`'s key through those helpers.
- orc: the DB actions call `do_gcp_pin_account`. Two new helpers in
  `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` carry the hub DB login.
  `spl_via_proxy` runs a command against the hub DB through the Cloud SQL
  proxy, with the DSN in its environment. `spl_pg_env` passes the login to
  psql in `PG*` env vars, never in an argv that `ps` shows.

cc7f79f made every existing `do_spl_*` cloud action resolve the SA key by
default. The agents' "run as the key" wrappers (`run-as-key.sh`,
`sa-migrate.sh`, `prd-tenant-create.sh`) are therefore now unnecessary:
the plain action does the same thing.

To read another project's data, such as a csi-rel secret, an action uses
that project's own key. Every mutating action is a dry run unless
`DRY_RUN=0`. Secret values are never printed.

## 2. Operations, and what now does them

Status values:

- **harvested**: a new action was added in this lane.
- **existing**: a committed action already did it. The row cites that action.
- **terraform**: a terraform step owns the thing, so the fix is a cnf change
  plus `make do-provision`, not a new script.
- **fixed**: a committed action was broken, which forced the hand run. It is
  now repaired.
- **reported**: this lane added no action, and the row says why.

| # | operation | who | evidence | action / step | status |
|---|---|---|---|---|---|
| 1 | dev 031 `state rm` of `hub["dev."]`, `hub["*.dev."]`, `acme_challenge[0]`, by raw `docker exec` into tf-runner | CLE-3354 | `CLE-3354/outbox/20260919T125044Z…re-3355-11daedb.md`: "state rm … (direct tf-runner exec…)"; `make do-tf-state-remove` died on "tf_proj: unbound variable" | `ENV=dev STEP=031-gcp-hub-ingress TARGET='<addr>,<addr>' make do-tf-state-remove` (do_tf_state_remove; do_tf_replace_target had the same bug) | **fixed** 1ae4f72; test `tf-actions-tf-proj-after-init.tst.sh` |
| 2 | 3 record sets deleted from the prd apex zone, raw gcloud as the prd SA | CLE-3354 | same file: "those 3 records deleted from the prd apex zone with the prd key" | the records belong to 025 / 031 | **terraform**, reported. The hosting lane (019/025/031, CLE-3354) is frozen until the owner's architecture decision, so I added no DNS-delete script |
| 3 | dev 031 state backup and `state cat` | CLE-3354 | re-3355-11daedb.md: "backup (…/CLE-3354/state-backup, 0600)" | `do_gcp_backup_env` (state/), `make do-tf-state-pull` / do_tf_state_show | **harvested** 071f750 + **existing** |
| 4 | local `firebase deploy --only hosting` of the WUI to csi-spl-dev-site | CLE-3354 | `CLE-3354/wui-deploy.sh`; outbox dev-016-019-applied-wui-live.md | none: hosting lane | **reported**, frozen lane (CLE-3354) |
| 5 | the same for prd, from a `git archive` of trunk 77672f9 | CLE-3354 | `CLE-3354/wui-deploy-export.sh`; outbox prd-wui-live.md | none: hosting lane | **reported**, frozen lane (CLE-3354) |
| 6 | host terraform plan of dev 016 (failed at backend init, nothing written) | CLE-3354 | `CLE-3354/hosting-dev.sh.RETIRED-host-terraform`; hosting-no-host-tf-disclosure…md | `make do-tf-plan` (tf-runner) | **reported**: host terraform is forbidden, and the committed path exists |
| 7 | read-only owner-account reads: project IAM policy, Firebase sites, tfstate prefixes | CLE-3354 | hosting-no-host-tf-disclosure…md: "--account=<owner> …" | `do_gcp_audit_iam`, `do_gcp_backup_env` (as the SA) | **harvested** 071f750 |
| 8 | apply 016 + 019, dev and prd | CLE-3354 | dev-016-019-applied-wui-live.md | make | **existing** |
| 9 | apply dev 025; partial dev 031 | CLE-3354 | re-3355-11daedb.md | make | **existing** |
| 10 | read-only reads of csi-rel GCP (LB, url maps, record sets), for the comparison | CLE-3354 | `CLE-3355/archive/20260919T131405Z…` | `do_gcp_compute_lb_list`, `do_gcp_export_dns` (ported csi-rel actions), run from the csi-rel tree | **existing** |
| 11 | gcp-002/003/004: SAs, one key each, roles/owner, cloudresourcemanager API | CLE-3355 | bootstrap-done-keys-minted…md | `do_gcp_002_*`, `do_gcp_003_*`, `do_gcp_004_*` | **existing**. The owner account is allowed for gcp-000..004 only |
| 12 | Cloud Run rolled to image 0.1.4 with raw `gcloud run services update --image`, dev + prd | CLE-3355 | latest-hub-deployed-local-then-gh.md | 030 owns the image: bump `hub.image.tag` in cnf, commit, `do_build_push_hub_image`, `make do-provision STEP=030-cloud-run-hub` (or `do_tf_sweep_steps STEPS=030-cloud-run-hub DRY_RUN=0`) | **terraform**. No script: an update outside 030 is drift that the next 030 apply reverts |
| 13 | the same for 0.1.5 (b5cf54f) | CLE-3355 | ack-031-hold.md | as row 12 | **terraform** |
| 14 | hub image built and pushed from a checkout with an uncommitted cnf tag bump | CLE-3355 | ack-no-adhoc…md | `do_build_push_hub_image` | **existing**. The gap was the uncommitted bump: commit the tag first |
| 15 | dev 030 partial destroy, then healed by re-apply | CLE-3355 | STOP-destroy-030-dev…md | make; now `do_tf_deprovision_steps` | **existing** + **harvested** |
| 16 | re-apply sweep: plan, gate, provision per step (017, 030, …) | CLE-3355 | `CLE-3355/tools/sweep.sh`; tools/sweep-20260919T091203Z.log | `do_tf_sweep_steps` (orc) | **harvested** 071f750 |
| 17 | 120 applied, later destroyed | CLE-3355 | tools/sweep-…095808Z.log, tools/destroy-20260919T103726Z.log | `do_tf_sweep_steps`, `do_tf_deprovision_steps` | **harvested** 071f750 |
| 18 | 050 files bucket destroyed and re-created; 030 re-applied | CLE-3355 | `CLE-3355/tools/destroy.sh`; destroy-20260919T103726Z.log | `do_tf_deprovision_steps`, `do_tf_sweep_steps` | **harvested** 071f750 |
| 19 | dev 030 applied twice (wui-key slot, SM key inject) | CLE-3355 | dev-030-applied-*.md | make | **existing** |
| 20 | auth secret versions (session key, Google client secret) | CLE-3355 | ack-no-backups.md | `do_spl_auth_secrets_seed` (b3528d6) | **existing** |
| 21 | dev tenant t1 created | CLE-3355 | ack-sa-only…md | `do_spl_tenant_create`, which runs as the SA since cc7f79f | **existing** |
| 22 | pre-destroy backup: tf state, secret values to 0600 files, DNS zones, relay + files buckets, registry tags, pg_dump through the proxy, restore check into lde | CLE-3355 | `CLE-3355/tools/backup.sh`; backups-done.md | `do_gcp_backup_env` (iac) | **harvested** 071f750 |
| 23 | IAM dumps (before / after) and their analysis | CLE-3355 | `CLE-3355/tools/iam-audit.sh`, `tools/iam-analyze.py` | `do_gcp_audit_iam` (iac) + `csi-spl-iac/src/bash/scripts/iam-analyze.py`, with SA ids read from cnf | **harvested** 071f750 |
| 24 | read-only `gcloud secrets list`, revisions, logs | CLE-3355 | re-030-import.md | `do_gcp_audit_iam`, `do_gcp_tail_logs`, `do_check_hub_deploy` | **harvested** + **existing** |
| 25 | owner-account reads that failed on reauth | CLE-3355, CLE-3354 | BLOCKED-gcloud-reauth.md | as row 24, as the SA | **harvested** |
| 26 | host terraform: an offline plan of dev 017 | CLE-3355 | ack-no-host-terraform.md | `make do-tf-plan` | **reported**: host terraform is forbidden |
| 27 | importer dry run, dev 040 | CLE-3355 | re-020-040-importer-settle.md | `do_tf_import_existing` | **existing** |
| 28 | csi-rel-prd/csi-rel-smtp-pass copied into a new version of csi-spl-prd/csi-spl-hub-mail-smtp-password | CLE-3373 | `CLE-3373/copy-smtp-secret.sh`; prd-native-on-probe.md | `ENV=prd SRC_PROJECT=csi-rel-prd SRC_SECRET=csi-rel-smtp-pass TGT_SECRET=csi-spl-hub-mail-smtp-password DRY_RUN=0 ./run -a do_gcp_copy_secret` (iac). Each side runs as its own project's SA; the value goes over a pipe only; checked by sha256 | **harvested** 071f750 |
| 29 | prd tenant t1 created, wrapped to run as the prd SA | CLE-3373 | `CLE-3373/prd-tenant-create.sh`; prd-tenant-t1-created…md | `ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_tenant_create`, which runs as the prd SA since cc7f79f | **existing**. The wrapper is not needed any more |
| 30 | owner invite for t1, dev + prd (`spool hub-invite` over the proxy) | CLE-3373 | `CLE-3373/t1-owner.sh`, `CLE-3373/prd-hub-invite.sh`; status-owner-seat…md | `ENV=<env> TENANT_ID=t1 INVITE_EMAIL=<owner-email> INVITE_ROLE=owner DRY_RUN=0 ./run -a do_spl_hub_invite` (orc) | **harvested** 071f750 |
| 31 | hand `UPDATE tenant_memberships SET role='member'` for the dev bootstrap owner HUM-4 | CLE-3373 | t1-owner.sh; status-owner-seat…md: "-> UPDATE 1" | `ENV=dev TENANT_ID=t1 HUMAN_ID=HUM-4 MEMBER_ROLE=member FROM_ROLE=owner DRY_RUN=0 ./run -a do_spl_tenant_member_role` (orc). Values go in as psql variables; exactly one row must change or the change is rolled back | **harvested** 071f750 |
| 32 | box-wui SM keys minted, t1 pinned, dev + prd | CLE-3373 | FINAL.md; `CLE-3373/run-as-key.sh` | `do_spl_wui_key_seed`, `do_spl_cloud_pin_box_wui`, which run as the SA since cc7f79f | **existing** |
| 33 | prd 030 applied 4 times | CLE-3373 | FINAL.md | make | **existing** |
| 34 | a test `POST /api/v1/auth/register` on prd with the owner's address, by raw curl | CLE-3373 | prd-native-on-probe.md | the relay is proven by `do_spl_mail_secret_seed SMTP_TEST_RCPT=…` | **reported**: an app-level probe, not infra. Do not repeat it on prd |
| 35 | Cloud Run log read for the mail component | CLE-3373 | `CLE-3373/prd-mail-log.sh` | `ENV=prd FILTER='resource.labels.service_name="<svc>"' FRESHNESS=1h ./run -a do_gcp_tail_logs` | **existing** |
| 36 | migrations 0011 + 0012, dev + prd, wrapped to run as the SA | CLE-3376 | `CLE-3376/sa-migrate.sh`; sa-key-ack-and-0012-applied.md | `ENV=<env> DRY_RUN=0 ./run -a do_spl_db_bootstrap`, which runs as the SA since cc7f79f | **existing**. The wrapper is not needed any more |
| 37 | a migrate attempt as the owner account (failed, nothing touched) | CLE-3376 | same file | as row 36 | **existing** (cc7f79f) |
| 38 | `\d tenants` and the migrations table through the proxy | CLE-3376 | `CLE-3376/d-tenants.sh` | `ENV=<env> SQL='\d tenants' ./run -a do_spl_db_query` (orc). One statement per run, inside `BEGIN READ ONLY … ROLLBACK` | **harvested** 071f750 |
| 39 | M3 e2e runs on dev (pins, native account, invite) | CLE-3372 | final-m3-e2e-dev.md | `do_spl_m3_e2e` (260aec3, d97bdad) | **existing** |
| 40 | hand SQL read of tenant_memberships through the proxy | CLE-3372 | t1-bootstrap-owner-taken-by-e2e.md | `do_spl_db_query` | **harvested** 071f750 |
| 41 | `make do-tf-plan` over all 13 steps × 2 envs | CLE-3356 | `CLE-3356/outbox/.plan-all.sh` | `do_tf_sweep_steps` (DRY_RUN=1 default, STEPS defaults to every step) | **harvested** 071f750 |

These were proposed but never run: the dev 019 site delete + `state rm`
(cancelled by the owner), and a zone-scoped `dns.admin` grant.

### 2.1 Found while harvesting, fixed later (CLE-3400, T081/T082)

- `do_gcp_list_secrets` only echoed its commands and ran none (a verbatim
  csi-rel port). Fixed in both repos (csi-rel adc94650, the files are
  byte-identical): it lists each env as that env's own project SA, names and
  metadata only, never `versions access`.
- `do_tf_state_remove` ran `state rm -lock=false` with no state backup.
  Fixed in both repos: `state pull` to a timestamped 0600 backup first (a
  failed or empty pull aborts), the lock is kept unless `FORCE=1`, and it is a
  dry run unless `DRY_RUN=0`.

## 3. The scratch files, which were left in place

| file | what it did | now |
|---|---|---|
| `CLE-3355/tools/backup.sh` | row 22 | `do_gcp_backup_env` |
| `CLE-3355/tools/iam-audit.sh`, `iam-analyze.py` | row 23 | `do_gcp_audit_iam` + `src/bash/scripts/iam-analyze.py` |
| `CLE-3355/tools/sweep.sh` | rows 16-18 | `do_tf_sweep_steps` |
| `CLE-3355/tools/destroy.sh` | rows 17-18 | `do_tf_deprovision_steps` |
| `CLE-3355/tools/push-loop.sh` | git land loop, not infra | none needed |
| `CLE-3356/outbox/.plan-all.sh` | row 41 | `do_tf_sweep_steps` |
| `CLE-3373/copy-smtp-secret.sh` | row 28 | `do_gcp_copy_secret` |
| `CLE-3373/prd-tenant-create.sh`, `run-as-key.sh` | rows 29, 32 | the plain actions (cc7f79f) |
| `CLE-3373/prd-hub-invite.sh`, `t1-owner.sh` | rows 30, 31 | `do_spl_hub_invite`, `do_spl_tenant_member_role`, `do_spl_db_query` |
| `CLE-3373/prd-mail-log.sh` | row 35 | `do_gcp_tail_logs` |
| `CLE-3376/sa-migrate.sh` | row 36 | `do_spl_db_bootstrap` (cc7f79f) |
| `CLE-3376/d-tenants.sh` | row 38 | `do_spl_db_query` |
| `CLE-3354/wui-deploy.sh`, `wui-deploy-export.sh`, `hosting-dev.sh.RETIRED-host-terraform` | rows 4-6 | frozen hosting lane |
| `CLE-3354/state-backup/` (0600) | row 3 | `do_gcp_backup_env` |
| `CLE-3353/land.sh`, `CLE-3354/land.sh`, `CLE-3375/land.sh` | git land helpers, not infra | none needed |

## 4. Tests

- `csi-spl-iac/src/bash/tests/adhoc-harvest-gcp-actions.tst.sh` covers
  `_gcp_env_sa`, do_gcp_copy_secret, do_gcp_audit_iam,
  do_gcp_backup_env and iam-analyze.py, with gcloud stubbed. It checks four
  things: the identity is the SA, the gcloud config is private, no secret
  value reaches the output or argv, and no mutating verb runs in a read-only
  action.
- `csi-spl-iac/src/bash/tests/tf-actions-tf-proj-after-init.tst.sh` covers
  row 1.
- `csi-spl-orc/src/bash/tests/adhoc-harvest-actions.tst.sh` covers
  the SA identity of the DB actions, do_spl_hub_invite,
  do_spl_tenant_member_role, do_spl_db_query, do_tf_sweep_steps and
  do_tf_deprovision_steps. gcloud, psql, spool and make are stubbed.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:24:52Z -->
