# The desk's new-topic lease gate

SPL-3520, grade fix C (owner HUM-10, t1 99ffa592, answer msg ce2045be).
The grounds are in [the grok dispatch grade](grok-dispatch-grade-2026-10-25.md),
section 5: a seat outside the lease wrote 14 first replies, and three graded
cases had two seats answering the same post.

## 1. The rule it enforces

The routing rule is in [fleet roles](SPEC-spool-fleet-roles.md), section 3.
A new topic belongs to the dispatch lease holder, and the first agent reply in
a topic makes its author the topic's owner. Until now that rule was a prompt
habit. Now `do_spl_desk_reply` enforces it.

## 2. What the desk refuses

For every vendor, `do_spl_desk_reply` refuses the **first** agent reply in a
topic. It exits 8, sends nothing, and the FATAL names the lease holder to
leave the post to or send the answer to. The reply goes through when the seat
is one of these:

| the seat | how the desk knows |
|---|---|
| the dispatch lease holder, right now | `<spool root>/dispatch/lease`, `<ID>[@<box>]`. The box must match `LEASE_MACHINE`, else `lease.conf`, else this machine's desk box id |
| the orchestrator lease holder (the 3-minute backstop, which then owns the topic) | `<spool root>/dispatch/lease.orch` |
| a workspace seat in its own workspace | this box is claimed by the reply's workspace (spec 108 3.5, `spl_box_ws_claim`) |
| a channel seat of the topic's channel | its brief `<spool root>/<id>/lifetime/brief.md` has `Channel: <tenant> #<channel>` (SPL-3500), and the topic was posted in that channel (`spool hub-tail --with-channel`). A spool binary without that flag: the tenant alone is matched |
| a seat the human addressed | a human post in the topic is a DM to it, or names it (`@<id>`) |

**A sole-seat channel comes first** (SPL-3542). When the channel-rules map
(`$SPOOL_CHANNEL_RULES_MAP`, default `<spool root>/channel-rules.tsv`) names
the topic's channel a sole seat (column 6, `<id>@<box>`, read with
`cr_sole_seat`), only that seat posts the first reply there. The table above
does not apply: the dispatch and orchestrator lease holders are refused too,
and the FATAL names the sole seat to send the answer to. A column 6 that is
not `<id>@<box>`, or a topic that cannot be read while the map exists:
refused (fail closed). A spool binary without `hub-tail --with-channel`
cannot name the topic's channel: the rule is skipped with a WARN. A tree
without `cr_sole_seat` (before SPL-3542 lands) skips it silently.

A reply that is not the first is never refused here. That covers the topic's
owner answering again, and anyone after an agent has already answered.

## 3. Edges

- The topic is read from the seat's own desk box (`spool hub-tail`), and the
  hub gives a box only the messages it sent or was sent. A reply made from
  another machine's box is not in that read. On 2026-10-30 (topic
  63674838) this refused the routed seat twice: the dispatch holder had taken
  the topic from the other box. So when the box's own read shows no agent
  post and no human addressing the seat, the gate asks the hub for one more
  number, `spool hub-tail --task <id> --agent-count` (SPL-4444). It is the
  count of the topic's agent posts from every box: not a person's, not the
  responder's, not a guest's. One or more means the reply is not the first.
  The hub answers it only for a topic the box holds something of, as it does
  for `hub-rsp`. It sends a count, never the posts. A count that cannot be
  read means the reply is treated as the first, and it is refused with a
  WARN. That covers a hub down, an older hub and an older spool binary.
- A `RSP-*` responder post is not an agent reply.
- No lease file (a box without dispatchers): no gate. A lease that names no
  holder: no gate, with a WARN.
- A `hub-tail` that fails: refused. The seat is not the holder, and the holder
  can answer.
- `do_spl_take` posts its take line through `do_spl_desk_reply`, so a take by
  a seat that may not take the topic is refused the same way.

## 4. Code and test

- Gate: `csi-spl-orc/lib/bash/funcs/spl-desk-lease-gate.func.sh`
  (`spl_desk_lease_gate`), one call in `do_spl_desk_reply` right after the
  conversation is chosen.
- Test: `csi-spl-orc/src/bash/tests/desk-reply-lease-gate.tst.sh`. 34 cases.
  With the gate call removed, 7 of the first 16 fail. With the sole-seat
  block removed, 6 of the 11 SPL-3542 cases fail. With the old tenant-only
  channel match, 1 of them fails. With the old gate (no hub count), 5 of the
  7 SPL-4444 cases fail.
- The hub count: `onTailCount` in `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go`
  (an `agent_count` tail frame), the client's `Session.AgentCount`, and the
  `hub-tail --agent-count` flag. Its test is `internal/hub/agent_count_test.go`.
  Another box's agent post is counted, the box's own tail still holds only its
  share, and `rsp_count` is unchanged. A box that holds nothing of the topic
  reads 0, and a frame asking both counts is refused.
