// CLE-77908 (owner, t1 b23639e2 + 07b84fd7): "why the times of the sent seem so
// off" / "off by 3hours". In a real browser (mock tenant, desktop 1440):
//
//   1  the desktop topic pane clock (`yyyy-mm-dd HH:MM:SS sent 7s`) prints the
//      browser's zone: Chrome in Europe/Helsinki and in UTC read the same
//      instant 3 h apart (it printed UTC before)
//   2  the message list row prints the same local wall time
//   3  an ISO time with Z inside a body reads local, its hover keeps the text
//      as written; a bare 18:46 in the same body stays as written (CONTROL)
//   4  a picked zone (Settings -> Appearance, per workspace) wins over the
//      browser's at once, without a reload, and clearing it returns
//   5  Settings -> Appearance shows the zone picker with the browser's zone first
//
//   node tests/e2e/local-time.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/local-time.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const pinia = 'document.querySelector("#__nuxt").__vue_app__.config.globalProperties.$pinia'

/* the instant: a minute ago, whole seconds, so it is the newest row */
const AT = new Date(Math.floor((Date.now() - 60e3) / 1000) * 1000)
const ISO = AT.toISOString().replace(/\.\d+Z$/, 'Z')
const BODY_ISO = '2026-10-01T18:46:26Z'
/** `yyyy-mm-dd HH:MM:SS` of `d` in `zone` (the expectation, computed apart from the WUI). */
function wall(d, zone) {
  const p = {}
  for (const x of new Intl.DateTimeFormat('en-US', { timeZone: zone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(d)) p[x.type] = x.value
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`
}

const signIn = (p, tz) => p.evaluate((tz) => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (tz) c.time_zone = tz
  session.adopt(c)
  return true
}, tz)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

async function inject(p, id) {
  await p.evaluate((id, ts, bodyIso) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-main')
    s.messages = [...s.messages, { v: 1, msg_id: id, task_id: 't-' + id, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: `done at ${bodyIso}, heartbeat 18:46 ${id}`, files: [] }]
  }, id, ISO, BODY_ISO)
}

/** What the page shows for row `id`: the list clock, the body time, the bare text. */
const rowView = (p, id) => p.evaluate((id) => {
  const row = document.querySelector(`.live-rows > article.msg[data-msg-id="${id}"]`)
  const bt = row?.querySelector('[data-test=body-time]')
  return {
    found: !!row,
    list: row?.querySelector('.msg-time')?.textContent?.trim() || '',
    body: bt?.textContent?.trim() || '',
    bodyTitle: bt?.getAttribute('title') || '',
    bare: /heartbeat 18:46/.test(row?.textContent || ''),
  }
}, id)

/** The open topic pane's clock (the line with ` sent `). */
const paneClock = (p) => p.evaluate((iso) => {
  const row = [...document.querySelectorAll('[data-pane="topic"] article.msg')].find((r) => r.getAttribute('data-ts') === iso)
  const el = row?.querySelector('.msg-time')
  return el ? el.textContent.trim() : ''
}, ISO)

async function run(browser, base, zone) {
  const p = await browser.newPage()
  await p.emulateTimezone(zone)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })
  const id = `tz-${zone.replace(/\W/g, '')}-${Date.now()}`
  await inject(p, id)
  await p.waitForSelector(`.live-rows > article.msg[data-msg-id="${id}"]`, { timeout: 15000 })
  const want = wall(AT, zone)
  const wantBody = wall(new Date(BODY_ISO), zone)

  let v = await rowView(p, id)
  check(`${zone} 2 list row: ${want.slice(0, 16)}`, v.list === want.slice(0, 16), v)
  check(`${zone} 3 body ISO time reads local, hover keeps it as written`, v.body === wantBody && v.bodyTitle === BODY_ISO, v)
  check(`${zone} 3 CONTROL a bare 18:46 stays as written`, v.bare, v)

  /* open the topic pane (a click on the row), let its own read land, then a
     reply at the same instant arrives as a live frame would */
  await p.evaluate((id) => document.querySelector(`.live-rows > article.msg[data-msg-id="${id}"]`)?.click(), id)
  await p.waitForSelector('[data-pane="topic"] .feed-body', { timeout: 15000 })
  await p.waitForFunction(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-pane')
    return s && s.taskId && !s.loading
  }, { timeout: 15000 })
  await sleep(800)
  await p.evaluate((ts) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-pane')
    s.messages = [...s.messages, { v: 1, msg_id: 'tz-reply-' + Date.now(), task_id: s.taskId, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: 'reply', files: [] }]
  }, ISO)
  await p.waitForFunction(() => [...document.querySelectorAll('.msg-time')].some((e) => / sent /.test(e.textContent || '')), { timeout: 15000 }).catch(() => null)
  const pane = await paneClock(p)
  check(`${zone} 1 topic pane: "${want} sent ..."`, pane.startsWith(want + ' sent '), { pane, want })

  /* 4: the person picks a zone in this workspace: it wins, live */
  const other = zone === 'UTC' ? 'Europe/Helsinki' : 'UTC'
  await p.evaluate(`${pinia}._s.get('session').setTimeZone('${other}')`)
  await sleep(400)
  const picked = await paneClock(p)
  check(`${zone} 4 picked ${other}: the open pane re-renders to ${wall(AT, other)}`, picked.startsWith(wall(AT, other) + ' sent '), { picked })
  await p.evaluate(`${pinia}._s.get('session').setTimeZone(null)`)
  await sleep(400)
  const cleared = await paneClock(p)
  check(`${zone} 4 cleared: back to the browser's zone`, cleared.startsWith(want + ' sent '), { cleared })

  /* 5: the picker */
  await go(p, '/settings/appearance')
  const sel = await p.waitForSelector('[data-test=time-zone-select]', { timeout: 15000 }).catch(() => null)
  const first = sel ? await p.$eval('[data-test=time-zone-select] option', (o) => o.textContent || '') : ''
  const n = sel ? await p.$$eval('[data-test=time-zone-select] option', (os) => os.length) : 0
  check(`${zone} 5 Settings -> Appearance: the browser's zone first, then the IANA list`, first.includes(zone) && n > 50, { first, n })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const zone of ['Europe/Helsinki', 'UTC']) await run(browser, server.base, zone)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nlocal-time: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
