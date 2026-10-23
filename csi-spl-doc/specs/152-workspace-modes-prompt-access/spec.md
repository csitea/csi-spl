# 152 Workspace modes: who may prompt agents, per role

Version v0.2 (2026-10-23). This is step 1 of the owner rule for a big
change: the written spec. Nothing in it is built until the owner has seen
the plan and answered its options (dispatcher answer
`msg:5b071dc7-759d-49b7-8eae-66a243bd74a2`: spec first).

v0.2 folds the panel: EDITOR c-686 (claude) wrote v0.1 (`15a982250`); SEAT 2
c-715 (claude) sent an independent proposal and a 34-row review
(`msg:022c8cb0-b82c-47ce-be80-a6089fef07d8`). Both positions, and what was
taken from each, are in [panel.md](panel.md).

Source: prd topic in the owner's workspace,
`topic:b4af24b2-65ec-4fde-bbaf-6350f24c025b`. Issues: SPL-3053 (this
spec) and epic SPL-3035. Each build row in [tasks.md](tasks.md) gets its
own issue once the owner has answered section 9.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`
- `hub/` = `api/hub/`, `store/` = `api/store/`, `rbac/` = `api/rbac/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`

Every `file:line` was read on origin/master `15a982250`; its code under
api, wui, orc and rdb equals v0.1's `fa817cee2`
(`git diff --stat fa817cee2 15a982250 -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-rdb`
prints nothing).

## 1. The owner's asks, verbatim

Owner HUM-10, 2026-10-23 UTC, in the topic above:

- `2c890f3f` (11:08Z): "we need the feature for access control for
  prompting .."
- `219f0105` (11:0xZ): "somthing like on certain modes - ageile ,
  corporate etc. the AC would work for different roles differnetly"

Read: a workspace has a MODE (agile, corporate, ...). The mode decides, per
ROLE, who may prompt agents and how.

## 2. What exists on master

### 2.1 Roles and the one prompting permission

- A member holds a SET of roles; the hub asks for a permission, never a
  role name (`rbac/rbac.go:1-8`, `rbac/rbac.go:187-197`; rdb
  `0021_tenant_rbac.sql`, `0201_tenant_member_roles.sql`).
- The member roles: `biz_owner`, `product_owner`, `admin`, `developer`,
  `tester`, `pure_agent`, `biz_customer`, `regular_user`
  (`rbac/rbac.go:63-70`, `RoleIDs` at `rbac/rbac.go:88`; the WUI copy
  `wui/utils/access.mjs:15`). Two exclusive non-member roles: `demo_user`
  (the open demo workspace) and `channel_guest` (a website visitor in one
  channel) (`rbac/rbac.go:71-85`). The legacy input names `owner` and
  `member` map to `biz_owner` and `developer` (`rbac/rbac.go:172-180`).
- Role grants are global, not per workspace: `rbac_role_permissions` has no
  tenant column (`rdb/0021_tenant_rbac.sql:37-41`), and no hub route writes
  a grant. A workspace admin changes only a member's role SET
  (`members.roles`).
- Prompting an agent is ONE permission today, `agents.command`
  ("command an agent through box-wui dispatch", `rbac/rbac.go:22`,
  `rbac/rbac.go:107`). The seed grants it to every member role except
  `tester` (`rbac/rbac.go:138-153`).
- Where the hub checks it (all on a person's browser send, `wuiSend`,
  `hub/wui.go:571`), through `s.allowed` -> `s.access`
  (`hub/rbac.go:45-69`):

| send | check | refused how | where |
|---|---|---|---|
| DM to an agent, `@agent ...` dispatch | `agents.command` | 403 `forbidden` | `hub/wui.go:830-845` (perm at `:838-839`; a door-off guest, `c.member == ""`, is not checked, `:841`) |
| plain channel post (fan-out to the channel's agent members) | `agents.command` | NOT refused: stored and shown, no box delivery | `hub/wui.go:715-726` (owner rule 2026-09-22), `:769-770` |
| channel-less reply dispatched to the topic's agent | `agents.command` | not dispatched: stays a browser-only post | `hub/topic_reply.go:26-28` |

- The WUI has no pre-check of it:
  `git grep -n "agents.command" origin/master -- csi-spl-wui/src` -> 0
  lines. A refused send is learned from the hub's error frame.
- The member's roles and effective permissions reach the WUI on
  `GET /v1/view/me` (`hub/rbac.go:91-113`, `permissions` at `:101`), which
  already carries one workspace policy, `topic_archive_policy`, from the
  cached tenant row (`hub/rbac.go:108-112`, `:139`).

### 2.2 The per-agent sender allow-list (SPL-1018)

Contract `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md`,
rdb `0188_agent_sender_allow.sql`, hub `hub/sender_allow.go`, store
`store/sender_allow.go`, WUI `wui/components/AgentSenders.vue`.

- One list per agent per workspace, of members by HUM id; no list = every
  member, an empty list = nobody (contract `:8-17`).
- Covers a DM, an `@agent` dispatch, a bare `@agent` anywhere in the body and
  a channel-less reply dispatched to an agent; NOT a channel post that names
  no agent (contract `:19-41`, the fan-out row at `:30`; targets
  `hub/sender_allow.go:219-241`). An edit is not re-checked; a mention added
  by an edit pokes through the WUI's mention DM, which is (contract
  `:39-41`).
- Runs only on a person's send; agents (orchestrator and dispatcher seats
  included) are never blocked from each other (`hub/sender_allow.go:35-39`,
  `:247-250`).
- Refusal: 403 `sender_not_allowed`, nothing stored, the frame names the
  agent (`hub/sender_allow.go:41-42`, `:268-271`, `:274-290`); the WUI line
  `composer.send_failed_not_allowed` (`wui/utils/send-failure.mjs:90`,
  `csi-spl-wui/i18n/locales/en.json:654`).
- Edited by `tenant.settings` holders (biz_owner, admin) in Workspace
  settings -> Agents (`wui/pages/tenant-settings/agents.vue:46`, `:148`;
  `wui/components/AgentSenders.vue:1-7`); a list of an agent on a box
  locked to someone else is that person's to set
  (`hub/sender_allow.go:168-178`).
- Order in `wuiSend`: route (`agents.command`, `hub/wui.go:589`), then the
  allow-list (`:593-595`), then the demo, admit, token-budget and audit
  checks (`:596-611`).

### 2.3 Channels, agents in them, and the mention poke

- A channel's agents get every person's post (fan-out) when the poster
  holds `agents.command` (2.1).
- The per-channel "AI agents" switch: off = no fan-out, a DM and an
  `@agent` dispatch still go (`store/channel_ai_agents.go:11-27`, rdb
  `0189_channel_ai_agents.sql`); its workspace default is the
  `channel_ai_agents` settings key.
- Humans-only channel: once people removed every agent, an `@agent` there is
  a plain post (`hub/wui.go:733`, `hub/channel_humans_only.go:33`, rdb
  `0206_channel_humans_only.sql`).
- The mention poke: for each extra agent a post @mentions, the WUI sends a
  DM in a NEW task carrying `ref_task_id` = the topic it is about
  (`wui/composables/useMentionPoke.ts:86-91`; the hub reads it at
  `hub/wui.go:136`, `:620`).

### 2.4 Who may start new work today

There is no hub concept of "new work". The orchestrator and dispatcher seats
(OD) are members of every channel
(`csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:3-16`), so any
person's channel post that fans out reaches them, and they decide what to
spawn. A post fans out exactly when its poster holds `agents.command`
(2.1). So today every member role but `tester` may start new work in any
channel it can post in. Because OD seats are in every channel, EVERY new
channel topic by such a member reaches an agent, "lunch at 12?" in #lobby
included.

### 2.5 Workspace settings, and no mode yet

- Generic workspace settings: `tenants.settings` jsonb (rdb
  `0136_tenant_settings_jsonb.sql`); a key is a `RegisterTenantSetting`
  call with its kind, default, `OneOf`, `MaxLen` and `Valid` check, no DDL
  (`store/tenant_kv.go:18-31`, `:57-70`), decoded once per tenant cache
  fill (`:25-31`). An unknown key is refused 400 `bad_setting`
  (`store/tenant_kv.go:123-125` -> `hub/tenant_settings.go:244-245`).
- `GET /v1/tenant/settings` (`hub/tenant_settings.go:92-104`) and
  `PATCH /v1/tenant/settings` (`:106-179`, the permission at `:107`) both
  need `tenant.settings`. The PATCH logs which groups changed, not which
  settings key or its old and new value (`:173-177`).
- No mode-like setting exists:
  `git grep -niE "'agile'|corporate|work_?mode" origin/master -- csi-spl-api csi-spl-wui/src csi-spl-rdb`
  -> 0 lines (on the whole tree: only `LICENSE`, prose docs and a
  `network_mode` in a security doc).

## 3. The design

### 3.1 Four prompting actions

The hub tells them apart on every person's send, from what `wuiRoute`
already resolves:

| id | action | the hub sees |
|---|---|---|
| `dm` | DM an agent | `to` = an agent, no channel, no `ref_task_id` |
| `mention` | address an agent from a topic | a dispatch, a body `@agent` (`sendTargets`), or a DM to an agent that carries `ref_task_id` (the mention poke, 2.3): it is classified by the REFERENCED topic |
| `post` | a channel post that names no agent | the fan-out (`rt.signing.fanOut`) |
| `start` | start new work | a `dm` or `mention` whose topic has no stored message yet; a poke is never a `start` when its referenced topic exists |

New-topic detection is one `EXISTS` probe on `messages (tenant_id,
task_id)`, served by the index `messages_task_received`
(`rdb/0083_messages_task_received_covering.sql:36`), and only on a send that
already addresses an agent. Not `Store.TaskEnvelopes` (it reads every
envelope of the task) and not `is_parent` (absent reads as 1 also for a
post into an existing topic, `hub/wui.go:555-558`).

A NEW channel topic that names no agent is a `post`, never a `start`
(decision D10): refusing it would silence a role for every new
conversation, since OD seats are in every channel (2.4).

### 3.2 The mode catalogue

One workspace setting, `prompt.mode` (string, `OneOf`), registered like
`channel_ai_agents`: no migration.

| mode | for | prompting |
|---|---|---|
| `agile` (default) | a small self-organising team | every role that holds `agents.command` does all four actions: exactly master today |
| `corporate` | a hierarchy: work is started by the people who own it | owners, admins and product owners start work; developers continue it; customers and regular users talk to agents only in a DM |
| `strict` (Q1-B) | one or two people drive the agents, the rest watch and talk | only `biz_owner` and `admin` prompt agents; everyone else's posts are stored and shown |

Rule 1, **a mode only narrows**: the mode is ANDed with `agents.command`
and with the allow-list. A mode never lets a member do what its role set or
a list denies. So `agile` (the unset key) is byte for byte master, and a
`tester` stays out of every mode unless an admin gives that member a second
role that holds `agents.command` (rdb 0201 role set); no admin can change a
role's grants (2.1).

Rule 2, **agents are never blocked**: like the allow-list, the check runs
only on a person's browser send (`isPerson`, `hub/dm_ref.go:99`); box
frames (agents, OD seats) never run it.

Rule 3, **demo, guests and the door-off socket unchanged**: `demo_user` and
`channel_guest` keep their own paths (`hub/demo.go`, spec 121); a door-off
guest (`c.member == ""`, no roles) is not checked for `agents.command`
today (`hub/wui.go:841`), and the mode is not read for it either.

### 3.3 The role x action matrix per mode

`Y` = allowed (when the member holds `agents.command`), `-` = refused for
`dm` / `mention` / `start`, not delivered for `post`.

**agile** (= master):

| role | dm | mention | post | start |
|---|---|---|---|---|
| biz_owner, admin, product_owner, developer, pure_agent, biz_customer, regular_user | Y | Y | Y | Y |
| tester (no `agents.command`) | - | - | - | - |

**corporate**:

| role | dm | mention | post | start |
|---|---|---|---|---|
| biz_owner | Y | Y | Y | Y |
| admin | Y | Y | Y | Y |
| product_owner | Y | Y | Y | Y |
| developer | Y | Y | Y | Q2 |
| pure_agent | Y | Y | Y | Q2 |
| biz_customer | Y | - | - | DM only |
| regular_user | Y | - | - | DM only |
| tester | - | - | - | - |

- "DM only": a `biz_customer` or `regular_user` may open a new DM with an
  agent (their one way to ask), never a channel topic that prompts one, and
  never a mention poke (it is a `mention`, 3.1): an `@agent` added by an
  edit of a plain post goes out as a poke and is refused.
- `pure_agent` has the developer row: it is a person's role (a member who
  works mostly through agents), not a box agent, so the hub sees its sends
  as a person's.

**strict** (if Q1 keeps it):

| role | dm | mention | post | start |
|---|---|---|---|---|
| biz_owner, admin | Y | Y | Y | Y |
| everyone else | - | - | - | - |

A member with several roles gets the union of their rows (the same rule as
permissions, `rbac/rbac.go:187-197`).

### 3.4 The mechanism: derived permission bits, and the allow-list kept

- The matrix is a Go table in `rbac` (mode x role x action -> bool),
  tested exhaustively; no database row.
- `s.access` (`hub/rbac.go:45-59`) adds four DERIVED permissions to the
  member's set: `agents.dm`, `agents.mention`, `agents.post`,
  `agents.start`. A member holds one exactly when it holds
  `agents.command` AND the workspace mode's row of one of its roles allows
  the action. They are computed, never stored: no `rbac_permissions` row,
  no seed change. The tenant row is cached, so this adds no query.
- The three call sites (2.1) ask for the action's bit instead of
  `agents.command`; every later site inherits the mode by asking for a
  bit. `/v1/view/me` already sends `permissions` (`hub/rbac.go:101`), so
  the WUI pre-check reads the effective bits and keeps no copy of the
  matrix in JS.
- The allow-list STAYS as it is, as the second, per-agent layer: the mode
  says which ROLES may prompt, the list says which MEMBERS may reach ONE
  agent. Generating lists from the mode would turn a role rule into member
  rows that go stale on every role change, and would overwrite the admins'
  hand-made lists. Order on a send: route (the action's bit), then the
  allow-list, then the rest of `wuiSend` unchanged. Whether the list also
  gates the fan-out in corporate and strict is Q4.

### 3.5 What a refused prompt shows

- `dm`, `mention`, `start`: refused before anything is stored, with the
  same 403 `sender_not_allowed` frame as the allow-list plus
  `"reason": "prompt_mode"`, `"mode": "<mode>"` and `"permission":
  "agents.<action>"` (025 FR-005 names the missing permission); `agent`
  names the first addressed agent. An old WUI reads the token it already
  knows and shows the existing line. The new WUI line:
  `composer.send_failed_prompt_mode` ("Not sent: in this workspace's
  {mode} mode your role cannot prompt agents this way. Your text is still
  here.").
- `post`, new topic or not: NOT refused, for the owner rule of 2026-09-22
  (`hub/wui.go:715-726`). It is stored and shown and no box delivery is
  built, exactly as for a poster without `agents.command` today; the ack
  carries `"agents_skipped": "prompt_mode"` and the WUI shows a quiet note
  under the sent card (`composer.agents_skipped_prompt_mode`).
- If the owner picks Q2-B (hold) or Q2-C (tag) for a developer's `start`,
  that send is not refused: it is stored and delivered held or tagged, and
  the WUI shows `composer.start_held_prompt_mode` or no note.
- The composer pre-checks from `/v1/view/me`: it gains `prompt_mode` next
  to `topic_archive_policy` (`hub/rbac.go:108-112`; members cannot read
  `GET /v1/tenant/settings`) and its `permissions` carry the bits (3.4).
  It shows `composer.prompt_mode_hint` before a send it knows will be
  refused. The hint never disables Send; the hub decides.

### 3.6 Who may change the mode

`tenant.settings` holders (biz_owner, admin), through the same
`PATCH /v1/tenant/settings {settings: {"prompt.mode": "corporate"}}` as
every other workspace setting (Q3 asks whether it is biz_owner only). A
change takes effect on the next send of every open socket: the check reads
the cached tenant row, as `agents.command` is "checked per send, so a
demotion bites on the open socket too" (`hub/wui.go:826-829`). The PATCH
log line gains the settings keys it changed and the old -> new mode
(today it logs `settings` as one bool, `hub/tenant_settings.go:173-177`).

### 3.7 Data change

None, for every answer to Q1:

- `prompt.mode`: one registered `tenants.settings` key.
- Q1-C (a custom mode): one more key, `prompt.custom`, a `SettingString`
  with a `Valid` check and its own `MaxLen`, holding the 8 roles x 4
  actions as `dm=biz_owner,admin;mention=...` (`store/tenant_kv.go:57-69`).
  32 booleans need no table, no RLS policy and no migration.

### 3.8 API and WUI sites

| site | change |
|---|---|
| `store/prompt_mode.go` (new) | `RegisterTenantSetting{Key: "prompt.mode", Kind: SettingString, Default: "agile", OneOf: [...]}` (and `prompt.custom` on Q1-C); `Tenant.PromptMode()` |
| `rbac/prompt_mode.go` (new) | the matrix and the four derived permission ids; `PromptAllows(mode, roles, action) bool` |
| `hub/rbac.go:45-59` | `s.access` adds the derived bits; `:101`, `:108-112`, `:139` `meBody.PromptMode` |
| `hub/prompt_mode.go` (new) | the action of a send (3.1), the new-topic probe, the refusal frame or the fan-out skip |
| `hub/wui.go:838-839`, `:769-770`, `hub/topic_reply.go:28` | ask for the action's bit |
| `hub/sender_allow.go:277-280` | `wuiErrAgent` gains `reason`, `mode`, `permission` |
| `hub/tenant_settings.go:173-177` | the log line names the keys and the old -> new mode |
| `wui/pages/tenant-settings/agents.vue` | a "Prompting mode" section above the allow-list: the modes as radios, each with its matrix as a small table |
| `wui/utils/send-failure.mjs:90` | `reason: prompt_mode` -> the new line |
| `wui/components/ComposerStatusLine.vue` | the pre-send hint and the skipped note |
| `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md` | a section "the mode comes first" |

### 3.9 i18n

New keys in `csi-spl-wui/i18n/locales/en.json` and the other 18 locale files
(`ls csi-spl-wui/i18n/locales | wc -l` -> 19), translated, not English
copies (the `i18n-untranslated` ratchet):

- `tenant_settings.prompt_mode.title`, `.hint`, `.agile`, `.agile_hint`,
  `.corporate`, `.corporate_hint`, `.strict`, `.strict_hint`, `.saved`,
  `.matrix_dm`, `.matrix_mention`, `.matrix_post`, `.matrix_start`
- `composer.send_failed_prompt_mode`, `composer.agents_skipped_prompt_mode`,
  `composer.prompt_mode_hint`, and on Q2-B `composer.start_held_prompt_mode`

agy reviews every locale as the LAST step before the WUI rows ship (fleet
language rule).

## 4. Red controls

Each `R` case FAILS on master `15a982250` today and passes once its row
lands; a case marked (C) is a control that passes on both. "c-007" is any
agent member of the channel.

| # | case | master today | expected |
|---|---|---|---|
| R1 | `PATCH /v1/tenant/settings {settings:{"prompt.mode":"corporate"}}` as admin | 400 `bad_setting` (unknown key) | 200, `GET` returns it |
| R2 | the same PATCH as a `developer` | 403 `forbidden` | 403 `forbidden` (C) |
| R3 | corporate: a `developer` opens a NEW channel topic `@c-007 build x` | delivered, ack has `to_box` | Q2-A: 403 `sender_not_allowed`, `reason: prompt_mode`, nothing stored (Q2-B / C: held / tagged) |
| R4 | corporate: the same developer replies `@c-007 ...` in an EXISTING topic | delivered | delivered (C) |
| R5 | corporate: a `product_owner` opens a new topic `@c-007 ...` | delivered | delivered (C) |
| R6 | corporate: a `regular_user` posts `@c-007 ...` in a channel | delivered | 403 `sender_not_allowed`, `reason: prompt_mode` |
| R7 | corporate: a `biz_customer` DMs c-007 | delivered | delivered (C) |
| R8 | corporate: a `biz_customer` plain post in an existing topic of a channel with agent members | fan-out delivery built | stored, no box delivery, ack `agents_skipped: prompt_mode` |
| R9 | strict: a `developer` DMs c-007 | delivered | 403 `reason: prompt_mode` |
| R10 | corporate, c-007's allow-list without the product_owner: PO `@c-007` | 403 `sender_not_allowed` (list) | 403, no `reason` (the list refused) (C) |
| R11 | the key unset (agile): `go test ./internal/hub/ -run 'SenderAllow\|WUI\|Wui' -count=1 -v`, memory store | 59 PASS, n=1 run on `15a982250` | the same 59 PASS (C, byte for byte) |
| R12 | a box frame from c-001 to c-007 in corporate | delivered | delivered (C: agents never blocked) |
| R13 | `GET /v1/view/me` of a corporate developer | no `prompt_mode`, no `agents.start` bit | `"prompt_mode": "corporate"`, `permissions` without `agents.start` |
| R14 | WUI: Workspace settings -> Agents shows `data-test="tenant-prompt-mode"` with the mode radios | absent | present; a click PATCHes the key |
| R15 | WUI: a `reason: prompt_mode` frame shows `composer.send_failed_prompt_mode` | shows the allow-list line | the mode line |
| R16 | i18n parity: the new keys in all 19 locales | missing | present, the `i18n-untranslated` count not raised |
| R17 | corporate: a `developer` opens a NEW #lobby topic "lunch at 12?" (no @) | fan-out delivery built (OD seats) | stored, no box delivery, `agents_skipped: prompt_mode`; never refused |
| R18 | corporate: a `developer` in an existing topic mentions a second agent; the WUI's poke DM (new task, `ref_task_id` = that topic) | delivered | delivered: a `mention` of an existing topic, not a `start` |
| R19 | corporate: a `biz_customer` edits a stored plain post to add `@c-007`; the poke DM goes out | delivered | 403 `reason: prompt_mode` (a `mention`) |
| R20 | corporate, view door off: a door-off guest socket sends `@c-007 ...` | delivered | delivered (C: the mode is not read, rule 3) |

## 5. Rollout

Additive and off by default: an unset `prompt.mode` is `agile` = master.
Build order: store key and matrix (T1) -> hub (T2, T3) -> WUI (T4, T5) ->
docs (T6). The hub rows deploy before the WUI rows; a hub with the check
and an old WUI already enforces the mode and shows the old allow-list
line.

## 6. Out of scope

- Per-channel modes (a mode is per workspace).
- Agents prompting agents (never gated, rule 2).
- New roles, and per-workspace role grants: the matrix uses the eight
  member roles and the global grants as they are.

## 7. Risks

- The new-topic probe is one indexed `EXISTS` per send that addresses an
  agent (3.1). T2 measures the hub's send p95 on dev before and after, with
  n, before T3 wires the fan-out.
- A WUI pre-check from a stale `/v1/view/me` could warn a member just
  promoted: the hint never disables Send, the hub decides.
- The derived bits ride `s.access`, which every member route calls: T2
  proves with the round-trip counting test (`TestRoundTripsPerRequest`)
  that it adds no query.

## 8. Decisions settled from the code

| # | decision | evidence | from |
|---|---|---|---|
| D1 | The mode is a `tenants.settings` key, no migration | `store/tenant_kv.go:18-31` (spec 098: a setting is a registry call) | both |
| D2 | A mode only narrows; `agile` = master | `agents.command` is the one gate today (2.1); a widening mode would bypass the role set | both |
| D3 | Keep the allow-list, after the mode | different subjects: roles vs the members of one agent (2.2) | both |
| D4 | Reuse 403 `sender_not_allowed` + `reason`, `mode`, `permission` | old WUIs keep working (`wui/utils/send-failure.mjs:90`); 025 FR-005 names the permission | both |
| D5 | A plain post, new topic or not, is never refused, only not delivered | owner rule `hub/wui.go:715-726`; OD seats in every channel (2.4) | seat 2 (review 17) |
| D6 | Box frames are never checked | `hub/sender_allow.go:35-39` | both |
| D7 | The WUI reads the mode and the bits from `/v1/view/me` | `GET /v1/tenant/settings` needs `tenant.settings` (`hub/tenant_settings.go:92-96`); precedent `topic_archive_policy` (`hub/rbac.go:108-112`) | both |
| D8 | The mode is four derived permission bits in `s.access`, not a separate check | 3 call sites inherit it; `/v1/view/me` ships the bits (`hub/rbac.go:101`) | seat 2 (D-A) |
| D9 | A mention poke (DM + `ref_task_id`) is a `mention` of the referenced topic | `wui/composables/useMentionPoke.ts:86-91`; closes the edit bypass (contract `:39-41`) | seat 2 (review 15) |
| D10 | `start` covers only a send that addresses an agent; detected by `EXISTS` on `messages_task_received` | `rdb/0083_messages_task_received_covering.sql:36`; `is_parent` cannot (`hub/wui.go:555-558`) | seat 2 (review 14, 17) |
| D11 | A custom mode (Q1-C) is one more settings key, no table | 32 booleans fit `SettingString` + `Valid` (`store/tenant_kv.go:57-69`) | seat 2 (1.5) |
| D12 | A mode change is logged with its keys and old -> new value | today one bool (`hub/tenant_settings.go:173-177`) | seat 2 (1.6) |
| D13 | Door-off guests are not read for the mode | `hub/wui.go:841` | seat 2 (review 19) |

## 9. Owner questions

Four questions; each is one form. Q3: both seats recommend A. Q1 and Q4:
the editor's recommendation; seat 2 named none. Q2: the seats differ, both
recommendations are marked.

```poll
Q1. Which modes should a workspace be able to pick?
(A) Agile and corporate (recommended: the two you named, the smallest build)
(B) Agile, corporate and strict, where only owners and admins prompt agents
(C) Agile and corporate, plus a custom mode whose role table each workspace admin ticks (one more settings key and a table editor, still no migration)
```

```poll
Q2. In corporate mode, what happens when a developer starts new work (a new topic or DM that prompts an agent)?
(A) Refused: product owners, admins and owners start work, developers continue it (recommended by the editor: clear and cheapest)
(B) Held: the agent gets it only after a product owner, admin or owner approves it with one click (a hold state and an approve button)
(C) Delivered, tagged so the dispatcher files it as an issue waiting for a product owner (recommended by seat 2: nothing bounces, one envelope field)
(D) Allowed: corporate limits only customers and regular users
```

```poll
Q3. Who may change a workspace's mode?
(A) Owners and admins, like every other workspace setting (recommended: no new permission)
(B) The workspace owner (biz_owner) only
```

```poll
Q4. Today a member left off an agent's allow-list still reaches it by a plain channel post (no @). In corporate and strict, should the list also stop that?
(A) No, keep your earlier decision: the list covers DMs and mentions only (recommended: one rule in every mode)
(B) Yes: in corporate and strict, the agent does not get plain posts from members off its list
```
