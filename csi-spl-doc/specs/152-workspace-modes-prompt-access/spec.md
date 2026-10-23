# 152 Workspace modes: who may prompt agents, per role

Version v0.1 (2026-10-23). This is step 1 of the owner rule for a big
change: the written spec. Nothing in it is built until the owner has seen
the plan and answered its options (dispatcher answer
`msg:5b071dc7-759d-49b7-8eae-66a243bd74a2`: spec first).

Source: prd topic in the owner's workspace,
`topic:b4af24b2-65ec-4fde-bbaf-6350f24c025b`. Issues: SPL-3053 (this
spec) and epic SPL-3035. Each build row in [tasks.md](tasks.md) gets its
own issue once the owner has answered section 9.

Paths used below:

- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`
- `hub/` = `api/hub/`, `store/` = `api/store/`, `rbac/` = `api/rbac/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`

Every `file:line` was read on origin/master `fa817cee2`.

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
- Prompting an agent is ONE permission today, `agents.command`
  ("command an agent through box-wui dispatch", `rbac/rbac.go:22`,
  `rbac/rbac.go:107`). The seed grants it to every member role except
  `tester` (`rbac/rbac.go:138-153`).
- Where the hub checks it (all on a person's browser send, `wuiSend`,
  `hub/wui.go:571`):

| send | check | refused how | where |
|---|---|---|---|
| DM to an agent, `@agent ...` dispatch | `agents.command` | 403 `forbidden` | `hub/wui.go:830-845` (perm at `:838-839`) |
| plain channel post (fan-out to the channel's agent members) | `agents.command` | NOT refused: stored and shown, no box delivery | `hub/wui.go:715-726` (owner rule 2026-09-22), `:769-770` |
| channel-less reply dispatched to the topic's agent | `agents.command` | not dispatched: stays a browser-only post | `hub/topic_reply.go:26-28` |

- The WUI has no pre-check of it:
  `git grep -n "agents.command" origin/master -- csi-spl-wui/src` -> 0
  lines. A refused send is learned from the hub's error frame.
- The member's roles and permissions reach the WUI on `GET /v1/view/me`
  (`hub/rbac.go:91-113`), which already carries one workspace policy,
  `topic_archive_policy`, from the cached tenant row (`hub/rbac.go:108-112`,
  `:139`).

### 2.2 The per-agent sender allow-list (SPL-1018)

Contract `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md`,
rdb `0188_agent_sender_allow.sql`, hub `hub/sender_allow.go`, store
`store/sender_allow.go`, WUI `wui/components/AgentSenders.vue`.

- One list per agent per workspace, of members by HUM id; no list = every
  member, an empty list = nobody (contract `:8-17`).
- Covers a DM, an `@agent` dispatch, a bare `@agent` anywhere in the body and
  a channel-less reply dispatched to an agent; NOT a channel post that names
  no agent (contract `:19-41`; targets `hub/sender_allow.go:219-241`).
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

### 2.3 Channels and agents in them

- A channel's agents get every person's post (fan-out) when the poster
  holds `agents.command` (2.1).
- The per-channel "AI agents" switch: off = no fan-out, a DM and an
  `@agent` dispatch still go (`store/channel_ai_agents.go:11-27`, rdb
  `0189_channel_ai_agents.sql`); its workspace default is the
  `channel_ai_agents` settings key.
- Humans-only channel: once people removed every agent, an `@agent` there is
  a plain post (`hub/wui.go:733`, `hub/channel_humans_only.go:33`, rdb
  `0206_channel_humans_only.sql`).

### 2.4 Who may start new work today

There is no hub concept of "new work". The orchestrator and dispatcher seats
(OD) are members of every channel
(`csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh:3-16`), so any
person's channel post that fans out reaches them, and they decide what to
spawn. A post fans out exactly when its poster holds `agents.command`
(2.1). So today every member role but `tester` may start new work in any
channel it can post in.

### 2.5 Workspace settings, and no mode yet

- Generic workspace settings: `tenants.settings` jsonb (rdb
  `0136_tenant_settings_jsonb.sql`); a key is a `RegisterTenantSetting`
  call with its kind, default and `OneOf` values, no DDL
  (`store/tenant_kv.go:18-31`, `:57-70`). An unknown key is refused 400
  `bad_setting` (`store/tenant_kv.go:123-125`,
  `hub/tenant_settings.go:200-203`). Read and written by
  `GET` / `PATCH /v1/tenant/settings` (`hub/tenant_settings.go:92-105`),
  both under `tenant.settings`.
- No mode-like setting exists:
  `git grep -niE "'agile'|corporate|work_?mode" origin/master -- csi-spl-api csi-spl-wui/src csi-spl-rdb`
  -> 0 lines (on the whole tree: only `LICENSE`, prose docs and a
  `network_mode` in a security doc).

## 3. The design

### 3.1 Four prompting actions

The hub can tell them apart on every person's send, from what `wuiRoute`
already resolves:

| id | action | the hub sees |
|---|---|---|
| `dm` | DM an agent | `to` = an agent, no channel |
| `mention` | `@agent` in a channel or topic | a dispatch, or a body `@agent` (`sendTargets`) |
| `post` | a channel post that names no agent | the fan-out (`rt.signing.fanOut`) |
| `start` | start new work | any of the three above, when the send opens a NEW topic: its task has no stored message yet (`Store.TaskEnvelopes`, `store/store.go:257`) |

A send that is `start` is also one of `dm` / `mention` / `post`; it must
pass both.

### 3.2 The mode catalogue

One workspace setting, `prompt.mode` (string, `OneOf`), registered like
`channel_ai_agents`: no migration for the mode itself.

| mode | for | prompting |
|---|---|---|
| `agile` (default) | a small self-organising team | every role that holds `agents.command` does all four actions: exactly master today |
| `corporate` | a hierarchy: work is started by the people who own it | owners, admins and product owners start work; developers continue it; customers and regular users only DM |
| `owner_only` (proposed, Q1) | one person drives the agents, the rest watch and talk | only `biz_owner` and `admin` prompt agents; everyone else's posts are stored and shown |

Rule 1, **a mode only narrows**: the matrix is ANDed with `agents.command`
and with the allow-list. A mode never lets a role do what its permissions
or a list deny. So `agile` (the unset key) is byte for byte master, and a
`tester` stays out of every mode unless an admin grants it
`agents.command`.

Rule 2, **agents are never blocked**: like the allow-list, the check runs
only on a person's browser send (`isPerson`, `hub/dm_ref.go:99`); box
frames (agents, OD seats) never run it.

Rule 3, **demo and guests unchanged**: `demo_user` and `channel_guest` keep
their own paths (`hub/demo.go`, spec 121); the mode is not read for them.

### 3.3 The role x action matrix per mode

`Y` = allowed (when the role holds `agents.command`), `-` = refused.

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
| developer | Y | Y | Y | - (Q2) |
| pure_agent | Y | Y | Y | - |
| biz_customer | Y | - | - | DM only |
| regular_user | Y | - | - | DM only |
| tester | - | - | - | - |

"DM only": a `biz_customer` or `regular_user` may open a new DM with an
agent (their one way to ask), but not a new channel topic that prompts one.

**owner_only** (if Q1 keeps it):

| role | dm | mention | post | start |
|---|---|---|---|---|
| biz_owner, admin | Y | Y | Y | Y |
| everyone else | - | - | - | - |

A member with several roles gets the union of their rows (the same rule as
permissions, `rbac/rbac.go:187-197`).

### 3.4 The matrix in code, and the allow-list kept

- The matrix is a Go table in a new package `api/promptac` (mode x role x
  action -> bool), tested exhaustively; no database row. A per-workspace
  editable matrix is option Q1-C (a table, 3.7).
- The allow-list STAYS as it is, as the second, per-agent layer: the mode
  says which ROLES may prompt, the list says which MEMBERS may reach ONE
  agent. Generating lists from the mode would turn a role rule into member
  rows that go stale on every role change, and would overwrite the admins'
  hand-made lists. Order on a send: route (`agents.command`), then the
  mode, then the allow-list, then the rest of `wuiSend` unchanged.

### 3.5 What a refused prompt shows

- `dm`, `mention`, `start`: refused before anything is stored, with the
  same 403 `sender_not_allowed` frame as the allow-list plus two fields,
  `"reason": "prompt_mode"` and `"mode": "<mode>"`; `agent` names the first
  addressed agent (empty for a `start` by a plain post). An old WUI reads
  the token it already knows and shows the existing line. The new WUI
  line: `composer.send_failed_prompt_mode` ("Not sent: in this workspace's
  {mode} mode your role cannot prompt agents this way. Your text is still
  here.").
- `post` (a channel post that names no agent, in an existing topic): NOT
  refused, for the owner rule of 2026-09-22 (`hub/wui.go:715-726`:
  refusing it would silence the role in every channel that has agents). It
  is stored and shown and no box delivery is built, exactly as for a poster
  without `agents.command` today; the ack carries
  `"agents_skipped": "prompt_mode"` and the WUI shows a quiet note under the
  sent card (`composer.agents_skipped_prompt_mode`).
- The composer pre-checks: `GET /v1/view/me` gains `prompt_mode` next to
  `topic_archive_policy` (`hub/rbac.go:108-112`; members cannot read
  `GET /v1/tenant/settings`, it needs `tenant.settings`), the WUI already
  has the member's roles, and the composer shows
  `composer.prompt_mode_hint` before a send it knows will be refused. The
  hint never disables Send; the hub decides.

### 3.6 Who may change the mode

`tenant.settings` holders (biz_owner, admin), through the same
`PATCH /v1/tenant/settings {settings: {"prompt.mode": "corporate"}}` as
every other workspace setting (Q3 asks whether it is biz_owner only). A
change takes effect on the next send of every open socket: the check reads
the cached tenant row, as `agents.command` is "checked per send, so a
demotion bites on the open socket too" (`hub/wui.go:826-829`).

### 3.7 Data change

- Q1-A or Q1-B: none. `prompt.mode` is a registered `tenants.settings` key.
- Q1-C (a per-workspace editable matrix): one table, rdb
  `0214_tenant_prompt_matrix.sql` (the number is taken at build time;
  master's last is `0213_box_locks.sql`), one row per (workspace, mode,
  role, action) with `allowed`, RLS like `tenant_agent_caps` (rdb
  `0212_workspace_agent_caps.sql`).

### 3.8 API and WUI sites

| site | change |
|---|---|
| `store/prompt_mode.go` (new) | `RegisterTenantSetting{Key: "prompt.mode", Kind: SettingString, Default: "agile", OneOf: [...]}`; `Tenant.PromptMode()` |
| `api/promptac/` (new) | the matrix; `Allowed(mode, roles, action) bool` |
| `hub/prompt_mode.go` (new) | `promptModeRefusal(ctx, c, m, rt)`: the frame refusal, or the fan-out skip |
| `hub/wui.go:593` | one call before `senderAllowed` |
| `hub/wui.go:769-770`, `hub/topic_reply.go:28` | the fan-out and the topic reply also ask the mode |
| `hub/sender_allow.go:277-280` | `wuiErrAgent` gains `reason`, `mode` |
| `hub/rbac.go:108-112`, `:139` | `meBody.PromptMode` |
| `wui/pages/tenant-settings/agents.vue` | a "Prompting mode" section above the allow-list: the modes as radios, each with its matrix as a small table |
| `wui/utils/send-failure.mjs:90` | `reason: prompt_mode` -> the new line |
| the composer | the pre-send hint (3.5) |
| `csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md` | a section "the mode comes first" |

### 3.9 i18n

New keys in `csi-spl-wui/i18n/locales/en.json` and the other 18 locale files
(`ls csi-spl-wui/i18n/locales | wc -l` -> 19), translated, not English
copies (the `i18n-untranslated` ratchet):

- `tenant_settings.prompt_mode.title`, `.hint`, `.agile`, `.agile_hint`,
  `.corporate`, `.corporate_hint`, `.owner_only`, `.owner_only_hint`,
  `.saved`, `.matrix_dm`, `.matrix_mention`, `.matrix_post`, `.matrix_start`
- `composer.send_failed_prompt_mode`, `composer.agents_skipped_prompt_mode`,
  `composer.prompt_mode_hint`

agy reviews every locale as the LAST step before the WUI row ships (fleet
language rule).

## 4. Red controls

Each `R` case FAILS on master `fa817cee2` today and passes once its row
lands; a case marked (C) is a control that passes on both.

| # | case | master today | expected |
|---|---|---|---|
| R1 | `PATCH /v1/tenant/settings {settings:{"prompt.mode":"corporate"}}` as admin | 400 `bad_setting` (unknown key) | 200, `GET` returns it |
| R2 | the same PATCH as a `developer` | 403 `forbidden` | 403 `forbidden` (C) |
| R3 | corporate: a `developer` opens a NEW channel topic `@c-007 build x` | delivered, ack has `to_box` | 403 `sender_not_allowed`, `reason: prompt_mode`, nothing stored |
| R4 | corporate: the same developer replies `@c-007 ...` in an EXISTING topic | delivered | delivered (C) |
| R5 | corporate: a `product_owner` opens a new topic `@c-007 ...` | delivered | delivered (C) |
| R6 | corporate: a `regular_user` posts `@c-007 ...` in a channel | delivered | 403 `sender_not_allowed`, `reason: prompt_mode` |
| R7 | corporate: a `biz_customer` DMs c-007 | delivered | delivered (C) |
| R8 | corporate: a `biz_customer` plain post in an existing topic of a channel with agent members | fan-out delivery built | stored, no box delivery, ack `agents_skipped: prompt_mode` |
| R9 | owner_only: a `developer` DMs c-007 | delivered | 403 `reason: prompt_mode` |
| R10 | corporate, c-007's allow-list without the product_owner: PO `@c-007` | 403 `sender_not_allowed` (list) | 403, no `reason` (the list refused) (C) |
| R11 | the key unset (agile): `hub/sender_allow_test.go` and the hub's wui send tests | green | green, unchanged (C, byte for byte) |
| R12 | a box frame from c-001 to c-007 in corporate | delivered | delivered (C: agents never blocked) |
| R13 | `GET /v1/view/me` in a corporate workspace | no `prompt_mode` | `"prompt_mode": "corporate"` |
| R14 | WUI: Workspace settings -> Agents shows `data-test="tenant-prompt-mode"` with the mode radios | absent | present; a click PATCHes the key |
| R15 | WUI: a `reason: prompt_mode` frame shows `composer.send_failed_prompt_mode` | shows the allow-list line | the mode line |
| R16 | i18n parity: the new keys in all 19 locales | missing | present, the `i18n-untranslated` count not raised |

## 5. Rollout

Additive and off by default: an unset `prompt.mode` is `agile` = master.
Build order: store key and matrix (T1) -> hub check (T2, T3) -> WUI (T4,
T5) -> docs (T6). The hub rows deploy before the WUI rows; a hub with the
check and an old WUI already enforces the mode and shows the old
allow-list line.

## 6. Out of scope

- Per-channel modes (a mode is per workspace).
- Agents prompting agents (never gated, rule 2).
- New roles: the matrix uses the eight member roles as they are.

## 7. Risks

- `start` detection reads the task's stored messages on a send that
  addresses an agent: one indexed read per such send. T2 measures the hub's
  send p95 on dev before and after, with n, before T3 wires the fan-out.
- A WUI pre-check from a stale role set could warn a member just promoted:
  the hint never disables Send, the hub decides.

## 8. Decisions settled from the code

| # | decision | evidence |
|---|---|---|
| D1 | The mode is a `tenants.settings` key, no migration | `store/tenant_kv.go:18-31` (spec 098: a setting is a registry call) |
| D2 | A mode only narrows; `agile` = master | `agents.command` is already the one gate (`hub/wui.go:838-839`, `:769-770`); a widening mode would bypass an admin's role grants |
| D3 | Keep the allow-list, check the mode before it | different subjects: roles vs the members of one agent (2.2) |
| D4 | Reuse 403 `sender_not_allowed` + `reason` | old WUIs keep working (`wui/utils/send-failure.mjs:90`) |
| D5 | A plain post in an existing topic is never refused, only not delivered | owner rule `hub/wui.go:715-726` |
| D6 | Box frames are never checked | `hub/sender_allow.go:35-39` |
| D7 | The WUI reads the mode from `/v1/view/me` | `GET /v1/tenant/settings` needs `tenant.settings` (`hub/tenant_settings.go:92-96`); precedent `topic_archive_policy` (`hub/rbac.go:108-112`) |

## 9. Owner questions

```poll
Q1. Which modes should a workspace be able to pick?
(A) Agile and corporate only, fixed in code (recommended: smallest build, no migration)
(B) Agile, corporate and owner-only, fixed in code (one more mode, still no migration)
(C) Agile and corporate, plus a custom mode whose role table each workspace admin edits (one migration and a table editor in settings)
```

```poll
Q2. In corporate mode, may a developer start new work (open a new topic that prompts an agent)?
(A) No: product owners, admins and owners start work, developers continue it in existing topics (recommended: this is what makes corporate differ from agile)
(B) Only in a DM with an agent, not in a channel
(C) Yes: corporate limits only customers and regular users
```

```poll
Q3. Who may change a workspace's mode?
(A) Owners and admins, like every other workspace setting (recommended: no new permission)
(B) The workspace owner (biz_owner) only
```
