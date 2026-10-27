// Workspace settings -> Agent keys (spec 159 T7 on spec 127 W1, SPL-3745),
// proved in a REAL browser against the mock bundle (utils/vendor-keys.mjs
// plays the hub routes of spec 127 4.3; the mock keeps last4 only).
//
// The row's red control (spec 159 section 11):
//   - a biz_owner sees the page, a developer does not (no nav entry, and the
//     URL itself shows one line and no key control);
//   - the exhausted state shows retry, and retry clears it;
//   - the key is cleared after save (127 L12): the input, the page text, the
//     Pinia store, localStorage and sessionStorage hold no `sk-test-0000`,
//     and no request the page made carries it (127 L17, the mock sends none
//     to the hub, so any request with it is a beacon or a leak).
// Also: grok and mistral read "waiting for the vendor's terms", agy "not
// supported" (127 R5.2), an unconfirmed manager sees the rows read-only, and
// Remove asks first.
//
// Plant the defect and watch it go red: drop the clear after save in
// pages/tenant-settings/agent-keys.vue (step 4 goes red), show the section
// without its permission in utils/tenant-settings-nav.ts (step 2 goes red),
// or hide the retry button (step 6 goes red).
//
// Run:
//   pnpm run test:e2e agent-keys
//   BASE_URL=<generated bundle> pnpm run test:e2e agent-keys
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FAKE = 'sk-test-0000'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const attrs = (p, sel, a) => p.$$eval(sel, (els, a) => els.map((e) => e.getAttribute(a)), a)
const rowState = (p, kind) => p.$eval(`[data-test=vk-row][data-kind=${kind}]`, (e) => e.dataset.state).catch(() => '')

/* hub permissions of the two roles (csi-spl-api internal/rbac Defaults, rdb 0232) */
const BIZ = { role: 'biz_owner', permissions: ['members.invite', 'members.roles', 'tenant.settings', 'keys.manage', 'audit.read', 'vendor_keys.manage'] }
const DEV = { role: 'developer', permissions: ['topics.read', 'notes.send', 'agents.command', 'channels.manage', 'docs.read', 'docs.write'] }

