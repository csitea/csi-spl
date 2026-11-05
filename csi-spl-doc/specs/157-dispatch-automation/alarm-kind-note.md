# Automatic alarms are notes, never blockers (SPL-4869)

- **Spec**: `157-dispatch-automation`, epic `SPL-2398`
- **Design**: [rca-blocker-issues-from-agent.md](rca-blocker-issues-from-agent.md) section 3, Option A1.3 (owner answer 1: A, t1 `8c64225e` msg `70d39d81`)
- **Issue**: `SPL-4869`

## 1. The rule

An alarm that a cron, the watchdog or the dispatcher's own checks send
automatically goes out as `--kind note`, never `--kind blocker`. The hub's
`SweepBlockerIssues` files every `kind = 'blocker'` message that gets no reply
in its topic within 3 minutes as a `todo` issue under `SPL-2394`. Nobody
answers an alarm in its topic, so each one became an issue that never closed
(88 of the 96 the RCA counted).

An alarm sent `--to orchestrator` also passes `--ask blocker`
(`spool-send.sh`). It is still journaled under `$SPOOL_ROOT/asks/<msg id>.json`
and re-raised until the orchestrator acks and closes it, exactly as the old
blocker was. A plain `--kind note` to the orchestrator journals no ask.

## 2. The senders

| sender | to | now |
|---|---|---|
| watchdog S2 login, S2 limit, held out (`spl-watchdog.func.sh`, `spl_wd_send ... alarm`) | orchestrator | note + `--ask blocker` |
| watchdog S2 auth (`spl-watchdog.func.sh`), orchestrator outcome (`spl-wd-orch-outcome.func.sh`) | dispatch holder, else orchestrator | note; + `--ask blocker` only on the orchestrator fallback |
| restart report (`spl-agent-restart.func.sh`, `spl_ars_send ... alarm`, its resend queue too) | orchestrator | note + `--ask blocker` |
| takeover job (`spl-wd-takeover.func.sh`), peer watchdog (`spl-wd-peers.func.sh`, `wd-box-*`), watchdog keeper (`spl-wd-ensure.func.sh`, `wd-keeper-*`) | orchestrator | note + `--ask blocker` |
| issue closer red (`scripts/issue-close-landed-cron.sh`) | orchestrator | note + `--ask blocker` |
| epic stall (`spl-epic-stall-check.func.sh`), work group stall (`spl-spawn-group-put.func.sh`) | dispatch holder | note (never an ask: `spl_spawn_q_send` passes `--no-ask`) |
| spawn share and supply lead (`spl-spawn-place.func.sh`, `spawn-share`) | dispatch holder | note |
| asks re-raise (`spl-asks-tick.func.sh`, `asks-open`) | the holder and the DO seats | note (never an ask) |
| push orphan (`spl-push-orphan-check.func.sh`) | dispatch holder | note |

`alarm` is a kind only `spl_wd_send` and `spl_ars_send` take: they send it as
`--kind note`, adding `--ask blocker` when the recipient is `orchestrator`.

## 3. What stays a blocker

Still `--kind blocker` in `csi-spl-orc`, outside this change (none is in the
RCA's list):

- `desk-reconcile-cron.sh` and `spl-spawn-place.func.sh` (`spawn-queue`): sent
  by a seat to itself, so the hub assigns no one and files no issue.
- `restore-mistral.sh` (NO-BRIEF), `spl-workspace-seat-alarm.func.sh`,
  `spl-workspace-delivery-probe.func.sh`, `spl-archived-seats-free.func.sh`,
  `spl-hub-member-access-schedule-check.func.sh`: each asks a person or a
  seat to act on one case; whether it is an alarm is a separate decision.
- `DESK_KIND=blocker` posts (`spl-asks-tick.func.sh` owner fallback,
  `spl-deploy-failure-post.func.sh`, `spl-deploy-lag-alarm.func.sh`): desk
  channel posts, not spool messages to a seat.

## 4. Tests

- `csi-spl-orc/src/bash/tests/alarm-kind-note.tst.sh`: each send helper (or
  the site) through the real `spool-send.sh` on a sandbox root
  (`alarm-real-send.inc.sh`): the message that lands is a note, the
  orchestrator ones journal ONE blocker ask, the others none. Red controls:
  the old `blocker` call lands a blocker; a plain note journals no ask. On an
  `origin/master` tree the test fails 9 of 11.
- The site tests assert the argv: `wd-situations`, `wd-human-window`,
  `wd-orch-outcome`, `wd-takeover`, `wd-ensure`, `wd-peer-restart`,
  `agent-restart`, `spl-issue-close-landed`, `spl-epic-stall-check`,
  `spl-spawn-group`, `spl-spawn-queue`, `spl-spawn-place-supply`,
  `spl-push-orphan-check`.
