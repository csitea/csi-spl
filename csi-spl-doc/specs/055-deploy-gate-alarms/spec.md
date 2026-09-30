# 055 — Deploy-gate alarms to #spool-hub-ops (SPL-1254, SPL-1255)

Part of epic SPL-1250 "deploy-gate prevention". The prevention half (the one
pre-push command SPL-1251, the per-worktree pre-push hook SPL-1252, the spawn
footer SPL-1253) stops a break at the lane that wrote it. This half is the
*alerting* backstop: when a deploy lags anyway, or a deploy workflow fails, a
human sees it in #spool-hub-ops without watching the Actions tab.

Both alarms POST to the spool hub channel **#spool-hub-ops** (a channel in the
product, not Slack). Posting is `do_spl_desk_post` — it signs a `spool send
--channel` envelope with an on-disk **desk** identity. There is no CI posting
identity yet; provisioning one is the single owner-go blocker (§4).

## 1. SPL-1254 — deploy-lag alarm every 10 min

**Signal.** `do_check_deploy_lag` (csi-spl-orc) reads what each env publishes
about itself (hub `/version`, WUI `/build.json`) and compares the served commit
to trunk. No GCP identity needed. Per component (hub, wui) it prints one line and
returns the worst verdict: `0` current/pending (within grace), `1` unknown
(endpoint unreachable / junk), `3` lagging (inputs changed and grace passed).

**Cadence.** Every 10 min. GitHub's `schedule:` is best-effort — csi-rel measured
~100 min real gaps on a declared 10 — so:
- **Primary:** a `05_deploy-lag-alarm.yml` on `cron: '*/10 * * * *'` (accepting
  that real cadence is coarser).
- **Fallback (real 10 min):** a box cron in the `csi-spl-desk-cron` worktree
  that runs the same orc action and posts through the on-box desk. The box cron
  is what actually guarantees the interval; the GitHub schedule is the version
  that survives the box being down.

**Alarm, once per episode.** On rc 3 for an env+component, post ONE `blocker`
naming the env, component, served vs trunk commit, age and grace, and the
`/version`|`/build.json` URL. Do NOT re-post every 10 min while it stays lagging.

**Recovery.** When a previously-lagging env+component returns rc 0, post ONE
`note` that it recovered.

**Dedup across stateless runs.** A CI runner keeps no state between runs, so the
"once per episode" and "recovery" edges need external state keyed by
`env+component`:
- **Box cron:** a state file under the desk-cron worktree
  (`~/.cache/csi-spl/deploy-lag-alarm.state`): last posted verdict per key; post
  only on a verdict *edge* (ok→lag, lag→ok).
- **GitHub:** the `actions/cache` keyed on `deploy-lag-<env>-<component>` holding
  the last verdict, restored at the top of the run and saved at the end. A cache
  miss is treated as "ok" so the first lagging run posts.

Only one of the two posters should be armed at a time (the box cron preferred);
the GitHub schedule stays a warm standby that a human enables if the box is down,
so the channel is never double-posted.

## 2. SPL-1255 — post on a workflow 20/30 failure

**Trigger.** `on: workflow_run:` for `20 ci-cd: spool hub build + deploy` and
`30 ci-cd: spool wui build + deploy`, `types: [completed]`, guarded by
`if: github.event.workflow_run.conclusion == 'failure'`.

**Post.** One `blocker` to #spool-hub-ops with: the run link
(`workflow_run.html_url`), the failing job/step (read via the REST API
`GET /repos/{repo}/actions/runs/{id}/jobs`, pick the first step with
`conclusion == failure`), the breaking commit (`head_sha` + first line of
`head_commit.message`), and the **agent id from its message** — parsed from the
breaking commit's trailer/subject (our commits carry `CLE-…`/`GRK-…`/`SPL-…`
tags), falling back to the commit author.

Same posting path as SPL-1254 (`do_spl_desk_post`, kind `blocker`). No dedup
needed — one post per failed run.

## 3. Posting helper

A thin orc action `do_spl_ops_alarm` wraps `do_spl_desk_post` with the ops-desk
defaults (ENV, TENANT_ID, DESK_AGENT, DESK_BOX, DESK_CHANNEL=spool-hub-ops) read
from env, so both workflows and the box cron call one thing. It is DRY_RUN=1 by
default (prints what it would post) and only sends with DRY_RUN=0 and a seated
desk present — so it lands green and inert before the identity exists, exactly as
20 / 00 skip an env with no key.

## 4. Owner-go — the CI posting identity (the one blocker)

`do_spl_desk_post` needs a seated desk (keys on disk) whose box key the hub
trusts, and the agent must be a member of #spool-hub-ops. None exists for CI.
Provisioning mutates prd and mints a key/secret → owner-go:

1. **Seat the ops desk** (mints the box key, hub-pins it):
   `ENV=prd TENANT_ID=<t> DESK_AGENT=<CI-BOT-ID> DESK_BOX=box-ci DRY_RUN=0 ./csi-spl-orc/run -a do_spl_desk_up`
2. **Add `<CI-BOT-ID>` to #spool-hub-ops** in the WUI (channel → Agents), or the
   hub returns `unknown_channel`.
3. **For the GitHub poster only:** publish the `box-ci` desk key as a new repo
   secret (a new secret = owner-go) so the runner can sign. The box cron reads
   the key from the on-box desk dir and needs no secret.

The box-cron poster (no new secret) is the lighter path; the GitHub poster is the
survives-box-down path and is the only one that needs the secret. Recommend
arming the box cron first.

## 5. Coordination

New files only: `05_deploy-lag-alarm.yml`, `25_deploy-failure-alert.yml`, the
`do_spl_ops_alarm` action, and the box-cron entry. `00_deploy-lag-watch.yml`
(hourly reconcile) is left as-is — the workflow-hardening lanes touch it, this
work does not.
