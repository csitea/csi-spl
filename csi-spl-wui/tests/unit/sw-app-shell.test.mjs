// Perf round 4 W9: public/sw.js keeps an app shell for warm loads.
// Runs the real sw.js in a vm with a fake worker scope, Cache Storage and
// clock, and drives its fetch and activate handlers: a navigation goes to
// the network (navigation preload) unless the same build was confirmed by
// the network within FRESH_MS; a reload always goes to the network; a cached
// answer whose background revalidation names another build tells the tab;
// the API is never cached; offline falls back to the cached shell.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SW = readFileSync(join(WUI, 'src/public/sw.js'), 'utf8')
const ORIGIN = 'https://wui.example.net'
const FRESH_MS = 30000

const doc = (build, commit = 'a1b2c3d4e5f6') =>
  `<!DOCTYPE html><html><head><script>window.__NUXT__={};window.__NUXT__.config={public:{buildCommit:"${commit}"},app:{baseURL:"/",buildId:"${build}"}}</script></head></html>`

/** A network response as a browser hands it to the worker (type basic). */
function net(body, { status = 200, type = 'basic', redirected = false, ctype = 'text/html; charset=utf-8' } = {}) {
  const r = new Response(body, { status, headers: { 'content-type': ctype, 'content-security-policy': "default-src 'self'", 'content-encoding': 'br' } })
  Object.defineProperty(r, 'type', { value: type })
  Object.defineProperty(r, 'redirected', { value: redirected })
  const clone = r.clone.bind(r)
  r.clone = () => net.wrap(clone(), type, redirected)
  return r
}
net.wrap = (r, type, redirected) => {
  Object.defineProperty(r, 'type', { value: type })
  Object.defineProperty(r, 'redirected', { value: redirected })
  return r
}

function fakeCaches() {
  const stores = new Map()
  const open = async (name) => {
    if (!stores.has(name)) stores.set(name, new Map())
    const m = stores.get(name)
    const key = (r) => (typeof r === 'string' ? r : r.url)
    return {
      match: async (r) => { const v = m.get(key(r)); return v ? v.clone() : undefined },
      put: async (r, res) => { m.set(key(r), res) },
      keys: async () => [...m.keys()].map((url) => ({ url })),
      delete: async (r) => m.delete(key(r)),
    }
  }
  return {
    stores,
    api: {
      open,
      keys: async () => [...stores.keys()],
      delete: async (name) => stores.delete(name),
    },
  }
}

function worker() {
  const handlers = {}
  const clock = { now: 1_000_000 }
  const store = fakeCaches()
  const tabs = new Map()
  const fetched = []
  let preloadOn = false
  const self = {
    addEventListener: (t, fn) => { handlers[t] = fn },
    skipWaiting: () => {},
    location: { origin: ORIGIN },
    registration: { navigationPreload: { enable: async () => { preloadOn = true } } },
    clients: {
      claim: async () => {},
      get: async (id) => tabs.get(id),
      matchAll: async () => [...tabs.values()],
    },
  }
  const fetchImpl = async (req) => { fetched.push(req.url); throw new TypeError('no fetch expected in this test') }
  vm.runInNewContext(SW, {
    self, caches: store.api, fetch: (r) => fetchImpl(r), Headers, Response, URL, MessageChannel, console,
    setTimeout: (fn) => setTimeout(fn, 0),
    Date: { now: () => clock.now },
  })

  /**
   * Navigate. `network` is what the preload resolves to (a Response, or an
   * Error for offline); returns { res, background, tab }.
   */
  async function go(path, network, { cache = 'default', method = 'GET', mode = 'navigate' } = {}) {
    const id = 'c' + Math.random().toString(36).slice(2)
    const tab = { id, posted: [], postMessage: (m) => tab.posted.push(JSON.parse(JSON.stringify(m))) }
    tabs.set(id, tab)
    let answer = null
    const pending = []
    let release
    const gate = new Promise((r) => { release = r })
    const preloadResponse = gate.then(() => (network instanceof Error ? Promise.reject(network) : network))
    handlers.fetch({
      request: { url: ORIGIN + path, mode, method, cache },
      preloadResponse,
      resultingClientId: id,
      respondWith: (p) => { answer = p },
      waitUntil: (p) => { pending.push(p) },
    })
    if (!answer) { release(); return { res: null, tab, background: Promise.resolve() } }
    /* a cached answer must not wait for the network: race it unreleased */
    const early = await Promise.race([answer.then((r) => ({ r })), new Promise((r) => setTimeout(() => r(null), 20))])
    release()
    const res = early ? early.r : await answer
    const background = (async () => { while (pending.length) await pending.shift() })()
    await background
    return { res, tab, early: Boolean(early), background }
  }

  /** The tab asks which build the network last served (SHELL_ASK). */
  async function ask() {
    let job = null
    let answer
    const port = { postMessage: (m) => { answer = m === null ? null : JSON.parse(JSON.stringify(m)) } }
    handlers.message({ data: { type: 'spool:shell-ask' }, ports: [port], waitUntil: (p) => { job = p } })
    await job
    return answer
  }

  async function activate() {
    let job = null
    handlers.activate({ waitUntil: (p) => { job = p } })
    await job
  }

  return { go, ask, activate, clock, store, fetched, preload: () => preloadOn }
}

const shellOf = (w) => w.store.stores.get('spool-shell-v1') || new Map()

