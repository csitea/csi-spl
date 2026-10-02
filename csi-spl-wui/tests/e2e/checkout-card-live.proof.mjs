// 006 T021w live proof of the CARD step against a deployed WUI whose hub runs
// the card rail in TEST mode (dev): /checkout -> tenant + email -> the card
// form (the vendor's iframe) -> the vendor's generic test card -> Pay ->
// /checkout/success -> the root key shown once. Checks: no key or claim
// token in the URL or storage, no redirect-return secret left in the address
// bar, 0 CSP violations, a reload shows "already claimed". The key text is
// never printed; results.json + screenshots go to OUT.
//
//   BASE=https://dev.<domain> TENANT=<new slug> EMAIL=<buyer> OUT=<dir> \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/checkout-card-live.proof.mjs
//
// TEST MODE ONLY: the plan must say rail=card and the page must show the card
// step; the card number is the vendor's public test number (a live key
// declines it, so no money can move). Exit 0 = every step PASS.
import { writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const EMAIL = need('EMAIL')
const TEST_CARD = ['4242', '4242', '4242', '4242'].join('')
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let exit = 1
try {
  const plan = await (await fetch(BASE + '/api/v1/checkout/plan')).json()
  step('plan: the card rail, available, a TEST publishable key', plan.rail === 'card' && plan.available === true && /^pk_test_/.test(plan.publishable_key || ''),
    { rail: plan.rail, available: plan.available, key_mode: String(plan.publishable_key || '').slice(0, 8) })
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  const csp = []
  p.on('console', (m) => { if (/Content Security Policy|Refused to (load|frame|connect|execute)/i.test(m.text())) csp.push(m.text().slice(0, 200)) })
  await p.goto(BASE + '/en/checkout', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=checkout-tenant]', { timeout: 20000 })
  await p.type('[data-test=checkout-tenant]', TENANT)
  await p.type('[data-test=checkout-email]', EMAIL)
  await p.click('[data-test=checkout-submit]')
  const cardStep = await p.waitForSelector('[data-test=checkout-card]', { timeout: 20000 }).catch(() => null)
  step('checkout: the card step replaces the form', !!cardStep)
  // the vendor's iframe mounted in the card element: pick the card method
  // (a tab, or the "more methods" select when the account offers others
  // first), then wait for the card number field
  let frame = null
  for (let i = 0; i < 60 && !frame; i++) {
    for (const f of p.frames()) {
      if (f === p.mainFrame() || new URL(f.url() || 'about:blank', BASE).origin === new URL(BASE).origin) continue
      const tab = await f.$('button[value=card]').catch(() => null)
      if (tab) await tab.click()
      else {
        const sel = await f.$('select option[value=card]').catch(() => null)
        if (sel) await f.evaluate(() => { const s = [...document.querySelectorAll('select')].find((x) => x.querySelector('option[value=card]')); s.value = 'card'; s.dispatchEvent(new Event('change', { bubbles: true })) })
      }
      if (await f.waitForSelector('input[name=number]', { timeout: 1500 }).catch(() => null)) { frame = f; break }
    }
    if (!frame) await sleep(500)
  }
  step('the card form (vendor iframe) mounted', !!frame)
  await p.screenshot({ path: `${OUT}/card-form.png` })
  await frame.type('input[name=number]', TEST_CARD, { delay: 20 })
  await frame.type('input[name=expiry]', '12' + String((new Date().getUTCFullYear() + 3) % 100), { delay: 20 })
  await frame.type('input[name=cvc]', '123', { delay: 20 })
  const postal = await frame.$('input[name=postalCode]')
  if (postal) await postal.type('00100', { delay: 20 })
  await p.click('[data-test=checkout-card-pay]')
  await p.waitForFunction(() => location.pathname.endsWith('/checkout/success'), { timeout: 60000 })
  step('Pay -> the success page', true, { path: new URL(p.url()).pathname })
  const shown = await p.waitForSelector('[data-test=checkout-key]', { timeout: 120000 }).catch(() => null)
  step('the webhook marked it paid and the key is shown once', !!shown)
  await p.screenshot({ path: `${OUT}/success.png` })
  const leak = await p.evaluate(() => {
    const all = [location.href, JSON.stringify({ ...sessionStorage }), JSON.stringify({ ...localStorage })].join(' ')
    return { urlSecret: /payment_intent_client_secret|_secret_/.test(location.href), storageKey: /root_private_key|[A-Za-z0-9+/]{80,}={0,2}/.test(all) }
  })
  step('no key, claim token or client secret in the URL or storage', !leak.urlSecret && !leak.storageKey, leak)
  await p.reload({ waitUntil: 'networkidle2' })
  const again = await p.waitForSelector('[data-test=checkout-claimed]', { timeout: 30000 }).catch(() => null)
  step('a reload shows "already claimed"', !!again)
  step('0 CSP violations', csp.length === 0, { csp })
  exit = res.steps.every((s) => s.ok) ? 0 : 1
} catch (e) {
  step('run', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(exit)
