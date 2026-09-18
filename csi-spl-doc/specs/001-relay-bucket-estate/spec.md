# Feature Specification: Relay Bucket & GCP Estate

**Feature ID**: `001-relay-bucket-estate`

**Created**: 2026-09-18

**Status**: Implemented

**Status hygiene (2026-09-18)**: Retrospective spec. Captures the as-built GCP
estate documented in `csi-spl-doc/doc/md/csi-spl.feature.md` (the operator
narrative remains the living how-to; this spec is the FR/SC record). Terraform
steps `000/001/020` exist; the git-rel switch landed in nea-nfs-orc `47dc615`;
`gs://bnc-cpt-all-relay` was retired 2026-09-17.

**Re-audit (GRK-931, 2026-09-18T14:36:48Z)**: read-only check of FR/SC against
the repo and live GCS. Findings at the end of this file. Spec text below was
corrected where the as-built disagreed (describe is not a relay-SA call;
"the domain" is the FQDN).

**Input**: "Provide the GCS bucket, service account and GCP projects that
git-rel needs to relay gpg-encrypted files between the hub and the boxes, with
the same access model as the bucket it replaces and one deliberate improvement:
objects expire after 1 day."

## Context

The spool is, first, the **GCP estate that carries git-rel** — the relay that
moves gpg-encrypted files between the hub and the boxes through one GCS bucket
using signed URLs in both directions. This feature owns the bucket, its service
account, and the projects around them. It does **not** contain the git-rel
client, which lives with its consumers (`nea-nfs-orc/src/bash/run/git-rel/`).

## User Scenarios & Testing

### User Story 1 - Operator provisions a relay bucket for an env (Priority: P1)

An operator bootstraps `csi-spl-dev` / `csi-spl-prd`, applies the Terraform
steps, mints the relay SA key out of band, and verifies the bucket enforces the
exposure controls git-rel depends on.

**Why this priority**: Without the bucket + SA + key, git-rel cannot relay
anything; this is the whole feature.

**Independent Test**: Run the §6.4 verification against a freshly applied env.
Describe the bucket with an operator identity that holds `storage.buckets.get`
— the relay SA is `roles/storage.objectUser` only and is refused
`buckets describe` (that refusal is FR-003 holding, not a failed describe).
Then, as the relay SA under a throwaway `CLOUDSDK_CONFIG`: signed PUT/GET
round-trip of `dyr-<32hex>/probe.gpg`, unsigned/anonymous = 403, delete = 0
objects.

**Acceptance Scenarios**:

1. **Given** an applied `020-gcp-relay-bucket`, **When** the relay SA does a
   signed PUT then signed GET of `dyr-<32hex>/probe.gpg`, **Then** the GET reads
   back the same sha256 and an unsigned GET + anonymous listing both answer 403.
2. **Given** the 1-day lifecycle rule is live, **When** an object is older than
   a day, **Then** the bucket deletes it with no log line on either side.

### User Story 2 - git-rel reads the relay from one config place (Priority: P1)

git-rel picks dev or prd from a single config and refuses to run on an empty
value or a key whose `project_id` mismatches.

**Why this priority**: A relay with a baked-in bucket or a silently-wrong key is
the failure mode this estate exists to remove.

**Independent Test**: `nea-nfs-orc/src/bash/tests/git-rel-roundtrip.tst.sh`
against `gs://csi-spl-prd-rel`: send, fetch, clean, cache-busted anonymous GET
after clean.

**Acceptance Scenarios**:

1. **Given** `GIT_REL_ENV=prd`, **When** git-rel signs a URL, **Then** it uses
   `gs://csi-spl-prd-rel` and `$HOME/.gcp/.csi/key-csi-spl-prd-rel.json`, signed
   with `--region europe-north1`.
2. **Given** a key whose `project_id` ≠ `RELAY_PROJECT`, **When** git-rel
   starts, **Then** it refuses before any upload.

### Edge Cases

- A box goes offline mid-transfer: the object ages out within a day and the
  sender learns only from the receiver's 403/404 — indistinguishable from an
  expired URL or a cleaned object. Re-send rather than wait; `--expiry` extends
  the URL's life, never the object's.
- An empty relay prefix no longer proves a `git-rel-clean` ran — only that the
  object is not there now (cleaned or aged out).
- A bare `gcloud` call with no `--account` fails `You do not currently have an
  active account selected` (ambient account unset 2026-09-02), not a misleading
  403; always pass `--account` or a throwaway `CLOUDSDK_CONFIG`.

