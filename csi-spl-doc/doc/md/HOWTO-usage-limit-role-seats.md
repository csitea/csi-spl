# Detect and prevent a role seat frozen at its AI usage limit

> Generated from qto doc `379b167a-e816-498d-8451-2e4402d5fb57`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Owner topic t1 865b7a05: "how-to detect and prevent usage limit situations for
the orchestrators". The lease design is in
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md), section 4; this page
covers only the usage-limit case.

<a id="ws-doc-32bf20a0-c0bd-46b3-8970-387331d46f3f"></a>
## 1. What went wrong on 2026-10-03

Every Claude session on the satellite showed `Usage limit reached · resets
10:50am` from about 05:5xZ to 07:50Z. The satellite was ranked first and held
BOTH role leases (orch and dispatch). Its lease loop kept renewing them for
about 30 minutes, until a human changed the ranks with `do_spl_lease_rank` at
07:18Z.

The renew loop already read the seat's tmux pane (CLE-77935), but it counted a
usage-limit banner only while a turn's spinner sat frozen. A seat at its limit
is IDLE: each poke gets the banner back and no turn starts, so there is no
spinner. The loop read the seat as able. The rotation gate saw the same banner
(`GATE SKIP stalled Usage limit reached` in `rotate.log` at 06:05Z, 06:15Z and
07:05Z), but the lease did not act on it.

<a id="ws-doc-48e94575-693b-42b8-8620-0bbef577c6a5"></a>
## 2. Detection: what the lease checks now

`spl_lease_agent_able` in `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`
decides, every tick, whether a seat may keep or take a role. A seat that is not
able is no candidate: its machine stops renewing, and the next machine in rank
takes the role once the lease is stale (180 s). The checks run in this order:

| check | not able when | why written to `able.<id>` |
|---|---|---|
| process | no live claude, grok or vibe process carries the id | `no live process` |
| rotation | `rotate.hold` names the id | `held: rotation ...` |
| modal screen | trust / login picker / onboarding in the pane footer | `stalled pid=N: Do you trust the files` |
| usage limit, idle | a limit banner, NO spinner, and the reset time in the banner still ahead | `stalled pid=N: Usage limit reached, resets in 109 min` |
| usage limit, in a turn | a limit banner under a spinner frozen for 45 s | `stalled pid=N: ..., turn frozen 60s at (12s ...)` |
| stuck (fleet mode, orch AND dispatch seats) | idle while an inbox message newer than its last transcript write waits more than `LEASE_UNREAD_MAX` s (600) | `stuck pid=N: oldest unread 602s > 600s, ...` |

How the reset time is read (`spl_lease_limit_until`):

- The CLI prints it in the agent's local time: `resets 10:50am`, `resets at
  7pm (Europe/Helsinki)`, `resets Oct 6, 10am`, `Continuing automatically at
  7:20am`.
- The zone is taken from the parentheses if present, else `LEASE_LIMIT_TZ`,
  else the box's own zone.
- A time with no date is today's or tomorrow's, and it counts only within
  `LEASE_LIMIT_WINDOW` s (18300, the 5-hour window plus slack). So `10:50am`
  read at 10:51 is the reset that just passed, not tomorrow's.
- A reset already passed means the banner is STALE. The CLI leaves the banner
  on screen after the session resumes (the false positive of 2026-10-02
  04:09Z), so a stale banner never blocks a seat.
- A banner with no readable time keeps the old frozen-spinner rule.

The seat comes back by itself: every tick re-reads the pane. Once the reset
time has passed, the seat is able again, its machine renews, and the role
returns to it on rank.

The check fails open: if no pane is found (no tmux, or the agent runs outside
tmux), only the process rule applies.

<a id="ws-doc-2f283a9c-3f83-44dd-ab79-9cef824d90a2"></a>
### 2.1 Read it on a box

These are read-only. The current holder of each role:

```bash
cd csi-spl-orc && SPOOL_ROOT=/var/spool-hub LEASE_CMD=show ./run -a do_spl_dispatch_lease
```

Why each local seat is or is not able, as of the last tick:

```bash
grep -H . /var/spool-hub/dispatch/able.*
```

The transitions (`renew stop`, `NO-LOCAL-AGENT`, `FLEET <role>: ... takes over`):

```bash
tail -n 50 /var/spool-hub/dispatch/lease.log
```

<a id="ws-doc-614e87f8-fd37-4a26-a9cf-f58c7155e7e6"></a>
### 2.1.1 The dispatch rotation checks the failover first

The hourly dispatch rotation (`do_spl_dispatch_rotate`) hands the lease to the
failover seat while the master gets a fresh session. Its GATE runs the lease's
own test on the failover (`spl_lease_agent_why`: a hold, a watchdog HIT under
90 s old, the pane; no key is pressed). A failover that is not able is
`GATE SKIP failover not able: <id> <why>` in `rotate.log`, with one note to the
orchestrator and no owner page. The master keeps the lease; the next hour
tries again.

Why (SPL-1890): rotation `20261014T0215Z-master` on the satellite started its
HOLD while `c-003` was on its weekly limit (`wd.log`: `HIT S2 kind=limit` every
30 s since the day before). The fleet loop never chose `c-003`, the HOLD waited
240 s, and the run ended `FAIL HOLD: the lease did not move to c-003` and paged
the owner.

<a id="ws-doc-76f495a9-9a61-40d5-b422-e12e1fe39c8a"></a>
### 2.2 How close a login is to its limit

The pane banner shows only that a seat HAS hit the limit. To see a limit
coming, read the login's usage:

- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`.
- Auth: the `claudeAiOauth.accessToken` from the agent user's
  `~/.claude/.credentials.json`, plus the header
  `anthropic-beta: oauth-2025-04-20`.
- Response: `five_hour` and `seven_day` utilization in percent.

Never print the token. When a login nears 97%, the standing rule is to switch
the agent user to a second login. That switch reaches running sessions only
after a restart or a token refresh, and it affects every session of that user.

Gap: no named action wraps this read yet. Make it one
(`do_spl_ai_usage`, per the "nothing ad hoc" rule) before anyone scripts it.

<a id="ws-doc-9ffc049f-e8c8-467a-a42f-1bd271686b89"></a>
## 3. Prevention: do not put every role seat on one login

The failover works only if the next machine's seats can still act. If every
role seat of every machine shares one AI login, they all hit its limit at the
same minute: the lease moves the roles to a machine whose seats are just as
frozen, and nothing dispatches until the reset.

- Run each machine's role seats (orch, master, failover) under a login that no
  other machine's role seats share. At least the first-ranked and the
  second-ranked machine must differ.
- Lane agents may share a login with each other. They must not share the login
  of the role seats they would starve.
- Check it after every login switch and after every rank change. Read
  `oauthAccount` in each machine's agent-user `~/.claude.json`: it names the
  account, though a live session may still hold the old token until restart.
- When the usage read (2.2) shows a login above about 90% of its window, move
  the roles first (`do_spl_lease_rank`, so a machine on another login ranks
  first), then switch that login.
