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
  TOPIC_DEFAULT_RATIO,
  topicDefaultFor,
  mainWidthFor,
  loadStoredTopic,
  PANE_VIEWS,
  viewOf,
  paneViews,
  paneSetFor,
  loadPaneViews,
  clearPaneWidths,
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

describe('pane-widths proportional default (spec 078 FR-006, AC5)', () => {
  it('is 40% of the space right of the left pane: 1174 -> 470, 1654 -> 662', () => {
    assert.equal(TOPIC_DEFAULT_RATIO, 0.4)
    assert.equal(topicDefaultFor(1174), 470)
    assert.equal(topicDefaultFor(1654), 662)
  })

  it('the main width is the window less the left pane and its divider', () => {
    assert.equal(mainWidthFor(1440, 260), 1174)
    assert.equal(mainWidthFor(1920, 260), 1654)
    /* the stored sidebar is clamped first; the rail breakpoint has no sidebar */
    assert.equal(mainWidthFor(1440, 9999), 1440 - sidebarMaxPx(1440) - DIVIDER_W)
    assert.equal(mainWidthFor(SIDEBAR_NARROW_MAX, 260), SIDEBAR_NARROW_MAX)
  })

  it('clamps at TOPIC_MIN, TOPIC_MAX_RATIO and MAIN_MIN', () => {
    assert.equal(topicDefaultFor(500), TOPIC_MIN)
    assert.equal(topicDefaultFor(700), TOPIC_MIN)
    assert.ok(topicDefaultFor(5000) <= Math.round(5000 * TOPIC_MAX_RATIO))
    for (const main of [700, 900, 1000, 1174, 1654, 3000]) {
      const t = topicDefaultFor(main)
      assert.ok(t >= TOPIC_MIN, `main=${main} t=${t}`)
      if (main - DIVIDER_W - MAIN_MIN >= TOPIC_MIN) assert.ok(main - t - DIVIDER_W >= MAIN_MIN, `main=${main} t=${t}`)
    }
    assert.equal(topicDefaultFor(0), TOPIC_DEFAULT)
    assert.equal(topicDefaultFor('junk'), TOPIC_DEFAULT)
  })

  it('the default survives clampPair at 1440 and 1920 (no truncating 380)', () => {
    for (const [w, want] of [[1440, 470], [1920, 662]]) {
      const pair = clampPair(260, topicDefaultFor(mainWidthFor(w, 260)), { viewportW: w, topicOpen: true })
      assert.equal(pair.topic, want)
    }
  })

  it('composable uses the default only when nothing is stored, and sets --topic-w from it', () => {
    const src = read('src/composables/usePaneWidths.ts')
    assert.equal(src.includes('storedTopic.value ?? topicDefaultFor(mainWidthFor('), true)
    assert.equal(src.includes('loadStoredTopic(undefined, v)'), true)
    assert.equal(src.includes('ref(TOPIC_DEFAULT)'), false)
    const css = read('src/assets/css/variables.css')
    assert.equal(/--topic-w:\s*380px/.test(css), false, 'variables.css is no longer the source')
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
    assert.equal(pointerDelta('issue', 380, 100, 60), 420)
    assert.equal(applySeparatorKey('issue', 'ArrowLeft', 380, 280, 720), 380 + STEP)
    assert.equal(applySeparatorKey('issue', 'ArrowRight', 380, 280, 720), 380 - STEP)
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
    assert.equal(store.getItem(PANE_WIDTHS_KEY), JSON.stringify({ views: { default: { sidebar: 300, topic: 400 } } }))
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

  it('loadStoredTopic is null until a topic width is dragged', () => {
    assert.equal(loadStoredTopic(memoryStore()), null)
    assert.equal(loadStoredTopic(memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 300 }) })), null)
    assert.equal(loadStoredTopic(memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 300, topic: 'x' }) })), null)
    assert.equal(loadStoredTopic(memoryStore({ [PANE_WIDTHS_KEY]: '{nope' })), null)
    assert.equal(loadStoredTopic(memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 300, topic: 410 }) })), 410)
  })

  it('a null topic drops the stored width so the default applies again', () => {
    const store = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 260, topic: 500, issues: 440 }) })
    assert.equal(savePaneWidths({ sidebar: 300, topic: null }, store), true)
    assert.deepEqual(JSON.parse(store.getItem(PANE_WIDTHS_KEY)), { issues: 440, views: { default: { sidebar: 300 } } })
    assert.equal(loadStoredTopic(store), null)
  })

  it('keeps the issue detail width when the sidebar is saved again', () => {
    const store = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 260, topic: 380, issues: 440 }) })
    assert.equal(savePaneWidths({ sidebar: 300, topic: 400 }, store), true)
    assert.deepEqual(JSON.parse(store.getItem(PANE_WIDTHS_KEY)), { issues: 440, views: { default: { sidebar: 300, topic: 400 } } })
  })

  it('PANE_WIDTHS_KEY is the FR-003 allow-list name spool.pane-widths', () => {
    assert.equal(PANE_WIDTHS_KEY, 'spool.pane-widths')
  })
})

