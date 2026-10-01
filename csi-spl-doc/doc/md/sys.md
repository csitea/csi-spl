# csi-spl — system guide (sys.md)

The machines the spool's agents run on, how each one is built, reached,
rebuilt and checked. One numbered section per machine. Specs say why;
this guide says what is there now and which command does what.

Status: 2026-10-01. Section 1 is current as of the destroy + recreate drill
(verify 15/15 PASS). The satellite is ON and stays on.

## 1. The satellite (GCP agent box, spec 057)

### 1.1 Purpose

One always-on virtual machine in GCP that runs agents for both dev and prd,
as an extension of the home box's terminal: **ssh only**, no UI, no web port,
no DNS name. Owner asks: [spec 057 section 1](../../specs/057-satellite/spec.md).
Next lane: install every binary and replicate the home box's agent user
setup onto it (section 1.10).

### 1.2 Architecture

| what | value |
|---|---|
| GCP project | `csi-spl-all` (its own project, neither dev nor prd) |
| region / zone | `europe-north1` / `europe-north1-a` |
| VM | `csi-spl-all-satellite`, `e2-highmem-4` (4 vCPU, 32 GB), always on, Shielded VM (secure boot, vTPM, integrity) |
| OS | Debian 13 (trixie), pinned dated image `debian-13-trixie-v20260921` (cnf `boot_disk_image`) |
| OS user | `debian` (GCE Debian default); OS Login off, project-wide ssh keys blocked |
| network | own VPC `csi-spl-all-satellite-vpc`, one subnet `10.80.0.0/24` with private Google access and 10% flow logs |
| outbound | Cloud Router + Cloud NAT (`csi-spl-all-satellite-router` / `-nat`); the VM has **no public IP** |
| inbound | ONE firewall rule: tcp/22 from the Google IAP range `35.235.240.0/20`, target tag `allow-ssh-iap-csi-spl-all-satellite`. Nothing else |
| ssh path | home box -> `gcloud compute start-iap-tunnel` (as the csi-spl-all SA) -> VM port 22, key `~/.ssh/.csi/debian@csi-spl-all-satellite` |
| budget | step 059: 170 per month in the billing account's currency, alerts at 50/90/100%, filter = project csi-spl-all AND label `box=satellite`. Alerts only, nothing is stopped |
| spool | box tag `sat`, `SPOOL_ROOT=/var/spool-hub`, no desk seated yet |

#### 1.2.1 Identities

| identity | holds | used for |
|---|---|---|
| owner login | org-level human account | ONLY the one-time `ENV=all` bootstrap gcp-000..004, while no csi-spl-all key exists |
| csi-spl-all project SA, key `~/.gcp/.csi/key-csi-spl-all.json` (home box) | `roles/owner` on csi-spl-all | terraform 059/060 (`tf_key_project`), the IAP tunnel, host-key pinning, `do_satellite_verify` |
| VM SA `csi-spl-all-satellite@…` | `roles/logging.logWriter`, `roles/monitoring.metricWriter` only | the VM's own metadata identity; a stolen token can spend nothing |
| dev + prd project SA keys, pushed to `~debian/.gcp/.csi/` (0600) | per-env, as on the home box | `ENV=dev|prd ./run -a ...` on the satellite |
| GitHub token, pushed to `~debian/.github/token` (0600) | repo access | the clone + pulls of the repo on the satellite |
| owner's AI accounts | the owner's own subscription | each CLI's own paste-the-code login on the satellite (never copied) |

#### 1.2.2 Disks: what lives where

| disk | size | mounted | holds | survives |
|---|---|---|---|---|
| boot `csi-spl-all-satellite` (pd-balanced) | 30 GB | `/` | the OS, packages, **`/home/debian`**: `~/.local/bin` (claude, spool, spool-agent), `~/.claude` (the claude login), `~/.bashrc` spool env, the pushed keys | nothing: lost on any VM recreate |
| data `csi-spl-all-satellite-data` (pd-balanced, device name `satellite-data`, label `satellite-data`) | 100 GB | `/mnt/data`, bind-mounted on `/opt` and `/var/spool-hub`; docker data-root `/mnt/data/docker` | the repo clone `/opt/csi/csi-spl`, the spool root, docker images | a VM-only rebuild; NOT a full step destroy (no `prevent_destroy` since the drill) |

