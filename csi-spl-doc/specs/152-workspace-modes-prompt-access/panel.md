# 152 panel record

The panel the owner asked for (msg `af62b408`, via the dispatcher): two
experts propose a solution and options for the owner to choose from.

## v0.3 (2026-10-23)

| seat | agent | vendor | what it did |
|---|---|---|---|
| EDITOR | c-393 | claude | wrote v0.3 from the owner's 15:36Z ask and the code on `6af865c34` |
| SEAT (closed) | m-909 | mistral | delivered no usable review: 4 empty messages (two bodies an unexpanded `$(cat ...)` of a file that did not exist), then findings with every claim and check field empty, 5 of 13 ids in the wrong stage, and the false claim that `tasks.md` is not in `08215dd93`. The dispatch holder closed the seat (msg `a76d68dc`); nothing of it is folded |
| SEAT | c-484 | claude | the specs_and_docs backup: its own action list (msg `1651c719`) and a 21-row review of `08215dd93` read on `6af865c34`, n = 1 reading per line (msg `57afe882`): 12 OK, 4 WRONG, 5 GAP |

What changed from v0.2, and why:

- The fixed matrix per mode and its `prompt.mode` key are gone: the owner
  asked for "a configureable list of what can be done by which role"
  covering the whole life cycle (msgs `cfc9d48a`, `295de9d0`, `8a3a1440`).
  The modes are now four presets that fill the list (msg `9465ddb1`).
- The prompting actions of v0.2 (`dm`, `mention`, `post`, `start`) stay,
  as permission ids, plus `reply`; v0.2's mention-poke and new-topic rules
  (D9, D10) stay as they were.
- The editor read every role check in the hub (152 permission sites, the
  role-name sites) and grouped them by stage: start 7, steer 10, review and
  accept 6, ship 4, administer 13 actions.
- Storage moved from a settings key to a table read inside `TenantRoles`,
  decided on evidence (spec 3.3).
- v0.2's Q2-Q4 are withdrawn; Q1 = B is recorded. The owner's next form is
  one poll: the action list and the four presets.

### Seat findings and what was done with them

Every WRONG and GAP row was re-read by the editor on `6af865c34` before it
was folded; all nine hold.

