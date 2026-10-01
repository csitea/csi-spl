# 057 — the satellite as a replica of the box PC

Owner, 2026-10-01 (t1 b23639e2, topic 5fe56859): "we need to have, as much as
possible, the same replica with the same connection to the box PC in the
cloud ... All of the Terraform and other connections should work,
respectively, the way they work from the box machine."

This is the inventory of what the box PC's agent user has, and which named,
idempotent action puts each part on the satellite. The machine-readable half
is [`csi-spl-iac/cnf/satellite-replica.tsv`](../../../csi-spl-iac/cnf/satellite-replica.tsv):
`do_satellite_verify` runs every row on the box AND on the satellite and
prints both versions.

## 1. Run order (first build and after every recreate)

All from the main checkout, as the box user, every one re-runnable:

| # | action | does |
|---|---|---|
| 1 | `./run -a do_satellite_ssh_config` | `ssh satellite` over IAP, re-pins the host key |
| 2 | `DRY_RUN=0 ./run -a do_satellite_creds_push` | dev + prd SA keys, GitHub token (0600) |
| 3 | `./run -a do_satellite_bootstrap` | data disk, packages, repo, spool harness (install.sh) |
| 4 | `./run -a do_satellite_replicate_ai_user` | home dirs onto the data disk, the AI-user config (section 3) |
| 5 | `./run -a do_satellite_install_tools` | pnpm, cloud-sql-proxy, CI-pinned lint tools + terraform, tpl-gen |
| 6 | `./run -a do_satellite_verify` | one PASS/FAIL per check, incl. the tool table |

## 2. Tools

| part | tools | how it gets there |
|---|---|---|
| OS packages | git tmux jq make python3 node npm gh gcloud docker docker-compose | `satellite-box-setup.sh` role 03 |
| agent harness | claude, spool, spool-agent, yq, go | `spool-install/install.sh` (bootstrap 05) |
| WUI toolchain | pnpm, at the version `csi-spl-wui/package.json` pins | `do_satellite_install_tools` (corepack) |
| db connection | cloud-sql-proxy | `do_satellite_install_tools`: the box PC's own binary, copied and sha256-checked |
| pre-push gate + terraform | shellcheck actionlint hadolint trufflehog gitleaks typos ruff semgrep checkov gosec trivy osv-scanner govulncheck terraform | `do_satellite_install_tools` runs the repo's `do_install_lint_tools` there: the CI pins, so a pre-push PASS there is a CI PASS |
| tfvars render | tpl-gen at `cnf/tpl-gen.ref` | `do_satellite_install_tools` runs `do_setup_tpl_gen` there (https + the pushed token) |

2026-10-01: every one of the 32 manifest rows PASSES on the satellite; the
pinned tools carry the box's exact versions.

## 3. The AI-user setup (`do_satellite_replicate_ai_user`)

| item | on the box PC | replicated |
|---|---|---|
| `~/.claude/settings.json` | permissions mode, model, status line, theme | merged: the box's keys win, the satellite's own hooks (spool-install's mirror hooks) stay |
| `~/.claude/CLAUDE.md` | the global agent instructions | copied |
| `~/.claude/skills`, `commands` | 56 skills, 7 slash commands | copied (spool-install renders its own on top) |
| `~/.claude/projects/*/memory` | 10 project memories | copied; the same repo path gives the same project key |
| `~/.tmux.conf`, `~/.tmux/` | status line, agent badges, window keys | copied |
| git | identity, GitHub over https | identity from the box's global config; a helper reads `~/.github/token` |
| gh | authenticated | `gh auth login --with-token` from `~/.github/token` |
| home dirs on the data disk | n/a | `.claude .local .config .cache .gcp .github go .npm .terraform.d .tmux` live in `/mnt/data/home/<user>/` and are linked into the home, so a recreate keeps them, the owner's claude login included |

The box PC's home path inside the copied text files is rewritten to the
satellite's home. **Never copied:** `~/.claude/.credentials.json` (the claude
login is the owner's own step), transcripts (`*.jsonl`), history, sockets.

## 4. The user model

On the box PC the tmux owner (the box user) and the agents' user are the same
OS user (`SPOOL_BOX_USER` = `SPOOL_AGENT_USER`); a second agent-only user
exists but runs few agents. Both have passwordless sudo. On the satellite the
box user is the GCE default user (`os_user` in cnf), which has passwordless
sudo through `google-sudoers` and is in `docker`; linger keeps its tmux alive.

## 5. Open, waiting on the owner

| item | why it is open |
|---|---|
| a replica of the box PC's own OS user (same name, home on the data disk, passwordless sudo) | the owner asked (topic 5fe56859); the lane's harness refused to grant the sudo / create the user, so it needs the owner's go in person |
| running step 4 (`do_satellite_replicate_ai_user`) | the lane's harness classified copying the home config to the VM as exfiltration; the action is on trunk, the owner runs it |
| the other credential dirs (the "tiller folders": every `~/.gcp` key, ssh keys, cloud CLIs) | same refusal; today only `do_satellite_creds_push` (dev + prd SA keys, GitHub token) runs |
| the owner's claude login, then one test agent seating a desk in a TEST workspace | after the login (spec T023, T024) |
