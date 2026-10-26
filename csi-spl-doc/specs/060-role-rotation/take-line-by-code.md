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
| the action reads the topic on the hub (`spool hub-tail --with-channel`, as the desk: each message with its envelope's channel) and runs `do_spl_take` with the plan "I read your post now" | `do_spl_take_auto`, `csi-spl-orc/src/bash/run/spl-take-auto.func.sh` |

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
| the topic is in a channel whose sole seat is another seat | only that seat posts there (section 3.1) |
| the hub tail does not say which channel the post is in, the box map cannot be read, or its sole seat column is malformed | fail closed: nothing is posted, the seat's model decides |

### 3.1 Sole-seat channels (SPL-3542)

On 2026-10-26 the take line went out in a channel whose owner rule lets one
named seat post and no other (grade fix A had no such check; the boxes then
got `take-auto.off`). A channel's sole seat is now machine-readable in one
place: column 6 of the box map `<spool root>/channel-rules.tsv`, the map of
channel rules docs (SPL-3500), as `<agent id>@<box>`; empty or `-` is none.
The map stays box-side, never in git: a channel name can be a customer's.
`cr_sole_seat` (`csi-spl-orc/src/bash/features/spawn-agents/lib/channel-rules.inc.sh`)
reads it.

`do_spl_take_auto` reads the channel of the human's post (its `msg_id` row,
else the poster's rows) and of every other message in the topic from
`hub-tail --with-channel`, and skips when any of those channels has a sole
seat that is not `<id>@<box>`. The sole seat itself still takes, and so does
a DM (channel `""`). A desk binary older than `--with-channel` fails the hub
tail, which already posts nothing.

## 4. Proof

`csi-spl-orc/src/bash/tests/spl-take-auto.tst.sh`: the take, the second
delivery, ownership, every skip, the dry run, the notifier gate and its
wiring, the sole-seat cases (section 8), and two planted controls (no owner
check: an owned topic is taken; no sole-seat check: a sole-seat post is
taken). Section 8 run against the code before SPL-3542 fails 12 assertions:
the sole-seat post is taken.
Run against the tree without this change it fails at the first assertion
(no action).
