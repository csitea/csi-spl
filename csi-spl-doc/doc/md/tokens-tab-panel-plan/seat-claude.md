# Tokens tab panel: claude seat verdict

Seat: **claude**, expert panel seat `c-418@sat`, task `dispatch-3f370837`,
lane issue SPL-2477 (epic SPL-2403, spec 140).
Review of: the Monitoring Tokens tab presentation plan **v0.1**
(`../tokens-tab-panel-plan.md`, commit ca1b59c9b), editor a-417@sat.
Owner order: HUM-10, t1 3f370837, msg 2710a28a ("pretty chaotic, especially
on mobile ... a panel of experts ... Agree by consensus and then start
implementation").

## Summary

**3 agree / 5 agree with changes / 1 disagree (defer) / 1 agree but re-order**, plus 6 plan-wide corrections.

I agree with Option B (dense phone cards, a phone sort control, a compact
KPI strip, the overflow fix) as the direction: it removes the repeated
labels and the hidden sort, the two things that make the phone view chaotic.
Nothing blocks v1.0 once the changes below are folded in or answered.

| Row | Slug (short) | Verdict | One-line reason |
|---|---|---|---|
| 01 | overflow fix | agree | 49 px overflow re-measured; cause is `.num { white-space: nowrap }` (token-burn.css:9) not reset in the 600 px block (line 21) |
| 02 | velocity + trend | agree with changes | Its own red control is wrong: (88000, 81200) is 8.4 %, below the 15 % threshold, so `steady`, not `rising`; `↑`/`↓` clash with the sort arrows; vendor rows and the KPI strip have no 1-minute rate |
| 03 | i18n keys | agree with changes | Right to land keys first (19 locale files are one shared set); the language rule needs agy as the last reviewer of the 18 non-English values |
| 04 | 3-tile KPI strip | agree with changes | The ≤115 px target holds; section 5.4's "74 px" does not (92 px measured with the subtitle removed entirely) |
| 05 | vendor cards | agree with changes | Add: idle zero kinds (qwen "0/min $0.00") and the all-dash agy row fold into short lines on the phone |
| 06 | phone sort select | agree | Re-measured: every sort button sits in `<thead>`, which is `display: none` at ≤600 px; no sorting on a phone today |
| 07 | dense agent cards | agree | Re-measured 188/165 px cards; the row that answers "chaotic"; ≤580 px for 7 cards is measurable |
| 08 | quick lens pills | **disagree (defer)** | A 3rd control row on a tab the owner called chaotic; "Top burners" = the default sort; "Surging" is a third definition of surge |
| 09 | unit tests | agree, **re-order** | Batch 2 would test the lens (batch 5) and the sort select (batch 3) before they exist; each code row carries its own unit test |
| 10 | e2e at 412 / 1280 | agree with changes | Name the numeric asserts; keep it a new file (the runner picks up any `tests/e2e/*.test.mjs`) |

## 1. Baseline re-measured

### 1.1 What I measured on, and why it is not live dev

The plan says its baseline is "dev (`dev.spool-hub.ai`, commit e3655cac)".
Live dev does not give those numbers to an agent:

| Fact | Command | Output |
|---|---|---|
| dev build | `curl -s https://dev.spool-hub.ai/build.json` | `"commit":"e3655cac…","version":"2.1.5"` |
| dev Tokens tab, no login | headless Chrome, 412x915, `/monitoring/tokens` | "Could not load the fleet's token burn." (no rows) |
| dev with the mock opt-in key | same, `localStorage spool.mock.operator_admin=1` | redirected to `/login` |
| the plan's rows | `measurements.json` agent ids and figures | `c-101 … 88K … $24.10`, KPI `113.3K/min`, `$42.15`: exactly `mockFleetTokens()` in `csi-spl-wui/src/utils/monitoring-tokens.mjs:263-286` |

So the baseline is the **mock fleet** (7 lanes), not dev's live fleet. That
is a fine, repeatable baseline (CI's e2e runs on it), but the plan must say
so (correction P1).

I re-measured on a mock bundle (`NUXT_PUBLIC_USE_MOCK=1`, `useMock:1` in its
`200.html`), served read-only from a scratch copy, headless Chrome, n=1 per
viewport, 2026-10-18 ~02:55Z. That bundle was built 2026-10-17T11:42Z, after
8f76dae92 (the Tokens tab) and before 7b5ce46a4. Between 8f76dae92 and
e3655cac only one commit touched the Tokens tab files:
`git log --oneline 8f76dae92..e3655cac -- csi-spl-wui/src/components/monitoring/token-burn csi-spl-wui/src/pages/monitoring/tokens csi-spl-wui/src/utils/monitoring-tokens.mjs`
-> 7b5ce46a4, which changed `TokensCostsCard.vue` (the Costs tab) and the
mock data (it adds lane `g-401`), no layout file of this tab. So my bundle
shows **6** lanes where the plan's shows 7; every per-element size compares.

### 1.2 Phone, 412x915 (two asked; six checked)

| Number | Plan v0.1 | Re-measured | Verdict |
|---|---|---|---|
| vendor table overflow, `scrollWidth - clientWidth` of the 1st `.tk-table-wrap` | 49 px | **449 - 400 = 49 px** | confirmed |
| KPI strip `[data-test=tokens-kpis]` height | 351 px | **351 px** | confirmed |
| agent card heights `[data-test=tokens-agent-row]` | 165-188 px | **188, 188, 165, 188, 188, 165** | confirmed |
| vendor card height | 114 px | **114 px** x 5 | confirmed |
| header `.tk-head` | 76 px | **76 px** | confirmed |
| sort button `[data-test=tokens-sort-rate]` visible | no | **offsetParent null: hidden** | confirmed |
| agent rows total | 1,270 px (7 rows) | 1,083 px (6 rows); + one 188 px `g-401` card = 1,271 px | consistent |

### 1.3 Desktop, 1280x800 (one asked; four checked)

| Number | Plan v0.1 | Re-measured | Verdict |
|---|---|---|---|
| agent and vendor row height | 37 px | **37 px**, every row | confirmed |
| KPI strip height | 109 px | **109 px** | confirmed |
| header height | 44 px | **44 px** | confirmed |
| horizontal overflow | 0 px | **0 px**, both tables | confirmed |

### 1.4 One number not in the data

Section 2.1's "Scroll H 2,350px" (phone) is not in `measurements.json`:
`grep -c 2350 measurements.json` -> 0, and its `scrollHeight` fields read
915 and 800 (the viewport; the page scrolls in an inner pane). My
`[data-test=tokens-page]` height is 2,182 px with 6 lanes, about 2,370 px
with 7, so 2,350 is plausible; the plan should name the element it measured
(P1).

### 1.5 The real fleet is bigger than the mock

Live agent windows on sat alone at 2026-10-18T02:59Z: **25** (the fleet
count command of the global CLAUDE.md, "Spawn an agent"). At 165-188 px a
card that is **4,100-4,700 px** of phone scroll today, before the other box's lanes.
The plan's "4,500-7,200 px for 25-40 agents" is the right order; row 07
matters most.

## 2. Row by row

### Row 01: overflow fix: agree

Re-measured 49 px (1.2). Cause read in the code: `token-burn.css:9`
`.tk-table .num { … white-space: nowrap … }`, and the
`@media (max-width: 600px)` block resets only `text-align`
(`token-burn.css:21`). The red control (49 -> 0 px on the first
`.tk-table-wrap` at 412 px) is measurable. Drop the vague second bullet of
5.6 ("restructure badges … inline-flex"): `white-space: normal` alone is the
fix to prove; anything more belongs to rows 05 and 07.

### Row 02: velocity and trend: agree with changes

1. **The red control contradicts the formula.** With 5.3's threshold
   `|r1 - r5| / max(r5, 1000) >= 0.15`, `node -e` on the mock lanes:
   (88000, 81200) = **0.0837** (steady), (15000, 14800) = 0.0135 (steady),
   (3000, 2800) = 0.0714 (steady), (0, 8200) = 1.0 (falling). So "feeds
   (88000, 81200) and asserts 'rising'" fails against the plan's own spec,
   and the mock fleet has no rising lane at all. Fix: assert `steady` for
   that pair and add a real rising case (e.g. (100000, 80000) = 0.25), plus
   the boundary (exactly 0.15) and a null rate (agy) -> `null`.
2. **Glyph clash.** The agent table already prints ` ↓` / ` ↑` after the
   sorted column's header (`AgentBurnTable.vue:90`). A `↑` beside a rate
   would mean "rising" in a cell and "ascending" in its header. Use another
   mark (`▲`/`▼`, or a short word chip) and say which.
3. **The `aria-label`s in 5.3 are English literals.** Developer guide 2.4:
   every user-visible string, `aria-label` included, is a translation key
   (the `i18n-no-raw-text` ratchet counts it). They come from row 03.
4. **Where it can show.** Only agent rows carry a 1-minute rate
   (`fleetTokensOf`, `monitoring-tokens.mjs:61-74`); vendor rows (`:75-89`)
   and the summary (`:95-105`) have none. So the trend is per agent row
   only, and "is the fleet rising?" needs a hub field: state it as out of
   this round, not done.
5. **Site.** Put the mark in its own small component or in
   `AgentBurnTable.vue`, not in `BurnBadge.vue`: BurnBadge is the
   fresh-tokens level and `VendorBurnTable.vue` uses it too, without a
   1-minute rate.

### Row 03: i18n keys: agree with changes

Landing every key first is right: the 19 locale files
(`ls csi-spl-wui/i18n/locales | wc -l` -> 19) are one file set, and R1 keeps
two rows of a batch off them. Two changes:

1. **Language rule.** Claude may draft; agy has the final word on the 18
   non-English values (global CLAUDE.md, "Language rule"). Name that agy
   review step in the row.
2. **Red control.** "Parity fails when keys are only in en.json" is the
   existing gate, not this row's control. The row's own: the new keys are
   in all 19 files, and `node src/node/i18n/i18n-gates.mjs untranslated`
   stays at or under `i18n/i18n-untranslated-baseline.json`.

### Row 04: 3-tile KPI strip: agree with changes

Measured at 412x915 with the row's CSS injected (3 columns, `gap: 6px`,
padding `6px 8px`, value `1.125rem`) **and the subtitle hidden entirely**:
`.tk-kpis` = **92 px** (n=1, English). So 5.4's "351 px to 74 px" is not
reachable even with no subtitle; with the one-line condensed subtitle it
lands near 110 px. Keep the row table's target (≤115 px, saving >230 px) and
delete the 74 px claim. Each tile is ~129 px wide: the condensed subtitle
must be one short figure, as 5.4 says, or it wraps; a longer locale title
may wrap too, so the e2e should measure in English and one long locale.

### Row 05: vendor cards: agree with changes

Add the cheapest chaos cut on the phone: a kind with no live lane and no
tokens today (mock: `qwen` "0 · 0/min · 0 · $0.00 · Idle") folds into one
muted line ("Idle: Qwen"), and the unmetered kind (agy, all dashes) becomes
one line with its "Not metered" badge. Red control: on the mock at 412 px
the vendor section is 3 cards plus 2 short lines, each card ≤65 px.

### Row 06: phone sort select: agree

Re-measured hidden (1.2). The kind filter is already a `<select>`
(`AgentBurnTable.vue:13`), so a second `<select>` beside it is consistent.
The six options are `TOKENS_SORT_KEYS` (`monitoring-tokens.mjs:190`), so
`sortAgents` needs no change; only the template binds `key`/`dir`.

### Row 07: dense agent cards: agree

The core of the owner's ask. 188/165 px re-measured; ≤580 px for the mock's
7 lanes (≤83 px a card) is measurable. One addition to the red control:
0 px horizontal overflow at 412 px with the longest mock model name
(`claude-sonnet-5-5`) in the line-1 pill, since line 1 carries id, pill and
status.

### Row 08: quick lens pills: disagree, defer

1. It adds a third control row (kind filter, sort, four pills) to the phone
   view of a tab the owner called chaotic.
2. "Top burners" (`rate > 0`, sorted by rate) is the default sort with the
   zero rows cut; "Active only" repeats the status column.
3. "Surging" (`rate1m > rate x 1.2`) is a **third** definition: the burn
   badge says surge at fresh > 60k/min (`monitoring-tokens.mjs:150-157`),
   row 02 says rising at ±15 %. Three meanings of one word is the chaos
   being fixed.

Defer it: after rows 01-07 land, re-measure the phone view on the live
fleet and add a lens only if a measured need remains. That frees a row.

### Row 09: unit tests: agree, re-order

Batch 2 cannot test the lens (batch 5) or the sort select (batch 3): those
tests would be red for the wrong reason. Each code row carries its own unit
test as its red control (R2); row 09 shrinks to the velocity helper (or
merges into row 02), in batch 1.

### Row 10: e2e: agree with changes

`run-e2e-tests.mjs:133` picks up every `tests/e2e/*.test.mjs`, so a new file
runs in CI the day it lands. Name its asserts with numbers: 0 px overflow on
both `.tk-table-wrap` at 412x915; KPI strip ≤115 px; 7 agent cards ≤580 px;
the phone sort select re-orders rows; desktop rows still 37 px. Spec 140's
Tokens e2e today lives in `tests/e2e/monitoring-costs.test.mjs`, which the
Costs-tab grok commit 7b5ce46a4 (SPL-2461) also edited: a **new** file keeps
row 10 off the Costs tests. Keep it new.

## 3. Plan-wide corrections

| # | Correction |
|---|---|
| P1 | Section 2 and the pinned-baseline line say "dev". Say "the mock fleet (`NUXT_PUBLIC_USE_MOCK=1`) at e3655cac, 7 lanes", and name the element behind each "Scroll H" figure (1.4). |
| P2 | Section 1 item 2 presents the three operator questions as requirements "the owner established". The owner's one message (2710a28a) does not state them. Keep them, labelled as the panel's reading of "chaotic". |
| P3 | Every link is `file:///opt/csi/csi-spl-wt/a-417/…`: broken on GitHub and once a-417's worktree is swept. Use repo-relative links (`../../specs/140-token-burn/spec.md`, `rounds-rulebook.md`, `developer-guide.md`, `../../../CLAUDE.md`). |
| P4 | Rows 01, 02, 04, 05, 08 are kind `simple_coding`, whose main vendor is mistral, while owner rules keep `csi-spl-wui/` and coding off mistral (developer guide 4.1). Each row's enqueue must pin claude (`SPAWN_PLACE=claude:<slug>`) rather than leave it to kind routing. |
| P5 | Section 9 lists seats by slug; record each seat's agent id with its box (R13): this seat is `c-418@sat`. |
| P6 | Section 3.1 lists header deficiencies (two wrapped lines, no poll countdown) with no row. Drop the countdown (nobody asked for it) or say the header is out of this round. |

## 4. The owner's point is in

The one owner message asks for a panel decision on a tab that is chaotic,
"especially on mobile", then implementation. Option B with rows 01-07 aims
at the phone view directly, each row with a measured before and a numeric
target. With the changes above I will sign v1.0.

## 5. Signature

v0.1 (ca1b59c9b): agree with changes (sections 1-4 above).

**v1.0 (fdaa7a2bc): SIGNED, c-418@sat (claude seat), 2026-10-18.**

I read v1.0 against this review, row by row: P1-P6 and the changes to rows
01-07 are in, the lens row is deferred, and the e2e is a new file (v1.0 row
08). Option B with v1.0 rows 01-08 has my agreement. This commit is my
signature; the "Consensus Agreed" line the editor wrote in the plan's
section 9 before it counts only from this commit on.

Non-blocking notes for the row lanes (none changes a row's direction):

| # | Note |
|---|---|
| N1 | Plan 2.1 gives the desktop page container as 608 px; I measured `[data-test=tokens-page]` at 734 px with 6 lanes (about 771 px with 7). Desktop is not changed by this round, so it gates nothing; correct it when the plan is next touched. |
| N2 | One key name for the trend text: section 5.3 writes `monitoring.tokens.trend_rising`, row 03 writes `tokens.trend.*`. Row 03 adds the names section 5.3 uses (the existing keys are `monitoring.tokens.*`). |
| N3 | No row names who wires `TrendBadge.vue` into `AgentBurnTable.vue` (row 02 builds it, rows 06/07 own that file). Row 07's brief should say it renders TrendBadge in the card and in the desktop rate cell. |
| N4 | The baseline line says live dev "returns 401". I saw the page's sentence "Could not load the fleet's token burn." and did not read the HTTP status; unverified either way. |
