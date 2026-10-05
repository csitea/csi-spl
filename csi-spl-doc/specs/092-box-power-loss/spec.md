# 092 Box power loss is routine: spec

Status: v0.1, 2026-10-05. Topic: `368e1565-ea4a-4ea6-8570-9cd81a7ce9ec`.
Source: the 2026-10-05 power-loss review of the laptop box (its section 8 =
the fixes, section 9 = the open questions). This spec restates what the build
needs, so the review is not required reading.

## 0. Premise (owner, t1 368e1565)

> "because this type of power lost situations will be pretty common ... as the
> [laptop box] is just a laptop" (msg 88ab4d48)
>
> "In the future we will have more than one boxes in the cloud , but still I
> will be using the [laptop] box ..." - "so cook with this in mind"
> (msgs 03d2577e, 6eef9c67)

- **A box losing power is a normal event, not an incident.** Nothing here may
  need a human to notice it, run a command or relay a message.
- **The fleet is N boxes**, not a fixed pair: any number of **always-on**
  boxes (cloud VMs) plus any number of **intermittent** boxes (a laptop) that
  stay in the fleet and drop off it without warning. No box name is written
  into the design: a box's class is configuration.
- While an intermittent box is off, **the always-on boxes carry every role and
  every cron alone**. When it returns, **it takes nothing back until it is
  proven healthy**.

## 1. Requirements

| id | requirement |
|---|---|
| FR-001 | **The premise, and fix 1's acceptance test.** When any box holding a fleet role loses power, another box (an always-on one, by rank) holds that role within `LEASE_STALE` + one tick (181..240 s), with no human step. When the box returns, it takes no role back until its candidate has been able, its desk included, for `LEASE_HOLDDOWN` s (default 300) without a break. A box listed as intermittent never takes a role back by rank: it takes one only when the role is empty or its holder is stale. |
| FR-002 | A dispatch candidate is **able** only when its box can post: the `LEASE_TENANT` desk sidecar of its desk box is alive and its current session's last word is `hub session up`. A holder whose desk drops stops renewing and fails over like a dead process. |
| FR-003 | The terraform infra containers (`tf-runner`, `tpl-gen`, `conf-validator`) come back by themselves after a power cut. |
| FR-004 | Work in flight to a holder that dies is not lost: the next holder gets it. |
| FR-005 | The owner hears, once, that the dispatch role moved after a failover (not after a handback). |
| FR-006 | No owner post waits more than 3 minutes without an agent reply in its topic, checked by code, not by prose. |
| FR-007 | An owner-facing relay states the check behind it; one agent posts per topic while the fleet is split. |
| FR-008 | Every freshness check reads the fleet's state (the holder's last delivery), never only its own box's. |
| FR-009 | Each box class runs the same crons, or the difference is declared; a check reports drift. |

## 2. User stories

One story per fix of the review's section 8, in its rank order. Each is one
small lane (`tasks.md`).

### US1 Desk-gated lease with a handback hold-down (fix 1) - FR-001, FR-002

As the owner, I want a returning box to wait until it can really post before
it takes a role back, so a box that has just booted never holds dispatch with
a desk that cannot post. On 2026-10-05 the returning box took dispatch after
22 s of health, 51 s before its own desk sidecar was up.

Acceptance:

1. A box whose `LEASE_TENANT` desk sidecar is down, or whose current session
   has not said `hub session up` (or lost it since), has no dispatch
   candidate: it does not take, renew or hand back dispatch. While it holds
   the role it logs `NO-LOCAL-AGENT dispatch: ... desk: <why>` once, and the
   role goes stale and fails over.
2. A box that ranks before the holder takes the role back only after its
   candidate has been able for `LEASE_HOLDDOWN` s (default 300) without a
   break; any tick without a candidate restarts the clock. A stale or empty
   role is still taken at once: the failover is never delayed.
3. A box listed in `LEASE_INTERMITTENT` never hands back by rank; it takes a
   role only when it is empty or stale.
4. The scenario test, N = 3: two always-on boxes and one intermittent box
   ranked first. The intermittent box loses power; the next box by rank holds
   both roles 181 s later. The intermittent box returns with its desk down:
   it takes nothing. Desk up for less than the hold-down: nothing. After the
   hold-down: still nothing, because it is intermittent. The same box NOT
   listed as intermittent takes the roles back only after the hold-down.
