// SPL-1839 (owner HUM-10, t1 659e3927, msg 4de3b04e): which plain sentence a
// failure gets (utils/plain-error.mjs), and that every screen and the
// snackbar keep the technical part behind the Debug pane.
//
// Run: node tests/unit/plain-error.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { mockReadFault, plainErrorKind, plainErrorStatus } from '../../src/utils/plain-error.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('plainErrorStatus', () => {
  it('reads the rejection, else the spool client message', () => {
    assert.equal(plainErrorStatus('x', { status: 502 }), 502)
    assert.equal(plainErrorStatus('spool 500 internal'), 500)
    assert.equal(plainErrorStatus('Failed to fetch'), 0)
    assert.equal(plainErrorStatus(''), 0)
  })
})

describe('plainErrorKind', () => {
  it('no HTTP answer is offline', () => {
    assert.equal(plainErrorKind(0, 'Failed to fetch'), 'offline')
    assert.equal(plainErrorKind(0, '', new TypeError('NetworkError when attempting to fetch resource.')), 'offline')
    assert.equal(plainErrorKind(0, 'Load failed'), 'offline')
    /* a sentence that merely contains the words is not the browser's */
    assert.equal(plainErrorKind(0, 'e2e: upload failed'), 'other')
  })
  it('a gateway or budget timeout is slow, 401/403 denied', () => {
    for (const s of [408, 503, 504]) assert.equal(plainErrorKind(s, ''), 'slow')
    for (const s of [401, 403]) assert.equal(plainErrorKind(s, ''), 'denied')
  })
  it('anything else is load on a screen, other in the snackbar', () => {
    assert.equal(plainErrorKind(500, 'spool 500 internal', null, 'load'), 'load')
    assert.equal(plainErrorKind(500, 'spool 500 internal'), 'other')
    assert.equal(plainErrorKind(0, 'spool config missing', null, 'load'), 'load')
  })
})

describe('mockReadFault', () => {
  it('is a no-op without the localStorage hook', () => {
    assert.doesNotThrow(() => mockReadFault('topic'))
  })
})

describe('screens', () => {
  it('lobby, channel, topic and live pane say a plain sentence with Try again', () => {
    for (const rel of ['src/pages/lobby.vue', 'src/components/MessageFeed.vue', 'src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      const src = read(rel)
      assert.match(src, /<LazyPlainErrorNotice [^>]*\bretry\b[^>]*@retry=/, rel)
      assert.equal(src.includes('<ErrorNotice'), false, rel)
    }
  })
  it('the snackbar row is the compact plain notice; no raw text or id of its own', () => {
    const src = read('src/components/common/ErrorSnackbar.vue')
    assert.match(src, /<LazyPlainErrorNotice\s+compact/)
    assert.equal(/\{\{\s*item\.(text|errorId)\s*\}\}/.test(src), false)
  })
  it('ErrorNotice shows its reference only with the Debug pane', () => {
    const src = read('src/components/common/ErrorNotice.vue')
    assert.match(src, /v-if="errorId && debug"/)
    /* a prop, not the session store: that import costs initial JS */
    assert.equal(/useSessionStore/.test(src), false)
    const bar = read('src/components/TopBar.vue')
    assert.match(bar, /:debug="debugOn"/)
    assert.match(bar, /debugPanelVisibleFor\(session\.claims/)
  })
  it('the technical line renders only with the Debug pane', () => {
    const src = read('src/components/PlainErrorNotice.vue')
    assert.match(src, /v-if="debug && techLine"/)
    assert.match(src, /debugPanelVisibleFor\(/)
  })
})
