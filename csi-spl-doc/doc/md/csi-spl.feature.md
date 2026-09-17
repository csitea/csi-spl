# csi-spl — the spool

Status as of 2026-09-17. Code: `github.com/csitea/csi-spl`, trunk `master`.

## 1. What the spool is

The spool is the GCP estate that carries **git-rel**, the relay that moves
gpg-encrypted files between the hub and the boxes through one GCS bucket,
using signed URLs in both directions. The spool provides the **bucket, its
service account and the GCP projects around them**. It does not contain the
git-rel client: that lives with its consumers (section 4.1).

It starts clean. Nothing was forked from csi-rel or pas-psf; the files that
were copied are listed one by one in section 2.2.

## 2. Layout

### 2.1 Directories

| dir | holds |
|---|---|
| `csi-spl-iac` | `./run` actions, terraform steps, tpl-gen templates, tests |
| `csi-spl-cnf` | `csi-spl/all.env.yaml`, `csi-spl/<env>.env.yaml` (sources); `csi-spl/<env>.env.json`, `csi-spl/<env>/tf/*.tfvars` (generated) |
| `csi-spl-doc` | this document |
| `csi-spl-dat`, `csi-spl-utl`, `csi-spl-orc` | a README each, saying what would go there |
| `tpl-gen/` | git-ignored sibling clone of `github.com/csitea/tpl-gen` |

### 2.2 Copied files and their sources

Everything not listed here was written for the spool.

| file in csi-spl | copied from | changed |
|---|---|---|
| `csi-spl-iac/src/bash/run/run.sh` | `pas-psf/pas-psf-utl/src/bash/run/run.sh` (v3.8.2) | banner only |
| `csi-spl-iac/src/bash/run/help/print-help.func.sh` | `pas-psf/pas-psf-utl/src/bash/run/help/print-help.func.sh` | banner only |
| `csi-spl-iac/lib/bash/funcs/detect-base-paths.func.sh` | `pas-psf/pas-psf-utl/lib/bash/funcs/` | probe stderr silenced |
| `csi-spl-iac/lib/bash/funcs/load-config.func.sh` | `pas-psf/pas-psf-utl/lib/bash/funcs/` | no `/var` symlink manifest |
| `csi-spl-iac/lib/bash/funcs/{require-bin,verify-symlinks,require-var,parse-metadata,validate-params}.func.sh` | `pas-psf/pas-psf-utl/lib/bash/funcs/` | banner only |
| `csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh` | `pas-psf/pas-psf-iac/lib/bash/funcs/` | none |
| `csi-spl-iac/lib/bash/funcs/gcp-require-live-account.func.sh` | `pas-psf/pas-psf-iac/lib/bash/funcs/` | none |
| `csi-spl-iac/src/bash/run/gcp-001-create-project.func.sh` | `pas-psf/pas-psf-iac/src/bash/run/gcp-001-create-project.func.sh` | rewritten around the same pre-flight + three-way check (section 6.1) |
| `csi-spl-iac/src/bash/tests/gcp-001-dead-credential-no-create.tst.sh` | `pas-psf/pas-psf-iac/src/bash/tests/` | adapted, cases added |

Why `pas-psf-utl`'s run.sh: of the eleven copies across pas-psf and csi-rel it
is the newest (v3.8.2, 2026-09-02); `csi-rel-utl`'s has the same body.

Read but deliberately NOT copied: `pas-psf-orc/src/bash/run/gcp-create-project.func.sh`
(older, unguarded, runs an interactive login), `pas-psf-orc/src/bash/run/remove-gcp-project.func.sh`
(the spool has no project-removal need yet), the tf-runner container and the
make/docker plumbing (terraform runs from a tfswitch-installed binary).

### 2.3 tpl-gen: a pinned sibling clone

`tpl-gen/` is a plain clone, ignored by the repo's `.gitignore`, and its
commit is pinned in `csi-spl-iac/cnf/tpl-gen.ref`. `do_tpl_gen` refuses to
render with any other HEAD.

- Not vendored, as pas-psf does: pas-psf's copy has drifted from upstream
  (on 2026-09-17 `diff -rq` against upstream, excluding `.git`, `.venv` and `__pycache__`, listed 62 differing or one-sided entries), which is the cost vendoring charges.
- Not a submodule: submodules make every clone, worktree and rebase an extra
  step for every agent on the box, for a tool the spool only runs at render time.
- The pin keeps renders reproducible; bump it deliberately by editing the ref.

Set up once:

```bash
git clone git@github.com:csitea/tpl-gen.git tpl-gen
```

