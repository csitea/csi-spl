// Topics view: a click on the opener's kind badge sets that message's kind.
// The row and the opened topic both show it. The row menu's Kind item opens
// the same picker, including the phone sheet.
//
//   node tests/e2e/topics-view-kind.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const CARD = '22222222-2222-4222-8222-222222222222'
const OTHER = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

async function until(p, fn, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    const ok = await p.evaluate(fn).catch(() => false)
    if (ok) return true
    await sleep(150)
  }
  return false
}

async function sign(p) {
  await p.evaluateOnNewDocument((claims) => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* private */ }
  }, CLAIMS)
}

const rowSel = `a.topic-row[data-key="${TOPIC}"]`
const kindsOf = (sel) => {
  const row = document.querySelector(sel)
  if (!row) return null
  return [...row.querySelectorAll('[data-kind]')].map((el) => el.getAttribute('data-kind'))
}

async function clickInPage(p, sel) {
  return p.evaluate((s) => {
    const el = document.querySelector(s)
    if (!el) return false
    el.click()
    return true
  }, sel).catch(() => false)
}

/* A cold dev server reloads once after the first paint. Wait until the
   topics list has stayed up, so the kind change is not wiped by that reload. */
async function settledList(p) {
  let last = 0
  const mark = () => { last = Date.now() }
  p.on('framenavigated', mark)
  mark()
  const t0 = Date.now()
  let stable = false
  while (Date.now() - t0 < 30000) {
    const there = await p.evaluate(() => Boolean(document.querySelector('a.topic-row'))).catch(() => false)
    if (there && Date.now() - last > 2000) { stable = true; break }
    await sleep(200)
  }
  p.off('framenavigated', mark)
  return stable
}