## Requirements

### Functional Requirements

- **FR-001**: The estate MUST provide GCP projects `csi-spl-dev` / `csi-spl-prd`
  in `europe-north1`, each with a versioned tfstate bucket `csi-spl-<env>-tfstate`.
- **FR-002**: A relay bucket `csi-spl-<env>-rel` MUST exist with uniform
  bucket-level access, public access prevention **enforced**, soft-delete
  604800s, and a lifecycle rule deleting objects at age 1 day.
- **FR-003**: A relay SA `csi-spl-rel-<env>` MUST hold exactly
  `roles/storage.objectUser` on that bucket and nothing else (no object IAM, no
  bucket-delete, no project role).
- **FR-004**: An unsigned object GET and an anonymous XML listing MUST both
  answer 403; nothing may make an object public.
- **FR-005**: The relay SA key MUST be minted out of band (never a Terraform
  resource), `chmod 600`, under `$HOME/.gcp/.csi/`.
- **FR-006**: The DNS domain (the FQDN in `all.env.yaml → env.dns.BASE_DOMAIN`)
  MUST live in exactly one place and appear in no tracked file outside
  `csi-spl-cnf/` and `csi-spl-doc/`. The product path `spool-hub-api` is not
  the domain.
- **FR-007**: `do_gcp_001_create_project` MUST be a dry run unless `DRY_RUN=0`
  and MUST prove `GCP_ACCOUNT` can mint a token before any create.
- **FR-008**: State for step `000` MUST bootstrap with a local backend then
  migrate to `gs://csi-spl-<env>-tfstate/...`, proven by matching lineage and an
  advanced serial (not a fresh empty state).

### Non-Functional Requirements

- **NFR-001**: Terraform version MUST be pinned (1.9.8 as built).
- **NFR-002**: No key in git, in Terraform state, or in a log (Constitution VII).
- **NFR-003**: Every `gcloud` call carries `--account` or a throwaway
  `CLOUDSDK_CONFIG`; the shared `~/.config/gcloud` is never mutated.
- **NFR-004**: Nothing mutates GCP without the owner's explicit go.

## Success Criteria

- **SC-001**: The §6.4 verification passes on both `csi-spl-dev-rel` and
  `csi-spl-prd-rel`. Bucket describe is an operator call (`storage.buckets.get`);
  the relay SA is used for the object round-trip only.
- **SC-002**: A git-rel round trip against `gs://csi-spl-prd-rel` passes
  (measured 2026-09-17: 48 passed / 1 known F3 leak; control against a
  non-existent bucket 22/27).
- **SC-003**: `gcloud storage buckets describe` (operator identity) shows the
  1-day lifecycle rule on both buckets.
- **SC-004**: The FQDN from `env.dns.BASE_DOMAIN` appears in no tracked file
  outside `csi-spl-cnf/` and `csi-spl-doc/`. The shipped
  `domain-single-source.tst.sh` greps the label without TLD and therefore also
  matches `spool-hub-api`; that over-match is recorded in Audit findings, not
  a domain leak.

## Assumptions

- The operator has an interactive GCP login (the org's reauth policy refuses the
  cached human credential for non-interactive project creation).
- git-rel v2 (`nea-nfs-orc`) is the sole consumer; the client is out of scope.
- `bnc-cpt-all@...` is `bnc-cpt`'s own owner identity, NOT a relay identity —
  left alone deliberately; retiring it is a `bnc-cpt` decision.

## Audit findings (GRK-931, 2026-09-18)

Read-only re-audit of this retrospective spec against the as-built repo and
live GCS. Nothing mutated GCP. Operator token
`gcloud auth print-access-token --account=<operator>` refused (org reauth,
same as `csi-spl.feature.md` §6.1.3). Relay SA keys used only under a
throwaway `CLOUDSDK_CONFIG`.

Worktree at audit: branch `GRK-931-001-estate-audit`.
`n=1` live pass of anonymous HTTP and SA object-list unless noted.

### FR / SC

