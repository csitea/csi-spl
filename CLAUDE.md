# csi-spl — "the spool"

One git repository (`github.com/csitea/csi-spl`, trunk `master`) for the spool:
the GCP estate that carries **git-rel**, the gpg-encrypted signed-URL relay
between the hub and the boxes. Nothing else lives here: no api, no wui, no rdb.

| dir | holds |
|---|---|
| `csi-spl-api` | Go module (`src/go/spool-hub-api`) for spool box CLI, MCP server, and Cloud Run hub API |
| `csi-spl-wui` | Nuxt 3 + TypeScript Slack-like WUI (M3). lde is `pnpm dev`; ship is `nuxt generate` to Firebase Hosting (`016`/`019`). Hub API stays on Cloud Run. |
| `csi-spl-iac` | `./run` actions (GCP project bootstrap, tpl-gen, terraform init/validate/plan) and the terraform steps |
| `csi-spl-orc` | Local dev orchestration (`lde`), container runner (`con-spl-tf-runner`), test DB, test dispatch (referencing `pas-psf-orc`) |
| `csi-spl-cnf` | `csi-spl/<env>.env.yaml`, the single source of truth; tpl-gen renders `csi-spl/<env>/tf/*.tfvars` from it |
| `csi-spl-doc` | `doc/md/csi-spl.feature.md` — start there |
| `csi-spl-dat`, `csi-spl-utl` | README only, until they have content |
| `tpl-gen/` | git-ignored sibling clone, pinned by `csi-spl-iac/cnf/tpl-gen.ref` |

## Environments

`dev` and `prd` only. GCP projects `csi-spl-dev` / `csi-spl-prd`, region
`europe-north1`. The operator identity and the org (owner rule 2026-09-19) are
cnf: `env.gcp.gcp_account_owner_email` / `env.gcp.gcp_org_id` in
`csi-spl-cnf/csi-spl/all.env.yaml` (an env file may override), and the ONLY
place those literals live. Every shell wrapper resolves the account once via
`do_gcp_account` (`ACCOUNT` > `GCP_ACCOUNT` > the yaml; never the active gcloud
account) and passes `--account` on every gcloud call; `GCP_ORG_ID` /
`GCP_FOLDER_ID` still override the org. The billing account stays an
**environment variable that fails fast** (`GCP_BILLING_ACCOUNT_ID`) — never
commit it. Gate: `csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`.

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
