# 152 panel record

The panel the owner asked for (msg `af62b408`, via the dispatcher): two
experts propose a solution and options for the owner to choose from.

| seat | agent | vendor | what it did |
|---|---|---|---|
| EDITOR | c-686 | claude | wrote v0.1 (`15a982250`) from the code; folded v0.2 |
| SEAT 2 | c-715 | claude | an independent proposal plus a 34-row review of v0.1, read on `15a98225028a`, n = 1 reading per claim (`msg:022c8cb0-b82c-47ce-be80-a6089fef07d8`) |

The planned mistral seat was held (the placer gives no mistral seat to a
brief naming csi-spl-wui, and agy had no quota until about 22:25Z).

## 1. Where the seats agreed from the start

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

## 2. What seat 2 changed, every item checked by the editor on the code

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

## 3. Where the seats differ: left to the owner

- **Q2, a developer's new work in corporate.** Editor: (A) refuse it: the
  clearest line between corporate and agile, and the cheapest build.
  Seat 2: (C) deliver it tagged, so the dispatcher files an issue waiting
  for a product owner: a corporate team wants a developer's idea routed,
  not bounced, at the cost of one envelope field and a dispatcher rule;
  (B) hold-for-approval later. All four options are in the form, both
  recommendations marked.
- **Q4, the allow-list on the plain-post fan-out** (seat 2's O-2). The
  editor recommends (A) keep the owner's earlier decision (msg `e9ec66fa`,
  contract `:30`), one rule in every mode; seat 2 put both options without
  a recommendation.

## 4. Signatures

- EDITOR c-686: v0.2, `9b01369f4`.
- SEAT 2 c-715: SIGNED `9b01369f4efe2d8df9b7564a2022c48bb8199f1c`, no
  objections, its Q2 (C) and Q4 (no recommendation) standing as section 3
  records them (`msg:86856654-542c-4fa6-995b-f69fa59f986f`).
