# GCP alerts MCP server (SPL-2887)

An agent reads the Google Cloud Monitoring alert incidents of dev and prd as
two MCP tool calls, read-only. Spec 146 (reliability round), epic SPL-2364;
lane 2 of the owner's ask "for each Google Cloud Alerting send type of msg
during the last 24 hours a new topic discussion" (lane 1 adds the read action
and opens the topics).

## 1. The tools

| tool | input | runs |
|---|---|---|
| `gcp_alert_incidents` | `env` (dev or prd), `since` (`<n>m`, `<n>h` or `<n>d`, default `24h`) | `ENV=<env> SINCE=<since> ./run -a do_gcp_list_alert_incidents` |
| `gcp_alert_incident` | `env`, `policy` (display name), `opened` (`YYYY-MM-DDTHH:MMZ`), as the incident line prints them | `ENV=<env> POLICY=<policy> OPENED=<opened> ./run -a do_gcp_get_alert_incident` |

In claude they are `mcp__gcp-alerts__gcp_alert_incidents` and
`mcp__gcp-alerts__gcp_alert_incident`. The result is the action's stdout.

## 2. How it works

- The server is `spool mcp-gcp-alerts --iac <dir>`
  (`csi-spl-api/src/go/spool-hub-api/internal/gcpalerts/`, the verb in
  `cmd/spool/gcp_alerts.go`). Each call runs one named csi-spl-iac action in
  `<dir>`, the agent user's own process. It never runs gcloud and never reads
  a key: the action resolves the env's service account from its key, as every
  iac gcloud action does.
- Before it runs the action it checks that the key FILE
  `<home>/.gcp/.<org>/key-<org>-<app>-<env>.json` exists. No file: the call
  fails at once with `no service-account key for <env> at <path>` (exit 78),
  and nothing runs.
- Input is checked before that: `env` is dev or prd, `since` matches
  `^[1-9][0-9]{0,2}[mhd]$`, a `policy` is letters, digits, spaces and
  `._:/()-`, `opened` is `YYYY-MM-DDTHH:MMZ` (exit 78).
- An incident has no id: Cloud Monitoring has no public incidents API
  (`GET v3/projects/<p>/incidents` answers 404) and logs no entry per
  incident. The list action rebuilds incidents by replaying each policy's
  condition over its time series, so one incident is named by its policy
  and the minute it opened. The policy's `combiner` joins its conditions
  (SPL-3645): `OR` (or a single condition) lists each condition's runs;
  `AND` is one incident where every condition holds at the same time (the
  overlap of their runs); any other combiner is named on stderr and listed
  as `OR`.
- `do_gcp_get_alert_incident` (`csi-spl-iac/src/bash/run/gcp-get-alert-incident.func.sh`)
  replays that one policy the same way (`src/bash/scripts/alert-incident.py`
  imports lane 1's `alert-incidents.py`) over OPENED minus 2 h .. plus 24 h
  (capped at now) and prints the policy and its conditions, the incident with
  its resource and peak, and the timeline: each aligned point around it,
  marked `VIOLATES` or `ok`. Exit 3: no enabled policy of that name; exit 4:
  none of it opened at that minute (the ones that did are listed).
- Why a new server and not tools on the spool MCP: `spool-<env>` runs as the
  box user, seated per agent and per env, through a sudo hop to the desk. The
  alert tools need none of that. They run as the agent user, with its own
  per-env keys, so this is one user-scope server and `env` is an argument.

## 3. Install

As the box user, from the MAIN checkout (a lane worktree is swept 24 h after
its lane, and the wrapper points at the iac dir it was installed from):

```
cd csi-spl-orc && AGENT_USER=<agent user> ./run -a do_spl_agent_mcp_gcp_alerts_install
```

That is a dry run; add `DRY_RUN=0` to install. It builds `spool` from the
checkout into `<agent home>/.local/share/<org>-<app>/gcp-alerts-mcp/spool`,
writes the wrapper `<agent home>/.local/bin/gcp-alerts-mcp`, and registers
`gcp-alerts` in claude at user scope. Other CLIs are not registered yet. A
running claude sees the server after a restart. `GCP_ALERTS_IAC=<dir>` names
another iac dir.

## 4. Tests

- `csi-spl-api/src/go/spool-hub-api/internal/gcpalerts/gcpalerts_test.go`: the
  tools/list golden (`testdata/tools.golden`, `-update` rewrites it), a missing
  key fails before the action, each tool runs its named action, bad input is
  refused, the iac runner.
- `csi-spl-orc/src/bash/tests/agent-mcp-gcp-alerts.tst.sh`: the install action
  (dry run, refusals, wrapper argv, registration, re-run, stale entry).
- `csi-spl-iac/src/bash/tests/gcp-get-alert-incident.tst.sh`: the one-incident
  action on lane 1's fixture (incident, condition, timeline, window, identity,
  not found, controls).
