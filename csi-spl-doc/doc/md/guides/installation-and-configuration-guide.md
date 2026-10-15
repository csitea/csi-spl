> Generated from qto doc `8e8454fe-c146-4bce-b705-b24a1a89772c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Exported from the Qto doc [Installation and configuration guide](https://spool-hub.ai/workspace/docs?doc=1a3900ac-774d-4a47-9ecd-4fc716542aa3&view=doc) (`1a3900ac-774d-4a47-9ecd-4fc716542aa3`) on 2026-10-11T20:33:54Z; edit in Qto, not here.

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

When the GCP projects themselves are gone too, start with the DevOps guide (bootstrap gcp-000..004 and the terraform steps), then come back here.

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

As `<OWNER_USER>`, into `/opt/csi/csi-spl`, with the GitHub token of section 5 (gh reads it; `gh auth login --with-token` takes it on stdin). Both users need git and gh logged in (role `08_spool_harness` does it from `~/.github/token`).

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
| `agent-id-reap` | frees ids of dead agents (dry run) | `do_spl_agent_id_reap_install_cron` |
| `orch-rotate`, `dispatch-rotate` | the hourly role rotations at :05 and :15 | `do_spl_orch_rotate_install_cron`, `do_spl_dispatch_rotate_install_cron` |
| `agent-identity-reconcile` | the identity map, every minute | `do_spl_agent_identity_install` |
| `agent-boot-restore` | `@reboot`: brings back the agents a reboot killed, as `<AGENT_USER>` | `do_spl_agent_boot_restore_install_cron` |
| `weekly-full-scan` | the weekly full lint scan | `do_install_weekly_full_scan_cron` (iac) |
| `box-cron:*` | sessions save, graft index, box-state backup, CI red note, agent login check, lane rotate, reverse tunnel (`csi-spl-orc/cnf/box-crons/box-crons.manifest`) | `do_install_box_crons` |
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

<a id="ws-doc-c05522d6-2353-42e9-a559-d5330860b5bc"></a>
# 15 Docs this guide replaces

Once this guide is exported to the repo (`csi-spl-doc/doc/md/guides/installation-and-configuration-guide.md`), the install parts of these docs become pointers to it, so each fact keeps one home:

| doc | what moves here |
|---|---|
| `SYS.md` section 1.5.8 | the build order (SYS.md keeps the satellite reference) |
| `HOWTO-setup-dispatchers.md` | nothing moves: it stays the one home of the dispatcher steps; this guide links it |
| `isg/*.ISG.md` | nothing moves: each stays the one home of its vendor's setup; this guide links them |
| `box-state-backup.md` section 5 | stays; this guide links it |