describe('pane-widths per view (spec 078 FR-007, AC7)', () => {
  it('viewOf maps a route to its view; any other page is default', () => {
    assert.deepEqual(PANE_VIEWS, ['default', 'channel', 'issues', 'help', 'docs'])
    assert.equal(viewOf('/channel/lobby'), 'channel')
    assert.equal(viewOf({ path: '/dm/peer-1' }), 'channel')
    assert.equal(viewOf('/issues'), 'issues')
    assert.equal(viewOf('/issues?id=x'), 'issues')
    assert.equal(viewOf('/help'), 'help')
    assert.equal(viewOf('/help/interface-overview'), 'help')
    assert.equal(viewOf('/docs'), 'docs')
    for (const p of ['/', '/t/abc', '/search', '/people', '/issuesx', '/documents', '', null]) {
      assert.equal(viewOf(p), 'default', String(p))
    }
  })

  it('AC7: drag-commit in view issues leaves channel unchanged', () => {
    const store = memoryStore()
    assert.equal(savePaneWidths({ sidebar: 300, topic: 520 }, store, 'channel'), true)
    assert.equal(savePaneWidths({ sidebar: 240, topic: 360 }, store, 'issues'), true)
    assert.deepEqual(loadPaneWidths(store, 'channel'), { sidebar: 300, topic: 520 })
    assert.deepEqual(loadPaneWidths(store, 'issues'), { sidebar: 240, topic: 360 })
    assert.equal(loadStoredTopic(store, 'channel'), 520)
    // a view never dragged falls back to default, then to the product default
    assert.deepEqual(loadPaneWidths(store, 'help'), { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT })
    assert.equal(loadStoredTopic(store, 'help'), null)
  })

  it('AC7: a stored flat {sidebar: .2, topic: .3} loads as default', () => {
    assert.deepEqual(paneViews({ sidebar: 0.2, topic: 0.3 }), { default: { sidebar: 0.2, topic: 0.3 } })
    assert.deepEqual(paneSetFor(paneViews({ sidebar: 0.2, topic: 0.3 }), 'issues'), { sidebar: 0.2, topic: 0.3 })
    const flat = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ sidebar: 300, topic: 410, issues: 440 }) })
    assert.deepEqual(loadPaneViews(flat), { default: { sidebar: 300, topic: 410 } })
    assert.deepEqual(loadPaneWidths(flat, 'channel'), { sidebar: 300, topic: 410 })
    // the first per-view save keeps the old flat pair as default
    assert.equal(savePaneWidths({ sidebar: 250, topic: 500 }, flat, 'docs'), true)
    assert.deepEqual(JSON.parse(flat.getItem(PANE_WIDTHS_KEY)), {
      issues: 440,
      views: { default: { sidebar: 300, topic: 410 }, docs: { sidebar: 250, topic: 500 } },
    })
  })

  it('paneViews keeps known views with finite widths and drops junk', () => {
    assert.deepEqual(paneViews(null), {})
    assert.deepEqual(paneViews(['x']), {})
    assert.deepEqual(paneViews({ channel: { topic: 0.4, x: 1 }, search: { topic: 0.3 }, docs: 'x', help: {} }),
      { channel: { topic: 0.4 } })
    assert.deepEqual(paneViews({ sidebar: 'nope', topic: 410 }), { default: { topic: 410 } })
    assert.equal(paneSetFor({}, 'channel'), null)
  })

  it('the issue detail width is not a view: it survives saves and reset', () => {
    const store = memoryStore({ [PANE_WIDTHS_KEY]: JSON.stringify({ issues: 440 }) })
    savePaneWidths({ sidebar: 260, topic: 400 }, store, 'issues')
    assert.equal(JSON.parse(store.getItem(PANE_WIDTHS_KEY)).issues, 440)
    assert.equal(clearPaneWidths(store), true)
    assert.deepEqual(JSON.parse(store.getItem(PANE_WIDTHS_KEY)), { issues: 440 })
  })

  it('composable: commit writes only the current view; a view change lands the pending drag first', () => {
    const src = read('src/composables/usePaneWidths.ts')
    assert.equal(src.includes('const view = computed(() => viewOf(route.path))'), true)
    assert.equal(src.includes('{ ...paneViews(session.claims?.pane_sizes), [v]: f }'), true)
    assert.equal(src.includes('if (commitTimer) commit(prev)'), true)
    assert.equal(src.includes('paneSetFor(paneViews(session.claims?.pane_sizes), v)'), true)
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
