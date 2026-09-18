# Tasks: Relay Bucket & GCP Estate (001-relay-bucket-estate)

**Input**: Design documents from `/specs/001-relay-bucket-estate/`

**Status**: Implemented — all boxes `[x]` reflect the as-built estate recorded
in `csi-spl-doc/doc/md/csi-spl.feature.md` (git log `020167a`..`b381f7b`).

**Re-audit (GRK-931, 2026-09-18)**: read-only. See `spec.md` Audit findings
for FR/SC verdicts. Task SHAs below still resolve in this repo except
`47dc615` (nea-nfs-orc, confirmed there).

## Phase 1: Setup

- [x] T001 [P] Copy `run.sh` + run-bsh helpers from `pas-psf-utl` (v3.8.2),
      banner-only changes (`csi-spl.feature.md` §2.2)
- [x] T002 [P] Pin `tpl-gen` as a git-ignored sibling clone via
      `csi-spl-iac/cnf/tpl-gen.ref`; `do_tpl_gen` refuses any other HEAD
- [x] T003 The domain is ONE key `env.dns.BASE_DOMAIN` in `all.env.yaml`;
      `domain-single-source.tst.sh` guards it (`82ffc2a`)
      — re-audit: FQDN still confined to cnf+doc; the test greps the label
      and now fails on `spool-hub-api` (spec 002, already on trunk)

## Phase 2: Foundational (projects + state)

- [x] T004 Implement `do_gcp_001_create_project` — token pre-flight, three-way
      exists check, dry run unless `DRY_RUN=0` (`020167a`)
- [x] T005 Implement `000-gcp-remote-bucket` (versioned tfstate bucket)
- [x] T006 Bootstrap `000` local→gcs migrate, proven by lineage + advanced
      serial; `do_tf_plan` never wipes a run dir holding state (`d1d5fd9`, `4cbb92c`)
      — re-audit: wipe-guard test PASS; live lineage unverifiable (operator reauth)
- [x] T007 Implement `001-enable-gcp-services` — storage, iam, orgpolicy
      (`439eb70`); never disabled on destroy

## Phase 3: Relay bucket + SA (US1)

- [x] T008 [US1] Implement `020-gcp-relay-bucket`: `csi-spl-<env>-rel`, uniform
      access, PAP enforced, SA `csi-spl-rel-<env>`, one `roles/storage.objectUser`
      binding
- [x] T009 [US1] Add the 1-day lifecycle rule (`object_max_age_days: 1`) in
      `<env>.env.yaml`; applied to both buckets (`8df4516`, `94d8d37`)
      — re-audit: yaml+tfvars still 1; live `buckets describe` unverifiable
- [x] T010 [US1] Document the SA-key out-of-band mint / rotate procedure
      (`csi-spl.feature.md` §6.3); key never a Terraform resource
- [x] T011 [US1] Verify per §6.4 on dev and prd (signed PUT/GET, unsigned +
      anonymous 403, delete = 0 objects)
      — re-audit: unsigned/anonymous 403 live both buckets; relay SA
      `buckets describe` denied (FR-003); signed PUT/GET not repeated
      (would mutate). Operator narrative §6.4 still says describe with the
      relay SA (out of this audit's pathspec).

## Phase 4: git-rel switch + retire old bucket (US2)

- [x] T012 [US2] Switch git-rel to read the relay from ONE config
      (`nea-nfs-orc/cnf/bash/git-rel.cnf`); fail fast on empty / mismatched key
      (landed `47dc615`)
- [x] T013 [US2] Prove with `git-rel-roundtrip.tst.sh` against `csi-spl-prd-rel`
      (48/1 known F3 leak; control 22/27)
      — re-audit: not re-run (live round-trip mutates); config + commit present
- [x] T014 [US2] Retire `gs://bnc-cpt-all-relay`; leave the `bnc-cpt` owner SA
      untouched, key file tightened to 0600 (`523eb2c`, `88a8df1`)
      — re-audit: anonymous GET of the retired bucket → HTTP 404 `NoSuchBucket`

## Phase 5: Doc truthing

- [x] T015 Record that an empty relay prefix no longer proves a clean happened —
      only that the object is absent now (`b381f7b`)

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T14:36:48Z -->
