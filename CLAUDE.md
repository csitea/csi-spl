# csi-spl — "the spool"

One git repository (`github.com/csitea/csi-spl`, trunk `master`) for the spool:
the GCP estate that carries **git-rel**, the gpg-encrypted signed-URL relay
between the hub and the boxes. Nothing else lives here: no api, no wui, no rdb.

| dir | holds |
|---|---|
| `csi-spl-api` | Go module (`src/go/spool-hub-api`) for spool box CLI, MCP server, and Cloud Run hub API |
| `csi-spl-wui` | Nuxt 3 + TypeScript Slack-like WUI (M3). lde is `pnpm dev`; ship is `nuxt generate` to Firebase Hosting (`016`/`019`). Hub API stays on Cloud Run. |
| `csi-spl-iac` | `./run` actions (GCP project bootstrap, the csi-rel `gcp-*` and `tf-*` actions, `do_provision`) and the terraform steps |
| `csi-spl-orc` | Local dev orchestration (`lde`), the terraform infra stack (`make do-setup-app-inf`: `con-csi-csi-spl-{tf-runner,tpl-gen,conf-validator}`) and its `make do-tf-*` targets, test DB, test dispatch |
| `csi-spl-cnf` | `csi-spl/<env>.env.yaml`, the single source of truth; tpl-gen renders `csi-spl/<env>/tf/*.tfvars` from it |
| `csi-spl-doc` | `doc/md/csi-spl.feature.md` — start there |
| `csi-spl-dat`, `csi-spl-utl` | README only, until they have content |
| `tpl-gen/` | git-ignored sibling clone, pinned by `csi-spl-iac/cnf/tpl-gen.ref` |

## Environments

`dev` and `prd` only. GCP projects `csi-spl-dev` / `csi-spl-prd`, region
`europe-north1`. The org (`env.gcp.gcp_org_id`) and the owner account
(`env.gcp.gcp_account_owner_email`) are cnf in
`csi-spl-cnf/csi-spl/all.env.yaml` (an env file may override), and the ONLY
place those literals live; `GCP_ORG_ID` / `GCP_FOLDER_ID` still override the
org. The billing account stays an **environment variable that fails fast**
(`GCP_BILLING_ACCOUNT_ID`) — never commit it.

### Service accounts only, per environment (owner rule 2026-09-19)

> "once the service account keys are provisioned, then you should be using
> only the service accounts per environment for everything. You should not be
> using the owner account." — "You should be using the service account keys."

- Every shell wrapper resolves the identity once via `do_gcp_account` /
  `do_gcp_pin_account`: `ACCOUNT` > `GCP_ACCOUNT` > the per-env project SA
  from its key `~/.gcp/.csi/key-csi-spl-<env>.json` (its `client_email`,
  activated in a throwaway `CLOUDSDK_CONFIG`) > **refuse**. No fallback to
  the owner account, and never to the active gcloud account.
- `gcp_account_owner_email` is read ONLY by the human bootstrap gcp-000..004
  (`do_gcp_pin_bootstrap_account`), which mints those keys, and only while no
  key exists yet.
- Nothing writes the shared `~/.config/gcloud`; `--account` on every call.
- A key that lacks a permission is reported, never worked around with the
  owner account.
- Gate: `csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`.

### Nothing ad hoc: every infra step is a named action (owner rule 2026-09-19)

> "Nothing in the infrastructure should be run ad hoc. Whenever it is
> executable via Terraform or via some Bash script, we create a Bash script
> and we execute it via Terraform. Nothing should be ad hoc. For anything you
> provision ad hoc, there should be a shell action wrapper for that with a
> proper naming convention and the thing should stay in the source code so
> that next time, when we are using it, we will reuse it."

How to apply:
- csi-rel naming: `<verb>-<noun>.func.sh` exposing `do_<verb>_<noun>`,
  invoked as `./run -a do_<verb>_<noun>`. Infra actions live in `csi-spl-iac`
  (`src/bash/run/`); local orchestration in `csi-spl-orc`.
- Terraform only via the make / tf-runner path (below), never on the host.
- A one-off need (a gcloud command you would type once) becomes a named action
  plus its test in the same commit, then runs through that action.

## Rules specific to this repo

- **Nothing mutates GCP without the owner.** `gcloud projects create`, a
  billing link, an IAM change and `terraform apply` each need an explicit go.
  The gcp-000..004 bootstrap is a dry run unless `DRY_RUN=0`. The destructive
  `gcp-*` actions (project delete, SA delete, apis disable, lb cleanup) are
  never run without the owner's go for that call.
