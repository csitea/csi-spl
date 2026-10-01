// Flow + Search live proof (owner, t1 topic 635f8072): the acceptance suite's
// use case on a DEPLOYED host with real data - "quickly browse through the
// entries and pick exactly the one". READ-ONLY: it signs one member in and
// clicks, it never posts, edits or deletes.
//
//   Flow     the left list, entries are messages; a click opens the message in
//            its channel / DM / thread (never /t/), marked; the list stays
//   keyboard ArrowDown + Enter opens the next entry, focus stays on the list
//   Search   /search?q=<a word from a Flow entry>: the hits are the left list,
//            a click opens the hit in place; query + list stay
//   links    a cold /m/<id> lands marked in place; an unknown id: a notice
//   phone    390: the list full screen, a tap opens in place, ONE Back returns
//            to the list with the same entry selected
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/flow-search-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const TENANT = process.env.TENANT || 't1'
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const ANY_LIST = '[data-testid=left-list]'
const list = (mode) => `${ANY_LIST}[data-mode=${mode}]`
const entries = (mode) => `${list(mode)} [data-testid=left-entry]`
const entry = (mode, id) => `${entries(mode)}[data-msg-id="${id}"]`
const marked = (id) => `[data-msg-id="${id}"]:is(.open-focus, .search-focus)`
const UNKNOWN = '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f'
const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const ok = (name, pass, ev) => {
  res.steps.push({ name, ok: Boolean(pass), ev })
  console.log(`  ${pass ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const seen = (p, sel, timeout = 15000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true).catch(() => false)
const path = (p) => new URL(p.url()).pathname
const notTopics = (p) => !/\/t(\/|$)/.test(path(p))
const selected = (p, mode) => p.$eval(`${entries(mode)}[aria-selected=true]`, (el) => el.getAttribute('data-msg-id')).catch(() => '')
const ids = (p, mode) => p.$$eval(entries(mode), (els) => els.map((e) => e.getAttribute('data-msg-id')).filter(Boolean))
/* An entry with neither a channel nor a DM peer (a message to ALL-0 outside
   any channel) shows "unknown" as its place and can only open on /t/. The
   checks below judge the entries that HAVE a place; these are counted apart. */
const byPlace = (p, mode, want) => p.$$eval(entries(mode), (els, want) => els.filter((e) => {
  /* the deployed CSP refuses new Function: the predicate lives here, inline */
  const w = (e.querySelector('.side-hit__where')?.textContent || '').trim()
  const has = w !== '' && !/^unkn/i.test(w)
  return has === want
}).map((e) => e.getAttribute('data-msg-id')).filter(Boolean), want)
const placed = (p, mode) => byPlace(p, mode, true)
const unplaced = (p, mode) => byPlace(p, mode, false)
async function shots(p, name) {
  for (const theme of ['light', 'dark']) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await p.screenshot({ path: `${OUT}/${name}-${theme}.png` })
  }
  await p.evaluate(() => document.documentElement.removeAttribute('data-theme'))
}

async function signIn(p) {
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 90000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.endsWith('/login'), { timeout: 60000 }).catch(() => {})
  await sleep(3000)
}

/** The rail's Flow tab; a click before hydration is lost, so retry. */
async function openFlow(p, tap = false) {
  const tab = '[data-testid=sidebar-tab-flow]'
  for (let i = 0; i < 6; i++) {
    if (await seen(p, list('flow'), i ? 3000 : 1000)) return true
    await p.waitForSelector(tab, { visible: true, timeout: 30000 }).catch(() => {})
    await (tap ? p.tap(tab) : p.click(tab)).catch(() => {})
  }
  return seen(p, list('flow'), 5000)
}

/** A word worth searching: the longest plain word of an entry's text. */
const wordOf = (p, mode, id) => p.$eval(entry(mode, id), (el) => {
  /* innerText keeps the row's parts apart; textContent runs author, place
     and time into one non-word ("desklobby18"). Letters only. */
  const words = (el.innerText || '').split(/[^\p{L}]+/u).filter((w) => w.length >= 5)
  return words.sort((a, b) => b.length - a.length)[0] || ''
}).catch(() => '')

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 180000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--window-size=1440,900'],
})
const errors = []
try {
  const ctx = await browser.createBrowserContext()
  const d = await ctx.newPage()
  d.on('pageerror', (e) => errors.push(String(e && e.message)))
  d.setDefaultNavigationTimeout(90000)
  await d.setViewport(DESKTOP)
  await signIn(d)

  /* 1 Flow */
  await d.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
  const flowUp = await openFlow(d)
  /* the entries stream in: wait for the list to settle at >= 3 rows */
  await d.waitForFunction((sel) => document.querySelectorAll(sel).length >= 3, { timeout: 60000 }, entries('flow')).catch(() => {})
  await sleep(2000)
  const flow = flowUp ? await placed(d, 'flow') : []
  const nowhere = flowUp ? await unplaced(d, 'flow') : []
  ok('1.1 Flow is the left list of message entries', flowUp && flow.length + nowhere.length >= 3, { placed: flow.length, unknownPlace: nowhere.length })
  res.unknownPlace = nowhere
  const rows = await d.$$eval('[data-testid=sidebar-panel-flow] a.nav-item[data-kind]', (els) => els.length).catch(() => 0)
  ok('1.2 no agent / channel LIST rows in Flow', rows === 0, { rows })
  await shots(d, '1-flow-desktop')

  /* 2 pick two entries: each opens in place, marked, the list stays */
  for (const [i, id] of flow.slice(0, 2).entries()) {
    await d.click(entry('flow', id)).catch(() => {})
    const m = await seen(d, marked(id))
    ok(`2.${i + 1} entry ${id.slice(0, 8)} opens in its place, marked, not /t/`, m && notTopics(d), { url: path(d) + new URL(d.url()).search })
    ok(`2.${i + 1}b the Flow list stays, that entry selected`, await seen(d, list('flow'), 3000) && await selected(d, 'flow') === id)
    if (i === 0) await shots(d, '2-flow-open-desktop')
  }

  /* 3 keyboard */
  if (flowUp) {
    await d.focus(list('flow')).catch(() => {})
    const all = await ids(d, 'flow')
    const from = await selected(d, 'flow')
    await d.keyboard.press('ArrowDown')
    const next = await selected(d, 'flow')
    ok('3.1 ArrowDown selects the next entry', next && all.indexOf(next) === all.indexOf(from) + 1, { from: from.slice(0, 8), next: next.slice(0, 8) })
    await d.keyboard.press('Enter')
    if (flow.includes(next)) ok('3.2 Enter opens it in place, marked', Boolean(next) && await seen(d, marked(next)) && notTopics(d), path(d))
    else console.log(`  INFO 3.2 skipped: the next entry ${next.slice(0, 8)} has no place (opened ${path(d)})`)
    const kept = await d.waitForFunction((l) => Boolean(document.activeElement && document.activeElement.closest(l)), { timeout: 5000 }, ANY_LIST)
      .then(() => true).catch(() => false)
    ok('3.3 the keyboard stays on the list', kept)
  } else ok('3 keyboard: no Flow list', false)

  /* 4 Search, for a word taken from the first Flow entry */
  const q = flow[0] ? await wordOf(d, 'flow', flow[0]) : ''
  await d.goto(`${BASE}/search?q=${encodeURIComponent(q)}`, { waitUntil: 'domcontentloaded' })
  const searchUp = q && await seen(d, `${entries('search')}`, 60000)
  /* a MESSAGES hit: a Topics-group hit carries the topic key, not a msg id */
  const msgHits = searchUp ? await d.$$eval(`${entries('search')}[data-type=messages]`, (els) => els.map((e) => e.getAttribute('data-msg-id'))).catch(() => []) : []
  const hits = (searchUp ? await placed(d, 'search') : []).filter((id) => msgHits.includes(id))
  ok('4.1 Search: the hits are the left list', hits.length >= 1, { q, n: hits.length })
  await shots(d, '4-search-desktop')
  if (hits[0]) {
    await d.click(entry('search', hits[0])).catch(() => {})
    ok('4.2 a hit opens its original place, marked, not /t/', await seen(d, marked(hits[0])) && notTopics(d), path(d))
    ok('4.3 the query and the hits stay', await seen(d, entry('search', hits[0]), 3000) && await d.evaluate((qq) => document.body.innerText.includes(qq), q))
    await shots(d, '4-search-open-desktop')
  } else ok('4.2 no hit to open', false, { q })

  /* 5 links */
  const cold = await ctx.newPage()
  cold.on('pageerror', (e) => errors.push(String(e && e.message)))
  cold.setDefaultNavigationTimeout(90000)
  await cold.setViewport(DESKTOP)
  if (flow[1]) {
    await cold.goto(`${BASE}/m/${flow[1]}`, { waitUntil: 'domcontentloaded' })
    ok('5.1 a cold /m/<id> lands in place, marked', await seen(cold, marked(flow[1]), 60000) && notTopics(cold),
      { id: flow[1], landed: path(cold) + new URL(cold.url()).search })
  }
  await cold.goto(`${BASE}/m/${UNKNOWN}`, { waitUntil: 'domcontentloaded' })
  const reason = await cold.waitForSelector('[data-testid=open-msg-notice]', { visible: true, timeout: 60000 })
    .then((el) => el.evaluate((e) => e.getAttribute('data-reason'))).catch(() => '')
  ok('5.2 an unknown (or deleted) id: a clear notice', ['not_found', 'deleted'].includes(reason), { reason })
  await shots(cold, '5-notice-desktop')

  /* 6 phone */
  const m = await ctx.newPage()
  m.on('pageerror', (e) => errors.push(String(e && e.message)))
  m.setDefaultNavigationTimeout(90000)
  await m.setViewport(PHONE)
  await m.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
  const up = await openFlow(m, true)
  await m.waitForFunction((sel) => document.querySelectorAll(sel).length >= 3, { timeout: 60000 }, entries('flow')).catch(() => {})
  await sleep(2000)
  const full = up && await m.$eval(list('flow'), (el) => el.getBoundingClientRect().width >= window.innerWidth - 32)
  ok('6.1 phone: the Flow list is full screen', full)
  await shots(m, '6-flow-phone')
  const pid = up ? (await placed(m, 'flow'))[0] : ''
  if (pid) {
    await m.tap(entry('flow', pid)).catch(() => {})
    ok('6.2 phone: a tap opens the message in place, marked', await seen(m, marked(pid)) && notTopics(m), path(m))
    await shots(m, '6-flow-open-phone')
    const backed = await m.tap('[data-testid=mobile-back]').then(() => true).catch(() => false)
    if (!backed) await m.goBack().catch(() => {})
    ok('6.3 phone: ONE Back returns to the list, same entry selected',
      await seen(m, list('flow'), 15000) && await selected(m, 'flow') === pid, { backed, selected: (await selected(m, 'flow')).slice(0, 8) })
  } else ok('6.2 phone: no entry to tap', false)

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module|ResizeObserver/.test(e))
  ok('7 no page errors', mine.length === 0, mine.slice(0, 3))
} finally {
  await browser.close()
}
const failed = res.steps.filter((s) => !s.ok)
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
console.log(`flow-search-live ${BASE}: ${res.steps.length - failed.length}/${res.steps.length} PASS (${OUT})`)
process.exit(failed.length ? 1 : 0)
