// Owner, t1 topic e3e9ca61: "whenever I click somewhere else, the snack bar
// and the omnibar should disappear." The one outside-tap rule the snackbars
// and the phone dock share.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { isOutsideTap, isPhoneOrTouch, onOutsideTap, PHONE_OR_TOUCH_QUERY } from '../../src/utils/outside-tap.mjs'

/** A tiny tree: node.contains(x) walks x's parents. */
function node(parent = null) {
  const n = { parent, contains(x) { for (let c = x; c; c = c.parent) if (c === n) return true; return false } }
  return n
}

function fakeDoc() {
  const ls = []
  return {
    ls,
    addEventListener: (type, fn, cap) => ls.push({ type, fn, cap }),
    removeEventListener: (type, fn, cap) => {
      const i = ls.findIndex((l) => l.type === type && l.fn === fn && l.cap === cap)
      if (i >= 0) ls.splice(i, 1)
    },
    tap(target) { for (const l of [...ls]) if (l.type === 'pointerdown') l.fn({ target }) },
  }
}

describe('isOutsideTap', () => {
  const page = node()
  const snack = node(page)
  const btn = node(snack)
  const feed = node(page)
  it('a tap on the root or inside it is not outside', () => {
    assert.equal(isOutsideTap(snack, [snack]), false)
    assert.equal(isOutsideTap(btn, [snack]), false)
  })
  it('a tap on the feed is outside', () => {
    assert.equal(isOutsideTap(feed, [snack]), true)
  })
  it('any of several roots counts as inside; a null root is skipped', () => {
    const dock = node(page)
    assert.equal(isOutsideTap(dock, [null, snack, dock]), false)
    assert.equal(isOutsideTap(feed, [null, snack, dock]), true)
  })
  it('no target is outside', () => {
    assert.equal(isOutsideTap(null, [snack]), true)
  })
})

describe('onOutsideTap', () => {
  it('fires for an outside pointerdown only, in the capture phase, until removed', () => {
    const doc = fakeDoc()
    const page = node()
    const root = node(page)
    const inner = node(root)
    let n = 0
    const off = onOutsideTap(doc, () => [root], () => { n++ })
    assert.equal(doc.ls[0].cap, true)
    doc.tap(inner)
    assert.equal(n, 0)
    doc.tap(page)
    assert.equal(n, 1)
    off()
    assert.equal(doc.ls.length, 0)
    doc.tap(page)
    assert.equal(n, 1)
  })
})

describe('isPhoneOrTouch', () => {
  it('asks the phone-or-touch query', () => {
    let asked = ''
    const win = { matchMedia(q) { asked = q; return { matches: true } } }
    assert.equal(isPhoneOrTouch(win), true)
    assert.equal(asked, PHONE_OR_TOUCH_QUERY)
  })
  it('false without matchMedia or when it throws', () => {
    assert.equal(isPhoneOrTouch({}), false)
    assert.equal(isPhoneOrTouch({ matchMedia() { throw new Error('x') } }), false)
  })
})