| seat c-484 | editor's check | in v0.3 |
|---|---|---|
| W1: an admin can give itself owner-only powers (`hours.approve`) or take them from the owner (`costs.read`); "administer needs `members.roles`" does not stop it | `rbac/rbac.go:254-268` (`Covers`), `hub/rbac.go:202`, `:214` | taken: 3.7 no-escalation rule (Covers the role, holds the action to grant; presets cell by cell), D6 rewritten, R28, R32 (an admin cannot apply move_fast: it grants `issues.blocker`) |
| W2: `channels.edit` is a ceiling over the creator / open-invite rules; removing another person, unarchive are `channels.manage` | `hub/channel_members.go:293`, `:356`, `:430`, `:528`, `:569`, `:607-608` | taken: both rows and poll S2, T8 reworded |
| W3: merge asks `notes.send` only, not `topics.manage` | `hub/merge.go:69`, `:167` | taken: "merge" dropped from `topics.manage` and poll T5; merge stays as today |
| W4: B1 alone or B2 alone reddens `TestRBACSeedMatchesDefaults` | `store/humans_rbac_test.go:170-197` | taken: B1 = the migration and the rbac ids in one commit |
| G1: six WUI helpers gate menus by role name | `wui/utils/msg-kind.mjs:26`, `msg-edit.mjs:103`, `:112`, `topic-menu.mjs:24`, `move.mjs:29`, `topic-archive.mjs:20`, `:63`, `:79`, `access.mjs:76-79` | taken: 3.7, D13, row B10, R31 |
| G2: `mayChangeTopic` also gates editing another's message and removing their attachment; box move paths run it for the human | 8 callers (`grep -n 'mayChangeTopic(' hub/*.go`) | taken: the row and poll R3 reworded, 3.8 box paths |
| G3: `issueWriter` has 9 callers; dropping `topics.manage` must not let `demo_user` through | `hub/issues.go:891`, `:914`, `:979`, `:1032`, `:1079`, `:1134`; `hub/issue_discussions.go:335`, `:357`; `hub/blocker_issue_make.go:34` | taken: 3.4 caller map, the issue ids seeded without `demo_user`, restore under `issues.remove_others`, R29, B6 scope |
| G4: goal approval, repo-doc retry and marketing account connect are in no row | `hub/calendar_sync.go:252-254`, `hub/repo_docs_edit.go:892`, `hub/marketing_channels.go:98` | taken: goal approval under `roadmap.publish` (poll P2), the other two under `tenant.settings`, B7 `calendar_sync.go` scope fixed |
| G5: B5, B7, B8 line scopes | `hub/wui.go:736` (`wuiMayPost`'s one caller); `hub/message_kind.go:124-138` | taken: B5 `:727-772`, `:830-845`; B7 `:32-34`, `:124-138`; B8 filed after B5 lands, its file named then |
| note: `agentDocs` reads the system grant | `hub/workspace_docs.go:113-120` | taken: one sentence in 3.8 |
| row 10: the last-owner / last-admin guards read the system grants | `store/humans_rbac_postgres.go:44-45`, `:86-91`; `store/humans_rbac.go:42` | taken: 3.7 and B3 say they stay there |

Second round, on `5c3ce7fda` (msg `d64338be`): every fold above read OK;
one new GAP.

| seat c-484 | editor's check | in v0.3 |
|---|---|---|
| N1: a grant beyond the admin's set (move_fast's `issues.blocker` to all, or one cell such as `hours.read` to `product_owner`) takes those roles out of the admin's member management, since `Covers` reads the list's grants | `rbac/rbac.go:258-268`; `hub/rbac.go:341`, `:398`, `:444`; `hub/members_admin.go:146`, `:158`; `hub/actas.go:202`; `store/humans.go:74` | taken, both of the seat's options: (a) move_fast gives `issues.blocker` to O and A only (its fill now 35 rows), every preset stays inside the admin's set; (b) 3.7 "Who admins can manage": the page names the roles leaving the admin's reach before it saves, GET `admin_unreachable_roles`; D14, R33, R34; poll MF reworded |

Not checked by the seat: the B5 p95 probe cost, the i18n plan, the page
design of 3.7 (no code exists yet).

### Signatures

- EDITOR c-393: v0.3, `16d63b4404684711dc490adf31037d231ad55ed8`.
- SEAT c-484: SIGNED `16d63b4404684711dc490adf31037d231ad55ed8`, after reading the N1 fold (`msg:2250af55-0b4c-4cc7-a509-7419448b4a1f`).

## v0.2 (2026-10-23)

| seat | agent | vendor | what it did |
|---|---|---|---|
| EDITOR | c-686 | claude | wrote v0.1 (`15a982250`) from the code; folded v0.2 |
| SEAT 2 | c-715 | claude | an independent proposal plus a 34-row review of v0.1, read on `15a98225028a`, n = 1 reading per claim (`msg:022c8cb0-b82c-47ce-be80-a6089fef07d8`) |

The planned mistral seat was held (the placer gives no mistral seat to a
brief naming csi-spl-wui, and agy had no quota until about 22:25Z).

### 1. Where the seats agreed from the start

- The four prompting actions: `dm`, `mention`, `post`, `start`.
- `agile` (the unset key) = master byte for byte; `corporate` = owners,
  admins and product owners start work, developers continue it, customers
  and regular users only DM; a third mode where only owners and admins
  prompt (v0.1 `owner_only`, seat 2 `strict`; v0.2 uses `strict`).
- A mode only narrows; agents are never blocked; demo users and channel
  guests are unchanged.
- The mode is one `tenants.settings` key, no migration; keep the allow-list
  as the per-agent layer after the mode; reuse 403 `sender_not_allowed`;
  the WUI reads the mode from `/v1/view/me`; owners and admins change it.

### 2. What seat 2 changed, every item checked by the editor on the code

| seat 2 | editor's check | in v0.2 |
|---|---|---|
| review 17: a new channel topic with no @ counts as `start` and is refused, which silences non-starters in every channel (OD seats are in every channel) | `spl-dispatch-subscribe.func.sh:3-16`; `hub/wui.go:715-726` | taken: D5, D10, R17 |
| review 15: the mention poke is a DM in a NEW task with `ref_task_id`; it misreads as `start` (15a) and lets a customer mention an agent through an edit (15b) | `wui/composables/useMentionPoke.ts:86-91`; `hub/wui.go:136`, `:620`; contract `:39-41` | taken: D9, R18, R19 |
| review 14: `TaskEnvelopes` reads every envelope; `is_parent` cannot tell a new topic | `store/store.go:257`; `hub/wui.go:554-558`; index `messages_task_received` (`rdb/0083_messages_task_received_covering.sql:36`, measured by the editor) | taken: the `EXISTS` probe, D10 |
| review 16: no admin can grant a permission to a role; grants are global | `rdb/0021_tenant_rbac.sql:37-41` (no tenant column) | taken: rule 1 reworded, 2.1 |
| review 19: say what the mode does for a door-off guest | `hub/wui.go:841` | taken: rule 3, D13, R20 |
| review 20: say why `pure_agent` has the developer row | - | taken: 3.3 |
| D-A: the mode as four derived permission bits in `s.access`, not a separate `promptac` check | `hub/rbac.go:45-69`, `:101`; 3 call sites (`grep AgentsCommand`) | taken: D8, 3.4 (an editor's call, not an owner question) |
| 1.5: a custom mode fits one settings key, no table | `store/tenant_kv.go:57-69` | taken: D11; Q1-C's cost no longer says "one migration" |
| 1.6: the mode change is not logged by key | `hub/tenant_settings.go:173-177` | taken: D12, T3 |
| reviews 11, 12: wrong line ranges for `bad_setting` and the GET / PATCH handlers | `:244-245`; GET `:92-104`, PATCH `:106-179` | fixed in 2.5 |
| review 28: R11 must name its command and n | `go test ./internal/hub/ -run 'SenderAllow\|WUI\|Wui' -count=1 -v` -> 59 PASS, n = 1, memory store, on `15a982250` (editor) | taken: R11 |

### 3. Where the seats differed (v0.2 Q2, Q4; both withdrawn in v0.3)

- **Q2, a developer's new work in corporate.** Editor: (A) refuse it.
  Seat 2: (C) deliver it tagged for a product owner.
- **Q4, the allow-list on the plain-post fan-out.** Editor: (A) keep the
  owner's earlier decision (msg `e9ec66fa`); seat 2 named none.

### 4. Signatures

- EDITOR c-686: v0.2, `9b01369f4`.
- SEAT 2 c-715: SIGNED `9b01369f4efe2d8df9b7564a2022c48bb8199f1c`
  (`msg:86856654-542c-4fa6-995b-f69fa59f986f`).
