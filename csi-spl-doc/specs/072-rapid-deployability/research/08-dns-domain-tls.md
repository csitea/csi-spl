# 072 research 08: DNS, domain, TLS, tenant hosts

Status: **research v0.1**, for the lead of spec 072 to merge (section 9).
Tree: `474b940a8` (2026-10-04), n = 1 per command unless stated. Docs only:
nothing built, nothing applied, no GCP call that writes. `<BASE_DOMAIN>`,
`<fqdn>`, `<tenant>`, `<ip>` are placeholders; no estate value appears here.

The question of this section: **what is the least a newcomer needs for names
and certificates, and can it run with no custom domain at all?**

| path | no domain at all | own domain |
|---|---|---|
| P1 compose, one user | **works** on localhost; from another machine only through an SSH tunnel (1.3) | works: an A record + 4 env vars, Caddy fetches the certificate |
| P1 compose, plain `http://<ip>` | **half-broken**: sign-in works, file attachments fail (1.3) | n/a |
| P2 GCP estate | **cannot**: steps 005, 025, 032 and the WUI's custom domain assume one | works after ~6 human DNS steps and a 10-30 min certificate wait per host |
| P3 agent box | needs no domain: it points at whatever hub URL it is given | same |

## 1. Today (the walk, measured)

### 1.1 One domain literal, in cnf only

| fact | command -> result |
|---|---|
| the domain lives in one cnf key, derived into `fqdn` and `api_fqdn` at render time | `grep -n 'BASE_DOMAIN:' csi-spl-cnf/csi-spl/all.env.yaml` -> line 12; derivation `csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh:33-34` |
| no code file carries the literal | `D=$(sed -n 's/^ *BASE_DOMAIN: *//p' csi-spl-cnf/csi-spl/all.env.yaml); git grep -l -F "$D" \| awk -F/ '{print $1}' \| sort \| uniq -c` -> `15 csi-spl-cnf`, `73 csi-spl-doc`, 0 elsewhere |
| a test guards it | `csi-spl-iac/src/bash/tests/domain-single-source.tst.sh` (named at `all.env.yaml:11`) |
| `api_fqdn` may be set literally (a literal wins) | `spl-merged-cnf.func.sh:9` ("a literal wins"), `:34` |

A fork changes one key, not code. The 73 doc files are prose and block no
deploy; the 15 cnf files are the env files plus rendered tfvars.

### 1.2 P1 compose: names and TLS

| fact | command -> result |
|---|---|
| Caddy is the one front door; `SPOOL_SITE_ADDRESS=:80` is plain http, a hostname makes Caddy fetch and renew a certificate | `csi-spl-wui/src/docker/Caddyfile:2-4,9`; `docker-compose.yml:148` |
| own domain = 4 name variables that all say the same host | README "Your own domain" rows `SPOOL_PUBLIC_URL`, `SPOOL_SITE_ADDRESS`, `SPOOL_DOMAIN`, plus `SPOOL_COOKIE_SECURE` (`.env.example:77`) |
| the hub's tenant host pattern is `{tenant}.${SPOOL_DOMAIN:-localhost}` and must look like `{tenant}.<fqdn>` | `docker-compose.yml:88`; `csi-spl-api/src/go/spool-hub-api/internal/config/config.go:475` |
| compose never hops to a tenant host: the WUI's tenant-host mode is off unless `NUXT_PUBLIC_TENANT_HOSTS=1`, which the compose build never sets | `csi-spl-wui/nuxt.config.ts:496` default `"0"`; `grep -c TENANT_HOSTS csi-spl-wui/src/docker/wui.Dockerfile docker-compose.yml` -> 0, 0 |
| the public URL and tenant are baked at build | `csi-spl-wui/src/docker/wui.Dockerfile:30-31` (spec 072 F2 / A3) |
| no DNS or port preflight before `up` | spec 072 F5 |

**One compose stack = one tenant on one host**, so P1 never needs a wildcard
DNS record or a wildcard certificate. That is the cheapest possible TLS story
and it already holds.

### 1.3 P1 with no domain

| shape | result | why (file:line) |
|---|---|---|
| browser on the same machine, `http://localhost:8080` | works (047 1.1: 6 min 26 s to the first message, n=1) | localhost is a secure context; `SPOOL_COOKIE_SECURE` defaults to `false` (`docker-compose.yml:106`) |
| browser elsewhere, `ssh -L 8080:localhost:8080 <box>`, then `http://localhost:8080` | works by the same reasoning; **not measured** in this pass (n=0) | the browser still sees `localhost`; README does not say so |
| browser elsewhere, `SPOOL_PUBLIC_URL=http://<ip>:8080`, `SPOOL_BIND=0.0.0.0` | sign-in works (cookie not Secure); **file upload and download break** | `crypto.subtle` exists only in a secure context and the WUI hashes every file with it: `csi-spl-wui/src/utils/spool-client.mjs:86` (upload, called at `:719`), `csi-spl-wui/src/components/FileAttachment.vue:94,133` (download check). Reasoned from the code, not driven in a browser (n=0) |
| `SPOOL_SITE_ADDRESS=<ip>` (a certificate for a bare IP) | I believe, unchecked, that Caddy's default ACME issuers will not issue one with this Caddyfile | image `caddy:2-alpine` (`wui.Dockerfile:45`) |

