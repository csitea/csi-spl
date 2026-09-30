// Spec 050 — the pure helpers behind the panel collapse triangles
// (utils/pane-collapse.mjs). The store and component build on these; pinning
// them here keeps the direction/side/filler rules honest without a browser.
// Run: node tests/unit/pane-collapse.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  PANES,
  COLLAPSE_STORAGE_KEY,
  COLLAPSE_ACCOUNT_KEY,
  normalizeCollapsed,
  collapseSide,
  fillerPane,
  collapseDir,
  arrowPointsEnd,
  loadCollapsed,
  saveCollapsed,
} from '../../src/utils/pane-collapse.mjs'

describe('pane names + keys', () => {
  it('the three panels, left→right, and the two storage keys', () => {
    assert.deepEqual([...PANES], ['channels', 'topic', 'threads'])
    assert.equal(COLLAPSE_STORAGE_KEY, 'spool.pane-collapsed')
    // the sibling key CLE-35099's SPL-1182 hosts next to pane_sizes
    assert.equal(COLLAPSE_ACCOUNT_KEY, 'pane_collapsed')
  })
})

describe('normalizeCollapsed', () => {
  it('coerces anything to a full {channels,topic,threads} boolean map', () => {
    assert.deepEqual(normalizeCollapsed(null), { channels: false, topic: false, threads: false })
    assert.deepEqual(normalizeCollapsed({ channels: true }), { channels: true, topic: false, threads: false })
    // only strict true is collapsed; truthy-but-not-true stays false
    assert.deepEqual(normalizeCollapsed({ topic: 1, threads: 'yes' }), { channels: false, topic: false, threads: false })
    assert.deepEqual(normalizeCollapsed([1, 2]), { channels: false, topic: false, threads: false })
  })
})

describe('collapseSide (mirrors the close X corner, SPL-1133)', () => {
  it('mac = start (left), windows = end (right), default mac', () => {
    assert.equal(collapseSide('mac'), 'start')
    assert.equal(collapseSide('windows'), 'end')
    assert.equal(collapseSide(null), 'start') // never picked = mac
    assert.equal(collapseSide('garbage'), 'start') // unknown = the default
  })
})

describe('collapseDir (the edge each panel DOCKS to; owner topic 80e40aca)', () => {
  it('channels always docks start, threads always docks end (fixed shell edges)', () => {
    for (const topicOpen of [true, false]) {
      for (const map of [{}, { channels: true }, { topic: true, threads: true }, { channels: true, topic: true, threads: true }]) {
        assert.equal(collapseDir('channels', map, topicOpen), 'start')
        assert.equal(collapseDir('threads', map, topicOpen), 'end')
      }
    }
  })
  it('topic docks toward the edge AWAY from the filler pane (its actual position)', () => {
    // a thread pane is open and not collapsed → it is the filler, on topic's
    // RIGHT, so topic docks to the start (left) — points ◀ open, ▶ collapsed
    assert.equal(collapseDir('topic', { threads: false }, true), 'start')
    // no thread pane → the channels sidebar fills on topic's LEFT, so topic
    // docks to the end (right)
    assert.equal(collapseDir('topic', {}, false), 'end')
    // THE BUG: messages + thread both collapsed, channels open and fills → both
    // strips sit on the right, so topic docks end (its arrow must point ◀)
    assert.equal(collapseDir('topic', { topic: true, threads: true }, true), 'end')
    // channels ALSO collapsed while a thread is open but collapsed → all three
    // strips, no filler; the middle strip leans start
    assert.equal(collapseDir('topic', { channels: true, topic: true, threads: true }, true), 'start')
    // channels collapsed, thread open (filler on the right) → topic docks start
    assert.equal(collapseDir('topic', { channels: true }, true), 'start')
  })
})

