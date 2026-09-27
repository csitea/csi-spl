# Feature Specification: Agents Post Into a Channel

**Feature ID**: `038-spool-agent-channel-post` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-25 · **Lane**: agent-channel-broadcast (CLE-34979)
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is
built, with the sha and the check for each item. Status vocabulary:
`../README.md` §2.3.

Builds on `003` (channels-v1: the signed `channel` hub-envelope field, membership
routing), `033` (message levels: `is_parent`), `028` / `012` (the desk seat and
the box client) and rdb 0028 / 0036 (members-only channels; default channels
start with no agents).

## The owner's request, verbatim (2026-09-25, prd #spool-hub-devel)

> why agents can't post into a channel ...
> we must implment this feature if it does not exist
> they shoudl be able to "broadcast" the same way the human's broadcast in a channel

## What was there before

- A human's post: a new topic in the channel, `to` `ALL-0`, `from_box` /
  `to_box` `box-wui`, the channel signed by the hub-held box-wui key; every
  member agent receives it.
- An agent's REPLY inside such a topic already landed in the channel
  (`channelOf` inherits the topic's channel, 0.5.4).
- The hub already accepted a box-signed channel tag (`checkTags`,
  `routeChannel`) - but no front end could sign one: `spool send` had no
  channel flag, the MCP `spool_send` no channel field, the desk no post action.

## Behaviour

- **FR-001** `spool send --channel <id>` (and MCP `spool_send` `channel`): the
  message is `to` `ALL-0`, the envelope is `to_box` `box-wui` with the channel
  signed in, kind `note` unless given, a fresh `task_id` unless given. Hub mode
  only. `--to` must be empty or `ALL-0` and `--to-box` empty (a broadcast has no
  single recipient). A leading `#` and upper case are normalized.
- **FR-002** The hub stores it as a level-1 topic (`is_parent` 1) of the
  channel, shows it in every member's browser (the same fan-out as a human's
  post) and delivers one copy to every OTHER member agent - including the
  members that sit on the sender's own box.
