# A desk reply that is stored while the roster write is refused

SPL-5644. On 2026-11-15, on prd workspace csitea, `do_spl_desk_reply` from
two desk seats on one box (n=2) exited 1 with:

`spool: hub refused: vendor_cap_exceeded (refused: grok agent cap reached for workspace csitea: max 0 live, requested 1 live: roster not updated)`

The hub had stored the second post (msg 0a7efcb5, 17:52:09Z); a third try
was refused as `duplicate_to_human`. The seats retried a post that had
already landed.

## 1. Why the send read a refusal it did not get

- The desk box's sidecar re-announces its spool dir scan when it changes.
  That desk's spool held a stale grok agent dir (2026-10-13), and csitea's
  grok cap is 0, so the hub refused the announce
  (`internal/hub/ws.go` `onAnnounce`).
- An announce refusal is an error frame with no `msg_id`, and nothing waits
  for it. A send in flight on the same socket accepts a `msg_id`-less error
  as its own answer (`internal/hubclient/hubclient.go`, `sendFrame`), so
  the send reported the announce's refusal while the hub stored the post.
- SPL-5642 stops the vendor cap case: an announce over a cap now keeps only
  the capped id out and sends no error frame. The other announce refusals
  (the bot seat cap, a duplicate roster id, a store error) still send one.

## 2. What the desk does now

When the send's error names a roster write (`roster not updated`,
`roster not stored` or `subscriptions not stored`), `do_spl_desk_reply`
reads the topic (`spool hub-tail --task <topic> --json`). If the newest post
from the agent in the last 15 minutes has the same body:

- it exits 0 and prints the usual JSON line, with that post's `msg_id` and
  permalink;
- it logs `WARN the post IS stored in topic <topic> as msg <id>; only this
  desk box's roster write was refused, do not post it again: <refusal>`;
- it does not send again, and does not fall back to the DM (spec 067
  edge 2).

Any other refusal, or no such post in the topic, still exits 1 with the
FATAL. Callers that branch on the exit code read 0 as posted and need no
change.

Code: `_spl_desk_reply_landed` in
`csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`. Test:
`csi-spl-orc/src/bash/tests/desk-reply-roster-refusal.tst.sh` (cases 1 and 2
fail on the old action; 3 to 5 are controls).
