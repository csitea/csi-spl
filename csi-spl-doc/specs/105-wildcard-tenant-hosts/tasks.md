# 105 one wildcard certificate for every workspace host: tasks

**Version**: v0.1 · **Spec**: [spec.md](spec.md)  
Status vocabulary: `../README.md` §2.3. Paths are repo-relative.

**One lane per task.** Each task names the files it owns. A file has one
owner at a time; a task that edits a file another task created starts only
after that task has landed on master. Dependencies are stated per task.

Every build task is done only when:
- iac / cnf tasks: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` green,
  `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code` clean;
- orc tasks: the orc suite green;
- hub tasks: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green;
- WUI tasks: `pnpm run typecheck`, `pnpm run test:unit` and
  `BASE_URL=<generated bundle> pnpm run test:e2e` green in `csi-spl-wui`;
- all: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` and
  `./run -a do_check_pre_push` green; landed on master.

**Owner go needed** (repo `CLAUDE.md`): every `make do-provision` /
`do-deprovision` in T008, T009 and T010. Building and planning need none.

**Never touched by any task below**: `csi-spl-iac/src/terraform/032-gcp-cloud-run-domain-mapping/**`
(the api host stays as it is, spec FR-006), `csi-spl-api/src/go/spool-hub-api/internal/hub/origin_tenant.go`,
`csi-spl-api/src/go/spool-hub-api/internal/hub/auth_cors.go`, the cookie and
CSP settings (spec §1.2).

---

### Phase 0: specification

- [x] T001 **v0.1 design** (lane c-504): `spec.md`, `tasks.md`.

### Phase 1: build (no GCP mutation)

