// spec 006 T021w — checkout + success pages against contracts/checkout-v1.md.
// Proves the security rules of the brief: the claim token lives in
// sessionStorage only and never in a URL / error; the root private key is never
// stored; POST /claim happens once even with overlapping polls or a re-mount;
// 410 claimed is a clear state.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CHECKOUT_STORE_CLAIM,
  CHECKOUT_STORE_ID,
  checkoutErrorMessage,
  checkoutMode,
  claimOnce,
  createCheckoutClient,
  dropClaimToken,
  forgetCheckout,
  formatPrice,
  keyFileName,
  loadCheckout,
  pollAndClaim,
  resetClaim,
  saveCheckout,
} from '../../src/utils/checkout-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const TOKEN = 'ct_7f3a9b2c5d8e1f4a6b9c2d5e8f1a4b7c'
const KEY = 'S2V5LW5vdC1yZWFsLWJ1dC02NC1ieXRlcy1sb25nLWZvci10aGUtdGVzdC1vbmx5IQ=='
let seq = 0
const newId = () => `co_test_${++seq}_${Date.now()}`

function memStorage() {
  const m = new Map()
  return {
    m,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)) },
    removeItem: (k) => { m.delete(k) },
  }
}

/** A fake hub implementing checkout-v1 §1.3/§1.4; routes by URL + method. */
function fakeHub({ paidAfter = 0, claimStatus = 200, claimed = false, claimDelayMs = 0 } = {}) {
  const calls = []
  let polls = 0
  const fn = async (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url, method, body: opts.body })
    const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body })
    if (method === 'POST' && url.endsWith('/claim')) {
      if (claimDelayMs) await new Promise((r) => setTimeout(r, claimDelayMs))
      if (claimStatus === 200) return reply(200, { tenant_id: 'acme', tenant_url: 'https://acme.example.com', root_private_key: KEY, emailed: true })
      return reply(claimStatus, { error: claimStatus === 410 ? 'claimed' : 'unavailable', detail: '' })
    }
    if (method === 'GET') {
      polls++
      return reply(200, { checkout_id: 'x', tenant_id: 'acme', status: polls > paidAfter ? 'paid' : 'pending', claimed })
    }
    return reply(404, { error: 'not_found' })
  }
  return { fn, calls, claims: () => calls.filter((c) => c.url.endsWith('/claim')).length }
}

const noSleep = async () => {}

describe('checkout-v1 client', () => {
  it('calls the §1 routes same-origin, JSON, with no secret in any URL', async () => {
    const seen = []
    const fetchFn = async (url, opts) => {
      seen.push({ url, opts })
      return { ok: true, status: 200, json: async () => ({}) }
    }
    const c = createCheckoutClient({ fetchFn })
    await c.plan()
    await c.start({ tenant_id: 'acme', email: 'b@example.com' })
    await c.status('co_1')
    await c.claim({ checkout_id: 'co_1', claim_token: TOKEN })
    await c.fakePay('co_1')
    assert.deepEqual(seen.map((s) => `${s.opts.method} ${s.url}`), [
      'GET /api/v1/checkout/plan',
      'POST /api/v1/checkout',
      'GET /api/v1/checkout/co_1',
      'POST /api/v1/checkout/claim',
      'POST /api/v1/checkout/fake-pay',
    ])
    for (const s of seen) {
      assert.equal(s.opts.credentials, 'same-origin')
      assert.ok(!s.url.includes(TOKEN), `token in URL ${s.url}`)
    }
    assert.deepEqual(JSON.parse(seen[3].opts.body), { checkout_id: 'co_1', claim_token: TOKEN })
  })

  it('maps error envelopes to tokens and never echoes the request', async () => {
    const c = createCheckoutClient({ fetchFn: async () => ({ ok: false, status: 409, json: async () => ({ error: 'tenant_taken', detail: 'acme' }) }) })
    const out = await c.start({ tenant_id: 'acme', email: 'b@example.com' })
    assert.deepEqual(out, { ok: false, status: 409, data: null, error: 'tenant_taken' })
    const net = await createCheckoutClient({ fetchFn: async () => { throw new Error(TOKEN) } }).claim({ checkout_id: 'x', claim_token: TOKEN })
    assert.equal(net.error, 'network')
    assert.ok(!JSON.stringify(net).includes(TOKEN))
    for (const code of ['bad_request', 'bad_tenant_id', 'tenant_taken', 'payment_unavailable', 'not_found', 'not_paid', 'claimed', 'network', TOKEN]) {
      assert.ok(!checkoutErrorMessage(code).includes(TOKEN), code)
    }
    assert.equal(checkoutErrorMessage(''), '')
  })

  it('formats price and file name', () => {
    assert.equal(formatPrice(2000, 'eur'), '20.00 EUR')
    assert.equal(formatPrice('x', 'eur'), '')
    assert.equal(keyFileName('acme'), 'acme.root.key')
    assert.equal(keyFileName('../etc'), 'tenant.root.key')
  })

  it('checkoutMode (1.1 §1.1): only the fake rail opens the form', () => {
    assert.equal(checkoutMode({ rail: 'fake', available: true, methods: ['card'] }), 'fake')
    assert.equal(checkoutMode({ rail: 'fake' }), 'fake')
    assert.equal(checkoutMode({ rail: 'none' }), 'none')
    assert.equal(checkoutMode({ rail: 'fake', available: false }), 'none')
    assert.equal(checkoutMode({ rail: 'card', available: false }), 'none')
    assert.equal(checkoutMode({ rail: 'card', available: true }), 'unsupported')
    assert.equal(checkoutMode({ rail: 'hosted' }), 'unsupported')
    assert.equal(checkoutMode(null), 'none')
  })
})

