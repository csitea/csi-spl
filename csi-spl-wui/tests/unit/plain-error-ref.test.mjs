// Spec 162 (owner HUM-10, t1 955ab0bd): the event log, fixes F4 and F6.
// F4 (SPL-5750 channel, SPL-5760 topic): one failure, one journal row - the
// api layer journals a "Failed to fetch" and the lobby / channel notice used
// to mint a second row for it, as it got only the message.
// F6 (SPL-5744 lobby, SPL-5753 channel): a 403 not_member while the
// not-member card is up is a state, not an error: the notice journals none.
// The journal, the feed read and noticeRef are EXECUTED; the rows are counted.
//
// Run: node tests/unit/plain-error-ref.test.mjs
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { getErrors, noteError, resetErrorJournal } from '../../src/composables/errorJournal.mjs'
import { readFirstPage } from '../../src/utils/feed-read.mjs'
import { isNotMember, noticeRef } from '../../src/utils/plain-error-ref.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const journal = { isClient: true }
const ref = (value) => ({ value })

/** What spool-client's fetchOnce does with a dropped GET: journal it, then throw it. */
function apiDrop() {
  const e = new TypeError('Failed to fetch')
  noteError({ source: 'api', method: 'GET', url: 'https://t1.example.test/v1/view/messages', error: e }, journal)
  return e
}

function notMember403() {
  return Object.assign(new Error('spool 403 not_member'), { status: 403, token: 'not_member' })
}

describe('F4: the notice quotes the api record, one failure = one row', () => {
  beforeEach(() => resetErrorJournal())

  it('the message alone mints a second row (the old notice)', () => {
    const e = apiDrop()
    noticeRef({ message: e.message, source: 'channel' }, { journal })
    assert.equal(getErrors().length, 2)
  })

  it('the rejection too: no second row, and the api record id is quoted', () => {
    const e = apiDrop()
    const id = noticeRef({ message: e.message, error: e, source: 'channel' }, { journal })
    assert.equal(getErrors().length, 1)
    assert.equal(id, getErrors()[0].errorId)
  })

  it('the channel feed read keeps the rejection for the notice', async () => {
    const s = {
      active: ref('c'), peer: ref(null), messages: ref([]), loading: ref(false), error: ref(null), errorCause: ref(null),
      totals: ref({}), olderCursor: ref(null), offlineAt: ref(null),
    }
    await readFirstPage(s, {
      read: async () => { throw apiDrop() },
      withHeld: (rows) => rows,
      keep: () => {},
      showKept: async () => false,
      follow: () => {},
      failed: (e) => e.message,
    })
    assert.equal(s.error.value, 'Failed to fetch')
    assert.ok(s.errorCause.value instanceof TypeError)
    noticeRef({ message: s.error.value, error: s.errorCause.value, source: 'channel' }, { journal })
    assert.equal(getErrors().length, 1)
  })

  it('a failure nobody journaled still gets its one row', () => {
    const id = noticeRef({ message: 'spool 500 internal', error: { status: 500 }, source: 'lobby' }, { journal })
    assert.equal(getErrors().length, 1)
    assert.equal(getErrors()[0].errorId, id)
  })

  it('lobby and channel pass the rejection; the notice uses noticeRef', () => {
    assert.match(read('src/components/MessageFeed.vue'), /<LazyPlainErrorNotice :message="channel\.error" :error="channel\.errorCause"/)
    assert.match(read('src/pages/lobby.vue'), /<LazyPlainErrorNotice :message="store\.error" :error="store\.errorCause"/)
    const live = read('src/stores/live.ts')
    assert.match(live, /s\.errorCause\.value = e/)
    const channel = read('src/stores/channel.ts')
    assert.equal((channel.match(/errorCause\.value = e/g) || []).length, 2, 'load older + catch-up')
  })
})

describe('F6: not a member is a state, not an error', () => {
  beforeEach(() => resetErrorJournal())

  it('reads the 403 not_member from the token or the message', () => {
    assert.equal(isNotMember('spool 403 not_member', notMember403()), true)
    assert.equal(isNotMember('spool 403 not_member'), true)
    assert.equal(isNotMember('spool 403 forbidden', { status: 403, token: 'forbidden' }), false)
    assert.equal(isNotMember('spool 401 not_member'), false)
  })

  it('the not-member card is up: the notice journals no 403 not_member', () => {
    const e = notMember403()
    assert.equal(noticeRef({ message: e.message, error: e, source: 'lobby' }, { notMember: true, journal }), '')
    assert.equal(getErrors().length, 0)
  })

  it('without the card, or another failure, it is journaled', () => {
    const e = notMember403()
    noticeRef({ message: e.message, error: e, source: 'channel' }, { journal })
    assert.equal(getErrors().length, 1)
    noticeRef({ message: 'spool 500 internal', error: { status: 500 }, source: 'channel' }, { notMember: true, journal })
    assert.equal(getErrors().length, 2)
  })

  it('the notice reads the state tenant-host-boot.mjs step 3 sets', () => {
    const src = read('src/components/PlainErrorNotice.vue')
    assert.match(src, /useState<[^>]*>\('tenant-host-not-member'/)
    assert.match(src, /noticeRef\(props, \{ notMember: !!notMember\.value\.tenant \}\)/)
    assert.match(read('src/plugins/tenant-host.client.ts'), /useState<[^>]*>\('tenant-host-not-member'/)
  })
})
