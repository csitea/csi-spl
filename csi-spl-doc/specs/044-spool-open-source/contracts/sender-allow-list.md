# Contract: the per-agent sender allow-list (FR-OS-017, SPL-1018)

Owner HUM-10, t1 `dee4081d`, msg `e9ec66fa` ("Ok" to the picks of
`873c8aa0`), recorded as D12 in [spec.md](../spec.md) section 6.1. Store:
rdb `0188_agent_sender_allow.sql`. Hub: `internal/hub/sender_allow.go`. WUI:
`src/components/AgentSenders.vue` (Workspace settings -> Agents).

## 1. What a list is

- One list per agent per workspace, keyed by the agent's bare id (`c-001`,
  not `c-001@sat`): the same list whichever box the agent is seated on.
- A list holds members of the workspace, by HUM id. A member who leaves the
  workspace leaves every list (the FK cascades); the list itself stays.
- **No list** = every member may message the agent (the behaviour before
  rdb 0188). **An empty list** = no member may. The two are different rows
  (`agent_sender_lists` without `agent_sender_allow` rows), so removing the
  last member never reopens an agent to everyone.

## 2. What it covers (decision 3)

A person's browser send (the WUI socket `send` frame) is checked when it
addresses an agent:

| the send | covered |
|---|---|
| a DM to the agent (`to` = the agent) | yes |
| `@agent <instructions>` (a dispatch) | yes |
| a bare `@agent` or `... @agent ...` anywhere in the body, `@agent@box` too | yes |
| a reply in a channel-less topic that the hub dispatches to its agent | yes |
| a channel post that @mentions no agent (the fan-out to agent members) | **no** |
| the WUI's mention poke (a DM from the author, spec 042) | yes, as a DM; the post that would trigger it is refused first |

The check runs only when the sender is a person (`HUM-*`, or a door-off
`GST-*`, which is on no list). Every agent, the orchestrator and the
dispatcher seats included, sends over its box (`onSend`), which never runs
this check, and a list can only hold member ids: **agents are never blocked
from each other**.

An edit of a stored message is not re-checked: an edit re-signs the same
envelope to the same box and builds no new delivery; a mention added by an
edit pokes through the WUI's mention DM, which is checked.

## 3. The refusal (decisions 4 and 5)

The send is refused before anything is stored or delivered. The error frame:

```json
{"type": "error", "error": "sender_not_allowed", "status": 403,
 "detail": "c-007 does not take messages from you", "msg_id": "<the send's>",
 "agent": "c-007"}
```

`agent` is the first (sorted) addressed agent whose list does not name the
sender. The WUI shows `composer.send_failed_not_allowed` with `{agent}` under
the composer, keeps the text, and offers Retry.

## 4. The admin routes (decision 1)

All need a member session whose role grants `tenant.settings` (owner, admin);
anyone else is 403 `forbidden`. `{agent}` is normalised (`C-007@sat` ->
`c-007`); a path that names no agent id is 400 `bad_agent`.

| route | body | answer |
|---|---|---|
| `GET /v1/tenant/agent-senders` | - | 200 `{tenant_id, lists: [{agent, members, updated_by, updated_at}]}`, agents sorted; an agent absent here has no list |
| `PUT /v1/tenant/agent-senders/{agent}` | `{members: ["HUM-3", ...]}` (`[]` = nobody) | 200 `{agent, members, updated_by, updated_at}`; members sorted, de-duplicated |
| `DELETE /v1/tenant/agent-senders/{agent}` | - | 204; the agent has no list again |

PUT refusals: 400 `bad_members` (no `members` array, an id that is not
`HUM-n`, more than 500), 400 `not_a_member` (an id not in the workspace;
nothing is written).

## 5. Tests

- Store, memory and Postgres: `internal/store/sender_allow_test.go`
  (`TestSenderAllowLists`); `crosstenant_test.go` seeds both tables.
- Hub: `internal/hub/sender_allow_test.go` - refused / allowed (control) for
  a dispatch, a DM and a mid-text mention; a post without a mention; no list
  allows all; an empty list; admin-only routes.
- WUI: `tests/unit/sender-allow.test.mjs`; e2e
  `tests/e2e/agent-senders.test.mjs` (the editor on the mock bundle).