describe('claim token storage (sessionStorage only)', () => {
  it('saves id + token, drops the token, forgets both', () => {
    const s = memStorage()
    assert.equal(saveCheckout({ checkout_id: 'co_1', claim_token: TOKEN }, s), true)
    assert.deepEqual(loadCheckout(s), { id: 'co_1', token: TOKEN })
    dropClaimToken(s)
    assert.deepEqual(loadCheckout(s), { id: 'co_1', token: '' })
    forgetCheckout(s)
    assert.deepEqual([...s.m.keys()], [])
  })

  it('a storage that throws reads as empty, save reports false', () => {
    const bad = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') }, removeItem() { throw new Error('x') } }
    assert.equal(saveCheckout({ checkout_id: 'a', claim_token: 'b' }, bad), false)
    assert.deepEqual(loadCheckout(bad), { id: '', token: '' })
    dropClaimToken(bad)
  })
})

describe('claim exactly once', () => {
  it('polls until paid, claims once, drops the token, never stores the key', async () => {
    const hub = fakeHub({ paidAfter: 2 })
    const s = memStorage()
    const id = newId()
    saveCheckout({ checkout_id: id, claim_token: TOKEN }, s)
    const statuses = []
    const out = await pollAndClaim(createCheckoutClient({ fetchFn: hub.fn }), loadCheckout(s), { storage: s, sleep: noSleep, onStatus: (x) => statuses.push(x) })
    assert.equal(out.state, 'ok')
    assert.equal(out.result.root_private_key, KEY)
    assert.deepEqual(statuses, ['pending', 'pending', 'paid'])
    assert.equal(hub.claims(), 1)
    assert.equal(s.getItem(CHECKOUT_STORE_CLAIM), null, 'token dropped after the claim')
    assert.equal(s.getItem(CHECKOUT_STORE_ID), id, 'id kept so a reload can say "already claimed"')
    for (const v of s.m.values()) assert.ok(!v.includes(KEY), 'key never in storage')
  })

  it('two overlapping polls and a re-mount share ONE POST /claim', async () => {
    const hub = fakeHub({ claimDelayMs: 20 })
    const client = createCheckoutClient({ fetchFn: hub.fn })
    const id = newId()
    const c = { id, token: TOKEN }
    const [a, b] = await Promise.all([
      pollAndClaim(client, c, { sleep: noSleep, storage: memStorage() }),
      pollAndClaim(client, c, { sleep: noSleep, storage: memStorage() }),
    ])
    // the "re-rendered" page asks again after both settled
    const again = await claimOnce(createCheckoutClient({ fetchFn: hub.fn }), c, memStorage())
    assert.equal(a.state, 'ok')
    assert.equal(b.state, 'ok')
    assert.equal(again.state, 'ok')
    assert.equal(hub.claims(), 1)
  })

  it('resetClaim after a success does NOT allow a second claim', async () => {
    const hub = fakeHub()
    const client = createCheckoutClient({ fetchFn: hub.fn })
    const id = newId()
    await claimOnce(client, { id, token: TOKEN }, memStorage())
    await resetClaim(id)
    await claimOnce(client, { id, token: TOKEN }, memStorage())
    assert.equal(hub.claims(), 1)
  })

  it('a failed claim is not retried by itself; one user retry may claim again', async () => {
    const hub = fakeHub({ claimStatus: 503 })
    const client = createCheckoutClient({ fetchFn: hub.fn })
    const id = newId()
    const first = await pollAndClaim(client, { id, token: TOKEN }, { sleep: noSleep, storage: memStorage() })
    assert.deepEqual(first, { state: 'error', error: 'unavailable' })
    await pollAndClaim(client, { id, token: TOKEN }, { sleep: noSleep, storage: memStorage() })
    assert.equal(hub.claims(), 1, 'no automatic retry')
    await resetClaim(id)
    await pollAndClaim(client, { id, token: TOKEN }, { sleep: noSleep, storage: memStorage() })
    assert.equal(hub.claims(), 2, 'one user-initiated retry')
  })

  it('410 is "claimed" and drops the token', async () => {
    const hub = fakeHub({ claimStatus: 410 })
    const s = memStorage()
    const id = newId()
    saveCheckout({ checkout_id: id, claim_token: TOKEN }, s)
    const out = await pollAndClaim(createCheckoutClient({ fetchFn: hub.fn }), loadCheckout(s), { storage: s, sleep: noSleep })
    assert.deepEqual(out, { state: 'claimed' })
    assert.equal(s.getItem(CHECKOUT_STORE_CLAIM), null)
  })

  it('a status that says claimed shows "claimed" without POSTing', async () => {
    const hub = fakeHub({ claimed: true })
    const out = await pollAndClaim(createCheckoutClient({ fetchFn: hub.fn }), { id: newId(), token: '' }, { sleep: noSleep, storage: memStorage() })
    assert.deepEqual(out, { state: 'claimed' })
    assert.equal(hub.claims(), 0)
  })

  it('paid without a token in this tab does not claim; stop ends the loop', async () => {
    const hub = fakeHub()
    const out = await pollAndClaim(createCheckoutClient({ fetchFn: hub.fn }), { id: newId(), token: '' }, { sleep: noSleep, storage: memStorage() })
    assert.deepEqual(out, { state: 'error', error: 'no_token' })
    assert.equal(hub.claims(), 0)
    const pending = fakeHub({ paidAfter: 1e9 })
    let n = 0
    const stopped = await pollAndClaim(createCheckoutClient({ fetchFn: pending.fn }), { id: newId(), token: TOKEN }, {
      sleep: noSleep, storage: memStorage(), isStopped: () => ++n > 3,
    })
    assert.deepEqual(stopped, { state: 'stopped' })
    assert.equal(pending.claims(), 0)
  })
})

