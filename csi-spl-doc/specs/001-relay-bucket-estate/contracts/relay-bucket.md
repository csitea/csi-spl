# Contract: the relay bucket git-rel depends on

**Owner**: spec 001 (this file). **Consumer**: git-rel v2 (`nea-nfs-orc`).
The contract is **derived from git-rel**, not imposed on it. Before changing
any row, read `../../../doc/md/csi-spl.feature.md` §4 and the git-rel sources
it names.

## 1. Names (per env, `<env>` ∈ `dev`, `prd`)

| thing | value | source of truth |
|---|---|---|
| GCP project | `csi-spl-<env>` | `<env>.env.yaml` |
| region | `europe-north1` | `<env>.env.yaml` |
| relay bucket | `gs://csi-spl-<env>-rel` | `steps.020-gcp-relay-bucket.relay_bucket_name` |
| relay SA | `csi-spl-rel-<env>@csi-spl-<env>.iam.gserviceaccount.com` | `steps.020-gcp-relay-bucket.relay_sa_account_id` |
| key file (on a box) | `$HOME/.gcp/.csi/key-csi-spl-<env>-rel.json`, mode `600` | out of band (§6.3) |
| git-rel selector | `GIT_REL_ENV=prd` (default) \| `dev` | `nea-nfs-orc/cnf/bash/git-rel.cnf` |

## 2. Bucket guarantees (FR-002, FR-004)

| property | value | why git-rel cares |
|---|---|---|
| uniform bucket-level access | `true` | no per-object ACLs to leak |
| public access prevention | `enforced` | no object can ever be public; reach is only by signed URL |
| versioning | off | a cleaned object is gone |
| soft delete | 604800 s | operator recovery window only; not visible to git-rel |
| lifecycle | Delete at age **1 day** | an undelivered object disappears; the sender learns only from a 403/404 |
| object prefix | `dyr-<32 hex>/…` | git-rel's own layout; the bucket does not enforce it |

## 3. Relay SA guarantees (FR-003, FR-005)

- Exactly one binding: `roles/storage.objectUser` **on this bucket**. There
  is no project role and no bucket-level permission: the SA **cannot**
  `buckets describe`, change IAM, or delete the bucket.
- Consequence for git-rel: `gcloud storage sign-url` MUST be given
  `--region` explicitly, because auto-detection needs `storage.buckets.get`.
- URLs are signed **locally** with the key file (`--private-key-file`), so no
  `iam.serviceAccounts.signBlob` is needed.
- The key is **never** a terraform resource and never in state; there is
  exactly one user-managed key per SA.

## 4. Wire behaviour git-rel relies on

| request | expected |
|---|---|
| signed PUT (V4, relay SA) to `dyr-<32hex>/<name>.gpg` | 200 |
| signed GET of that object | 200, same sha256 |
| unsigned GET of any object | 403 |
| anonymous XML listing of the bucket | 403 |
| GET of an aged-out, cleaned or never-sent object, signed or not | 403/404, indistinguishable |

## 5. Change rules

- Renaming the bucket, the SA or the key path changes **both** `020` cnf keys
  **and** `git-rel.cnf`, in one coordinated change.
- Loosening any row of §2 or §3 needs the owner's go.

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:01:26Z -->
