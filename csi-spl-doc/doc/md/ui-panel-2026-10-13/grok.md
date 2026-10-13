# UI panel, grok seat, 2026-10-13

Lowest-hanging cuts in `csi-spl-wui` on `origin/master` `4ac30d59b`. Doc only.
The sign-in page, its layout, and `LoginFeatures.vue` / `LoginLinks.vue` are
left out (live redesign, SPL-1722).

Eight items, ranked. Speed, the paint the timer actually shows, then
cleanliness. Each one names the files, the gain, the effort, and the command
that proves it.

## Measurements

Box `sat`, 16 cores. Two passes.

| what | value | when |
|---|---|---|
| deployed WUI | `8.1.3`, commit `06a9ecb8de37677b95400f6da20cd35ed99fc481`, built `2026-10-13T20:00:33Z` (`/build.json` on the prd apex) | same `csi-spl-wui` tree as `4ac30d59b`: `git diff --stat 06a9ecb8..4ac30d59b -- csi-spl-wui` is empty (5 commits, none in the WUI) |
| initial JS, `/lobby` and `/200.html` | **3 chunks, 452.1 KB raw, 154.3 KB gzip** | node `v20.19.2` zlib, load `4.11 3.40 3.20`, n=1. Same set as `src/node/test/bundle-size.mjs`: `<script src>` plus `<link rel="modulepreload">`, never prefetch |
| that set, per file | `X0CRYONW.js` 305846 raw / 98077 gzip, `BCquUYUA.js` 126166 / 48657, `Y7KHiUip.js` 30971 / 11303 | same pass. None of the three contains `top-bar`, `composer-target-chip`, `omnibox-resize`, `search-operators`, `shell-late`, or `go-tip` |
| `/` (prerendered) | **83 chunks, 962.9 KB raw, 344.2 KB gzip** | same pass, n=1 |
| CSS named by `/lobby` | **23 files, 108.9 KB raw, 24.9 KB gzip** | same pass |
| prefetch links on `/lobby` | **129** | same pass. `/` names 51 |
| ceiling | `ci_initial_gzip_kb` 155.0 in `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json` | headroom on this node is 0.7 KB. That file's basis says the CI runner's node (`20.20.2`) gzips about 0.7 KB higher than `20.19.2`, so a CI run of this tree sits on the ceiling |
| first paint, `/lobby` | **median 88 ms** (84, 88, 88, 92, 136) | n=5, cold: fresh Chrome profile each round, cache disabled, window 1440×900, headless, load `7.74 6.32 4.62`. Every round painted `.spl-boot` with the text `spool-hub`. `.app-frame` was not up yet |

The first-paint pass blocks the client hop to the sign-in page so the
skeleton's paint is the one recorded. A sample that lands on the sign-in
page is discarded.

The chunk count uses node zlib of the files the HTML names, the same rule as
`csi-spl-wui/src/node/test/bundle-size.mjs`, against the deployed documents
rather than a local `.output/public`.

Two results the numbers already settled, so they are not items:

- Adding `/lobby`'s later chunks to `200.html` as `modulepreload` would count
  them in `ci_initial_gzip_kb`. That set is 154.3 of a 155 ceiling.
- Deleting the `/` modulepreloads as a block made the first row slower in
  spec 109 T003: the bytes fell and the same chunks arrived as a waterfall.
  Item 3 shrinks the closure instead.

## 1. Aesthetic — the 88 ms paint does not match the shell

What. `.spl-boot__side` is hardcoded at `240px`. The shell token
`--sidebar-w` is `260px` (`src/assets/css/variables.css`). The skeleton also
paints the word `spool-hub`. The top bar dropped that word (the comment in
`TopBar.vue`: no brand text, a 28 px logo). First paint is this skeleton,
and it jumps when the shell arrives.

Files. `csi-spl-wui/src/spa-loading-template.html`.

Gain. The first paint keeps the sidebar width and the logo box the shell
uses. No extra download.

Effort. Small. One inline stylesheet.

Measured by:

