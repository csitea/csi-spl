// Flow + Search acceptance (owner, t1 topic 635f8072, 2026-10-01): "one should
// be able to quickly browse through the flow entries and pick exactly the one
// which matches", and "the search should work exactly the same". The suite
// drives the owner's use case end to end on the mock tenant, through the hooks
// the three lanes agreed on (spool 635f8072), and nothing else:
//
//   /m/<msgId>                         opens a message in its original place
//   [data-msg-id].open-focus           the opened message, highlighted
//   [data-testid=open-msg-notice]      data-reason=deleted|not_found|no_access
//   [data-testid=left-list]            role=listbox, data-mode=flow|search
//   [data-testid=left-entry]           role=option, data-msg-id, aria-selected
//
// Desktop 1440 and phone 390, light and dark (shots only), keyboard, deep
// link, thread reply, DM, deleted message. A path under /t/ (the Topics view)
// is a FAIL wherever the message has a channel or DM of its own.
//
//   node tests/e2e/flow-search-acceptance.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/flow-search-acceptance.test.mjs
//   SHOTS=/var/tmp/fs-shots node tests/e2e/flow-search-acceptance.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || mkdtempSync(join(tmpdir(), 'spool-flow-search-'))
/* the mock tenant (utils/mock-data.mjs) */
const OWN_ROOT = '11111111-1111-4111-8111-111111111111' /* #lobby, HUM-1's own */
const ROOT = '22222222-2222-4222-8222-222222222222' /* #lobby topic root */
const REPLY = '33333333-3333-4333-8333-333333333333' /* reply in thread bbbbbbbb */
const THREAD = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const DM = '77777777-7777-4777-8777-777777777777' /* HUM-1 -> GRK-03 */
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a' /* GRK-03's reply in the DM's thread (CLE-77909) */
const UNKNOWN = '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f'
const Q = 'Applying'

const ANY_LIST = '[data-testid=left-list]'
/* Flow and Search lists can both be mounted (a warm panel is only hidden),
   and both can carry the same message: every lookup names the active mode. */
let MODE = 'flow'
const list = () => `${ANY_LIST}[data-mode=${MODE}]`
const entries = () => `${list()} [data-testid=left-entry]`
const entry = (id) => `${entries()}[data-msg-id="${id}"]`
/* the agreed mark: open-focus (lane A), or the older search-focus */
const focused = (id) => `[data-msg-id="${id}"]:is(.open-focus, .search-focus)`
const DESKTOP = { width: 1440, height: 900 }
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const seen = (p, sel, timeout = 10000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true).catch(() => false)
const path = (p) => new URL(p.url()).pathname
const notTopics = (p) => !/\/t(\/|$)/.test(path(p))

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
        defaultViewport: DESKTOP,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** A page signed in as the mock admin (specs/054: the mock is signed-out by default). */
async function page(browser, vp, errors) {
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.setViewport(vp)
  /* on every document, before the app boots: this suite never signs out */
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    } catch { /* a data: frame has no storage */ }
  })
  return p
}

/** Client-side navigation, as an in-app link would do it (keeps the SPA state). */
const push = (p, to) => p.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), to)

async function shots(p, name) {
  for (const theme of ['light', 'dark']) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await p.screenshot({ path: `${SHOTS}/${name}-${theme}.png` })
  }
  await p.evaluate(() => document.documentElement.removeAttribute('data-theme'))
}

const selectedId = (p) => p.$eval(`${entries()}[aria-selected=true]`, (el) => el.getAttribute('data-msg-id')).catch(() => '')
const entryIds = (p) => p.$$eval(entries(), (els) => els.map((e) => e.getAttribute('data-msg-id')))
const inFeedView = (p, id) => p.$eval(focused(id), (el) => {
  const r = el.getBoundingClientRect()
  const s = (el.closest('.feed-body') || document.documentElement).getBoundingClientRect()
  return r.bottom > s.top && r.top < s.bottom
}).catch(() => false)

/** Open the Flow rail tab. A click before hydration is lost (or the tab is
 *  not rendered yet), so retry until the Flow list answers. */
