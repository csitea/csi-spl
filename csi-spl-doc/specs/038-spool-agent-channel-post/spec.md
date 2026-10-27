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
  - SPL-3717 (lessons-learnt row 8, the badge said "box offline" while that
    box's agents answered): `online` is the presence `GET /v1/view/roster`
    reads (`presence.go`: a socket on the answering instance, else a fresh
    shared stamp), no longer "this instance holds the socket", which any
    other Cloud Run instance or revision answered as offline. The dialog
    reads the roster into the shared roster store on open and draws each
    badge from that store's presence, which the socket's presence frames keep
    live while it stays open (`channel-agents-live.ts`). Proof:
    `internal/hub/channel_agent_presence_test.go`,
    `csi-spl-wui/tests/e2e/channel-people.test.mjs`.

Proof: `csi-spl-api/.../internal/hub/backfill_test.go` (memory and Postgres):
3 browser posts in 2 topics, then 2 agents invited -> each inbox holds exactly
the 3, one summary poke each, a re-invite adds nothing, a later post is an
ordinary delivery; a table-written seat is back-filled at the next hello; an
old client gets nothing and the seat stays owed; an empty channel stamps the
seat and pokes nobody. Control: with the back-fill switched off all three fail.

## No human post goes unheard: the fallback responder (SPL-997, 2026-09-27)

Owner, prd t1 #spool-hub-devel, topic 1451c158, answering the SPL-987 report
("the 3 posts you made before the invite never reached them"): "change the
source code to prevent this type of situation from happening ... as long as
there is even 1 agent online ... it should get informed and react".

Measured before (prd, last 7 days to 2026-09-27 10:16Z, `do_spl_db_query`,
n = every browser post by a HUM-* that is not a DM to another human):
t1 30 of 289 (10.4%) reached no agent box (deliveries to box-wui only);
csi-rel 14 of 14 (100%, every one unsigned: no box can take an unsigned post,
see FR-038); e2e (test tenant) 90 of 120. All tenants: 134 of 423 (31.7%).

- **FR-030** Which posts. A browser post by a signed-in human (HUM-*) that the
  hub stored NEW (not a resend) and SIGNED with the box-wui key: a new topic
  or a reply in a channel (#lobby included), or a DM to an agent. A DM to
  another human, an agent's own post and an unsigned post are never passed
  on.
- **FR-031** Heard or not. The post is heard when at least one agent it
  routes to is ONLINE in the FR-026 sense - its box holds a live socket to
  the hub AND the box's roster names it: the channel's member agents (any box
  but box-wui) and, for a DM or an @agent dispatch, `msg.to` on its box.
  Heard = nothing more happens.
- **FR-032** Unheard -> ONE fallback agent. The hub picks exactly one agent,
  never a broadcast: (1) the first agent of the tenant's responder list
  (`tenants.responders`, rdb 0067, an ordered list of agent ids) that is
  online and seated; (2) else any online seated agent of the tenant, the box
  with the longest-running socket first, then agent id. A candidate on a box
  whose hello does not carry `features: ["fallback"]` (an older `spool`
  binary) is skipped, as FR-024 skips it for the back-fill.
- **FR-033** The delivery. The post goes to that agent alone as a recv frame
  flagged `fallback: "<where>"` (`#<channel>`, or `DM to <agent>`). The box
  accepts it only for an envelope signed by box-wui (the one signer of a human
  post) and only for an agent it hosts; it writes the post into that agent's
  inbox without the ordinary poke and rings ONE line instead:
  `unanswered post in #<channel> (no member agent online): <excerpt>` (for a
  DM: `unanswered post in DM to <agent> (agent offline): <excerpt>`), from the
  post's author, on the post's topic, so a reply lands in the right thread.
  The agent answers, or routes it (for the orchestrator: claim and route,
  like any owner post). The fallback agent is NOT seated in the channel.
- **FR-034** Recorded. A deliveries row (to_box = the fallback box, sent), so
  the SPL-997 measurement counts the post as heard, and one
  `fallback_deliveries` row (rdb 0067: tenant, msg, channel, box, agent,
  delivered_at; RLS 0021 form). A write to a socket that fails leaves the
  deliveries row queued; it expires by TTL.
- **FR-035** Visible. `GET /v1/channels/{ch}/members` carries `fallback`: the
  agent a post would go to now (`id`, `box`; empty when no agent of the
  tenant is online), `active` (no member agent online now, so posts DO go to
  it), and `recent` (the fallback deliveries of this channel in the last
  7 days: `count`, and the newest one's `id` and `at`). The WUI's Properties ->
  Agents list shows it as a "fallback responder" line.
- **FR-036** The setting. `do_spl_tenant_responders ENV=<env> TENANT_ID=<t>
  AGENTS="CLE-001 ..."` (`none` clears) writes the list; dry run unless
  `DRY_RUN=0`. t1's list is `CLE-001` on dev and prd.
- **FR-037** Unchanged: the FR-020 back-fill still hands a member agent the
  history when it comes online later; a heard post is delivered exactly as
  before.
- **FR-038** Not covered: an UNSIGNED post (a tenant without the box-wui pin,
  or a poster whose role lacks agents.command) cannot be taken by any box, so
  no fallback is possible; the hub logs `fallback_unsigned` for it instead of
  staying silent.
- **FR-039** Per-channel opt-out (CLE-001, 2026-09-27, after go-live: proof
  runs posting into #live-proof poked the responder every time). A channel
  with `channels.no_fallback` (rdb 0068) keeps the pre-SPL-997 behaviour: an
  unheard post there reaches no agent. People's channels keep the fallback
  (default false). Set with `do_spl_channel_fallback ENV=<env> TENANT_ID=<t>
  CHANNEL=<ch> NO_FALLBACK=1|0`; no test user id is hard-coded anywhere. The
  members answer's `fallback.off` says so, and Properties shows "off for this
  channel".

Proof: `internal/hub/fallback_test.go` (memory and Postgres): a channel with no
agent member, a human post -> the responder's inbox holds it with one fallback
poke; the control with a member agent online -> no fallback; the responder
offline -> the next online agent; an old client is skipped; a DM to an offline
agent falls back; a DM to another human does not. Live: `do_spl_fallback_probe`
in prd e2e (post + control), and the measurement re-run after.

## The AI agents switch per channel (SPL-1684, 2026-10-13)

Owner decision in a workspace poll (both admins voted B): "the AI agents are
turned on with a button per channel, off by default" in that workspace. Every
other workspace keeps today's behaviour.

- **FR-040** A channel has an AI agents switch. Off, its posts reach no agent
  through the channel: the hub builds no member box delivery (routeChannel),
  drops a member row queued before the switch (recvAgents), leaves the
  back-fill of its seats pending, and does not hand the post to the fallback
  responder (fallback or SPL-1225 escalation). The unanswered sweep reads the
  switch and counts such a post under `channel` (cstate `ai_off`), never as
  unanswered.
- **FR-041** What still goes when off: a DM to an agent, and a post addressed
  to an agent (`@c-007 ...`, msg.to / env.to_box), which the hub enqueues
  before any channel routing. The WUI's mention poke is a DM, so it goes too.
  The sweep keeps a post addressed to an agent open.
- **FR-042** Value in force: the channel's own `channels.ai_agents` (rdb 0189;
  NULL = follow), else the workspace default `tenants.settings`
  `channel_ai_agents` (a registered setting, default true), else on. A store
  read error counts as on, as before the switch existed.
- **FR-043** Wire: `GET /v1/channels/{c}/members` carries
  `"ai_agents_off": true` only while off, so a workspace without the setting
  answers byte for byte as before. `PUT /v1/channels/{c}/ai-agents
  {"on": true|false|null}` (null = back to the workspace default) answers
  `{channel, on, ai_agents_off}`; the channel's creator or a workspace admin
  (`tenant.settings`) may, anyone else 403.
- **FR-044** WUI: Properties -> Settings shows the switch to every member
  (disabled for those who may not change it, with a line saying who may) and
  what on and off mean; Properties -> Agents says when the agents are off.
- **FR-045** The workspace default and a channel's own value are set by the
  named action `do_spl_channel_ai_agents` (csi-spl-orc): `ENV=<env>
  TENANT_ID=<t> AI_AGENTS=on|off|default [CHANNEL=<c>] DRY_RUN=0`. Setting
  `ai_agents_at` with a channel's value makes the sweep's delta read re-read
  that channel; a workspace default change is seen at the next full read.

Proof: `internal/hub/channel_ai_agents_test.go` (memory and Postgres): a
workspace without the setting delivers to the member agent with no new field
on the wire (control); with the default off, the channel post reaches neither
the member agent nor the responder (a channel with no agent), while a DM and an
`@GRK-36 ...` post in the same channel do; the channel's own switch on
delivers again; a non-owner member is refused. Each gate removed turns it red.
`internal/store/channel_ai_agents_test.go` (both drivers, tenant isolation),
`csi-spl-orc` `unanswered-sweep-pg.tst.sh` case 8, `adhoc-harvest-actions.tst.sh`
2f.

- **FR-046** Humans-only channel (SPL-2423, owner HUM-10 2026-10-17, t1
  ccb3d037 poll answer A): when a person's remove leaves a channel with no
  agent, the hub marks it humans-only (`channels.humans_only_at`, rdb 0206);
  a person's invite of an agent clears it, nothing else writes it. Marked, no
  agent is a member, reads or posts there: no fan-out, queued row, back-fill
  or fallback, an `@agent` send is stored as a plain post, an agent's post is
  refused (`#lobby` too), members GET carries `"humans_only": true`, and the
  automatic joins (`do_spl_dispatch_subscribe`) and the unanswered sweep skip
  it. Proof: `internal/hub/channel_humans_only_test.go`.
- **FR-047** The hub refuses a broken poll form (SPL-3203, owner HUM-10
  2026-10-24, t1 8f476aa8 msg 64f8633b, csitea 348d8011 msg 27761df2): a box
  send (`spool send`, the MCP `spool_send`, the desk actions: every agent
  post) whose `poll` block the WUI would show as a code block, not a form, is
  refused `422 poll_not_a_form` and nothing is stored; the detail is
  pollProblems' lines (how-to-post section 7). A body with no `poll` block
  and a sealed (v:3) body pass unchanged; browser posts (`wui.go`) and
  edits are not checked. The rule is a Go port of `readPoll` /
  `pollProblems` (`csi-spl-wui/src/utils/poll.mjs`, option keys 1-8 since
  SPL-3202): `internal/pollform`, held equal to the JS by the shared case
  file `internal/pollform/testdata/poll-form-cases.json` (each body with the
  JS's exact problem lines). Why the hub: the send check of the desk actions
  (SPL-3062) ran only when the sender's tree had it. Measured on prd
  2026-10-24 00:00-09:26Z: 11 agent posts carried a `poll` block, 3 were no
  form under the 1-3 key rule (keys `NONE`/`LATER`, `DROP`, `K180`), all 11
  are forms under 1-8. Proof: `internal/pollform/pollform_test.go`,
  `internal/hub/poll_not_a_form_test.go` (memory and Postgres).

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
