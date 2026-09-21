// spec 006 T021w — checkout, success + claim pages against contracts/checkout-v1.md 1.2.
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
  checkoutErrorCopy,
  checkoutErrorKey,
  checkoutErrorMessage,
  checkoutMode,
  claimOnce,
  createCheckoutClient,
  dropClaimToken,
  forgetCheckout,
  formatPrice,
  keyFileName,
  loadCheckout,
  readClaimFragment,
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
function fakeHub({ paidAfter = 0, claimStatus = 200, claimError = '', claimed = false, claimDelayMs = 0 } = {}) {
  const calls = []
  let polls = 0
  const fn = async (url, opts = {}) => {
    const method = opts.method || 'GET'
    calls.push({ url, method, body: opts.body })
    const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body })
    if (method === 'POST' && url.endsWith('/claim')) {
      if (claimDelayMs) await new Promise((r) => setTimeout(r, claimDelayMs))
      if (claimStatus === 200) return reply(200, { tenant_id: 'acme', tenant_url: 'https://acme.example.com', root_private_key: KEY })
      return reply(claimStatus, { error: claimError || (claimStatus === 410 ? 'claimed' : 'unavailable'), detail: '' })
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
    // no locale asked for, none sent: the hub keeps its default (§1.2, rdb 0025)
    assert.deepEqual(JSON.parse(seen[1].opts.body), { tenant_id: 'acme', email: 'b@example.com' })
  })

  it('spec 021 T022: the active locale rides the checkout BODY, so the claim mail speaks it', async () => {
    const seen = []
    const c = createCheckoutClient({
      fetchFn: async (url, opts) => {
        seen.push({ url, opts })
        return { ok: true, status: 201, json: async () => ({ checkout_id: 'co_1' }) }
      },
    })
    await c.start({ tenant_id: 'acme', email: 'b@example.com', locale: 'fi' })
    assert.deepEqual(JSON.parse(seen[0].opts.body), { tenant_id: 'acme', email: 'b@example.com', locale: 'fi' })
    // The body, never a header: X-Locale is non-simple, so it preflights, and a
    // hub whose CORS allow-list lacks it refuses the whole checkout (2e2c601).
    for (const k of Object.keys(seen[0].opts.headers)) assert.notEqual(k.toLowerCase(), 'x-locale')
    // nothing to say -> the key is absent, not an empty string the hub must strip
    for (const loc of ['', null, undefined, '   ']) {
      seen.length = 0
      await c.start({ tenant_id: 'acme', email: 'b@example.com', locale: loc })
      assert.deepEqual(JSON.parse(seen[0].opts.body), { tenant_id: 'acme', email: 'b@example.com' }, `locale ${JSON.stringify(loc)}`)
    }
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

  it('spec 021: every error code has a catalogue key whose English is the copy', () => {
    const copy = checkoutErrorCopy()
    for (const code of [...Object.keys(copy).filter((c) => c !== 'generic'), 'weird', TOKEN]) {
      const k = checkoutErrorKey(code)
      const leaf = k.key.replace(/^checkout\.error\./, '')
      assert.equal(copy[leaf], checkoutErrorMessage(code), code)
      assert.ok(!k.key.includes(TOKEN), 'a code never becomes a key')
    }
    assert.equal(checkoutErrorKey(''), null)
    assert.equal(checkoutErrorKey('toString').key, 'checkout.error.generic')
  })

  it('formats price and file name', () => {
    assert.equal(formatPrice(2000, 'eur'), '20.00 EUR')
    assert.equal(formatPrice('x', 'eur'), '')
    // spec 021: the active locale's separators; no locale = unchanged
    assert.equal(formatPrice(2000, 'eur', 'en'), '20.00 EUR')
    assert.equal(formatPrice(2000, 'eur', 'fi'), '20,00 EUR')
    assert.equal(formatPrice(2000, 'eur', 'not a locale!'), '20.00 EUR')
    assert.equal(keyFileName('acme'), 'acme.root.key')
    assert.equal(keyFileName('../etc'), 'tenant.root.key')
  })

  it('checkoutMode (1.1 §1.1): the fake rail, and the card rail with a usable publishable key, open the form', () => {
    assert.equal(checkoutMode({ rail: 'fake', available: true, methods: ['card'] }), 'fake')
    assert.equal(checkoutMode({ rail: 'fake' }), 'fake')
    assert.equal(checkoutMode({ rail: 'none' }), 'none')
    assert.equal(checkoutMode({ rail: 'fake', available: false }), 'none')
    assert.equal(checkoutMode({ rail: 'card', available: false }), 'none')
    assert.equal(checkoutMode({ rail: 'card', available: true }), 'unsupported')
    assert.equal(checkoutMode({ rail: 'card', available: true, publishable_key: '' }), 'unsupported')
    assert.equal(checkoutMode({ rail: 'card', available: true, publishable_key: 'sk_test_abc' }), 'unsupported')
    assert.equal(checkoutMode({ rail: 'card', available: true, publishable_key: 'pk_test_abc123' }), 'card')
    assert.equal(checkoutMode({ rail: 'card', available: false, publishable_key: 'pk_test_abc123' }), 'none')
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

  it('1.2: 410 claim_expired is "expired", 409 conflict is a non-retry error', async () => {
    const exp = fakeHub({ claimStatus: 410, claimError: 'claim_expired' })
    assert.deepEqual(await claimOnce(createCheckoutClient({ fetchFn: exp.fn }), { id: newId(), token: TOKEN }, memStorage()), { state: 'expired' })
    const con = fakeHub({ claimStatus: 409, claimError: 'conflict' })
    assert.deepEqual(await claimOnce(createCheckoutClient({ fetchFn: con.fn }), { id: newId(), token: TOKEN }, memStorage()), { state: 'error', error: 'conflict' })
    for (const c of ['claim_expired', 'conflict', 'bad_link']) assert.notEqual(checkoutErrorMessage(c), 'Something went wrong — try again.', c)
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

describe('claim link (1.2 §1.8)', () => {
  it('reads #checkout=&token= and refuses anything malformed', () => {
    assert.deepEqual(readClaimFragment(`#checkout=co_abc123&token=${TOKEN}`), { id: 'co_abc123', token: TOKEN })
    assert.deepEqual(readClaimFragment(`checkout=co_abc123&token=${TOKEN}`), { id: 'co_abc123', token: TOKEN })
    for (const bad of ['', '#', '#checkout=co_abc123', `#token=${TOKEN}`, `#checkout=x&token=${TOKEN}`, '#checkout=co_abc&token=short', `#checkout=co_a/b&token=${TOKEN}`, `#checkout=co_a&token=${TOKEN}<script>`]) {
      assert.deepEqual(readClaimFragment(bad), { id: '', token: '' }, bad)
    }
  })

  it('the link claim is single-flight too and 410 claimed after the success page', async () => {
    const hub = fakeHub({ claimStatus: 410 })
    const c = createCheckoutClient({ fetchFn: hub.fn })
    const link = { id: newId(), token: TOKEN }
    const [a, b] = await Promise.all([claimOnce(c, link, memStorage()), claimOnce(c, link, memStorage())])
    assert.deepEqual(a, { state: 'claimed' })
    assert.deepEqual(b, { state: 'claimed' })
    assert.equal(hub.claims(), 1)
  })
})

describe('source + build output: where secrets may never go', () => {
  const FILES = ['src/utils/checkout-client.mjs', 'src/pages/checkout/index.vue', 'src/pages/checkout/success.vue', 'src/pages/checkout/claim.vue', 'src/components/CheckoutKeyReveal.vue']
  const read = (p) => readFileSync(join(WUI, p), 'utf8')
  // code only: drop comments so the rules can be stated in prose
  const code = (s) => s.replace(/<!--[\s\S]*?-->/g, '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

  it('spec 021 T022: the checkout page hands its active locale to start()', () => {
    const src = code(read('src/pages/checkout/index.vue'))
    assert.match(src, /client\.start\(\{[^}]*locale:\s*locale\.value/, 'index.vue does not send the active locale')
  })

  it('no localStorage, no console, no secret in a URL / router query', () => {
    for (const f of FILES) {
      const src = code(read(f))
      assert.ok(!/localStorage|indexedDB|document\.cookie/.test(src), `${f}: persistent storage`)
      assert.ok(!/console\./.test(src), `${f}: console`)
      assert.ok(!/claim_token\s*=|[?&]claim_token|root_private_key\s*=/.test(src), `${f}: secret in a URL`)
      assert.ok(!/query\s*:\s*\{[^}]*(claim|token|key)/i.test(src), `${f}: secret in a router query`)
    }
  })

  it('the claim page clears the fragment before claiming and never makes the token reactive', () => {
    const src = code(read('src/pages/checkout/claim.vue'))
    assert.ok(!/sessionStorage|setItem\(/.test(src), 'claim page writes no storage')
    const take = src.indexOf('takeFragment()', src.indexOf('onMounted'))
    const call = src.indexOf('claim()', take + 1)
    assert.ok(take > 0 && call > take, 'fragment taken before the claim')
    assert.match(src, /history\.replaceState\([^)]*location\.pathname \+ window\.location\.search\)/)
    assert.match(src, /let link = \{ id: '', token: '' \}/, 'link token is a plain variable, not a ref')
    assert.ok(!/ref\([^)]*token/.test(src), 'no reactive token')
    assert.match(src, /onBeforeUnmount\([\s\S]*keyText\.value = ''/)
    assert.match(src, /claimOnce\(/)
    assert.ok(!/\.claim\(/.test(src), 'the page never calls client.claim directly')
    // the router must not scroll to "#checkout=…&token=…" (it logs the selector)
    assert.match(src, /definePageMeta\(\{[^}]*scrollToTop: false/)
  })

  it('1.2 copy: nothing says the key was emailed', () => {
    for (const f of ['src/pages/checkout/success.vue', 'src/pages/checkout/claim.vue', 'src/components/CheckoutKeyReveal.vue']) {
      const src = code(read(f))
      assert.ok(!/emailed to you|was also emailed|\bemailed\b\s*\?/i.test(src), `${f}: says the key was emailed`)
    }
    // spec 021: the warning lives in the catalogue; the component must render
    // that key, and the English copy must say it
    assert.match(read('src/components/CheckoutKeyReveal.vue'), /t\('checkout\.key\.warning_once'\)/)
    const en = JSON.parse(read('i18n/locales/en.json'))
    const once = en.checkout && en.checkout.key && en.checkout.key.warning_once
    assert.match(String(once), /It is not emailed and the hub does not keep it/)
    for (const v of Object.values((en.checkout && en.checkout.key) || {})) {
      assert.ok(!/emailed to you|was also emailed/i.test(String(v)), 'en copy says the key was emailed')
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

// specs/024: the tenant host is provisioned after the payment; the page says
// so until §1.3 reports it ready.
describe('pollHostReady (specs/024)', async () => {
  const { pollHostReady } = await import('../../src/utils/checkout-client.mjs')
  const noSleep = async () => {}
  const seqClient = (answers) => {
    let i = 0
    const calls = []
    return {
      calls,
      status: async (id) => { calls.push(id); return answers[Math.min(i++, answers.length - 1)] },
    }
  }
  it('polls through pending and a failed request, resolves ready', async () => {
    const c = seqClient([
      { ok: true, data: { status: 'paid', host_status: 'pending' } },
      { ok: false, status: 0, error: 'network' },
      { ok: true, data: { status: 'paid', host_status: 'ready' } },
    ])
    assert.equal(await pollHostReady(c, 'co_1', { sleep: noSleep }), 'ready')
    assert.deepEqual(c.calls, ['co_1', 'co_1', 'co_1'])
  })
  it('an unknown status ends the poll (no notice for a host the hub cannot see)', async () => {
    const c = seqClient([{ ok: true, data: { status: 'paid', host_status: 'unknown' } }])
    assert.equal(await pollHostReady(c, 'co_2', { sleep: noSleep }), 'unknown')
  })
  it('CONTROL: a host that stays pending keeps polling until maxPolls, then reads pending', async () => {
    const c = seqClient([{ ok: true, data: { status: 'paid', host_status: 'pending' } }])
    assert.equal(await pollHostReady(c, 'co_3', { sleep: noSleep, maxPolls: 5 }), 'pending')
    assert.equal(c.calls.length, 5)
  })
  it('stops when the page is left', async () => {
    const c = seqClient([{ ok: true, data: { host_status: 'pending' } }])
    assert.equal(await pollHostReady(c, 'co_4', { sleep: noSleep, isStopped: () => true }), 'stopped')
    assert.equal(c.calls.length, 0)
  })
})
