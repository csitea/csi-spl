# Feature Specification: Relay Bucket & GCP Estate

**Feature ID**: `001-relay-bucket-estate` · **Milestone**: pre-M1 (retro)

**Status**: **Implemented** in both `dev` and `prd`. Every FR below was
re-verified against the repo and live GCP on 2026-09-18 (redo lane CLE-3339).
The FR table has the evidence, and the drifts found are open in `tasks.md`
Phase 6.

**Authorities**: ground rules `../README.md` (status vocabulary, seams,
provisioning order §6). The operator how-to is
`../../doc/md/csi-spl.feature.md` (§4 relay contract, §5 terraform, §6
operate, §7 git-rel switch, §8 retirement). The bucket/SA/key interface git-rel
depends on is `contracts/relay-bucket.md`.

**Input**: "Provide the GCS bucket, service account and GCP projects that
git-rel needs to relay gpg-encrypted files between the hub and the boxes, with
the same access model as the bucket it replaces and one deliberate improvement:
objects expire after 1 day."

## Context

The spool is, first, the **GCP estate that carries git-rel**. git-rel is the
relay that moves gpg-encrypted files between the hub and the boxes through one
GCS bucket, using signed URLs in both directions. This spec owns that bucket,
its service account and the two GCP projects around them: terraform steps
`000`, `001` (the relay-era services only) and `020`.

Out of scope:

- **The git-rel client.** It lives with its consumer
  (`nea-nfs-orc/src/bash/run/git-rel/`).
- **The spool message bus** (spec 003). Agent mail is a different plane
  (`SPEC-spool-message-bus.md` §"git-rel"). Do not conflate the two.
- **The hub files bucket** `csi-spl-<env>-files` (step `050`, spec 007). It is
  a separate bucket with the same hygiene but no lifecycle.
- **Every hub step** (DNS zone, `040`, `050`, `028`, `030`, `031`) and the
  hub-era services added to `001` later. All of that is spec 007 (README §5
  and §6). Terraform **apply** for any step is the 007 apply owner's; this
  lane proposes, it never applies.

## Provisioning position

In the canonical order (README §6), 001 owns rows **1** (`000`) and **2**
(`001`). Step `020` depends only on those two, and nothing in the hub chain
depends on `020`. It is therefore an **independent branch after row 2**, and
it was applied in both envs before any hub step existed.

## User Scenarios & Testing

### User Story 1 — Operator provisions a relay bucket for an env (P1)

An operator bootstraps `csi-spl-dev` / `csi-spl-prd`, applies `000` → `001` →
`020`, mints the relay SA key out of band, and verifies that the bucket
enforces the exposure controls git-rel depends on.

**Independent test**: `csi-spl.feature.md` §6.4 against a freshly applied env.
The bucket describe is an **operator** call (`storage.buckets.get`). The relay
SA holds `roles/storage.objectUser` only and is refused `buckets describe`,
which is FR-003 holding, not a failed check. Then, as the relay SA under a
throwaway `CLOUDSDK_CONFIG`, run these object checks:

1. Signed PUT then GET of `dyr-<32hex>/probe.gpg` returns the same sha256.
2. An unsigned GET and an anonymous listing are both 403.
3. After a delete, the prefix holds 0 objects.

**Acceptance scenarios**

1. **Given** an applied `020`, **when** the relay SA does a signed PUT then a
   signed GET of `dyr-<32hex>/probe.gpg`, **then** the GET reads back the same
   sha256, and an unsigned GET plus an anonymous listing both answer 403.
2. **Given** the 1-day lifecycle rule is live, **when** an object is older than
   a day, **then** GCS deletes it and neither side logs anything.

### User Story 2 — git-rel reads the relay from one config place (P1)

git-rel picks dev or prd from a single config file. It refuses to run on an
empty value or on a key whose `project_id` does not match.

**Independent test**: run `nea-nfs-orc/src/bash/tests/git-rel-roundtrip.tst.sh`
against `gs://csi-spl-prd-rel` (send, fetch, clean, then a cache-busted
anonymous GET after the clean).

**Acceptance scenarios**

1. **Given** `GIT_REL_ENV=prd`, **when** git-rel signs a URL, **then** it uses
   `gs://csi-spl-prd-rel` and `$HOME/.gcp/.csi/key-csi-spl-prd-rel.json`, with
   `--region europe-north1`.