```bash
python3 -c '
import re
boot=open("csi-spl-wui/src/spa-loading-template.html").read()
var=open("csi-spl-wui/src/assets/css/variables.css").read()
w=re.search(r"--sidebar-w:\s*(\d+)px", var).group(1)
b=re.search(r"spl-boot__side\{[^}]*width:(\d+)px", boot).group(1)
print("sidebar", w, "boot", b)
print("brand", "spl-boot__brand" in boot)
'
```

Today: `sidebar 260 boot 240` and `brand True`. Done when the widths match
and `brand` is `False`. The paint text at FCP is no longer `spool-hub`.

## 2. Speed — prerendered pages have no skeleton

What. `layouts/default.vue` wraps the whole frame, including the page slot,
in `<ClientOnly>` with no fallback. `200.html` paints `.spl-boot` (item 1).
A prerendered default-layout page (`/`, and any other page that does not set
`layout: false` or `layout: 'login'`) ships an empty `#__nuxt` until the JS
runs. `/` then only redirects to `/lobby` (`src/pages/index.vue`).

Files. `csi-spl-wui/src/layouts/default.vue`.

Gain. The prerender paints the same outline as the 88 ms lobby paint,
and the outline is replaced when the frame mounts. Blog and the public
calendar set `layout: false`. The sign-in pages use the other layout.

Effort. Small. A `<ClientOnly>` fallback that reuses the shell's own
placeholder classes (`shell-late`), so the width comes from `--sidebar-w`.

Measured by: after `nuxt generate`, `index.html` contains the fallback, and
`node src/node/test/bundle-size.mjs .output/public --json` still reports
`initial.gzipKB` at or under 155. The fallback is HTML, not another chunk.

## 3. Speed — `/` modulepreloads the composer the lobby does not

What. `layouts/default.vue` static-imports `TopBar.vue` (line 178).
`TopBar.vue` static-imports `MessageComposer.vue` (2003 lines) plus
`TenantDropBox.vue`, `ThemeToggle.vue`, and `TopBarTenant.vue`.
`firstScreenHintsModule` walks that static closure and writes it onto `/`:
83 chunks, 344.2 KB gzip. The same file already loads `OperatorPane` with
`defineAsyncComponent` (line 193), and `feed-first.mjs` already waits until
the first feed rows before it mounts the bar (`shellIn`). The lobby
fallback's 3 chunks do not contain the composer. The cost sits on the
prerendered front door, and on the lobby waterfall that still parses the bar.

Files. `csi-spl-wui/src/layouts/default.vue` only. Leave `TopBar.vue`'s own
imports alone.

Gain. The composer graph leaves `/`'s modulepreload set. `ci_initial_gzip_kb`
stays where it is. `home.gzipKB` drops by whatever those chunks gzip to.
Measure the delta. Do not budget it in advance.

Effort. Small. One import, the pattern already in the file.

Measured by:

```bash
cd csi-spl-wui && node src/node/test/bundle-size.mjs .output/public --json
```

`home.gzipKB` against today's 344.2, and `initial.gzipKB` still at or under
155. A grep of the home document's modulepreload targets no longer finds
`composer-target-chip`.

## 4. Speed — 23 stylesheets before the shell

What. `/lobby` names 23 CSS files, 24.9 KB gzip. The bytes are modest. The
request count is the cost: the real frame waits on them after the skeleton.
The global entry is `css: ["@/assets/css/main.css"]` (1519 lines) plus one
extracted stylesheet per SFC on the first screen.

Files. `csi-spl-wui/nuxt.config.ts` (the `css` array and the first-screen
CSS hints) and `csi-spl-wui/src/assets/css/main.css`.

Gain. The lobby document's style links go from 23 to one or two. Gzip stays
near 25 KB. The win is the wave.

Effort. Medium. Keep the cascade order the shell depends on.

Measured by the same link count: stylesheet plus `rel=preload as=style` on
the lobby HTML. Today 23 files, 24.9 KB gzip. `initial.gzipKB` does not move,
because CSS is outside that sum.

## 5. Aesthetic — the type token names a face that never loads

What. `--font-stack` is `"IBM Plex Sans"` and `--font-mono` is `"IBM Plex
Mono"` (`variables.css`). There is no `@font-face` and no font file in the
WUI. Every OS paints the next face in the stack (`Segoe UI`, then
`system-ui`). The skeleton's own inline font is `system-ui`, so the 88 ms
paint and the hydrated shell can be two different faces.