No snapshots and no backups (owner round 1 Q13: git is the backup), so
anything not pushed is lost with its disk.

### 1.3 Cost (list estimate, per month)

| item | per month |
|---|---|
| e2-highmem-4, always on | ~$145 |
| 30 GB boot + 100 GB data, pd-balanced | ~$14 |
| Cloud NAT (replaces the ~$4 public IP) | ~$4 |
| IAP tunnel, budget alert, flow logs (10%) | ~$0 |
| **total** | **~$163** (owner limit $170) |

The estimate is list price; confirming it from the Cloud Billing catalogue
is open task T013.

### 1.4 Where the code is

| what | path |
|---|---|
| cnf (single source of truth) | `csi-spl-cnf/csi-spl/prd.env.yaml`, `env.steps.059-gcp-satellite-budget` and `env.steps.060-gcp-vm-satellite` (rendered from prd only; dev renders carry `# prd-only-step`) |
| terraform | `csi-spl-iac/src/terraform/059-gcp-satellite-budget`, `csi-spl-iac/src/terraform/060-gcp-vm-satellite` (state bucket `csi-spl-all-tfstate`) |
| actions | `csi-spl-iac/src/bash/run/satellite-*.func.sh`, helpers `csi-spl-iac/lib/bash/funcs/satellite.func.sh` |
| scripts | `csi-spl-iac/src/bash/scripts/satellite-iap-proxy.sh` (ssh ProxyCommand), `satellite-box-setup.sh` (root roles on the VM) |
| make | `csi-spl-orc/src/make/tf-tasks.func.mk` (`do-tf-plan`, `do-provision`, `do-tf-plan-destroy`, `do-deprovision`) |
| tests | `csi-spl-iac/src/bash/tests/satellite-steps.tst.sh`, `satellite-actions.tst.sh` |
| spec | `csi-spl-doc/specs/057-satellite/` (spec section 7 = as built) |

### 1.5 Build from nothing, in order

Every step that changes GCP needs the owner's go for that call. Terraform runs
only in the tf-runner container, from the main checkout, one env + step at a
time. The billing account id is only ever an environment variable; replace
`<BILLING-ACCOUNT-ID>` at run time, never commit it.

#### 1.5.1 Project bootstrap, once, with the owner login (gcp-000..004)

Creates csi-spl-all, links billing, mints the csi-spl-all SA and its key
`~/.gcp/.csi/key-csi-spl-all.json`, grants it owner, enables compute, iap,
billingbudgets, cloudbilling, logging, monitoring. Dry run first:

```bash
cd csi-spl-iac && ENV=all GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> ./run -a do_gcp_000_bootstrap_gcp_env
```

Then for real (owner go):

```bash
cd csi-spl-iac && ENV=all DRY_RUN=0 GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> ./run -a do_gcp_000_bootstrap_gcp_env
```

From here on, everything runs as the csi-spl-all SA key; the owner login is
not used again.

#### 1.5.2 Terraform state bucket

```bash
cd csi-spl-iac && PROJECT_ENV=all DRY_RUN=0 ./run -a do_gcp_bkp_state_bucket_create
```

#### 1.5.3 The ssh key pair (local only, no GCP call)

Mints `~/.ssh/.csi/debian@csi-spl-all-satellite` (0600) and its `.pub`.
Terraform reads only the `.pub`, so no private key enters state. Idempotent.

```bash
cd csi-spl-iac && ./run -a do_satellite_ssh_keygen
```

#### 1.5.4 Render the tfvars

```bash
cd csi-spl-orc && ENV=prd STEP=059-gcp-satellite-budget make do-generate-config-for-step
```

```bash
cd csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-generate-config-for-step
```

#### 1.5.5 Step 059, the budget (BEFORE the VM)

```bash
cd csi-spl-orc && ENV=prd STEP=059-gcp-satellite-budget GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> make do-tf-plan
```

Owner go, then:

```bash
cd csi-spl-orc && ENV=prd STEP=059-gcp-satellite-budget GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> make do-provision
```

#### 1.5.6 Step 060, the VM, disk, network, NAT, firewall, VM SA

```bash
cd csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-tf-plan
```

Owner go, then:

```bash
cd csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-provision
```

#### 1.5.7 ssh config + host-key pin

