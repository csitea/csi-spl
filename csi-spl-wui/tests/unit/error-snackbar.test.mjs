// The error snackbar's queue (005 FR-WUI-ERR-SNACK, CLE-34990), executed.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  SNACKBAR_MAX,
  SNACKBAR_TTL_MS,
  bindSnackbarToJournal,
  createSnackbarQueue,
  snackbarText,
} from '../../src/utils/error-snackbar.mjs'

function clock(t0 = 1_000_000) {
  let t = t0
  return { now: () => t, add: (ms) => { t += ms } }
}

const rec = (over = {}) => ({
  seq: 1, errorId: 'ERR-CLIENT-20260925-190000-ABCD', at: new Date().toISOString(),
  source: 'api', method: 'GET', path: '/v1/view/roster', status: 502, code: '', message: 'Bad gateway', name: '',
  ...over,
})

describe('snackbarText', () => {
  it('falls back message -> code -> name -> HTTP status -> Error', () => {
    assert.equal(snackbarText(rec()), 'Bad gateway')
    assert.equal(snackbarText(rec({ message: '', code: 'error.forbidden' })), 'error.forbidden')
    assert.equal(snackbarText(rec({ message: ' ', code: '', name: 'TypeError' })), 'TypeError')
    assert.equal(snackbarText(rec({ message: '', status: 404 })), 'HTTP 404')
    assert.equal(snackbarText(rec({ message: '', status: 0 })), 'Error')
    assert.equal(snackbarText(null), '')
  })
  it('caps a long line', () => {
    assert.ok(snackbarText(rec({ message: 'x'.repeat(900) })).length <= 200)
  })
})

describe('createSnackbarQueue', () => {
  it('shows newest first and keeps at most SNACKBAR_MAX rows', () => {
    const c = clock()
    const q = createSnackbarQueue({ now: c.now })
    for (let i = 1; i <= SNACKBAR_MAX + 2; i++) q.push(rec({ seq: i, message: `m${i}` }))
    const items = q.items()
    assert.equal(items.length, SNACKBAR_MAX)
    assert.equal(items[0].text, `m${SNACKBAR_MAX + 2}`)
  })

  it('coalesces an identical error into one row with a count', () => {
    const c = clock()
    const q = createSnackbarQueue({ now: c.now })
    const a = q.push(rec({ seq: 1 }))
    c.add(1000)
    const b = q.push(rec({ seq: 2, errorId: 'ERR-CLIENT-20260925-190001-BEEF' }))
    assert.equal(a, b)
    const [row] = q.items()
    assert.equal(q.items().length, 1)
    assert.equal(row.count, 2)
    assert.equal(row.errorId, 'ERR-CLIENT-20260925-190001-BEEF')
  })

  it('does not coalesce outside the window or across different errors', () => {
    const c = clock()
    const q = createSnackbarQueue({ now: c.now, ttlMs: 60000 })
    q.push(rec())
    c.add(6000)
    q.push(rec())
    q.push(rec({ status: 503 }))
    assert.equal(q.items().length, 3)
  })

  it('expires rows after the TTL; a held row stays and restarts on release', () => {
    const c = clock()
    const q = createSnackbarQueue({ now: c.now })
    const a = q.push(rec({ message: 'a' }))
    q.push(rec({ message: 'b' }))
    q.hold(a, true)
    c.add(SNACKBAR_TTL_MS + 1)
    assert.equal(q.tick(), true)
    assert.deepEqual(q.items().map((r) => r.text), ['a'])
    q.hold(a, false)
    c.add(SNACKBAR_TTL_MS - 1)
    assert.equal(q.tick(), false)
    c.add(2)
    q.tick()
    assert.equal(q.items().length, 0)
  })

  it('dismiss removes a row and notifies subscribers', () => {
    const q = createSnackbarQueue()
    let seen = null
    q.subscribe((items) => { seen = items })
    const id = q.push(rec())
    assert.equal(seen.length, 1)
    q.dismiss(id)
    assert.equal(seen.length, 0)
  })

  it('never throws on junk and a bad subscriber does not break it', () => {
    const q = createSnackbarQueue()
    q.subscribe(() => { throw new Error('boom') })
    assert.equal(q.push(null), '')
    assert.equal(q.push('x'), '')
    assert.ok(q.push(rec()))
  })
})

describe('bindSnackbarToJournal', () => {
  it('shows only records newer than the last seen seq, and replays recent boot errors', () => {
    const c = clock(Date.parse('2026-09-25T19:00:20Z'))
    const q = createSnackbarQueue({ now: c.now, coalesceMs: 0 })
    let fire = null
    const boot = [
      rec({ seq: 1, at: '2026-09-25T18:00:00Z', message: 'old' }),
      rec({ seq: 2, at: '2026-09-25T19:00:15Z', message: 'fresh' }),
    ]
    const unbind = bindSnackbarToJournal(q, {
      now: c.now,
      getErrors: () => boot,
      subscribeErrors: (fn) => { fire = fn; return () => { fire = null } },
    })
    assert.deepEqual(q.items().map((r) => r.text), ['fresh'])
    fire([...boot, rec({ seq: 3, message: 'new' })])
    fire([...boot, rec({ seq: 3, message: 'new' })])
    assert.deepEqual(q.items().map((r) => r.text), ['new', 'fresh'])
    unbind()
    assert.equal(fire, null)
  })
})
