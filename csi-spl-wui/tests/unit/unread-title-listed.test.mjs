// SPL-3587 (owner HUM-10, csitea topic 739eb4f1, 2026-10-26: "once again the
// unread msgs are not shown correctly"). The screenshot: #ops open with a
// row badge 1, the Channels rail 1, and the tab "(3)". Measured on prd the
// same day: the owner had 2 uncovered flow events under ch:issues (hub
// "Resolved: ... cleared the blocker mark" lines in issue topics with no
// live head). The issues board has no sidebar row, yet the title added every
// ch: key the hub sent: 1 + 2 = 3, while the rail summed only listed rows.
// And a card's open zeroed its t: key but not its channel's ch: key, so the
// open channel's row kept a count no card showed until the hub's next frame.
//
// Run: node tests/unit/unread-title-listed.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tabUnread, unreadModel } from '../../src/utils/unread-model.mjs'
import { dropTopicKey } from '../../src/utils/flow-keys.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

// The screenshot's shape, as the hub sent it.
const KEYS = { 'ch:ops': 1, 't:f02eae50': 1, 'ch:issues': 2, 't:88be75ab': 1, 't:b4322c67': 1 }
const LISTED = ['ops', 'spool-hub', 'lobby']

describe('the tab title is the sum of the listed rows (spec 079 FR-006)', () => {
  const { rows } = unreadModel({ keys: KEYS })

  it('a ch: key with no sidebar row stays out of the title', () => {
    assert.equal(tabUnread(rows, LISTED), 1, 'the screenshot read (3) here')
  })

  it('it equals the rail: listed channel rows plus every DM row', () => {
    const m = unreadModel({ keys: { ...KEYS, 'dm:c-002@sat': 2 } })
    assert.equal(tabUnread(m.rows, LISTED), 3)
  })

  it('a muted listed channel stays out (Q2)', () => {
    assert.equal(tabUnread(rows, LISTED, ['ops']), 0)
  })

  it('app.vue reads the listed title from useUnread, not every ch: key', () => {
    const app = read('src/app.vue')
    assert.match(app, /unreadRows\.tabTitle\.value/)
    assert.doesNotMatch(app, /unreadRows\.section\('channels'\)/, 'the section sums every ch: key, listed or not')
  })

  it('useUnread lists the channels the sidebar lists (channel.ordered)', () => {
    const src = read('src/composables/useUnread.ts')
    assert.match(src, /tabUnread\(model\.value\.rows, channel\.ordered\.map/)
  })
})

describe('a card opened drops its channel row by the same number', () => {
  it('t: goes to 0 and ch: falls by what t: held', () => {
    assert.deepEqual(dropTopicKey({ 'ch:ops': 3, 't:A': 2, 't:B': 1 }, 'A', 'ops'), { 'ch:ops': 1, 't:A': 0, 't:B': 1 })
  })

  it('nothing to drop leaves the keys as they were', () => {
    const k = { 'ch:ops': 1, 't:B': 1 }
    assert.equal(dropTopicKey(k, 'A', 'ops'), k)
    assert.equal(dropTopicKey(null, 'A', 'ops'), null)
  })

  it('never below 0, and a DM card touches no ch: key', () => {
    assert.deepEqual(dropTopicKey({ 'ch:ops': 1, 't:A': 2 }, 'A', 'ops'), { 'ch:ops': 0, 't:A': 0 })
    assert.deepEqual(dropTopicKey({ 'dm:x': 1, 't:A': 1 }, 'A', ''), { 'dm:x': 1, 't:A': 0 })
  })

  it('useTopicCardNew.opened drops the card with its channel, through useUnread', () => {
    assert.match(read('src/composables/useTopicCardNew.ts'), /useUnread\(\)\.dropTopic\(String\(m\.task_id \|\| ''\), String\(m\.channel \|\| ''\)\)/)
    assert.match(read('src/composables/useUnread.ts'), /dropTopicKey\(keys\.value, taskId, channelId\)/)
  })
})