```bash
git -C tpl-gen checkout "$(cat csi-spl-iac/cnf/tpl-gen.ref)"
```

```bash
python3 -m venv tpl-gen/src/python/tpl-gen/.venv
```

```bash
tpl-gen/src/python/tpl-gen/.venv/bin/pip install jinja2 pyyaml jq colorama rich pprintjson requests
```

## 3. Environments, projects and the domain

### 3.1 Projects

| env | GCP project | region | tf state bucket |
|---|---|---|---|
| dev | `csi-spl-dev` | `europe-north1` | `csi-spl-dev-tfstate` |
| prd | `csi-spl-prd` | `europe-north1` | `csi-spl-prd-tfstate` |

prd is the env nea and osp would use; dev is for proving changes first.

### 3.2 What is NOT in config

The project's parent, the billing account and the operator identity are
environment variables that fail fast, never committed:
`GCP_ORG_ID` or `GCP_FOLDER_ID`, `GCP_BILLING_ACCOUNT_ID`, `GCP_ACCOUNT`.

### 3.3 The domain: change it in ONE place

The spool's domain is `spool-hub.ai`. It is stored once:

- **`csi-spl-cnf/csi-spl/all.env.yaml` → `env.dns.BASE_DOMAIN`** — change the
  domain here and nowhere else, then re-render both envs (section 6.2.1).
- `csi-spl-cnf/csi-spl/<env>.env.yaml` → `env.dns.env_subdomain`: `dev` for
  dev, empty for prd.
- The effective hostname `env.dns.fqdn` is derived at render time
  (`do_spl_merged_cnf`) into `<env>.env.json`: `dev.spool-hub.ai` and the apex
  `spool-hub.ai`. This is the csi-rel / pas-psf convention.

`csi-spl-iac/src/bash/tests/domain-single-source.tst.sh` fails if the domain
appears in any tracked file outside `csi-spl-cnf/` and `csi-spl-doc/`.

Nothing DNS-related exists: no domain verification, no records, no mappings.
Those are future steps and need the owner's go. As read on 2026-09-17 the
domain is registered at Gandi (created that day) with Gandi nameservers.

## 4. The relay bucket contract (derived from git-rel)

### 4.1 Where git-rel lives

git-rel v2 is in `nea-nfs/nea-nfs-orc/src/bash/run/git-rel/`:
`git-rel.lib.sh` (defaults, helpers) and `git-rel-{send,request,fetch,clean,destroy}.func.sh`,
documented in `nea-nfs-orc/doc/md/git-rel.feature.md`.

### 4.2 What git-rel needs from the bucket

| need | from |
|---|---|
| one object per transfer at `dyr-<32 hex>/<name>.gpg`, gpg-encrypted to the receiving box | `git-rel.lib.sh` `_gr_new_id`, `_gr_pub_fpr` |
| hub → box: object uploaded **private** (no predefined ACL), `Content-Type: application/octet-stream`, `Cache-Control: no-store`, fetched by `curl` with a **signed GET URL**, 1–240 min | `git-rel-send.func.sh` |
| send PROVES: signed GET reads back the right sha256; **unsigned GET, anonymous listing and a wrong-name signed GET all answer 403** | `git-rel-send.func.sh` exposure controls |
| box → hub: **signed PUT URL**, 1–60 min, signed headers `content-type` and `x-goog-if-generation-match: 0` (single use) | `git-rel-request.func.sh` |
| hub fetches and deletes the object with the SA | `git-rel-fetch.func.sh` |
| clean deletes one `dyr-*` prefix, verifies 0 objects with the SA and a cache-busted anonymous GET answering 403 or 404 | `git-rel-clean.func.sh` |
| destroy empties the bucket, then deletes it | `git-rel-destroy.func.sh` |
| URLs are signed **locally** with the SA's private key file (`--private-key-file`), every gcloud call runs under a throwaway `CLOUDSDK_CONFIG` | `git-rel.lib.sh` `_gr_sa_begin`, send/request |
| region `europe-north1`; the doc promises objects expire after 1 day | `git-rel.feature.md` |

Consequences for the bucket: nothing may make an object public; the sender
needs object get/list/create/delete on this bucket and nothing else; a key
file for that SA must exist on the hub.

## 5. The relay bucket in terraform

### 5.1 Steps

