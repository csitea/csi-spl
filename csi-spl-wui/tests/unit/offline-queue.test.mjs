// 080 T006 (FR-009, mobile §3.3): a send the network failed waits and goes
// again with the SAME msg_id on reconnect; TopBar's Retry reuses the msg_id.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSendQueue, isNetworkFailure, isOffline, offlineError, retryWith, takeMsgId } from '../../src/utils/offline-queue.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const closed = () => Object.assign(new Error('socket closed'), { token: 'closed' })
const timeout = () => Object.assign(new Error('send timed out'), { token: 'timeout' })

describe('isOffline / isNetworkFailure', () => {
  it('reads navigator.onLine, and no navigator is online', () => {
    assert.equal(isOffline({ onLine: false }), true)
    assert.equal(isOffline({ onLine: true }), false)
    assert.equal(isOffline(null), false)
  })

  it('closed or timeout while offline or with the socket down is the network', () => {
    assert.equal(isNetworkFailure(closed(), { offline: true }), true)
    assert.equal(isNetworkFailure(timeout(), { offline: true }), true)
    assert.equal(isNetworkFailure(timeout(), { socket: 'reconnecting' }), true)
    assert.equal(isNetworkFailure(offlineError(), { offline: true }), true)
  })

  it('a timeout on an open socket while online is a slow hub: reported, not held', () => {
    assert.equal(isNetworkFailure(timeout(), { offline: false, socket: 'open' }), false)
  })

  it('a hub refusal is never the network', () => {
    const refused = Object.assign(new Error('403'), { token: 'tenant_mismatch' })
    assert.equal(isNetworkFailure(refused, { offline: true, socket: 'closed' }), false)
    assert.equal(isNetworkFailure(new Error('x'), { offline: true }), false)
  })
})

describe('createSendQueue: held sends go again on drain', () => {
  it('AC8: a held send is resent once on drain and then leaves', async () => {
    const sent = []
    const q = createSendQueue({ stillOffline: () => true })
    q.hold('m1', async () => { sent.push('m1') })
    assert.equal(q.size, 1)
    await q.drain()
    assert.deepEqual(sent, ['m1'])
    assert.equal(q.has('m1'), false)
    await q.drain()
    assert.deepEqual(sent, ['m1'], 'a landed send is not sent again')
  })

  it('still offline: the send stays held, in order, for the next drain', async () => {
    let online = false
    const sent = []
    const q = createSendQueue({ stillOffline: (e) => e.token === 'closed' })
    for (const id of ['a', 'b']) {
      q.hold(id, async () => {
        if (!online) throw closed()
        sent.push(id)
      })
    }
    await q.drain()
    assert.equal(q.size, 2)
    online = true
    await q.drain()
    assert.deepEqual(sent, ['a', 'b'])
    assert.equal(q.size, 0)
  })

  it('a hub refusal on drain leaves the queue and is reported, never dropped silently', async () => {
    const failed = []
    const q = createSendQueue({ stillOffline: () => false, onFail: (id, e) => failed.push([id, e.message]) })
    q.hold('m1', async () => { throw new Error('403 refused') })
    await q.drain()
    assert.equal(q.size, 0)
    assert.deepEqual(failed, [['m1', '403 refused']])
  })

  it('two drains at once (online + reconnect) send each held frame once', async () => {
    let calls = 0
    const q = createSendQueue()
    q.hold('m1', async () => { calls++; await new Promise((r) => setTimeout(r, 5)) })
    await Promise.all([q.drain(), q.drain()])
    assert.equal(calls, 1)
  })
})

describe('retryWith / takeMsgId: Retry reuses the msg_id', () => {
  it('the retried text takes the armed msg_id, once', () => {
    retryWith('m1', 'hello')
    assert.equal(takeMsgId('hello', 'fresh'), 'm1')
    assert.equal(takeMsgId('hello', 'fresh2'), 'fresh2')
  })

  it('a different text never inherits it', () => {
    retryWith('m1', 'hello')
    assert.equal(takeMsgId('other', 'fresh'), 'fresh')
  })

  it('disarmed: a fresh id', () => {
    retryWith('m1', 'hello')
    retryWith('')
    assert.equal(takeMsgId('hello', 'fresh'), 'fresh')
  })
})

describe('wiring (source)', () => {
  const channel = src('src/stores/channel.ts')
  const topBar = src('src/components/TopBar.vue')
  const live = src('src/stores/live.ts')

  it('channel.sendLive holds a network-failed send instead of rolling it back', () => {
    assert.match(channel, /isNetworkFailure\(e, \{ offline: isOffline\(\), socket: client\.state \}\)\) return waitForNetwork\(sent, client\)/)
    assert.match(channel, /frame\.msg_id = takeMsgId\(text, newId\(\)\)/)
  })

  it('reconnect and `online` drain the queue', () => {
    assert.match(channel, /addEventListener\('online', \(\) => \{ void queue\.drain\(\) \}\)/)
    assert.match(channel, /onReconnected\(\(\) => \{ void queue\.drain\(\) \}\)/)
  })

  it('TopBar Retry arms the failed msg_id, and both stores put it on the error', () => {
    assert.match(topBar, /retryWith\(failed\.msgId \|\| '', failed\.text\)/)
    assert.match(channel, /Object\.assign\(e, \{ msgId: frame\.msg_id \}\)/)
    assert.match(live, /msgId = takeMsgId\(body, crypto\.randomUUID\(\)\)/)
    assert.match(live, /Object\.assign\(e, \{ msgId \}\)/)
  })
})
