# 072 research 04: cnf and estate literals

Contributor: c-168. Tree: `origin/master` @ `474b940a8`, 2026-10-04. n = 1 per
command. Docs only: this file builds nothing. It feeds 072 gaps **G8**, **G9**
and **G13**, and actions **A7**, **A8** and **A12**.

No estate value of ours appears below. Every command reads the value from the
cnf, so it runs on any estate and passes the single-source gates. Run this
preamble first, from the repo root:

```bash
C=csi-spl-cnf/csi-spl; D=$(yq .env.dns.BASE_DOMAIN $C/all.env.yaml); O=$(yq .env.gcp.gcp_org_id $C/all.env.yaml); E=$(yq .env.gcp.gcp_account_owner_email $C/all.env.yaml); R=$(yq '.env.steps."017-github-wif-deploy".github_repository' $C/prd.env.yaml)
```

Placeholders: `<domain>`, `<org>`, `<app>`, `<env>`, `<owner>/<repo>`.

## 1. Today

### 1.1 The cnf: its size, and how much of it names our estate

| measure | value | command |
|---|---|---|
| hand-written leaves (scalars and list items, comments excluded) | all 191, dev 177, prd 234 | `yq -o=props $C/<f>.env.yaml \| grep -vc '^#'` |
| effective leaves after the merge | dev 342, prd 402 | `yq eval-all '. as $i ireduce ({}; . * $i)' $C/all.env.yaml $C/prd.env.yaml \| yq -o=props \| grep -vc '^#'` |
| effective leaves that name our estate (org, app, project, bucket, SA, domain, repo, mail, region, org id, owner) | dev 53, prd 65 | the same props, filtered by the patterns in 1.3 (script in 1.4) |
| ... of those, a pure function of `ORG`, `APP`, `ENV` and region | dev 37, prd 48 | the same script, pattern `^<org>-<app>(-<env>\|-all\|-bkp)?(-<suffix>)?$` and `<project>@<project>.iam...` |
| keys set in BOTH dev and prd files with the **same value** (they could live once, in `all`) | 96 of 132 | a python diff of the two `-o=props` files (1.4) |
| keys in both whose values differ **only by the env token** | 19, 18 of them estate names | the same diff |
| lines in dev + prd naming a project id (comments excluded) | 30 | `cat $C/dev.env.yaml $C/prd.env.yaml \| grep -vE '^\s*#' \| grep -cE 'csi-spl-(dev\|prd)'` |

A newcomer sees 402 effective prd values, but **only 8 of them hold a fact
about their own estate** (section 3). Every other value is either a setting
with a working default, or a name the cnf could derive.

### 1.2 What the cnf already derives (the precedent)

`do_spl_merged_cnf` (`csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh:29-50`)
already derives `env.dns.fqdn`, `env.dns.api_fqdn`, `hub.image.ref`,
`SPOOL_HUB_ENV`, `SPOOL_HUB_FILES_BUCKET` and `SPOOL_HUB_TENANT_HOST_PATTERN`.
It also expands the tokens `{fqdn}`, `{base_domain}` and `{api_fqdn}` inside
values. `do_tpl_gen` renders from that merge (`tpl-gen.func.sh:44`). The
conf-validator already **requires** a derivation that nothing performs:
`EnvModels/cloud.py:64` (`gcp_project` must equal `{ORG_APP}-{ENV}`) and `:66`
(`state_bucket` must equal `{gcp_project}-tfstate`). The rule is checked, but
each env file still writes the values out by hand.

### 1.3 The literal classes across the tree

`tree` = `git grep -l` over the whole tree. `code` = the same, excluding
`csi-spl-cnf`, `csi-spl-doc` and `*.md`.

