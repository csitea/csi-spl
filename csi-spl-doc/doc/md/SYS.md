# csi-spl — System Guide

The system guide describes what is running, where it is defined, and how to
operate it. It is the operator's reference. The specs under
`csi-spl-doc/specs/` hold the design history behind each part.

Sections:

1. [The satellite: the GCP agent box](#1-the-satellite-the-gcp-agent-box)

---

## 1. The satellite: the GCP agent box

The satellite is ONE always-on Debian VM in GCP. It runs AI CLI agents for
both the dev and the prd environments. It has no UI and no web endpoint. You
reach it only over ssh, through Google's IAP tunnel, as an extension of a fleet
box's terminal. Spec: [057-satellite](../../specs/057-satellite/spec.md).
Section 7 of the spec records how it was actually built.

### 1.1 What runs, as of 2026-10-01

| item | value |
|---|---|
| GCP project | `csi-spl-all`: its own project, not dev or prd (owner, 2026-10-01) |
| instance | `csi-spl-all-satellite`, zone `europe-north1-a`, always on |
| machine | `e2-highmem-4`: 4 vCPU, 32 GB RAM (31 GiB usable) |
| OS | Debian GNU/Linux 13 (trixie), cloud kernel, image `debian-13-trixie-v20260921` (pinned, dated) |
| boot disk | 30 GB pd-balanced: OS, `/home` |
| data disk | `csi-spl-all-satellite-data`, 100 GB pd-balanced, ext4, label `satellite-data`; mounted at `/mnt/data`, with `/opt` and `/var/spool-hub` bind-mounted from it and docker's data-root on it |
| users | the box PC's split (box-playbook role 05): `<owner>` uid 2000 (tmux, the UI, `/opt/csi`) and `<agent>` uid 2001 (every AI CLI agent), names from the ysg-box overlay's `boxes/sat/box.env` (`BOX_USER`, `BOX_AGENT_USER`); homes `/mnt/data/home/<user>`, NOPASSWD sudo, `docker` + `spool-agents`, linger. `debian` (the GCE default) is the ssh/Ansible entry only |
| network | own VPC `csi-spl-all-satellite-vpc`, subnet `10.80.0.0/24` (private Google access, 10% flow logs); internal IP only |
| outbound | Cloud Router + Cloud NAT (`csi-spl-all-satellite-nat`); **no public IP** |
| inbound | ONE firewall rule: tcp/22 from `35.235.240.0/20`, Google IAP only; no http/https, no load balancer, no DNS |
| sshd | keys only: no passwords, no root login (`/etc/ssh/sshd_config.d/60-satellite.conf`) |
| VM service account | `csi-spl-all-satellite@…`: logs and metrics writer only. The agents use the per-env SA keys, not this SA |
| budget | `csi-spl-all-satellite`: 170 per month in the billing account's currency, alerts at 50/90/100%, filtered to resources labelled `box=satellite` |
| cost | about $163 per month list price: VM ~$145, disks ~$14, NAT/IP ~$4 |

#### 1.1.1 What lives on which disk

| disk | holds | survives |
|---|---|---|
| boot, 30 GB | the OS, packages, `/home/debian` (the ssh entry only) | nothing: lost on any VM recreate |
| data, 100 GB | the users' homes `/mnt/data/home/<owner>` and `/mnt/data/home/<agent>` (`~/.local/bin`, `~/.claude` with the agent's claude login, the keys and token), `/opt` (the repo `/opt/csi/csi-spl`, the ysg-box overlay and engine), `/var/spool-hub` (the spool root), docker's data-root `/mnt/data/docker` | a VM-only rebuild (e.g. an image change); NOT a 060 destroy |

No snapshots and no backups (owner: git is the backup): anything not pushed is
lost with its disk.

### 1.2 What is installed

