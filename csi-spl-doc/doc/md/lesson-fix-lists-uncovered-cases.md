# Lesson: a fix for one case lists the cases it does not cover, and tests each

Source: the incident report on t1 topic `f87e6c9d` (spec 117,
`csi-spl-doc/specs/117-dm-reply-addressing/spec.md`), section 4 items 3-6.
Rule first, the case that taught it after.

## 1. The rule

A fix that handles one case of a shape names, in its commit and in its test,
**every other case of the same shape**: the ones it does not handle. For
each one, either it is handled too, or a test pins down what happens to it
and a check reports it when it happens in real use.

1. **Name the shape, not the case.** "A reply in a channel-less topic with no
   `to`" is the shape. "A reply to an agent" is one case of it.
2. **List the shape's cases next to the fix.** Who else can be on the other
   end, and what does each read door, count and push do with the row?
3. **One test per case**, including the ones the fix leaves alone. A case
   left alone gets a test that asserts what it does today, so a reader sees
   that it was left alone on purpose.
4. **Every case left alone gets a report in real use.** A test proves the
   code. Only a check on real data proves nobody is hit. Write a read-only
   action that lists the rows of the uncovered cases and run it on a
   schedule.
5. **Nothing that classifies rows may hide a case.** A sweep or report that
   puts a case in a bucket meaning "someone else has it" must be sure that
   someone else really reads it.

## 2. Worked example: "reach the agent" (604f9fa22)

### 2.1 The fix

A person's reply to the whole topic (to `ALL-0`, no `@mention`) in a topic
with no channel reached nobody: no channel to fan out to, no agent to send
to. Commit 604f9fa22 (`internal/hub/topic_reply.go`, `topicReplyAgent`)
re-addressed such a reply to the topic's most recent agent. It said what it
left out ("a person-to-person DM, an agent that left: keeps the browser-only
post"), but nothing tested those cases and nothing reported them.

### 2.2 The cases it did not cover

| case | what happened | today's guard |
|---|---|---|
| a reply in a person-to-person DM, sent from the topic page | stored to `ALL-0`, read by its writer alone (spec 117 1.1: 3 rows) | spec 117 FR-1 (hub), FR-4 (WUI); LANE B e2e |
| a new channel-less root naming nobody | stored to `ALL-0`, read by its writer alone (1 row) | spec 117 FR-2 refuses it; FR-5 shows "Not sent" |
| a reply under an agent that is no longer announced | stored to `ALL-0`, read by its writer alone | `do_spl_msg_unreadable` lists it (`in topic: agent`) |
| the unanswered sweep's view of all three | counted as `to-human`, so never listed | the sweep's "Reached nobody" table |

prd, read-only, 2026-10-09, `ENV=prd UNREADABLE_DAYS=15 ./run -a
do_spl_msg_unreadable` on tree 332ec1975 plus this lane: 42 writer-only rows
outside test workspaces. 20 are in person-only topics and 22 are in topics
an agent posted in. 123 more are in the e2e workspace.

### 2.3 What closes it

- `do_spl_msg_unreadable` (csi-spl-orc): lists every person -> `ALL-0` row
  with no channel, per env and workspace, by ids, times and seats only. It
  runs daily (box-crons manifest row `msg-unreadable`) and sends the NEW
  rows to the orchestrator as one spool note. Test workspaces are counted
  apart and never alerted. Test: `msg-unreadable.tst.sh`, with a real
  Postgres part and CONTROL rows for each shape that must NOT be listed.
- `do_spl_unanswered_sweep`: the bucket `to-human` is only for a post
  addressed to a person. A null-channel `ALL-0` post with no agent in the
  topic goes in its own `nobody` count and "Reached nobody" table. Tests:
  `unanswered-sweep.tst.sh`, `unanswered-sweep-pg.tst.sh`, both red on the
  old classifier.

## 3. Checklist for the next fix of this kind

- [ ] The commit names the shape and lists its cases.
- [ ] Each case has a test: handled, or pinned as left alone.
- [ ] Each case left alone has a read-only report on real data, run on a
      schedule, with ids and no bodies.
- [ ] No sweep or report puts the case in a bucket that assumes a reader.