- [ ] T002 **step `031-gcp-wildcard-ingress`**
  - **Owns**: `csi-spl-iac/src/terraform/031-gcp-wildcard-ingress/**` (creates),
    its tfvars templates under the tpl-gen tree (creates),
    `csi-spl-iac/src/bash/tests/wildcard-ingress-031.tst.sh` (creates),
    `csi-spl-iac/src/bash/tests/wui-hosting-019-031.tst.sh` (the "031 must
    not return" assertion becomes "031 is the wildcard ingress shape").
  - **Depends on**: T001.
  - **Builds**: spec §3.1, §3.4: certificate `[<fqdn>, *.<fqdn>]` with DNS
    authorization, certificate map + PRIMARY entry, global address, url map
    (`<fqdn>`, `*.<fqdn>` -> wui; default 404), HTTPS proxy + rule, HTTP
    redirect proxy + rule, internet NEG to `<site_id>.web.app:443` with Host
    rewrite. No Cloud Armor, no serverless NEG. Start from `70b84824^`.
  - **Positive test**: `make do-tf-plan` for dev lists only creates (no
    change outside the step); the test asserts both certificate names, two
    forwarding rules, and that no `google_compute_security_policy` exists.
  - **Negative test**: a planted serverless NEG or a third forwarding rule
    fails the test.

- [ ] T003 **cnf split + `025` wildcard records**
  - **Owns**: `csi-spl-iac/src/terraform/025-gcp-dns-zone/**`, the 025
    tfvars templates, the cnf keys `env.dns.wildcard_tenants`,
    `env.dns.wildcard_apex` and the `025` `wildcard_ingress_ip` wiring in
    `csi-spl-cnf/csi-spl/{all,dev,prd}.env.yaml` (both start empty / false),
    `csi-spl-iac/src/bash/tests/dns-zone-025.tst.sh`.
  - **Depends on**: T002 landed (reads its output).
  - **Builds**: spec §3.3, §5.1: the `*` A + `_acme-challenge` CNAME when the
    ip is set; a tenant in `wildcard_tenants` gets no explicit `025` record;
    `wildcard_apex: true` points the apex A at the LB IP.
  - **Positive test**: rendering with `wildcard_tenants: [e2e]` drops e2e's
    A + TXT and keeps its `019` domain; every other tenant's records are
    byte-identical.
  - **Negative test (CONTROL)**: a plan that destroys the `019` domain of a
    tenant still in `wildcard_tenants` is refused by the gate.

- [ ] T004 **`do_spl_wildcard_host_probe HOST= ENV= [LB_IP=]`**
  - **Owns**: `csi-spl-orc/src/bash/run/wildcard-host-probe.func.sh`
    (creates) and its test (creates).
  - **Depends on**: T001.
  - **Builds**: spec §5.2 steps 1-7 and 10 (8 and 9 are the WUI e2e run the
    action invokes with `BASE_URL=https://<host>`). `LB_IP` set = the
    before-move mode (`curl --resolve`).
  - **Positive test**: against fixtures, all steps PASS.
  - **Negative tests**: each step fails on its planted bad input (wrong
    SAN, a CSP one byte different, `Location` naming `web.app`, a DNS answer
    of `199.36.158.100` in after-move mode).

- [ ] T005 **daily soak probe**
  - **Owns**: one line in the existing probe cadence that runs T004 for
    every host in `wildcard_tenants` that is also still in `mapped_tenants`.
    No new workflow.
  - **Depends on**: T004 landed.
  - **Positive test**: a host in both lists is probed; a fully moved host is
    not.

- [ ] T006 **hub: a host is ready at once while the wildcard is on**
  - **Owns**: the `tenant_hosts` insert path and `host_status` in
    `internal/payments/handler.go`, a new hub env flag
    `SPOOL_HUB_WILDCARD_HOSTS` (default false) in `internal/config/config.go`,
    their tests.
  - **Depends on**: T001.
  - **Builds**: spec §4: with the flag on, checkout status and claim answer
    `host_status: ready` for every tenant; the "being prepared" page never
    shows.
  - **Positive test**: flag on, a fresh tenant reads `ready` with no
    reconcile. **Negative test**: flag off, behaviour as today (`pending`).

- [ ] T007 **WUI: "no workspace at this address"**
  - **Owns**: the WUI page or state shown when the hub refuses the page
    tenant as unknown, and its unit + e2e test.
  - **Depends on**: the owner's answer to spec §7 Q2.
  - **Positive test**: `nosuch.<fqdn>` (mock) shows the message and a link
    to the apex. **Negative test**: a member of an existing tenant never
    sees it.

### Phase 2: dev (owner go per apply)

- [ ] T008 **dev: build, canary, move `e2e`, `csitea`, then the dev apex**
  - **Owns**: `csi-spl-cnf/csi-spl/dev.env.yaml` lines `wildcard_tenants`
    and `wildcard_apex` only, and this spec's §5.2 step 10 result.
  - **Depends on**: T002, T003, T004 landed; owner go.
  - **Does**: spec §5.3 item 1, one host at a time, before- and after-move
    proof per host, rollback on any red. Sets hub flag `SPOOL_HUB_WILDCARD_HOSTS`
    for dev only after the canary passes (T006 landed).
  - **Done**: every dev host green on T004 after the move; the owner told
    once.

### Phase 3: prd (owner go per apply)

- [ ] T009 **prd: build, canary, move every tenant, t1 last**
  - **Owns**: `csi-spl-cnf/csi-spl/prd.env.yaml` lines `wildcard_tenants`
    and `wildcard_apex` only.
  - **Depends on**: T008 done; owner go.
  - **Does**: spec §5.3 item 2. The order is measured on the day.

### Phase 4: cleanup (owner go)

- [ ] T010 **remove the per-host machinery**
  - **Owns**: `.github/workflows/40_tenant-host-reconcile.yml` (deletes),
    `csi-spl-orc` `do_spl_tenant_host_provision` / `_deprovision` /
    `_reconcile` and their tests (deletes), `env.dns.mapped_tenants` and
    `019` `additional_fqdns` (empties), the 024 / SPL-959 notes that point
    at them.
  - **Depends on**: T009 done and every host's 7-day soak green (spec §5.4).
  - **Does**: per batch, empty `mapped_tenants` for soaked hosts, which
    removes their `019` custom domains; then delete the machinery once the
    list is empty in both envs.
  - **Positive test**: `do_spl_lb_absent_check`-style read lists 0 `019`
    tenant domains and the wildcard still serves every tenant (T004 run over
    all tenant rows). **Negative test**: the gate refuses to empty a host
    whose soak is younger than 7 days.

<!-- version: 0.1.0 · updated: 2026-10-07 -->