- **Terraform runs only in the tf-runner container, never on the host**
  (csi-rel's path, flow map: `csi-spl-doc/specs/007-spool-hub-api-infra/csi-rel-flow-map.md`).
  From the main checkout: `cd csi-spl-orc && ENV=<env> STEP=<step> make do-tf-plan`,
  then `make do-provision` with the owner's go. `do_tf_init` sets
  `GOOGLE_APPLICATION_CREDENTIALS` to the project key
  `~/.gcp/.csi/key-csi-spl-<env>.json`. Tfvars are rendered with
  `make do-generate-config-for-step` (conf-validator, then tpl-gen).
  - **One run per env + step at a time**: `do_tf_init` wipes
    `csi-spl-iac/bin/csi/spl/<env>/<step>` first, so two concurrent runs on
    the same env and step break each other.
  - **One infra stack per box**, mounting the tree that last ran
    `make do-setup-app-inf` (which does `down --rmi all`). Run it only from
    the main checkout, and not while someone is applying.
- **Every gcloud call carries `--account`, or runs under a throwaway
  `CLOUDSDK_CONFIG`.** The box's `~/.config/gcloud` is shared by every agent;
  never `gcloud config set` anything in it.
- **No key in git, in terraform state or in a log.** The relay SA key is minted
  out of band (doc section 6.3); terraform never creates it.
- The relay contract is git-rel's, not ours: before changing bucket semantics
  read the git-rel sources named in the doc, section 4.
- Tests: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh`. Keep them green.
- **Run the cheap gate for the tree you touched, before you push.** Measured
  2026-09-21 (`csi-spl-doc/specs/016-spool-testability/ci-gate-reliability-2026-09-21.md`):
  42 red runs that day were SIX defects — each one red for the 5..20 minutes
  and the 4..12 other pushes that landed before its lane fixed it. Every one of
  them was catchable locally in under a minute:

  | you touched | run first |
  |---|---|
  | anything at all | `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (~1 s) |
  | `csi-spl-cnf/**`, a tfvars, an image tag | `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code` |
  | `csi-spl-wui/**` | `pnpm run typecheck` |
  | `csi-spl-wui/**`, anything the browser renders | `BASE_URL=<generated bundle> pnpm run test:e2e` — typecheck does not drive Chrome |
  | `csi-spl-api/**` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` |

  The pre-push HOOK runs `do_check_pre_push` in its FAST tier (CLE-77824,
  owner 2026-10-01; it had grown to 16 min for iac and >10 min for api, so
  pushes race-lost trunk for hours). It runs only the parts the push touches
  (`origin/master...HEAD`), re-uses a part's green verdict while the paths that
  part reads are unchanged (a rebase over other lanes' commits re-runs
  nothing), FAILS on a missing tool instead of WARNing, and writes one
  `PART <part> PASS|PASS-cached|WARN-pre-existing trunk=<sha>|FAIL|SKIP-untouched <secs>`
  line per part to `~/.cache/csi-spl/pre-push.log`. Moved to CI only, because
  each costs minutes and workflow 10 (and the 20 deploy gate) already runs it
  on every push and fails on a skip: api `go test -race` (plain `go test`
  stays), `build-stripped`, `hub-pg` (~384 s), `hub-gcs`; iac tests whose
  header says `# pre-push-tier: slow` (terraform validate, tpl-gen renders).
  Touching the store or a migration: run `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.

  Pushing onto a red trunk is NOT the thing to avoid — that just serialises the
  fleet and punishes lanes that did nothing. Landing the red is.
- **A control that has to turn trunk red belongs on a throwaway branch**
  (`gh workflow run <file> --ref <branch>`), not on trunk. In the run list a
  deliberate plant is indistinguishable from a defect, and the next person to
  read that list spends an hour proving it was intentional.
- What is red lately, per JOB rather than per run:
  `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`.
  Counted per run, one bad line reads as twelve broken pipelines.
- **Spool posts are markdown, no fence needed** (owner, 2026-09-26, SPL-975):
  the one rule is `csi-spl-doc/doc/help/how-to-post.md`; point to it, never
  restate it.
- **Never roll the version by hand** (owner, 2026-09-27: "we should have been
  at 1.3 by now"). Every hub (20) and WUI (30) deploy mints its commit's
  version with `do_release_version`: a `v<X.Y.Z>` git tag, one odometer step
  past the highest tag, claimed by pushing it (the remote is the lock). The hub
  image tag, `/version` and the WUI footer + `build.json` all show it.
  `.version` = cnf `hub.image.tag` is only the FLOOR: raise it (all 9 files,
  still 0-9 digits) only for a deliberate jump such as 2.0.0. What is live:
  `git ls-remote --tags origin 'v*'`.
- Commits: `Yordan Georgiev <yordan.georgiev@csitea.net>`, no AI trailers,
  explicit pathspecs.