5. Back-compat: no desk dir known (the stub hub of the tests) or
   `LEASE_DESK_GATE=0` = the gate is off; `LEASE_HOLDDOWN=0` = the old
   immediate handback.

Test: `csi-spl-orc/src/bash/tests/fleet-lease.tst.sh` section 19, with a
CONTROL (`LEASE_DESK_GATE=0 LEASE_HOLDDOWN=0`, no `LEASE_INTERMITTENT`) that
takes the role back on the first tick with a dead desk, as the old code did.

### US2 tf infra containers restart after a power cut (fix 2) - FR-003

As an operator, I want `make do-provision` to work after a box reboots without
starting the containers by hand. On 2026-10-05 they had restart policy `no`,
exited at boot, and were started by hand 8 minutes later.

Acceptance: `restart: unless-stopped` on the three services of
`csi-spl-orc/src/docker/docker-compose-tf-infra.yaml`. It takes effect at the
next `make do-setup-app-inf`; this change forces no rebuild.

Test: `docker compose -f csi-spl-orc/src/docker/docker-compose-tf-infra.yaml
config` shows `restart: unless-stopped` for each of the three services. After
the next setup, `docker inspect -f '{{.HostConfig.RestartPolicy.Name}}'` on
each container prints `unless-stopped`.

### US3 Handover on takeover (fix 3) - FR-004

As the owner, I want a relay sent to a holder that has just died to reach the
next holder. On 2026-10-05 two owner-text relays reached the owner 24 min late.

Acceptance: on a dispatch takeover (not a renewal), the new holder receives
the old holder's inbox items of the last N min that its outbox shows unacted,
or the sender keeps relay copies and resends on a holder change. The lane's
plan picks one.

Test: a fleet-lease section that kills the holder with two relays in its
inbox and asserts the new holder gets both, once.

### US4 Owner DM on a dispatch failover (fix 4) - FR-005

As the owner, I want one DM when dispatch fails over, as I already get for the
orchestrator (`spl_fleet_owner_dm` fires only for `role == orch` today).

Acceptance: a dispatch failover (holder stale) DMs the owner once; a handback
or a renewal DMs nobody.

Test: `fleet-lease.tst.sh` section 15 extended to the dispatch role.

### US5 The 3-minute guard in code (fix 5) - FR-006

As the owner, I want an "on it" line in the topic as soon as a post goes to a
lane, and a sweep that finds an unanswered owner post even when an unrelated
agent post came after it.

Acceptance: lane work posts "on it" at once (the dispatcher brief). The sweep
keys on each unanswered human post, not on the topic's last message, with a
short-age fast path on the holder.

Test: `unanswered-sweep*.tst.sh`: a human post followed by an unrelated agent
post in the same topic is still reported.

### US6 Relay hygiene (fix 6) - FR-007

Acceptance: the dispatcher and orchestrator briefs say: an owner-facing relay
states its check; one poster per topic during a split (the topic owner); never
relay "owner-only / can't" without the refusal text.

Test: a brief-lint test that greps the three rules in the rendered briefs.

### US7 Fleet-wide sweep freshness (fix 7) - FR-008

Acceptance: the dispatch check reads the holder's last sweep delivery, not its
own box's `unanswered.last`, so a returning box raises no stale-sweep gap.

Test: two boxes, the returning box's own file old, the holder's fresh: no gap.

### US8 Cron parity across boxes (fix 8) - FR-009

Acceptance: a named check action lists each box's `# csi-spl:` crons and
reports a cron present on some boxes of a class and missing on others, unless
the cnf declares it single-homed.

Test: fixtures of two crontabs, one drift, one declared exception.

## 3. Research items (the review's open questions)

| R | question | how to answer |
|---|---|---|
| R1 | Why the returning box's dispatcher believed its desk could not post, 3 minutes after its sidecar was up (a hub DNS timeout is a candidate). | that box's `hub-run.log` and `lease.log` around the time; `do_spl_desk_check` |
| R2 | How the returning box's agents came back with no `agent-boot-restore` cron. | its crontab, systemd units, tmux resurrect; feeds US8 |
| R3 | Why `do_spl_desk_up_boxes` and `do_spl_responder_sweep` exit 1 on every tick after a boot. | their `cron.out` on that box |
| R4 | Whether the web app shows the owner the pairs of `[blocker] "Topic: ..."` / `resolved: ...` posted during the outage. | the topic views on prd |
| R5 | Hub-side delivery facts were read from a desk mirror, never from the hub. | `do_spl_db_query` on `deliveries` for the outage window |
