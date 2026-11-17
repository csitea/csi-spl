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
- SPL-5642 stopped the vendor cap case: an announce over a cap now keeps
  only the capped id out and sends no error frame. The other announce
  refusals (the bot seat cap, a duplicate roster id, a store error) still
  sent one until SPL-5735.

SPL-5735 (`b4b9c4f1b`) stops the cross-talk for every announce refusal, on
both sides. The hub writes each one as a frame type of its own,
`announce_error` (`failAnnounce`, `internal/hub/ws.go:129`, called from
`onAnnounce`), never an `error` frame; a box client that predates it waits
only for `error` or the reply it asked for, so it skips that frame. The
box client diverts `wire.IsAnnounceRefusal` frames
(`internal/wire/announce.go:28`) in its read loop
(`internal/hubclient/hubclient.go:607`) to a log line and
`Session.AnnounceRefusals()`, never to a request's reply: an `announce_error`,
and also an older hub's `msg_id`-less `error` that names a roster write, so
a hub that predates SPL-5735 is covered too. The frame:
`csi-spl-doc/specs/003-spool-message-bus/contracts/http-v1.md` section 2.1,
frame 15. Paths are under `csi-spl-api/src/go/spool-hub-api/`.

## 2. What the desk does now

When the send's error names a roster write (`roster not updated`,
`roster not stored`, `subscriptions not stored` or the token
`roster_duplicate`), `do_spl_desk_reply`
reads the topic (`spool hub-tail --task <topic> --json`). If the newest post
from the agent in the last 15 minutes has the same body:

- it exits 0 and prints the usual JSON line, with that post's `msg_id`
  (and its permalink when the workspace has a WUI link base, as for any
  reply);
- it logs `WARN the post IS stored in topic <topic> as msg <id>; only this
  desk box's roster write was refused, do not post it again: <refusal>`;
- it does not send again, and does not fall back to the DM (spec 067
  edge 2).

Only a post from the answering agent counts: the same body from another
agent in that topic is not this post.

Any other refusal, or no such post in the topic, still exits 1 with the
FATAL. Callers that branch on the exit code read 0 as posted and need no
change.

Since SPL-5735 (section 1) a send no longer gets an announce refusal as
its own answer when the hub or the box's `spool` binary carries that fix,
so this check is reached only when both predate it. It stays as a fallback;
no code was changed for SPL-5735.

Code: `_spl_desk_reply_landed` in
`csi-spl-orc/src/bash/run/spl-desk-reply.func.sh`. Test:
`csi-spl-orc/src/bash/tests/desk-reply-roster-refusal.tst.sh` (cases 1, 2 and
6 fail on the old action; 3 to 5 and 7 are controls).
