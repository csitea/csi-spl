# Seat a person in every workspace channel: do_spl_member_seat_all

SPL-2126. Owner HUM-10, 2026-10-16: "all of them should see all of the
channels". One named action seats ONE person, in several workspaces at once,
with one role, and in every live channel of each:

`cd csi-spl-orc && ENV=prd TENANT_IDS='<ws> demo' HUMAN_ID=HUM-<n> MEMBER_ROLE=<role> ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_member_seat_all`

## 1. What it does, per workspace

1. A read-only lookup (one `READ ONLY` transaction per workspace, under its
   `app.tenant_id`): the human behind `HUMAN_ID` or `EMAIL`, its membership
   and role, the live channels that hold membership rows.
2. The writes are the existing named actions, never its own SQL:
   - not a member: `do_spl_tenant_member_add` with `MEMBER_ROLE` (it also
     stamps a pending invite of that workspace as accepted);
   - a member with another role: `do_spl_tenant_member_role` with
     `FROM_ROLE` = the current one;
   - every channel: `do_spl_channel_member_add`. The default channels
     (lobby, alerts, feedback, tasks) and #issues are shown to every member
     and hold no rows, so they are skipped.
3. Idempotent: a seated person is reported and nothing changes.

`DRY_RUN=1` (default) runs the lookup and each write action as its own dry run.

## 2. On sign-in: an invitee with no account yet

`EMAIL=<address>` for a person who has not signed in anywhere is **pending**:
exit 3, nothing written. `WATCH=1` repeats the pass every `WATCH_INTERVAL`
seconds (default 300) until the person is seated, or exits 3 at `WATCH_UNTIL`
(a `date(1)` time, default `+7 days`). A first sign-in in any workspace
creates the human, and the next pass seats them in every listed one. Run the
watch in the lane's own pane, under `timeout`, never as a loose script.

## 3. Exit codes and test

0 seated; 3 pending; 1 refused or a write action failed (the others still
run, and the log names each one). Test:
`csi-spl-orc/src/bash/tests/member-seat-all.tst.sh`.
