# Tasks: spool-hub-api infra

**Feature**: `specs/007-spool-hub-api-infra`

Reference trees: csi-rel-iac/orc, pas-psf-iac/orc. Morph then strip shop.

## Phase 1: lde / docker (US1)

- [ ] T001 Copy `docker-compose-{api,rdb,infra}.yaml` + Dockerfiles from
      pas-psf-orc / csi-rel-orc into `csi-spl-orc/src/docker/`; rename
      service to spool-hub-api; drop wui/wordpress/stripe-mock
- [ ] T002 Copy `gen-docker-env.func.sh` and docker check-install actions
      into `csi-spl-orc/src/bash/run/`
- [ ] T003 [P] lde smoke: compose rdb+api up; `go test` against local DSN

## Phase 2: terraform steps (US2)

- [ ] T004 Extend `001-enable-gcp-services` APIs (run, sqladmin, dns,
      secretmanager, artifactregistry)
- [ ] T005 [P] Morph `003-gcp-iam-users`, `005-gcp-domain-verification`
- [ ] T006 Morph `007-dns` **and** Gandi LiveDNS: public NS stay `*.gandi.net`
      (feature.md §3.3). Copy dob-luk-iac `gandi-api` + get/set nameservers +
      list/set LiveDNS records. Domain from cnf `env.dns.BASE_DOMAIN` only.
      Do **not** `do_gandi_set_nameservers` to GCP Cloud DNS. Dry-run unless
      `CONFIRM=yes`. Wildcard `*` + env fqdn records. No apply without owner go.
- [ ] T007 [P] Morph `017-github-wif-deploy`, `028-gcp-artifact-registry`,
      `029-create-gcp-secrets` (no shop captcha/BIN)
- [ ] T008 Morph `030-gcp-cloud-run` for spool-hub-api (WS, min instances cnf)
- [ ] T009 Morph `031-gcp-cloud-run-domain-mapping` + wire `do_wait_for_cert`
- [ ] T010 Morph `040-gcp-cloud-sql`
- [ ] T011 Files bucket step (prefix isolation); **not** git-rel `020`
- [ ] T012 [P] cnf tfvars templates under `csi-spl-cnf` for each new step
- [ ] T013 `terraform validate` each step (`tf-plan`); no apply in CI

## Phase 3: DNS ops + rdb (US3–4)

- [ ] T014 Copy `export-all-dns-settings`, `flush-dns`, `wait-for-cert` into
      csi-spl-orc. Public record writes go through Gandi LiveDNS (`do_gandi_*`),
      not a GCP-only flush that assumes Cloud DNS is authoritative.
- [ ] T015 `csi-spl-rdb` numbered SQL for spool tables only
- [ ] T016 Test: grep rdb SQL for store entities (product, cart, sku, wp_)
      is empty
- [ ] T017 Hygiene: no baked hostname in Go; no keys in tf

## Out of this task list

M2 payment secrets/drivers. M3 WUI firebase. Store TF steps listed in the
narrative “do not copy”.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T17:50:00Z -->