Files. `csi-spl-wui/src/assets/css/variables.css`, a font file under
`csi-spl-wui/src`, and the preload list in `nuxt.config.ts` `app.head`.

Gain. One face on every OS, the face the tokens already name. Use
`font-display: swap`, so the 88 ms skeleton paint does not wait on the file.

Effort. Small. Two weights of a latin subset (regular and semibold) cover
the UI weights in `main.css` (`font-weight: 600` and the body). Record the
file size with `wc -c`. If the subset is large, ship one weight.

Measured by: `grep -R -c "@font-face" csi-spl-wui/src` prints nothing today. After, a
headless check of `document.fonts.check('16px "IBM Plex Sans")'` is true
once the file has loaded, and the lobby FCP median stays in the same band.

## 6. Clean — `issues.vue` is 4031 lines

What. One SFC holds the page. Template starts at line 9, script at 1136
(about 2000 lines), scoped style at 3174 (about 860 lines). It is the
largest file under `src/`. The next three are the shell: `MessageCard.vue`
2229, `ChannelSidebar.vue` 2224, `MessageComposer.vue` 2003.

Files. `csi-spl-wui/src/pages/issues.vue`. Move the scoped style to a
sibling stylesheet the SFC imports, and move the table into
`src/components/IssuesTable.vue`. Leave the route and the data load in the
page.

Gain. The page file drops by the style plus the table. No change to the
initial JS: this page is outside the 3-chunk set.

Effort. Medium. The style is one block at the bottom, so the first commit
can be that move alone.

Measured by:

```bash
wc -l csi-spl-wui/src/pages/issues.vue
cd csi-spl-wui && node src/node/test/run-unit-tests.mjs
```

Done when the page is under 1500 lines and the unit run is green. Today
`wc -l` is 4031.

## 7. Clean — the sidebar footer is a second component inside the first

What. `ChannelSidebar.vue` (2224 lines) paints the version, the commit
popover, the newer-build reload, and the release-notes button in the footer
(template lines 645–714). The script static-imports `build-stamp.mjs`,
`build-watch.mjs`, and `useBuildWatch` to feed them.
`LazyReleaseNotesDialog` is already its own chunk. The footer is the piece
that does not belong in the rail's setup.

Files. `csi-spl-wui/src/components/ChannelSidebar.vue`, new
`csi-spl-wui/src/components/SidebarVersion.vue`.

Gain. The rail file loses the popover and three imports. The version UI
loads with the footer.

Effort. Small. The markup is one contiguous block.

Measured by: `wc -l csi-spl-wui/src/components/ChannelSidebar.vue` below
today's 2224, and `node src/node/test/run-unit-tests.mjs` green. A search
for `app-version-copy` finds it in the new file only.

## 8. Clean — 133 hand-written ambient modules

What. `src/types/mjs-shims.d.ts` is 2647 lines and 133 `declare module`
blocks, one per `src/utils/*.mjs` the SFC side imports. Every new export is
a hand edit in a second file. The drift shows up as a typecheck failure
well after the `.mjs` change.

Files. `csi-spl-wui/src/types/mjs-shims.d.ts`, plus a generator under
`csi-spl-wui/src/node/` (the tree already generates catalogues there) or a
unit test that reads each `export function` and `export const` and fails
when the shim does not name it.

Gain. One source for an export. Reviewers stop reading a 2647-line twin of
the utils directory.

Effort. Medium. A test is the smaller first step. A generator replaces the
file in the same change only when that test is green on the current 133.

Measured by:

```bash
grep -c '^declare module' csi-spl-wui/src/types/mjs-shims.d.ts
wc -l csi-spl-wui/src/types/mjs-shims.d.ts
cd csi-spl-wui && pnpm run typecheck
```

Today the grep is 133 and the line count is 2647. Done when a missing
export fails the unit run, or the file is produced by the generator and
`typecheck` is green.

## Order

Items 1 and 2 are the paint. Item 3 is the kilobyte cut that leaves the
0.7 KB of `ci_initial_gzip_kb` headroom alone. Item 4 is requests. Item 5
is the face. Items 6–8 are the files a later change keeps tripping over.
None of them edits the sign-in page.
