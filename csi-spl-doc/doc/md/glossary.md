# Glossary — the app's lingo

The words we use for the things in the spool app, so a spec, a post and the
screen all say the same thing. Each term is taken from what the app itself
shows (its English labels, `csi-spl-wui/i18n/locales/en.json`) or from the code
name behind it (component, store, route, action). The **Source** column cites
the key or file, so a row can be checked with one grep.

Why it exists: the card right-click menu change (t1 topic `c15b557e`, "Open
parent section" becomes "Open in channels view" / "Open in direct msg view")
needed shared words for card, topic, reply, section, DM and channel. The
owner's conclusion there: say **topic message** and **reply**. Discussion of
this doc: t1 #spool-hub-ops topic `6e61fb91`. In the app, a topic opens at
`/t/<topic id>`.

## 1. Terms

| Term | What it is | Where it shows in the app | NOT to be confused with | Source |
|---|---|---|---|---|
| **workspace** (code: **tenant**) | One customer's own space: its members, channels, DMs and agents. Ids look like `t1`. | Top bar and left panel label "Workspace"; Workspace settings; each workspace has its own host `<tenant>.<domain>` | a channel; a box | `sidebar.tenant`, `tenant_settings.title`; code `TENANT_ID`, `pages/tenant-settings/`, `TopBarTenant.vue` |
| **channel** | A named, shared conversation inside a workspace, e.g. `#spool-hub-ops`. Holds topics. | Left panel "Channels"; `/channel/<name>` | a DM; a section | `sidebar.channels`; `pages/channel/[name].vue`, `stores/channel.ts` |
| **lobby** | The workspace's default channel, the one everyone lands in. | Left panel "Lobby"; `/lobby` | Flow | `nav.lobby`; `pages/lobby.vue` |
| **DM / direct message** | A one-to-one conversation with a person or an agent. It holds topics too, like a channel. | Left panel "Direct messages"; notifications "DM from …"; `/dm/<peer>` | a channel; a mention | `sidebar.direct_messages`, `notify.title_dm`; `pages/dm/[peer].vue` |
| **section** | One entry of the left panel's icon row (the rail): Flow, Channels, Direct messages, Issues, Archive, People, Agents, Boxes, Help, Workspace settings. On a phone, the "section strip". | Rail icons; "Drag the section icon …"; a section's own page has a close X | the old menu item "Open parent section", which meant the card's **channel or DM**, not a section. Avoid "section" for a channel or DM. | `sidebar.help.people`; `utils/section-strip.mjs`, `SectionClose.vue` |
| **topic** | A conversation inside a channel or DM: a topic message plus its replies. Its id (`task_id`) is the topic id. | Feed rows; "Start topic"; "Open topic"; "Topics"; `/t/<topic id>`, `?topic=<topic id>` | a thread (the same topic, seen open in the pane); a channel | `topic.title`, `composer.go_new`, `feed.open_topic`, `nav.topics`; `pages/t/[task_id].vue`, `stores/topic.ts`, `TopicPane.vue` |
| **topic message** | A topic's **first** message: the one that starts it. The hub stores it as a level-1 message. Archive and Delete act on the whole topic from this card. | The card in the channel/DM feed; "the topic's opening card" / "its first card" | a reply | `feed.topic_delete.error_not_card`; "level-1" in `utils/topic-archive.mjs`, `utils/move.mjs` |
| **reply** | Any message **inside** a topic, after the topic message. People also say **reply message** (the owner's preferred spoken form) and sometimes **thread message**: both mean a reply, never the topic message. | Topic pane "Replies, newest first"; "{n} replies"; menu "Reply"; "Send reply" | a topic message; a DM | `topic.replies_label`, `feed.replies`, `feed.msg_menu.reply`, `composer.go_reply` |
| **thread** | A topic as it reads when **open** in the topic pane: the topic message with its replies under it. "Your threads" are the topics you took part in. | "Expand thread" / "Collapse thread"; "Replying in the open thread"; Flow "Replies in your threads" | a topic in general: prefer "topic" in specs, "thread" only for the open pane | `pane.expand_thread`, `composer.target_thread`, `flow.chip_reply` |
| **card** | One message as drawn on screen: a topic message in the feed, or a reply in the pane. It has the right-click message menu. | Every message; "Card height" setting | a person's / agent's / box's **profile card** ("see their card"); a payment card at checkout | `feed.clip.label`, `feed.msg_menu.label`; `MessageCard.vue`, `MessageMenu.vue` (profile: `people.empty`; payment: `checkout.card_loading`) |
| **kind** | The type tag on a message: task, result, note, reject, blocker, message. | Badge on a card; menu "Change kind" | an issue type (Epic, Issue) | `feed.kind`, `feed.msg_menu.kind`; `KindBadge.vue` |
| **Flow** | Your personal "for you" stream: mentions, replies in your threads and direct messages, across channels. | Left panel "Flow"; `/` | the lobby; a channel | `sidebar.flow`, `flow.empty_mine`; `pages/index.vue`, `stores/flow.ts` |
| **archive** | Taking a topic (or a channel) out of the live view without deleting it; it can be unarchived. | Menu "Archive" / "Unarchive"; "Archived" badge; the Archive section | delete (gone, with an undo); mute | `feed.msg_menu.archive`, `archive.badge`, `sidebar.archive`, `sidebar.row_menu.archive_channel`; `pages/archive.vue`, `utils/topic-archive.mjs` |
| **pin** | Keeping a person or bot row at the top of the left panel's Direct messages, above the most-recent order. Today it is held only in the page: a reload forgets it (the Channels order, by contrast, is saved to your account). | DM row menu "Pin" / "Unpin" | a **key pin** (`spool hub-pin`, a box key trusted by the hub); the **pinned root** of an open topic in `stores/topic.ts` | `sidebar.row_menu.pin`, `sidebar.help.direct_messages`; `SidebarRowMenu.vue` |
| **member** | A person who belongs to a workspace (with a role). A **channel** member is a person or agent added to one channel. | "Members" in Workspace settings; "Member since"; channel Properties → Agents | a box; a person who is only mentioned | `tenant_settings.members`, `people.member`, `users.since`, `channels.properties.agents_tab` |
| **agent** | A bot that reads and posts messages: Claude, Antigravity, Grok or Qwen. Has an agent id (e.g. `CLE-00`). | Left panel "Agents"; agent card; "AI agent" | a person; a box (where it runs) | `sidebar.agents`, `agents.kinds`, `feed.ai.title`; `pages/agents/` |
| **box** | A machine that agents run on and send from. | Left panel "Boxes"; box card: who is seated there, online or not | a workspace; a desk | `sidebar.boxes`, `sidebar.help.boxes`; `pages/boxes/` |
| **desk** | The seat that connects an agent already running in a terminal pane to a workspace, so people can DM it from the app. Not a label in the app. | Nowhere on screen: you see the agent and its box | a box (the desk lives on one); a channel | `csi-spl-orc/src/bash/run/spl-desk-up.func.sh`, `do_spl_desk_post` / `do_spl_desk_reply` |
| **Seen** | The responder's one automatic reply in a topic ("Seen: routed to the team"), at most once per topic. | A reply card from the responder agent | the read marks (what you have read; code field `Seen`, a reply count); "last seen" on a person's card | `csi-spl-orc/src/bash/run/spl-responder-run.func.sh`; not to be confused: `csi-spl-api/src/go/spool-hub-api/internal/store/read_marks.go`, `sidebar.help.people` |
| **issue** | A tracked work item (Epic, Issue, subtask), with its own discussion topic. | Left panel "Issues"; `/issues` | a topic of kind task | `sidebar.issues`; `pages/issues.vue` |

## 2. Say it this way

- **topic message** for the first message, **reply** for the rest. Not "root",
  "parent", "post" or "starting msg".
- **reply message** (preferred) or **thread message** is what people say for a
  **reply**; both mean the reply, not the topic message. In writing, **reply**
  or **reply message**; avoid "thread message" (topic `b6253a70`).
- **channel** or **DM** for where a topic lives. Not "section": a section is a
  left-panel entry.
- **topic** in specs; **thread** only when you mean the topic open in the pane.
- **card** for a message on screen; say **profile card** for a person's,
  agent's or box's card.
- **workspace** in anything a user reads; **tenant** only in code and cnf.

## 3. Open questions

- The menu item behind `feed.msg_menu.open_parent` still reads "Open parent
  section"; the c-084 lane replaces it ("Open in channels view" / "Open in
  direct msg view"). Once that lands, the section row's note can go.
- Should a DM pin be saved to the account like the Channels order? (asked in `6e61fb91` with the "What is the pin?" answer)
- Owner answers to "anything you call differently?" in topic `6e61fb91` are
  folded in here as they come.
