// CLE-77884: the left-panel compact list (Search results / Flow entries).
// Run: node tests/unit/side-hit-list.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cycleIndex, groupRuns, itemSegments } from '../../src/utils/side-hit-list.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('cycleIndex', () => {
  it('wraps ArrowDown / ArrowUp and jumps Home / End', () => {
    assert.equal(cycleIndex(-1, 3, 'ArrowDown'), 0)
    assert.equal(cycleIndex(2, 3, 'ArrowDown'), 0)
    assert.equal(cycleIndex(0, 3, 'ArrowUp'), 2)
    assert.equal(cycleIndex(-1, 3, 'ArrowUp'), 2)
    assert.equal(cycleIndex(1, 3, 'Home'), 0)
    assert.equal(cycleIndex(1, 3, 'End'), 2)
  })
  it('an empty list has no active entry', () => {
    assert.equal(cycleIndex(0, 0, 'ArrowDown'), -1)
  })
  it('an out-of-range index restarts', () => {
    assert.equal(cycleIndex(9, 3, 'ArrowDown'), 0)
    assert.equal(cycleIndex(1, 3, 'x'), 1)
  })
})

describe('groupRuns', () => {
  it('consecutive items of one group share a heading, flat indexes kept', () => {
    const runs = groupRuns([
      { key: 'a', group: 'Messages' },
      { key: 'b', group: 'Messages' },
      { key: 'c', group: 'Files' },
      { key: 'd' },
    ])
    assert.deepEqual(runs.map((r) => r.group), ['Messages', 'Files', ''])
    assert.deepEqual(runs.flatMap((r) => r.items.map((x) => x.index)), [0, 1, 2, 3])
  })
  it('null is no runs', () => assert.deepEqual(groupRuns(null), []))
})

describe('itemSegments', () => {
  it('prefers the marked segments, falls back to the plain text', () => {
    assert.deepEqual(itemSegments({ segs: [{ text: 'x', mark: true }], text: 'y' }), [{ text: 'x', mark: true }])
    assert.deepEqual(itemSegments({ text: 'y' }), [{ text: 'y', mark: false }])
    assert.deepEqual(itemSegments({}), [])
  })
})

describe('SideHitList.vue carries the shared acceptance hooks (lane D)', () => {
  const src = read('src/components/SideHitList.vue')
  it('listbox + mode, option + msg id + selection', () => {
    assert.match(src, /role="listbox"/)
    assert.match(src, /data-testid="left-list"/)
    assert.match(src, /:data-mode="mode"/)
    assert.match(src, /role="option"/)
    assert.match(src, /data-testid="left-entry"/)
    assert.match(src, /:data-msg-id="item\.msgId \|\| item\.key"/)
    assert.match(src, /:aria-selected=/)
  })
})
