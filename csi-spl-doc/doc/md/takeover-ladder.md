# The takeover ladder (per-workspace setting)

SPL-2115. Owner HUM-10, t1 topic 35beee77:

- d83369df: "whenever Mistral or somebody else fails in some coding task, then
  Claude or somebody cleverer in coding (like, after Mistral, AGI) should take
  over. If it fails also, then Claude should fix the code." ("AGI" is agy.)
- 97b09186: "a configurable setting for the order in which the agent kinds
  should take precedence after the failure of previous agents, and the amount
  of failure allowed per type of task".
- 20161759: "those should be on each workspace's settings."

This page is the contract for the setting. The engine that acts on it (M1b,
which hands a failed task to the next vendor on the same branch) reads it and
does not change it.

## 1. What it holds

For each task kind, the lane-mix names without `orchestration`:

| field | meaning |
|---|---|
| `order` | the vendors in takeover order. The first works on the task first, and the next takes over after the one before it failed `max_failures` times. Distinct vendors from `claude, grok, agy, qwen, mistral`, at least one. |
| `max_failures` | how many failures each vendor in the order may have before the next takes over. A whole number from 1 to 10. |

The rules, checked by the hub (`store.CheckTakeoverOrder`, the PUT) and, before
Save, by the WUI (`takeoverRule`):

- known vendors, none twice, at least one;
- `max_failures` from 1 to 10;
- **the `secret` order never names `agy` or `qwen`** (the data rule, owner msgs
  803c3b38, 26117740, 474f32a0). The generic settings route refuses it too.

## 2. Defaults

A workspace that never set a kind reads its default:

| kind | order | max_failures |
|---|---|---|
| `specs_and_docs` | agy, claude | 1 |
| `tests` | mistral, agy, claude | 2 |
| `simple_coding` | mistral, agy, claude | 2 |
| `complex_coding` | mistral, agy, claude | 2 |
| `i18n` | agy, claude | 1 |
| `secret` | claude, mistral | 2 |

The vendor split (spec 115, `/v1/agent-split`) still picks the FIRST vendor of
new work. The ladder only says who takes over after a failure. The two settings
are separate, so a coding ladder may name agy although the coding split keeps
agy at 0.

## 3. Where it is stored

There is no table and no migration. It uses two registered keys per kind in
`tenants.settings` (spec 098, rdb 0136), `csi-spl-api/src/go/spool-hub-api/internal/store/takeover_ladder.go`:

- `takeover.<kind>.order`: a string, the vendors comma-separated (`"mistral,agy,claude"`);
- `takeover.<kind>.max_failures`: an int.

A key that is not set reads as its default. A stored value that a later, tighter
check refuses also reads as the default, so the tenant row never breaks. The
keys ride the cached tenant row, so a Go reader holding a `store.Tenant` calls
`store.TakeoverLadderOf(t.Settings)` and makes no query.

## 4. The API

### 4.1 Read: `GET /v1/takeover-ladder`

Any member of the workspace (`topics.read`), with a member session.

```json
{
  "tenant_id": "t1",
  "vendors": ["claude", "grok", "agy", "qwen", "mistral"],
  "max_failures_max": 10,
  "kinds": [
    {"kind": "specs_and_docs", "order": ["agy", "claude"], "max_failures": 1, "set": false},
    {"kind": "tests", "order": ["mistral", "agy", "claude"], "max_failures": 2, "set": false},
    {"kind": "simple_coding", "order": ["claude", "mistral", "agy"], "max_failures": 3, "set": true},
    {"kind": "complex_coding", "order": ["mistral", "agy", "claude"], "max_failures": 2, "set": false},
    {"kind": "i18n", "order": ["agy", "claude"], "max_failures": 1, "set": false},
    {"kind": "secret", "order": ["claude", "mistral"], "max_failures": 2, "set": false}
  ]
}
```

`kinds` always lists all six kinds in this order. `set` is false when the
kind reads as its default.

### 4.2 Write: `PUT /v1/takeover-ladder`

`tenant.settings` only (workspace admins and business owners); any other
member gets 403 `forbidden`. `Content-Type: application/json`.

```json
{"kinds": {"simple_coding": {"order": ["claude", "mistral", "agy"], "max_failures": 3},
           "tests": null}}
```

- A kind given as an object replaces that kind whole (both fields required).
- `null` resets the kind to its default.
- A kind left out keeps its value.
- The answer is the GET body after the write.
- A broken rule is 400 `bad_ladder`, and its `detail` names the rule, e.g.
  `secret: agy never takes secret work (the data rule)`. **Nothing is
  written**, including the valid kinds of the same PUT.

The same keys can also be set through `PATCH /v1/tenant/settings
{settings: {"takeover.tests.order": "claude,grok"}}` under the same checks. Use
the structured route: it writes both keys of a kind together.

### 4.3 From a box (M1b)

A box agent has no member session. Choose one:

- In the hub (Go), with the tenant row loaded: `store.TakeoverLadderOf(t.Settings)`.
- On the box, read `tenants.settings` through an operator-scoped read action
  (as `do_spl_agent_split_show` does for the split), and apply the defaults in
  section 2 for every key that is missing.

## 5. The WUI

Workspace settings -> **Agent takeover** (`/tenant-settings/takeover`,
`csi-spl-wui/src/pages/tenant-settings/takeover.vue`) shows one row per kind.
In each row you can move a vendor up or down, remove it, add one, and set the
number. **Save** sends the kinds you changed, and **Reset to defaults** sends
`null` for every kind. The help text is in `csi-spl-doc/doc/help/user-settings.md`, section 9.

## 6. Tests

- `internal/store/takeover_ladder_test.go`: Memory and Postgres, the round trip
  through the fresh read and the cached tenant row, and the secret rule as a
  CONTROL.
- `internal/hub/takeover_ladder_test.go`: the routes, admin-only PUT (developer
  403), any member GET, the secret rule as a CONTROL (with the guard removed,
  3 CONTROL lines go red).
- `csi-spl-wui/tests/unit/takeover-ladder.test.mjs`: the defaults are pinned to
  the Go source.
- `csi-spl-wui/tests/e2e/tenant-settings.test.mjs` steps 8p..8t: an order is
  changed, saved, and still there after a reload.
  `PROVE_RED=takeover-no-save` turns 8s red.