async function openFlow(p, { tap = false } = {}) {
  const tab = '[data-testid=sidebar-tab-flow]'
  for (let i = 0; i < 6; i++) {
    if (await seen(p, `${ANY_LIST}[data-mode=flow]`, i ? 2000 : 500)) return true
    await p.waitForSelector(tab, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
    await (tap ? p.tap(tab) : p.click(tab)).catch(() => {})
  }
  return seen(p, `${ANY_LIST}[data-mode=flow]`, 2000)
}

/** Click (desktop) or tap (phone) one entry, then wait for the place to show it. */
async function pick(p, id, { tap = false } = {}) {
  if (tap) await p.tap(entry(id))
  else await p.click(entry(id))
  return seen(p, focused(id))
}

const server = await startServer()
const browser = await launch()
mkdirSync(SHOTS, { recursive: true })
const errors = []
try {
  /* ---------- 1 Flow, desktop ---------- */
  const d = await page(browser, DESKTOP, errors)
  await d.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const flowUp = await openFlow(d)
  ok('1.1 Flow: the left-most panel is the entry list (listbox, data-mode=flow)', flowUp)
  await shots(d, '1-flow-desktop')
  const flowIds = flowUp ? await entryIds(d) : []
  ok('1.2 Flow: entries are messages, each with its msg id', flowIds.length >= 3 && flowIds.every(Boolean), flowIds)
  const agentList = await d.$$eval('[data-testid=sidebar-panel-flow] a.nav-item[data-kind]', (els) => els.length).catch(() => 0)
  ok('1.3 Flow: no agent / channel LIST rows any more', agentList === 0, { rows: agentList })
  ok('1.4 Flow: the agent DM appears as a message entry', flowIds.includes(DM))
  ok('1.5 Flow: the compact row shows who + short text + time', await d.$eval(entry(ROOT), (el) => {
    const t = el.textContent || ''
    return /Review the spool WUI scaffold/.test(t) && el.getBoundingClientRect().height <= 96
  }).catch(() => false))

  /* 2 pick an entry: the message opens IN ITS PLACE, the list stays */
  ok('2.1 click a channel entry: #lobby opens with the message highlighted', flowUp && await pick(d, ROOT) && path(d).endsWith('/channel/lobby'), d.url())
  ok('2.2 the message is scrolled into its feed', await inFeedView(d, ROOT))
  ok('2.3 the Flow list stays, the entry is the selected one', await seen(d, `${ANY_LIST}[data-mode=flow]`, 2000) && await selectedId(d) === ROOT)
  ok('2.4 not the Topics view', notTopics(d), path(d))
  await shots(d, '2-flow-open-channel-desktop')
  ok('2.5 click a thread reply: its thread opens on the right, the reply highlighted',
    flowUp && await pick(d, REPLY) && await seen(d, `aside.live-pane ${focused(REPLY)}`, 3000) && new URL(d.url()).searchParams.get('topic') === THREAD,
    d.url())
  ok('2.6 ... still in #lobby, the list still there', path(d).endsWith('/channel/lobby') && await seen(d, list(), 2000))
  await shots(d, '2-flow-open-reply-desktop')
  ok('2.7 click the DM entry: the DM opens with the message highlighted',
    flowUp && await pick(d, DM) && /\/dm\//.test(path(d)) && notTopics(d), d.url())
  await shots(d, '2-flow-open-dm-desktop')

  /* 3 keyboard: up/down cycle, Enter opens */
  if (flowUp) {
    await d.focus(list()).catch(() => {})
    const ids = await entryIds(d)
    const from = await selectedId(d)
    await d.keyboard.press('ArrowDown')
    const down = await selectedId(d)
    ok('3.1 ArrowDown moves the selection to the next entry', ids.indexOf(down) === ids.indexOf(from) + 1 || (from === '' && down === ids[0]), { from, down })
    await d.keyboard.press('ArrowUp')
    const up = await selectedId(d)
    ok('3.2 ArrowUp moves it back', from === '' ? up === ids[0] : up === from, { from, up })
    await d.keyboard.press('ArrowDown')
    const target = await selectedId(d)
    await d.keyboard.press('Enter')
    ok('3.3 Enter opens the selected entry in place', Boolean(target) && await seen(d, focused(target)) && notTopics(d), { target, url: d.url() })
    ok('3.4 the focus stays on the list, so the next ArrowDown keeps cycling',
      await d.evaluate((l) => Boolean(document.activeElement && document.activeElement.closest(l)), list()))
  } else ok('3 keyboard: no Flow list to drive', false)

  /* ---------- 4 Search, desktop ---------- */
  await d.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  MODE = 'search'
  const searchUp = await seen(d, `${ANY_LIST}[data-mode=search]`, NAV_TIMEOUT)
  ok('4.1 Search: the results are the left-most list (data-mode=search), not the middle', searchUp)
  await shots(d, '4-search-desktop')
  ok('4.2 a hit opens its original place: the #lobby thread, the reply highlighted, not Topics',
    searchUp && await pick(d, REPLY) && path(d).endsWith('/channel/lobby') && notTopics(d), d.url())
  /* the query may live in an input, the omnibox, or the list's own header */
  const kept = await d.evaluate((list, q) => {
    const inField = [...document.querySelectorAll('input, textarea')].some((el) => String(el.value || '').includes(q))
    const l = document.querySelector(list)
    const onList = Boolean(l && ((l.closest('[data-query]') && l.closest('[data-query]').getAttribute('data-query') === q) || (l.parentElement && l.parentElement.textContent.includes(q))))
    return inField || onList ? q : ''
  }, list(), Q).catch(() => '')
  ok('4.3 the query and the results stay while you click through', kept === Q && await seen(d, `${ANY_LIST}[data-mode=search] [data-testid=left-entry][data-msg-id="${REPLY}"]`, 2000), { kept })
  await shots(d, '4-search-open-desktop')
  if (searchUp) {
    await d.focus(list()).catch(() => {})
    const before = await selectedId(d)
    await d.keyboard.press('ArrowDown')
    const next = await selectedId(d)
    await d.keyboard.press('Enter')
    ok('4.4 keyboard cycles the results and Enter opens one', Boolean(next) && (next !== before || (await entryIds(d)).length === 1) && await seen(d, focused(next)), { before, next })
  } else ok('4.4 keyboard: no Search list to drive', false)

  /* ---------- 5 deep link + deleted ---------- */
  const cold = await page(browser, DESKTOP, errors)
  await cold.goto(server.base + '/m/' + REPLY, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('5.1 cold deep link /m/<reply> lands in the #lobby thread, highlighted',
    await seen(cold, `aside.live-pane ${focused(REPLY)}`, NAV_TIMEOUT) && path(cold).endsWith('/channel/lobby'), cold.url())
  await cold.goto(server.base + '/m/' + UNKNOWN, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const reason = await cold.waitForSelector('[data-testid=open-msg-notice]', { visible: true, timeout: NAV_TIMEOUT })
    .then((el) => el.evaluate((e) => e.getAttribute('data-reason'))).catch(() => '')
  ok('5.2 an unknown id: a clear notice, no blank page', ['not_found', 'deleted'].includes(reason), { reason })
  await shots(cold, '5-notice-desktop')
  /* delete our own #lobby message, then follow its link in the same session */
  await cold.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await seen(cold, `article.msg[data-msg-id="${OWN_ROOT}"] [data-testid=msg-menu-btn]`, NAV_TIMEOUT)
  const del = await cold.evaluate(async (id) => {
    const btn = document.querySelector(`article.msg[data-msg-id="${id}"] [data-testid=msg-menu-btn]`)
    if (!btn) return 'no-menu'
    btn.click()
    await new Promise((r) => setTimeout(r, 300))
    /* a topic card offers "Delete topic", a thread line plain "Delete" */
    const item = document.querySelector('[data-testid=msg-menu-delete], [data-testid=msg-menu-delete-topic]')
    if (!item) return 'no-delete'
    item.click()
    await new Promise((r) => setTimeout(r, 300))
    const confirm = document.querySelector('[data-testid=msg-delete-confirm], [data-testid=topic-delete-confirm]')
    if (!confirm) return 'no-confirm'
    confirm.click()
    return 'ok'
  }, OWN_ROOT)
  await new Promise((r) => setTimeout(r, 800))
  await push(cold, '/m/' + OWN_ROOT).catch(() => {})
  const gone = await cold.waitForSelector('[data-testid=open-msg-notice]', { visible: true, timeout: 10000 })
    .then((el) => el.evaluate((e) => e.getAttribute('data-reason'))).catch(() => '')
  ok('5.3 a deleted message: the notice says so (deleted, or not_found)', del === 'ok' && ['deleted', 'not_found'].includes(gone), { del, gone })
  /* CLE-77909 (dev red, lane D): a cold link to a reply in a DM thread opened the Topics view */
  const coldDm = await page(browser, DESKTOP, errors)
  await coldDm.goto(server.base + '/m/' + DM_REPLY, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('5.4 cold deep link /m/<DM reply> lands in the DM, thread open, highlighted - never /t/',
    await seen(coldDm, focused(DM_REPLY), NAV_TIMEOUT) && /\/dm\//.test(path(coldDm)) && notTopics(coldDm), coldDm.url())
  await coldDm.close().catch(() => {})
  const coldDmPhone = await page(browser, PHONE, errors)
  await coldDmPhone.goto(server.base + '/m/' + DM_REPLY, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const phoneLanded = await seen(coldDmPhone, focused(DM_REPLY), NAV_TIMEOUT) && /\/dm\//.test(path(coldDmPhone)) && notTopics(coldDmPhone)
  const phoneAt = coldDmPhone.url()
  await shots(coldDmPhone, '5-dm-reply-phone')
  /* the thread is one phone level over the DM (as for a #lobby reply): one Back is the DM, never /m/ or /t/ */
  await coldDmPhone.goBack({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => {})
  await new Promise((r) => setTimeout(r, 500))
  ok('5.5 phone: the same cold link lands in the DM thread, highlighted; one Back is the DM - never /m/ or /t/',
    phoneLanded && /\/dm\//.test(path(coldDmPhone)) && notTopics(coldDmPhone), { at: phoneAt, back: coldDmPhone.url() })
  await coldDmPhone.close().catch(() => {})

  /* ---------- 6 phone ---------- */
  for (const mode of ['flow', 'search']) {
    MODE = mode
    const m = await page(browser, PHONE, errors)
    /* the list scrolls inside the sidebar's own scroller, not by itself */
    await m.evaluateOnNewDocument(() => { window.scroller = (el) => el.closest('.sidebar-scroll') || el })
    if (mode === 'flow') {
      /* the section strip shows only at mobile level 1 (the list), not in a feed */
      await m.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      /* a tap before hydration is lost: tap until the Flow list answers */
      await openFlow(m, { tap: true })
    } else {
      await m.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    }
    const up = await seen(m, `${ANY_LIST}[data-mode=${mode}]`, NAV_TIMEOUT)
    const full = up && await m.$eval(list(), (el) => el.getBoundingClientRect().width >= window.innerWidth - 32)
    ok(`6.${mode} 1 phone: the ${mode} list is full screen`, full)
    await shots(m, `6-${mode}-phone`)
    const id = mode === 'flow' ? ROOT : REPLY
    const top = up ? await m.$eval(list(), (el) => { const s = scroller(el); s.scrollTop = s.scrollHeight; return s.scrollTop }) : -1
    await m.$eval(entry(id), (el) => el.scrollIntoView({ block: 'nearest' })).catch(() => {})
    const scrollAt = up ? await m.$eval(list(), (el) => scroller(el).scrollTop) : -1
    ok(`6.${mode} 2 phone: a tap opens the original place, highlighted`, up && await pick(m, id, { tap: true }) && notTopics(m), m.url())
    await shots(m, `6-${mode}-open-phone`)
    /* the visible Back button, else the browser's Back */
    const backed = await m.tap('[data-testid=mobile-back]').then(() => true).catch(() => false)
    if (!backed) await m.goBack().catch(() => {})
    const again = await seen(m, `${ANY_LIST}[data-mode=${mode}]`, 10000)
    const now = again ? await m.$eval(list(), (el) => scroller(el).scrollTop) : -2
    ok(`6.${mode} 3 phone: Back returns to the list, same scroll, same entry selected`,
      again && Math.abs(now - scrollAt) <= 4 && await selectedId(m) === id, { top, scrollAt, now, selected: await selectedId(m) })
  }

  console.log(`  screenshots ${SHOTS}`)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('7 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`flow-search-acceptance: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
