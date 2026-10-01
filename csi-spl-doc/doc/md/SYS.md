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
| OS user | `debian` (the GCE Debian default): groups `docker` and `google-sudoers`, linger on, so tmux and agents survive logout |
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
| boot, 30 GB | the OS, packages, **`/home/debian`**: `~/.local/bin` (claude, spool, spool-agent), `~/.claude` (the owner's claude login), the spool env in `~/.bashrc`, the pushed keys and GitHub token | nothing: lost on any VM recreate |
| data, 100 GB | `/opt` (the repo clone `/opt/csi/csi-spl`), `/var/spool-hub` (the spool root), docker's data-root `/mnt/data/docker` | a VM-only rebuild (e.g. an image change); NOT a 060 destroy |

No snapshots and no backups (owner: git is the backup): anything not pushed is
lost with its disk.

### 1.2 What is installed

| what | version (2026-10-01) | installed by |
|---|---|---|
| tmux, git, curl, jq, python3, perl, make, rsync, acl, build-essential, htop | Debian 13 | `satellite-box-setup.sh` role 03 |
| docker + docker-compose | 26.1.5 | role 03 |
| node + npm | 20.19 / 9.2 | role 03 |
| gh | 2.46 | role 03 |
| Google Cloud SDK | 585.0.0 | role 03 (Google apt repo) |
| the csi-spl repo | `/opt/csi/csi-spl` (https clone, the token is read from `~/.github/token`) | bootstrap role 05 |
| claude (Claude Code) | 2.1.x | `spool-install/install.sh --cli claude` |
| spool, spool-agent, yq, Go | from this checkout | `spool-install/install.sh` |
| spool env | `SPOOL_ROOT=/var/spool-hub`, `SPOOL_BOX_TAG=sat` (in `~/.bashrc`) | bootstrap role 05 |
| credentials | `~/.gcp/.csi/key-csi-spl-{dev,prd}.json`, `~/.github/token`, all 0600 | `do_satellite_creds_push` |

These are **not yet** on the satellite: the owner's AI CLI logins, grok / agy /
qwen, chrome (for e2e), the full AI-user setup of the home box, and a seated
spool desk. Lane CLE-77894 replicates the AI-user setup; add what it installs
to this table.

### 1.3 Where it is defined

| what | where |
|---|---|
| cnf (single source of truth) | `csi-spl-cnf/csi-spl/prd.env.yaml` → `steps.059-gcp-satellite-budget`, `steps.060-gcp-vm-satellite` |
| terraform: budget | `csi-spl-iac/src/terraform/059-gcp-satellite-budget` |
| terraform: VM, disk, VPC, NAT, firewall, SA | `csi-spl-iac/src/terraform/060-gcp-vm-satellite` |
| tfvars templates | `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/05{9,60}-*.tpl` |
| box actions | `csi-spl-iac/src/bash/run/satellite-*.func.sh`, helpers in `csi-spl-iac/lib/bash/funcs/satellite.func.sh` |
| on-VM setup script | `csi-spl-iac/src/bash/scripts/satellite-box-setup.sh` (roles 01 data disk, 02 OS user, 03 packages, 06 ssh hardening) |
| ssh ProxyCommand | `csi-spl-iac/src/bash/scripts/satellite-iap-proxy.sh` |
| tests | `csi-spl-iac/src/bash/tests/satellite-steps.tst.sh`, `satellite-actions.tst.sh` |

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
| dev + prd SA keys in `~debian/.gcp/.csi/` | per env, as on the home box | `ENV=dev\|prd ./run -a ...` on the satellite |
| GitHub token `~debian/.github/token` | repo access | the clone and pulls on the satellite |

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
- claude, spool and spool-agent are installed;
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

```bash
cd /opt/csi/csi-spl/csi-spl-iac && DRY_RUN=0 ./run -a do_satellite_creds_push
```

```bash
cd /opt/csi/csi-spl/csi-spl-iac && ./run -a do_satellite_bootstrap
```

`SATELLITE_CLIS=claude,grok` installs more CLIs. `SATELLITE_SKIP_HARNESS=1`
runs the root setup only.

#### 1.5.6 Destroy and recreate (owner go for every destroy)

Show what would be removed: 10 resources for 060, 1 for 059.

```bash
cd /opt/csi/csi-spl/csi-spl-orc && GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ENV=prd STEP=060-gcp-vm-satellite make do-tf-plan-destroy
```

```bash
cd /opt/csi/csi-spl/csi-spl-orc && GCP_BILLING_ACCOUNT_ID=<BILLING_ACCOUNT_ID> ENV=prd STEP=060-gcp-vm-satellite make do-deprovision
```

Then `make do-provision` for 059 (if it was destroyed) and 060. After that,
in order:
1. `do_satellite_ssh_config`: drops the old host key and pins the new one.
2. `DRY_RUN=0 do_satellite_creds_push`.
3. `do_satellite_bootstrap`.
4. `do_satellite_verify`.

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
7. Then the four steps after a recreate (1.5.6) and the owner's login (1.5.9).

#### 1.5.9 The owner's claude login (T023)

Once per VM: the login lives in `~/.claude` on the boot disk. From a fleet box:

```bash
ssh satellite
```

On the satellite, start claude, open the printed authorize URL in any browser
on any machine, sign in with the owner's account and paste the code back:

```bash
claude
```

#### 1.5.10 Keep agents alive after ssh disconnects

Linger is on for `debian`; run agents inside tmux, never in the bare ssh session:

```bash
ssh -t satellite tmux new -A -s main
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

| | box PC | satellite |
|---|---|---|
| orchestrator | `CLE-001` | `CLE-101` |
| master dispatcher | `CLE-002` | `CLE-102` |
| failover dispatcher | `CLE-003` | `CLE-103` |
| leads | while it is on (priority 1 today) | when the PC is silent > 180 s; hands back when the PC returns |

- The lease row is on the hub (rdb 0094), which the satellite reaches through
  Cloud NAT; there is no bucket and no inbound path.
- Each machine runs one fleet loop (`do_spl_dispatch_lease LEASE_CMD=fleet`),
  kept alive by its desk reconcile cron.
- The satellite trio runs as the agent user, in auto mode on the current
  model, with the terminal mirror on. It is seated as prd desks in every
  workspace the PC trio serves, with the same channel subscriptions. Its desk
  box id must differ from the PC's in each workspace.
- Phasing out the PC is one config change: `LEASE_PRIORITY=sat,pc` on both
  machines (HOWTO 6.4).

### 1.8 Known gaps and next steps

- T023: the owner logs in to claude on the satellite (`ssh satellite`, then `claude`).
- T024: agents spawned there; a desk seated in a test workspace that answers
  a post. The satellite trio (1.7) waits for the agent user on the satellite
  (lane CLE-77894), then its desks and the live lease drill. This needs `install.sh` without `--no-seat`, `SPOOL_HUB_URL` and the
  tenant admin pin.
- The AI-user replication: lane CLE-77894.
- The bootstrap is bash roles, not ansible (owner round 1 asked for ansible).
  The role numbering is kept for a mechanical port.
- The guest had not published its ssh host keys at the first pin, so the
  first connect used accept-new. 060 sets `enable-guest-attributes=TRUE`, so
  later `do_satellite_ssh_config` runs pin them.
- T013: price confirmed from the billing catalogue (the `cloudbilling` API is
  now on in csi-spl-all).