/* every place in the browser the typed key could still sit after the save */
const keyTraces = (p, fake) => p.evaluate((fake) => {
  const where = []
  const scan = (name, s) => { if (String(s).includes(fake)) where.push(name) }
  for (const el of document.querySelectorAll('input, textarea')) scan('input:' + (el.dataset.test || el.name || el.type), el.value)
  scan('page text', document.body.innerText)
  for (let i = 0; i < localStorage.length; i++) scan('localStorage:' + localStorage.key(i), localStorage.getItem(localStorage.key(i)))
  for (let i = 0; i < sessionStorage.length; i++) scan('sessionStorage:' + sessionStorage.key(i), sessionStorage.getItem(sessionStorage.key(i)))
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const pinia = app?.config?.globalProperties?.$pinia
  try { scan('pinia', JSON.stringify(pinia?.state?.value ?? {})) } catch { where.push('pinia unreadable') }
  return { where, pinia: Boolean(pinia) }
}, fake)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  const leaks = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  p.on('request', (r) => {
    const body = r.postData() || ''
    if (r.url().includes(FAKE) || body.includes(FAKE)) leaks.push(r.url())
  })
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((biz) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Owner', email: 'owner@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify(biz))
    localStorage.removeItem('spool.mock.vendor_keys')
    localStorage.removeItem('spool.mock.vendor_keys_unconfirmed')
  }, BIZ)

  // 1. a biz_owner: the section is in the nav and the page lists the five kinds
  await p.goto(server.base + '/tenant-settings/agent-keys', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=vk-row]', { visible: true, timeout: 15000 }).catch(() => null)
  const nav = await attrs(p, '[data-test=tenant-settings-nav] a', 'data-test')
  const kinds = await attrs(p, '[data-test=vk-row]', 'data-kind')
  ok('1 a biz_owner sees Agent keys in the nav and the five kinds', nav.includes('tenant-settings-nav-agent-keys') && kinds.join() === 'claude,grok,agy,mistral,qwen', { nav, kinds })
  const states = await attrs(p, '[data-test=vk-row]', 'data-state')
  ok('1b claude and qwen can take a key; grok, agy, mistral are not available', states.join() === 'not_set,not_available,not_available,not_available,not_set', states)
  const agyWhy = await text(p, '[data-test=vk-row][data-kind=agy] [data-test=vk-unavailable]')
  const grokWhy = await text(p, '[data-test=vk-row][data-kind=grok] [data-test=vk-unavailable]')
  ok('1c agy says "not supported"; grok says it waits for the vendor\'s terms', agyWhy.length > 0 && grokWhy.length > 0 && agyWhy !== grokWhy && !(await p.$('[data-test=vk-row][data-kind=grok] [data-test=vk-input]')), { agyWhy, grokWhy })

  // 3. set the claude key: a password field, then saved, last4 shown
  const inputType = await p.$eval('[data-test=vk-row][data-kind=claude] [data-test=vk-input]', (e) => [e.type, e.autocomplete].join()).catch(() => '')
  ok('3 the key input is a password field with autocomplete=new-password (127 L12)', inputType === 'password,new-password', inputType)
  await p.type('[data-test=vk-row][data-kind=claude] [data-test=vk-input]', FAKE)
  await p.click('[data-test=vk-row][data-kind=claude] [data-test=vk-save]')
  await p.waitForFunction(() => document.querySelector('[data-test=vk-row][data-kind=claude]')?.dataset.state === 'set', { timeout: 10000 }).catch(() => null)
  const last4 = await text(p, '[data-test=vk-row][data-kind=claude] [data-test=vk-last4]')
  ok('3b saved: the claude row is set and shows the last 4', (await rowState(p, 'claude')) === 'set' && last4.includes('0000'), { state: await rowState(p, 'claude'), last4 })

  // 4. 127 L12: nothing in the browser holds the key after the save
  const after = await keyTraces(p, FAKE)
  ok('4 after save the input, page, Pinia store, localStorage and sessionStorage hold no sk-test-0000', after.where.length === 0 && after.pinia, after)

  // 5. a refused PUT (qwen without its https base_url): the reason, no beacon
  await p.type('[data-test=vk-row][data-kind=qwen] [data-test=vk-input]', FAKE)
  await p.click('[data-test=vk-row][data-kind=qwen] [data-test=vk-save]')
  await p.waitForSelector('[data-test=vk-row][data-kind=qwen] [data-test=vk-error]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('5 qwen without a base_url is refused with the reason', (await text(p, '[data-test=vk-row][data-kind=qwen] [data-test=vk-error]')).length > 0 && (await rowState(p, 'qwen')) === 'not_set')
  await p.$eval('[data-test=vk-row][data-kind=qwen] [data-test=vk-input]', (e) => { e.value = ''; e.dispatchEvent(new Event('input')) })
  await sleep(300)
  ok('5b no request the page made carries sk-test-0000 (127 L17)', leaks.length === 0, leaks)

  // 6. exhausted (spec 159 9): the row says so and offers retry; retry clears it
  await p.evaluate(() => {
    const rows = JSON.parse(localStorage.getItem('spool.mock.vendor_keys') || '{}')
    rows.claude = { ...rows.claude, exhausted: true }
    localStorage.setItem('spool.mock.vendor_keys', JSON.stringify(rows))
  })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=vk-row][data-kind=claude]', { visible: true, timeout: 15000 }).catch(() => null)
  const retry = await p.$('[data-test=vk-row][data-kind=claude] [data-test=vk-retry]')
  ok('6 an exhausted key shows its state and a retry button', (await rowState(p, 'claude')) === 'exhausted' && Boolean(retry), { state: await rowState(p, 'claude') })
  if (retry) await retry.click()
  await p.waitForFunction(() => document.querySelector('[data-test=vk-row][data-kind=claude]')?.dataset.state === 'set', { timeout: 5000 }).catch(() => null)
  ok('6b retry: the key is usable again', (await rowState(p, 'claude')) === 'set')

  // 7. Remove asks first, then the row is not set
  await p.click('[data-test=vk-row][data-kind=claude] [data-test=vk-remove]')
  await p.waitForSelector('[data-test=vk-remove-confirm]', { visible: true, timeout: 5000 }).catch(() => null)
  const asked = Boolean(await p.$('[data-test=vk-remove-confirm]'))
  if (asked) await p.click('[data-test=vk-remove-confirm]')
  await p.waitForFunction(() => document.querySelector('[data-test=vk-row][data-kind=claude]')?.dataset.state === 'not_set', { timeout: 5000 }).catch(() => null)
  ok('7 Remove asks, then the claude row is not set', asked && (await rowState(p, 'claude')) === 'not_set')

  // 8. an unconfirmed (operator-made) manager: rows read, nothing changes
  await p.evaluate(() => localStorage.setItem('spool.mock.vendor_keys_unconfirmed', '1'))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=vk-row]', { visible: true, timeout: 15000 }).catch(() => null)
  const controls = await p.$$eval('[data-test=vk-row] input, [data-test=vk-row] button', (xs) => xs.length)
  ok('8 an unconfirmed manager sees the rows read-only, with the reason', Boolean(await p.$('[data-test=vk-unconfirmed]')) && controls === 0, { controls })
  await p.evaluate(() => localStorage.removeItem('spool.mock.vendor_keys_unconfirmed'))

  // 2. a developer: no nav entry, and the URL shows one line, no key control
  await p.evaluate((dev) => localStorage.setItem('spool.mock.me', JSON.stringify(dev)), DEV)
  await p.goto(server.base + '/tenant-settings/agent-keys', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=vk-forbidden], [data-test=vk-row]', { timeout: 15000 }).catch(() => null)
  const devNav = await attrs(p, '[data-test=tenant-settings-nav] a', 'data-test')
  ok('2 a developer does not see the page: no nav entry, no rows, one line', !devNav.includes('tenant-settings-nav-agent-keys') &&
    !(await p.$('[data-test=vk-row]')) && Boolean(await p.$('[data-test=vk-forbidden]')), { devNav })
  await p.evaluate(() => { localStorage.removeItem('spool.mock.me'); localStorage.removeItem('spool.mock.vendor_keys') })

  ok('9 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nagent-keys: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
