# Secrets, security round 1: versions, key ages, compute SA, scanning alert

SPL-1967. Rows 6 and 8 of the first security round. Each one is a named
action with a dry run. Nothing changes in GCP or on GitHub until the owner
approves one `DRY_RUN=0` run.

| row | action | what it changes |
|---|---|---|
| 6 | `do_spl_secret_age_report` | nothing: a markdown report of secret versions and SA key ages |
| 6 | `do_spl_secret_version_disable_old` | disables every older enabled version of one secret, keeps the newest |
| 6 | `do_spl_compute_sa_editor_drop` | drops `roles/editor` from the env's default compute service account |
| 8 | `do_spl_secret_scan_alert_triage` | resolves one GitHub secret-scanning alert as `used_in_tests` |

All four run from `csi-spl-iac` as `./run -a <action>`. They default to a dry
run, and `DRY_RUN=0` applies. Each runs as the env's project service account
in a private gcloud config, never as the owner account. No action prints a
secret value or a real secret's hash.

## 1. Age report (row 6)

```bash
cd csi-spl-iac && ENV=prd ./run -a do_spl_secret_age_report
```

It lists every Secret Manager secret with its enabled versions (number,
create date, age) and every user-managed service account key (key id prefix,
created, age, expiry). Flags: `EMPTY` (0 enabled versions), `MULTI` (an older
version is still usable), `OVER` (older than its max age), `NO-EXPIRY`. The
max ages are cnf `env.secrets.max_age_days.secret_version` and `.sa_key`, in
days: 90 each, the owner's defaults (SPL-1945, t1 8f476aa8 msgs e8d4c60d and
018e37eb). `null` would mean not set, and then nothing of that class is
`OVER`.

## 2. Disable the old version of a secret (row 6)

```bash
cd csi-spl-iac && ENV=prd SECRET=csi-spl-hub-stripe-secret-key ./run -a do_spl_secret_version_disable_old
```

Before it changes anything, it reads the hub Cloud Run service and refuses if
the hub pins this secret to a version it would disable. The hub reads
`latest` until SPL-2251 is applied, then the cnf pin
([secret rotation](secret-rotation.md)). It never reads a value. Each disabled
version prints its undo:
`gcloud secrets versions enable <n> --secret=<secret> --project=<project>`.

## 3. Drop roles/editor from the default compute SA (row 6)

```bash
cd csi-spl-iac && ENV=dev ./run -a do_spl_compute_sa_editor_drop
```

It first measures, each as a count: Cloud Run services and jobs, VMs, Cloud
Functions and Cloud Builds running as the SA, its user-managed keys, and its
audit log rows as caller over `AUDIT_DAYS` (30). A control query must find
audit rows at all, or the log is unreadable and the run is refused. Any use
above 0 refuses. It removes that one binding and prints the
`add-iam-policy-binding` undo. It is an IAM change, so dev runs first, then
prd.

## 4. Triage a secret-scanning alert (row 8)

```bash
cd csi-spl-iac && ALERT=1 ./run -a do_spl_secret_scan_alert_triage
```

It proves the alert is a fixture in two ways:

- Every location is a test file whose line, at the alert's commit, holds the
  alert's secret verbatim.
- The alert's sha256 matches no version of any real secret whose id names the
  alert's provider, in dev and prd.

Only then does it resolve the alert as `used_in_tests`. Undo: reopen the
alert.

## 5. The session run, 2026-10-16

The owner approved each run (form 063d3ca1, rows S1-S4). All four ran with
exit 0:

| row | run | result |
|---|---|---|
| S1 | the four actions landed on master | tip `3ec830cfb` |
| S2 | prd Stripe secret key | version 1 (2026-09-19) disabled, version 2 kept; prd hub current and Ready afterwards |
| S3 | dev, then prd | `roles/editor` dropped in both after 0 uses in 30 days; both hubs Ready afterwards |
| S4 | alert 1 | resolved `used_in_tests`; matched none of 6 real versions |

Hub health after a change: an external `GET /healthz` gets the load
balancer's 404 page and never reaches the hub. Check with
`cd csi-spl-orc && ENV=<env> ./run -a do_check_hub_deploy` and
`GET https://api.<fqdn>/version` instead.
