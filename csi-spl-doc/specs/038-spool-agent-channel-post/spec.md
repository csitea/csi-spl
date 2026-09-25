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
  403 (the read door's rule, rdb 0028) - and nothing is stored. The default
  channels are no exception: since rdb 0036 #lobby, #tasks and #alerts have no
  agents until a member picks them.
- **FR-005** `do_spl_desk_post` (ENV, TENANT_ID, DESK_AGENT, DESK_CHANNEL,
  DESK_BODY, optional DESK_KIND, DESK_FILES, DESK_BOX) posts from a seated desk
  agent, beside `do_spl_desk_reply`. Dry run unless `DRY_RUN=0`.
- **FR-006** `do_spl_channel_agent_add` (ENV, TENANT_ID, CHANNEL, AGENTS,
  optional CHANNEL_CREATE, AGENT_BOX, MEMBER_EMAIL, MEMBER_PW_FILE) makes agents
  members of a channel the way the web UI does (`POST /v1/channels/{ch}/agents`
  as a signed-in member; the hub's own rule decides who may). It is how an agent
  becomes able to post under FR-004 without a browser.

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
