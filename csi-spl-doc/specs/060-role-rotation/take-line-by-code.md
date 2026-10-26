# The take line is posted by code (grade fix A, SPL-3517)

Owner HUM-10 picked fixes A-E in t1 topic `99ffa592-3717-4b9e-8a80-62c70456ceff`
(answer msg `ce2045be-6ee2-414e-817a-4ba7c2d81194`). The grounds:
[grok dispatch grade 2026-10-25](../../doc/md/grok-dispatch-grade-2026-10-25.md)
section 5: posts answered within 3 minutes were 19.3% under a grok holder
against 79.4% under claude, median first reply 481 s against 40 s.

## 1. The rule it serves

[SPEC-spool-fleet-roles.md](../../doc/md/SPEC-spool-fleet-roles.md) section 3:
a new post (a new topic, or a topic no OD owns) is taken by the dispatch lease
holder at once, with the take line of `do_spl_take`. Until this change the
holder's model ran `do_spl_take`, so the 3-minute answer waited on the
model. Now the box posts the take line itself; the model only answers.

## 2. How it works

| step | where |
|---|---|
| the desk sidecar delivers a post and runs the notifier | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-notify.sh` |
| the gate, pure bash: the sender is a human (`HUM-n`), the task is a full topic uuid, the kind is `task`, `note` or `msg`, not a probe, and `<spool root>/dispatch/lease` names `<to>@<SPOOL_BOX_ID>`; then it starts the action in the background | `spool_notify_take_auto`, `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify-take.inc.sh` |
| the action reads the topic on the hub (`spool hub-tail --json`, as the desk) and runs `do_spl_take` with the plan "I read your post now" | `do_spl_take_auto`, `csi-spl-orc/src/bash/run/spl-take-auto.func.sh` |

The human sees: "Taken by `<id>@<box>`: I read your post now. I post the
result here." The ledger `dispatch/take.log` holds one take per topic and
taker, so when the model then runs `do_spl_take` itself it gets
`TAKEN-ALREADY` and posts nothing.

## 3. When it takes nothing

Each decision is one line in `<spool root>/dispatch/take-auto.log`
(`<epoch> <topic> <id>@<box> <decision>`).

| case | why |
|---|---|
| `<spool root>/dispatch/take-auto.off` exists | the off switch |
| the lease names another seat or box, or is older than `LEASE_STALE` (180 s) | only the live holder takes |
| a test workspace (`spl_test_workspace`) | nobody dispatches there |
| the post names another agent (`@c-001`) | that agent takes it (section 3 table) |
| the hub tail fails | fail closed: the seat's model takes it, as before |
| the topic holds an agent message to a human or to the channel | an OD owns it. An agent-to-agent relay on the topic and the non-AI responder (`RSP-*`) do not count |

## 4. Proof

`csi-spl-orc/src/bash/tests/spl-take-auto.tst.sh`: the take, the second
delivery, ownership, every skip, the dry run, the notifier gate and its
wiring, and a planted control (no owner check: an owned topic is taken).
Run against the tree without this change it fails at the first assertion
(no action).
