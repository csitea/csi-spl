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
- [x] T015 roll hub + WUI, live e2e proof (3 posts, invite, inbox 3 + 1 poke).
      Hub 0.9.8 = 8514554b on dev and prd (run 36307389746, ROLLED true on
      both); WUI build.json ea67bc8b on dev and prd (run 36307367903).
      `do_spl_backfill_probe` (20e32990), n=1 per env, both PASS:
      dev t1 #bf-probe-20260927085931 and prd e2e #bf-probe-20260927090004:
      PRB-9872 inbox_new 3 (every posted msg_id present), pokes 1, line
      "added to #<ch>: 3 earlier messages in 3 topics, newest from PRB-9871";
      the re-invite added nothing. Desk sidecars: dev t1 and prd t1 restarted
      on the rebuilt binary by the reconcile cron (12:00 / 12:02 EEST); the
      prd csi-rel / leiden / csitea desk sidecars still run the pre-SPL-987
      binary, so seats on them stay owed until those restart (FR-024).

## SPL-997 fallback responder (FR-030..FR-038)

- [x] T020 measure the before number (prd, 7 days to 2026-09-27 10:16Z):
      t1 30/289, csi-rel 14/14 (all unsigned), e2e 90/120; all 134/423 human
      posts reached no agent box
- [x] T021 rdb 0067 `tenants.responders` + `fallback_deliveries` (RLS 0021
      form, crosstenant seed), applied on dev and prd 2026-09-27
      (`do_spl_db_bootstrap`: "applied 0067_tenant_fallback_responders.sql")
- [x] T022 hub fallback (`hub/fallback.go`, wuiSend hook, members `fallback`),
      box client `fallback` frame + one poke (`hubclient/fallback.go`),
      `fallback_test.go` 6 tests, memory + Postgres; control = feature off
      reaches nobody. `688aedea`
- [x] T023 `do_spl_tenant_responders` + adhoc-harvest-actions.tst.sh 2d.
      `72af55d9`
- [x] T024 WUI Properties -> Agents "fallback responder" line (both agent
      lists, 19 locales, channel-properties.test.mjs). `14c4fab8`
- [x] T025 roll hub + WUI 0.9.9 (`9f8c8cc6`): hub /version on
      dev.api.spool-hub.ai and api.spool-hub.ai = 0.9.9 / 9f8c8cc6 (run
      36313246355, success); WUI build.json on dev and prd = 953f2a4d, which
      contains 14c4fab8 (run 36313768039). t1 responders = CLE-001 on dev and
      prd. The t1 box-desk sidecars (dev pid started 13:50, prd 13:47 EEST)
      run binaries built from 953f2a4d / 56864629, both containing 688aedea,
      so their hello says `fallback`.
- [x] T026 live e2e, prd e2e, n=1 (`do_spl_fallback_probe`, `42c3788e`):
      #fb-probe-20260927104957 (no agent) -> PRB-9973 (the tenant's
      responder) got msg 8091ef8b in 0.22 s with one poke "unanswered post in
      #fb-probe-20260927104957 (no member agent online): SPL-997 fallback
      probe: ..."; control #fb-ctrl-20260927104957 with PRB-9974 seated and
      online -> PRB-9974 got b4c32d8e, no fallback (DB: fallback_deliveries 1
      row for the post, deliveries box-fbprobe sent; 0 rows for the control).
      After (prd, human posts since the roll at 10:50Z): 2 posts, 0 reached
      no agent box (1 of them via the fallback); before: 134/423 in 7 days.
- [x] T027 FR-039 per-channel opt-out (CLE-001 after go-live: proof posts in
      dev t1 #live-proof poked the responder). rdb 0068 `channels.no_fallback`
      applied dev + prd; hub `2e414626` (TestFallbackChannelOptOut, memory +
      Postgres); `do_spl_channel_fallback` `38613ef5`; WUI "off for this
      channel" `c6f5e2a2`. Set off on dev t1 #live-proof, #agent-post-proof,
      #bf-probe-20260927085931, #spl72-proof-0926093818 (prd t1 has no
      proof channel). Not proven live: needs an online e2e agent AND the flag;
      the hub test is the proof.
- [x] T028 re-roll to 1.0.0 (`a0480eb9`; 0.9.10 / 0.9.11 broke the odometer
      gate hub-version-digits). Test race fixed `404f32d7` (the hub records a
      fallback after writing the frame; the test now waits for the rows).
      Gate 36316714165 on a0480eb9 = success; hub /version dev + prd = 1.0.0 /
      a0480eb9; WUI build.json dev + prd = a0480eb9. Probe re-run on 1.0.0,
      prd e2e: PASS, 0.17 s, control no fallback (probe box id is now per run:
      a fixed id hit pin_conflict on the second run).
      After (prd, human posts since the roll at 10:50Z, to 12:00Z): t1 7 posts,
      0 reached no agent box (3 via the fallback); csi-rel 3, 0; e2e 7, 5 -
      made while no e2e agent was online, which the rule does not cover.
