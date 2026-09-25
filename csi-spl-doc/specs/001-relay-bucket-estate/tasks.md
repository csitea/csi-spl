# Tasks: Relay Bucket & GCP Estate (001-relay-bucket-estate)

**Input**: `./spec.md`, `./plan.md`, `./contracts/relay-bucket.md`

**Status vocabulary** (README): Implemented / Partial / Planned. Each
Implemented task cites a sha or a `command → result`. Live checks are
2026-09-18, about 19:00Z, n=1 per env, read-only, `--account=$GCP_ACCOUNT`.

## Phase 1: Setup

- [x] T001 [P] Copy `run.sh` + run-bsh helpers from `pas-psf-utl` (v3.8.2),
      banner-only changes (`csi-spl.feature.md` §2.2). **Implemented**:
      `./run` actions load and the iac suite runs them (T004).
- [x] T002 [P] Pin `tpl-gen` as a git-ignored sibling clone via
      `csi-spl-iac/cnf/tpl-gen.ref`; `do_tpl_gen` refuses any other HEAD.
      **Implemented**: `tf-steps-render-and-validate.tst.sh` PASS.
- [x] T003 One domain key, `env.dns.BASE_DOMAIN` in `all.env.yaml`, guarded
      by `domain-single-source.tst.sh` (`82ffc2a`; boundary match `dd68eea`,
      `bd58df5`). **Implemented** (FR-006): test PASS.

## Phase 2: Foundational (projects + state)

- [x] T004 `do_gcp_001_create_project`: token pre-flight, three-way exists
      check, dry run unless `DRY_RUN=0` (`020167a`). **Implemented**
      (FR-007): `gcp-001-dead-credential-no-create.tst.sh` PASS.
- [x] T005 `000-gcp-remote-bucket`, a versioned tfstate bucket.
      **Implemented** (FR-001): `versioning_enabled: true` ×2.
- [x] T006 Bootstrap `000` local→gcs, proven by lineage + advanced serial;
      `do_tf_plan` never wipes a run dir holding state (`d1d5fd9`,
      `4cbb92c`). **Implemented** (FR-008): lineage matches, serial 3 > 2
      ×2; `tf-plan-keeps-local-state.tst.sh` PASS.
- [~] T007 `001-enable-gcp-services`: storage, iam, orgpolicy (`439eb70`),
      never disabled on destroy. **Partial** (FR-009): live enabled ×2, but
      prd state lacks `orgpolicy` → T020.

## Phase 3: Relay bucket + SA (US1)

- [x] T008 [US1] `020-gcp-relay-bucket`: `csi-spl-<env>-rel`, uniform
      access, PAP enforced, SA `csi-spl-rel-<env>`, one
      `roles/storage.objectUser` binding. **Implemented** (FR-002, FR-003):
      live describe + bucket/project IAM ×2.
- [x] T009 [US1] 1-day lifecycle rule (`object_max_age_days: 1`) in
      `<env>.env.yaml`, applied to both buckets (`8df4516`, `94d8d37`).
      **Implemented** (SC-003): live `lifecycle_config` `{Delete, age: 1}` ×2.
- [x] T010 [US1] SA key minted and rotated out of band (§6.3), never a
      terraform resource. **Implemented** (FR-005): `020` state holds no
      `private_key`; 1 user-managed key per SA = the key file's id; mode 600.
- [~] T011 [US1] Verify per §6.4 on dev and prd. **Partial** (SC-001):
      settings, IAM and 403 halves re-measured; signed PUT/GET not repeated
      (it mutates); §6.4 step 1 text is wrong → T016.

## Phase 4: git-rel switch + retire old bucket (US2)

- [x] T012 [US2] git-rel reads the relay from ONE config
      (`nea-nfs-orc/cnf/bash/git-rel.cnf`) and fails fast on an empty or
      mismatched key (nea-nfs-orc `47dc615`). **Implemented** (FR-010).
- [x] T013 [US2] `git-rel-roundtrip.tst.sh` against `csi-spl-prd-rel`: 48
      passed / 1 known F3 leak; control 22/27. **Implemented** 2026-09-17
      (SC-002); not re-run (it mutates).
- [x] T014 [US2] Retire `gs://bnc-cpt-all-relay`; leave the `bnc-cpt` owner
      SA alone, key file tightened to 0600 (`523eb2c`, `88a8df1`).
      **Implemented** (FR-011): anonymous GET → 404 `NoSuchBucket`.

## Phase 5: Doc truthing

- [x] T015 Record that an empty relay prefix no longer proves a clean
      happened (`b381f7b`). **Implemented**: spec Edge cases.

## Phase 6: Redo 2026-09-18 — drift found, to close

- [x] T016 Correct `csi-spl.feature.md` §6.4 step 1: describe with an
      **operator** identity; the relay SA is refused `storage.buckets.get` by
      design (FR-003). **Implemented**: `grep -c 'Describe it with an \*\*operator\*\*' csi-spl-doc/doc/md/csi-spl.feature.md` → 1.
- [x] T017 Drop the stale "OPEN QUESTION" comment next to
      `object_max_age_days: 1` in `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml`
      (decided `8df4516`). **Implemented** (`bd9be9b`): `grep -c 'OPEN QUESTION' csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` → 0, 0.
- [x] T018 `tf-steps-render-and-validate.tst.sh`: assert both envs render
      `object_max_age_days = 1`, soft delete `604800`, SA id
      `csi-spl-rel-<env>`, exactly one bucket binding (`objectUser`) and no
      project role in `020`. **Implemented** (`bd9be9b`): suite
      `6/6 test files passed`; negative control (dev `object_max_age_days = 0`)
      → `FAIL: 1 assertion(s)`.
- [x] T019 `terraform plan` of `000` / `001` / `020` in dev and prd,
      read-only (`-lock=false`, terraform 1.9.8, gcs backend, operator token,
      2026-09-18 ~19:20Z). **Implemented**: `plan -detailed-exitcode` → rc 0
      "No changes" for dev `000`/`001`/`020` and prd `000`/`020`; prd `001` →
      rc 2, `Plan: 10 to add` (the hub-era services plus `orgpolicy`), which is
      spec 007's pending prd `001` apply. Run by hand because `./run` cannot
      plan from a `csi-spl-wt/<ID>` worktree (it derives ORG/APP from the path
      → `csi-spl-wt-3339-cnf`), which was reported, not fixed here. Since
      fixed by `8dded98e` (`do_resolve_oap` derives ORG/APP from the project
      dir name; gate `resolve-oap-worktree.tst.sh`).
- [ ] T020 prd `001` state lacks `orgpolicy.googleapis.com` although it is
      enabled live. The prd `001` plan already includes it as an
      (idempotent) create, so **no import is needed**: the prd `001` apply
      that the hub needs anyway closes it. Proposed to the 007 apply owner.
      **Planned**; this lane never applies. 2026-09-25: 007 T050 records a
      prd `make do-provision`, so this is probably closed; confirming needs a
      `terraform state list` of prd `001` (read-only, not run in this sync).
- [ ] T021 `nea-nfs-orc` `git-rel.lib.sh` header still says "hub → box:
      public-read object"; the sender uploads private and signs a GET. That is
      another repo, so it is reported to its owner, not edited here. **Planned**.

<!-- version: 1.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:09:09Z -->