Nothing refuses or warns about the `http://<ip>` shape:
`grep -rn 'isSecureContext' csi-spl-wui/src` -> 0 hits.

### 1.4 P2 GCP estate: names, certificates, no load balancer

| step | what it needs from a human | evidence |
|---|---|---|
| registrar | NS delegation of `<BASE_DOMAIN>` to the prd Cloud DNS zone, which is adopted (imported), never created | `csi-spl-cnf/csi-spl/dev.env.yaml:148` |
| 005 domain verification | the env SA must become a verified owner before any Cloud Run mapping: `do_spl_domain_verify` (token) -> paste a record into cnf -> render -> provision 005 -> `VERIFY=1` | `csi-spl-orc/src/bash/run/spl-domain-verify.func.sh:3-14`; 005 writes into the prd zone with the prd provider (`csi-spl-iac/src/terraform/005-gcp-domain-verification/05.site-verification.tf:14`) |
| 025 DNS zone | the dev subzone is created and delegated from the prd zone on the **prd key**: apply prd before dev | `dev.env.yaml:146-152` |
| 019 Firebase site | the WUI on `<fqdn>` as a Firebase custom domain; certificate wait 10-25 min (047) | `csi-spl-orc/src/bash/run/spl-wait-for-firebase-domain.func.sh` |
| 032 domain mapping | the hub on `api_fqdn` as a Cloud Run domain mapping, its own certificate wait | `dev.env.yaml` 032 comment ("do_spl_wait_for_mapping_cert per host") |
| load balancer | **none**, by owner decision ("exactly csi-rel: no load balancer"); so **no wildcard certificate**: every tenant host is one Firebase custom domain plus its 025 records | `all.env.yaml:72-76`; `.github/workflows/40_tenant-host-reconcile.yml:13-15` |

### 1.5 The tenant-host hop (047 W1/W12/W15, SPL-1161)

- GCP WUI builds turn tenant hosts on (`wui_tenant_hosts: true`,
  `csi-spl-cnf/csi-spl/prd.env.yaml:138`), so after sign-in on the apex the
  WUI hops to `<tenant>.<fqdn>`.
- A paid tenant's host is provisioned by workflow 40. Its header says
  **"REVIVED - owner option A, 2026-09-30"** (`40_tenant-host-reconcile.yml:3`),
  but GitHub says it is off:
  `gh workflow list --all | grep -i tenant` -> `40 cd: tenant host reconcile  disabled_manually`;
  `gh run list --workflow 40_tenant-host-reconcile.yml` -> last run
  2026-09-19 (cancelled). The header and the switch disagree.
- The WUI no longer strands a buyer on NXDOMAIN: it probes `<host>/build.json`
  first and shows "your address is being prepared"
  (`csi-spl-wui/src/utils/tenant-host-boot.mjs:13-22`). With workflow 40 off,
  "being prepared" ends only when an operator runs
  `do_spl_tenant_host_provision` by hand.
- Each new host costs a cnf commit (`env.dns.mapped_tenants`, rewritten by the
  action, `prd.env.yaml:23-24`), a 019 + 025 apply, a WUI re-deploy (its CSP
  lists the hosts, wf 40 header step 3) and a ~30 min certificate wait.

A **newcomer's** estate needs none of this: one tenant on the apex is a
complete product. Tenant hosts are a multi-tenant SaaS feature, and today they
are on in every env file a fork would copy.

## 2. Blockers

1. **Plain http off localhost silently breaks files.** `spool-client.mjs:86`
   calls `crypto.subtle.digest` with no secure-context check; on `http://<ip>`
   uploads and downloads fail with a browser error, not a Spool message.
   Neither hub-init nor README refuses or warns.
2. **The zero-domain remote path is undocumented.** The SSH tunnel (1.3 row 2)
   is the only no-domain shape that keeps every feature, and
   `grep -c 'ssh -L' README.md` -> 0.
3. **Four variables for one name.** `SPOOL_PUBLIC_URL`, `SPOOL_SITE_ADDRESS`,
   `SPOOL_DOMAIN`, `SPOOL_COOKIE_SECURE` must agree by hand (README table); a
   mismatch shows up as a failed certificate, a CORS refusal or a lost cookie,
   never as a named error.
4. **GCP has no "no custom domain" mode.** `fqdn` is always derived from
   `BASE_DOMAIN` (`spl-merged-cnf.func.sh:33`); 005/025/032 and the 019 custom
   domain assume a delegated zone. A newcomer must own and delegate a domain
   before the first plan is meaningful.
5. **Tenant hosts are on by default for a fork.** `wui_tenant_hosts: true` in
   both env files, and provisioning depends on workflow 40, which is
   `disabled_manually` while its header says revived (1.5). On a fork the
   first tenant other than the apex sits on "being prepared" for ever.
