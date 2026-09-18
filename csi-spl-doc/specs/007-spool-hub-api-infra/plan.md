# Implementation Plan: spool hub cloud estate (iac)

**Feature ID**: `007-spool-hub-api-infra` · **Status**: Partial · **Date**: 2026-09-18 (redo)

**Spec**: `./spec.md` · **Contract**: `./contracts/provisioning-order.md` ·
**Narrative**: `../../doc/md/SPEC-spool-hub-api-infra.md` · **Index**: `../README.md`

## Summary

Host the spool hub on GCP the way csi-rel and pas-psf host theirs, without
the shop, in the canonical order of README §6. dev is stood up through Cloud
Run; the work left is (1) the DNS-zone import step, (2) the NS decision, (3)
ingress on dev, (4) the whole chain on prd, (5) WIF so `008` can deploy, and
(6) the secrets / IAM / domain-verification steps.

## Technical Context

- **Repo trees**: `csi-spl-iac` (terraform steps + `./run` `do_tf_plan`,
  `do_tpl_gen`), `csi-spl-cnf` (`csi-spl/<env>.env.yaml` -> rendered
  `<env>/tf/*.tfvars`), `csi-spl-orc` (lde, image build, DB bootstrap, DNS
  ops), `csi-spl-rdb` (spool DDL), `csi-spl-api` (Go hub).
- **References, read-only**: `csi-rel-{iac,orc,cnf}`, `pas-psf-{iac,orc,cnf}`.
- **Terraform** `>= 1.7`, provider `google ~> 6.0`, GCS backend per env.
- **Region** `europe-north1`; projects `csi-spl-dev`, `csi-spl-prd`.

## Constitution check

- Nothing mutates GCP without the owner: `do_tf_plan` only plans; there is
  no apply action; orc cloud actions are `DRY_RUN=1` by default.
- Every gcloud call carries `--account`; the shared gcloud config is never
  changed.
- No key in git, tf state or log (040 holds no user/password/version; 017
  uses WIF, no SA key).
- The domain lives only in `env.dns.BASE_DOMAIN`.

## Phases (order = README §6)

1. **DNS zone step `025-gcp-dns-zone`** — land the in-flight step (import
   block, `prevent_destroy`, cnf `zone_name`), wire `031` to write into it
   (dev records into the prd zone), plan must show 1 import / 0 add.
2. **NS decision** — owner picks A or B (spec §2); then either the Gandi NS
   change plus lifting the `ns-cloud-*` refusal, or `do_gandi_*` record
   writes for the ACME CNAME and the wildcard A records.
3. **dev ingress** — apply `031` on dev, `do_wait_for_cert`, healthz gate.
4. **prd chain** — re-apply `001` with the current list, then 025 → 040 →
   050 → 028 → image → DB bootstrap → 030 → 031.
5. **WIF** — land `017`, apply per env, set the repo variables `008` reads.
6. **Remaining copies** — `029` secrets, `003` IAM users, `005` domain
   verification; hygiene gate tests (no keys in tf, no store entities in
   rdb).

## Risks

- **Zone recreate** breaks delegation → import only, `prevent_destroy`, the
  plan gate rejects any add/replace.
- **Apex capture** in prd (`fqdn` = apex) → no apex A record until the owner
  says so.
- **Stale reports** — several earlier lanes reported steps done that hold no
  state; the status of every row comes from `terraform state` / gcloud, not
  from reports.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:30:00Z -->
