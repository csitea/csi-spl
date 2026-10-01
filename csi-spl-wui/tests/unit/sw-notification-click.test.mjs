// CLE-77890 (owner, t1 bd6d7291): tapping an Android alert opens its message.
// Runs the real public/sw.js in a vm with a fake worker scope and drives its
// notificationclick handler: an open tab, a tab from an older bundle that
// never answers, an uncontrolled tab, and no tab at all.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SW = readFileSync(join(WUI, 'src/public/sw.js'), 'utf8')

/** Load sw.js against `tabs`; returns a click(data) that resolves what waitUntil got. */
function worker(tabs, { openWindow = true } = {}) {
  const handlers = {}
  const opened = []
  const clients = {
    matchAll: async () => tabs,
    claim: async () => {},
  }
  if (openWindow) clients.openWindow = async (url) => { opened.push(url); return { url } }
  const self = {
    addEventListener: (t, fn) => { handlers[t] = fn },
    skipWaiting: () => {},
    clients,
  }
  vm.runInNewContext(SW, { self, caches: { keys: async () => [] }, MessageChannel, setTimeout, console })
  async function click(data, tag = '') {
    let closed = false
    let job = null
    handlers.notificationclick({
      notification: { data, tag, close: () => { closed = true } },
      waitUntil: (p) => { job = p },
    })
    assert.equal(closed, true, 'the tapped alert is dismissed')
    return job
  }
  return { click, opened }
}

/** A window client. `answers`: the page bundle takes NOTIFY_OPEN and answers on the port. */
function tab({ answers = true, controlled = true, focused = false, visibilityState = 'hidden' } = {}) {
  const t = { focused, visibilityState, focusedCount: 0, posted: [], navigated: [] }
  t.focus = async () => { t.focusedCount++; return t }
  t.postMessage = (msg, ports) => {
    /* a plain copy: the vm's objects carry another realm's prototype */
    t.posted.push(JSON.parse(JSON.stringify(msg)))
    if (answers) ports[0].postMessage('ok')
  }
  t.navigate = async (url) => {
    if (!controlled) throw new TypeError('not controlled')
    t.navigated.push(url)
    return t
  }
  return t
}

const DATA = { msgId: 'ab0f3c1e-1111-4222-8333-444455556666', url: '/m/ab0f3c1e-1111-4222-8333-444455556666' }

describe('sw.js notificationclick (CLE-77890)', () => {
  it('an open tab is brought forward and handed the message - no reload, no new tab', async () => {
    const a = tab()
    const w = worker([a])
    assert.equal(await w.click(DATA), a)
    assert.equal(a.focusedCount, 1)
    assert.deepEqual(a.posted, [{ type: 'spool:notification-open', msgId: DATA.msgId, url: DATA.url }])
    assert.deepEqual(a.navigated, [])
    assert.deepEqual(w.opened, [])
  })

  it('the focused (else visible) tab wins over the first one', async () => {
    const a = tab()
    const b = tab({ visibilityState: 'visible' })
    const c = tab({ focused: true })
    const w = worker([a, b, c])
    await w.click(DATA)
    assert.equal(c.posted.length, 1)
    assert.equal(a.posted.length + b.posted.length, 0)
  })

  it('a tab that never answers (a bundle from before this change) is navigated to the deep link', async () => {
    const a = tab({ answers: false })
    const w = worker([a])
    await w.click(DATA)
    assert.equal(a.posted.length, 1)
    assert.deepEqual(a.navigated, [DATA.url])
    assert.deepEqual(w.opened, [])
  })

  it('an uncontrolled tab that never answers: a new window at the deep link', async () => {
    const a = tab({ answers: false, controlled: false })
    const w = worker([a])
    await w.click(DATA)
    assert.deepEqual(w.opened, [DATA.url])
  })

  it('no tab open: a window is opened at the deep link', async () => {
    const w = worker([])
    await w.click(DATA)
    assert.deepEqual(w.opened, [DATA.url])
  })

  it('an alert with no target (Settings test, an old alert) only focuses, as before', async () => {
    const a = tab()
    const w = worker([a])
    await w.click(undefined)
    assert.equal(a.focusedCount, 1)
    assert.deepEqual(a.posted, [])
    const none = worker([])
    await none.click(null)
    assert.deepEqual(none.opened, ['/'])
  })

  it('an alert from an older page (no data) opens the feed its tag names', async () => {
    /* owner bd6d7291 msg 5f40daa7: a phone tab still on a pre-4.9.6 bundle raises alerts without a target */
    const a = tab({ answers: false })
    const w = worker([a])
    await w.click(undefined, 'ch:alerts')
    assert.deepEqual(a.navigated, ['/channel/alerts'])
    const b = tab()
    const w2 = worker([b])
    await w2.click(null, 'dm:GRK-03@box1')
    assert.equal(b.posted[0].url, '/dm/GRK-03%40box1')
    const none = worker([])
    await none.click(undefined, 'ch:lobby')
    assert.deepEqual(none.opened, ['/channel/lobby'])
    /* the data's own link wins over the tag */
    const c = tab()
    await worker([c]).click(DATA, 'ch:lobby')
    assert.equal(c.posted[0].url, DATA.url)
  })

  it('only a same-origin path is ever opened', async () => {
    for (const url of ['https://evil.example.com/x', '//evil.example.com/x', 'javascript:alert(1)']) {
      const w = worker([])
      await w.click({ msgId: 'x', url })
      assert.deepEqual(w.opened, ['/'], url)
    }
  })

  it('old workers are replaced at once: skipWaiting + clients.claim stay', () => {
    assert.match(SW, /self\.skipWaiting\(\)/)
    assert.match(SW, /self\.clients\.claim\(\)/)
  })
})