6. **Domain verification is 5 manual steps across two keys** (1.4 row 005),
   and a fork's SA starts with no verified ownership.

## 3. Actions

One lane each. `D1..D7` are new ids in spec 072 section 6 shape; "feeds" names
the 072 A/G/F id it changes.

| id | action | feeds | lane | effort | done when (a test can check) |
|---|---|---|---|---|---|
| **D1** | hub-init (or the A2 preflight) refuses `SPOOL_PUBLIC_URL=http://<non-loopback>` unless `SPOOL_ALLOW_INSECURE_HTTP=1`, naming the two fixes (own domain, SSH tunnel); the WUI shows a one-line banner when `!isSecureContext` | G3, A2 | api + WUI | S | compose test with `SPOOL_PUBLIC_URL=http://203.0.113.5:8080` -> hub-init exits non-zero and its log names both fixes; `localhost` -> exit 0 (control); WUI unit test: `isSecureContext=false` renders the banner |
| **D2** | README "No domain yet" subsection: localhost, and `ssh -L 8080:localhost:8080 <box>` for a remote browser; one line on why plain `http://<ip>` is not supported | A15 | docs | XS | `grep -c 'ssh -L' README.md` -> >= 1; doc-link tests green |
| **D3** | One name variable: derive `SPOOL_SITE_ADDRESS`, `SPOOL_DOMAIN` and `SPOOL_COOKIE_SECURE` from `SPOOL_PUBLIC_URL` in the web and hub-init entrypoints, unless set explicitly | G3, A2 | orc + WUI docker | S | compose with only `SPOOL_PUBLIC_URL=https://chat.example.test` -> the web container's site address is `chat.example.test` and the hub's cookie-secure is `true`; README name rows go from 4 to 1 |
| **D4** | `do_spl_self_host_preflight` (A2's DNS half, landable alone): the URL host's A/AAAA record resolves to this machine's public IP, ports 80/443 reach it, the host is not a bare IP; each failure prints its fix | A2, F5 | orc | S | test with a stub resolver: wrong A record -> exit 1 naming the record; bare IP -> exit 1 pointing at D2; correct -> exit 0 |
| **D5** | Tenant hosts off in the newcomer template: the A7 blank cnf sets `wui_tenant_hosts: false`, `mapped_tenants: []`, `redirect_hosts: []`; the tenant lives on the apex | A7, A12 | cnf | XS | `do_spl_cnf_init` with sample answers -> the merged cnf has `wui_tenant_hosts: false` and the rendered 019 tfvars 0 additional custom domains |
| **D6** | GCP "no custom domain" mode: `BASE_DOMAIN: ""` makes `fqdn` the Firebase default site host and `api_fqdn` the Cloud Run service URL, and turns 005/025/032 off (A12's skip) | A7, A12 | iac + cnf | M | `ENV=<env> ./run -a do_tpl_gen` with `BASE_DOMAIN: ""` renders and conf-validator accepts it; the sweep plans 0 resources in 005/025/032; `auth-urls-from-fqdn.tst.sh` gains an empty-domain case |
| **D7** | Workflow headers agree with GitHub: a check (deploy-lag family) that fails when a header says enabled/revived and `gh workflow list` says disabled; then fix wf 40's header or switch | SPL-1161, 047 B5 | orc + CI | XS | the check today -> red naming wf 40; after the fix -> green |

Order by the 072 ranking rule (time to first deploy, manual steps, clarity of
errors): **D2, D1, D3** (P1, every newcomer), then D4 (folds into A2), D5
(folds into A7), D7, D6.

Costs, as numbers: D1-D5 and D7 add no running cost. D6 removes one Cloud DNS
zone per env (list price ~USD 0.20/zone/month, unchecked) and the 10-30 min
certificate waits from the first deploy. Workflow 40 enabled runs 4 times an
hour (`cron: "7,22,37,52 * * * *"`, line 43) = 96 runs/day per env, each about
one runner minute when nothing is open (header: "the job ends after one read").

## 4. Questions for the owner

1. **Is plain `http://<ip>` a supported shape?**
   Recommended: **no**. Refuse it with a named fix (D1) and document the SSH
   tunnel (D2). Supporting it needs a non-crypto file-hash path and a
   non-Secure cookie on the open internet.
2. **Should a newcomer with no domain get TLS through a public IP-embedding
   wildcard DNS name (`<ip>.<wildcard-dns-service>`)?** It gives Caddy a real
   hostname, so a real certificate, in one step.
   Recommended: **offer it as D4's printed fallback, never the default**: it
   puts a third party in the name path of someone's chat.
3. **Workflow 40 (SPL-1161)**: the header says revived on 2026-09-30 under
   option A; GitHub says `disabled_manually`. Which is meant?
   Recommended: enable it for our estate if option A stands (the WUI's "being
   prepared" state covers the wait), and ship D5 so forks never depend on it.
4. **Is GCP without a custom domain (D6) worth an M lane now?**
   Recommended: **yes, after D1-D5**. It removes P2's hardest human
   prerequisite (a delegated domain plus the 005 dance) and the first
   certificate waits; a fork adds its domain later by setting one key.