Writes a `Host satellite` block into `~/.ssh/config` (between marker lines,
replaced on a re-run) with the IAP ProxyCommand, then drops every stale
host key for the VM from `~/.ssh/known_hosts.satellite` and pins the keys
the guest published in its guest attributes.

```bash
cd csi-spl-iac && ./run -a do_satellite_ssh_config
```

```bash
ssh satellite hostname
```

#### 1.5.8 Credentials push

Copies the dev + prd SA keys and the GitHub token to `~debian` over ssh
stdin, 0600 (dirs 0700). Nothing is printed, logged or put in metadata.
A dry run lists what it would copy:

```bash
cd csi-spl-iac && ./run -a do_satellite_creds_push
```

```bash
cd csi-spl-iac && DRY_RUN=0 ./run -a do_satellite_creds_push
```

#### 1.5.9 Bootstrap

Waits for sshd, runs `satellite-box-setup.sh` as root (roles
`01_data_disk`, `03_os_packages`, `02_os_user`, `06_ssh_hardening`, one
`ROLE <name> OK|CHANGED|FAIL` line each), then as `debian` the role
`05_spool_harness`: clones the repo to `/opt/csi/csi-spl` with the pushed
token, writes the spool env (`SPOOL_ROOT=/var/spool-hub`,
`SPOOL_BOX_TAG=sat`, `~/.local/bin` on PATH) into `~/.bashrc`, and runs
`spool-install/install.sh --cli claude --no-seat`. Idempotent.

```bash
cd csi-spl-iac && ./run -a do_satellite_bootstrap
```

More CLIs (`SATELLITE_CLIS`), box setup only (`SATELLITE_SKIP_HARNESS=1`):

```bash
cd csi-spl-iac && SATELLITE_CLIS=claude,grok ./run -a do_satellite_bootstrap
```

#### 1.5.10 Verify

Read-only, as the csi-spl-all SA ONLY (it ignores `ACCOUNT` / `GCP_ACCOUNT`
and refuses any other identity). One `PASS|FAIL` line per check, 15 checks:
VM RUNNING, no public IP, the only ingress rule is tcp:22 from the IAP range,
ssh over IAP, the data disk on `/mnt/data`, `/opt`, `/var/spool-hub`,
`claude` / `spool` / `spool-agent` installed, `SPOOL_BOX_TAG=sat`, the three
pushed credentials 0600, the budget exists. Ends with
`SATELLITE-VERIFY fails=<n>`, non-zero exit on any FAIL.

```bash
cd csi-spl-iac && ./run -a do_satellite_verify
```

With the billing id it lists the budget on the billing account; without
it, it reads step 059's terraform state and says so.

#### 1.5.11 The owner's claude login (task T023)

Once per VM (the login lives in `~/.claude` on the boot disk). From the
home box:

```bash
ssh satellite
```

Then on the satellite, start claude and take its paste-the-code login:
open the printed authorize URL in any browser on any machine, sign in with
the owner's account, paste the code back.

```bash
claude
```

Other CLIs (grok, agy, …) log in the same way, each with its own login. No
AI token is ever copied from the home box.

### 1.6 Day-2 operations

#### 1.6.1 Is the pinned image still the newest?

```bash
cd csi-spl-iac && ./run -a do_satellite_image_latest
```

Raising it is a reviewed cnf change of `boot_disk_image`, then a 060 plan +
provision (recreates the VM: section 1.7 applies).

#### 1.6.2 Keep agents alive after ssh disconnects

Linger is enabled for `debian` (role `02_os_user`). Run agents inside tmux on
the satellite, never in the bare ssh session:

```bash
ssh -t satellite tmux new -A -s main
```

#### 1.6.3 Update the repo clone on the satellite

Re-running the bootstrap fast-forwards `/opt/csi/csi-spl` and re-runs the
installer; it changes nothing else that is already in place.

```bash
cd csi-spl-iac && ./run -a do_satellite_bootstrap
```

### 1.7 Destroy + recreate drill (owner order, 2026-10-01)

#### 1.7.1 What a full destroy would remove (changes nothing)

```bash
cd csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-tf-plan-destroy
```

```bash
cd csi-spl-orc && ENV=prd STEP=059-gcp-satellite-budget GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> make do-tf-plan-destroy
```

