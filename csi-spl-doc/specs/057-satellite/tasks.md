# 057 — the satellite: tasks

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md).
Every apply, bootstrap and credentials push needs the owner's go for that call.
As built: spec section 7 (csi-spl-all, steps 059 + 060, bash bootstrap roles).

## 1. Specification

- [x] T001 Measure the home box (spec 3)
- [x] T002 Study the existing VM code under /opt, decide what is reused and dropped (spec 5.1)
- [x] T003 Round-1 questions posted in f35d82fc; answered 08:55Z, recorded in spec 4.1
- [x] T004 Round-2 answers (machine, disk, ssh key, budget) recorded in spec 4.2, design updated to match
- [x] T005 Owner go for implementation

## 2. Terraform (after T005)

- [x] T009 `do_satellite_ssh_keygen` + test (round 2 Q3 b): the key pair in `~/.ssh/.csi/`, the public key path into cnf
- [x] T010 cnf `steps.060-gcp-vm-satellite` in `prd.env.yaml`, tfvars templates, `do_tpl_gen` clean
- [x] T011 Step `060-gcp-vm-satellite` from csi-rel `050-gcp-vm-rdb`, trimmed per spec 5.1
- [x] T012 Tests: tcp/22 is the only ingress; no key resource; no web tag; dated image
- [ ] T013 Price confirmed from the Cloud Billing catalogue, <= $170/month (owner go to turn its API on). The owner's go was on the list estimate (~$163, 2026-10-01 12:57Z)
- [x] T014 `make do-tf-plan` (ENV=prd cnf, csi-spl-all key), 059 then 060; plan + price to the owner (CLE-001)
- [x] T015 Owner go -> `make do-provision`: 059 budget (~13:40Z, applied by the prd-linked owner billing, no costsManager grant needed) and 060 VM applied by CLE-001; ssh + bootstrap done, verified 14:05Z (Debian 13, 4 vCPU / 31 GB, /mnt/data on /opt + /var/spool-hub, claude + spool, SPOOL_BOX_TAG=sat)

## 3. Box (after T015)

- [x] T020 `do_satellite_ssh_config` + test
- [x] T021 `do_satellite_bootstrap` (bash roles 01/02/03/06 + 05 spool harness, spec 7) + test
- [x] T022 `do_satellite_creds_push` + test
- [ ] T023 Owner AI logins on the satellite
- [ ] T024 First agent spawned on the satellite; it shows on the spool under its BOX_TAG
