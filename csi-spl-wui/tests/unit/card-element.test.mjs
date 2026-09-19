// spec 006 T021w — the card step (src/utils/card-element.mjs) against a fake
// vendor SDK: the Payment Element is mounted with the checkout's client secret
// and confirmed with return_url = the success page and redirect only when
// needed; declines and failures map to catalogue codes; a bad config never
// loads anything; the redirect-return parameters (one is a client secret) are
// stripped from the success page URL; the SDK script is injected once.
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import {
  CARD_RETURN_PARAMS,
  cardKeyUsable,
  cardReturnCleanUrl,
  loadCardSdk,
  mountCardPayment,
  resetCardSdk,
} from '../../src/utils/card-element.mjs'

const PK = 'pk_test_abc123'
const CS = 'pi_123_secret_456'

function fakeSdk({ confirmResult = { paymentIntent: { status: 'succeeded' } }, throws = false } = {}) {
  const calls = { init: [], elements: [], mount: [], confirm: [], destroyed: 0 }
  const factory = (key, opts) => {
    calls.init.push({ key, opts })
    return {
      elements(o) {
        calls.elements.push(o)
        return { create: (kind) => ({ kind, mount: (el) => calls.mount.push({ kind, el }), destroy: () => { calls.destroyed++ } }) }
      },
      async confirmPayment(o) {
        calls.confirm.push(o)
        if (throws) throw new Error('boom')
        return confirmResult
      },
    }
  }
  return { factory, calls }
}

describe('card-element', () => {
  beforeEach(() => resetCardSdk())

  it('cardKeyUsable: only a publishable key shape', () => {
    assert.equal(cardKeyUsable(PK), true)
    assert.equal(cardKeyUsable('pk_live_Xy9'), true)
    for (const bad of ['', null, 'sk_test_abc', 'rk_live_abc', 'pk_test_', 'pk_test_a b', 'PLACEHOLDER']) assert.equal(cardKeyUsable(bad), false, String(bad))
  })

  it('mounts the payment element with the client secret and confirms with the success page, redirect if_required', async () => {
    const { factory, calls } = fakeSdk()
    const el = { id: 'card' }
    const c = await mountCardPayment({ publishableKey: PK, clientSecret: CS, el, locale: 'fi', sdk: factory })
    assert.deepEqual(calls.init, [{ key: PK, opts: { locale: 'fi' } }])
    assert.deepEqual(calls.elements, [{ clientSecret: CS }])
    assert.deepEqual(calls.mount, [{ kind: 'payment', el }])
    const out = await c.confirm('https://site.example.com/checkout/success')
    assert.deepEqual(out, { ok: true, status: 'succeeded' })
    assert.equal(calls.confirm.length, 1)
    assert.equal(calls.confirm[0].redirect, 'if_required')
    assert.deepEqual(calls.confirm[0].confirmParams, { return_url: 'https://site.example.com/checkout/success' })
    c.destroy()
    assert.equal(calls.destroyed, 1)
  })

  it('a decline is retryable (card_declined); anything else is card_failed; a throw never escapes', async () => {
    for (const [type, want] of [['card_error', 'card_declined'], ['validation_error', 'card_declined'], ['api_error', 'card_failed'], ['', 'card_failed']]) {
      const { factory } = fakeSdk({ confirmResult: { error: { type, message: 'vendor text' } } })
      const c = await mountCardPayment({ publishableKey: PK, clientSecret: CS, el: {}, sdk: factory })
      assert.deepEqual(await c.confirm('https://x.example.com/s'), { ok: false, error: want }, type)
    }
    const { factory } = fakeSdk({ throws: true })
    const c = await mountCardPayment({ publishableKey: PK, clientSecret: CS, el: {}, sdk: factory })
    assert.deepEqual(await c.confirm('https://x.example.com/s'), { ok: false, error: 'card_failed' })
  })

  it('CONTROL: a bad config is refused before any SDK is touched', async () => {
    const { factory, calls } = fakeSdk()
    for (const cfg of [
      { publishableKey: 'sk_test_abc', clientSecret: CS, el: {} },
      { publishableKey: PK, clientSecret: 'pi_123', el: {} },
      { publishableKey: PK, clientSecret: CS, el: null },
    ]) {
      await assert.rejects(mountCardPayment({ ...cfg, sdk: factory }), /card_config/)
    }
    assert.equal(calls.init.length, 0)
  })

  it('loadCardSdk injects the script once and resolves the factory; a load error rejects card_sdk and may retry', async () => {
    const appended = []
    const win = {}
    const doc = { createElement: () => ({}), head: { appendChild: (s) => appended.push(s) } }
    const p1 = loadCardSdk({ doc, win })
    const p2 = loadCardSdk({ doc, win })
    assert.equal(appended.length, 1)
    assert.match(appended[0].src, /^https:\/\//)
    win.Stripe = () => ({})
    appended[0].onload()
    assert.equal(await p1, win.Stripe)
    assert.equal(await p2, win.Stripe)

    resetCardSdk()
    const win2 = {}
    const p3 = loadCardSdk({ doc, win: win2 })
    appended[1].onerror()
    await assert.rejects(p3, /card_sdk/)
    loadCardSdk({ doc, win: win2 }).catch(() => {})
    assert.equal(appended.length, 3, 'a failed load may be retried')
  })

  it('cardReturnCleanUrl strips every redirect-return parameter and keeps the rest', () => {
    const u = 'https://site.example.com/fi/checkout/success?payment_intent=pi_1&payment_intent_client_secret=pi_1_secret_2&redirect_status=succeeded&x=1#h'
    assert.equal(cardReturnCleanUrl(u), '/fi/checkout/success?x=1#h')
    assert.equal(cardReturnCleanUrl('https://site.example.com/checkout/success'), null)
    assert.equal(cardReturnCleanUrl('not a url'), null)
    for (const p of CARD_RETURN_PARAMS) assert.equal(cardReturnCleanUrl(`https://a.example.com/s?${p}=v`), '/s')
  })
})
