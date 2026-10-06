// t1 58b8055d (HUM-24): open an archived topic from Archive, then close it.
// The reader must land back on Archive with the left rail still on screen
// — the channels / agents / messages icons — at both a desktop width and a
// phone width. Closing used to stay on /t/:id, which hides that rail and
// leaves the Topics list with no way back.
//
// Runs against the lde mock (no hub).
//
//   node tests/e2e/archive-close-rail.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/archive-close-rail.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH = 'archive-close-rail'
const WIDTHS = [
  { name: '1440', width: 1440, height: 900 },
  { name: '390', width: 390, height: 844 },
]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`

async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

/** Seed one own topic card and archive it from its menu. Returns its ids. */
async function seedArchived(p) {
  const seeded = await p.evaluate(async (CH) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    const ch = app.config.globalProperties.$pinia._s.get('channel')
    await ch.createChannel(CH).catch(() => {})
    await app.config.globalProperties.$router.push('/channel/' + CH)
    await new Promise((r) => setTimeout(r, 500))
    const m = await ch.send('58b8055d archived topic', undefined, undefined, undefined, 1)
    return { msg_id: m.msg_id, task_id: m.task_id }
  }, CH)
  await p.waitForSelector(midCard(seeded.msg_id), { timeout: 10000 })
  await sleep(300)
  const menu = await openMenu(p, midCard(seeded.msg_id))
  if (!menu.includes('msg-menu-archive')) return null
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  const gone = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.msg_id))
  return gone ? seeded : null
}

/** What a reader can see: painted, not display:none, not visibility:hidden. */
const seen = (p) => p.evaluate(() => {
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 8 && r.height > 8
  }
  const icon = (id) => vis(document.querySelector(`[data-testid=sidebar-tab-${id}]`))
  return {
    path: location.pathname,
    rail: vis(document.querySelector('[data-testid=sidebar-rail]')),
    channels: icon('channels'),
    messages: icon('dm'),
    agents: icon('agents'),
    archive: vis(document.querySelector('[data-test=archive-page]')),
    topic: vis(document.querySelector('[data-test=topic-section]')),
    browse: vis(document.querySelector('[data-test=topic-browse]')),
  }
})

/** The control the reader uses to leave the thread: the X, else the phone Back. */
async function closeThread(p) {
  return p.evaluate(() => {
    const vis = (e) => {
      if (!e) return false
      const r = e.getBoundingClientRect()
      const cs = getComputedStyle(e)
      return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
    }
    const x = [...document.querySelectorAll('[data-test=topic-pane-close], [data-test=live-topic-close]')].find(vis)
    if (x) { x.click(); return 'x' }
    const back = [...document.querySelectorAll('[data-test=topic-section] [data-testid=mobile-back], [data-test=topic-browse-thread] [data-testid=mobile-back]')].find(vis)
    if (back) { back.click(); return 'back' }
    return ''
  })
}

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of WIDTHS) {
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    /* Width only, until the document exists. isMobile on about:blank reports
       the 980 px layout width and the phone page never mounts the shell. */
    await p.setViewport({ width: vp.width, height: vp.height })
    try {
      await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
      await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      await applyViewport(p, vp)
    } catch (e) {
      ok(`${vp.name} the shell is up`, false, String(e).slice(0, 240))
      await p.close()
      continue
    }
    await sleep(500)

    const seeded = await seedArchived(p)
    ok(`${vp.name} archived a topic from its card`, Boolean(seeded), seeded)

    await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/archive'))
    const listed = seeded && await until(p, (id) => Boolean(document.querySelector(`[data-test=archive-row][data-msg-id="${id}"]`)), seeded.msg_id)
    ok(`${vp.name} Archive lists that topic`, listed)

    const before = await seen(p)
    ok(`${vp.name} Archive shows the rail`, before.rail && before.channels && before.messages && before.archive && !before.browse, before)

    await p.evaluate((id) => document.querySelector(`[data-test=archive-row][data-msg-id="${id}"] [data-test=archive-open]`)?.click(), seeded && seeded.msg_id)
    const opened = await until(p, () => {
      const e = document.querySelector('[data-test=topic-section]')
      if (!e) return false
      const r = e.getBoundingClientRect()
      const cs = getComputedStyle(e)
      return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 8 && r.height > 8
    })
    ok(`${vp.name} opening the row shows the thread`, opened, await seen(p))

    const how = await closeThread(p)
    const back = await until(p, () => {
      const vis = (e) => {
        if (!e) return false
        const r = e.getBoundingClientRect()
        const cs = getComputedStyle(e)
        return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 8 && r.height > 8
      }
      const topic = document.querySelector('[data-test=topic-section]')
      const topicOn = topic && vis(topic)
      const rail = vis(document.querySelector('[data-testid=sidebar-rail]'))
      const archive = vis(document.querySelector('[data-test=archive-page]'))
      const browse = vis(document.querySelector('[data-test=topic-browse]'))
      return !topicOn && rail && archive && !browse && location.pathname === '/archive'
    })
    const after = await seen(p)
    ok(`${vp.name} closing the thread returns to Archive with the rail`, how && back && after.rail && after.channels && after.messages && after.agents && after.archive && !after.topic && !after.browse && after.path === '/archive', { how, ...after })

    const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
    ok(`${vp.name} no unexpected page errors`, errors.filter((e) => !benign(e)).length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\narchive-close-rail: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
