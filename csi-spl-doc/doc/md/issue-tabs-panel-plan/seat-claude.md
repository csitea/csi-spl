# Issue tabs panel: claude seat verdict

Seat: **claude**, expert panel seat `c-227`, task `dispatch-67d850ce`,
lane issue SPL-2523 (epic SPL-2403, spec 039).
Review of: the Issues view tabs 3D styling plan **v0.1**
(`../issue-tabs-panel-plan.md`, commit 97d976cd1), editor a-226.
Owner order: HUM-10, t1 67d850ce, msgs 0850198a and a175a8f0 ("some kind of
3D ... it's on the downside, and it should be on the upside ... pretty
obvious that these are two tabs, which is the selected one").

## Summary

**1 agree / 2 agree with changes / 3 merge into another row**, plus 8 plan-wide corrections.

I agree with the direction: Option 1, a folder tab joined to the panel below
with the marker on the top edge. Option 1 **as written** does not deliver it.
I injected its CSS into the served page and measured four defects:

- A focused selected tab shows **two** colours: accent `#34d5f0` plus the
  focus ring `#6ee4f7`. That breaks the owner's one-colour rule.
- The tab floats **about 5 px above** the divider it is meant to join.
- On desktop the active tab's fill is the same colour as the dialog
  behind it (1.00:1).
- Its 3D shadow resolves to nothing, because `--color-shadow` does not exist.

The fixes are small. With them, rows 01-06 collapse into **2 commits**, so
no commit lands trunk red. Nothing blocks v1.0 once the changes below are
folded in or answered.

| Row | Slug (short) | Verdict | One-line reason |
|---|---|---|---|
| 01 | tokens (`--color-shadow`) | **merge into 02** | Its red control `tests/unit/issue-tabs-tokens.test.mjs` is created by no row; the site `variables.css:85-115` is inside the dark `:root` block and misses the other 7 colour theme blocks (lines 116, 165, 198, 231, 267, 304, 337) |
| 02 | 3D CSS, top marker | agree with changes | Marker must be `--focus-ring` at `--select-bar-w`, not `--color-accent` 3px (measured 2 colours on focus); equal tab heights; a real joint; a fill that differs on desktop |
| 03 | clip control out of the tablist | agree with changes | Right fix, but it reds `tests/unit/list-clip-modes.test.mjs:95` unless row 04 is in the same commit (R2); the snippet's i18n keys `issues.thread` / `issues.history` do not exist |
| 04 | update list-clip-modes test | **merge into 03** | A separate batch means batch 3 lands a red unit test on trunk |
| 05 | unit test tabs | **merge into 02 and 03** | Batch 1 would test CSS (batch 2) and keyboard keys (batch 3) that do not exist yet; a node unit test cannot read computed style |
| 06 | e2e at 412 / 1280 | agree | Name the numeric asserts (section 3); prefer extending `tests/e2e/issues-crud-modal.test.mjs`, which already clicks these tabs (lines 355-375) |

## 1. Baseline re-measured

### 1.1 What I measured on

- **Bundle:** my own mock bundle (`NUXT_PUBLIC_USE_MOCK=1
  NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate`), built from 97d976cd1.
- **Server:** served by `csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh`.
- **Browser:** headless Chrome, page `/issues?issue=SPL-1`.
- **Runs:** n=1 per viewport and theme, 2026-10-19T08:23Z.
- **Same source as dev:** dev served `70ae29de7` (`curl -s
  https://dev.spool-hub.ai/build.json`). `git diff --stat 70ae29de7 97d976cd1
  -- csi-spl-wui/src` is empty, so this is dev's CSS on mock data. The plan's
  pinned `e7ebe20f6` also touches neither `issues.vue` nor `assets/css`
  after dev's commit.
- **Why not live dev:** live dev needs a signed-in member, and I found no
  e2e password file on this box.

Script, JSON and 8 captures (today and Option 1, 2 viewports x 2 themes):
`/var/spool-hub/dispatch/67d850ce/work/c-227/`
(`measure-tabs.mjs`, `c227-measure.json`, `c227-<w>-<theme>-{today,option1}.png`).

### 1.2 Numbers re-measured (three at 412x915, one at 1280x800)

| # | Viewport | What | Plan v0.1 | Mine | Verdict |
|---|---|---|---|---|---|
| B1 | 412x915 dark + light | tab boxes, Discussion / History | 85.6x31.6 / 59.8x31.6 | 85.6x31.6 / 59.8x31.6 | **agree** |
| B2 | 412x915 dark + light | tablist header height | 46 | 46 | **agree** |
| B3 | 412x915 dark / light | selected vs unselected text contrast | 1.00:1 | **2.02:1 / 2.52:1** | **disagree**: the plan compares raw `color` and ignores `opacity: 0.7`; blended over the real background, the unselected text is 8.73:1 / 6.33:1 against the background, the selected one 17.66:1 / 15.95:1 |
| B4 | 1280x800 dark / light | header height, tab boxes, text contrast | 31.6 tabs, 1.00:1 | tabs 85.6x31.6 / 59.8x31.6; header 39.6; text 1.90:1 / 2.60:1 | tabs **agree**; contrast **disagree** as B3 |

B3 matters for the build. The plan's target "inactive contrast ≥ 1.4:1"
**already passes on today's tree** (1.90..2.60), so it cannot be a red
control. Section 3 replaces it with structural targets that fail today.

### 1.3 What the "bracket" is

The owner called today's marker a "bracket". The capture shows why. The
selected tab's 2 px `border-bottom` is bent up at both ends by the global
`button { border-radius: var(--radius-sm) }` (`main.css:8-13`,
`--radius-sm: 8px`, measured `borderRadius: 8px`). The plan should name this.
Any new marker must also zero the bottom radii, or the folder tab keeps
rounded feet (seen in `c227-412-dark-option1.png`).

## 2. Option 1, as written, measured

The plan's section 3.1 CSS was injected into the served page. Its selectors
were raised to `.issues-talk .issues-talk__h .issues-talk__tab`, because the
page's scoped rules out-rank a bare class. The rows below are what Chrome
computed.

| # | Check | 412x915 dark | 1280x800 dark | Result |
|---|---|---|---|---|
| O1 | selected + keyboard focus | outline `2px #6ee4f7` + border-top `3px #34d5f0` | same | **2 colours** on one selected item: breaks the owner rule "no more than 1 color in the selected border" (the `:focus-visible` comment in `main.css`, `tests/unit/focus-tokens.test.mjs`). The accent and the ring differ by 1.18:1, a near-miss that reads as a smudge |
| O2 | tab heights / tops | selected 43.6 high, top 431.9; unselected 44.6, top 430.9 | 43.6 / 44.6 | the two tabs are **1 px out of line**: the selected one gains side borders and loses 1 px to `margin-bottom: -1px`, and the unselected one keeps today's 2 px transparent `border-bottom` |
| O3 | touch target | 43.6 px | - | the plan's own "≥ 44 px" (section 6.3) is **not met** |
| O4 | joint to the panel | header 53.6, tab 43.6, `align-items: center` | header 53.6 | the tab ends about **5 px above** the new divider ((53.6-43.6)/2; visible in the capture). The divider runs under the clip control, not under the tab, so "seamless" fails |
| O5 | active fill vs what is behind it | `--color-surface #0e1c33` on page `--color-bg #060912`: 1.17:1 (light: 1.07:1) | `--color-surface` on the dialog, which is `--color-surface`: **1.00:1** | on desktop the fill adds nothing; on a phone it barely shows |
| O6 | 3D shadow | `--color-shadow` = "" | "" | `box-shadow: 0 -2px 6px var(--color-shadow), …` is invalid at computed time, so **no shadow and no bevel** render |
| O7 | inactive text | `--color-text-dim` = "", opacity stays 0.7 | same | the token does not exist (`grep -c -- '--color-text-dim:' variables.css` → 0); `--color-muted` is the existing one |
| O8 | header growth | 46 → 53.6 (+7.6) | 39.6 → 53.6 (+14) | acceptable, but state it as a budget |

## 3. Row verdicts

### Row 01, tokens: merge into row 02

- A new `--color-shadow` must go into all 8 colour theme blocks of
  `variables.css` (`:root` line 10, `light` 116, `light-violet` 165,
  `light-green` 198, `light-yellow` 231, `light-orange` 267, `light-red`
  304, `dark` 337). Otherwise a theme renders no shadow (O6).
- Simpler: reuse the existing `--bevel-shine` / `--bevel-shade` plus a
  shadow on `--focus-3d`'s pattern (already per-theme, lines 64, 147, 187,
  220, 253), and add no token.
