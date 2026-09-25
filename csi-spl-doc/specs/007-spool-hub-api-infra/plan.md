# Implementation Plan: spool hub cloud estate (iac)

**Feature ID**: `007-spool-hub-api-infra` · **Status**: Partial · **Date**: 2026-09-18 (redo), synced 2026-09-25

**Spec**: `./spec.md` · **Contract**: `./contracts/provisioning-order.md` ·
**Narrative**: `../../doc/md/SPEC-spool-hub-api-infra.md` · **Index**: `../README.md`

## Summary

Host the spool hub on GCP the way csi-rel hosts its API, without the shop and
**without a load balancer** (owner 2026-09-19, "exactly csi-rel: no load
balancer"): Cloud Run `030` with `ingress: all`, reached on `032` Cloud Run
domain mappings after `005` domain verification; the WUI on Firebase Hosting
`019` with the env FQDN as custom domain and a `/api/v1/auth/**` rewrite to
the hub. The `031` LB was deprovisioned and removed (`70b84824`).

Work left: `003-gcp-iam-users`; retire the 031-era `do_wait_for_cert` (T090);
a fresh per-step state re-measure on both envs (T091); the owner questions
in spec §7.

## Technical Context

- **Repo trees**: `csi-spl-iac` (terraform steps + `./run` `do_tf_*`,
  `do_provision`, `do_tpl_gen`), `csi-spl-cnf` (`csi-spl/<env>.env.yaml` ->
  rendered `<env>/tf/*.tfvars`), `csi-spl-orc` (lde, `make do-tf-plan` /
  `do-provision` via tf-runner, image build, DB bootstrap, DNS ops),
  `csi-spl-rdb` (spool DDL), `csi-spl-api` (Go hub).
- **References, read-only**: `csi-rel-{iac,orc,cnf}`, `pas-psf-{iac,orc,cnf}`.
- **Terraform** pinned `1.9.8` (`env.versions.terraform_version`), provider
  `google ~> 6.0`, GCS backend per env.
- **Region** `europe-north1`; projects `csi-spl-dev`, `csi-spl-prd`.

## Constitution check

- Nothing mutates GCP without the owner: apply exists only behind
  `make do-provision` in tf-runner, run on the owner's go; orc cloud actions
  are `DRY_RUN=1` by default.
- Every gcloud call carries `--account` and runs as the per-env project SA;
  the shared gcloud config is never changed.
- No key in git, tf state or log (040 holds no user/password/version; the CI
  key reaches GitHub only through step `120`; 017 WIF needs no key).
- The domain lives only in `env.dns.BASE_DOMAIN`.

## Phases (order = spec §1)

1. **DNS** — `025` (prd apex import, dev subzone + delegation), NS handoff
   (option A). Done (code).
2. **Domain verification** — `005` + `do_spl_domain_verify`. Done (code).
3. **Data + registry** — `040`, `050`, `045`, `028`, image, DB bootstrap.
   Done (code).
4. **Hub** — `030` (`ingress: all`), then `032` mappings,
   `do_spl_wait_for_mapping_cert`. Done (code).
5. **CI identity** — `120` key secret (primary), `017` WIF (alternative).
   Done (code).
6. **Remaining** — `003` IAM users; T090; T091.

## Risks

- **Zone recreate** breaks delegation → import only, `prevent_destroy`, the
  plan gate rejects any add/replace of the apex zone.
- **Stale reports** — the status of every row comes from `terraform state` /
  the SA's gcloud reads, not from reports.
- **LB leftovers** — `compute` + `certificatemanager` APIs stay enabled
  (disabling is owner-gated, spec §7).

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:24:52Z -->