describe('source + build output: where secrets may never go', () => {
  const FILES = ['src/utils/checkout-client.mjs', 'src/pages/checkout/index.vue', 'src/pages/checkout/success.vue']
  const read = (p) => readFileSync(join(WUI, p), 'utf8')
  // code only: drop comments so the rules can be stated in prose
  const code = (s) => s.replace(/<!--[\s\S]*?-->/g, '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

  it('no localStorage, no console, no secret in a URL / router query', () => {
    for (const f of FILES) {
      const src = code(read(f))
      assert.ok(!/localStorage|indexedDB|document\.cookie/.test(src), `${f}: persistent storage`)
      assert.ok(!/console\./.test(src), `${f}: console`)
      assert.ok(!/claim_token\s*=|[?&]claim_token|root_private_key\s*=/.test(src), `${f}: secret in a URL`)
      assert.ok(!/query\s*:\s*\{[^}]*(claim|token|key)/i.test(src), `${f}: secret in a router query`)
    }
  })

  it('the success page keeps the key in memory and clears it on leave', () => {
    const src = code(read('src/pages/checkout/success.vue'))
    assert.ok(!/sessionStorage|setItem\(/.test(src), 'success page writes no storage')
    assert.match(src, /onBeforeUnmount\([\s\S]*keyText\.value = ''/)
    assert.match(src, /claimOnce|pollAndClaim/)
    assert.ok(!/\.claim\(/.test(src), 'the page never calls client.claim directly')
  })

  it('the built output (when present) carries no secret pattern', () => {
    const out = join(WUI, '.output/public')
    if (!existsSync(out)) return
    const walk = (d) => readdirSync(d).flatMap((n) => {
      const p = join(d, n)
      return statSync(p).isDirectory() ? walk(p) : [p]
    })
    for (const p of walk(out).filter((x) => /\.(js|html|json)$/.test(x))) {
      const s = readFileSync(p, 'utf8')
      assert.ok(!/[?&]claim_token=|claim_token=|root_private_key=/.test(s), `${p}: secret in a URL`)
      assert.ok(!/localStorage\.setItem\([^)]*spool\.checkout/.test(s), `${p}: checkout in localStorage`)
      assert.ok(!s.includes(TOKEN) && !s.includes(KEY), `${p}: fixture secret`)
    }
  })
})