#### 1.7.2 Destroy (owner go for EACH call; 060 first, then 059)

```bash
cd csi-spl-orc && ENV=prd STEP=060-gcp-vm-satellite make do-deprovision
```

```bash
cd csi-spl-orc && ENV=prd STEP=059-gcp-satellite-budget GCP_BILLING_ACCOUNT_ID=<BILLING-ACCOUNT-ID> make do-deprovision
```

#### 1.7.3 Recreate

Steps 1.5.5 (059) and 1.5.6 (060), then after ANY recreate, in this order:
1.5.7 ssh config (re-pins the new host key), 1.5.8 creds push with
`DRY_RUN=0`, 1.5.9 bootstrap, 1.5.10 verify, 1.5.11 the owner's claude login.

#### 1.7.4 Results of the 2026-10-01 drill

| stage | result |
|---|---|
| plan -destroy | exactly 10 (060) + 1 (059) resources, as expected |
| destroy | done, owner-gated per call |
| re-provision | 059 then 060 (1 + 10 resources) |
| ssh after recreate | the old host key was replaced, no "Host key has changed" (the pin fix) |
| creds push, bootstrap | OK, every ROLE line OK/CHANGED |
| verify | **15/15 PASS** |
| lost by the drill | the home dir (claude login, pushed keys, `~/.local/bin`) and the data disk (repo clone, spool root); all restored by 1.7.3 except the owner's claude login |

### 1.8 Known gaps

| gap | effect | way out |
|---|---|---|
| `/home/debian` is on the boot disk | any VM recreate loses the claude login, the pushed keys and `~/.local/bin`; 1.7.3 restores all but the login | move home (or `~/.claude` and `~/.local`) onto the data disk in the replication lane |
| the data disk has no `prevent_destroy` | a full 060 destroy wipes the repo clone and the spool root | push everything; a destroy is owner-gated per call and always planned first |
| guest-attribute host keys | right after a create the guest may not have published `hostkeys/` yet; `do_satellite_ssh_config` then falls back to accept-new on the first connect and says WARN | re-run `do_satellite_ssh_config` a minute after the VM boots to get a real pin |
| bootstrap is bash, not ansible | owner round 1 asked for the eli-vta ansible pattern | the role numbering is kept, so a port to ansible roles is mechanical |
| price is a list estimate | T013 | confirm from the Cloud Billing catalogue |
| no desk seated, no agent spawned yet | T024 | the replication lane (1.10) |
| 4 vCPU | slower builds and e2e than the home box | `machine_type` is one cnf value; raise it within the $170 limit |

### 1.9 Security rules

1. The csi-spl-all SA key exists only after the owner's bootstrap (1.5.1); from
   then on every satellite action and terraform run uses that key, never the
   owner login, never the shared `~/.config/gcloud` (a throwaway
   `CLOUDSDK_CONFIG` and `--account` on every call).
2. No key, token or credential in git, terraform state, instance metadata, a
   startup script, an image, a log or a spool post. Terraform sees only the
   ssh PUBLIC key; the pushed credentials cross ssh stdin only.
3. Every credential file on the satellite is 0600, its directory 0700;
   `do_satellite_verify` checks it.
4. sshd: keys only, no root login, no passwords (role `06_ssh_hardening`).
   The only way in is IAP tcp/22; there is no public IP and no other ingress.
5. The VM SA can write logs and metrics, nothing else.
6. AI accounts: each CLI's own login on the satellite; no AI token is copied.
7. The billing account id is an environment variable at run time, never in
   cnf, git, a doc or a post.

### 1.10 Next: replicate the home box's agent setup (in progress)

Owner order (2026-10-01): an agent ssh-es to the satellite, installs every
binary the home box uses (Claude Code and the rest) and replicates the AI
user setup there. Lane: CLE-77894 (branch `CLE-77894-satellite-replicate`).
This section is updated as that lane lands.

| item | state |
|---|---|
| claude, spool, spool-agent | installed by the bootstrap |
| other agent CLIs (grok, agy, …), chrome for e2e, go/terraform toolchain parity | open (replication lane) |
| home / `~/.claude` on the data disk | open (gap 1.8) |
| owner claude login | open (T023, 1.5.11) |
| 2-3 agents spawned, a desk seated in a test workspace, an agent answers a post | open (T024) |
