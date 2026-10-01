# 057 — the satellite: tasks

Spec: [spec.md](spec.md). Plan: [plan.md](plan.md).
Every apply, bootstrap and credentials push needs the owner's go for that call.

## 1. Specification

- [x] T001 Measure the home box (spec 3)
- [x] T002 Study the existing VM code under /opt, decide what is reused and dropped (spec 5.1)
- [x] T003 Round-1 questions posted in f35d82fc; answered 08:55Z, recorded in spec 4.1
- [ ] T004 Round-2 answers (machine, disk, ssh key, budget) recorded in spec 4.2, design updated to match
- [ ] T005 Owner go for implementation

## 2. Terraform (after T005)

- [ ] T009 `do_satellite_ssh_keygen` + test (round 2 Q3 b): the key pair in `~/.ssh/.csi/`, the public key path into cnf
- [ ] T010 cnf `steps.060-gcp-vm-satellite` in `prd.env.yaml`, tfvars templates, `do_tpl_gen` clean
- [ ] T011 Step `060-gcp-vm-satellite` from csi-rel `050-gcp-vm-rdb`, trimmed per spec 5.1
- [ ] T012 Tests: tcp/22 is the only ingress; no key resource; no web tag; dated image
- [ ] T013 Price confirmed from the Cloud Billing catalogue, <= $170/month (owner go to turn its API on)
- [ ] T014 `make do-tf-plan` (prd), plan + price to the owner
- [ ] T015 Owner go -> `make do-provision`

## 3. Box (after T015)

- [ ] T020 `do_satellite_ssh_config` + test
- [ ] T021 `do_satellite_bootstrap` (ansible roles 01-06, spec 5.4) + test
- [ ] T022 `do_satellite_creds_push` + test
- [ ] T023 Owner AI logins on the satellite
- [ ] T024 First agent spawned on the satellite; it shows on the spool under its BOX_TAG
