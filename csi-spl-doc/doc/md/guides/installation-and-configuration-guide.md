> Generated from qto doc `8e8454fe-c146-4bce-b705-b24a1a89772c`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The Qto doc `8e8454fe-c146-4bce-b705-b24a1a89772c` (workspace `system`, repo tree) is the primary copy of this guide; edit it there, not the exported md file.

<a id="ws-doc-bb20d955-e70f-4af7-a912-52c768945731"></a>
# 1 About this guide

This guide takes an operator from an **empty Debian 13 box** to a running box of the spool fleet: OS packages, the two users, the checkout, the agent harness, the credentials, the cnf, the crons, the desks, the leases and the first checks. Its first test is the worst case: **both fleet boxes are gone**.

It is one of four guides, kept as Qto documents in the t1 workspace, folder *System documentation*:

| guide | answers |
|---|---|
| System guide | what the parts are and how they connect |
| **Installation and configuration guide** (this one) | how a box is built and configured, from nothing |
| DevOps guide | the GCP estate: bootstrap gcp-000..004, terraform, Cloud Run, Cloud SQL, Firebase, CI workflows, runners, restore from backup |
| Operations and maintenance guide | the daily and weekly routine on a running fleet, incidents and their fixes |

Each fact here points to the file or action it comes from on `origin/master`. Where a step has no named action today, it says so and the step is listed in section 14 (gaps). The fleet rules themselves (one home each) are in [fleet-rules-index.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/fleet-rules-index.md); the coding rules in the [developer guide](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/developer-guide.md).

<a id="ws-doc-4d3163b5-71a1-4e3b-bcd4-897f9d99c62d"></a>
## 1.1 What you hold before you start

| item | what for |
|---|---|
| the GitHub repo `csitea/csi-spl` and a token that can read and push it | the checkout, every action, the CI |
| an empty Debian 13 (trixie) box with sudo, reachable over ssh | the new fleet box |
| the GCP organisation owner login | ONLY the one-time project bootstrap gcp-000..004, and only while no service-account key exists (DevOps guide) |
| the credentials handed over out of band (section 5) | the service-account keys, the GitHub token, the tenant root keys, the vendor API keys |
| a browser | the interactive AI CLI logins (section 7.5) |

Nothing else: no knowledge from chat, memory or a running box.

<a id="ws-doc-0aec5946-ebbf-4bfa-897b-cd81b27a6910"></a>
## 1.2 Conventions

| placeholder | means |
|---|---|
| `<BOX>` | this box's desk box id and tag (box.env `SPOOL_DESK_BOX`, `SPOOL_BOX_TAG`) |
| `<OWNER_USER>` | the box user: owns tmux, the UI, `/opt/csi`, the desks, the crons |
| `<AGENT_USER>` | the user every AI CLI agent runs as (never the owner user) |
| `<ENV>` | `dev` or `prd` |
| `<TENANT>` | a workspace slug, e.g. `t1` |
| `<CHECKOUT>` | the main checkout, `/opt/csi/csi-spl` |

Every `./run -a do_*` action is a dry run unless `DRY_RUN=0` when it writes anything; run the dry run first, read it, then repeat with `DRY_RUN=0`. Every action is idempotent: re-running a step that is done changes nothing. Run actions as `<OWNER_USER>` from the main checkout, never from an agent worktree (most installers refuse a worktree).

<a id="ws-doc-b706945b-439a-4d33-abe1-b2784a6742e1"></a>
# 2 The disaster path: both boxes are gone

<a id="ws-doc-8c19539e-72df-4ef2-9b21-5bca57aeeec2"></a>
## 2.1 What survives without the boxes

| part | where it lives | survives |
|---|---|---|
| code, specs, docs, tags `v<X.Y.Z>` | GitHub `csitea/csi-spl` | yes |
| hub API, database, web UI, buckets | GCP projects `csi-spl-dev` / `csi-spl-prd` (Cloud Run, Cloud SQL, Firebase Hosting, GCS) | yes: they do not run on a box |
| the satellite VM definition | terraform step `060-gcp-vm-satellite` + its Ansible playbook, in the repo | yes; the VM itself may be gone |
| each box's nightly state backup (transcripts, spool root, state dirs; never keys) | the env's box-state bucket, terraform step `056-gcs-box-state`, 30 days | yes ([box-state-backup.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/box-state-backup.md)) |
| the self-hosted CI runners | they ran ON the boxes | **no**: hub and WUI deploys (wf 20 / 30) wait until a runner is registered again (DevOps guide) |
| agent worktrees, unpushed commits | the boxes | **no**: git is the only backup |
| AI CLI logins, desk box keys | the boxes' homes and desk state | **no**: log in again (7.5), re-seat the desks (10.1) |

<a id="ws-doc-cbc38386-2850-4eb3-9dbc-74c0cedb42b7"></a>
## 2.2 The order

Follow the sections in this order. Each one ends in a check.

| step | section | result |
|---|---|---|
| 1 | 3 The OS: packages and users | Debian packages, `<OWNER_USER>`, `<AGENT_USER>`, groups, sudo |
| 2 | 4 The checkout | `/opt/csi/csi-spl` on master, tpl-gen at its pin, the pre-push hook |
| 3 | 5 Credentials | every key and token in its place, 0600 |
| 4 | 6 Spool root and box config | `/var/spool-hub`, `box.env` |
| 5 | 7 The agent harness | spool, spool-agent, the CLIs, CLAUDE.md, skills, settings, logins |
| 6 | 8 Configuration | cnf read, tfvars rendered |
| 7 | 9 The server side | crons and long-lived processes, dev and prd |
| 8 | 11 Restore the box state | transcripts, spool root, state from the last nightly backup |
| 9 | 10 Desks, role seats, leases, tmux | the box answers in the workspaces, the fleet lease runs |
| 10 | 12 The second box | the satellite rebuilt from terraform 060 |
| 11 | 13 First boot checks | every check green |