- Either way, it belongs in the same commit as the CSS that reads it.

### Row 02, CSS: agree with changes (the row that answers the owner)

Change the spec to:

1. **Marker** = `box-shadow: inset 0 var(--select-bar-w) 0 var(--focus-ring)`
   on the selected tab. This is the same token and width as every other
   selected item (`main.css` `.msg.selected` uses `inset var(--select-bar-w)
   0 0 var(--focus-ring)`), and an inset shadow adds no height (fixes O1,
   O2). On focus, the outline and the marker are then one colour.
2. **Both tabs keep the same box**: zero `border-bottom` and the bottom
   radii on both, `opacity: 1` on both, `color: var(--color-muted)` on the
   inactive one (fixes O2, O7).
3. **The joint**: the tablist aligns its tabs to the bottom
   (`align-items: flex-end`, with the clip control moved out by row 03),
   and the divider is the tablist's bottom border. The selected tab's fill
   equals the panel fill below it (fixes O4).
4. **Depth that shows on desktop**: inactive tabs are recessed, with
   `background: var(--color-bg-2)` and `var(--bevel-shade)`. The selected
   tab is raised, with the panel's own fill, `var(--bevel-shine)`, side
   borders `var(--color-border)` and the upward shadow. Measured fills on
   desktop: today 1.00:1; a recessed inactive tab at `--color-bg-2`
   (`#0a1424`) vs the dialog's `#0e1c33` differs. The editor should measure
   and record the ratio for both themes (fixes O5).
