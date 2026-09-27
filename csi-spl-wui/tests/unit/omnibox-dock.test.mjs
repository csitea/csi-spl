// Topic c6994436 lane B: the Omnibox at the bottom on tablet and desktop.
//
// Every risk the three evaluations named (CLE-35047/35048/35049, topic
// c6994436, 2026-09-27) that a pure rule or the source can pin is pinned
// here; the geometry (dock under the middle pane only, popovers inside the
// window, the feed not covered) is tests/e2e/omnibox-bottom.test.mjs.
//
// Run: node tests/unit/omnibox-dock.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DEFAULT_POSITION, DOCK_ID, omniboxAtBottom, omniboxMaxHeight, parsePosition, resizeHeight } from '../../src/utils/omnibox-dock.mjs'
import { paneOfTarget } from '../../src/utils/pane-focus.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')

describe('the setting', () => {
  it('the default is today\'s layout: at the top', () => {
    assert.equal(DEFAULT_POSITION, 'top')
    for (const v of [undefined, null, '', 'TOP', 'left', 1, 'top']) assert.equal(parsePosition(v), 'top')
    assert.equal(parsePosition('bottom'), 'bottom')
  })
  it('bottom only above 820 px - a phone has its own dock in either setting', () => {
    assert.equal(omniboxAtBottom({ position: 'bottom', phone: false }), true)
    assert.equal(omniboxAtBottom({ position: 'bottom', phone: true }), false)
    assert.equal(omniboxAtBottom({ position: 'top', phone: false }), false)
    assert.equal(omniboxAtBottom({ position: null, phone: false }), false)
    assert.equal(omniboxAtBottom(), false)
  })
})

describe('B2: the grip', () => {
  it('in the top bar dragging DOWN grows the box (unchanged)', () => {
    assert.equal(resizeHeight({ startH: 100, startY: 500, y: 560, max: 900 }), 160)
  })
  it('in the bottom dock dragging UP grows it, down shrinks it', () => {
    assert.equal(resizeHeight({ startH: 100, startY: 500, y: 440, bottom: true, max: 900 }), 160)
    assert.equal(resizeHeight({ startH: 100, startY: 500, y: 560, bottom: true, max: 900 }), 40)
  })
  it('stays between one line and the cap', () => {
    assert.equal(resizeHeight({ startH: 100, startY: 500, y: 900, bottom: true, max: 900 }), 36)
    assert.equal(resizeHeight({ startH: 100, startY: 500, y: 0, bottom: true, max: 300 }), 300)
  })
})

describe('B1: the box in the dock pushes the feed up, it never eats the pane', () => {
  it('the top bar box may reach the window bottom (unchanged)', () => {
    assert.equal(omniboxMaxHeight({ innerHeight: 900 }), 900 - 58 - 8)
  })
  it('the dock stops at 60% of the space under the bar', () => {
    assert.equal(omniboxMaxHeight({ innerHeight: 900, bottom: true }), Math.floor((900 - 58) * 0.6))
    assert.ok(omniboxMaxHeight({ innerHeight: 900, bottom: true }) < 900 - 58 - 100)
  })
})

describe('B6: typing in the dock does not choose the middle pane', () => {
  const inDock = { closest: (s) => (s === '.omnibox-dock' || s === '.spool-main' ? {} : null) }
  it('a pointerdown in the dock chooses nothing, a row in the middle still does', () => {
    assert.equal(paneOfTarget(inDock), '')
    assert.equal(paneOfTarget({ closest: (s) => (s === '.spool-main' ? {} : null) }), 'middle')
  })
})

describe('wiring', () => {
  const topBar = read('components/TopBar.vue')
  const layout = read('layouts/default.vue')
  const composer = read('components/MessageComposer.vue')
  const css = read('assets/css/main.css')
  it('ONE composer: TopBar moves it with a Teleport (draft and files survive), never mounts a second', () => {
    assert.equal((topBar.match(/<MessageComposer\b/g) || []).length, 1)
    assert.match(topBar, /<Teleport :to="dockSelector" :disabled="!atBottom" defer>/)
    assert.match(topBar, /const dockSelector = `#\$\{DOCK_ID\}`/)
    assert.equal((layout.match(/<MessageComposer\b/g) || []).length, 0)
  })
  it('the dock is the last child of the MIDDLE pane, not of the shell (not over the rail or the thread)', () => {
    const main = layout.slice(layout.indexOf('<main class="spool-main">'), layout.indexOf('</main>'))
    assert.match(main, /<slot \/>[\s\S]*:id="DOCK_ID"/)
    assert.equal(DOCK_ID, 'spl-omnibox-dock')
  })
  it('the dock takes no room while off, so the default desktop is unchanged', () => {
    assert.match(css, /\.omnibox-dock \{ display: none; \}/)
    assert.match(css, /\.omnibox-dock\[data-on="true"\] \{/)
  })
  it('B3: pickers, syntax help and the GO tip open UPWARD in the dock', () => {
    assert.match(composer, /\.omnibox--bottom\.omnibox--global \.mention-list \{\s*top: auto;\s*bottom: 100%;/)
    assert.match(composer, /\.omnibox--bottom \.search-syntax \{\s*top: auto;\s*bottom: calc\(100% \+ 4px\);/)
    assert.match(composer, /\.omnibox--bottom \.composer-go__tip \{\s*top: auto;\s*bottom: calc\(100% \+ 6px\);/)
  })
  it('B4: the send error sits above the box in the dock', () => {
    assert.match(topBar, /\.top-bar__omnibox--bottom \.top-bar__send-error \{ order: -1;/)
  })
  it('B6: the dock names where the post goes (SPL-1003 hint) on a desktop too', () => {
    assert.match(composer, /v-if="\(docked \|\| bottom\) && !searchMode && dockHint"/)
  })
  it('the panes that overlay the middle one at <= 1100 px end above the dock', () => {
    assert.match(css, /\.live-pane \{[\s\S]*?bottom: var\(--omnibox-dock-h, 0px\);/)
    assert.match(read('pages/issues.vue'), /\.issues-detail \{[\s\S]*?bottom: var\(--omnibox-dock-h, 0px\);/)
  })
  it('B10: the dock rides above a tablet keyboard', () => {
    assert.match(css, /\.omnibox-dock\[data-on="true"\] \{[\s\S]*?calc\(6px \+ var\(--kb-inset, 0px\)\)/)
  })
  it('search stays one tap away in the top bar while the box is at the bottom', () => {
    assert.match(topBar, /data-test="top-bar-search"/)
    assert.match(topBar, /setText\('\/search '\)/)
  })
})
