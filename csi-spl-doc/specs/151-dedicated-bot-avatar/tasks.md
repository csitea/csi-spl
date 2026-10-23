# Tasks: Spec 151 — dedicated bots: add agents to a DM, blobatar avatar

Status vocabulary:

- `Planned`: nothing is built yet.
- `Partial`: some of it exists.
- `Implemented`: the artifact exists and its check passes.

Status: **v0.2, owner go d6d5009c; build in progress**. Requirements and
cases are in [spec.md](spec.md). Epic SPL-3030.

v0.2 (SPL-3057) folds the owner's answers: Q1 = A (msg `5ba9b628`, the
agent joins the same DM), Q2 = B (msg `d6d5009c`, the blobatar only in the
channels and DMs the bot was added to, the robot everywhere else) and his go
(msg `d6d5009c`). Q2 = B reworks T007 and T008, and moves the avatar scope
type into T003 so that T004 can use it without sharing a file with T008.

Each row is one small lane, and no two rows touch the same file, with one
exception: T005 reviews the locale files T004 wrote, so it runs after T004 lands. The order
is: part 1 before part 2, the API before the WUI, and the docs last.

## 1. Part 1: add agents to a direct message

| ID | Status | Area | Task |
|---|---|---|---|
| **T001** | **Planned** | `rdb`/`api` | **Store the agents added to a DM** (spec 4.1). Files: rdb migration `NNNN_dm_agents.sql` (next free number); new `store/dm_agents.go` and `store/dm_agents_postgres.go` (methods `AddDMAgent`, `RemoveDMAgent`, `DMAgents`); the `readableBy` case for an added agent's message in `store/view.go` and `store/view_postgres.go`. Gate: case C1, run with `PRE_PUSH_TIER=full`. |
| **T002** | **Planned** | `api` | **Hub routes and delivery for DM agents** (spec 4.1). Files: new `hub/dm_agents.go` (GET, POST, DELETE `/v1/dms/{peer}/agents`, with the channel door's rules); the fan-out to added agents in `hub/ws.go` `commitRowTyped`. Gate: cases C2-C5. Docs: the routes in the channels-v1 / view-v1 contract. |
| **T003** | **Planned** | `wui` | **WUI client calls for DM agents** (spec 4.1). Files: `wui/utils/spool-client-lazy.mjs` and `wui/utils/spool-client.mjs` (`listDmAgents`, `addDmAgent`, `removeDmAgent`, live and mock); `wui/types/mjs-shims.d.ts`; new `wui/utils/avatar-scope.ts` (the `AvatarScope` type, `{channel}` / `{dm: <peer id@box>}`, and its Vue injection key; spec 4.2). Gate: case C6, `pnpm run typecheck`. |
| **T004** | **Planned** | `wui` | **"Add an agent" entry in the DM row menu, and its dialog** (spec 4.1). Files: `wui/utils/sidebar-row-menu.mjs` (`add-agent`); `wui/components/ChannelSidebar.vue` (opens the dialog); new `wui/components/DmAgentsDialog.vue`, which uses `useChannelAgentPick.ts` with the DM calls and provides the avatar scope `{dm: <the row's peer>}` (T003's key) to its agent rows; i18n keys in all 19 locales. Gate: cases C7 and C8, `pnpm run typecheck`, the i18n gates. |
| **T005** | **Planned** | `i18n` | **agy review of the new DM-agent texts in all 19 locales** (the language rule; it lands after T004). Gate: agy's signed review; only the locale files change. |

## 2. Part 2: the blobatar avatar for dedicated bots

| ID | Status | Area | Task |
|---|---|---|---|
| **T006** | **Planned** | `rdb`/`api` | **Record who added a channel agent** (spec 4.2). Files: rdb migration `NNNN_channel_subscription_invited_by.sql`, which backfills `legacy` on non-role invite rows (109 on prd); `store/channels_postgres.go` `InviteChannelAgent` and `ChannelMembers` (`invited_by`, `dedicated`); `hub/channel_members.go` (passes `hum`; members answer `dedicated`). Gate: cases C9 and C10, run with `PRE_PUSH_TIER=full`. |
| **T007** | **Planned** | `api` | **Roster says where each bot is dedicated, per scope** (spec 4.2). Not one flag per agent: `viewBox` gets `agent_dedicated`, agent id -> `{channels: [<channel id>...], dms: [<peer id@box>...]}`, the channels and DM peers it was added to by hand. Filtered per reader: only channels the reader may read, only DMs of which the reader is one end (named by the other end), nothing for a reader with no member session. Files: new `store/agent_dedicated.go` and `store/agent_dedicated_postgres.go` (one query over `channel_subscriptions` with `invited_by` set and `dm_agents`, both `origin = 'invite'`); `hub/view.go` (`viewBox.AgentDedicated`, the per-reader filter next to `lockViewFor`); `hub/view_dedicated_test.go`. Gate: cases C11 and C12 (C12 is the privacy red control), run with `PRE_PUSH_TIER=full`. Docs: the field in the view-v1 contract. |
| **T008** | **Planned** | `wui` | **Blobatar for a bot in the scopes it was added to** (spec 3 and 4.2). The avatar needs the scope it renders in. Files: `csi-spl-wui/package.json` with `"blobatar": "2.7.0"` (exact) and `pnpm-lock.yaml`; `wui/utils/avatar.ts` (`dedicatedAvatarUri`, a lazy `import('blobatar/uri')`, the `id@box` + scope set read from the roster's `agent_dedicated`, the "dedicated in this scope" helper); `wui/components/SpoolAvatar.vue` (optional `scope` prop, else the injected one; reads the roster for a bot drawn in a scope); the sites that know their scope: `wui/pages/channel/[name].vue` (provides `{channel}`), `wui/pages/dm/[peer].vue` (provides `{dm}`), `wui/components/MessageCard.vue` (`msg.channel` when set, `:72` and `:109`), `wui/components/ChannelPropertiesDialog.vue` (provides `{channel}` to its agent rows). Every other site draws the robot and is not edited: `ChannelSidebar.vue` (DM and people rows), `pages/monitoring/boxes/[id].vue`, `pages/issues.vue`, `MentionList.vue` outside a pane; the agents pages draw no avatar. Tests: `tests/unit/feed-avatar.test.mjs`, a new `tests/unit/avatar-scope.test.mjs`, and C15 in an existing e2e file (a new e2e file reddens the shard control). Gate: cases C13-C16 (C14 and C15 are the "same bot, robot in an un-added channel" red controls), `pnpm run typecheck`, and `perf-budget.py bundle` with the same-box A/B. |
| **T009** | **Planned** | `doc` | **SPEC-spool-avatars section 2: the dedicated-bot row** (last). Edit qto doc `7a99eb3d-766d-44fd-9d89-99c577b3c102`, then run `do_spl_doctree_export_md`; the only file that changes is `csi-spl-doc/doc/md/SPEC-spool-avatars.md`. Gate: the export diff shows only the new row and the version line. |

<!-- version: 0.2.0 · updated: 2026-10-23 -->