2. **Given** a key whose `project_id` ≠ `RELAY_PROJECT`, **when** git-rel
   starts, **then** it refuses before any upload.

### Edge cases

- **A box goes offline mid-transfer.** The object ages out within a day. The
  sender learns only from the receiver's 403/404, which looks the same as an
  expired URL or a cleaned object. Re-send rather than wait: `--expiry`
  extends the URL's life, never the object's.
- **An empty relay prefix** no longer proves that a `git-rel-clean` ran, only
  that the object is not there now (cleaned or aged out).
- **A bare `gcloud` with no `--account`** fails with `You do not currently
  have an active account selected`, not with a misleading 403. Always pass
  `--account=$GCP_ACCOUNT` or use a throwaway `CLOUDSDK_CONFIG`.

## Requirements

Status vocabulary per README: **Implemented** (verified, cited) / **Partial** /
**Planned**. Live evidence was measured on 2026-09-18 at about 19:00Z, n=1 per
env, operator identity `--account=$GCP_ACCOUNT`, read-only calls only. Repo
evidence is at trunk `bbc41e7`.

### Functional requirements

| id | requirement | status | evidence |
|---|---|---|---|
| FR-001 | GCP projects `csi-spl-dev` / `csi-spl-prd` in `europe-north1`, each with a **versioned** tfstate bucket `csi-spl-<env>-tfstate` (step `000`). | Implemented | `gcloud projects describe csi-spl-<env>` → `ACTIVE` ×2. `buckets describe gs://csi-spl-<env>-tfstate` → `versioning_enabled: true` ×2. |
| FR-002 | Relay bucket `csi-spl-<env>-rel`: uniform access, PAP **enforced**, versioning off, soft-delete 604800 s, lifecycle Delete at age 1 day, location `EUROPE-NORTH1`, class STANDARD. | Implemented | `03-relay-bucket.tf`. `buckets describe gs://csi-spl-<env>-rel` ×2 → `uniform_bucket_level_access: true`, `public_access_prevention: enforced`, `versioning_enabled: false`, `retentionDurationSeconds: '604800'`, `lifecycle_config.rule[0] = {Delete, age: 1}`, `EUROPE-NORTH1`. |
| FR-003 | Relay SA `csi-spl-rel-<env>` holds **exactly** `roles/storage.objectUser` on that bucket, with no project role, no object IAM and no bucket-delete. | Implemented | `04-relay-sa.tf` has one binding. `buckets get-iam-policy` ×2 → the only non-legacy binding is `roles/storage.objectUser` for `csi-spl-rel-<env>@…`. `projects get-iam-policy … --filter=bindings.members:csi-spl-rel-<env>` → empty ×2. |
| FR-004 | An unsigned object GET and an anonymous XML listing both answer 403. Nothing can make an object public. | Implemented | Cache-busted `curl` of `…/csi-spl-<env>-rel/dyr-0…0/probe.gpg` and `…/csi-spl-<env>-rel` → `403` ×4. PAP enforced (FR-002). |
| FR-005 | The relay SA key is minted **out of band** (never a terraform resource), `chmod 600`, under `$HOME/.gcp/.csi/`. | Implemented | `020` state resources = `google_service_account.relay`, `google_storage_bucket.relay`, `google_storage_bucket_iam_member.relay_object_user`; `'private_key' in state` → `False` ×2. Key files mode `600`, `project_id` = env, `client_email` = `csi-spl-rel-<env>@…`. `keys list --managed-by=user` → exactly 1 key per SA, matching the file's `private_key_id`. |
| FR-006 | The product domain (the FQDN in `all.env.yaml → env.dns.BASE_DOMAIN`) appears in no tracked file outside `csi-spl-cnf/` and `csi-spl-doc/`. | Implemented | `domain-single-source.tst.sh` PASS. It now matches label+TLD at a boundary (`bd58df5`, `dd68eea`), so the earlier over-match on `spool-hub-api` is fixed. |
| FR-007 | `do_gcp_001_create_project` is a dry run unless `DRY_RUN=0`, and proves `GCP_ACCOUNT` can mint a token before any create. | Implemented | `gcp-001-dead-credential-no-create.tst.sh` PASS. |
| FR-008 | Step `000` state bootstraps on a local backend, then migrates to `gs://csi-spl-<env>-tfstate/terraform/000-gcp-remote-bucket/`, proven by matching lineage and an advanced serial. | Implemented | `default.tfstate` vs `local-state-copy/terraform.tfstate`: dev lineage `378c0bc3…` serial 3 vs 2; prd lineage `a9a694dd…` serial 3 vs 2. `tf-plan-keeps-local-state.tst.sh` PASS. |
| FR-009 | Step `001` enables the relay-era services `storage`, `iam` and `orgpolicy` (the latter for the key-creation reset, §6.3), and never disables them on destroy. | Partial | Live: all three enabled in both envs. `001` state: dev holds all three (serial 4); **prd state holds only `iam`, `storage`** (serial 3), so prd `orgpolicy` was enabled outside terraform → T020. The hub-era services missing in prd are spec 007's. |
| FR-010 | git-rel reads the bucket, project, region and key path from **one** file and fails fast on an empty or mismatched value. | Implemented | `nea-nfs-orc` `47dc615`. `cnf/bash/git-rel.cnf` maps `GIT_REL_ENV` prd/dev → `gs://csi-spl-<env>-rel` / `csi-spl-<env>` / `europe-north1` / `$HOME/.gcp/.csi/key-csi-spl-<env>-rel.json`. `git-rel-send.func.sh` calls `sign-url … --region="$RELAY_REGION"` with no predefined ACL. |
| FR-011 | The predecessor bucket `gs://bnc-cpt-all-relay` is retired, and its owner SA is left alone. | Implemented | Cache-busted anonymous GET → `404` (`NoSuchBucket`). |