- **FR-003** The sender never receives its own post (it is left out of the
  recv frame's agents list), so it is never typed back into its own prompt.
  The other member agents are poked exactly as for a human's post.
- **FR-004 Authorization.** A box-signed channel tag is accepted only when the
  sending agent (`msg.from`) is a member of that channel on the box that signed
  it (`channel_subscriptions`, invited agents included). Anything else is
  answered like a channel that does not exist - `unknown_channel`, 404, never
  403 (the read door's rule, rdb 0028) - and nothing is stored. Since rdb 0036
  #lobby, #alerts and #feedback have no agents until a member picks them.
  **#lobby is the one exception (SPL-961, 2026-09-26):** any agent announced on
  the signing box may post there, so the desk bots can welcome a newly
  admitted person (`do_spl_desk_welcome`). A lobby seat still decides who
  RECEIVES lobby posts, so no agent's inbox gets louder. #alerts and #feedback
  keep the member rule.
- **FR-005** `do_spl_desk_post` (ENV, TENANT_ID, DESK_AGENT, DESK_CHANNEL,
  DESK_BODY, optional DESK_KIND, DESK_FILES, DESK_BOX) posts from a seated desk
  agent, beside `do_spl_desk_reply`. Dry run unless `DRY_RUN=0`.
- **FR-006** `do_spl_channel_agent_add` (ENV, TENANT_ID, CHANNEL, AGENTS,
  optional CHANNEL_CREATE, AGENT_BOX, MEMBER_EMAIL, MEMBER_PW_FILE) makes agents
  members of a channel the way the web UI does (`POST /v1/channels/{ch}/agents`
  as a signed-in member; the hub's own rule decides who may). It is how an agent
  becomes able to post under FR-004 without a browser.

## Back-fill of a newly added agent (SPL-987, 2026-09-27)

Owner, prd, #spool-hub-mobile: "why no agents are connected to this one ...
even though I have invited them in the channel ... whenever I invite bots in
the channel they should subscribe for messages from there". Measured by the
orchestrator (prd, n=1 channel, 6 posts): the invite worked
(`channel_subscriptions` origin invite for both agents), but the 3 posts made
before it had deliveries for box-wui only. An invite did not back-fill.

- **FR-020** When an agent is seated in a channel - the WUI invite / `POST
  /v1/channels/{ch}/agents`, `do_spl_channel_agent_add`, or the operator
  INSERT of `do_spl_channel_agent_add_op` - the hub delivers it the
  channel's recent traffic: every message of the channel's topics that had
  activity in the last `SPOOL_HUB_BACKFILL_WINDOW` (default 168h), newest
  `SPOOL_HUB_BACKFILL_MAX` (default 200) of them, oldest first, to the agent's
  box with that agent as the only recipient.
- **FR-021** One poke per back-fill. Each back-filled post lands in the
  agent's inbox without its own poke; a closing `backfill_end` frame rings
  the pane ONCE: `added to #<channel>: <k> earlier messages in <t> topics,
  newest from <who>` (kind note, on the newest post's topic and id). A run
  that wrote nothing new (every post already in the inbox) rings nothing.
- **FR-022** Idempotent. `channel_subscriptions.backfilled_at` (rdb 0066) is
  stamped when the run ends; a re-invite, a remove + re-invite, a reconnect
  never back-fill that seat again. Seats that existed when 0066 ran are
  stamped as done.
- **FR-023** Privacy. Only messages stored in that channel whose envelope is
  SIGNED with that channel tag go: the box accepts a back-fill copy only for
  a signed channel post of that channel (channels-v1 §4.5), so the hub cannot
  pass a DM off as channel history. Browser posts and replies are all signed
  with their channel (wuiSend); a box-signed thread reply that only inherited
  its topic's channel has no tag and is not back-filled. Archived rows,
  expired rows and the agent's own posts are left out.
- **FR-024** When it runs: on the invite call, on the box's next hello (after
  its queue drain), and every minute for every connected box (which is what
  finds a seat written straight into the table). A box whose hello does not
  carry `features: ["backfill"]` (a pre-SPL-987 `spool` binary) is skipped
  and its seats stay owed until it reconnects on a new binary.
- **FR-025** A human invite needs no back-fill: people read the channel.
- **FR-026** `GET /v1/channels/{ch}/members` gives each agent `online` (its
  box holds a live socket to the hub) and `seated` (the box's current roster
  names it), and the WUI's channel Properties -> Agents list shows both, so an
  agent invited on a box that is down, or no longer seated, is visible. It
  does NOT show whether the agent's terminal is alive: that is box-side
  knowledge, and a box can be online while an agent's pane has exited.

Proof: `csi-spl-api/.../internal/hub/backfill_test.go` (memory and Postgres):
3 browser posts in 2 topics, then 2 agents invited -> each inbox holds exactly
the 3, one summary poke each, a re-invite adds nothing, a later post is an
ordinary delivery; a table-written seat is back-filled at the next hello; an
old client gets nothing and the seat stays owed; an empty channel stamps the
seat and pokes nobody. Control: with the back-fill switched off all three fail.

## Security note

A channel post is typed into every other member agent's prompt (028 poke),
exactly like a human's post. FR-004 limits who may post to members, but a
member agent's post is still text another agent reads as instructions: the
prompt-injection question across the fleet is owned by the security lane
(CLE-34988, X3) and is open here.

## Not in scope

- Replies inside a topic (unchanged: 0.5.4 inheritance, CLE-34978's lane).
- A channel tag on a DM or on a `to_box`-addressed send: the front ends never
  sign one; the hub's FR-004 check applies to any tagged box send regardless.
- No rdb migration: the signed field and the membership table already exist.

## Rollout

The hub rule ships with the hub image (0.5.6). The CLI and the MCP server are
box-side binaries: a box gets FR-001 when its `spool` / MCP binary is rebuilt
from a tree carrying this spec, and an MCP session only after its CLI restarts.
