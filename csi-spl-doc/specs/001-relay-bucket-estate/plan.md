# Implementation Plan: Relay Bucket & GCP Estate

**Feature ID**: `001-relay-bucket-estate` · **Status**: Implemented (drift
tasks T016–T021 open) · **Date**: 2026-09-18

**Spec**: `./spec.md` · **Contract**: `./contracts/relay-bucket.md` ·
**Operator narrative**: `../../doc/md/csi-spl.feature.md`

## Summary

A terraform-managed GCP estate for the git-rel relay:

- two projects;
- a versioned tfstate bucket in each;
- a private relay bucket per env, with public access prevention and a 1-day
  lifecycle;
- a minimum-role relay SA whose key is minted out of band.

git-rel reads the relay from one config file and fails fast on an empty or
mismatched value.

## Technical Context

**Language/Version**: Terraform 1.9.8 (pinned in cnf); Bash 5 (`./run`
actions).

**Primary dependencies**: `google` provider, `gcloud`, and `tpl-gen` (a pinned
sibling clone) that renders tfvars from the cnf YAML.

**Storage**: GCS only: the tfstate buckets and the relay bucket.

**Testing**: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` → `6/6 test
files passed` at `bbc41e7`. That covers dead-credential, domain-single-source,
tf-plan-keeps-local-state, tf-steps-render-and-validate, plus 007's `028` and
`031` tests. git-rel has its own roundtrip suite in `nea-nfs-orc`.

**Target platform**: GCP `europe-north1`.

**Constraints**:

- No key or secret in git, in state or in a log.
- No GCP mutation without the owner's go.
- Every gcloud call is scoped by `--account=$GCP_ACCOUNT` or a throwaway
  `CLOUDSDK_CONFIG`.
- **Terraform apply is the 007 apply owner's.** This lane plans and proposes.

## Constitution Check

- [x] **I. Paths**: lives under `csi-spl-iac`; paths are derived, not hard-coded.
- [x] **II. Env**: `GCP_ACCOUNT` / `GCP_ORG_ID` / `GCP_BILLING_ACCOUNT_ID` fail
      fast; no default URLs or buckets in code.
- [x] **VI. Cnf-only**: bucket names, region, services and lifecycle all come
      from `csi-spl-cnf/csi-spl/<env>.env.yaml`; tfvars are tpl-gen output.
- [x] **VII. No key in git/state/log**: the SA key is minted out of band,
      `chmod 600`; the `020` state holds no `private_key` (verified).
- [x] **V. Hygiene**: org-neutral; the domain is confined to cnf + doc.

## Project Structure

```text
csi-spl-iac/
├── src/terraform/
│   ├── 000-gcp-remote-bucket/     # versioned tfstate bucket (local→gcs migrate)   [001]
│   ├── 001-enable-gcp-services/   # relay-era: storage, iam, orgpolicy              [001]
│   │                              #   hub-era services in the same list             [007]
│   └── 020-gcp-relay-bucket/      # csi-spl-<env>-rel + SA + one IAM binding        [001]
├── src/tpl/%app%/%env%/tf/        # tpl-gen templates → <env>/tf/*.tfvars
├── src/bash/run/                  # do_gcp_001_create_project, do_tpl_gen, do_tf_plan
└── src/bash/tests/                # suite; 001 owns dead-credential, domain-single-source,
                                   # tf-plan-keeps-local-state, and the 000/001/020
                                   # assertions of tf-steps-render-and-validate
csi-spl-cnf/csi-spl/
├── all.env.yaml                   # env.dns.BASE_DOMAIN (the one source of the domain)
└── <env>.env.yaml                 # steps.000/001/020 keys, terraform_version
```

## Provisioning position (README §6)

Rows 1 (`000`) and 2 (`001`) belong to this spec. `020` is an independent
branch after row 2. The hub chain (DNS zone → `040` → … → `031`) neither needs
it nor is needed by it. Dev first, then prd.

## Execution plan (as built)

1. Bootstrap `000` with a local backend, migrate its state to gcs, and prove
   the lineage.
2. Apply `001` (services are never disabled on destroy).
3. Apply `020` (relay bucket + SA + the `roles/storage.objectUser` binding).
4. Mint the relay SA key out of band (§6.3), `chmod 600`.
5. Verify (§6.4): an operator describe; a signed PUT/GET round-trip as the
   relay SA; unsigned and anonymous requests get 403.
6. Switch git-rel to the new bucket via one config file in `nea-nfs-orc`
   (`47dc615`), then retire `gs://bnc-cpt-all-relay`.

## Redo 2026-09-18

Everything was re-verified live and in the repo (see the `spec.md` tables).
Drift is tracked as T016–T021:

- two doc/comment truthing fixes;
- one missing test assertion;
- a read-only `terraform plan` of `000` / `001` / `020`;
- one prd state drift, proposed to the apply owner;
- one cross-repo comment, reported to its owner.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:01:26Z -->
