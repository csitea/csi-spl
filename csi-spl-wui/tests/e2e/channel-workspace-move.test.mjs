// Spec 169 row T19, case C35's browser half: the "Move to workspace" dialog
// of a channel row's menu, on the mock bundle, at 1280x800 and on a 390 px
// phone. The mock answers the hub's routes (T14 plan, T15 confirm, T17
// status) only from the fixture this test writes (spool.mock.channel_move,
// src/utils/channel-workspace-move.mjs); without it nobody is offered a move.
//
// Per viewport:
//   1. the row menu offers Move to workspace once the probe answered allowed;
//   2. plan screen: the target, the counts, a keep checkbox per person who
//      loses access;
//   3. blocked screen: each .blocked line with what clears it; an hours stop
//      has "leave these rows", and with it ticked the re-check clears it;
//   4. confirm screen: the people who lose access, no undo, one button; the
//      click sends the person's GO (the confirm body: dst, keep, leave_hours);
//   5. the stuck table: desktop reads T17's answer (not_moved and its
//      reason); the phone's read answers 404 unknown_move, as T17's route does
//      from <SRC>'s page today, and the dialog says the status cannot be read
//      here and links the GO's topic (spec 169 9.x, open item T17b).
//
// Run:
//   BASE_URL=<generated mock bundle> node tests/e2e/channel-workspace-move.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = 'spl-6730-move'
const MOVE_ID = '6f0c2a9e-3b1d-4c55-9e7a-1d2b3c4d5e6f'
const TOPIC = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d'
const REASON = 'seat c-401 on boxa has no desk in beta (W2)'
const HOURS = 'hours: HUM-7 2 rows not coming to beta (Q5)'

const fixture = (status) => ({
  targets: [{ slug: 'beta', name: 'Beta' }],
  plan: {
    counts: { messages: 12, channels: 1, issues: 2 },
    seats: [],
    mentions: [{ line: 'a post in #lobby links a moved topic' }],
    members_lost: ['HUM-2'],
    kept: [{ store: 'hub logs', gone_by: "the log bucket's retention" }],
    refuse: [HOURS],
    shared_files: [],
    blocked: [HOURS],
  },
  confirm: { move_id: MOVE_ID, topic: TOPIC },
  ...(status ? { status } : {}),
})

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Click the first VISIBLE match (a phone keeps hidden copies of some panes). */
const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)
const shown = (p, sel, timeout = 8000) => p.waitForSelector(sel, { visible: true, timeout }).then(Boolean).catch(() => false)
const text = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''
}, sel)
const screenIs = (p, name) => p.waitForFunction((n) => document.querySelector('[data-testid=channel-move]')?.getAttribute('data-screen') === n,
  { timeout: 8000 }, name).then(() => true).catch(() => false)

async function openPage(browser, srv, vp, status) {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport(vp)
  await page.evaluateOnNewDocument((f) => {
    try { localStorage.setItem('spool.mock.channel_move', f) } catch { /* private mode */ }
  }, JSON.stringify(fixture(status)))
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return page
}

async function makeChannel(page) {
  return page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const row = await ch.createChannel(name)
    return String(row?.channel_id || '')
  }, CHANNEL)
}