### Non-functional requirements

| id | requirement | status | evidence |
|---|---|---|---|
| NFR-001 | Terraform version pinned (1.9.8). | Implemented | `env.versions.terraform_version: 1.9.8` in `<env>.env.yaml`, used by `do_tf_plan`. `required_version >= 1.5.0` is a floor, not the pin. |
| NFR-002 | No key in git, in terraform state or in a log. | Implemented | FR-005 state check. `git grep google_service_account_key` → comments only. |
| NFR-003 | Every `gcloud` call carries `--account` or a throwaway `CLOUDSDK_CONFIG`; the shared `~/.config/gcloud` is never mutated. | Implemented | Every `gcloud` in `gcp-001-create-project.func.sh` carries `--account`; git-rel runs under a throwaway `CLOUDSDK_CONFIG`. |
| NFR-004 | Nothing mutates GCP without the owner's explicit go. | Implemented | `csi-spl-iac` has no apply action. Create-project is dry-run by default. This redo issued no mutating call. |

## Success criteria

| id | criterion | status | evidence |
|---|---|---|---|
| SC-001 | §6.4 verification passes on `csi-spl-dev-rel` and `csi-spl-prd-rel`. | Partial (procedure text) | The settings/IAM half and the 403 half were re-measured live 2026-09-18 (FR-002..004). The signed PUT/GET round-trip was not repeated (it mutates); it last passed 2026-09-17 (operator narrative §7). §6.4 step 1 still says "describe with the relay SA", which FR-003 makes impossible → T016. |
| SC-002 | A git-rel round trip against `gs://csi-spl-prd-rel` passes. | Implemented (2026-09-17) | Measured 48 passed / 1 known F3 leak; control against a non-existent bucket 22/27 (`csi-spl.feature.md` §7). Not re-run (it mutates). |
| SC-003 | An operator `buckets describe` shows the 1-day lifecycle rule on both buckets. | Implemented | FR-002 evidence. |
| SC-004 | The FQDN is confined to `csi-spl-cnf/` + `csi-spl-doc/`. | Implemented | FR-006. `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` → `6/6 test files passed`. |

## Assumptions

- The operator has an interactive GCP login. The org's reauth policy has at
  times refused the cached human credential for non-interactive calls; on
  2026-09-18 it was accepted for read-only calls.
- git-rel v2 (`nea-nfs-orc`) is the sole consumer of the relay bucket.
- `bnc-cpt`'s own owner identity is not a relay identity and was left alone
  deliberately. Retiring it is a `bnc-cpt` decision.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:01:26Z -->
