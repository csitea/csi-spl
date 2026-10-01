# 057 — the satellite: a GCP agent box (gcp-agent-box)

Status: **SPECIFICATION, draft.** Round 1 answered 2026-10-01 08:55Z; round 2
(machine within budget, disk, ssh key, budget alert) pending (section 4).
Nothing is created in GCP without the owner's explicit go for that call.
Implementation is a separate go.

Owner topic: t1 `f35d82fc-6110-41cb-8b1b-c66420311583` (2026-10-01).

## 1. What the owner asked for (verbatim, in order)

1. "we need to start to design the feature to have one vm in the GCP cloud
   which will have also running agents ... it should be exactly the same OS
   version as this one, and preferably as much as possible having at least 75%
   of the hardware capacity of this box, but it will not have ui, and it will
   be accessed via ssh from this box (or other boxes for that matter)"
2. "we need to create the specification for that, so ask me questions ..."
3. "the code of this gcp-agent-box should be in terraform"
4. "there is plenty of code under the /opt which provisions similar boxes
   (check all of the wordpress based projects eli-vta etc., or at least the
   latest 3 ones"
5. "so do not re-invent the wheel, this box should NOT be accessible via
   https ... aka it should be considered an extension of this box's terminal
   access ..."
6. "I will use my ai credentials there .."
7. "there should be only one box for both the dev and the prd environments and
   against all best practices make it in the prd project, but it should be able
   to connect to the dev site as well ... we could call this box the satellite
   btw"

8. (round 1) "should not cost more than 170 $ per month - emphasize on RAM
   ... if have to do tradeoffs" and "Estimate the price before go"
9. (round 1) "check the code in terraform from the eli-vta - the code should
   create the public private ssh key to ssh to the box"; "Instead of <the box
   user>, use the default from google debian"; "re-use the same pattern -
   terraform for the outer shell - ansible for the binaries - install on it the
   same binaries we have been using on this laptop for this project"

## 2. Requirements

### 2.1 Hard (from section 1)

| id | requirement | source |
|---|---|---|
| R1 | ONE VM, named **the satellite**, serving both dev and prd | 7 |
| R2 | lives in the **prd** GCP project (`csi-spl-prd`), by explicit owner choice | 7 |
| R3 | reaches the dev environment too (dev hub/WUI, dev GCP via the dev SA key) | 7 |
| R4 | the same OS release as the home box: Debian 13 (trixie), 13.5 at measurement | 1 |
| R5 | at least 75% of the home box's hardware (section 3) | 1 |
| R6 | no UI | 1 |
| R7 | **SSH only**: no http/https, no load balancer, no web DNS, no public web port; an extension of the home box's terminal | 1, 5 |
| R8 | reachable over SSH from the home box and from other fleet boxes | 1 |
| R9 | infra is terraform: a csi-spl-iac step, run only through the tf-runner make path | 3, CLAUDE.md |
| R10 | reuse the existing VM provisioning code under /opt, no new VM module | 4, 5 |
| R11 | the agents use the owner's own AI accounts | 6 |
| R17 | **<= $170 per month in total**, RAM first when trading off; price estimated before the go | 8 |
| R18 | the OS user is GCE Debian's default (`debian`, as in eli-vta), not the home box user | 9 |
| R19 | eli-vta pattern: terraform for the outer shell, ansible for the binaries | 9 |

### 2.2 Repo rules that apply

- R12 terraform runs under the per-env SA key only (`~/.gcp/.csi/key-csi-spl-prd.json`), never the owner account.
- R13 cnf in `csi-spl-cnf/csi-spl/prd.env.yaml`; tfvars rendered by tpl-gen; no literal in the step.
- R14 no key, token or credential in git, terraform state, instance metadata, a startup script, an image or a log.
- R15 every infra step is a named action (`do_<verb>_<noun>`), no ad hoc gcloud.
- R16 the image is pinned (a dated image name in cnf, never a floating family).

## 3. The home box, measured 2026-10-01

| what | value | 75% |
|---|---|---|
| OS | Debian GNU/Linux 13.5 (trixie), kernel 6.12.90 (+deb13 amd64) | same release |
| CPU | Intel Core Ultra 7 255H, 16 cores, 1 thread per core | 12 cores ~ 24 vCPU at core parity, 12 vCPU at count parity |
| RAM | 62 GiB | 47 GiB |
| disk | 889 GB NVMe, 482 GB used | 667 GB |
| GPU | laptop RTX PRO 500; no NVIDIA driver loaded, agents use no GPU | none needed |
| load | ~31 (about 32 agent sessions, docker local stack + tf-runner, chrome e2e) | — |

A GCP vCPU is one hyperthread, so 16 vCPU is about 8 physical cores.

## 4. Decisions

Prices are GCP list price, europe-north1, per month (730 h), approximate.

### 4.1 Round 1 (answered 2026-10-01 08:55Z)

| # | decision | owner answer |
|---|---|---|
| 1 | machine type | none of the four (all ~$325-1000): **<= $170/month in total, RAM first** -> round 2, Q1 |
| 2 | schedule | **A** always on, on-demand |
| 3 | data disk | not answered -> round 2, Q2 |
| 4 | GPU | **A** none |
| 5 | zone | **A** europe-north1-a |
| 6 | OS image | **A** pin the dated `debian-13-trixie-vYYYYMMDD` image, keep the cloud kernel |
| 7 | SSH path | **A** tcp/22 only from Google IAP (35.235.240.0/20); ephemeral IP for outbound only |
| 8 | SSH identity | **the eli-vta pattern: the code creates the ssh key pair** -> round 2, Q3 (the repo forbids a key in tf state) |
| 9 | users and paths | **the GCE Debian default user** (`debian`), not the home box user |
| 10 | installed | **eli-vta pattern**: terraform for the outer shell, ansible for the binaries; the same binaries the home box uses for this project |
| 11 | spool membership | **A** its own box, BOX_TAG `sat`, own spool root and desk seats on dev + prd |
| 12 | GCP + GitHub credentials | **A** a named action copies the dev + prd SA keys and the GitHub token over ssh (0600); the VM SA has no roles beyond logging |
| 13 | backups | **C** none, git is the backup |

### 4.2 Round 2 (posted 2026-10-01 08:57Z, pending)

Fixed in every option: 30 GB boot + 100 GB data disk pd-balanced ~$14,
outbound IPv4 ~$4, IAP free; total = VM + ~$18.

| # | decision | options | recommended | owner answer |
|---|---|---|---|---|
| 1 | machine | A e2-highmem-4, 4 vCPU / 32 GB on-demand, total ~$163; B e2-highmem-8, 8 vCPU / 64 GB, 3-year commitment, total ~$149; C e2-highmem-8 spot, total ~$110-130 (GCP may stop it); D e2-custom 3 vCPU / 24 GB, total ~$127 | A | pending |
| 2 | data disk | A 100 GB pd-balanced; B 200 GB (+$11, 1A goes over budget) | A | pending |
| 3 | ssh key | a eli-vta exactly: terraform creates the pair, the private key lands in the prd tf state (overrides the repo rule for this key); b a named action creates the pair in `~/.ssh/.csi/`, terraform receives only the public key | b | pending |
| 4 | budget alert | A $170/month at 50/90/100%; B none | A | pending |

## 5. Design

### 5.1 What is reused, and from where

The reference code is eli-vta `modules/gcp-compute-instance-v05` with step
`130-org-app-gcp-vm` / `131-gcp-vm-www-data-setup`, the three most recent
WordPress projects under /opt that copy it (the same 130 step on the v04/v05
module; the newest adds an IAP ssh rule), and csi-rel `050-gcp-vm-rdb` (the
same csi tf-runner family as csi-spl).

| taken | from |
|---|---|
| `google_compute_instance` + a separate `google_compute_disk` data disk that survives a VM rebuild, attached by `device_name` | v05 `04.vm.tf`, csi-rel `05.vm.tf` |
| the label set (`org`, `app`, `env`, `managed_by`, `step`, `role`) and `allow_stopping_for_update` | csi-rel `05.vm.tf` |
| firewall rule with target tags and `source_ranges` from a var | csi-rel `06.firewall.tf` |
| the IAP ssh rule (`35.235.240.0/20`, port 22) | the newest WordPress copy's `05.network-config.tf` |
| the ansible-over-ssh bootstrap: inventory + `box-playbook.yaml` + numbered roles | v05 `06.app-vm-ansible.tf`, csi-rel `08.ansible-trigger.tf` |
| role `01_format_and_mount_data_disk` | csi-rel `ansible/roles` |
| the agent harness: `spool-install`, `spawn-agents` | csi-spl-orc features |

| dropped | why |
|---|---|
| firewall 80/443/8080/8443, DNS A/CNAME/CAA, nginx, certbot, WordPress, MySQL, adminer roles, db/wp passwords | R7: no web at all |
| ssh from `0.0.0.0/0` | R7, decision 7 |
| the `tls_private_key` minted by terraform and copied to Secret Manager and a GitHub secret | R14: it lands in terraform state (round 2 Q3 b; with Q3 a the key pair stays in terraform, Secret Manager and the GitHub secret are still dropped) |
| the VM SA with project-wide `storage.admin` | least privilege; the satellite's agents use the per-env SA keys like the home box |
| the ansible run as a terraform `local-exec` | the bootstrap is a re-runnable named action (5.4), so a harness change never needs an apply |

### 5.2 Terraform step `060-gcp-vm-satellite` (csi-spl-iac)

Applied once, in the prd project only (`ENV=prd`); there is no dev twin (R1, R2).

1. `01-providers.tf`, `02-variables.tf` as in `050-gcs-files`.
2. `03-vm.tf`: the data disk and the instance `csi-spl-prd-satellite`;
   boot disk pd-balanced from the pinned image; `metadata.ssh-keys` built from
   the public key of the pair (round 2 Q3); `enable-oslogin = FALSE` (decision 8);
   network tag `allow-ssh-iap-csi-spl-prd-satellite`; no web tag.
3. `04-sa.tf`: a dedicated VM SA `csi-spl-prd-satellite` with
   `roles/logging.logWriter` and `roles/monitoring.metricWriter` only.
4. `05-firewall.tf`: one ingress rule, tcp/22 from `ssh_source_ranges`
   (default the IAP range). No other ingress rule exists for the tag.
5. `06-iap.tf`: `roles/iap.tunnelResourceAccessor` on the instance for the
   members in cnf (the prd SA and the owner).
6. `07-ansible.tf`: the eli-vta `06.app-vm-ansible.tf` pattern: renders the
   inventory and the `run-ansible-*.sh` script (the IAP `ProxyCommand` in the
   inventory); it does not run them (5.4 does).
7. No snapshot schedule (round 1, Q13: git is the backup).
8. `08-budget.tf`: a `google_billing_budget` at `budget_usd_month` with 50/90/100% alerts (round 2 Q4; the billing account id comes from `GCP_BILLING_ACCOUNT_ID`, never cnf).
9. `09-outputs.tf`: instance name, zone, internal IP. No key, no secret.

### 5.3 cnf (`csi-spl-cnf/csi-spl/prd.env.yaml`, `steps.060-gcp-vm-satellite`)

```yaml
060-gcp-vm-satellite:
  vm_name: csi-spl-prd-satellite
  gcp_zone: europe-north1-a
  machine_type: e2-highmem-4   # round 2 Q1
  boot_disk_image: projects/debian-cloud/global/images/debian-13-trixie-v20260921
  boot_disk_size_gb: 30
  data_disk_name: csi-spl-prd-satellite-data
  data_disk_type: pd-balanced
  data_disk_size_gb: 100       # round 2 Q2
  data_disk_prevent_destroy: true
  os_user: debian              # the GCE Debian default, as eli-vta (round 1 Q9)
  ssh_public_key_file: ~/.ssh/.csi/debian@csi-spl-prd-satellite.pub   # round 2 Q3 b
  ssh_source_ranges: ["35.235.240.0/20"]
  iap_members: []              # the prd SA + the owner
  budget_usd_month: 170        # round 2 Q4
```

The tfvars template is `csi-spl-iac/src/tpl/%org%-%app%/%env%/tf/060-gcp-vm-satellite.*.tfvars.tpl`,
rendered by `make do-generate-config-for-step`, like every other step.

### 5.4 Bootstrap: `./run -a do_satellite_bootstrap` (csi-spl-iac)

Runs from any fleet box, over the IAP tunnel, idempotent, re-runnable.

1. ssh through `gcloud compute start-iap-tunnel` with `--account` = the prd SA
   (throwaway `CLOUDSDK_CONFIG`, per the repo rule).
2. ansible `box-playbook.yaml`, roles:
   `01_format_and_mount_data_disk` (csi-rel, mounts at `/opt` and `/var/spool-hub`),
   `02_os_user` (`debian`: groups docker, the `/opt/csi` tree owned by it),
   `03_os_packages` (tmux, git, docker, node + corepack pnpm, go, terraform, gcloud, chrome, jq, yq, python3),
   `04_agent_clis` (claude, gemini, grok, agy, qwen),
   `05_spool_harness` (csi-spl-orc `spool-install`, `spawn-agents`),
   `06_ssh_hardening` (keys only, no root, no password).
3. Prints one verdict line per role.

Credentials are a separate action, `./run -a do_satellite_creds_push`
(decision 12): rsync over the same tunnel of `~/.gcp/.csi/key-csi-spl-{dev,prd}.json`
and the GitHub token, mode 0600, into the agent user's home. The owner's AI
accounts (R11) are logged in on the satellite with each CLI's paste-the-code
login, so no AI token is copied. There are no snapshots (round 1 Q13), so no
copy of these credentials exists outside the VM's disk.

### 5.5 Access from a fleet box

`./run -a do_satellite_ssh_config` writes a `Host satellite` block into the
box user's `~/.ssh/config` with a `ProxyCommand` through the IAP tunnel.
After that, `ssh satellite` is the extension of the terminal (R7, R8).

### 5.6 Reaching dev (R3)

The satellite holds the dev SA key next to the prd one, and every csi-spl
action already selects its key by `ENV`, so `ENV=dev ./run -a ...` on the
satellite reaches dev exactly as on the home box. The dev hub and WUI are
public endpoints; no cross-project IAM is needed.

## 6. Out of scope

- Applying any of this (owner go per call: the step's `make do-provision`, the bootstrap, the credentials push).
- A second satellite, a dev twin, autoscaling, a GPU.
- Any web endpoint on the satellite.
