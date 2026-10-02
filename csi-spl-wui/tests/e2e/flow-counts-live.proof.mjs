// Live proof for spec 062 lane L5 (owner t1 25826b7b): on a deployed WUI + hub,
// member A mentions member B; B's desktop Flow badge goes 0 -> 1; B opens the
// Flow on a phone (a second signed-in session = a second socket); the desktop
// badge goes back to 0 within 1 s (FR-005, FR-007: the hub's `flow` frame,
// not the 5 s read-marks sync).
//
//   BASE=https://dev.<domain> A_EMAIL=<member A> A_PW_FILE=<0600 file> \
//   B_EMAIL=<member B> B_PW_FILE=<0600 file> B_ID=HUM-<n> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=] node tests/e2e/flow-counts-live.proof.mjs
//
// A writes ONE line: a DM to B naming @B (CHANNEL set: a line in that channel
// instead, B must be a member). Three sign-ins per run (A, B desktop, B phone):
// the native login allows 10 per email per 15 min.
//
// steps
//   start     B's desktop shows no number once B's phone has opened the Flow
//   rise      after A's line, B's desktop shows 1 (and the title "(1) ...")
//   listed    B's phone lists A's line in Mine, as a mention
//   clear     B's phone opens the Flow: the desktop number is gone in < 1000 ms
//
// The passwords are read from files and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} must be set`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/$/, '')
const A = { email: need('A_EMAIL'), pw: readFileSync(need('A_PW_FILE'), 'utf8').trim() }
const B = { email: need('B_EMAIL'), pw: readFileSync(need('B_PW_FILE'), 'utf8').trim(), id: need('B_ID') }
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || ''
const COUNT = '[data-testid=sidebar-tab-flow-count]'
const RUN = new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14)
mkdirSync(OUT, { recursive: true })

const results = []
const facts = { base: BASE, run: RUN }
const step = (name, pass, ev) => {
  results.push(pass)
  console.log(`  ${pass ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  const spec = process.env.PUPPETEER_CORE
  const href = spec ? pathToFileURL(spec).href : pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
}

/** A signed-in page in its own browser context (its own cookie jar = its own device). */
async function signIn(browser, who, viewport, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport(viewport)
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent(path)}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', who.email)
  await p.type('[data-test=native-auth-password]', who.pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  return { p, ok }
}

const countOf = (p) => p.evaluate((sel) => (document.querySelector(sel)?.textContent || '').trim(), COUNT)

const browser = await launch()
try {
  const desk = await signIn(browser, B, { width: 1440, height: 900 }, '/lobby')
  step('B desktop signed in', desk.ok, { url: desk.p.url() })
  facts.build = await desk.p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  console.log('  build.json ' + JSON.stringify(facts.build))
  const phone = await signIn(browser, B, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/')
  step('B phone signed in', phone.ok, { url: phone.p.url() })

  /* start: the phone opens the Flow (f:seen), then leaves it for the channels list */
  await phone.p.waitForSelector('[data-testid=sidebar-tab-flow]', { timeout: 30000 })
  await phone.p.click('[data-testid=sidebar-tab-flow]')
  await sleep(1500)
  await phone.p.click('[data-testid=sidebar-tab-channels]')
  await desk.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 5000 }, COUNT).catch(() => {})
  const c0 = await countOf(desk.p)
  step('start: B desktop shows no number', c0 === '', { count: c0 })

  /* A's line: a DM to B naming @B (or a channel line) */
  const a = await signIn(browser, A, { width: 1440, height: 900 }, CHANNEL ? `/channel/${encodeURIComponent(CHANNEL)}` : `/dm/${encodeURIComponent(B.id)}`)
  step('A signed in', a.ok, { url: a.p.url() })
  await a.p.waitForSelector('form.composer textarea', { timeout: 30000 })
  const text = `spec 062 flow proof ${RUN} @${B.id} please look`
  await a.p.click('form.composer textarea')
  /* the @ word is not last, so the mention picker has closed when Enter sends */
  await a.p.keyboard.type(text)
  const t0 = Date.now()
  await a.p.keyboard.press('Enter')
  const sent = await a.p.waitForFunction((needle) => {
    const box = document.querySelector('form.composer textarea')
    return (!box || !box.value.includes(needle)) && [...document.querySelectorAll('main, [role=main], .feed, body')].some((e) => (e.textContent || '').includes(needle))
  }, { timeout: 15000 }, `flow proof ${RUN}`).then(() => true, () => false)
  step('A\'s line is sent and shows in A\'s feed', sent)
  if (!sent) await a.p.screenshot({ path: join(OUT, 'flow-counts-a.png') })

  /* rise: 0 -> 1 on B's desktop */
  const rose = await desk.p.waitForFunction((sel) => (document.querySelector(sel)?.textContent || '').trim() !== '', { timeout: 20000 }, COUNT).then(() => true, () => false)
  const riseMs = Date.now() - t0
  const c1 = await countOf(desk.p)
  const title1 = await desk.p.title()
  facts.rise_ms = riseMs
  step('rise: B desktop shows 1 after A\'s line', rose && c1 === '1', { count: c1, ms: riseMs })
  step('rise: the tab title leads with (1)', title1.startsWith('(1) '), { title: title1 })

  /* clear: the phone opens the Flow; the desktop drops within 1 s */
  const t1 = Date.now()
  await phone.p.click('[data-testid=sidebar-tab-flow]')
  const cleared = await desk.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 10000, polling: 20 }, COUNT).then(() => true, () => false)
  const clearMs = Date.now() - t1
  facts.clear_ms = clearMs
  step('clear: B desktop number gone within 1000 ms of the phone opening the Flow', cleared && clearMs < 1000, { ms: clearMs })
  const title2 = await desk.p.title()
  step('clear: the title drops its number', !/^\(\d+\+?\) /.test(title2), { title: title2 })

  /* listed: the phone's Mine holds A's line as a mention */
  const listed = await phone.p.waitForFunction((needle) => [...document.querySelectorAll('[data-testid=sidebar-panel-flow] [data-testid=left-entry]')]
    .some((e) => e.getAttribute('data-type') === 'mention' && (e.textContent || '').includes(needle)), { timeout: 10000 }, `flow proof ${RUN}`).then(() => true, () => false)
  const scope = await phone.p.evaluate(() => document.querySelector('[data-testid=flow-scope-mine]')?.getAttribute('aria-checked') || '')
  step('listed: B\'s phone lists A\'s line in Mine as a mention', listed && scope === 'true', { scope })

  await desk.p.screenshot({ path: join(OUT, 'flow-counts-desktop.png') })
  await phone.p.screenshot({ path: join(OUT, 'flow-counts-phone.png') })
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'flow-counts-live.json'), JSON.stringify(facts, null, 2))
const ok = results.length > 0 && results.every(Boolean)
console.log(ok ? `PASS ${results.length}/${results.length}` : `FAIL ${results.filter(Boolean).length}/${results.length}`)
process.exit(ok ? 0 : 1)
