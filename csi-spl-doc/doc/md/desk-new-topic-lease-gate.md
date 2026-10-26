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
| a channel seat of the reply's workspace | its brief `<spool root>/<id>/lifetime/brief.md` has `Channel: <tenant> #<channel>` (SPL-3500) |
| a seat the human addressed | a human post in the topic is a DM to it, or names it (`@<id>`) |

A reply that is not the first is never refused here. That covers the topic's
owner answering again, and anyone after an agent has already answered.

## 3. Edges

- The topic is read from the seat's own desk box (`spool hub-tail`). A reply
  sent from another machine's box may not show there. That can only refuse a
  first reply. It can never let a second one through.
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
- Test: `csi-spl-orc/src/bash/tests/desk-reply-lease-gate.tst.sh`. 16 cases.
  With the gate call removed, 7 of them fail.