| id | verdict | evidence |
|---|---|---|
| FR-001 | verified in repo; live project describe unverifiable | `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` `gcp_project` / `gcp_region` / `state_bucket`; terraform `000-gcp-remote-bucket`. Operator token dead. |
| FR-002 | verified in repo; live settings unverifiable | yaml+tfvars `object_max_age_days = 1`, `soft_delete_retention_seconds = 604800`; `03-relay-bucket.tf` PAP `enforced`, uniform access, dynamic lifecycle. Buckets exist: anonymous GET is 403, not 404. |
| FR-003 | verified | terraform `04-relay-sa.tf` one `roles/storage.objectUser` binding; no `google_service_account_key` resource. Live: relay SA denied `storage.buckets.get` and `storage.buckets.getIamPolicy`; `gcloud storage ls gs://csi-spl-<env>-rel/dyr-*` is allowed (empty). |
| FR-004 | verified live | `curl` unsigned GET of a missing object and anonymous listing, both buckets, cache-busted: HTTP 403 `AccessDenied`. |
| FR-005 | verified | keys `$HOME/.gcp/.csi/key-csi-spl-{dev,prd}-rel.json`, mode `600`, `project_id` matches env, `client_email` is `csi-spl-rel-<env>@csi-spl-<env>.iam.gserviceaccount.com`. `git grep google_service_account_key` → comments only. |
| FR-006 | verified for the FQDN; test over-matches | `git grep spool-hub.ai -- :!csi-spl-cnf :!csi-spl-doc` → empty. `domain-single-source.tst.sh` fails because it greps the label `spool-hub`, which hits Go module `spool-hub-api` (spec 002, already on `origin/master`, 13 files). |
| FR-007 | verified | `do_gcp_001_create_project`: `DRY_RUN` default 1; `gcp-001-dead-credential-no-create.tst.sh` all PASS. |
| FR-008 | verified in repo; live lineage unverifiable | procedure in `csi-spl.feature.md` §6.2.4; `do_tf_plan` refuses to wipe a run dir holding state; `tf-plan-keeps-local-state.tst.sh` PASS. Operator cannot `storage cat` tfstate (reauth). |
| NFR-001 | verified as built | pin is `env.versions.terraform_version: 1.9.8` in cnf, used by `do_tf_plan`. Terraform `required_version` is `>= 1.5.0` (a floor, not the pin). |
| NFR-002 | verified | no private-key PEM in the tree; SA key is not a terraform resource. |
| NFR-003 | verified | every `gcloud` in `gcp-001-create-project.func.sh` carries `--account`; git-rel uses a throwaway `CLOUDSDK_CONFIG`. Ambient `[core] account` unset. |
| NFR-004 | verified | no apply action in `csi-spl-iac`; create-project is dry-run unless `DRY_RUN=0`. This audit issued no mutating gcloud. |
| SC-001 | partial; procedure drifted | unsigned/anonymous 403 live on both buckets. §6.4 step 1 "describe with the relay SA" cannot succeed (FR-003). Signed PUT/GET not repeated (would mutate). |
| SC-002 | unverifiable this audit | would mutate. Client still reads `nea-nfs-orc/cnf/bash/git-rel.cnf`; commit `47dc615` present; `sign-url --region="$RELAY_REGION"`. Prior measurement in the operator narrative. |
| SC-003 | unverifiable live | needs operator `buckets describe`. Repo has the 1-day rule; previously read back 2026-09-18 in the operator narrative. |
| SC-004 | drifted as a test | FQDN still confined (FR-006). Test fails on `spool-hub-api`. Follow-up (not this audit, iac): search for the FQDN, or allow the product path. 002 owns the module name. |

### Out of this audit's pathspec (not edited)

- `csi-spl-doc/doc/md/csi-spl.feature.md` §6.4 still says describe with the relay SA.
- `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` comments still say "OPEN QUESTION" next to `object_max_age_days: 1` (decided 2026-09-18, `8df4516`).
- `nea-nfs-orc` `git-rel.lib.sh` header still says "public-read object"; `git-rel-send.func.sh` uploads private (no predefined ACL).
- Hygiene grep hits the box-harness name (spec 002/003 docs and the constitution) — not in spec 001 / iac / cnf / the operator narrative.
- `tf-steps-render-and-validate.tst.sh` does not assert `object_max_age_days = 1`.

### Tests (this worktree)

`bash csi-spl-iac/src/bash/tests/run-all-tests.sh` → 3/4 files passed.
`domain-single-source.tst.sh` FAIL (label match, above). The other three PASS.
`tf-steps-render-and-validate.tst.sh` skipped tpl-gen in the worktree (no clone);
render-sync re-run against the sibling `tpl-gen` clone HEAD `89468a10`
(= `csi-spl-iac/cnf/tpl-gen.ref`): both envs in sync.

Live extras: anonymous GET of retired `gs://bnc-cpt-all-relay` → HTTP 404
`NoSuchBucket`. Relay SA object list of `dyr-*` on both current buckets →
no objects.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T14:36:48Z -->
