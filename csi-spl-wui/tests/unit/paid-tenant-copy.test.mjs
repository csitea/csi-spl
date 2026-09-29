// 047 W1 + W2 (SPL-1161, SPL-1162): a stranger finds the way to /checkout
// from the documents they land on, and the buyer is told which address signs
// in as the workspace owner (the paid webhook invited only that one).
//
// Run: node tests/unit/paid-tenant-copy.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const LOCALES = join(WUI, 'i18n/locales')

describe('Buy a workspace (047 W2)', () => {
  const link = src('src/components/BuyWorkspaceLink.vue')

  it('is a static link to /checkout, so the prerendered documents carry it', () => {
    assert.match(link, /<NuxtLink :to="localePath\('\/checkout'\)" data-test="buy-workspace-link">/)
  })

  it('the price line comes from the plan, only while it is on sale, and loads the client lazily', () => {
    assert.match(link, /await import\('~\/utils\/checkout-client\.mjs'\)/)
    assert.doesNotMatch(link, /^import .*checkout-client/m)
    assert.match(link, /\['fake', 'card'\]\.includes\(checkoutMode\(out\.data\)\)/)
    assert.match(link, /t\('checkout\.price', \{ price \}\)/)
  })

  it('rides in the prerendered product shell and on the sign-in page (with the price)', () => {
    assert.match(src('src/layouts/default.vue'), /<template #fallback>\s*(<!--[\s\S]*?-->\s*)?<div class="login"><p class="muted">\{\{ \$t\('app\.loading'\) \}\}<\/p><BuyWorkspaceLink \/><\/div>/)
    assert.match(src('src/pages/login.vue'), /<BuyWorkspaceLink v-if="session\.state !== 'in'" with-price \/>/)
  })
})

describe('sign in with the checkout email (047 W1)', () => {
  it('the key reveal names the owner address the claim answer carries', () => {
    const reveal = src('src/components/CheckoutKeyReveal.vue')
    assert.match(reveal, /<i18n-t v-if="email" keypath="checkout\.key\.sign_in_as"[^>]*data-test="checkout-sign-in-as">/)
    for (const page of ['src/pages/checkout/success.vue', 'src/pages/checkout/claim.vue']) {
      const s = src(page)
      assert.match(s, /:email="email"/, page)
      assert.match(s, /email\.value = String\(r\.email \|\| ''\)/, page)
    }
  })

  it('every locale has both strings; the owner line keeps its {email} slot', () => {
    const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const c = JSON.parse(readFileSync(join(LOCALES, f), 'utf8')).checkout
      assert.ok(c.buy?.link?.trim(), `${f}: checkout.buy.link`)
      assert.match(c.key?.sign_in_as || '', /\{email\}/, `${f}: checkout.key.sign_in_as`)
      assert.doesNotMatch(c.key.sign_in_as + c.buy.link, /[@<]/, `${f}: '@' or '<' breaks nuxt generate`)
    }
  })
})
