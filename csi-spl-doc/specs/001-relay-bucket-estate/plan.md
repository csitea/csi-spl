# Implementation Plan: Relay Bucket & GCP Estate

**Feature ID**: `001-relay-bucket-estate` · **Status**: Implemented · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Operator narrative**: `csi-spl-doc/doc/md/csi-spl.feature.md`

## Summary

Terraform-managed GCP estate for the git-rel relay: two projects, versioned
tfstate buckets, a private relay bucket per env with public-access-prevention
and a 1-day lifecycle, and a minimum-role relay SA whose key is minted out of
band. git-rel reads the relay from one config file and fails fast on empty or
mismatched values.

## Technical Context

**Language/Version**: Terraform 1.9.8; Bash 5 (`run-bsh` `./run` actions).

**Primary Dependencies**: `google`/`google-beta` providers; `gcloud`; `tpl-gen`
(pinned sibling clone) for rendering tfvars from cnf YAML.

**Storage**: GCS (tfstate buckets; the relay bucket itself). No database.

**Testing**: `csi-spl-iac/src/bash/tests/*.tst.sh` (dead-credential guard,
domain-single-source, tf-plan-keeps-local-state, tf-steps-render-and-validate)
+ git-rel's own roundtrip suite in `nea-nfs-orc`.

Re-audit 2026-09-18: `domain-single-source.tst.sh` currently fails on the
product path `spool-hub-api` (spec 002, already on trunk) because it greps the
label without TLD; the FQDN itself is still confined to cnf+doc. See
`spec.md` Audit findings. `tf-steps-render-and-validate.tst.sh` does not
assert `object_max_age_days = 1`.

**Target Platform**: GCP `europe-north1`.

**Project Type**: Infrastructure-as-code (single project, `csi-spl-iac`).

**Constraints**: No key/secret in git or state (VII); no GCP mutation without
owner go; every gcloud call scoped by `--account`/throwaway `CLOUDSDK_CONFIG`.

## Constitution Check

- [x] **I. Paths** — lives under `csi-spl-iac`; paths derived, not hard-coded.
- [x] **II. Env** — `GCP_ACCOUNT`/`GCP_ORG_ID`/`GCP_BILLING_ACCOUNT_ID` fail
      fast; no default URLs or buckets in code.
- [x] **VI. Cnf-only** — bucket names, region, services, lifecycle all from
      `csi-spl-cnf/csi-spl/<env>.env.yaml`; tfvars are tpl-gen output.
- [x] **VII. No key in git/state/log** — SA key minted out of band, `chmod 600`.
- [x] **V. Hygiene** — org-neutral; domain confined to cnf + doc.

## Project Structure

```text
csi-spl-iac/
├── src/terraform/
│   ├── 000-gcp-remote-bucket/     # versioned tfstate bucket (local→gcs migrate)
│   ├── 001-enable-gcp-services/   # storage, iam, orgpolicy
│   └── 020-gcp-relay-bucket/      # csi-spl-<env>-rel + SA + one IAM binding
├── src/tpl/%app%/%env%/tf/        # tpl-gen templates → <env>/tf/*.tfvars
├── src/bash/run/                  # do_gcp_001_create_project, do_tpl_gen, do_tf_plan
├── src/bash/tests/                # dead-credential, domain-single-source,
│                                  # tf-plan-keeps-local-state, tf-steps-render-and-validate
└── cnf/tpl-gen.ref                # pinned tpl-gen commit

csi-spl-cnf/csi-spl/
├── all.env.yaml                   # env.dns.BASE_DOMAIN (one source of the domain)
└── <env>.env.yaml                 # projects, region, steps.<step>, object_max_age_days
```

**Structure Decision**: Single IaC project. Terraform is organised as numbered
steps with per-step run dirs; apply is a manual, reviewed step (no apply action).

## Execution Plan (as built)

1. Bootstrap `000` with a local backend, migrate state to gcs, prove lineage.
2. Apply `001` (enable storage/iam/orgpolicy; never disabled on destroy).
3. Apply `020` (relay bucket + SA + `roles/storage.objectUser` binding).
4. Mint the relay SA key out of band (`6.3`), `chmod 600`.
5. Verify (`6.4`): operator describe (`storage.buckets.get`); signed PUT/GET
   round-trip as the relay SA; unsigned/anonymous 403.
6. Switch git-rel to the new bucket via one config file in `nea-nfs-orc`
   (landed `47dc615`); retire `gs://bnc-cpt-all-relay`.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T14:36:48Z -->
