# 21: a new private cloud, end to end: the baseline hours

Issue SPL-59. Lane c-571, 2026-10-15, tree `origin/master` @ `b340c14c5`.
**Plan only: nothing here was applied, and nothing mutates GCP without the
owner's go.** The GCP figures below were read, not made: `gcloud ... list` and
`describe` under the per-env project service account in a private
`CLOUDSDK_CONFIG`, as the repo CLAUDE.md requires.

It answers one question that 072 section 4.3 left open: 4.3 counts the manual
steps of a P2 estate (one GCP estate, dev + prd) and says 047's "2-3 working
days" is an **estimate, not measured**. This file times each step from what
the repo and the live estate already record, marks who has to act, and names
the critical path. It does not repeat 4.3's step counts or the research files'
findings; it points to them.

`<fqdn>`, `<org>`, `<app>`, `<env>`, `<region>` and `<tenant>` are placeholders.

## 1. Where the numbers come from

Each number carries its source and its kind: **measured** (a timestamp pair
or a timed run, with n), or **estimate** (no record exists; the reason is
given).

| source | what it gives | how to re-read it |
|---|---|---|
| Cloud SQL operation log | the instance CREATE, start to end, per env | `gcloud sql operations list --project <org>-<app>-<env> --instance <instance> --account <env SA> --format='value(operationType,startTime,endTime)'` |
| Cloud Run domain mapping | `metadata.creationTimestamp` to the `CertificateProvisioned` condition's `lastTransitionTime` | `gcloud beta run domain-mappings list --project <org>-<app>-<env> --region <region> --account <env SA> --format=json` |
| project and resource `createTime` | the calendar of the first build of this estate | `gcloud projects describe`, `gcloud run services list`, `gcloud artifacts repositories list`, each with `--account <env SA>` |
| tf-runner apply logs | terraform's own `Creation complete after <t>` per resource | `grep -hoE 'Creation complete after [0-9hms]+' csi-spl-iac/dat/log/tf_apply.<org>-<app>-<env>.<step>.log` in the main checkout (it keeps the last apply of each step only) |
| CI run times | wf 20, wf 30, wf 50 wall time | the `gh run list ... --json createdAt,updatedAt` lines in research 05, 06 and 20 |
| research 02, 03, 07, 10, 13 and 047 | gcp-000 behaviour, render + validate, migrate, box install, tenant walk, compose walk | each file's own table |

## 2. The step table

One estate, two envs, in the order of devops-guide sections 3-9 (which follows
spec 007 section 1). Who acts: **owner** = the owner's go or the owner's own
hands (repo CLAUDE.md, "Nothing mutates GCP without the owner");
**operator** = whoever runs the estate, human or agent; **wait** = nobody, a
clock. Times are per estate (both envs) unless the row says "per env".

