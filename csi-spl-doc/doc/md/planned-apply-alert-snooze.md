# Planned database apply: the alert snooze (SPL-3457)

Alerts fix round row 03, part A (`alerts-fix-round-plan.md` v1.0, section 3;
owner answer to Q2: "Both"). An owner-approved apply of step
`040-cloud-sql-postgres` restarts Cloud SQL for about a minute. Every hub
loop logs one ERROR per failing call per 5 s tick while the database is gone,
so the apply paged `error_logs` (and can page `sql_down`) for a change that
was already agreed. Part B, the 600 s duration on the error-log policy, is a
later terraform 070 change.

## 1. What happens on a 040 apply

`make do-provision ENV=<env> STEP=040-cloud-sql-postgres`
(`csi-spl-orc/src/make/tf-tasks.func.mk`) now runs, around the apply in the
tf-runner:

1. before: `SNOOZE_CMD=start ./run -a do_gcp_alert_snooze` (from
   `csi-spl-iac`): one Cloud Monitoring snooze over the two 070 policies
   `<org>-<app>-<env> hub error log rate` (`error_logs`) and
   `<org>-<app>-<env> Cloud SQL down` (`sql_down`), from now until now + 60
   min. A failed or hung apply still ends it at that time.
2. the apply, unchanged.
3. after: `SNOOZE_CMD=end`: the same snooze now ends 15 min from now, so the
   hub has 15 min to recover before the alerts watch again.

No other step snoozes anything, and the other policies (health check, 5xx,
429, capacity) stay live during the apply. A snooze that cannot be created is
a WARN line and the apply goes on: the owner approved the apply, not the
snooze.

## 2. Dry run unless DRY_RUN=0

Like every gcp action, the snooze is a dry run by default: it reads the two
policies and prints the `gcloud monitoring snoozes create` it would make. To
snooze for real, run the approved apply with `DRY_RUN=0`:

`cd csi-spl-orc && DRY_RUN=0 ENV=<env> STEP=040-cloud-sql-postgres make do-provision`

`DRY_RUN` reaches only the snooze; the tf-runner apply does not read it.

## 3. The action

`csi-spl-iac/src/bash/run/gcp-alert-snooze.func.sh`, `do_gcp_alert_snooze`:

| env var | meaning | default |
|---|---|---|
| `ENV` | dev or prd | required |
| `SNOOZE_CMD` | `start` or `end` | required |
| `DRY_RUN` | 1 prints, 0 acts | 1 |
| `ALERT_SNOOZE_MAX_MIN` | the window `start` opens, minutes | 60 |
| `ALERT_SNOOZE_AFTER_MIN` | minutes the snooze lasts after `end` | 15 |
| `ALERT_SNOOZE_STATE_FILE` | where `start` keeps the snooze name for `end` | `${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/alert-snooze-<env>.name` |

- It runs as the env's project service account (`do_gcp_pin_account`) in a
  private gcloud config, `--account` on every call; never the owner account.
- `end` with no kept snooze does nothing and succeeds.
- Each policy must match exactly one display name, else it refuses (070 not
  applied, or renamed).

## 4. Unverified: the service account's permission

Whether the per-env service account holds `monitoring.snoozes.create` and
`monitoring.snoozes.update` was not checked against GCP when this landed
(the lane made no GCP call). The first `DRY_RUN=0` run answers it: a refusal
is printed as `ERROR snooze not created ... (monitoring.snoozes.create?)` and
the apply goes on unsnoozed. Report it; never work around it with the owner
account.

## 5. Test

`csi-spl-iac/src/bash/tests/gcp-alert-snooze.tst.sh`, with a stub `gcloud`:
the `make -n` plan of 040 names the start before the apply and the end after
it, the 070 plan names no snooze (control), a dry run creates nothing, and
the start, end, missing-policy, refused-create and no-key paths.
