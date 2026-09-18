# Feature Specification: Relay Bucket & GCP Estate

**Feature ID**: `001-relay-bucket-estate`

**Created**: 2026-09-18

**Status**: Implemented

**Status hygiene (2026-09-18)**: Retrospective spec. Captures the as-built GCP
estate documented in `csi-spl-doc/doc/md/csi-spl.feature.md` (the operator
narrative remains the living how-to; this spec is the FR/SC record). Terraform
steps `000/001/020` exist; the git-rel switch landed in nea-nfs-orc `47dc615`;
`gs://bnc-cpt-all-relay` was retired 2026-09-17.

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

**Independent Test**: Run the §6.4 verification (describe with the relay SA,
signed PUT/GET round-trip, unsigned/anonymous = 403, delete = 0 objects) against
a freshly applied env.

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
- **FR-006**: The domain MUST live in exactly one place
  (`all.env.yaml → env.dns.BASE_DOMAIN`) and appear in no tracked file outside
  `csi-spl-cnf/` and `csi-spl-doc/`.
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
  `csi-spl-prd-rel`.
- **SC-002**: A git-rel round trip against `gs://csi-spl-prd-rel` passes
  (measured 2026-09-17: 48 passed / 1 known F3 leak; control against a
  non-existent bucket 22/27).
- **SC-003**: `gcloud storage buckets describe` shows the 1-day lifecycle rule
  on both buckets.
- **SC-004**: `domain-single-source.tst.sh` finds the domain nowhere outside
  `csi-spl-cnf/` and `csi-spl-doc/`.

## Assumptions

- The operator has an interactive GCP login (the org's reauth policy refuses the
  cached human credential for non-interactive project creation).
- git-rel v2 (`nea-nfs-orc`) is the sole consumer; the client is out of scope.
- `bnc-cpt-all@...` is `bnc-cpt`'s own owner identity, NOT a relay identity —
  left alone deliberately; retiring it is a `bnc-cpt` decision.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T00:00:00Z -->