5. **Touch**: `min-height` in rem that gives ≥ 44 px at the default font
   level (fixes O3; the rem rule forbids px font sizes, and a rem height
   keeps the 5 font levels in step).

Targets, each red on today's tree, each read by `getComputedStyle` in the
e2e (row 06):

| # | Target | Today |
|---|---|---|
| T1 | selected tab: top inset marker colour == `--focus-ring`, width == `--select-bar-w`; `border-bottom-width` 0 | bottom 2px, `currentColor` |
| T2 | selected and focused: outline colour == marker colour (one colour) | n/a today (no top marker); Option 1 fails it |
| T3 | both tabs: same height and same top (±0.5 px) | equal today; Option 1 fails |
| T4 | selected tab bottom == tablist bottom (±0.5 px) | not joined |
| T5 | inactive tab background ≠ selected tab background, in both themes, at both widths | both transparent |
| T6 | tab height ≥ 44 px at 412x915 | 31.6 |

The unit part is a source-text test, the way `list-clip-modes.test.mjs`
reads `issues.vue`, for example "the selected rule uses `--focus-ring` and
`--select-bar-w`, no `--color-accent`". A node unit test has no layout, so
"computed style" in rows 02 and 05 can only come from the e2e.

### Row 03, clip control out of the tablist: agree with changes

- Right fix for the tablist role. `tests/unit/list-clip-modes.test.mjs:95`
  asserts today's exact shape, the clip control **inside**
  `<div class="issues-talk__h"[^>]*role="tablist"`. Row 03 alone turns that
  test red. Rows 03 and 04 land as **one** commit (R2: a test that reads the
  site's source is in the row's test column).
- The section 4.2 snippet must not be copied as is. It uses
  `t('issues.thread')` and `t('issues.history')`, and neither key exists:
  `en.json` has `issues.discussion` = "Discussion" and
  `issue_history.tab` = "History", which today's template uses. It also
  replaces today's `v-for` over `TALK_TABS` with two hand-written buttons.
  Keep the `v-for` and the existing keys, and add the wrapper only.