| # | step | who | machine / wait time | human time | kind | source |
|---|---|---|---|---|---|---|
| 0.1 | prerequisites: GCP org or folder, billing account, org-admin login, a domain at a registrar, an SMTP relay, the sign-in IdP client(s), a GitHub repo and token | **owner** | calendar: minutes if they exist, **days** if billing or the domain is new | 1-2 h | estimate: each is outside the repo | 072 4.3 row 1 |
| 0.2 | box: packages, users, clone, harness | operator | ~2 min 10 s | 15-30 min reading the installation guide | measured n=1 (machine) | research 10 section 1 |
| 0.3 | `make do-setup-app-inf`: tf-runner, tpl-gen, conf-validator images | operator | 5-10 min | 0 | estimate: not timed; timing it rebuilds the box's one infra stack (`down --rmi all`) | devops-guide 5.1 |
| 1.1 | cnf for a new estate: ~65 estate values in 1435 lines, 9 terraform name validations, no template | operator | 54 s to render + validate every step | **2-4 h** | estimate; the edit count is measured | 072 4.3 rows 3-5; research 03 1.3; research 04 1.1 |
| 2.1 | `do_gcp_000_bootstrap_gcp_env` dev (gcp-001..004) | **owner** go | **<= 4 min 27 s** per env, up to 220 s of it gcp-002's key-policy wait | 5 min | measured n=1: dev project `createTime` 17:32:06Z, prd 17:36:33Z (2026-09-17), so dev's 002..004 and prd's 001 fit in 4 min 27 s | `gcloud projects describe`; research 02 B6 |
| 2.2 | the same for prd (and `bkp`, `all` when the estate keeps an off-project backup or a satellite) | **owner** go | <= 4.5 min each | 5 min each | as 2.1 | devops-guide 3.3-3.5 |
| 3.1 | terraform 000 + 001, dev then prd | **owner** go | 001 apply 30-37 s per env, plus init + plan per step (3.5) | read 2 plans | measured n=2 (001) | tf_apply logs |
| 3.2 | **025 DNS zone, prd then dev, then the NS delegation at the registrar** | **owner**: registrar login | apply 2 s per env; delegation propagates in minutes to hours (the registrar's TTL) | 10-15 min | apply measured n=2; propagation estimate | tf_apply logs; spec 007 1.2 ("NS handoff happened out of band") |
| 3.3 | 005 domain verification per env: token, cnf edit, re-render, apply, then `VERIFY=1` | operator, **owner** go | apply 2 s per env; Google verifies within minutes once the record resolves | 15 min | apply measured n=2; verify wait estimate | `spl-domain-verify.func.sh` header |
| 3.4 | **040 Cloud SQL Postgres**, dev then prd | **owner** go | **14 min 23 s dev, 13 min 33 s prd** | read 2 plans | **measured n=2**: CREATE 17:57:20 -> 18:11:42Z dev, 19:23:24 -> 19:36:56Z prd (2026-09-18) | Cloud SQL operation log |
| 3.5 | the other shared steps (016, 017, 019, 028, 045, 046, 050, 051, 052, 054, 055, 056, 057, 070, 120): 15 steps x 2 envs | **owner** go (one per sweep) | each apply 1-14 s; the cost is init + plan + apply in the container per step and env: **~25-50 min** for 30 runs | read the sweep log | applies measured n=2 per step; the per-run overhead (~45-90 s) is an estimate, no log times it | tf_apply logs; devops-guide 5.7-5.8 |
| 4.1 | seven secret seeds per env (auth, auth-idp, mail, payment, wui-key, search, release-note bans) | operator; the **owner** supplies the IdP client secret, the SMTP password and the payment key | seconds each | 30-60 min, mostly collecting values from vendor consoles | estimate | 072 4.3 row 10; research 09 B6 |
| 4.2 | `do_spl_db_bootstrap` dev, then prd | operator, **owner** go | ~1 min per env; `spool migrate` of every file is 2.1 s | 2 min | migrate measured n=2; the rest estimate | research 07 1.1; devops-guide 6.1-6.2 |
| 5.1 | GitHub: the deploy key secret (step 120, in 3.5), `do_gh_set_ci_vars`, runners or `ubuntu-latest` | operator | seconds | 15-30 min | estimate | 072 4.3 rows 11, 13; devops-guide 14 |
| 5.2 | **030 Cloud Run hub, the first create** | **owner**: a decision | apply 12 s per env once it runs | unknown | **blocked** by gap D3: the first `make do-provision` of 030 returns 1 while no service exists | devops-guide 17 D3 |
| 5.3 | hub image build + mint + roll, dev and prd (wf 20, or `do_deploy_hub` from the box) | wait | **median 469 s** (min 318, max 502) for both envs | 0 | measured n=20 | research 05 1.1 |
| 5.4 | 032 hub domain mapping and its managed certificate, per env | **owner** go, then wait | **16 min 37 s dev, 10 min 36 s prd**, mapping to `CertificateProvisioned` | 0 | **measured n=2**: 14:15:25 -> 14:32:02Z dev, 14:45:20 -> 14:55:56Z prd (2026-09-19) | domain-mappings list |
| 6.1 | WUI generate + Firebase deploy, both envs (wf 30 or `do_deploy_wui`) | wait | **median 120-143.5 s** | 0 | measured n=60 and n=20 | research 06 1.1; research 20 1.1 |
| 6.2 | the WUI custom domain on Firebase Hosting: its certificate | wait | **10-60 min** per host | 0 | measured n=3 (range only) | research 06 W7 |
| 7.1 | first tenant: `do_spl_tenant_create` (or the paid checkout, 11 s), then the owner invite (`do_spl_hub_invite`) | operator, **owner** go on prd | seconds; team setup is 4.2 s of hub work | 10 min | measured n=1 | 047 1.4; research 13 1.2 |
| 7.2 | the tenant host: `do_spl_tenant_host_provision` (cnf commit, 052 + 019 + 025 apply, the Firebase certificate, a WUI redeploy for its CSP) | operator, **owner** go | ~30 min, the certificate | 15 min | estimate from the code's own header (~30 min) and 6.2 | research 13 1.2 T-c |
| 7.3 | the box-wui pin, then the first agent seated and posting in #lobby | operator | ~2-3 min | 5 min | measured n=1 (~3 min, 6 failed tries unscripted) | 047 1.4 |

## 3. The critical path

What a new estate waits on, in order. Everything not on this line can run
beside it.

1. **0.1 prerequisites** (owner). A new billing account or domain is the
   longest wait of the whole estate, and it is calendar time, not work.
2. **1.1 cnf** (2-4 h of operator work). Nothing renders before it.
3. **2.1 gcp-000 dev** (owner go, <= 4.5 min).
4. **3.1 terraform 000, 001** (the state bucket and the APIs, ~5 min with init).
5. **3.4 Cloud SQL dev** (14 min 23 s) -> **4.2 db bootstrap dev** (~1 min).
   The secrets of 4.1 must be in place before the hub starts.
6. **5.2 the first 030 create (gap D3)** -> **5.3 hub image and roll**.
7. **3.2 DNS delegation** propagated and **3.3 verification** passed, before
   **5.4 the hub domain mapping** (16 min 37 s on dev).
8. Prd repeats 2.1 -> 5.4 behind dev. The dev-leads-prd rule (devops-guide
   5.3, `do_check_dev_leads_prd`) refuses a prd apply while dev has pending
   changes for that step, so the two envs run in series. The prd chain is a
   little shorter (13 min 33 s SQL, 10 min 36 s certificate).
9. **7.1-7.3 the first tenant**, whose ~30 min is again a certificate.

Off the path: 0.2 and 0.3 (box, minutes, while 1.1 is edited), 3.5 (the
bucket and IAM steps; "one run per env + step" in principle lets a different
step run beside the SQL create, untried), 5.1, and 6.1-6.2 (the WUI
certificate can start once 019 and the zone exist, and finish while the hub
is built).

## 4. The baseline

| measure | today | how |
|---|---|---|
| machine and clock time on the critical path | **~2 h 30 min - 3 h 30 min** | two SQL creates (28 min), two hub certificates (27 min), the hub deploy (8 min), gcp-000 x 2 (9 min), terraform overhead (25-50 min), the WUI and tenant certificates where they do not overlap (30-60 min), DNS propagation (est. 10-30 min) |
| operator work | **~4-7 h** | cnf 2-4 h, secrets 0.5-1 h, reading plans and guides ~1 h, GitHub and tenant ~0.5 h |
| owner work | **~1.5-2.5 h of hands**, plus **10-15 separate gos** | prerequisites 1-2 h and the registrar 15 min; the gos: gcp-000 x 2 (x 4 with `bkp` and `all`), the terraform runs (000/001, 025, the shared sweep, 030, 032) per env, the db bootstraps, the prd tenant |
| **end to end, someone who knows this repo, owner reachable** | **one working day (~7-9 h)** | the operator edits and reads while the clocks run, so the two lines above overlap |
| end to end, a first-timer | **2-3 days** (047's figure stands, now as an upper estimate) | adds learning the guides, the D3 blocker and the owner round trips |
| the first build of this estate, for comparison | **~21.5 h calendar** from the empty projects (2026-09-17 17:32Z) to the prd hub certificate (2026-09-19 14:55Z); the dev hub service existed at 18:55Z on 2026-09-18 | the `createTime` of the projects, the Cloud Run services and the domain mappings. It **includes writing the code** the steps run, so it is an upper bound, not a baseline |

**The steps that need the owner's own hands, from section 2:** 0.1, 2.1, 2.2,
3.2 (the registrar), the IdP, SMTP and payment values of 4.1, and the decision
on 5.2 (D3). Every terraform apply also waits for the owner's go, but those
are approvals, not work.

## 5. What would cut it most

Ranked by hours removed from the "knows the repo" baseline. Each is already an
action in 072 section 5 or a gap in devops-guide section 17; this file only
adds the measured weight.

| rank | change | removes | where it is tracked |
|---|---|---|---|
| 1 | a blank cnf template with derived names (48 of the ~65 values derive from org, app and env) | ~1.5-3 h of operator work | 072 A7; research 04 |
| 2 | close gap D3: let the first 030 create pass the regress guard | the only hard blocker on the path, and an owner round trip | devops-guide 17 D3 |
| 3 | one `do_spl_estate_up ENV=<env>` that runs the legal order (gap D2) and starts the WUI and tenant certificates first | ~20-40 min of serial waiting; ~5 owner gos folded into one per env | 072 A9; devops-guide 17 D2 |
| 4 | a secret preflight that names every empty slot before 030 | a failed first roll and its diagnosis | research 09 B6 |
| 5 | the timed clean-room run: replace every **estimate** in section 2 with a median and an n | nothing directly; it turns this baseline into a measurement | 072 A16; research 20 |

## 6. Not measured here, and why

- gcp-000 per step, terraform init + plan overhead, and `make do-setup-app-inf`:
  no log keeps their times. Measuring them means running them, which is a GCP
  mutation (gcp-000, an apply) or a rebuild of the box's one infra stack.
- DNS propagation and the Google domain verification wait depend on the
  registrar, and were done out of band on the first build (spec 007 1.2).
- The first 030 create: it has never run through the make path (D3); the
  first build predates the regress guard.

072 A16's clean-room estate closes all three; it needs the owner's one
throwaway project.