| class | cnf yaml lines | tree files | code files | pattern |
|---|---|---|---|---|
| product domain | 10 | 88 | **0** | `"$D"` (gated: `domain-single-source.tst.sh`) |
| GCP org id | 1 | 3 | **0** | `"$O"` (gated: `gcloud-account-pinned.tst.sh`) |
| owner account | 1 | 3 | **0** | `"$E"` (gated by the same test and the hygiene sweep) |
| mail domain | 2 per env | 14 | 2 (both `<<run-time>>` placeholders) | `"@${M#*@}"` with `M=$(yq .env.mail.env.SPOOL_HUB_MAIL_FROM $C/prd.env.yaml)` |
| GitHub repo | 4 | 396 | 373 (363 are Go import paths) | `"$R"`; `git grep -hE "$R" -- '*.go' '*.mod' \| wc -l` -> 889 lines |
| region | 3 | 83 | 26 | `europe-north1` |
| project ids | 52 | 180 | 71 | `'\bcsi-spl-(dev\|prd\|bkp)\b'` |
| SA emails | 4 | 60 | 41 | `'iam\.gserviceaccount\.com'` |
| `<org>-<app>-` prefix | 130 | 867 | 541 | `'\bcsi-spl-'` (mostly the repo's own dir names, not estate) |
| default hosts (`web.app`, `run.app`) | 1 | 15 | 5 (all built from `${SITE}` or a placeholder) | `'\.web\.app\|firebaseapp\.com\|\.run\.app'` |

The three values that could embarrass or bind a fork (the domain, the org id
and the owner) are **already single-sourced and gated**. The newcomer's cost
comes from two other places: derivable names that are written out by hand, and
code that accepts only our names.

### 1.4 Reproduce 1.1

```bash
for e in dev prd; do yq eval-all '. as $i ireduce ({}; . * $i)' $C/all.env.yaml $C/$e.env.yaml | yq -o=props | grep -v '^#' > /tmp/$e.leaves; yq -o=props $C/$e.env.yaml | grep -v '^#' > /tmp/$e.own; done; wc -l /tmp/*.leaves /tmp/*.own
```

The diff and the derivable filter are 25 lines of python over those four
files. The script splits each line on ` = `, compares dev with prd, and matches
each value against the estate patterns in 1.3.

## 2. Blockers

Each blocker makes a newcomer edit something that is not their own estate data.

1. **The derivable names are written out by hand, once per env.** 48 prd and
   37 dev values have the form `{org}-{app}-{env}-<suffix>`. They cover the
   state bucket, the relay bucket and its SA, the site id, the AR repo, the SQL
   instance, the backup and files buckets, the deploy SAs, and the hub service
   and runtime SA. Examples: `$C/prd.env.yaml:37` (`gcp_project`), `:39`
   (`state_bucket`), `$C/dev.env.yaml:236` (`writer_service_account`). A new
   estate rewrites every one by hand, in each env file.
2. **14 secret slot ids carry the org-app prefix** (`csi-spl-hub-*`).
   `yq -o=props $C/all.env.yaml | grep -v '^#' | grep -c ' = csi-spl-hub-'`
   -> 14. These are derivable too: `{org_app}-hub-<name>`.
3. **Host values that follow from the domain are written as literals.**
   `SPOOL_HUB_VIEW_CORS_ORIGINS`, `SPOOL_HUB_PAYMENT_CLAIM_URL`,
   `SPOOL_HUB_OPERATOR_AUDIENCE` and `SPOOL_HUB_OPERATOR_EMAILS`
   (`$C/dev.env.yaml:275,308,314,315`; prd has the same keys) spell out the env
   host and the SA. The domain gate does not catch them because they live in
   the cnf, where the gate allows the domain.
4. **One fact, two keys.** Each env sets the GitHub repo twice:
   `steps.017-github-wif-deploy.github_repository` (`$C/dev.env.yaml:104`) and
   `steps.120-github-general-secrets.gh_repo` (`:260`). The SMTP user and the
   From address name the same mailbox (`:385,386`).
5. **96 identical dev/prd keys.** Every change to one of these settings must be
   made twice. A newcomer reading two 400-line files cannot tell which
   differences matter: only 36 do (19 by env token, 17 otherwise).
6. **Estate-only data sits beside template data, unmarked.** This covers our
   tenant slugs (`env.dns.mapped_tenants`, `$C/dev.env.yaml:25`), our domain
   verification token (step 005, `:82`), the off-project backup project (046,
   `:233`), and the satellite VM (059 and 060, prd only). Together they are 52
   prd leaves:
   `... | grep -cE '^env\.(steps\.(005|046|059|060)-|dns\.mapped_tenants)'` -> 52.
   A newcomer has to guess which of them to delete. (072 G13, A12.)
7. **The validator knows only `dev` and `prd`** (`Classes/EnvEnum.py:6-7`). Any
   other env name fails validation before tpl-gen runs (072 4.3 #5).
8. **ORG and APP come from the directory name, not from the cnf**
   (`csi-spl-iac/lib/bash/funcs/resolve-oap.func.sh:13`). The cnf repeats them
   (`$C/dev.env.yaml:10-12`), so a clone under any other directory name
   disagrees with its own cnf. (072 A8.)
9. **Code outside the cnf that pins our estate.** This list excludes the 9
   terraform `regex("^csi-spl` validations, which 072 A8 already counts.
   - The region is a terraform **default** in 15 steps:
     `git grep -lE 'default\s*=\s*"europe-north1"' -- csi-spl-iac/src/terraform | wc -l` -> 15
     (for example `000-gcp-remote-bucket/02-variables.tf:29`). It is also
     hard-coded in `gcp-bkp-state-bucket-create.func.sh:36` and
     `sec-scan.func.sh:324`.
   - The key path is written with our org dir and project ids in
     `.github/workflows/40_tenant-host-reconcile.yml:115,117` and
     `satellite-verify.func.sh:66,74`. 18 other files already build it from `$ORG`.
   - `csi-spl-wui/firebase.json:84-85` is a committed render that names the dev
     hub service and region. `render-wui-firebase-json.sh` renders it again at
     deploy, so this is a stale-file trap, not a runtime pin.
10. **No minimal file, and no message that names what is missing.** The
   validator models (`EnvModels/cloud.py`) type the shape but have no "estate"
   section. An empty or placeholder value therefore surfaces later, as a tfvars
   or `gcloud` error, instead of as "set `<key>` in the estate file".

## 3. The minimal config a newcomer fills in

This classification covers the 65 estate values of 1.1 and the 15
`PLACEHOLDER-*` values in `all.env.yaml`. **Must-set** means no value works for
someone else. **Default-able** means a value works out of the box, or can be
derived.

### 3.1 Must-set: 8 answers (the proposed `estate.yaml`)

| # | key | today, where | why it cannot default |
|---|---|---|---|
| 1 | `org` | `ORG` in each env file, and the dir name | it names every resource and the key dir |
| 2 | `app` (default `spl`) | `APP`, and the dir name | the same; the default is safe |
| 3 | `base_domain` | `env.dns.BASE_DOMAIN` | it is theirs |
| 4 | `github_repository` (`<owner>/<repo>`) | 017 and 120, twice per env | WIF trust and secret publishing are bound to it |
| 5 | `bootstrap_account` | `env.gcp.gcp_account_owner_email` | the human who runs gcp-000..004 once |
| 6 | `gcp_org_id` or `gcp_folder_id`, **or none** (072 A10) | `env.gcp.gcp_org_id` | their org; "none" should be a valid answer |
| 7 | `mail.from` (plus `smtp_host`, `smtp_port`) | `SPOOL_HUB_MAIL_FROM`, `_SMTP_USER`, `_SMTP_HOST` | their mailbox; `transport: none` is a valid answer |
| 8 | `envs` (default `[dev, prd]`) | the file names, and `EnvEnum.py` | the names are theirs; the default is safe |

The billing account stays an **environment variable that fails fast**
(`GCP_BILLING_ACCOUNT_ID`). It is never a cnf value (repo CLAUDE.md).

### 3.2 Default-able: everything else

| group | count (prd) | how it defaults |
|---|---|---|
| resource names (projects, buckets, SAs, site, AR repo, SQL, service) | 48 | derived as `{org}-{app}-{env}[-<suffix>]`, the validator's own rule |
| secret slot ids | 14 | derived as `{org}-{app}-hub-<name>` |
| hosts that follow the domain (CORS, claim URL, audience, cookie) | 6 | derived from `{fqdn}`, `{api_fqdn}` and `{base_domain}` |
| region | 2 (plus 15 tf defaults) | one cnf default, `region:`; the tf defaults are removed |
| env subdomain | 1 per env | the env name, except the last env in `envs`, which serves the apex |
| IdP client ids, Stripe keys | 15 `PLACEHOLDER-*` | off until set; the hub already fails fast when a listed provider has a placeholder |
| our estate only: mapped tenants, step 005 records, 046 bkp project, 059/060 satellite | 52 | **off** in the template; ours stays in our env file (072 A12) |
| hub, auth, i18n, payment and box settings | the rest | already defaulted in `all.env.yaml`; unchanged |

## 4. Actions

Cost: these actions change files only. **No GCP spend** (0 resources,
0 EUR/month). Effort is per lane: XS < 0.5 day, S <= 1 day, M 2-5 days. Ranked
by the 072 rule: the actions that cut the most values a newcomer types come
first.

| # | action | changes | effort | done when (a test can check it) |
|---|---|---|---|---|
| **C1** | Derive the resource names. `do_spl_merged_cnf` expands `{org}`, `{app}`, `{org_app}`, `{env}`, `{project}` and `{region}` (beside the existing `{fqdn}`), and gives each derivable key a default. The env files drop those 48 values | A7 prerequisite, G8 | M | `ENV=dev ./run -a do_tpl_gen && ENV=prd ./run -a do_tpl_gen && git diff --exit-code csi-spl-cnf/csi-spl/*/tf` exits 0 (**byte-identical** renders), and the 1.1 project-id line count falls from 30 to <= 4 |
| **C2** | Derive the 14 secret slot ids as `{org_app}-hub-<name>` | G8 | S | renders byte-identical; the blocker 2 command -> 0 |
| **C3** | Derive the 6 host-shaped hub values from `{fqdn}` / `{api_fqdn}` / `{base_domain}`, and the SA from `{project}` | G8 | S | renders byte-identical; `grep -vE '^\s*#' $C/dev.env.yaml $C/prd.env.yaml \| grep -cF "$D"` -> only the step 005 record lines |
| **C4** | One key per fact: `github_repository` once (017 and 120 read it), `mail.from` once (the SMTP user defaults to it) | G8 | XS | renders byte-identical; `grep -hcE 'gh_repo:\|github_repository:' $C/*.env.yaml \| paste -sd+ \| bc` -> 1 |
| **C5** | Move the 96 identical dev/prd keys into `all.env.yaml` | G8 | S | renders byte-identical; the 1.4 diff prints `identical: 0` |
| **C6** | `csi-spl-cnf/template/estate.yaml` with the 8 keys of 3.1 and comments, plus an `Estate` model in the conf-validator whose error names the key and the file ("set `base_domain` in estate.yaml") | A7 | S | the validator on the blank template exits non-zero and prints each of the 8 key names; on a filled sample it exits 0 |
| **C7** | `do_spl_cnf_init` reads `estate.yaml` and writes `all` plus one env file per `envs` entry, with the estate-only steps of 3.2 off | A7 | M | with a sample `estate.yaml` (`org=acme`, `base_domain=example.com`), `do_tpl_gen` renders every step for each env, `grep -rlF "$D" <out>/` -> 0 files and `grep -rlE 'csi-spl-' <out>/*/tf` -> 0 files |
| **C8** | Env names from the cnf: `EnvEnum.py` builds its model list from the env files present, not from a fixed `dev`/`prd` | G9 (072 4.3 #5) | S | a copied `stg.env.yaml` (dev with `ENV: stg`) passes the validator and `ENV=stg ./run -a do_tpl_gen` |
| **C9** | Remove the region and key-dir literals from code: drop the region `default` in the 15 tf steps (tfvars always set it), read `GCP_REGION` from the cnf in the 2 bash actions, and build the key path from `$ORG`/`$APP` in the 2 workflow lines and `satellite-verify` | G9 | S | `git grep -lE 'europe-north1' -- csi-spl-iac/src csi-spl-orc/src .github \| grep -v 060-gcp-vm-satellite \| wc -l` -> 0; `git grep -nE '\.gcp/\.csi/key-csi' -- .github csi-spl-iac/src/bash/run \| wc -l` -> 0 |
| **C10** | Gate it: add `cnf-estate-single-source.tst.sh` to iac. It generalises `domain-single-source.tst.sh` to the org-app prefix, the region, the repo and the mail domain: each may appear only in `estate.yaml` (or our env file) and in derived output | keeps C1-C9 | S | the test is green on the result; a control that adds a project id literal to a step's `02-variables.tf` turns it red (on a throwaway branch) |

**Order.** C4 and C5 first (no new mechanism, they remove noise), then C1, C2
and C3 (the derivation), then C6 and C8, then C7, then C9 and C10. C1-C5 must
keep the rendered tfvars byte-identical, so each one lands with **zero infra
change**: no plan diff, no apply, no owner go needed. C7 depends on 072 A8 (the
9 regex validations) and A12 (optional steps).

**Result for a newcomer:** today they rewrite ~65 estate values spread across
1435 lines (072 4.3 #3). After C1-C7 they type **8 answers**, 2 of which have
defaults.

### 4.1 Top 3

1. **C1**: derive the 48 resource names from org, app and env. It is the
   biggest cut in values typed, and a byte-identical render proves it safe.
2. **C6**: the 8-key `estate.yaml`, with a validator that names each missing
   key. This is the newcomer's whole edit, and its errors say what to do.
3. **C3**: derive the host-shaped values from the domain. A domain change
   becomes a one-line edit again, as the domain gate intended.

## 5. Questions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Should our live env files switch to the derived form (C1-C5), or stay literal, with derivation used only in the template? | **switch**: one code path, proven safe by the byte-identical render; a literal still wins, so nothing is forced |
| Q2 | Which default region should the template use? | **keep ours as the default**: it works, and a newcomer changes one key to move it |
| Q3 | Should our estate-only data (tenant slugs, the step 005 token, the 046 bkp project, the satellite) move to a separate overlay file, e.g. `<env>.estate.yaml`? | **no, mark it off in the template** (C7, 072 A12): an extra file costs every reader more than a flag does |
| Q4 | Should `gcp_org_id` stay committed in the cnf, now that `GCP_ORG_ID` overrides it? | **yes**: it is ours, and the repo is public by choice. The template leaves it empty (3.1 #6) |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T08:40:00Z -->
