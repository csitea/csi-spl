import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { memoryStore } from '../../src/utils/prefs.mjs'
import {
  SIDEBAR_DEFAULT,
  TOPIC_DEFAULT,
  SIDEBAR_MIN,
  SIDEBAR_MAX_RATIO,
  sidebarMaxPx,
  TOPIC_MIN,
  TOPIC_MAX_RATIO,
  topicMaxPx,
  MAIN_MIN,
  DIVIDER_W,
  STEP,
  PANE_WIDTHS_KEY,
  SIDEBAR_NARROW_MAX,
  TOPIC_NARROW_MAX,
  clamp,
  num,
  sidebarShown,
  topicShown,
  clampSidebar,
  clampTopic,
  clampPair,
  sidebarRange,
  topicRange,
  applySeparatorKey,
  pointerDelta,
  loadPaneWidths,
  savePaneWidths,
  resetPane,
} from '../../src/utils/pane-widths.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function read(rel) {
  return readFileSync(join(WUI, rel), 'utf8')
}

describe('pane-widths clamp', () => {
  it('num falls back for junk and clamp bounds a value', () => {
    assert.equal(num('260', 1), 260)
    assert.equal(num('nope', 7), 7)
    assert.equal(num(Infinity, 7), 7)
    assert.equal(clamp(100, 180, 420), 180)
    assert.equal(clamp(500, 180, 420), 420)
    assert.equal(clamp(200, 180, 420), 200)
  })

  it('defaults sit inside the static min/max', () => {
    assert.equal(SIDEBAR_DEFAULT, 260)
    assert.equal(TOPIC_DEFAULT, 380)
    assert.equal(SIDEBAR_MAX_RATIO, 0.35)
    assert.ok(SIDEBAR_DEFAULT >= SIDEBAR_MIN && SIDEBAR_DEFAULT <= sidebarMaxPx(1280))
    assert.ok(TOPIC_DEFAULT >= TOPIC_MIN && TOPIC_DEFAULT <= topicMaxPx(1280))
  })

  it('the left divider stops at 35% counted from the left edge of the screen', () => {
    for (const w of [1280, 1440, 1920]) {
      const mark = Math.round(w * 0.35)
      assert.equal(sidebarMaxPx(w), mark)
      assert.equal(clampSidebar(9999, { viewportW: w, topicOpen: false }), mark)
      /* a fully stretched topic does not move that mark */
      assert.equal(clampSidebar(9999, { viewportW: w, topicOpen: true, topicW: topicMaxPx(w) }), mark)
      assert.equal(sidebarRange({ viewportW: w, topicOpen: true, topicW: topicMaxPx(w) }).max, mark)
    }
  })

  it('clamps sidebar below min and above max', () => {
    const ctx = { viewportW: 1280, topicOpen: false }
    assert.equal(clampSidebar(0, ctx), SIDEBAR_MIN)
    assert.equal(clampSidebar(9999, ctx), sidebarMaxPx(1280))
    assert.equal(clampSidebar(260, ctx), 260)
  })

  it('clamps topic below min and above max when the pane is in flow', () => {
    const ctx = { viewportW: 1920, topicOpen: true, sidebarW: 260 }
    assert.equal(clampTopic(0, ctx), TOPIC_MIN)
    assert.equal(clampTopic(9999, ctx), topicMaxPx(1920))
    assert.equal(topicMaxPx(1920), Math.round(1920 * TOPIC_MAX_RATIO))
    assert.equal(clampTopic(380, ctx), 380)
  })

  it('a stretched topic yields so the left divider can sit at 35%', () => {
    const w = 1280
    const pair = clampPair(sidebarMaxPx(w), topicMaxPx(w), { viewportW: w, topicOpen: true })
    assert.equal(pair.sidebar, Math.round(w * 0.35))
    const used = pair.sidebar + pair.topic + 2 * DIVIDER_W
    assert.ok(w - used >= MAIN_MIN, `main=${w - used}`)
    assert.ok(pair.topic < topicMaxPx(w))
  })

  it('keeps the main feed at least MAIN_MIN when the topic is closed', () => {
    const s = clampSidebar(9999, { viewportW: 900, topicOpen: false })
    assert.equal(s, sidebarMaxPx(900))
    assert.ok(900 - s - DIVIDER_W >= MAIN_MIN)
  })

  it('does not apply the topic width against the budget when the pane is closed', () => {
    const pair = clampPair(260, 560, { viewportW: 900, topicOpen: false })
    assert.equal(pair.sidebar, 260)
    assert.equal(pair.topic, 560)
  })

  it('hides the sidebar divider at the rail breakpoint and the topic divider when overlaying', () => {
    assert.equal(sidebarShown(SIDEBAR_NARROW_MAX), false)
    assert.equal(sidebarShown(SIDEBAR_NARROW_MAX + 1), true)
    assert.equal(topicShown(TOPIC_NARROW_MAX, true), false)
    assert.equal(topicShown(TOPIC_NARROW_MAX + 1, true), true)
    assert.equal(topicShown(1400, false), false)
  })

  it('sidebarRange / topicRange report the live min/max', () => {
    const ctx = { viewportW: 1920, topicOpen: true, topicW: 380, sidebarW: 260 }
    const s = sidebarRange(ctx)
    const t = topicRange(ctx)
    assert.equal(s.min, SIDEBAR_MIN)
    assert.equal(s.max, sidebarMaxPx(1920))
    assert.equal(t.min, TOPIC_MIN)
    assert.equal(t.max, topicMaxPx(1920))
  })
})