describe('arrowPointsEnd across the full state matrix (owner topic 80e40aca)', () => {
  // the edge each pane docks to, reasoned from the flex layout by hand (the
  // filler pane fills the slack; every other pane packs to the edge away from
  // it). topic's dock does not depend on topic's own collapsed flag.
  const topicDock = (topicOpen, chCollapsed, thCollapsed) =>
    topicOpen && !thCollapsed ? 'start' : (!chCollapsed ? 'end' : 'start')
  const bool = [false, true]
  it('the arrow points toward the dock edge when open, back to the interior when collapsed', () => {
    for (const topicOpen of bool) {
      for (const ch of bool) {
        for (const tp of bool) {
          for (const th of bool) {
            const map = { channels: ch, topic: tp, threads: th }
            const dock = { channels: 'start', threads: 'end', topic: topicDock(topicOpen, ch, th) }
            for (const pane of ['channels', 'topic', 'threads']) {
              const collapsed = map[pane]
              const want = collapsed ? dock[pane] === 'start' : dock[pane] === 'end'
              assert.equal(
                arrowPointsEnd(collapsed, pane, map, topicOpen),
                want,
                `${pane} collapsed=${collapsed} topicOpen=${topicOpen} map=${JSON.stringify(map)} dock=${dock[pane]}`,
              )
            }
          }
        }
      }
    }
  })
  it('the LEFT panel (channels) points ◀ open, ▶ collapsed', () => {
    assert.equal(arrowPointsEnd(false, 'channels', { channels: false }, true), false) // ◀ toward its left dock
    assert.equal(arrowPointsEnd(true, 'channels', { channels: true }, true), true) // ▶ back to expand
  })
  it('the RIGHT panel (threads) is the mirror — ▶ open, ◀ collapsed', () => {
    assert.equal(arrowPointsEnd(false, 'threads', { threads: false }, true), true) // ▶ toward its right dock
    assert.equal(arrowPointsEnd(true, 'threads', { threads: true }, true), false) // ◀ back to expand
  })
  it('THE BUG: messages + thread both collapsed → BOTH point ◀ (toward where they expand)', () => {
    const both = { channels: false, topic: true, threads: true }
    // both strips docked to the RIGHT edge → both expand LEFT → both point ◀ (pointsEnd false)
    assert.equal(arrowPointsEnd(true, 'topic', both, true), false)
    assert.equal(arrowPointsEnd(true, 'threads', both, true), false)
  })
})

describe('fillerPane (which panel absorbs the slack)', () => {
  const open = { channels: false, topic: false, threads: false }
  it('normally the middle topic feed', () => {
    assert.equal(fillerPane(open, true), 'topic')
    assert.equal(fillerPane(open, false), 'topic')
  })
  it('when the middle collapses, the open thread pane takes over', () => {
    assert.equal(fillerPane({ ...open, topic: true }, true), 'threads')
  })
  it('middle collapsed and no thread open → the channels sidebar', () => {
    assert.equal(fillerPane({ ...open, topic: true }, false), 'channels')
    // thread present but also collapsed → still fall back to channels
    assert.equal(fillerPane({ channels: false, topic: true, threads: true }, true), 'channels')
  })
  it('every panel collapsed → none (all strips)', () => {
    assert.equal(fillerPane({ channels: true, topic: true, threads: true }, true), 'none')
  })
})

describe('load / save round-trip', () => {
  it('persists and reads back through a Storage-like object', () => {
    const mem = new Map()
    const storage = { getItem: (k) => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, v) }
    assert.deepEqual(loadCollapsed(storage), { channels: false, topic: false, threads: false })
    saveCollapsed(storage, { channels: true, topic: false, threads: true })
    assert.equal(mem.get(COLLAPSE_STORAGE_KEY), '{"channels":true,"topic":false,"threads":true}')
    assert.deepEqual(loadCollapsed(storage), { channels: true, topic: false, threads: true })
  })
  it('tolerates a null storage and corrupt JSON', () => {
    assert.deepEqual(loadCollapsed(null), { channels: false, topic: false, threads: false })
    const bad = { getItem: () => '{not json', setItem: () => {} }
    assert.deepEqual(loadCollapsed(bad), { channels: false, topic: false, threads: false })
    assert.doesNotThrow(() => saveCollapsed(null, { channels: true }))
  })
})