- Keyboard: today's buttons have no `@keydown` (`sed -n 952,967p
  src/pages/issues.vue | grep -c keydown` → 0). Arrow/Home/End handling is
  new behaviour. Its unit test goes in this commit, not in row 05.
- "Layout shift when switching tabs" (plan 2.3.6) is plausible but I did
  not measure it. The e2e should assert that the tablist height is equal on
  Discussion and History.

### Row 04: merge into row 03 (see above)

### Row 05, unit tests: merge into rows 02 and 03

- Batch 1 lands before the CSS (batch 2) and the keyboard keys (batch 3).
  The test is then either red on trunk or vacuous.
- Each code commit carries its own test, the same reason the tokens tab
  panel's claude seat gave for its row 09.

### Row 06, e2e: agree

- Assert T1-T6 numerically at 412x915 and 1280x800, dark and light.
- I'd extend `tests/e2e/issues-crud-modal.test.mjs`, which already opens an
  issue and clicks `[data-test=issues-talk-tab]` (lines 355-375). That
  avoids a new file, and with it a new entry for the shard packer
  (`tests/unit/e2e-shard-pack.test.mjs` pins packing on
  `src/node/test/e2e-shard-weights.txt`). I believe, unchecked, that a new
  file without a weight entry shifts that packing.

## 4. Plan-wide corrections

| # | Where | Correction |
|---|---|---|
| P1 | header, 2.2 | Say the baseline is the **mock** bundle, built from which commit, n=1, and that live dev was not measured (needs a login) |
| P2 | 4.1 token table | Wrong values. Actual `variables.css`: `--color-surface` `#0e1c33` / `#f4f8ff` (not `#162235` / `#ffffff`); `--color-bg-2` `#0a1424` / `#dce7f6`; `--color-border` `rgba(130,200,255,0.16)` / `rgba(12,60,110,0.16)`; `--focus-ring` is a **colour**, `#6ee4f7` / `#4bb8dc`, not `0 0 0 2px var(--color-accent)`. The ring width is `--focus-ring-w` (2px) |
| P3 | 3.1, 4.1 | `--color-text-dim` does not exist; use `--color-muted` (`#93a6c4` / `#47597a`) |
| P4 | 1.2.3, 2.3.4, row 02 | Contrast metric ignores opacity (B3); replace "≥ 1.4:1" with T1-T6 |
| P5 | 1.2.1, 3.1 | Marker colour `--focus-ring`, width `--select-bar-w`, per the WUI focus/selection contract (one ring colour, ≤ 3 px), not `--color-accent` 3px (O1) |
| P6 | 2.3 | Name the cause of the "bracket": the 8 px button radius on a 2 px bottom border (1.3) |
| P7 | 3.5, 7 | "Unanimous" before the reviews are in; say "editor's recommendation" until signed |
| P8 | 5.1/5.2 | Two commits instead of five batches: **A** = rows 01+02+05(css part)+06 (`variables.css` if a token is kept, `issues.vue` style block, `issues-crud-modal.test.mjs`, a source unit test); **B** = rows 03+04+05(keys part) (`issues.vue` template + script, `list-clip-modes.test.mjs`, a keys unit test). A and B share `issues.vue`, so B waits for A (R1), and each is green on its own. Vendor claude for both (developer guide 4.1, WUI never to mistral) |

## 5. Owner points check

| Owner point | In the plan? | In my amended row 02? |
|---|---|---|
| "some kind of 3D" | yes, but O6: renders flat | yes: recessed inactive, raised selected, bevel + shadow from existing per-theme tokens |
| "on the upside" | yes | yes: top inset marker |
| "this current bracket does not work" | yes | yes, and the cause is named (1.3) |
| "obvious that these are two tabs, which is the selected one" | yes, but O5: no fill difference on desktop | yes: T5 fill difference, T1 marker, muted vs full text |

## 6. Signature

v0.1: **agree with changes**. I sign v1.0 when sections 3 and 4 are folded
in or answered on this task.
