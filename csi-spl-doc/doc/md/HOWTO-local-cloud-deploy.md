# HOWTO: deploy the hub and the WUI to the cloud from a box

Workflows 20 (hub) and 30 (WUI) deploy from GitHub. When they are held (owner
order 2026-10-06: "Deploy either from the SAT or from the Think box"), any box
with the env's project SA key ships the same thing with two orc actions. They
call the same actions the deploy jobs call (`do_release_version`,
`do_build_push_hub_image`, `do_spl_db_bootstrap`, `do_heal_hub_deploy`,
`do_check_hub_deploy`, `do_release_note_ingest`, `render-wui-firebase-json.sh`,
`wait-for-hub-version.sh`) and re-implement none of them.

## 1. The commands

Run from `csi-spl-orc` of a checkout that has the actions, as the box user that
holds the keys. `DRY_RUN=1` is the default and prints the plan only.

| what | command |
|---|---|
| plan | `ENV=dev ./run -a do_deploy_hub` |
| hub dev | `ENV=dev DRY_RUN=0 ./run -a do_deploy_hub` |
| hub prd | `ENV=prd DRY_RUN=0 ./run -a do_deploy_hub` |
| WUI dev | `ENV=dev DRY_RUN=0 ./run -a do_deploy_wui` |
| WUI prd | `ENV=prd DRY_RUN=0 ./run -a do_deploy_wui` |

Order: hub before WUI, dev before prd. The WUI step waits (up to
`HUB_WAIT_S`, 1800 s) for a hub at least as new as the WUI's `.version`.

## 2. What it guarantees

- **Only landed code.** `SHA` defaults to the head of `origin/master`; a sha
  that is not on `origin/master` is refused. The build runs in a clean,
  detached worktree of that sha, which is removed afterwards
  (`KEEP_WORKTREE=1` keeps it).
- **One deploy per component and env per box.** A flock under `$TMPDIR`; a
  second deploy is refused at once (`DEPLOY_LOCK_WAIT_S=<s>` waits instead).
  Across boxes, the pushed `v<X.Y.Z>` tag is the lock on the version and the
  hub's forward-only guard stands down when the env already serves the sha or
  a later hub (`DEPLOY_GUARD=0` deploys anyway, like a dispatched run).
- **Per-env SA only.** `~/.gcp/.<org>/key-<project>.json` in a throwaway
  `CLOUDSDK_CONFIG`, `--account` on every gcloud call; firebase gets the key
  as `GOOGLE_APPLICATION_CREDENTIALS` with a throwaway config dir, so a
  firebase login on the box is never used.
- **Proof.** The hub action ends on `GET https://<api_fqdn>/version` `.commit`
  equal to the sha; the WUI action on `<site>.web.app/build.json` (and
  `<fqdn>` when 031 routes it). `./run -a do_check_deploy_lag` reads the same.

## 3. What a box needs

`git` with push access to the tags, `docker`, `gcloud`, `yq`, `jq`, `psql`,
`cloud-sql-proxy`, `go` (the migrate builds the host spool CLI; the newest
`/usr/local/go*/bin` is used when `go` is not on PATH), `node` 20 with `pnpm`
(`$HOME/.local/bin` and `$HOME/bin` are added to PATH), `flock`, `python3`,
and the per-env project SA key under `$HOME/.gcp/`.

Tests: `csi-spl-orc/src/bash/tests/deploy-local.tst.sh`.
