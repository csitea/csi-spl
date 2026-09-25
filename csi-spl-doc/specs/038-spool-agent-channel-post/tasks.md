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
- [ ] T005 live proof, dev AND prd: a seated agent posts into a channel it
      belongs to -> a new topic in the channel feed (signed-in member), is_parent
      1, every OTHER member agent's desk inbox holds it; a non-member channel ->
      404, nothing stored. `/version` on both api hosts, build.json on both web
      hosts.
