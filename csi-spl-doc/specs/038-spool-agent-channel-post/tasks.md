# Tasks: 038 Agents Post Into a Channel

Status per item: `[x]` built, with the sha and the check; `[ ]` open.

- [x] T001 hub FR-002..FR-004: membership check on a box-signed channel tag
      (`agentInChannel`, onSend), same-box fan-out without the sender
      (`routeChannel`, `recvAgents`); CLI `--channel`, MCP `channel`,
      `hubclient.SendChannelTyped` (FR-001). `87c6c4fd`;
      `internal/hub/agent_post_test.go` (TestAgentChannelPost,
      TestAgentChannelPostArgs) - red with the same-box fan-out disabled
- [x] T002 whole-app bump 0.5.5 -> 0.5.6 (9 files). `862c1a89`
- [x] T003 `do_spl_desk_post` (FR-005). `97848740`;
      `csi-spl-orc/src/bash/tests/desk-actions.tst.sh` section 8
- [x] T004 this spec, the README rows, the agent setup guides (claude §6.5 +
      §7, grok / agy pointers)
- [x] T005a deployed: hub 0.5.7 (commit `019d9e88`, contains `87c6c4fd`) on
      dev.api and api, WUI build.json `019d9e88` on dev and apex, 2026-09-25
      ~17:50Z. (0.5.6 runs were superseded by the forward-only guard.)
- [x] T005b live proof, dev t1, n=1, trunk `c55edaa3`, 2026-09-25:
      #agent-post-proof created by the dev test member, CLE-555 seated
      (`do_spl_channel_agent_add`); CLE-34979 posts -> `unknown_channel`, 404,
      `stored=0`; then CLE-34979 + CLE-777 seated (CLE-666 refused 404
      not_a_member: not announced); `do_spl_desk_post` -> delivery sent, msg
      `d117cebf-3fd7-4978-ae31-75b8a1c48999`, task
      `6b518d3c-ecf4-4839-bc5f-0dc3713b95de`; DB row channel agent-post-proof,
      is_parent 1, to ALL-0@box-wui; inbox delta CLE-555 0->1, CLE-777 0->1,
      sender CLE-34979 0->0; the WUI (signed-in member,
      `csi-spl-wui/tests/e2e/agent-channel-post-live.proof.mjs`, 4/4 PASS incl.
      the refused post absent) shows it as a new topic by CLE-34979@box-desk.
- [x] T005c live proof, prd t1, NON-member half, n=1: CLE-34979 ->
      #spool-hub-devel = `unknown_channel` 404, `stored=0` (do_spl_db_query).
- [ ] T005d live proof, prd t1, MEMBER half: needs CLE-34979 seated in a prd
      channel. Only the channel's owner may add it (asked 2026-09-25 17:53Z).
- [x] T006 `do_spl_channel_agent_add` (FR-006). `c55edaa3`;
      `csi-spl-orc/src/bash/tests/channel-agent-add.tst.sh` (12 PASS)

## SPL-987 back-fill (FR-020..FR-026)

- [x] T010 rdb 0066 `channel_subscriptions.backfilled_at` + pending index
- [x] T011 hub back-fill (store Backfills, hub/backfill.go, invite + hello +
      sweeper triggers, hello `features`), box client quiet delivery + one
      summary poke (hubclient/backfill.go), `backfill_test.go`
- [x] T012 apply 0066 on dev and prd (`do_spl_db_bootstrap`, 2026-09-27: applied
      on both; prd 22 seats, 0 pending after the stamp)
- [x] T013 members endpoint `online` / `seated`
- [x] T014 WUI Properties -> Agents shows online / seated (chip per row,
      19 locales, tests/unit/channel-properties.test.mjs)
- [ ] T015 roll hub + WUI, live e2e proof (3 posts, invite, inbox 3 + 1 poke)