describe('pane-widths keyboard and pointer', () => {
  it('ArrowLeft/Right move the sidebar separator; Home/End snap', () => {
    assert.equal(applySeparatorKey('sidebar', 'ArrowRight', 260, 180, 420), 260 + STEP)
    assert.equal(applySeparatorKey('sidebar', 'ArrowLeft', 260, 180, 420), 260 - STEP)
    assert.equal(applySeparatorKey('sidebar', 'Home', 260, 180, 420), 180)
    assert.equal(applySeparatorKey('sidebar', 'End', 260, 180, 420), 420)
    assert.equal(applySeparatorKey('sidebar', 'ArrowLeft', 180, 180, 420), 180)
    assert.equal(applySeparatorKey('sidebar', 'Tab', 260, 180, 420), 260)
  })

  it('ArrowLeft grows the topic (separator moves left); Home is max', () => {
    assert.equal(applySeparatorKey('topic', 'ArrowLeft', 380, 280, 560), 380 + STEP)
    assert.equal(applySeparatorKey('topic', 'ArrowRight', 380, 280, 560), 380 - STEP)
    assert.equal(applySeparatorKey('topic', 'Home', 380, 280, 560), 560)
    assert.equal(applySeparatorKey('topic', 'End', 380, 280, 560), 280)
  })

  it('pointerDelta grows the sidebar to the right and the topic to the left', () => {
    assert.equal(pointerDelta('sidebar', 260, 100, 140), 300)
    assert.equal(pointerDelta('topic', 380, 100, 140), 340)
    assert.equal(pointerDelta('topic', 380, 100, 60), 420)
  })

  it('resetPane returns the CSS default for that pane', () => {
    assert.equal(resetPane('sidebar'), SIDEBAR_DEFAULT)
    assert.equal(resetPane('topic'), TOPIC_DEFAULT)
  })
})

describe('pane-widths persist', () => {
  it('round-trips JSON through storage try/catch', () => {
    const store = memoryStore()
    assert.deepEqual(loadPaneWidths(store), { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT })
    assert.equal(savePaneWidths({ sidebar: 300, topic: 400 }, store), true)
    assert.equal(store.getItem(PANE_WIDTHS_KEY), JSON.stringify({ sidebar: 300, topic: 400 }))
    assert.deepEqual(loadPaneWidths(store), { sidebar: 300, topic: 400 })
  })

  it('returns defaults when storage throws or JSON is junk', () => {
    const boom = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') } }
    assert.deepEqual(loadPaneWidths(boom), { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT })
    assert.equal(savePaneWidths({ sidebar: 300, topic: 400 }, boom), false)
    const junk = memoryStore({ [PANE_WIDTHS_KEY]: '{nope' })
    assert.deepEqual(loadPaneWidths(junk), { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT })
    const bad = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify(['x']) })
    assert.deepEqual(loadPaneWidths(bad), { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT })
    const partial = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 'nope', topic: 410 }) })
    assert.deepEqual(loadPaneWidths(partial), { sidebar: SIDEBAR_DEFAULT, topic: 410 })
  })

  it('PANE_WIDTHS_KEY is the FR-003 allow-list name spool.pane-widths', () => {
    assert.equal(PANE_WIDTHS_KEY, 'spool.pane-widths')
  })
})

describe('pane-widths wiring', () => {
  it('layout hosts two PaneDividers and applies CSS vars on the shell', () => {
    const layout = read('src/layouts/default.vue')
    assert.equal(layout.includes('<PaneDivider'), true)
    assert.equal(layout.includes('pane="sidebar"'), true)
    assert.equal(layout.includes('pane="topic"'), true)
    assert.equal(layout.includes('topicPaneOpen'), true)
    assert.equal(layout.includes(':style="shellStyle"'), true)
    const composable = read('src/composables/usePaneWidths.ts')
    assert.equal(composable.includes('--sidebar-w'), true)
    assert.equal(composable.includes('--topic-w'), true)
    assert.equal(composable.includes('loadPaneWidths'), true)
    assert.equal(composable.includes('savePaneWidths'), true)
  })

  it('PaneDivider is a vertical ARIA separator with keyboard and pointer hooks', () => {
    const src = read('src/components/PaneDivider.vue')
    assert.equal(src.includes('role="separator"'), true)
    assert.equal(src.includes('aria-orientation="vertical"'), true)
    assert.equal(src.includes('aria-valuenow'), true)
    assert.equal(src.includes('aria-valuemin'), true)
    assert.equal(src.includes('aria-valuemax'), true)
    assert.equal(src.includes('tabindex="0"'), true)
    assert.equal(src.includes('@pointerdown'), true)
    assert.equal(src.includes('@keydown'), true)
    assert.equal(src.includes('@dblclick'), true)
    assert.equal(src.includes('applySeparatorKey'), true)
    assert.equal(src.includes('pointerDelta'), true)
    const down = src.slice(src.indexOf('function onDown'), src.indexOf('function onMove'))
    assert.equal(down.includes('e.preventDefault'), false, 'pointerdown must not preventDefault (dblclick reset)')
    assert.equal(src.includes('Math.abs(e.clientX - startX.value) < 3'), true)
    assert.equal(src.includes('lastTapAt'), true)
    assert.equal(src.includes("emit('reset')"), true)
  })

  it('CSS hides dividers when the matching pane is collapsed or overlaying', () => {
    const css = read('src/assets/css/main.css')
    assert.equal(css.includes('.pane-divider'), true)
    assert.equal(css.includes('col-resize'), true)
    assert.equal(/@media \(max-width: 800px\)[^{]*\{[^}]*pane-divider-sidebar/.test(css)
      || css.includes('[data-pane="sidebar"]'), true)
    assert.equal(css.includes('[data-pane="topic"]'), true)
    assert.equal(css.includes('max-width: 1100px'), true)
  })
})
