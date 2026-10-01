// CLE-77871: after Undo the card that came back is selected again (focus with
// the focus-visible highlight, its feed scrolled to it) - utils/reselect-row.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { findRow, paneOfRow, reselectRow } from '../../src/utils/reselect-row.mjs'

/** A row stub: `pane` is 'topic' or 'main'; records how it was focused. */
function row(id, pane) {
  return {
    id, pane, focused: null,
    closest: (sel) => (sel === '.topic' && pane === 'topic' ? {} : null),
    getClientRects: () => [{}],
    getBoundingClientRect: () => ({ top: 0, bottom: 10 }),
    focus(opts) { this.focused = opts || {} },
    parentElement: null,
  }
}

/** A document stub over a mutable list of rows. */
function doc(rows) {
  const d = {
    rows,
    scrollingElement: {},
    documentElement: {},
    defaultView: { getComputedStyle: () => ({ overflowY: 'visible' }) },
    querySelector: (sel) => d.querySelectorAll(sel)[0] || null,
    querySelectorAll(sel) {
      const id = /data-msg-id="([^"]+)"/.exec(sel)?.[1]
      const scope = sel.startsWith('.topic ') ? 'topic' : sel.startsWith('.spool-main ') ? 'main' : ''
      return d.rows.filter((r) => r.id === id && (!scope || r.pane === scope))
    },
  }
  return d
}

/** Timers you step by hand. */
function clock() {
  const q = []
  return { set: (fn) => { q.push(fn) }, step() { const fn = q.shift(); if (fn) fn(); return Boolean(fn) } }
}

describe('reselect-row', () => {
  it('paneOfRow names the right pane, main otherwise, "" for nothing', () => {
    assert.equal(paneOfRow(row('a', 'topic')), 'topic')
    assert.equal(paneOfRow(row('a', 'main')), 'main')
    assert.equal(paneOfRow(null), '')
  })

  it('findRow prefers the pane the row was in', () => {
    const t = row('a', 'topic')
    const m = row('a', 'main')
    const d = doc([m, t])
    assert.equal(findRow('a', 'topic', d), t)
    assert.equal(findRow('a', 'main', d), m)
    assert.equal(findRow('a', '', d), m)
    assert.equal(findRow('b', '', d), null)
  })

  it('selects the row as soon as the re-read brings it back, with the visible focus', async () => {
    const d = doc([])
    const c = clock()
    const done = reselectRow('a', { doc: d, set: c.set })
    c.step()
    const back = row('a', 'main')
    d.rows.push(back)
    c.step()
    assert.equal(await done, true)
    assert.deepEqual(back.focused, { preventScroll: true, focusVisible: true })
  })

  it('a row that never comes back selects nothing and gives up', async () => {
    const d = doc([])
    const c = clock()
    const done = reselectRow('a', { doc: d, set: c.set, wait: 200 })
    let n = 0
    while (c.step()) n++
    assert.equal(await done, false)
    assert.ok(n >= 3 && n <= 5, `polled ${n} times`)
  })

  it('no id selects nothing', async () => {
    assert.equal(await reselectRow('', { doc: doc([]) }), false)
  })
})
