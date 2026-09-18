# csi-spl — "the spool"

One git repository (`github.com/csitea/csi-spl`, trunk `master`) for the spool:
the GCP estate that carries **git-rel**, the gpg-encrypted signed-URL relay
between the hub and the boxes. Nothing else lives here: no api, no wui, no rdb.

| dir | holds |
|---|---|
| `csi-spl-api` | Go module (`src/go/spool-hub-api`) for spool box CLI, MCP server, and Cloud Run hub API |
| `csi-spl-wui` | Nuxt 3 SSR + TypeScript web application: read-only thread viewer (referencing `pas-psf-wui`) |
| `csi-spl-iac` | `./run` actions (GCP project bootstrap, tpl-gen, terraform init/validate/plan) and the terraform steps |
| `csi-spl-orc` | Local dev orchestration (`lde`), container runner (`con-spl-tf-runner`), test DB, test dispatch (referencing `pas-psf-orc`) |
| `csi-spl-cnf` | `csi-spl/<env>.env.yaml`, the single source of truth; tpl-gen renders `csi-spl/<env>/tf/*.tfvars` from it |
| `csi-spl-doc` | `doc/md/csi-spl.feature.md` — start there |
| `csi-spl-dat`, `csi-spl-utl` | README only, until they have content |
| `tpl-gen/` | git-ignored sibling clone, pinned by `csi-spl-iac/cnf/tpl-gen.ref` |

## Environments

`dev` and `prd` only. GCP projects `csi-spl-dev` / `csi-spl-prd`, region
`europe-north1`. The org/folder, the billing account and the operator identity
are **environment variables that fail fast** (`GCP_ORG_ID` or `GCP_FOLDER_ID`,
`GCP_BILLING_ACCOUNT_ID`, `GCP_ACCOUNT`) — never commit them.

## Rules specific to this repo

- **Nothing mutates GCP without the owner.** `gcloud projects create`, a
  billing link, an IAM change and `terraform apply` each need an explicit go.
  `do_gcp_001_create_project` is a dry run unless `DRY_RUN=0`; there is no
  apply action.
- **Every gcloud call carries `--account`, or runs under a throwaway
  `CLOUDSDK_CONFIG`.** The box's `~/.config/gcloud` is shared by every agent;
  never `gcloud config set` anything in it.
- **No key in git, in terraform state or in a log.** The relay SA key is minted
  out of band (doc section 6.3); terraform never creates it.
- The relay contract is git-rel's, not ours: before changing bucket semantics
  read the git-rel sources named in the doc, section 4.
- Tests: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh`. Keep them green.
- Commits: `Yordan Georgiev <yordan.georgiev@csitea.net>`, no AI trailers,
  explicit pathspecs.
