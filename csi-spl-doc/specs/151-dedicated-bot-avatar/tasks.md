# Tasks: Spec 151 — dedicated bots: add agents to a DM, blobatar avatar

Status vocabulary:

- `Planned`: nothing is built yet.
- `Partial`: some of it exists.
- `Implemented`: the artifact exists and its check passes.

Status: **v0.1, waiting for the owner's go**. Requirements and cases are in
[spec.md](spec.md). Epic SPL-3030.

Each row is one small lane, and no two rows touch the same file, with one
exception: T005 reviews the locale files T004 wrote, so it runs after T004 lands. The order
is: part 1 before part 2, the API before the WUI, and the docs last.

## 1. Part 1: add agents to a direct message

| ID | Status | Area | Task |
|---|---|---|---|
| **T001** | **Planned** | `rdb`/`api` | **Store the agents added to a DM** (spec 4.1). Files: rdb migration `NNNN_dm_agents.sql` (next free number); new `store/dm_agents.go` and `store/dm_agents_postgres.go` (methods `AddDMAgent`, `RemoveDMAgent`, `DMAgents`); the `readableBy` case for an added agent's message in `store/view.go` and `store/view_postgres.go`. Gate: case C1, run with `PRE_PUSH_TIER=full`. |
| **T002** | **Planned** | `api` | **Hub routes and delivery for DM agents** (spec 4.1). Files: new `hub/dm_agents.go` (GET, POST, DELETE `/v1/dms/{peer}/agents`, with the channel door's rules); the fan-out to added agents in `hub/ws.go` `commitRowTyped`. Gate: cases C2-C5. Docs: the routes in the channels-v1 / view-v1 contract. |
| **T003** | **Planned** | `wui` | **WUI client calls for DM agents** (spec 4.1). Files: `wui/utils/spool-client-lazy.mjs` and `wui/utils/spool-client.mjs` (`listDmAgents`, `addDmAgent`, `removeDmAgent`, live and mock); `wui/types/mjs-shims.d.ts`. Gate: case C6. |
| **T004** | **Planned** | `wui` | **"Add an agent" entry in the DM row menu, and its dialog** (spec 4.1). Files: `wui/utils/sidebar-row-menu.mjs` (`add-agent`); `wui/components/ChannelSidebar.vue` (opens the dialog); new `wui/components/DmAgentsDialog.vue`, which uses `useChannelAgentPick.ts` with the DM calls; i18n keys in all 19 locales. Gate: cases C7 and C8, `pnpm run typecheck`, the i18n gates. |
| **T005** | **Planned** | `i18n` | **agy review of the new DM-agent texts in all 19 locales** (the language rule; it lands after T004). Gate: agy's signed review; only the locale files change. |

## 2. Part 2: the blobatar avatar for dedicated bots

| ID | Status | Area | Task |
|---|---|---|---|
| **T006** | **Planned** | `rdb`/`api` | **Record who added a channel agent** (spec 4.2). Files: rdb migration `NNNN_channel_subscription_invited_by.sql`, which backfills `legacy` on non-role invite rows (109 on prd); `store/channels_postgres.go` `InviteChannelAgent` and `ChannelMembers` (`invited_by`, `dedicated`); `hub/channel_members.go` (passes `hum`; members answer `dedicated`). Gate: cases C9 and C10, run with `PRE_PUSH_TIER=full`. |
| **T007** | **Planned** | `api` | **Roster says which bots are dedicated** (spec 4.2). Files: new `store/agent_dedicated_postgres.go` (one query over `channel_subscriptions` and `dm_agents`); `hub/view.go` `viewBox` gets `agent_dedicated`. Gate: case C11. |
| **T008** | **Planned** | `wui` | **Blobatar default for dedicated bots** (spec 3 and 4.2). Files: `csi-spl-wui/package.json` with `"blobatar": "2.7.0"` (exact) and `pnpm-lock.yaml`; `wui/utils/avatar.ts` (`dedicatedAvatarUri`, a lazy `import('blobatar/uri')`, the dedicated set read from the roster); `wui/components/SpoolAvatar.vue`; `tests/unit/feed-avatar.test.mjs`. Gate: cases C12-C16, `pnpm run typecheck`, and `perf-budget.py bundle` with the same-box A/B. |
| **T009** | **Planned** | `doc` | **SPEC-spool-avatars section 2: the dedicated-bot row** (last). Edit qto doc `7a99eb3d-766d-44fd-9d89-99c577b3c102`, then run `do_spl_doctree_export_md`; the only file that changes is `csi-spl-doc/doc/md/SPEC-spool-avatars.md`. Gate: the export diff shows only the new row and the version line. |

<!-- version: 0.1.0 · updated: 2026-10-23 -->
