# 092 Box power loss is routine: plan

Spec: `spec.md`. Every fix is an orc or doc change: no hub, rdb or terraform
change, so none needs a deploy beyond trunk (the desk reconcile cron runs the
orc checkout).

## 1. Fix 1: the desk gate, the hold-down, the intermittent class

All in `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh`, fleet mode.

### 1.1 The desk gate (`spl_fleet_desk_able`)

- The desk dir: `LEASE_DESK_DIR`, else
  `$SPL_STATE_DIR/desk/$LEASE_TENANT/$LEASE_DESK_BOX` (the pin
  `spl_fleet_hub_init` already checks). Neither known (the tests' stub hub)
  or `LEASE_DESK_GATE=0` = the gate is off.
- Alive: `<dir>/spool/.hub/hub-run.pid` names a pid whose cmdline (under
  `LEASE_PROC_ROOT`, `/proc` by default) carries `hub-run`.
- Session up: in `<dir>/spool/.hub/hub-run.log`, the last session line
  (`hub session up`, `hub session down`, `... so the session reconnects`) is
  `hub session up`, and the log was written no earlier than the pid file. A
  last `up` that belongs to the sidecar before a restart is not this
  session's.
- Only the dispatch role is gated: the dispatcher is the seat that posts. The
  reason goes into `able.<id>`, so `NO-LOCAL-AGENT` names it.

### 1.2 The hold-down and the intermittent class

- `fleet.<role>.able-since` holds the first tick of the current unbroken run
  with a candidate; a tick with none removes it.
- A rank handback (holder fresh, its box ranked after this one) needs
  `now - able-since >= LEASE_HOLDDOWN` (default 300 s; 0 = the old rule).
- `LEASE_INTERMITTENT` (lease.conf or env, comma-separated boxes): a listed
  box never hands back by rank; it takes a role only when empty or stale.
- Taking a stale or empty role is never delayed: that is the failover.
- Held back is logged once per condition (`HOLD <role>: ...`) and cleared
  when it changes.

### 1.3 Tests

`fleet-lease.tst.sh` section 19: the N = 3 scenario of spec US1 acceptance 4,
plus the control. The `tick` helper passes `LEASE_HOLDDOWN=0` to the older
sections, so they keep testing what they tested.

## 2. Fix 2

`restart: unless-stopped` on the three services. `unless-stopped`, not
`always`: a container stopped on purpose stays stopped.

## 3. Fixes 3-8

One lane each, from `tasks.md`. A lane that changes the design updates this
plan in its own commit.