/** Steps 1 to 4: the menu item, the plan, the blocked screen, the confirm. */
async function throughConfirm(page, at) {
  const id = await makeChannel(page)
  ok(`${at}: a channel to move is created`, Boolean(id), { id })
  await click(page, '[data-testid=sidebar-tab-channels]')
  const row = `[data-testid=sidebar-row-menu][data-menu-id="ch:${id}"]`
  await shown(page, row)
  await click(page, row)
  const item = await shown(page, '[data-testid=sidebar-row-menu-move-workspace]')
  ok(`${at}: the row menu offers Move to workspace after the probe`, item)
  await click(page, '[data-testid=sidebar-row-menu-move-workspace]')
  ok(`${at}: the dialog opens on the plan screen`, await screenIs(page, 'plan'))
  const target = await page.evaluate(() => document.querySelector('[data-testid=channel-move-target]')?.value || '')
  ok(`${at}: the one target is picked`, target === 'beta', { target })
  ok(`${at}: the plan shows the counts in words`, await shown(page, '[data-testid=channel-move-counts]') &&
    (await text(page, '[data-testid=channel-move-counts]')).includes('messages'), await text(page, '[data-testid=channel-move]'))
  ok(`${at}: a person who loses access has a keep checkbox`, await shown(page, '[data-testid=channel-move-keep]'))
  await click(page, '[data-testid=channel-move-keep]')
  await click(page, '[data-testid=channel-move-next]')
  ok(`${at}: a blocked plan shows the blocked screen, not the confirm`, await screenIs(page, 'blocked'))
  const stop = await page.evaluate(() => [...document.querySelectorAll('[data-testid=channel-move-stop]')].map((e) => e.getAttribute('data-kind')))
  ok(`${at}: the hours stop is listed with what clears it`, stop.length === 1 && stop[0] === 'hours', { stop })
  await click(page, '[data-testid=channel-move-leave]')
  await click(page, '[data-testid=channel-move-recheck]')
  ok(`${at}: leaving the hours rows clears the stop: the confirm screen`, await screenIs(page, 'confirm'))
  const go = await page.evaluate(() => {
    const b = document.querySelector('[data-testid=channel-move-go]')
    return b ? { disabled: b.disabled, w: b.getBoundingClientRect().width } : null
  })
  ok(`${at}: one enabled confirm button`, Boolean(go && !go.disabled && go.w > 0), go)
  ok(`${at}: a kept person is not listed as losing access`, !(await page.$('[data-testid=channel-move-confirm-lost]')))
  ok(`${at}: the confirm says it cannot be undone`, (await text(page, '[data-testid=channel-move-confirm] .cwm__warn')).includes('cannot be undone'))
  await click(page, '[data-testid=channel-move-go]')
  ok(`${at}: the click opens the status`, await screenIs(page, 'status'))
  const sent = await page.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.channel_move.sent') || 'null'))
  ok(`${at}: the confirm sent the person's GO with the picks`,
    JSON.stringify(sent) === JSON.stringify({ dst: 'beta', keep: ['HUM-2'], keep_emails: [], leave_hours: ['HUM-7'] }), sent)
}

async function noXScroll(page, at) {
  const m = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, vw: innerWidth }))
  ok(`${at}: no page x-scroll with the dialog open`, m.sw <= m.vw, m)
}

const srv = await startServer()
const browser = await launch()
try {
  /* desktop: T17's answer, a refused P2 */
  const desk = await openPage(browser, srv, { width: 1280, height: 800 }, { state: 'not_moved', stuck: false, reason: REASON, src: 'alpha', dst: 'beta' })
  await throughConfirm(desk, '1280')
  ok('1280: the stuck table shows the not_moved row', await shown(desk, '[data-testid=channel-move-status][data-state=not_moved]'))
  ok("1280: the stuck table shows T17's reason", (await text(desk, '[data-testid=channel-move-reason]')) === REASON, await text(desk, '[data-testid=channel-move-reason]'))
  ok('1280: nothing reads as moved', !(await desk.$('[data-testid=channel-move-link]')))
  await noXScroll(desk, '1280')
  await desk.close()

  /* phone: the status read answers 404, as T17's route does from <SRC>'s page */
  const phone = await openPage(browser, srv, { width: 390, height: 844, isMobile: true, hasTouch: true }, null)
  await throughConfirm(phone, '390')
  ok('390: a 404 status says it cannot be read here', await shown(phone, '[data-testid=channel-move-status-gone]'))
  const href = await phone.evaluate(() => document.querySelector('[data-testid=channel-move-topic]')?.getAttribute('href') || '')
  ok("390: and links the GO's topic", href.endsWith(`/t/${TOPIC}`), { href })
  const full = await phone.evaluate(() => {
    const d = document.querySelector('[data-testid=ui-dialog]')?.getBoundingClientRect()
    return d ? { w: Math.round(d.width), vw: innerWidth } : null
  })
  ok('390: the dialog is full width on the phone', Boolean(full && full.w === full.vw), full)
  await noXScroll(phone, '390')
  await phone.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-workspace-move: ${results.length - failed.length}/${results.length} ok`)
process.exit(failed.length ? 1 : 0)