async function openMenu(p, taskId) {
  const btn = `[data-menu-id="home:${taskId}"]`
  await p.waitForSelector(btn, { timeout: 15000 })
  for (let i = 0; i < 4; i++) {
    await p.evaluate((s) => document.querySelector(s)?.click(), btn)
    const opened = await until(p, () => Boolean(document.querySelector('[data-testid=sidebar-row-menu-panel]')), 3000)
    if (opened) return true
  }
  return false
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  const consoleErrors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 400)))
  p.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text().slice(0, 300)) })
  p.setDefaultNavigationTimeout(NAV)
  await sign(p)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/`, { waitUntil: 'domcontentloaded', timeout: NAV })
  const listed = await until(p, () => Boolean(document.querySelector('a.topic-row')), 90000)
  let snap = ''
  if (!listed) {
    snap = await p.evaluate(() => ({
      href: location.href,
      text: (document.body && document.body.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 500),
      shell: Boolean(document.querySelector('.spool-shell')),
    })).catch((e) => String(e))
  }
  check('the topics list is up', listed, { snap, errors, consoleErrors: consoleErrors.slice(0, 6) })
  if (!listed) throw new Error('topics list never appeared ' + JSON.stringify({ snap, errors, consoleErrors: consoleErrors.slice(0, 8) }))
  check('the list stayed up', await settledList(p))

  const before = await p.evaluate(kindsOf, rowSel)
  check('the multi-kind row shows task, note and result', JSON.stringify(before) === JSON.stringify(['task', 'note', 'result']), before)

  await clickInPage(p, `${rowSel} [data-kind="task"]`)
  const picker = await until(p, () => Boolean(document.querySelector('[data-testid=kind-picker]')?.getClientRects().length), 8000)
  const whileOpen = await p.evaluate((sel) => {
    const row = document.querySelector(sel)
    const btns = row ? [...row.querySelectorAll('[data-testid=kind-badge-btn]')] : []
    const spans = row ? [...row.querySelectorAll('span.kind[data-kind]')].map((el) => el.getAttribute('data-kind')) : []
    return {
      pane: Boolean(document.querySelector('[data-test=topic-section]')),
      btnKinds: btns.map((el) => el.getAttribute('data-kind')),
      spans,
    }
  }, rowSel)
  check('the badge click opens the picker and leaves the topic closed', picker && whileOpen.pane === false, whileOpen)
  check('only the opener badge is a button, still task', JSON.stringify(whileOpen.btnKinds) === JSON.stringify(['task']) && JSON.stringify(whileOpen.spans) === JSON.stringify(['note', 'result']), whileOpen)

  await clickInPage(p, '[data-testid=kind-picker] [data-kind=blocker]')
  const changed = await until(p, () => {
    const row = document.querySelector('a.topic-row[data-key="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]')
    if (!row) return false
    const kinds = [...row.querySelectorAll('[data-kind]')].map((el) => el.getAttribute('data-kind'))
    return kinds.includes('blocker') && !kinds.includes('task')
  }, 8000)
  check('the row drops task and shows blocker', changed)

  await clickInPage(p, `${rowSel} .topic-subject`)
  const card = await until(p, () => Boolean(document.querySelector('[data-test=topic-section] article.msg[data-msg-id="22222222-2222-4222-8222-222222222222"] [data-kind=blocker]')), 8000)
  check('the opened topic card shows blocker', card)

  await p.keyboard.press('Escape')
  await sleep(200)
  const menu = await openMenu(p, TOPIC)
  const kindItem = menu && await until(p, () => Boolean(document.querySelector('[data-testid=sidebar-row-menu-kind]')), 5000)
  check('the row menu offers Kind', Boolean(kindItem))
  if (kindItem) {
    await clickInPage(p, '[data-testid=sidebar-row-menu-kind]')
    check('Kind in the menu opens the picker', await until(p, () => Boolean(document.querySelector('[data-testid=kind-picker]')), 5000))
    await p.keyboard.press('Escape')
  }

  const other = await openMenu(p, OTHER)
  let otherKind = true
  if (other) {
    await until(p, () => {
      const st = document.querySelector('[data-testid=sidebar-row-menu-panel]')?.getAttribute('data-topic-state') || ''
      return st === 'ready' || st === 'none'
    }, 5000)
    await sleep(400)
    otherKind = await p.evaluate(() => Boolean(document.querySelector('[data-testid=sidebar-row-menu-kind]')))
  }
  check('a topic the viewer did not open has no Kind item', other && otherKind === false, { other, otherKind })
  check('no page error', errors.length === 0, errors)

  await p.screenshot({ path: '/tmp/g399-topics-kind-desktop.png' })
  await p.close()

  const phone = await browser.newPage()
  const phoneErr = []
  phone.on('pageerror', (e) => phoneErr.push(String(e).slice(0, 240)))
  phone.setDefaultNavigationTimeout(NAV)
  await sign(phone)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
  await phone.goto(`${srv.base}/`, { waitUntil: 'load', timeout: NAV })
  await until(phone, () => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === '1', 15000)
  await phone.evaluate(async () => {
    const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
    try { await r.push('/') } catch { /* duplicated: the shell pushes level 2 */ }
  })
  const level2 = await until(phone, () => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === '2' && Boolean(document.querySelector('a.topic-row')), 15000)
  check('phone topics view is the middle list', level2)
  if (level2) {
    const opened = await openMenu(phone, TOPIC)
    const item = opened && await until(phone, () => Boolean(document.querySelector('[data-testid=sidebar-row-menu-kind]')), 5000)
    check('phone row menu offers Kind', Boolean(item))
    if (item) {
      await clickInPage(phone, '[data-testid=sidebar-row-menu-kind]')
      const sheet = await until(phone, () => {
        const el = document.querySelector('[data-testid=kind-picker]')
        return Boolean(el && el.classList.contains('touch-sheet') && el.getClientRects().length)
      }, 5000)
      check('phone Kind opens the picker sheet', sheet)
    }
  }
  check('phone page has no error', phoneErr.length === 0, phoneErr)
  await phone.screenshot({ path: '/tmp/g399-topics-kind-phone.png' })
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
if (failed.length) {
  console.error(`FAILED ${failed.length}/${results.length}`)
  process.exit(1)
}
console.log(`OK ${results.length}`)
