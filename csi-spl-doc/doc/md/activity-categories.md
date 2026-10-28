# Activity categories: what the fleet's tokens are spent on

Spec: [143 section 4](../../specs/143-reporting-section/spec.md) (tasks T040-T043)  
Issue: SPL-2790, epic SPL-2389  
Schema: `csi-spl-rdb/src/sql/postgres/spool-hub/0204_activity_categories.sql`

Owner HUM-10, token burn topic e8ae0aad: "not all tokens are equal" (msg
1b2269f7), and the tree "has to be expandable in the future" (msg 52fddc9d).

## 1. The tree

The categories are rows of `activity_categories`, in path notation
(`coding/hard`). A node's parent is its path minus the last segment. Adding a
finer category is one row: no code change and no deploy. The seed holds 5
areas with their sub-categories (owner poll 2, answer A):
`coding` (`simple`, `hard`, `i18n`), `review` (`r7`, `gate`),
`specs_and_docs` (`spec`, `doc`), `tests` (`unit`, `e2e`) and `dispatch`
(`triage`, `placement`).

## 2. A brief names its category

The spawn placer (`do_spl_spawn_place`) reads two header lines of a brief:

| line | read as | stored in |
|---|---|---|
| `Kind: complex_coding` | the lane kind, as the lane mix reads it | `fleet_asks.work_kind` (one of the 8 lane kinds, else left empty) |
| `Category: coding/hard` | must start the line | `fleet_asks.category_path` |

The placer records both on the spawn request right before the launch
(`spool ask category --id <ask> --by <holder> --work-kind <kind> --category <path>`).
`spawn-window.sh` writes the same pair to
`<spool root>/<id>/lifetime/category.json`.

- A brief with neither line places exactly as before, and nothing is sent.
- A `Category:` that names no node is refused by the hub
  (`unknown_category`). The placer logs one WARN line and still places the
  lane. Its tokens then count as uncategorised.

The placer reads one more line when it picks the vendor (SPL-3627). A
brief whose work is under the data rule (personal data or secrets: claude,
grok or mistral only, never agy or qwen) starts a line with:

| line | read as | stored in |
|---|---|---|
| `Data: secret` | the data rule: a `mistral:` row that the UI or coding rule swaps goes to claude, never to agy or qwen | nothing (`spl_spawn_place_data_rule`) |

`Kind: secret` counts as the same marker, and so do the words `Data rule:`
anywhere in the brief (ask c581963b carried only that prose and was launched
as agy). A brief with no marker keeps the old swap: agy for
`specs_and_docs` or `i18n`, else claude.

A review seat writes no code (SPL-3776). Its slug, the brief's file name,
ends in `-reviewer`, or its `Kind:` is `review`. Neither the coding rule nor
the UI rule swaps it: a `mistral:` review seat stays mistral on a
`Kind: secret` brief (SPL-3776; before, it was launched as claude, so a
claude author got a same-vendor review) and on a brief that names
`csi-spl-wui/` (SPL-3954, owner HUM-10, t1 1be0e370, msg 594d77e1: "Mistral
may review them, read-only (it writes no code; your UI-work rule still holds
for building)"). A mistral build row on WUI work is still swapped. When a
mistral review seat's author is a mistral lane, the placer places nothing.
It logs one WARN line and hands the row to the orchestrator with the reason.
The author is the lane id on a line that starts with `Author:`. A brief with
no such line counts every lane id it names, except the role seats 001-003.

## 3. The routes

| route | who | what |
|---|---|---|
| `GET /v1/reporting/categories` | any signed-in member | the active nodes, nested (`children`) |
| `POST /v1/operator/categories` | operator admin or operator service account | adds a node: `{category_path, title, description?, dimensions?, is_active?}`. Its parent must exist |
| `PUT /v1/operator/categories/{path...}` | the same | changes `title`, `description`, `dimensions`, `is_active`. A missing field is kept. A node is never moved |
| `GET /v1/reporting/tokens/by-category?from=&to=&depth=` | the same (owner poll 4, answer A) | the token rollup below |

## 4. The token rollup

A placed request is closed with `placed: <agent>@<box>`. Its lane's token
minutes (`fleet_token_burn_events`, same `agent_id` and `box_tag`) count
under the request's category, from 5 minutes before the placement until the
next placement of that id on that box. Only requests of the operator
workspace count.

- A parent sums itself and every descendant. `depth=1` gives the 5 areas,
  `depth=2` adds their children, `depth=leaf` (or none) gives every level.
- Every minute that no categorised request claims is `uncategorised`. It is
  never dropped and never guessed: the areas plus `uncategorised` add up to
  the total. Old minutes are not backfilled.
- The window is `from` to `to` (RFC 3339 or `YYYY-MM-DD`, `to` excluded),
  7 days by default, at most 30 (the minute rows' retention).
- `tokens` = input + output + cache write. `cache_read` is shown beside it.
  `cost_usd` is the list cost of the rows priced in USD.

Spec 143 section 4.4 drafts the join on `fleet_asks.from_agent`. That column
is the agent that ASKED for the lane (the dispatcher), not the lane that burns
the tokens, so the rollup joins on the placed lane instead. Measured on prd
2026-10-22: 146 of 147 placements of the last 2 days have burn rows under
their `(agent_id, box_tag)` within an hour of the placement.