describe('sw.js app shell (perf round 4 W9)', () => {
  it('activate enables navigation preload and keeps only the shell cache', async () => {
    const w = worker()
    await w.store.api.open('spool-shell-v1')
    await w.store.api.open('some-old-cache')
    await w.activate()
    assert.equal(w.preload(), true)
    assert.deepEqual([...w.store.stores.keys()], ['spool-shell-v1'])
  })

  it('a navigation with no confirmed build goes to the network (the preload) and keeps the document', async () => {
    const w = worker()
    const { res, early } = await w.go('/', net(doc('build-0001')))
    assert.equal(early, false, 'nothing cached: it waited for the network')
    assert.match(await res.text(), /build-0001/)
    assert.deepEqual(w.fetched, [], 'the preload was used, no second request')
    const kept = shellOf(w).get(ORIGIN + '/')
    assert.equal(kept.headers.get('x-spool-shell-build'), 'build-0001')
    assert.equal(kept.headers.get('content-security-policy'), "default-src 'self'", 'security headers stay')
    assert.equal(kept.headers.get('content-encoding'), null, 'the body is stored decoded')
  })

  it('within FRESH_MS of the network serving the same build, the hop is answered from the shell, no round trip', async () => {
    const w = worker()
    await w.go('/login', net(doc('build-0001')))          // an earlier visit kept /login
    w.clock.now += 10 * 60_000
    await w.go('/', net(doc('build-0001')))               // this visit: / from the network
    w.clock.now += 400
    const { res, early, tab } = await w.go('/login?redirect=/', net(doc('build-0001')))
    assert.equal(early, true, 'answered before the network')
    assert.match(await res.text(), /build-0001/)
    assert.deepEqual(tab.posted, [], 'same build: nothing to tell the tab')
  })

  it('a cached answer whose revalidation names another build tells the tab, and the next navigation goes to the network', async () => {
    const w = worker()
    await w.go('/login', net(doc('build-0001', 'aaaaaaaa1111')))
    await w.go('/', net(doc('build-0001', 'aaaaaaaa1111')))
    const { early, tab } = await w.go('/login', net(doc('build-0002', 'bbbbbbbb2222')))
    assert.equal(early, true)
    assert.deepEqual(tab.posted, [{ type: 'spool:shell-stale', build: 'build-0002', commit: 'bbbbbbbb2222' }])
    assert.equal(shellOf(w).has(ORIGIN + '/'), false, 'the old build is pruned')
    const again = await w.go('/', net(doc('build-0002', 'bbbbbbbb2222')))
    assert.equal(again.early, false, '/ is cached only for the old build: network')
  })

  it('SHELL_ASK: a tab that missed the push learns the build the network last served', async () => {
    const w = worker()
    assert.equal(await w.ask(), null, 'a worker that saw no document knows nothing')
    await w.go('/login', net(doc('build-0001', 'aaaaaaaa1111')))
    await w.go('/', net(doc('build-0001', 'aaaaaaaa1111')))
    await w.go('/login', net(doc('build-0002', 'bbbbbbbb2222')))
    assert.deepEqual(await w.ask(), { type: 'spool:shell-stale', build: 'build-0002', commit: 'bbbbbbbb2222' })
  })

  it('a reload always goes to the network, even inside FRESH_MS (build-watch and chunk-reload swap builds by reloading)', async () => {
    const w = worker()
    await w.go('/', net(doc('build-0001')))
    for (const cache of ['no-cache', 'reload', 'no-store']) {
      const { early } = await w.go('/', net(doc('build-0001')), { cache })
      assert.equal(early, false, cache)
    }
  })

  it('after FRESH_MS the shell is not trusted: the network answers', async () => {
    const w = worker()
    await w.go('/', net(doc('build-0001')))
    w.clock.now += FRESH_MS + 1
    const { early } = await w.go('/', net(doc('build-0001')))
    assert.equal(early, false)
  })

  it('a document of another build than the one just confirmed is never served', async () => {
    const w = worker()
    await w.go('/login', net(doc('build-0001')))
    await w.go('/', net(doc('build-0002')))               // a deploy between the two
    const { early, res } = await w.go('/login', net(doc('build-0002')))
    assert.equal(early, false)
    assert.match(await res.text(), /build-0002/)
  })

  it('the API, non-GET and non-navigation requests are never cached or answered from cache', async () => {
    const w = worker()
    const cb = await w.go('/api/v1/auth/callback?code=x', net('', { status: 200 }))
    assert.ok(cb.res, 'an API navigation still uses the preload (one request, not two)')
    assert.deepEqual(w.fetched, [])
    assert.equal(shellOf(w).size, 0)
    const post = await w.go('/login', net(doc('build-0001')), { method: 'POST' })
    assert.equal(post.res, null, 'not intercepted')
    const sub = await w.go('/_nuxt/entry.js', net('x', { ctype: 'text/javascript' }), { mode: 'no-cors' })
    assert.equal(sub.res, null, 'not intercepted')
    await w.go('/build.json', net('{}', { ctype: 'application/json' }))
    assert.equal(shellOf(w).size, 0)
  })

  it('redirected, non-200 and build-less documents are not kept', async () => {
    const w = worker()
    await w.go('/a', net(doc('build-0001'), { redirected: true }))
    await w.go('/b', net(doc('build-0001'), { status: 404 }))
    await w.go('/c', net('<html>no build here</html>'))
    await w.go('/d', net(doc('build-0001'), { type: 'opaqueredirect' }))
    assert.equal(shellOf(w).size, 0)
  })

  it('offline: a navigation falls back to the shell of that path', async () => {
    const w = worker()
    await w.go('/lobby', net(doc('build-0001')))
    w.clock.now += 3_600_000
    const { res } = await w.go('/lobby', new TypeError('Failed to fetch'))
    assert.match(await res.text(), /build-0001/)
  })
})
