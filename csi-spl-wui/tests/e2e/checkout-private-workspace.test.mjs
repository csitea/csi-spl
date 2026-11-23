// Spec 181 row B3: the private-workspace checkout is an ORDER form, proved in a
// REAL browser against the mock bundle. The hub's B2 submit
// (POST /api/v1/checkout/private-workspace) is played by request
// interception, answering as handler.go submitOrder does.
//
// The row's red control: the page shows a token price, or a card field ->
// this test fails (steps 2 and 3). Also: the price lines are seats x 9 EUR
// and the VM cost + 33 % with no number; the page says the invoice comes
// monthly in arrears, paid by bank transfer [Q-18 C]; the submit carries no
// email and no payment field; a signed-out submit (401) offers sign-in.
//
// Plant the defect and watch it go red: add <input autocomplete="cc-number">
// to pages/checkout/private-workspace.vue (step 3), or a price line naming
// tokens (step 2).
//
// Run:
//   pnpm run test:e2e checkout-private-workspace
//   BASE_URL=<generated bundle> pnpm run test:e2e checkout-private-workspace
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const ROUTE = '/api/v1/checkout/private-workspace'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')

/* every way a card or payment field could show: an input, a vendor iframe, a card element */
const cardFields = (p) => p.evaluate(() => {
  const hits = []
  for (const el of document.querySelectorAll('input, select, textarea')) {
    const id = [el.autocomplete, el.name, el.id, el.dataset.test, el.placeholder, el.getAttribute('aria-label')].join(' ')
    if (/(^|\s)cc-|card|cvc|cvv|iban|expir/i.test(id)) hits.push(id.trim())
  }
  for (const f of document.querySelectorAll('iframe')) hits.push('iframe ' + (f.src || f.name))
  for (const el of document.querySelectorAll('[data-test*=card]')) hits.push('el ' + el.dataset.test)
  return hits
})

/* the hub's answers, as handler.go submitOrder writes them */
const ORDER = { order_id: 'wo_e2e', tenant_id: 'acme-e2e', status: 'submitted', seats_users: 3, email: 'owner@example.com',
  tenant_url: 'https://acme-e2e.example.com', replayed: false, currency: 'EUR', seat_member_cents: 900, vm_margin_pct: 33,
  invoice: 'monthly_in_arrears', payment: 'bank_transfer' }

async function fill(p) {
  await p.type('[data-test=pw-tenant]', 'acme-e2e')
  await p.$eval('[data-test=pw-seats]', (e) => { e.value = ''; e.dispatchEvent(new Event('input')) })
  await p.type('[data-test=pw-seats]', '3')
  await p.type('[data-test=pw-billing-name]', 'Example Oy')
  await p.type('[data-test=pw-billing-address]', 'Example Street 1, 00100 City')
  await p.type('[data-test=pw-billing-country]', 'fi')
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  const posts = []
  let answer = { status: 201, body: ORDER }
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.setRequestInterception(true)
  p.on('request', (r) => {
    if (!new URL(r.url()).pathname.endsWith(ROUTE)) return r.continue()
    if (r.method() === 'OPTIONS') return r.respond({ status: 204 })
    posts.push({ body: r.postData() || '', credentials: true })
    return r.respond({ status: answer.status, contentType: 'application/json', body: JSON.stringify(answer.body) })
  })

  // 1. the page opens as an order form with its two price lines
  await p.goto(server.base + '/checkout/private-workspace', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=pw-form]', { visible: true, timeout: 15000 }).catch(() => null)
  const lines = await p.$$eval('[data-test=pw-line]', (els) => els.map((e) => e.dataset.line)).catch(() => [])
  ok('1 the order form shows two price lines: seat_member, vm_cost', Boolean(await p.$('[data-test=pw-form]')) && lines.join() === 'seat_member,vm_cost', lines)
  const seat = await text(p, '[data-test=pw-line][data-line=seat_member]')
  const vm = await text(p, '[data-test=pw-line][data-line=vm_cost]')
  ok('1b the seat line is 1 x 9.00 EUR; the VM line is its cloud cost + 33% with no amount', seat.includes('9.00 EUR') && /\+ 33%/.test(vm) && !/\d+[.,]\d\d/.test(vm), { seat, vm })

  // 2. RED CONTROL: no token price anywhere on the page (Q-10 A, P5)
  const body = await p.evaluate(() => document.body.innerText)
  ok('2 the page names no token and no token price', !/token/i.test(body), (body.match(/.{0,40}token.{0,40}/i) || [])[0])

  // 3. RED CONTROL: no card field, no payment iframe (Q-18 C)
  const cards = await cardFields(p)
  ok('3 the page has no card field and no payment iframe', cards.length === 0, cards)

  // 4. the invoice: monthly in arrears, by bank transfer
  const inv = await text(p, '[data-test=pw-invoice]')
  ok('4 the page says the invoice comes monthly in arrears, paid by bank transfer', /each month/.test(inv) && /in arrears/.test(inv) && /bank transfer/.test(inv), inv)

  // 5. the seat total follows the seats
  await fill(p)
  const seat3 = await text(p, '[data-test=pw-line][data-line=seat_member]')
  ok('5 three seats read 27.00 EUR per month', seat3.includes('27.00 EUR'), seat3)

  // 6. a signed-out submit: 401 -> the reason and a sign-in link, no done state
  answer = { status: 401, body: { error: 'unauthorized', detail: 'sign in to order a private workspace' } }
  await p.click('[data-test=pw-submit]')
  await p.waitForSelector('[data-test=pw-error]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('6 a signed-out submit shows the reason and a sign-in link', Boolean(await p.$('[data-test=pw-sign-in]')) && !(await p.$('[data-test=pw-done]')))

  // 7. the submit: the order only, then the workspace is created
  answer = { status: 201, body: ORDER }
  await p.click('[data-test=pw-submit]')
  await p.waitForSelector('[data-test=pw-done]', { visible: true, timeout: 10000 }).catch(() => null)
  const sent = posts.length ? JSON.parse(posts[posts.length - 1].body) : {}
  ok('7 the submit sends the order only: slug, seats, billing; no email, no payment field', sent.tenant_id === 'acme-e2e' && sent.seats_users === 3 &&
    sent.billing?.country === 'FI' && !/card|email|payment|token|cvc|iban/i.test(JSON.stringify(sent)), sent)
  const done = await text(p, '[data-test=pw-done]')
  const href = await p.$eval('[data-test=pw-open]', (a) => a.getAttribute('href')).catch(() => '')
  ok('7b the workspace is created: its name and the link the hub gave', done.includes('acme-e2e') && /bank transfer/.test(done) && href === ORDER.tenant_url, { done, href })
  ok('7c after the submit still no card field and no token', (await cardFields(p)).length === 0 && !/token/i.test(await p.evaluate(() => document.body.innerText)))

  ok('8 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncheckout-private-workspace: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
