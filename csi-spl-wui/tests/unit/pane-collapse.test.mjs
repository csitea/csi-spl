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
  pointsRight,
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

describe('pointsRight (open ◀ / collapsed ▶ in LTR; CSS mirrors RTL)', () => {
  it('the glyph points right only when the panel is collapsed', () => {
    assert.equal(pointsRight(false), false) // open → points left (close)
    assert.equal(pointsRight(true), true) // collapsed → points right (open)
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