| step | creates | state |
|---|---|---|
| `000-gcp-remote-bucket` | `csi-spl-<env>-tfstate`: uniform access, PAP enforced, versioning on, keeps 10 archived versions | local, in the run dir |
| `001-enable-gcp-services` | `storage.googleapis.com`, `iam.googleapis.com` only; never disabled on destroy | gcs |
| `020-gcp-relay-bucket` | `csi-spl-<env>-rel`, SA `csi-spl-rel-<env>`, one bucket IAM binding | gcs |

### 5.2 Decisions

- **Name** (owner, 2026-09-17): `csi-spl-dev-rel`, `csi-spl-prd-rel`.
- **Access model** (owner, 2026-09-17: "the same access model which existing
  for the git-relay bucket"): copied from `bnc-cpt-all-relay` as MEASURED
  read-only that day with its SA through a throwaway `CLOUDSDK_CONFIG`.

| setting | bnc-cpt-all-relay, measured | csi-spl-<env>-rel |
|---|---|---|
| location / class | EUROPE-NORTH1 region / STANDARD | same |
| uniform bucket-level access | true | true |
| public access prevention | enforced | enforced |
| versioning | off | off |
| soft delete | 604800 s | 604800 s |
| lifecycle | none | none (`object_max_age_days: 0`) |
| labels, CORS, retention, logging, website | none | none (the provider's implicit attribution label is switched off) |
| bucket IAM | GCS default legacy bindings only | the same defaults, plus `roles/storage.objectUser` for the relay SA |
| unsigned object GET / anonymous XML listing | 403 / 403 | expected the same |

The earlier description of that bucket as "fine-grained ACLs, public-read
objects, 1-day lifecycle" was wrong on all three counts; git-rel stopped
uploading public-read objects at nea-nfs-orc commit `aba9fbb`.

- **Sender SA, minimum role.** `roles/storage.objectUser` on the bucket only:
  object get/list/create/delete/update, no object IAM, no bucket permission.
  The old bucket's SA reaches its bucket through project `roles/owner`.
  Consequence: `git-rel-destroy`'s final `buckets delete` is refused for the
  new SA; deleting the bucket is terraform's job. Signing needs no
  `iam.serviceAccounts.signBlob`, because git-rel signs with the key file.
- **The SA key is not a terraform resource**: a `google_service_account_key`
  would store the private key in the state bucket in clear. It is minted out
  of band (section 6.3).

### 5.3 Open question

git-rel's doc promises "objects expire after 1 day", but the measured bucket
has no lifecycle rule (13 objects dated the previous day were still in it).
The terraform copies the measurement. To keep git-rel's promise instead, set
`object_max_age_days: 1` in both `csi-spl-cnf/csi-spl/<env>.env.yaml` and
re-render. The owner's call.

## 6. How to operate it

All commands run from `csi-spl-iac` as the box user. Every gcloud call carries
`--account` or runs under a throwaway `CLOUDSDK_CONFIG`; nothing is ever
written to the shared `~/.config/gcloud`.

### 6.1 Create a project

`do_gcp_001_create_project` proves `GCP_ACCOUNT` can mint a token, then reads
whether the project exists (exists / reported absent / could not tell) and
only on "reported absent" creates it; then links billing. **It is a dry run
unless `DRY_RUN=0`**: the dry run prints the create and link commands it would
run.

#### 6.1.1 Dry run

```bash
ENV=dev GCP_ACCOUNT="$GCP_ACCOUNT" GCP_ORG_ID="$GCP_ORG_ID" GCP_BILLING_ACCOUNT_ID="$GCP_BILLING_ACCOUNT_ID" ./run -a do_gcp_001_create_project
```

#### 6.1.2 Create and link (needs the owner's go)

```bash
ENV=dev GCP_ACCOUNT="$GCP_ACCOUNT" GCP_ORG_ID="$GCP_ORG_ID" GCP_BILLING_ACCOUNT_ID="$GCP_BILLING_ACCOUNT_ID" DRY_RUN=0 ./run -a do_gcp_001_create_project
```

Use `GCP_FOLDER_ID` instead of `GCP_ORG_ID` for a folder parent.

#### 6.1.3 Identity notes (measured 2026-09-17)

- The human credentials cached on the box were refused by the org's reauth
  policy for non-interactive use; the operator must log in interactively first.
- No service account on the box held `resourcemanager.projects.create` on the
  csi organization.
- The billing account with spend is visible only to the identity of the org
  that owns it; `gcloud billing accounts list --account "$GCP_ACCOUNT"` shows
  which accounts an identity can link.

### 6.2 Render, plan, apply

#### 6.2.1 Render the tfvars (after any yaml change)

```bash
ENV=dev ./run -a do_tpl_gen
```

#### 6.2.2 Plan one step

`TF_BACKEND=local TF_OFFLINE_PLAN=1` plans with no state bucket and no
credential, for resources that do not exist yet. Once 000 is applied, plan
001 and 020 against the real state with the default `TF_BACKEND=gcs`.

```bash
ENV=dev STEP=020-gcp-relay-bucket ./run -a do_tf_plan
```

The plan is saved to `bin/csi/spl/<env>/<step>/csi-spl-<env>.tfplan`
(git-ignored). Do not plan a step while that same step is being applied from
its run dir: `do_tf_plan` wipes and re-copies the run dir.

#### 6.2.3 Apply a reviewed plan (needs the owner's go)

There is deliberately no apply action. Apply the saved plan, in order 000,
001, 020, dev before prd, under the operator's credentials:

```bash
"$HOME/.local/share/csi-spl/bin/terraform-1.9.8" -chdir=bin/csi/spl/dev/020-gcp-relay-bucket apply csi-spl-dev.tfplan
```

000's state is local: after applying it, keep `bin/csi/spl/<env>/000-gcp-remote-bucket/terraform.tfstate`
safe outside git (it is the only record of the state bucket).

### 6.3 The relay SA key: mint, store, rotate

git-rel signs URLs with the SA's private key file, so a key must exist on the
hub. An org policy `iam.disableServiceAccountKeyCreation` would block this;
check before relying on it.

#### 6.3.1 Mint (needs the owner's go)

```bash
gcloud iam service-accounts keys create "$HOME/.gcp/.csi/key-csi-spl-rel-prd.json" --iam-account=csi-spl-rel-prd@csi-spl-prd.iam.gserviceaccount.com --account="$GCP_ACCOUNT"
```

```bash
chmod 600 "$HOME/.gcp/.csi/key-csi-spl-rel-prd.json"
```

Never print, copy into chat, or commit the file.

#### 6.3.2 Rotate

Mint a new key (6.3.1, to a new file name), switch `GCP_KEY_FILE` to it, run
one git-rel round trip, then delete the old key by id:

```bash
gcloud iam service-accounts keys list --iam-account=csi-spl-rel-prd@csi-spl-prd.iam.gserviceaccount.com --account="$GCP_ACCOUNT"
```

```bash
gcloud iam service-accounts keys delete "$OLD_KEY_ID" --iam-account=csi-spl-rel-prd@csi-spl-prd.iam.gserviceaccount.com --account="$GCP_ACCOUNT"
```

### 6.4 Verify a relay bucket after apply

1. Describe it with the relay SA under a throwaway `CLOUDSDK_CONFIG` and
   compare every row of the table in 5.2.
2. Signed PUT of a test object to `dyr-<32 hex>/probe.gpg` (headers as in
   4.2), expect 200.
3. Signed GET of it: same sha256.
4. Unsigned GET of it and an anonymous listing, cache-busted: both 403. There
   is no "anonymous GET of a public object" check: public access prevention
   makes that impossible, by design.
5. Delete it with the SA; list the prefix: 0 objects.

## 7. Switching git-rel to the new bucket — NOT DONE

nea and osp use `bnc-cpt-all-relay` today. The switch changes nea-nfs-orc's
code, not the spool, and is gated through the orchestrator (no transfer may be
in flight).

1. Apply dev and prd (6.2), mint the prd key (6.3), verify (6.4).
2. In `git-rel.lib.sh` `_gr_defaults`, replace the baked defaults of
   `RELAY_BUCKET` and `GCP_KEY_FILE` with fail-fast env vars (no default URL
   or bucket), with a way to pick dev or prd; prd is `gs://csi-spl-prd-rel`
   with `$HOME/.gcp/.csi/key-csi-spl-rel-prd.json`. Update
   `git-rel.feature.md` in the same change.
3. Prove it with nea-nfs-orc's `src/bash/tests/git-rel-roundtrip.tst.sh`
   against `csi-spl-prd-rel`: send, fetch, clean, and the cache-busted
   anonymous GET after clean.
4. Only then land the switch.

## 8. Retiring bnc-cpt-all-relay — NOT DONE

Owner order: remove it LAST, after the new relay is proven. Irreversible.

1. List its objects with its SA (not anonymously) and report them; it must be
   empty or hold only leftovers nobody is waiting for.
2. The orchestrator confirms no transfer is in flight.
3. Delete it with its SA under a throwaway `CLOUDSDK_CONFIG`, then prove a
   describe returns 404.
4. Record the date and the replacing bucket here.

<!-- keep this section as the retirement record -->