Everything in the VM is installed by ONE Ansible playbook, the eli-vta
pattern (owner, topic 6f10f92b: "use the established ansible approach ... not
anything ad-hoc"): `csi-spl-iac/src/terraform/060-gcp-vm-satellite/box-playbook.yaml`.
Each role is idempotent; a recreate plus one playbook run rebuilds the box.

| role | what | replaced (bash, retired 2026-10-02) |
|---|---|---|
| 01_data_disk | ext4 on the data disk (formatted only when blank), `/mnt/data`; `/opt` and `/var/spool-hub` bind-mounted from it; docker's data-root on it | `satellite-box-setup.sh` 01 |
| 02_os_binaries | tmux git curl jq python3 perl make rsync acl sudo build-essential htop, docker + docker-compose, node + npm, gh, the Google Cloud CLI (Google's apt repo) | `satellite-box-setup.sh` 03 |
| 03_timezone | `Europe/Helsinki` (topic 9a6e0f12) | `satellite-box-setup.sh` 07 |
| 04_ssh_hardening | keys only, no passwords, no root login (`/etc/ssh/sshd_config.d/60-satellite.conf`, `sshd -t` validated) | `satellite-box-setup.sh` 06 |
| 05_users | `<owner>` + `<agent>` as on the box PC (1.1), `/opt/csi` the owner's (setgid, default ACL group rwx), `/var/spool-hub` `<owner>:spool-agents` 2770, `/etc/csi-spl-satellite.env` (what verify reads) | `satellite-box-setup.sh` 02 |
| 06_secrets | `~/.gcp/.csi/key-csi-spl-{dev,prd}.json` and `~/.github/token` for both users, 0600 in 0700 dirs, `no_log` | `do_satellite_creds_push` |
| 07_ysg_box | the ysg-box engine + overlay, its `/var` dat dirs, and box `sat`'s claude-config rendered on the VM and applied per role (`.bashrc` & co, `~/.claude` CLAUDE.md settings commands skills, dotfiles); never a `.credentials.json` | `do_satellite_claude_config` |
| 08_spool_harness | `/opt/csi/csi-spl`, git + gh for both users, the spool env (`/etc/profile.d/csi-spl-satellite.sh`: `SPOOL_ROOT`, `SPOOL_BOX_TAG=sat`), `spool-install/install.sh --cli claude --no-seat` as `<agent>` (claude, spool, spool-agent, yq, Go, hooks, skills) | `do_satellite_bootstrap` 05 |
| 09_agent_tools | cloud-sql-proxy (Google's release, sha256-pinned to the box PC's), pnpm (corepack, the WUI's pin), the CI-pinned scanners + terraform (`do_install_lint_tools`, system-wide), tpl-gen | `do_satellite_install_tools` |
| 10_rotation_cron | the box user's hourly role rotation crons: orchestrator at :05, dispatchers at :15 (spec 060), through `do_spl_orch_rotate_install_cron` / `do_spl_dispatch_rotate_install_cron`, then checked; the rotation acts on this box's own lease.conf ids | the owner's one-off install |
| 11_boot_restore | the @reboot agent restore (no other boot job runs on this box): the identity map (`do_spl_agent_identity_install`: per-minute record + tmux hooks) and one `@reboot` line (`do_spl_agent_boot_restore_install_cron`, then checked); after a reboot `do_spl_agent_boot_restore` starts each agent the reboot killed as `<agent>`, never `<owner>`, and leaves `/var/spool-hub/agents/boot-FAILED` on a failure | nothing (there was no restore) |

`csi-spl-iac/cnf/satellite-replica.tsv` names every tool and the role that
installs it; `do_satellite_verify` compares each with the box PC.

Not on the satellite: the AI CLI logins (each user's own interactive step,
1.5.9), grok / agy / qwen, chrome (for e2e), a seated spool desk.

### 1.3 Where it is defined

| what | where |
|---|---|
| cnf (single source of truth) | `csi-spl-cnf/csi-spl/prd.env.yaml` → `steps.059-gcp-satellite-budget`, `steps.060-gcp-vm-satellite` |
| terraform: budget | `csi-spl-iac/src/terraform/059-gcp-satellite-budget` |
| terraform: VM, disk, VPC, NAT, firewall, SA | `csi-spl-iac/src/terraform/060-gcp-vm-satellite` |
| terraform → Ansible | `060-gcp-vm-satellite/07-ansible.tf`: writes `inventory.prd.ini` (the VM over the IAP proxy) and `csi-spl-iac/src/bash/scripts/run-ansible-csi-spl-prd-060-gcp-vm-satellite.sh` (both git-ignored, no secret); `do_tf_apply` runs the script after every 060 apply, in the tf-runner |
| the playbook | `060-gcp-vm-satellite/box-playbook.yaml`, `roles/01..09`, `tasks/git-sync.yml` |
| the users' names | the ysg-box overlay `boxes/sat/box.env` (`BOX_USER`, `BOX_AGENT_USER`, `BOX_ENGINE_ROOT`), never this repo |
| tfvars templates | `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/05{9,60}-*.tpl` |
| box actions | `csi-spl-iac/src/bash/run/satellite-*.func.sh`, helpers in `csi-spl-iac/lib/bash/funcs/satellite.func.sh` |
| ssh ProxyCommand | `csi-spl-iac/src/bash/scripts/satellite-iap-proxy.sh` |
| tests | `csi-spl-iac/src/bash/tests/satellite-steps.tst.sh`, `satellite-actions.tst.sh`, `satellite-ansible.tst.sh` |

The bash setup (`satellite-box-setup.sh`, `do_satellite_bootstrap`,
`do_satellite_install_tools`, `do_satellite_home_persist`,
`do_satellite_replicate_ai_user`, `do_satellite_creds_push`,
`do_satellite_claude_config`) was retired on 2026-10-02, once the playbook
passed verify on a recreated VM (1.5.6). `satellite-actions.tst.sh` fails if
one of them comes back.

Both steps take their cnf from **prd** (`ENV=prd`), but they run as the
**csi-spl-all** service account (`tf_key_project: csi-spl-all`, key
`~/.gcp/.csi/key-csi-spl-all.json`). Their state lives in
`gs://csi-spl-all-tfstate`. This is the same pattern as step 046 and
csi-spl-bkp. The dev renders of both steps are header-only (`# prd-only-step`).

### 1.4 Identity rules

- After the one-time project bootstrap, everything runs as the **csi-spl-all
  service-account key**: terraform, ssh, the box actions and verify. The owner
  account is used only by `ENV=all ./run -a do_gcp_000_bootstrap_gcp_env`.
  Owner, 2026-10-01: "once the big account is used, use only the service key
  accounts".
- Every gcloud call carries `--account` or runs in a throwaway
  `CLOUDSDK_CONFIG`. The shared `~/.config/gcloud` is never written.
- No key enters git, terraform state, instance metadata or a log. The ssh key
  pair is minted locally (`do_satellite_ssh_keygen`), and terraform reads only
  the `.pub`. The billing account id comes only from `GCP_BILLING_ACCOUNT_ID`;
  make passes it as `TF_VAR_billing_account_id`.
- No key, token or billing id in a spool post either. The pushed credentials
  cross ssh stdin only; on the satellite every credential file is 0600 and its
  directory 0700 (`do_satellite_verify` checks the files).
- The owner's AI accounts are never copied: each CLI logs in on the satellite
  with its own paste-the-code login (1.5.9).

#### 1.4.1 Who is who

| identity | holds | used for |
|---|---|---|
| owner login | org-level human account | ONLY the one-time `ENV=all` gcp-000..004 bootstrap, while no csi-spl-all key exists |
| csi-spl-all SA, key `~/.gcp/.csi/key-csi-spl-all.json` on the fleet box | `roles/owner` on csi-spl-all | terraform 059/060, the IAP tunnel, the host-key pin, `do_satellite_verify` |
| VM SA `csi-spl-all-satellite@…` | logs + metrics writer only | the VM's own metadata identity; a stolen token can spend nothing |
| dev + prd SA keys in `~/.gcp/.csi/` of `<owner>` and `<agent>` | per env, as on the home box | `ENV=dev\|prd ./run -a ...` on the satellite |
| GitHub token `~/.github/token` of both users | repo access | the clones, pulls and pushes on the satellite |

### 1.5 Operating it

All commands run as the box user, from the main checkout.

#### 1.5.1 Connect

One-time on a fleet box: write the `Host satellite` block and pin the VM's host key.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_ssh_config
```

Then:

```bash
ssh satellite
```

#### 1.5.2 Verify everything (read-only, csi-spl-all SA only)

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_verify
```

It prints one `PASS`/`FAIL` line per check:
- the VM is running and has no public IP;
- the only ingress rule is tcp:22 from IAP;
- ssh works;
- the data disk is mounted on `/mnt/data`, `/opt` and `/var/spool-hub`;
- the users (role 05): `<owner>` uid 2000 and `<agent>` uid 2001, homes on
  the data disk, NOPASSWD sudo, docker, linger, the agent in the owner's group;
- AS THE AGENT: claude, spool and spool-agent, every tool of the replica
  manifest, the claude-config, git, gh, docker, tpl-gen, and whether claude is
  logged in (`claude auth status`, the `loggedIn` flag only);
- `SPOOL_BOX_TAG=sat`;
- the keys are 0600;
- the budget exists.

It ends with `SATELLITE-VERIFY fails=N`. It was 15/15 PASS on 2026-10-01
after the destroy+recreate drill.

#### 1.5.3 Plan a change (the step reads its key and state itself)

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-tf-plan
```

#### 1.5.4 Apply a change (owner go per apply)

```bash
cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-provision
```

The budget step also needs the billing id in the environment:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ENV=prd STEP=059-gcp-satellite-budget make do-provision
```

#### 1.5.5 Re-run the box setup (idempotent)

The playbook, inside the tf-runner container (the eli-vta ad-hoc path as a
named action). Needs one 060 apply from the mounted tree first: that apply
writes the script.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_playbook
```

One role, or a dry run:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && SATELLITE_PLAYBOOK_ARGS="--tags 07_ysg_box" ./run -a do_satellite_playbook
```

The same, straight in the container:

```bash
docker exec -it con-csi-csi-spl-tf-runner bash /opt/csi/csi-spl/csi-spl-iac/src/bash/scripts/run-ansible-csi-spl-prd-060-gcp-vm-satellite.sh
```

#### 1.5.6 Destroy and recreate (owner go for every destroy)

Show what would be removed: 10 resources for 060, 1 for 059.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ENV=prd STEP=060-gcp-vm-satellite make do-tf-plan-destroy
```

```bash
cd /opt/csi/csi-spl/csi-spl-orc && GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ENV=prd STEP=060-gcp-vm-satellite make do-deprovision
```

Then `make do-provision` for 059 (if it was destroyed) and 060. The 060
apply creates the VM, then runs the whole playbook against it (it waits for
sshd; a new instance id drops the stale host key). After that, in order:
1. `do_satellite_ssh_config`: pins the new host keys for `ssh satellite`.
2. `do_satellite_verify`.
3. The agent's claude login (1.5.9).

The data disk has no `prevent_destroy` (owner drill, 2026-10-01): a 060
destroy deletes it, and **git is the only backup**. Push everything before a
destroy. A recreate also loses `/home`, which holds the AI CLI logins, so the
owner logs in again.

Results of the 2026-10-01 drill:

| stage | result |
|---|---|
| plan -destroy | exactly 10 (060) + 1 (059) resources |
| destroy, re-provision | owner-gated per call; 059 then 060 back (1 + 10) |
| ssh after the recreate | the stale host key was dropped, no "Host key has changed" |
| creds push, bootstrap | every ROLE line OK/CHANGED |
| verify | 15/15 PASS |
| lost | `/home` (claude login, pushed keys, `~/.local/bin`) and the data disk (repo clone, spool root); all restored by the four steps above except the owner's claude login |

Results of the 2026-10-02 rebuild loop (owner: "destroy and re-create as
many times as needed until you get one full time from the step beginning till
the end WITHOUT errors"):

| run | destroy / recreate | playbook | cause, fix |
|---|---|---|---|
| 1 | 10 / 12 | hung in 07 | claude-apply's `bash -ic` smoke start fought over become's pty; long tasks now run under `timeout N setsid -w` |
| 2 | 12 / 12 | 1 failed (09) | ansible-core 2.14's `get_url` vs Python 3.13 on Debian 13; curl + sha256, and no `get_url`/`uri` anywhere |
| 3 | 12 / 12 | 1 failed (09) | no Go for `govulncheck`; role 02 installs the go.mod Go into `/usr/local/go` |
| 4 | 12 / 12 | **73 ok, 0 failed** | verify then read 19 FAIL, 18 of them its own bugs (sudo dropped the user names, the agent started in an unreadable cwd); fixed: **71 PASS / 1 FAIL**, the one being the agent's claude login (1.5.9) |

#### 1.5.7 Raise the pinned image

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_image_latest
```

Copy the printed image into `boot_disk_image` in cnf, run
`ENV=prd ./run -a do_tpl_gen`, then plan and apply. The image change
recreates the VM; the data disk survives.

#### 1.5.8 Build from nothing, in order (owner go for every GCP change)

1. Project bootstrap, once, with the owner login (dry run unless `DRY_RUN=0`):
   creates csi-spl-all, links billing, mints the csi-spl-all SA key, enables
   compute, iap, billingbudgets, cloudbilling, logging, monitoring.

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=all DRY_RUN=0 GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ./run -a do_gcp_000_bootstrap_gcp_env
```

2. The terraform state bucket `csi-spl-all-tfstate`:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && PROJECT_ENV=all DRY_RUN=0 ./run -a do_gcp_bkp_state_bucket_create
```

3. The ssh key pair, local only (terraform reads the `.pub`):

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_ssh_keygen
```

4. Render the tfvars:

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ENV=prd ./run -a do_tpl_gen
```

5. Step 059 (the budget) BEFORE 060: `make do-tf-plan`, then
   `make do-provision` with `GCP_BILLING_ACCOUNT_ID` (1.5.4).
6. Step 060: `make do-tf-plan`, then `make do-provision` (1.5.3, 1.5.4).
7. Then the steps after a recreate (1.5.6): the 060 apply already ran the playbook.

#### 1.5.9 The claude login, per user

Agents run as `<agent>`, so the claude login is `<agent>`'s, in
`/mnt/data/home/<agent>/.claude` on the data disk (a VM-only rebuild keeps it,
a 060 destroy does not). It is the owner's interactive step, once: from a
fleet box, one line, then open the printed URL in any browser, sign in and
paste the code back:

```bash
ssh -t satellite sudo -iu <agent> claude auth login
```

`do_satellite_verify` then reads `<agent>: claude is logged in` as PASS. The
`<owner>` user needs no claude login (it runs tmux, not agents).

#### 1.5.10 Keep agents alive after ssh disconnects

Linger is on for `<owner>` and `<agent>`; run agents inside the owner's tmux,
never in the bare ssh session:

```bash
ssh -t satellite sudo -iu <owner> tmux new -A -s main
```

### 1.6 Owner decisions (topics f35d82fc, b23639e2)

| date (UTC) | decision |
|---|---|
| 2026-10-01 08:55 | always on, no GPU, europe-north1-a, pinned Debian 13 image, IAP-only ssh, GCE default user, no backups (git is the backup), its own BOX_TAG |
| 12:51 | round 2 defaults: e2-highmem-4, 100 GB data disk, ssh key pair minted by an action (public key only in terraform), $170 budget alert |
| 12:56 | project **csi-spl-all**, not csi-spl-prd |
| 12:57 | price go (~$163/month) |
| ~14:15 | "destroy and recreate it ... verify everything once again": done, 15/15 PASS |
| ~14:47 | keep it on; document it here; next, an agent replicates the home box's AI-user setup onto it |

### 1.7 The satellite trio and the fleet lease

Owner decision "a" (t1 5fe56859, 2026-10-01): exactly one orchestrator and one
master dispatcher act at a time across the box PC and the satellite. The
design is [SPEC-spool-fleet-roles.md section 4.1](SPEC-spool-fleet-roles.md),
and the steps are [HOWTO-setup-dispatchers.md section 6](HOWTO-setup-dispatchers.md).

| | box PC | satellite (box `sat`) |
|---|---|---|
| orchestrator | `CLE-001@<box>` | `CLE-001@sat` |
| master dispatcher | `CLE-002@<box>` | `CLE-002@sat` |
| failover dispatcher | `CLE-003@<box>` | `CLE-003@sat` |
| leads | while it is on (priority 1 today) | when the PC is silent > 180 s; hands back when the PC returns |

- The lease row is on the hub (rdb 0094), which the satellite reaches through
  Cloud NAT; there is no bucket and no inbound path.
- Each machine runs one fleet loop (`do_spl_dispatch_lease LEASE_CMD=fleet`),
  kept alive by its desk reconcile cron.
- The satellite trio runs as the agent user, in auto mode on the current
  model, with the terminal mirror on. It is seated as prd desks in every
  workspace the PC trio serves, with the same channel subscriptions. Its desk
  box is `sat` (box.env `SPOOL_DESK_BOX`), unlike the PC's. Ids `001`-`003`
  are reserved on every box (owner, t1 2efb3e78), so a holder is always
  written `<ID>@<box>`.
- Phasing out the PC is one config change: `LEASE_PRIORITY=sat,<pc box>` on both
  machines (HOWTO 6.4).

### 1.8 Known gaps and next steps

- The agent's claude login (1.5.9), the owner's one interactive step; verify
  is all PASS after it.
- T024: agents spawned there; a desk seated in a test workspace that answers
  a post. The satellite trio (1.7) waits for the agent user on the satellite
  (lane CLE-77894), then its desks and the live lease drill. This needs `install.sh` without `--no-seat`, `SPOOL_HUB_URL` and the
  tenant admin pin.
- The AI-user replication: the playbook's roles 05..09.
- The bootstrap is bash roles, not ansible (owner round 1 asked for ansible).
  The role numbering is kept for a mechanical port.
- The guest had not published its ssh host keys at the first pin, so the
  first connect used accept-new. 060 sets `enable-guest-attributes=TRUE`, so
  later `do_satellite_ssh_config` runs pin them.
- T013: price confirmed from the billing catalogue (the `cloudbilling` API is
  now on in csi-spl-all).
