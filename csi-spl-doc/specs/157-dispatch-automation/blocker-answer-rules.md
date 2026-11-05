# Who answers a blocker: the hub's relayed-line rules (SPL-4864)

RCA [rca-blocker-issues-from-agent.md](rca-blocker-issues-from-agent.md) v1.0,
section 3, options A1.1, A1.2 and C1 (owner HUM-10, t1 8c64225e, msg
70d39d81, answer 1 A). Code: `csi-spl-api/src/go/spool-hub-api/internal/store/blocker_issue.go`
(`BlockerPost.RealSender`, `AnswerQuery`), `internal/hub/blocker_issue.go`
(`blockerOpenPass`), `internal/spool/fromagent.go` (`FromAgentOf`).

## 1. The real sender of a relayed blocker

A line one box relays to another opens with `from_agent: <id>@<box>` and is
sent under a seated proxy id of that box (`spool-fleet-relay.sh`); the hub
stores that body verbatim. The blocker sweep now reads it the way the
receiving box does (`spool.FromAgentOf`, the rule of `WithFromAgent`): when
the row's `from_id` is an agent and the line names an agent of the row's
`from_box`, the line is dropped and its id and box are the sender. So:

- the issue title is the blocker's first real line, never `from_agent: ...`;
- `created_by` and the description name the real sender, not the proxy;
- the self-send rule holds through a proxy: `c-001` to `c-001` files nothing.

A line claiming another box's agent, or one on a person's row, is kept as it
is: a box speaks only for its own agents.

## 2. Which post answers

A post in the blocker's topic after it answers for assignee `a` when its real
author (the same `from_agent` rule, else `from_id` and `from_box`) is `a`, and:

1. **Box.** It came from the box `a` was asked on: the `@box` it was tagged
   with, else the DM's `to_box` when `a` is the recipient agent. A person, or
   an agent tagged with no box, may answer from any box.
2. **Rotation.** The same id from another box answers only when the post
   references the blocker: its first 8 hex (`re 09824eb5`, `accepts
   09824eb5`) or the whole msg_id. Chosen because the role ids (`c-001`
   orchestrator, `c-002` dispatch) move between boxes on a lease rotation:
   the reference proves the new holder answers this blocker, while the same
   bare id on the other box without one is another seat (RCA rows
   SPL-1588, SPL-2769). A strict id@box rule would leave a rotated role's
   real answer unmatched for ever; a bare-id rule is the false match the RCA
   measured.
3. **Shared topic.** When the topic holds any other message that is, or was,
   a blocker (`message_kind_changes`), the post must reference this blocker.
   One `spool-task:<name>` topic holds every alarm of that name, so an answer
   to the newest alarm, or a status card, no longer resolves the older ones
   (RCA rows SPL-1588, 2769, 3244, 3901, 4360).

Issues made before this rule from a proxied self-blocker still link to their
message: clearing the mark or resolving the issue reaches the other
(`blockerAssignees` reads the row both ways).

## 3. No 24 h cutoff for open issues

The sweep reads blockers that fell due in the last hour, or the last 24 h on
every 10th tick. On that long tick it now also re-checks every open `todo`
issue labelled `blocker` whose message is older than the window: it finds
the message by the issue's link, checks the issue's topic is derived from
that message (`madeFor`), and looks for the answer with the rules above, one
read of `messages_task_received` each. Before, an answer after a day never
resolved its issue.

## 4. Tests

`internal/hub/blocker_issue_test.go` (memory, and Postgres under
`SPOOL_TEST_PG_DSN`): `TestBlockerRelayedTitleAndAuthor`,
`TestBlockerRelayedSelfSendMakesNoIssue`,
`TestBlockerRelayedAnswerFromAssigneeBoxResolves`,
`TestBlockerFalseMatchesDoNotResolve` (proxy id equal to the assignee, the
same bare id on the other box, an unrelated post in a shared topic),
`TestBlockerSharedTopicReferenceResolves`,
`TestBlockerRotatedRoleAnswerWithReferenceResolves`,
`TestBlockerAnswerAfterADayResolvesOnLongTick`; `internal/spool/fromagent_test.go`
`TestFromAgentOf`.

Not in this change: the alarm call sites' switch to `--kind note` (A1.3) and
the cleanup of the open issues (B1), each its own lane.