When the GCP projects themselves are gone too, start with the DevOps guide (bootstrap gcp-000..004 and the terraform steps), then come back here. For a joined **macOS box** (where the macOS steps replace the Debian commands of sections 3, 6 and 7), see [17 macOS box](#17-macos-box).

<a id="ws-doc-33cbd53a-c492-4b81-a9a9-19a2199d3969"></a>
# 3 The OS: packages and users

<a id="ws-doc-81b2550a-0ade-47e9-b0a5-51309f3f95a7"></a>
## 3.1 Debian packages

The satellite gets its packages from Ansible role `02_os_binaries` ([main.yml](https://github.com/csitea/csi-spl/blob/master/csi-spl-iac/src/terraform/060-gcp-vm-satellite/roles/02_os_binaries/tasks/main.yml)). A box that is not the satellite has no named action for this yet (gap 14.1), so install the bootstrap set by hand, then let `do_spl_box_deploy` (section 9) name and install anything still missing.

```bash
sudo apt-get update && sudo apt-get install -y tmux git curl wget ca-certificates gnupg jq python3 python3-venv perl util-linux rsync acl sudo make unzip zip build-essential docker.io docker-compose nodejs npm gh htop postgresql-client pandoc zstd cron
```

<a id="ws-doc-9221d746-1173-4af7-8518-0feb1174a0d5"></a>
## 3.2 The Google Cloud CLI

From Google's apt repo, as role `02_os_binaries` does (the key, the repo line, then `google-cloud-cli`). Follow Google's Debian instructions for the repo; no named action does it on a non-satellite box (gap 14.1). Check:

```bash
gcloud version
```

<a id="ws-doc-6920b4f3-2510-4c40-a457-c863984e9c39"></a>
## 3.3 Go, yq, Node, pnpm

- **Go**: the version in `csi-spl-api/src/go/spool-hub-api/go.mod`. The harness installer (section 7) downloads it into the user's tools dir when it must build `spool`; the CI and the cron PATH use `csi-spl-api/src/bash/use-go-toolchain.sh`. The satellite puts it in `/usr/local/go` (role 02).
- **yq v4**: installed per user by `install.sh` (section 7).
- **Node and pnpm**: Node from Debian; pnpm through corepack at the WUI's pin (`csi-spl-wui/package.json` `packageManager`), as role `09_agent_tools` does.
- **The CI-pinned scanners** (shellcheck, actionlint, hadolint, trufflehog, gosec, eslint, checkov, semgrep) are needed by the pre-push gate. To install them for every user, run:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && LINT_TOOLS_SYSTEM=1 ./run -a do_install_lint_tools
```

<a id="ws-doc-e5683bd2-736d-4277-b52d-5a686a47ba9a"></a>
## 3.4 The two users

The owner rule ([global CLAUDE.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md) block "Claude Code instances start as"): `<OWNER_USER>` runs tmux, the UI, the desks and the crons; `<AGENT_USER>` runs every AI CLI. They must be equivalent in access. On the satellite, role `05_users` makes them (uids 2000 / 2001, names from cnf `steps.060-gcp-vm-satellite` `box_owner_user` / `box_agent_user`). On any other box this is by hand today (gap 14.2). What the result must be:

| property | value |
|---|---|
| users | `<OWNER_USER>` and `<AGENT_USER>`, each with a home and bash |
| groups | both in `sudo`, `docker` and `spool-agents` (cnf `env.box.spool_root_group`); `<AGENT_USER>` also in `<OWNER_USER>`'s group |
| sudo | NOPASSWD for both, so `sudo -u <OWNER_USER>` works from the agent and back |
| linger | `loginctl enable-linger` for both, so tmux survives logouts |
| `/opt/csi` | owned by `<OWNER_USER>`, setgid, default ACL group rwx |

Check from the agent user that it can act as the box user:

```bash
sudo -n -u <OWNER_USER> true && echo ok
```

<a id="ws-doc-19e4f24b-326c-4ec5-8433-f5714c77d27e"></a>
## 3.5 Timezone and ssh

The fleet boxes run `Europe/Helsinki` (role `03_timezone`); the box restart slots in cnf `env.box.restart` are read in that zone. sshd: keys only, no root login (role `04_ssh_hardening`).

```bash
sudo timedatectl set-timezone Europe/Helsinki
```

<a id="ws-doc-4fc3456e-a344-4733-9a6b-4474518ad108"></a>
# 4 The checkout

<a id="ws-doc-2cec61e2-5de6-4041-8ebe-0cbb8227e5c3"></a>
## 4.1 Clone the repo

As `<OWNER_USER>`, into `/opt/csi/csi-spl` (on macOS, into `/Users/<OWNER_USER>/opt/csi/csi-spl`; see section 17.4), with the GitHub token of section 5 (gh reads it; `gh auth login --with-token` takes it on stdin). Both users need git and gh logged in (role `08_spool_harness` does it from `~/.github/token`).

```bash
git clone https://github.com/csitea/csi-spl.git /opt/csi/csi-spl
```

<a id="ws-doc-587eb087-8c39-442f-a267-8bcbaa9b6514"></a>
### 4.1.1 Check the gh login

Run this as both users once the token is in place. It prints the account gh is logged in as; "not logged in" means the token step did not run for that user.

```bash
gh auth status
```

<a id="ws-doc-603eac40-edcb-40e5-b447-270f4f2805fb"></a>
## 4.2 Identity for commits

Never `git config` in a shared tree: pass the identity on each commit and rebase with `-c user.name=... -c user.email=...`. The address is the one on the repo CLAUDE.md "Commits:" line; no AI trailers ([developer guide](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/developer-guide.md) 2.4). A commit, with the name and address from that line:

```bash
git -c user.name="FirstName LastName" -c user.email=<COMMIT_EMAIL> commit -m "<why>"
```

<a id="ws-doc-6c0c38e1-1d28-4704-9c0d-eb53c84e103d"></a>
## 4.3 Read and acknowledge the developer guide

Every coder, human or agent, confirms it once per guide version; the pre-push hook refuses a push without it.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_dev_guide_ack
```

<a id="ws-doc-ab2e7cd6-a288-410e-a23d-939a35c86a29"></a>
## 4.4 tpl-gen at its pin

tpl-gen renders the tfvars from cnf. It is a git-ignored sibling clone pinned by `csi-spl-iac/cnf/tpl-gen.ref`, with its own `.venv`.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_setup_tpl_gen
```

<a id="ws-doc-a38cbc03-3ea2-456f-98a8-7773e20a1321"></a>
## 4.5 The pre-push hook

One hook in the common git hooks dir gates the main checkout and every worktree ([pre-push-gate.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/pre-push-gate.md)). The spawn launcher installs it for each new worktree; for the main checkout run the script once:

```bash
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/install-pre-push-hook.sh /opt/csi/csi-spl
```

<a id="ws-doc-bfba7cd2-9b69-446b-bf24-11ddb6c02cd0"></a>
## 4.6 The self-updating cron checkout

The crons run from `<CHECKOUT>-desk-cron` (`/opt/csi/csi-spl-desk-cron`), a second clone that fast-forwards itself, so a worktree that vanishes never breaks a cron. `do_spl_desk_install_service` creates it when missing (section 9.2); nothing to do by hand.

<a id="ws-doc-49a57b61-24fc-48f4-b53a-9cab5d5e9cf9"></a>
# 5 Credentials: what and where

Never copy a secret value or a key file into a doc, a post, a commit or a log. This section names each credential and where it lives; the values are handed over out of band. The data rule: only claude, grok or mistral lanes may handle them ([fleet rules index](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/fleet-rules-index.md)).

<a id="ws-doc-39719404-4513-42cd-b3ee-8e20dbc0778a"></a>
## 5.1 The table

| credential | where on the box | mode | placed by |
|---|---|---|---|
| per-env GCP service-account keys (`dev`, `prd`) | `~/.gcp/.csi/key-csi-spl-<ENV>.json` of BOTH users | file 0600, dir 0700 | out of band; satellite: role `06_secrets`, or `do_box_copy_gcp_key` from a box that has them |
| the `csi-spl-all` project key (satellite terraform, IAP, verify) | `~/.gcp/.csi/key-csi-spl-all.json` of `<OWNER_USER>` | 0600 | out of band, or minted again by `ENV=all ./run -a do_gcp_000_bootstrap_gcp_env` (owner login, DevOps guide) |
| GitHub token | `~/.github/token` of both users | 0600 | out of band |
| tenant root key, one per workspace | a 0600 JSON outside git (the file `do_spl_tenant_create` wrote, field `root_private_key`); passed as `ROOT_KEY_JSON`, or a directory of `<workspace>.json` as `DISPATCH_ROOT_KEY_DIR` | 0600 | out of band; needed only for a desk's FIRST pin (10.1) |
| desk box keys | minted by the first `do_spl_desk_up` under the desk state dir (0700, `keys/`) | 0600 | never copied: a new box mints new ones and pins them |
| AI CLI logins | each vendor's dir in `<AGENT_USER>`'s home | vendor's | interactive login (7.5) |
| Mistral API key | `<AGENT_USER>`'s `~/.vibe/.env` | 0600 | `do_set_mistral_key` (7.4) |
| GCP billing account id | the environment variable `GCP_BILLING_ACCOUNT_ID` only, never a file in git | n/a | the operator, per command (DevOps guide) |
| satellite ssh key pair | minted locally by `do_satellite_ssh_keygen`; terraform reads only the `.pub` | 0600 | the action (12) |
| GitHub App key, vendor key pepper, other hub secrets | GCP Secret Manager, not the box | n/a | DevOps guide |

The GCP rule: once the per-env keys exist, everything runs as the per-env service account, never the owner account (repo [CLAUDE.md](https://github.com/csitea/csi-spl/blob/master/CLAUDE.md), "Service accounts only, per environment").

<a id="ws-doc-66b6a91b-501b-4fb7-a467-a50650c2af2c"></a>
## 5.2 Check the keys are in place

Presence and mode only; the action never prints a key. It is part of the box deploy check (9.1). By hand, the modes:

```bash
stat -c '%a %U %n' ~/.gcp/.csi/key-csi-spl-dev.json ~/.gcp/.csi/key-csi-spl-prd.json ~/.github/token
```

<a id="ws-doc-e8ecb4c0-f83f-4ffd-ab58-4466fd6c0640"></a>
# 6 Spool root and box config

<a id="ws-doc-ac9cf423-87e8-4982-8c58-1f2ebf3d3567"></a>
## 6.1 The spool root

`/var/spool-hub` (cnf `env.box.spool_root`): every agent's inbox, outbox and archive, the dispatch dir, the identity map. Owned by the group `spool-agents`, setgid, ACLs (spec 017 FR-SEC-001). On a new box `do_repair_spool_root` creates the group, adds its members and makes the root (as root, through `sudo -n`); it is a dry run unless `DRY_RUN=0`:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && SPOOL_ROOT_MEMBERS="<OWNER_USER> <AGENT_USER>" DRY_RUN=0 ./run -a do_repair_spool_root
```

<a id="ws-doc-9491371f-8b7d-40ad-8ce5-6a577058a096"></a>
## 6.2 Provision and verify the root

Idempotent; re-running repairs drift.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_provision_spool_root
```

<a id="ws-doc-4de1925b-daff-4a3b-8e1b-1f1491a98006"></a>
## 6.3 box.env

`<spool root>/box.env` holds the defaults every spawn and restore on this box resolves: the agent user, the CLI paths, the desk box, the box tag, the fleet env and tenant, the login peers. Keys: `SPOOL_AGENT_USER SPOOL_RUN_AS_AGENT CLAUDE_BIN GROK_BIN AGY_BIN QWEN_BIN MISTRAL_BIN SPOOL_AGENT_ID_RANGE SPOOL_DESK_BOX SPOOL_FLEET_ENV SPOOL_FLEET_TENANT SPOOL_DIR_LAYOUT SPOOL_BOX_TAG SPOOL_LOGIN_PEERS` (`spawn-agents/lib/spool-env.inc.sh`). Two boxes of one fleet need different `SPOOL_DESK_BOX` and `SPOOL_BOX_TAG`.

```bash
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/box-config.sh SPOOL_AGENT_USER=<AGENT_USER> SPOOL_DESK_BOX=<BOX> SPOOL_BOX_TAG=<BOX> SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=<TENANT>
```

<a id="ws-doc-a7b57f85-04fc-4de9-9a8d-ed1d9afe384c"></a>
# 7 The agent harness

<a id="ws-doc-7e7f41fe-efdf-4144-8b29-a273837878be"></a>
## 7.1 What install.sh installs

`csi-spl-orc/src/bash/features/spool-install/install.sh` (spec 037) installs the harness for the user who runs it, under that user's home, without sudo: the agent CLIs picked with `--cli`, yq, the `spool` binary (downloaded from the newest stable release, built from the checkout when that is impossible), the `spool-agent` shim, the terminal mirror hooks, the slash commands and skills, the tmux snippet. With `--fleet` it also writes the fleet's `~/.claude/CLAUDE.md` block (from `spool-install/assets/claude/claude-md`), the settings (`assets/claude/settings`, `00-fleet.json`: bypass permissions only, `disableAutoMode`), the same rules into vibe's `~/.vibe/AGENTS.md`, agy's rules and qwen's QWEN.md, the kill guards and the force-push guards. `--dry-run` prints the plan.

<a id="ws-doc-bd84d2ae-726e-44fc-a17f-033c9681af65"></a>
## 7.2 As the agent user

The vendor list is what this box will run (claude, grok, agy, qwen, mistral). `--no-seat`: seating is its own step (10.1).

```bash
sudo su --pty - <AGENT_USER> -c 'cd /opt/csi/csi-spl && bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli claude,grok,agy,mistral --no-seat --fleet'
```

<a id="ws-doc-9a4ad854-28be-4753-9b0c-5dacf6c09264"></a>
## 7.3 As the owner user

The box user runs the desks, the crons and the lease loop: it needs `spool` and `spool-agent` but no AI CLI.

```bash
cd /opt/csi/csi-spl && bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli none --no-seat --fleet
```

<a id="ws-doc-d82bcd17-eed0-4e0b-9635-b4cd2886cadf"></a>
## 7.4 Each vendor CLI

Each vendor has one install and setup guide; follow it, do not copy it here:

| vendor | guide |
|---|---|
| claude | [claude-agent-setup.ISG.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/claude-agent-setup.ISG.md) |
| grok | [grok-agent-setup.ISG.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/grok-agent-setup.ISG.md) |
| agy | [antigravity-agent-setup.ISG.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/antigravity-agent-setup.ISG.md) |
| mistral | [mistral-agent-setup.ISG.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/mistral-agent-setup.ISG.md) |

Which vendor takes which kind of work is cnf `env.box.agent_split_by_kind` (`csi-spl-cnf/csi-spl/all.env.yaml`). The Mistral API key goes in with its own action; it reads the key from the terminal, never from argv:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_set_mistral_key
```

<a id="ws-doc-8a08d3dc-15b6-4ed2-87b9-8185c4046504"></a>
## 7.5 The logins

Each AI CLI logs in once, interactively, as `<AGENT_USER>`: open the printed URL in any browser, sign in, paste the code back. The owner's own logins are never copied to the agent user. For claude:

```bash
sudo su --pty - <AGENT_USER> -c 'claude auth login'
```

<a id="ws-doc-e32b8a72-c978-48b8-8580-9eb95c55d92e"></a>
### 7.5.1 Check the claude login

Run this after each login as `<AGENT_USER>`. `"loggedIn": true` is the pass; any other answer means the login did not complete. The other vendor CLIs have no status verb of their own. After this, the box cron row `agent-login-check` (`csi-spl-orc/cnf/box-crons/box-crons.manifest`, installed by `do_install_box_crons`) probes the claude login every minute and heals a dead one.

```bash
sudo su --pty - <AGENT_USER> -c 'claude auth status'
```

<a id="ws-doc-441fee4c-cb36-4fa9-8ea8-8d6ada3468c2"></a>
## 7.6 The agent hooks and MCP tools

The agent hook (spec 093) in the agent user's claude settings, and the spool as MCP tools (`spool-dev`, `spool-prd`) for every agent CLI. Each action is a dry run unless `DRY_RUN=0`; the command below applies both. To see the plan first, run it without the two `DRY_RUN=0`:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 ./run -a do_spl_agent_hooks_install && DRY_RUN=0 ./run -a do_spl_agent_mcp_install
```

<a id="ws-doc-f3ff0043-1fb9-4c7e-87dc-6a8a5b4d4eaf"></a>
## 7.7 The force-push guard in both homes

The pre-tool hook and deny rules that refuse a force push in claude, grok, agy and qwen, for both users:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 ./run -a do_install_force_push_guard
```

<a id="ws-doc-39f36382-5a91-452f-8607-264b75ab0581"></a>
## 7.8 Check the harness

The settings of both users (valid JSON, `bypassPermissions`, no rejected allow rule):

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_spl_agent_settings_check
```

<a id="ws-doc-1731e418-281d-461e-a56f-326542a6dc44"></a>
# 8 Configuration (cnf)

<a id="ws-doc-b10fe786-e67c-4a07-992f-25bd5627ce00"></a>
## 8.1 The single source of truth

`csi-spl-cnf/csi-spl/<env>.env.yaml` with `all.env.yaml` under it. It holds, among the rest: the GCP org id and owner email (only for the bootstrap), the DNS names the hub and WUI answer on, `env.box.*` (spool root, its group, the workspace base, the box restart slots, the vendor split by kind, the mistral vibe pin), and every terraform step's values under `env.steps.<step>`. Never a secret and never the billing account id. Edit cnf, never a rendered file.

Google sign-in and the Calendar connect use one OAuth Web client per env: its id is cnf `env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID` (`<env>.env.yaml`), its secret is in Secret Manager. Its Google console steps (the redirect URIs, the consent screen's scope and test users) and the check `cd csi-spl-iac && ENV=<env> ./run -a do_gcp_gcal_connect_check` are in the [Google Calendar connect ISG](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/google-calendar-connect.ISG.md).

<a id="ws-doc-e8338d96-6a9b-477a-b96c-53c388bd9fb1"></a>
## 8.2 Render the tfvars

tpl-gen renders `csi-spl-cnf/csi-spl/<env>/tf/*.tfvars` from cnf. After a cnf change, render and commit the result in the same commit; CI fails on a drift.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=prd ./run -a do_tpl_gen
```

<a id="ws-doc-0582560e-69f8-4e38-a723-a2f6d72e9a5b"></a>
## 8.3 One step's config through the validator

The infra stack's path (conf-validator, then tpl-gen), from the main checkout; the stack itself is the DevOps guide's:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd STEP=030-cloud-run-hub make do-generate-config-for-step
```

<a id="ws-doc-f3c61ad8-f502-456a-986c-8090d537a62e"></a>
# 9 The server side of the box

<a id="ws-doc-0c532dca-9574-4f61-8149-1648c9590913"></a>
## 9.1 Check what is missing

`do_spl_box_deploy` (spec 071 section 5) brings a Linux box from a main checkout to a running server side by calling the existing installers. `check` is read-only: the plan and every prerequisite (tools on the cron PATH, a main checkout on trunk, the self-updating cron checkout, the spool root, the cnf, the keys present).

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd BOX_DEPLOY_CMD=check ./run -a do_spl_box_deploy
```

<a id="ws-doc-0374f39b-8295-48c3-aa7b-da0b5a7724e2"></a>
## 9.2 Install, dev and prd

`install` builds the desk `spool` binary, installs the crons through their own installers, then starts the long-lived rows (`do_spl_pool_ctl`) and fails when one is not running. `BOX_DEPLOY_PKGS=1` installs missing tools with the package manager. Run it for `dev`, then the same with `ENV=prd`.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev BOX_DEPLOY_CMD=install BOX_DEPLOY_PKGS=1 DRY_RUN=0 ./run -a do_spl_box_deploy
```

<a id="ws-doc-dd004680-bb4f-468a-b832-4ef13bbab979"></a>
## 9.3 The crons it installs

One tagged line each in `<OWNER_USER>`'s crontab, matched by the tag at the end of the line (spec 071 section 3.2):

| tag `# csi-spl:` | runs | installer |
|---|---|---|
| `desk-reconcile`, `desk-reconcile-prd` | keeps every live agent seated; keeps the lease loop alive | `do_spl_desk_install_service` |
| `unanswered-sweep` | the topics whose last post is a human's, to the lease holder | `do_spl_unanswered_sweep_install_cron` |
| `agent-id-reap` | frees ids of dead agents; retries hub lane rows the retire could not close and alerts the dispatch holder; tells the holder when a reaped seat held an owner topic | `do_spl_agent_id_reap_install_cron` |
| `orch-rotate`, `dispatch-rotate` | the hourly role rotations at :05 and :15 | `do_spl_orch_rotate_install_cron`, `do_spl_dispatch_rotate_install_cron` |
| `agent-identity-reconcile` | the identity map, every minute | `do_spl_agent_identity_install` |
| `agent-boot-restore` | `@reboot`: brings back the agents a reboot killed, as `<AGENT_USER>` | `do_spl_agent_boot_restore_install_cron` |
| `weekly-full-scan` | the weekly full lint scan | `do_install_weekly_full_scan_cron` (iac) |
| `box-cron:*` | sessions save, graft index, box-state backup, CI red note, agent login check, lane rotate, reverse tunnel, the topic status card every 5 min (acts on the dispatch lease holder's box only) (`csi-spl-orc/cnf/box-crons/box-crons.manifest`) | `do_install_box_crons` |
| `box-update` | the box and both envs to trunk twice a day | `do_spl_box_update_install_cron` |

<a id="ws-doc-784280d0-92b3-4293-897b-6a56381184d4"></a>
## 9.4 Crons installed on their own

Not part of `do_spl_box_deploy` today; each is a dry run until `DRY_RUN=0`:

| cron | installer |
|---|---|
| the weekly box restart, in this box's slot of cnf `env.box.restart` | `BOX_RESTART_SLOT=<n> ./run -a do_spl_box_restart_install_cron` |
| the cross-box spawn receiver | `./run -a do_spl_spawn_remote_install_cron` |
| the watchdog starter (spec 102) | `./run -a do_spl_wd_ensure_install_cron` ([watchdog-setup.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/watchdog-setup.md)) |
| the /tmp scratch sweep | `./run -a do_tmp_scratch_sweep_install_cron` |
| the disk headroom check | `./run -a do_check_disk_headroom_install_cron` |

List what is installed:

```bash
crontab -l | grep -o '# csi-spl:[a-z0-9:-]*$'
```

<a id="ws-doc-6b5fcafe-5cff-447f-994d-384e851880a4"></a>
# 10 Desks, role seats, leases and tmux

<a id="ws-doc-a030ac27-2d0a-4b17-bb2f-8afe6994af81"></a>
## 10.1 Seat the desks

A desk is this box's seat in a workspace: one `spool hub-run` sidecar per (env, workspace, desk box). The FIRST seat of a desk box mints its key and pins it with the workspace root key (`ROOT_KEY_JSON`, section 5); later runs reuse the pin. Do it for each workspace the box serves, dev and prd. Details and checks: [claude-agent-setup.ISG.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/isg/claude-agent-setup.ISG.md) sections 2.4 and 5.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd TENANT_ID=<TENANT> DESK_AGENT=c-001 DESK_BOX=<BOX> ROOT_KEY_JSON=<path to the workspace root key JSON> DRY_RUN=0 ./run -a do_spl_desk_up
```

<a id="ws-doc-58c517f5-b6fe-4643-ab56-b2ec39f4fdfd"></a>
## 10.2 The tmux session

`<OWNER_USER>` owns the one tmux server; every agent is a window whose name carries its agent id (`c-004`, or `<ID>@<BOX>`; grammar in spec 061 section 0). `install.sh` copies the snippet `tmux-agent-status.conf` (badges, status line, window sort) and prints the one `source-file` line to add to `~/.tmux.conf`. Start the session as the owner:

```bash
tmux new -A -s main
```

<a id="ws-doc-75841a5c-3bd6-45e7-9e84-d6f9a0e92ceb"></a>
## 10.3 The first orchestrator

`c-001` is the orchestrator, `c-002` the master dispatcher, `c-003` the failover (ids `001`..`003` are reserved on every box). The hourly rotation only replaces a running orchestrator; the first one is started by hand in a window named `c-001` with the spawn launcher (no role-seat action yet, gap 14.4). Its job: [runbook-orchestrator.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/runbook-orchestrator.md).

```bash
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh claude c-001 /opt/csi/csi-spl
```

<a id="ws-doc-117299bc-1296-4b9e-9b26-d01e9809d5c0"></a>
## 10.4 The dispatchers and the lease

`do_spl_dispatch_setup` writes `lease.conf`, renders the dispatchers' briefs, makes their worktrees and settings, spawns `c-002` and `c-003`, seats them in every workspace, starts the lease loops, subscribes the role seats to every channel and installs the unanswered sweep. The steps and checks: [HOWTO-setup-dispatchers.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/HOWTO-setup-dispatchers.md) sections 3 and 4; the dispatcher's job: [runbook-dispatcher.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/runbook-dispatcher.md).

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd DISPATCH_ORCH=c-001 DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 DRY_RUN=0 ./run -a do_spl_dispatch_setup
```

<a id="ws-doc-5571e35c-b845-4d4f-9e75-06d673ad321c"></a>
## 10.5 One fleet lease across two boxes

With two boxes, exactly one orchestrator and one dispatch holder act at a time. Write the fleet lines on EACH box, its own `DISPATCH_MACHINE`, the same priority list ([HOWTO-setup-dispatchers.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/HOWTO-setup-dispatchers.md) section 6):

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 DISPATCH_FLEET=main DISPATCH_MACHINE=<BOX> DISPATCH_PRIORITY=<BOX>,<OTHER_BOX> DISPATCH_LEASE_TENANT=<TENANT> ./run -a do_spl_dispatch_setup
```

<a id="ws-doc-862f8296-92fa-4003-8230-a0cefe53b7ab"></a>
## 10.6 The identity map and the boot restore

The identity map (`<spool root>/agents`) records which agent runs in which pane with which session, so a reboot brings each one back as `<AGENT_USER>` in its own worktree. `do_spl_box_deploy` installs both parts; by hand:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 ./run -a do_spl_agent_identity_install && DRY_RUN=0 ./run -a do_spl_agent_boot_restore_install_cron
```

<a id="ws-doc-15c3c675-30bb-4646-96cc-84873719f4a4"></a>
# 11 Restore the box state from the nightly backup

Each box backs up its box-only state every night to the env's box-state bucket: agent transcripts and memory (`~/.claude/projects`), the spool root, `/var/csi/csi-spl` and `~/.local/state/csi-spl`. Never keys, tokens or `.env` files. The restore reads as the env's project SA, scans the archive (key material refuses it), stages it and lists each file as NEW or OVERWRITE; only `DRY_RUN=0` copies. Details: [box-state-backup.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/box-state-backup.md) section 5.

<a id="ws-doc-d6717abb-7713-41e1-a029-e40d1e7aebdd"></a>
## 11.1 List the backups of the lost box

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd PREFIX=<LOST_BOX>/ ./run -a do_spl_box_state_ls
```

<a id="ws-doc-396534f9-c103-4e94-be00-ce2c3ca71d88"></a>
## 11.2 Restore one night

Dry run first; then the same with `DRY_RUN=0`. Restored worktree records point at worktrees that no longer exist: the identity restore refuses those, and the role seats start fresh (10.3, 10.4).

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd BOX=<LOST_BOX> DATE=<YYYY-MM-DD> ./run -a do_spl_box_state_restore
```

<a id="ws-doc-278d8cdf-5298-4182-8809-abf013e95c46"></a>
# 12 The second box: the satellite

The satellite is a GCP VM in its own project `csi-spl-all`, defined by terraform `059-gcp-satellite-budget` and `060-gcp-vm-satellite`; the 060 apply runs the Ansible playbook `box-playbook.yaml` against it (roles 01..11: disk, packages, timezone, ssh, users, secrets, harness, tools, rotation crons, boot restore). Terraform runs only in the tf-runner container, and every apply needs the owner's go. The full build from nothing, in order, is [SYS.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/SYS.md) section 1.5.8; the GCP side is the DevOps guide's.

<a id="ws-doc-9e14f1a0-0add-4386-8616-a4461f9e668f"></a>
## 12.1 Pin the satellite's ssh host key

After the 060 apply, from this box:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_ssh_config
```

<a id="ws-doc-83f10588-9acb-4829-8c90-5d06901015fb"></a>
## 12.2 Verify the satellite

One PASS/FAIL line per check, ending `SATELLITE-VERIFY fails=N`:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_verify
```

<a id="ws-doc-8fb54dd4-afd7-402b-8c80-483bb1a743ae"></a>
## 12.3 After verify

The agent user's AI CLI logins on the satellite (interactive, 7.5), its desks (10.1, with its own desk box), its fleet lease lines (10.5) and its own GCP keys if role 06 had none (`do_box_copy_gcp_key`).

<a id="ws-doc-5de400df-231b-48c4-b879-820a2efd1c26"></a>
## 12.4 Let the satellite reach this box

The satellite has no route to this box. This box keeps a reverse ssh tunnel to it instead (SPL-1766): the satellite reaches this box's sshd at its own `127.0.0.1:2222`, and its key may run only the verbs of the forced command `csi-spl-orc/src/bash/scripts/peer-ssh-gate.sh` (`ping`, `lease`). Both actions run on this box, as the owner user, from the main checkout; each is a dry run until `DRY_RUN=0`.

<a id="ws-doc-e4e3bad2-4888-4d0a-aa67-d98c5fffe984"></a>
### 12.4.1 Grant the satellite's key

Makes the satellite agent user's key on the satellite if it is missing (the private key stays there), adds a `Host <this box>-tunnel` block to its `~/.ssh/config`, and puts the public key in this box's agent user's `authorized_keys` as one `from="127.0.0.1,::1",restrict,command=...` line:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 ./run -a do_box_peer_ssh_grant
```

<a id="ws-doc-3e9c2d41-1680-4c74-b8c3-47c23ddabceb"></a>
### 12.4.2 Start the tunnel

Records the tunnel and starts it; the `box-cron:reverse-tunnel` row (9.3) restarts it every minute when it dropped:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && DRY_RUN=0 ./run -a do_setup_reverse_tunnel
```

<a id="ws-doc-946e256c-64fa-496e-82ce-282a3a1a859c"></a>
### 12.4.3 Check it from the satellite

As the satellite's agent user, must print `pong <agent user>@<this box> from sat`:

```bash
ssh <THIS_BOX>-tunnel ping
```

<a id="ws-doc-8d37d980-716a-4387-b5c8-f230c0cd0762"></a>
### 12.4.4 Let the satellite's sshd drop a dead tunnel

On the satellite, as the owner user, from its checkout. A tunnel session whose ssh on this box died must not keep holding the satellite's `127.0.0.1:2222` (SPL-1802). This writes `/etc/ssh/sshd_config.d/65-spl-reverse-tunnel.conf`: a `Match User <TUNNEL_LOGIN>` block with `ClientAliveInterval 15` and `ClientAliveCountMax 4`, checked with `sshd -t` before the reload. `<TUNNEL_LOGIN>` is the `user` that `ssh -G satellite` prints on this box:

```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && TUNNEL_LOGIN_USER=<TUNNEL_LOGIN> DRY_RUN=0 ./run -a do_setup_tunnel_sshd_keepalive
```

<a id="ws-doc-e3eee010-cf7e-4895-a865-e861438d1570"></a>
### 12.4.5 Free a stuck tunnel port

When something else already listens on the satellite's `127.0.0.1:2222`, every forward is refused. This box's cron then records `<state>/sat.stuck` (`/var/csi/csi-spl/reverse-tunnel`), logs one `WARN STUCK` line at most every 15 minutes (`REVERSE_TUNNEL_STUCK_EVERY`), and `REVERSE_TUNNEL_CMD=status` prints `stuck since`. On the satellite, this frees the port, but only when the holder is an `sshd-session` of the tunnel login and the tunnel does not answer `ping`. It kills that one pid; this box's cron forwards again within a minute:

```bash
cd /opt/csi/csi-spl-desk-cron/csi-spl-orc && REVERSE_TUNNEL_FROM_BOX=<THIS_BOX> TUNNEL_LOGIN_USER=<TUNNEL_LOGIN> DRY_RUN=0 ./run -a do_clear_reverse_tunnel_listener
```

<a id="ws-doc-5aa6022c-a6da-43d0-b6cb-30e9981a9ba0"></a>
# 13 First boot checks

Run these after the build and after every restart of the box. Each must read green.

<a id="ws-doc-676fb628-f3bc-452e-bb03-9205070dae02"></a>
## 13.1 The server side is running

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd POOL_CMD=status ./run -a do_spl_pool_ctl
```

<a id="ws-doc-37f52360-3184-40b8-80e4-93b987e3e7f5"></a>
## 13.2 The desks answer at the hub

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd TENANT_ID=<TENANT> DESK_AGENT=c-001 DESK_BOX=<BOX> ./run -a do_spl_desk_check
```

<a id="ws-doc-2a4952e5-b75f-456c-b202-141f83045384"></a>
## 13.3 The dispatch setup is complete

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd ./run -a do_spl_dispatch_check
```

<a id="ws-doc-f1ebc04c-1e01-45bc-8b46-4cad7aa8930d"></a>
## 13.4 The fleet lease has one holder per role

```bash
cd /opt/csi/csi-spl/csi-spl-orc && LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
```

<a id="ws-doc-524c5af9-a4f1-41a1-8380-c5d17dccf86e"></a>
## 13.5 The identity map matches the windows

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ./run -a do_spl_agent_identity_check
```

<a id="ws-doc-aa33962e-dfc0-4cf2-9ed1-b1ca0ee9df33"></a>
## 13.6 No agent runs as the owner user

Must print nothing:

```bash
ps -u <OWNER_USER> -o pid=,args= | awk '$2 ~ /(^|\/)claude$/'
```

<a id="ws-doc-cd969faa-0469-4aef-84c5-9c8e94d93ff4"></a>
## 13.7 No agent runs in a permission mode other than bypass

Must print nothing:

```bash
ps -eo args= | awk '$1 ~ /(^|\/)claude$/' | grep -E -- '--permission-mode (auto|default|acceptEdits|plan|dontAsk)'
```

<a id="ws-doc-4c7687a2-2228-4059-bb8c-cc3edf519f10"></a>
## 13.8 Both envs are on trunk

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd ./run -a do_check_deploy_lag
```

<a id="ws-doc-72a834c4-c211-4f50-9495-4153002843c4"></a>
# 14 Gaps

Each row is a step that needs a human or has no named action today: a candidate lane.

<a id="ws-doc-7a643f10-e6d5-44f2-a413-494c03671aaa"></a>
## 14.1 Packages and the Google Cloud CLI on a non-satellite box

Role `02_os_binaries` runs only against the satellite (`hosts: satellite`). A plain Debian 13 box gets its packages from the hand-typed apt line of 3.1. Candidate: a `do_box_os_bootstrap` action, or the playbook made runnable against `localhost`.

<a id="ws-doc-030c455c-2431-4d32-a784-adcc5c116a67"></a>
## 14.2 Users, groups, sudo and linger on a non-satellite box

Role `05_users` is satellite-only; on any other box section 3.4 is by hand. Candidate: the same role on `localhost`, names from cnf.

<a id="ws-doc-d06a0f77-e1cd-4fed-a881-6f4400d55333"></a>
## 14.3 gh login and the GitHub token

Role `08_spool_harness` logs gh in from `~/.github/token` on the satellite only; elsewhere it is `gh auth login --with-token` by hand.

<a id="ws-doc-bb0e4d95-bdd1-46f3-83ef-98c8316a5e5b"></a>
## 14.4 The first orchestrator

No action starts `c-001` with its role brief on an empty box; `do_spl_orch_rotate` only replaces a running one and `do_spl_dispatch_setup` spawns only the dispatchers. Candidate: an orchestrator step in `do_spl_dispatch_setup`.

<a id="ws-doc-5679322d-2647-46d2-84e3-564917e4a9fe"></a>
## 14.5 The AI CLI logins

Interactive by design, one per vendor per agent user, after every box loss.

<a id="ws-doc-8c90df4f-8481-4c4e-b347-d5f01a61992e"></a>
## 14.6 The self-hosted CI runners

They die with the boxes, and hub and WUI deploys wait for them. Re-register them with `do_gh_runner_add`, then check with `do_check_gh_runner` (DevOps guide, section 14). The gap is that no box step runs it for you, and a rebuild drill must time it.

<a id="ws-doc-d053df40-ed6b-46a6-8e5c-1ccc25cf0886"></a>
## 14.7 Crons outside the box deploy

The box restart, spawn-remote, watchdog, /tmp sweep and disk headroom crons (9.4) are separate installers, not part of `do_spl_box_deploy`, so a new box can miss one.

<a id="ws-doc-78f56ef1-cc6a-4a4e-9909-01a1f9cb3297"></a>
## 14.8 Tenant root keys

The workspace root keys are held only out of band; no action lists which workspaces a new box must be seated in or checks that a key for each is at hand.

<a id="ws-doc-2e24ed73-fa64-4c45-b786-e3ba83515e76"></a>
# 15 Gmail access from Claude through the claude.ai connector

This is how Claude reads the workspace's Gmail mailbox (a mailbox of `<GOOGLE_ACCOUNT>`'s Google Workspace) programmatically. The route is the claude.ai Gmail connector. The connector belongs to the **Claude account**, not to the box: connect it once, and every Claude Code session that is logged in to that Claude account gets the Gmail tools, on any machine.

Placeholders: `<CLAUDE_ACCOUNT>` is the Claude account the agent seats log in with, `<GOOGLE_ACCOUNT>` is the workspace's Google account that owns the mailbox, `<AGENT_USER>` is the agent OS user, `<AGENT_ID>` is the seat's agent id (for example `c-001`) and `<BOX>` is the box.

<a id="ws-doc-07ce7dd3-4947-4e80-97c8-66b3faf39bfd"></a>
## 15.1 Connect the Gmail connector to the Claude account

A human does this once, in a browser:

1. Open claude.ai and sign in as `<CLAUDE_ACCOUNT>`, the account the seats use.
2. Go to Settings, then Connectors, then Gmail, then Connect.
3. Sign in with `<GOOGLE_ACCOUNT>` and allow the access. It may be a different Google account from the one behind the Claude login; that works.

From then on every Claude Code session logged in to `<CLAUDE_ACCOUNT>` gets the `mcp__claude_ai_Gmail__*` tools after the session starts or restarts.

<a id="ws-doc-6302716a-dd0c-44a1-9ab8-d1695806f77d"></a>
## 15.2 A running session loads connectors only when it starts

A session started before the connect does not get the tools. Restart it: let the seat exit, then resume it with its current flags from `csi-spl-orc`:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && IDENTITY_RESTORE_IDS=<AGENT_ID> DRY_RUN=0 ./run -a do_spl_agent_identity_restore
```

<a id="ws-doc-4a4a43e8-6b0f-49bf-b360-7bc10419107f"></a>
## 15.3 Who can read the mailbox

Every session on `<CLAUDE_ACCOUNT>` can read the mailbox, on every box and for every agent that logs in with that account. Connect only a mailbox that all of them may read.

<a id="ws-doc-a53958f8-8b79-4659-8f3f-dd40a1e362cb"></a>
## 15.4 Limit: no attachment download

The connector has no tool that downloads an attachment. It reads messages and threads; an attachment's content is not reachable through it.

<a id="ws-doc-c27ae465-a557-4db0-b19d-3efe2e617e34"></a>
## 15.5 The route not chosen: Google's hosted Gmail MCP server

Google's hosted Gmail MCP endpoint can be added with `claude mcp add --transport http`. Without a Google OAuth client made in advance it fails with "Incompatible auth server: does not support dynamic client registration". It works only with `--client-id`, `--client-secret` and `--callback-port`, which need a Google Cloud project with the Gmail API enabled, an OAuth consent screen and a Desktop OAuth client. The owner chose the claude.ai connector instead, so this guide does not set it up.

<a id="ws-doc-4fce92c1-4762-4de5-a185-a8c4e3f87c04"></a>
## 15.6 For agent seats

<a id="ws-doc-d5c60763-8e72-49e9-a032-6d0063f642fa"></a>
### 15.6.1 The seat's OS user holds the connector

The seat runs as `<AGENT_USER>` on `<BOX>`, and that user's Claude Code login must be `<CLAUDE_ACCOUNT>`, the account that holds the connector. A seat logged in to another Claude account has no Gmail tools.

<a id="ws-doc-75011b28-5004-4271-ac8f-4cca425775bd"></a>
### 15.6.2 The tools

The tools are named `mcp__claude_ai_Gmail__*`: `search_threads`, `get_thread`, `get_message`, `list_labels`, `list_drafts` and more. The set also holds writing tools: `send_message`, `reply`, `forward`, `create_draft`, `trash_message`, `trash_thread` and the label changes. Use them read-only unless the owner asks for a write.

<a id="ws-doc-9f4d20c7-d244-412f-b82f-1f4d37b643fb"></a>
### 15.6.3 Load the tools

The tools are deferred: load them with ToolSearch, query `claude_ai_Gmail`, before the first call. A seat started before the connect has none to load; restart it as in 15.2.

<a id="ws-doc-eea51906-5442-46fb-9f7d-1d81cc32e891"></a>
### 15.6.4 Data rule: mail is personal and finance data

Mail content is personal and finance data. Only claude seats read it (grok is off for this work). Put the results only in the topic that asked for them, never in git and never in a spool message body.

<a id="ws-doc-97febabb-e580-403b-a7db-56c45e2728cf"></a>
### 15.6.5 No attachment download

As in 15.4: a seat cannot download an attachment through the connector. Say so in the asking topic; do not look for a workaround.

<a id="ws-doc-c05522d6-2353-42e9-a559-d5330860b5bc"></a>
# 16 Docs this guide replaces

Once this guide is exported to the repo (`csi-spl-doc/doc/md/guides/installation-and-configuration-guide.md`), the install parts of these docs become pointers to it, so each fact keeps one home:

| doc | what moves here |
|---|---|
| `SYS.md` section 1.5.8 | the build order (SYS.md keeps the satellite reference) |
| `HOWTO-setup-dispatchers.md` | nothing moves: it stays the one home of the dispatcher steps; this guide links it |
| `isg/*.ISG.md` | nothing moves: each stays the one home of its vendor's setup; this guide links them |
| `box-state-backup.md` section 5 | stays; this guide links it |

<a id="ws-doc-2e08704b-00d3-4bcc-b798-724232c4d125"></a>
# 17 macOS box

Sections 3, 6.1–6.2, 9 and 12 target Debian 13 (`apt-get`, `useradd`/`usermod`/`getent`, `setfacl`/`getfacl`, `systemd`/`loginctl enable-linger`, GNU `su --pty`, GNU `stat -c`). This section gives the macOS (`Darwin`, Apple silicon `arm64` or Intel `x86_64`) equivalents for each step of sections 3.x, 4.x, 6.3 and 7.x that a joined Mac box needs so that `<OWNER_USER>` owns the box session and the single-user base directories under `/Users/<OWNER_USER>`, while every AI CLI agent runs as the dedicated `<AGENT_USER>` account (spec 108 section 3.8).

On macOS, root `/opt` and `/var` are not writable by `<OWNER_USER>`, so every path uses the single-user home layout under `/Users/<OWNER_USER>`:

- `BASE_PATH` (`BASE_DIR`) is `/Users/<OWNER_USER>/opt` and `VAR_BASE_PATH` (`VAR_DIR`) is `/Users/<OWNER_USER>/var`: `_do_probe_writable_root` in `csi-spl-orc/lib/bash/funcs/detect-base-paths.func.sh:9,17-19` (and the identical copies in `csi-spl-iac` and `csi-spl-utl`) falls back from `/opt` and `/var` to `$HOME/opt` and `$HOME/var` when `/` is not user-writable, and `csi-spl-orc/src/bash/run/run.sh:454-456,538-543,553` (plus `csi-spl-orc/lib/make/derive-proj-paths.mk:5-6`) derives `PROJ_PATH`, `APP_PATH`, `ORG_PATH`, `BASE_PATH` and `VAR_DIR="${VAR_DIR:-${_above_base%/}/var}"` relatively from the checkout's location in `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`.
- Cloning the repo into `/Users/<OWNER_USER>/opt/csi/csi-spl` (which also satisfies `csi-spl-orc/src/bash/features/spool-install/install.sh:306-312`) therefore sets `BASE_PATH=/Users/<OWNER_USER>/opt`, `ORG_PATH=/Users/<OWNER_USER>/opt/csi`, `APP_PATH=/Users/<OWNER_USER>/opt/csi/csi-spl`, `VAR_DIR=/Users/<OWNER_USER>/var`, run logs under `/Users/<OWNER_USER>/var/csi/csi-spl/<proj>/dat/log/bash` (`run.sh:454`), and spawned lane worktrees under `/Users/<OWNER_USER>/opt/csi/csi-spl-wt/<ID>` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:199,236`).
- Workspace and spool state live under `/Users/<OWNER_USER>/var/spool-ws`: exporting `SPL_WS_BASE=/Users/<OWNER_USER>/var/spool-ws`, `SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` and `SPOOL_BOX_ENV=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool/box.env` points `spool join` (`csi-spl-api/src/go/spool-hub-api/internal/action/join.go:36-38,93-100`), `spl_box_ws_base` (`csi-spl-orc/lib/bash/funcs/spl-box-workspace.func.sh:39-50`), `spool-env.inc.sh` (`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:10,323,437`), `box-config.sh` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/box-config.sh:18-19`), and `install.sh --fleet` (`csi-spl-orc/src/bash/features/spool-install/install.sh:1004,1031`, `steps/y11-kill-guard.sh:33`, `steps/y17-rm-guard.sh:31`, `steps/y19-git-credential-store.sh:31`) to `/Users/<OWNER_USER>/var/spool-ws`.

Placeholders: `<OWNER_USER>` is the primary macOS administrator account on the Mac, `<AGENT_USER>` is the dedicated agent OS user (never `<OWNER_USER>`), `<WORKSPACE>` is the workspace slug the Mac box joins, `<BOX>` is this Mac's box id, `<HUB_URL>` is the hub address shown in the WUI help (Connect an agent, section 2), and `<JOIN_TOKEN>` is the one-use join token from **Workspace settings -> Agents -> Join tokens**. Every command below that could not be executed on a Mac from the Linux fleet is marked **not tested on macOS**.

<a id="ws-doc-7c771d32-22ba-4012-b394-fa84cec3142d"></a>
## 17.1 Homebrew packages and base tools (macOS equivalent of 3.1, 3.2, 3.3, 3.5)

macOS ships `/bin/bash` 3.2, while `csi-spl-orc/src/bash/features/spool-install/install.sh` requires Bash 4 or newer (`BASH_VERSINFO[0] >= 4`) plus `git`, `python3` (3.12+ for Mistral Vibe), `tar`, `perl`, `curl`, `flock` and `setsid`. Install Homebrew's `bash` (5.x), `tmux`, `git`, `curl`, `jq`, `python@3.12`, `gh`, `go`, `yq`, `node`, `pnpm`, `coreutils` (GNU `stat`, `sha256sum`, `readlink`) and `flock` as `<OWNER_USER>` (**not tested on macOS**):

```bash
brew install bash tmux git curl jq python@3.12 gh go yq node pnpm coreutils flock
```

<a id="ws-doc-3455c290-285a-4d84-80e7-0da0b4938c7f"></a>
### 17.1.1 Google Cloud CLI and Docker Desktop (macOS equivalent of 3.1 docker group and 3.2)

macOS has no Linux `docker` kernel group: Docker runs inside Docker Desktop's lightweight VM (`/Applications/Docker.app`). Check the current Homebrew cask names (`gcloud-cli` / `google-cloud-sdk` and `docker` / `docker-desktop`) with `brew info --cask`, then install the Google Cloud CLI and Docker Desktop casks as `<OWNER_USER>` (**not tested on macOS**):

```bash
brew info --cask gcloud-cli docker && brew install --cask gcloud-cli docker
```

Start Docker Desktop once from `<OWNER_USER>`'s GUI session so it creates `/Users/<OWNER_USER>/.docker/run/docker.sock`, then grant `<AGENT_USER>` a `file_inherit,directory_inherit` ACL on `/Users/<OWNER_USER>/.docker/run` and read/write ACL access on `docker.sock` so `<AGENT_USER>` can run `docker` commands without a separate GUI login (if Docker Desktop recreates `docker.sock` on restart without inheriting the ACE, re-run the `chmod +a` on `docker.sock` after each Docker Desktop restart; **not tested on macOS**):

```bash
open -a Docker && chmod +a "user:<AGENT_USER> allow list,search,readattr,readextattr,readsecurity" /Users/<OWNER_USER> /Users/<OWNER_USER>/.docker && chmod +a "user:<AGENT_USER> allow list,search,read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit" /Users/<OWNER_USER>/.docker/run && chmod +a "user:<AGENT_USER> allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity" /Users/<OWNER_USER>/.docker/run/docker.sock
```

<a id="ws-doc-5ed17372-6c08-47d6-95b9-eaa306a549be"></a>
### 17.1.2 `getent` and `setsid` shims for macOS

`box-config.sh` and `spool-env.inc.sh` (`_spool_home_of`) call `getent passwd <user>`, and `install.sh` and `do_spl_desk_up` require `setsid` on `PATH` (neither ships in macOS base). Install both shims in `/usr/local/bin` (mode `0755`, owned by `root:wheel`) and register `/opt/homebrew/bin/bash` in `/etc/shells` so `su` / `sudo -i` accept it (**not tested on macOS**):

```bash
sudo mkdir -p /usr/local/bin && grep -qxF /opt/homebrew/bin/bash /etc/shells || echo /opt/homebrew/bin/bash | sudo tee -a /etc/shells >/dev/null
```

Write `/usr/local/bin/getent` backed by Directory Service (`dscl`) (**not tested on macOS**):

```bash
sudo tee /usr/local/bin/getent >/dev/null <<'EOF' && sudo chown root:wheel /usr/local/bin/getent && sudo chmod 0755 /usr/local/bin/getent
#!/bin/sh
case "$1:$2" in
  passwd:*)
    u="$2"; [ -n "$u" ] || exit 2
    h="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -n "$h" ] || exit 2
    uid="$(id -u "$u" 2>/dev/null)" || exit 2
    gid="$(id -g "$u" 2>/dev/null)" || exit 2
    sh="$(dscl . -read "/Users/$u" UserShell 2>/dev/null | awk '{print $2}')"
    printf '%s:*:%s:%s::%s:%s\n' "$u" "$uid" "$gid" "$h" "${sh:-/bin/bash}"
    ;;
  group:*)
    g="$2"; [ -n "$g" ] || exit 2
    gid="$(dscl . -read "/Groups/$g" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
    [ -n "$gid" ] || exit 2
    m="$(dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | cut -d: -f2- | tr -s ' ' ',' | sed 's/^,//;s/,$//')"
    printf '%s:*:%s:%s\n' "$g" "$gid" "$m"
    ;;
  *) exit 2 ;;
esac
EOF
```

Write `/usr/local/bin/setsid` using Perl's `POSIX::setsid` (**not tested on macOS**):

```bash
sudo tee /usr/local/bin/setsid >/dev/null <<'EOF' && sudo chown root:wheel /usr/local/bin/setsid && sudo chmod 0755 /usr/local/bin/setsid
#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(setsid);
setsid() != -1 or die "setsid: $!\n";
exec @ARGV or die "exec: $!\n";
EOF
```

<a id="ws-doc-d8a3038e-a35e-4f2b-bc0f-18e395109258"></a>
### 17.1.3 Timezone (macOS equivalent of 3.5)

Set the system timezone to `Europe/Helsinki` with `systemsetup` (**not tested on macOS**):

```bash
sudo systemsetup -settimezone Europe/Helsinki
```

<a id="ws-doc-b71f1987-4cac-4656-b73a-e6eeb150ed9d"></a>
## 17.2 The two users, groups and sudo on macOS (macOS equivalent of 3.4)

<a id="ws-doc-b3c5828a-9b76-4787-9783-f81a16edd327"></a>
### 17.2.1 Create the agent user (`sysadminctl` / `dscl`)

Create `<AGENT_USER>` as a local macOS account with home `/Users/<AGENT_USER>` and shell `/opt/homebrew/bin/bash` (use `/usr/local/bin/bash` on an Intel Mac) via `sysadminctl`, remove its password login (delete `AuthenticationAuthority`, set the `Password` attribute to `*`, and set `IsHidden 1` to hide it from the login window) so the account is entered only through `sudo -u <AGENT_USER>`, and populate its home directory with `createhomedir` (passing `-admin` already adds `<AGENT_USER>` to the `admin` group; **not tested on macOS**):

```bash
sudo sysadminctl -addUser <AGENT_USER> -fullName "Spool Agent" -shell /opt/homebrew/bin/bash -home /Users/<AGENT_USER> -admin && sudo dscl . -delete /Users/<AGENT_USER> AuthenticationAuthority && sudo dscl . -create /Users/<AGENT_USER> Password "*" && sudo dscl . -create /Users/<AGENT_USER> IsHidden 1 && sudo createhomedir -c -u <AGENT_USER>
```

If `<AGENT_USER>` already exists with `/bin/zsh` or `/bin/bash`, set its login shell to Homebrew's Bash 5+ with `dscl` and verify the record (**not tested on macOS**):

```bash
sudo dscl . -create /Users/<AGENT_USER> UserShell /opt/homebrew/bin/bash && dscl . -read /Users/<AGENT_USER> UserShell NFSHomeDirectory PrimaryGroupID
```

Ensure `<AGENT_USER>`'s login profile puts Homebrew's GNU coreutils (`stat -c`, `sha256sum`, `readlink -f`), Homebrew binaries and `~/.local/bin` ahead of `/usr/bin` on `PATH` (**not tested on macOS**):

```bash
sudo -n -u <AGENT_USER> tee -a /Users/<AGENT_USER>/.bash_profile >/dev/null <<'EOF'
export PATH="$HOME/.local/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/local/bin:$PATH"
EOF
```

<a id="ws-doc-3556ccc6-f92e-4789-a9a8-ff8261d50c4d"></a>
### 17.2.2 Groups (`dseditgroup`)

macOS manages groups through Directory Service (`dseditgroup`) rather than `groupadd`/`usermod`. Create the `spool-agents` group and add both `<OWNER_USER>` and `<AGENT_USER>` to `spool-agents` and `staff` (`sysadminctl -admin` in 17.2.1 already placed `<AGENT_USER>` in `admin`) (**not tested on macOS**):

```bash
sudo dseditgroup -o create -r "Spool Agents" spool-agents && sudo dseditgroup -o edit -a <OWNER_USER> -t user spool-agents && sudo dseditgroup -o edit -a <AGENT_USER> -t user spool-agents && sudo dseditgroup -o edit -a <AGENT_USER> -t user staff
```

Verify that both accounts belong to `spool-agents` and `<AGENT_USER>` belongs to `admin` (**not tested on macOS**):

```bash
dseditgroup -o checkmember -m <AGENT_USER> spool-agents && dseditgroup -o checkmember -m <OWNER_USER> spool-agents && dseditgroup -o checkmember -m <AGENT_USER> admin
```

<a id="ws-doc-437ca758-8920-4232-a12e-7b53cf6fe37e"></a>
### 17.2.3 NOPASSWD sudo both ways (`/etc/sudoers.d/`, `visudo -c`)

Write a candidate file via `mktemp`, validate its syntax with `visudo -cf` first (on macOS a broken `/etc/sudoers.d/` file breaks every subsequent `sudo` invocation, including the `visudo` needed to repair it), and only after validation succeeds install it to `/etc/sudoers.d/90-spool-users` (`root:wheel`, mode `0440`) so `<OWNER_USER>` can hop to `<AGENT_USER>` (`sudo -n -u <AGENT_USER>`) and `<AGENT_USER>` can hop to `<OWNER_USER>` or `root` without a password prompt (**not tested on macOS**):

```bash
t="$(mktemp)" && printf '%s ALL=(ALL) NOPASSWD:ALL\n%s ALL=(ALL) NOPASSWD:ALL\n' '<OWNER_USER>' '<AGENT_USER>' > "$t" && sudo visudo -cf "$t" && sudo install -o root -g wheel -m 0440 "$t" /etc/sudoers.d/90-spool-users && rm -f "$t"
```

Check NOPASSWD sudo in both directions (**not tested on macOS**):

```bash
sudo -n -u <AGENT_USER> sudo -n -u <OWNER_USER> true && echo ok
```

<a id="ws-doc-1143c224-b48a-4f9a-a900-9671e7d818a1"></a>
## 17.3 What "full visibility on the whole box" means on macOS

On Linux, membership in `sudo`, `<OWNER_USER>`'s group, `docker` and `spool-agents` plus `NOPASSWD:ALL` gives `<AGENT_USER>` unrestricted access to the whole filesystem. On macOS, two separate layers govern access:

1. **UNIX / Darwin ACL layer (`admin` + `NOPASSWD:ALL` + `chmod +a`)**: putting `<AGENT_USER>` in `admin`, `staff` and `spool-agents` (17.2.2), granting `NOPASSWD:ALL` (17.2.3), and adding an inherited read/traverse ACL for `<AGENT_USER>` on `/Users/<OWNER_USER>` gives `<AGENT_USER>` visibility over `/Users/<OWNER_USER>/opt/csi`, `/Users/<OWNER_USER>/var/csi/csi-spl`, `/Users/<OWNER_USER>/var/spool-ws`, `/Library`, `/Applications` and `<OWNER_USER>`'s workspace directories, plus root execution through `sudo -n`.
2. **macOS TCC (Transparency, Consent, and Control) and SIP limits that `sudo` cannot lift**: even `root` (`sudo`) is denied (`Operation not permitted`, `EPERM`) when reading TCC-protected folders (`~/Desktop`, `~/Documents`, `~/Downloads`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`, `/Library/Application Support/com.apple.TCC/TCC.db`) unless the responsible binary (`Terminal.app`, `iTerm.app`, `/opt/homebrew/bin/tmux`, `/opt/homebrew/bin/bash`, and `/usr/sbin/sshd-keygen-wrapper` for SSH sessions) has been granted **Full Disk Access** by a human in System Settings. When System Integrity Protection (SIP) is enabled, no CLI command (`sudo`, `tccutil`, or writing `TCC.db`) can grant Full Disk Access programmatically; a human must toggle it once in the GUI.

First, open **System Settings -> Privacy & Security -> Full Disk Access** on the Mac, toggle Full Disk Access on for the terminal application, `/opt/homebrew/bin/tmux`, `/opt/homebrew/bin/bash` and `/usr/sbin/sshd-keygen-wrapper`, and open a new terminal window so the session runs with Full Disk Access (**not tested on macOS**):

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

Next, from the new terminal with Full Disk Access active, grant `<AGENT_USER>` inherited Darwin ACL visibility across `/Users/<OWNER_USER>` (if `chmod -R +a` was run before Full Disk Access was toggled on, re-run it now after enabling Full Disk Access; without Full Disk Access, `chmod -R +a` gets `EPERM` on `Desktop`, `Documents`, `Downloads` and parts of `Library`, leaving those mode-`0700` directories without the ACE) (**not tested on macOS**):

```bash
sudo chmod -R +a "user:<AGENT_USER> allow list,search,read,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit" /Users/<OWNER_USER>
```

Verify whether the current session's responsible binary has Full Disk Access and the Darwin ACE on `/Users/<OWNER_USER>/Desktop` as `<AGENT_USER>` (prints `fda-ok` when granted; note that running this in an interactive terminal tests the Full Disk Access of the terminal application you typed it in, not of the `launchd` daemon or the `tmux` server that runs the agents — run the same check inside a `tmux` pane as `<AGENT_USER>` to confirm `tmux`'s Full Disk Access) (**not tested on macOS**):

```bash
sudo -n -u <AGENT_USER> ls /Users/<OWNER_USER>/Desktop >/dev/null && echo fda-ok
```

<a id="ws-doc-25e5c50b-7784-4d5a-a1fc-310b339291c7"></a>
## 17.4 Shared directories under `/Users/<OWNER_USER>`, ACLs (`chmod +a`), checkout, spool root and `box.env` (macOS equivalent of 3.4, 4.1–4.5, 6.1, 6.2, 6.3)

macOS uses Darwin extended ACLs (`chmod +a`, `ls -le`) instead of Linux POSIX ACLs (`setfacl`/`getfacl`), so `do_repair_spool_root` and `do_provision_spool_root` cannot run on Darwin. On BSD/Darwin, new files and directories automatically inherit their parent directory's group (`spool-agents`) without needing a Linux setgid bit, and `_sp_agent_acl` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:105`) is a clean no-op when `setfacl` is absent because worktrees under `/Users/<OWNER_USER>/opt/csi/csi-spl-wt/<ID>` inherit the Darwin ACL from `/Users/<OWNER_USER>/opt/csi`. A dedicated joined Mac box keeps its checkout at `/Users/<OWNER_USER>/opt/csi/csi-spl`, its run logs and state under `/Users/<OWNER_USER>/var/csi/csi-spl`, and its workspace spool root at `/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` (section 17.4.1). Create `/Users/<OWNER_USER>/opt/csi` and `/Users/<OWNER_USER>/var/csi/csi-spl` with group `spool-agents`, mode `0775` and inherited Darwin ACLs granting `spool-agents` full read/write/execute inheritance (**not tested on macOS**):

```bash
mkdir -p /Users/<OWNER_USER>/opt/csi /Users/<OWNER_USER>/var/csi/csi-spl && sudo chown -R <OWNER_USER>:spool-agents /Users/<OWNER_USER>/opt /Users/<OWNER_USER>/var && chmod 0775 /Users/<OWNER_USER>/opt /Users/<OWNER_USER>/opt/csi /Users/<OWNER_USER>/var /Users/<OWNER_USER>/var/csi /Users/<OWNER_USER>/var/csi/csi-spl && chmod +a "group:spool-agents allow list,add_file,search,delete,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit" /Users/<OWNER_USER>/opt/csi /Users/<OWNER_USER>/var/csi/csi-spl
```

Verify the Darwin ACLs and permissions on `/Users/<OWNER_USER>/opt/csi` and `/Users/<OWNER_USER>/var/csi/csi-spl` (**not tested on macOS**):

```bash
ls -lde /Users/<OWNER_USER>/opt/csi /Users/<OWNER_USER>/var/csi/csi-spl
```

Clone the repository into `/Users/<OWNER_USER>/opt/csi/csi-spl` as `<OWNER_USER>` (macOS equivalent of 4.1; **not tested on macOS**):

```bash
git clone https://github.com/csitea/csi-spl.git /Users/<OWNER_USER>/opt/csi/csi-spl
```

Read and acknowledge the developer guide from `/Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-orc` (macOS equivalent of 4.3; **not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-orc && ./run -a do_dev_guide_ack
```

Set up `tpl-gen` at its pin under `/Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-iac` (macOS equivalent of 4.4; **not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-iac && ./run -a do_setup_tpl_gen
```

Install the pre-push hook on `/Users/<OWNER_USER>/opt/csi/csi-spl` (macOS equivalent of 4.5; **not tested on macOS**):

```bash
bash /Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/install-pre-push-hook.sh /Users/<OWNER_USER>/opt/csi/csi-spl
```

<a id="ws-doc-83b52dae-8c68-4c51-825f-98dfdbacc8ba"></a>
### 17.4.1 Dedicated workspace claim on a joined Mac box (spec 108 section 3.8)

When a workspace has `box_join_enabled = true`, the hub accepts `spool join` only from a box whose `$SPL_WS_BASE/claim` (`csi-spl-api/src/go/spool-hub-api/internal/action/join.go:36-38,93-100`; default `/var/spool-ws`, overridden by `SPL_WS_BASE=/Users/<OWNER_USER>/var/spool-ws` in `~/.spool/env`, which `spl_box_ws_base` in `csi-spl-orc/lib/bash/funcs/spl-box-workspace.func.sh:39-50` also honours) names `<WORKSPACE>` (`box_mode = dedicated`, spec 108 section 3.8; a missing claim joins as `shared` and is refused with `403 box_mode_shared`). Because `do_spl_box_workspace_setup` (`csi-spl-orc/src/bash/run/spl-box-workspace-setup.func.sh:74-75`) hard-codes Linux `chown root:root` and `useradd --system` (on macOS root's group is `wheel`), create the dedicated workspace directory `/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>` owned by `<AGENT_USER>` (mode `0700`) and the root-owned `/Users/<OWNER_USER>/var/spool-ws/claim` (mode `0644`) directly (**not tested on macOS**):

```bash
sudo mkdir -p /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/state && sudo chown root:wheel /Users/<OWNER_USER>/var/spool-ws && sudo chmod 0755 /Users/<OWNER_USER>/var/spool-ws && sudo chown -R <AGENT_USER>:staff /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE> && sudo chmod 0700 /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE> /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/state && printf '%s\n' '<WORKSPACE>' | sudo tee /Users/<OWNER_USER>/var/spool-ws/claim >/dev/null && sudo chown root:wheel /Users/<OWNER_USER>/var/spool-ws/claim && sudo chmod 0644 /Users/<OWNER_USER>/var/spool-ws/claim
```

<a id="ws-doc-498d7ae0-8570-46da-8240-f74e2854bbe5"></a>
### 17.4.2 `box.env` and paths that still need explicit overrides (macOS equivalent of 6.3)

macOS BSD `su` does not support `--pty`, so `box.env` sets `SPOOL_RUN_AS_AGENT=sudo-i` alongside `SPOOL_AGENT_USER=<AGENT_USER>`. Because `/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` is mode `0700` owned by `<AGENT_USER>`, run `box-config.sh` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/box-config.sh:18-19`) as `<AGENT_USER>` with `SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` so `SPOOL_DESK_BOX`, `SPOOL_BOX_TAG`, `SPOOL_FLEET_ENV` and `SPOOL_FLEET_TENANT` are written to `/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool/box.env` (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> env SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool /opt/homebrew/bin/bash /Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/box-config.sh SPOOL_AGENT_USER=<AGENT_USER> SPOOL_RUN_AS_AGENT=sudo-i SPOOL_DESK_BOX=<BOX> SPOOL_BOX_TAG=<BOX> SPOOL_FLEET_ENV=prd SPOOL_FLEET_TENANT=<WORKSPACE>
```

Paths in fleet scripts that do not derive from `run.sh` or `SPOOL_ROOT` alone without an extra environment variable or a code change:

- `spool-mcp.sh` `box.env` lookup — still at `/var/spool-hub/box.env`: `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mcp.sh:109,230` hard-codes `${SPOOL_BOX_ENV:-/var/spool-hub/box.env}` (export `SPOOL_BOX_ENV=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool/box.env`; note that `spool-mcp.sh:114,118` also hard-codes Linux `/proc/$pid/cmdline` and `/proc/$pid/environ`, so section 17.5.3 registers `spool mcp --as c-001` directly).
- Watcher role markers and box socket — still at `/var/spool-hub`: `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:972,1003` hard-codes `/var/spool-hub` in `spl_watcher_markers` (which also checks `$SPOOL_ROOT`) and `stat -c %u /var/spool-hub` in `_spl_watcher_box_socket` (export `SPOOL_TMUX_SOCKET=/tmp/tmux-$(id -u <OWNER_USER>)/default`, which `spool-env.inc.sh:448,1029` honours).
- `do_spl_desk_wsdoc` input allowlist — still at `/var/spool-hub/dispatch`: `csi-spl-orc/src/bash/run/spl-desk-wsdoc.func.sh:159,164` hard-codes `/var/spool-hub/dispatch` alongside `${APP_PATH:-}` and `/tmp` (pass `WSDOC_IN` under `/tmp` or `/Users/<OWNER_USER>/opt/csi/csi-spl`).
- `do_spl_box_clean_tree` worktree root default — still at `/opt/csi/csi-spl-wt`: `csi-spl-orc/src/bash/run/spl-box-clean-tree.func.sh:33` hard-codes `SPOOL_WT_ROOT="${SPOOL_WT_ROOT:-/opt/csi/csi-spl-wt}"` (pass `SPOOL_WT_ROOT=/Users/<OWNER_USER>/opt/csi/csi-spl-wt`).
- `do_spl_spawn_place` token-burn state dir default — still at `/var/csi/csi-spl/token-burn`: `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:460` hard-codes `TOKEN_BURN_STATE_DIR="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}"` (pass `TOKEN_BURN_STATE_DIR=/Users/<OWNER_USER>/var/csi/csi-spl/token-burn`).
- `do_spl_review_line_check` worktree and lifetime path checks — still at `/opt/csi/csi-spl-wt/` and `/var/spool-hub/`: `csi-spl-orc/src/bash/run/spl-review-line-check.func.sh:306,338,356` hard-codes `/opt/csi/csi-spl-wt/` and `/var/spool-hub/`.
- `rm-guard` home directory list — still at `/etc/passwd`: `csi-spl-orc/src/bash/features/spool-install/assets/rm-guard/rm-guard.sh:102` reads `${RM_GUARD_PASSWD:-/etc/passwd}` (top-level `/Users` is still protected by `rm-guard.sh:74`, while `/Users/<user>` entries live in OpenDirectory unless listed in `RM_GUARD_PASSWD`).

<a id="ws-doc-d9db30ce-3a50-4530-b63a-edeadc7f0612"></a>
## 17.5 The agent harness, join token and Claude login as `<AGENT_USER>` (macOS equivalent of 7.2, 7.3, 7.5, 7.8)

<a id="ws-doc-3e5a9d7c-6f24-4a2f-9580-f5ab00373ca9"></a>
### 17.5.1 Install the harness as `<AGENT_USER>` (macOS equivalent of 7.2)

Because macOS `su` has no `--pty` flag and `install.sh --fleet` (`csi-spl-orc/src/bash/features/spool-install/install.sh:1004,1031`) defaults `SPOOL_ROOT` to `/var/spool-hub` unless `SPOOL_ROOT` is set in the environment, pass `SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` when running `install.sh` from `/Users/<OWNER_USER>/opt/csi/csi-spl` as `<AGENT_USER>` (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> /opt/homebrew/bin/bash -lc 'cd /Users/<OWNER_USER>/opt/csi/csi-spl && SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli claude,grok,agy,mistral --no-seat --fleet'
```

<a id="ws-doc-d766cd99-d9fb-45db-bfe9-6241dc02b76a"></a>
### 17.5.2 Install `spool` and `spool-agent` as `<OWNER_USER>` (macOS equivalent of 7.3)

Run the no-CLI harness install from `/Users/<OWNER_USER>/opt/csi/csi-spl` as `<OWNER_USER>` with `SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool` (**not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl && SPOOL_ROOT=/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool /opt/homebrew/bin/bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli none --no-seat --fleet
```

<a id="ws-doc-6a6d2028-2021-4817-9918-f495c5625681"></a>
### 17.5.3 Enrol the Mac box with a workspace join token (`spool join`)

As `<AGENT_USER>`, write `~/.spool/env` (setting `<HUB_URL>` to the hub address shown in the WUI help under **Connect an agent**, section 2, or derived at write time with `awk '/^ *BASE_DOMAIN:/{print "https://api."$2; exit}' /Users/<OWNER_USER>/opt/csi/csi-spl/csi-spl-cnf/csi-spl/all.env.yaml`), create the first agent mailbox (`c-001`) under `/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool`, redeem the one-use join token from **Workspace settings -> Agents -> Join tokens** (`SPOOL_JOIN_TOKEN`), and register the `spool` MCP server in `<AGENT_USER>`'s Claude Code configuration (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> /opt/homebrew/bin/bash -lc 'mkdir -p ~/.spool /Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool/c-001 && cat > ~/.spool/env <<EOF
export SPOOL_HUB_URL="<HUB_URL>"
export SPOOL_TENANT="<WORKSPACE>"
export SPOOL_BOX_ID="<BOX>"
export SPOOL_ROOT="/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool"
export SPOOL_BOX_ENV="/Users/<OWNER_USER>/var/spool-ws/<WORKSPACE>/spool/box.env"
export SPL_WS_BASE="/Users/<OWNER_USER>/var/spool-ws"
export PATH="\$HOME/.local/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
EOF
. ~/.spool/env && SPOOL_JOIN_TOKEN="<JOIN_TOKEN>" spool join "\$SPOOL_HUB_URL" && claude mcp add spool -- /opt/homebrew/bin/bash -c ". ~/.spool/env && exec spool mcp --as c-001"'
```

<a id="ws-doc-a0261b9b-6efe-4e18-a93f-422b7f0e2699"></a>
### 17.5.4 Interactive Claude Code login as `<AGENT_USER>` (macOS equivalent of 7.5)

Log in to Claude Code interactively as `<AGENT_USER>` (never copy `<OWNER_USER>`'s `~/.claude` credentials) (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> claude auth login
```

Verify that `<AGENT_USER>` is logged in (`"loggedIn": true`) (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> claude auth status
```

<a id="ws-doc-f50e0379-9922-4eaa-8588-e1470dfe2cac"></a>
### 17.5.5 Check the harness as `<AGENT_USER>` (macOS equivalent of 7.8)

Verify that `spool`, `spool-agent`, `claude`, `~/.claude/CLAUDE.md` and the `spool` MCP entry are in place for `<AGENT_USER>` (**not tested on macOS**):

```bash
sudo -i -u <AGENT_USER> /opt/homebrew/bin/bash -lc 'command -v spool spool-agent claude && test -s ~/.claude/CLAUDE.md && claude mcp list'
```

<a id="ws-doc-a9d5c951-6d9c-4812-861d-70f324ce75c4"></a>
## 17.6 Keep-alive with `launchd` instead of `loginctl enable-linger` and systemd (macOS equivalent of 3.4 linger, 9, 10.1)

macOS has neither `systemd` nor `loginctl enable-linger`. A `~/Library/LaunchAgents` plist only runs while that user is logged in to the macOS GUI; a system `LaunchDaemon` in `/Library/LaunchDaemons/net.csitea.spool.hub-run.plist` with `<key>UserName</key><string><AGENT_USER></string>`, `<key>RunAtLoad</key><true/>` and `<key>KeepAlive</key><true/>` starts `spool hub-run` at boot as `<AGENT_USER>` and restarts it if it exits, even when no GUI session is open.

Disable idle system sleep on the Mac box so macOS does not suspend the network interface and drop the `spool hub-run` WebSocket session (**not tested on macOS**):

```bash
sudo pmset -a sleep 0 disksleep 0 displaysleep 15
```

Write `/Library/LaunchDaemons/net.csitea.spool.hub-run.plist` (`root:wheel`, mode `0644`), sourcing the absolute path `/Users/<AGENT_USER>/.spool/env`, and validate it with `plutil -lint` (**not tested on macOS**):

```bash
sudo tee /Library/LaunchDaemons/net.csitea.spool.hub-run.plist >/dev/null <<'EOF' && sudo chown root:wheel /Library/LaunchDaemons/net.csitea.spool.hub-run.plist && sudo chmod 0644 /Library/LaunchDaemons/net.csitea.spool.hub-run.plist && sudo plutil -lint /Library/LaunchDaemons/net.csitea.spool.hub-run.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>net.csitea.spool.hub-run</string>
  <key>UserName</key>
  <string><AGENT_USER></string>
  <key>GroupName</key>
  <string>staff</string>
  <key>WorkingDirectory</key>
  <string>/Users/<AGENT_USER></string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/bash</string>
    <string>-lc</string>
    <string>. "/Users/<AGENT_USER>/.spool/env" &amp;&amp; exec spool hub-run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>/Users/<AGENT_USER>/.spool/hub-run.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/<AGENT_USER>/.spool/hub-run.log</string>
</dict>
</plist>
EOF
```

Unload any previous instance with `launchctl bootout` and wait briefly before bootstrapping (`launchctl bootout` is asynchronous on macOS and an immediate `bootstrap` can fail with `5: Input/output error`), then load and start the daemon in the `system` domain (**not tested on macOS**):

```bash
sudo launchctl bootout system/net.csitea.spool.hub-run 2>/dev/null || true; sleep 2 && sudo launchctl bootstrap system /Library/LaunchDaemons/net.csitea.spool.hub-run.plist && sudo launchctl kickstart -k system/net.csitea.spool.hub-run
```

Verify that `net.csitea.spool.hub-run` is running as `<AGENT_USER>` and connected to the hub (**not tested on macOS**):

```bash
sudo launchctl print system/net.csitea.spool.hub-run | head -n 25 && sudo -n -u <AGENT_USER> tail -n 10 /Users/<AGENT_USER>/.spool/hub-run.log
```

## 17.7 Local dev mode on macOS (spec 148)

From `/Users/<OWNER_USER>/opt/csi/csi-spl`, the root `./run` symlink (`run` -> `csi-spl-orc/run`) resolves `APP_PATH=/Users/<OWNER_USER>/opt/csi/csi-spl`, `BASE_PATH=/Users/<OWNER_USER>/opt` and `VAR_DIR=/Users/<OWNER_USER>/var` (`csi-spl-orc/src/bash/run/run.sh:538-543`), and `do_dev_mode_ctl` (`csi-spl-orc/src/bash/run/dev-mode-ctl.func.sh:61`) sets `DEV_MODE_TREE="${DEV_MODE_TREE:-${APP_PATH:-}}"`. `dev-preflight.sh` (`csi-spl-orc/src/bash/scripts/dev-preflight.sh:85,121,183-184`) supports `Darwin:arm64`, `Darwin:aarch64` and `Darwin:x86_64`, verifying that Docker Desktop (section 17.1.1), `docker compose`, `go`, `node`, `pnpm`, `jq` and `curl` are available and that ports `5432`, `8025`, `1025`, `8080` and `5173` are free ([local-dev-mode-guide.md](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/md/local-dev-mode-guide.md)).

Start the local dev stack (PostgreSQL 16 and Mailpit in Docker Compose, `spool-hub-api` with `SPOOL_DEV_MODE=1` on `http://127.0.0.1:8080/health`, Vite WUI on `http://127.0.0.1:5173`, Mailpit UI on `http://127.0.0.1:8025`, seeded workspace `acme-corp` and login `dev@local.test` / `dev`, with pids and logs under `/Users/<OWNER_USER>/opt/csi/csi-spl/.local/dev-mode/`) (`csi-spl-orc/src/bash/run/dev-mode-up.func.sh:10`, `dev-mode-ctl.func.sh:60-90`; **not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl && ./run -a do_dev_mode_up
```

Verify the 3 Mailpit email scenarios (`register`, `verify`, `reset`) against the running local stack (`csi-spl-orc/src/bash/scripts/dev-mailpit-scenarios.sh:1-35`; **not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl && bash csi-spl-orc/src/bash/scripts/dev-mailpit-scenarios.sh
```

Stop the local dev stack and purge the PostgreSQL volume and `/Users/<OWNER_USER>/opt/csi/csi-spl/.local/dev-mode/` state (`csi-spl-orc/src/bash/run/dev-mode-down.func.sh:11`, `dev-mode-ctl.func.sh:91-110`; **not tested on macOS**):

```bash
cd /Users/<OWNER_USER>/opt/csi/csi-spl && ./run -a do_dev_mode_down --purge
```
