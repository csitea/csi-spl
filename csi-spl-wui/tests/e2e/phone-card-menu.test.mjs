// t1 7a6be5a3 (owner, HUM-10): "move the whole archive option two or three
// positions up in the menu because it's the most used one ... Fix, of course,
// the actual bug of the menu not appearing whole and one having to slide it up."
//
// On a phone the card's ⋯ menu is a bottom sheet. Opened on the LAST card of a
// channel, at 390x844 and at a short 390x664, every entry must sit inside the
// visual viewport and be the element a finger lands on (nothing under the
// composer dock, no scroll inside the sheet), and Archive must sit two or three
// places higher than its old spot (it was after Move / Merge, right before
// Delete; now right after Edit).
//
//   1  own topic card (the longest menu): every entry whole, Archive moved up
//   2  someone else's card (locked entries carry a reason line: the tallest)
//
// Run:
//   node tests/e2e/phone-card-menu.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/phone-card-menu.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CH = 'phone-card-menu'
const OTHER = '66666666-6666-4666-8666-666666666666' // #alerts card by GRK-03 (mock-data)
const SIZES = [{ width: 390, height: 844 }, { width: 390, height: 664 }]
if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

/** Open the LAST middle card's ⋯ menu (the sheet) and wait for its entries. */
async function openLastMenu(p) {
  for (let i = 0; i < 2; i++) {
    await p.evaluate(() => {
      const cards = [...document.querySelectorAll('.spool-main article.msg')]
      const last = cards[cards.length - 1]
      last?.scrollIntoView({ block: 'end' })
      last?.querySelector('[data-testid=msg-menu-btn]')?.click()
    })
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const n = await p.evaluate(() => document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]').length)
      if (n) {
        await sleep(400) /* the sheet's slide-up animation */
        return true
      }
    }
  }
  return false
}

/** Each entry: inside the visual viewport, and the thing a finger at its centre hits. */
const measure = (p) => p.evaluate(() => {
  /* nuxi dev's devtools pill floats over the page bottom; a generated bundle has none */
  for (const e of document.querySelectorAll('[id^=nuxt-devtools]')) e.style.display = 'none'
  const vv = window.visualViewport
  const top = vv ? vv.offsetTop : 0
  const bottom = vv ? vv.offsetTop + vv.height : window.innerHeight
  const sheet = document.querySelector('[data-testid=msg-menu]')
  const items = [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => {
    const r = e.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    return {
      id: e.getAttribute('data-testid').replace(/^msg-menu-/, ''),
      top: Math.round(r.top),
      bottom: Math.round(r.bottom),
      inside: r.top >= top - 0.5 && r.bottom <= bottom + 0.5 && r.height > 0,
      reachable: Boolean(hit && e.contains(hit)),
    }
  })
  return {
    vh: Math.round(bottom - top),
    scrolls: sheet ? sheet.scrollHeight - sheet.clientHeight > 1 : null,
    sheetBottom: sheet ? Math.round(sheet.getBoundingClientRect().bottom) : null,
    items,
  }
})

async function signIn(p, base) {
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', 'everyone')
    localStorage.setItem('spool.mock.role', 'developer')
  })
}

/** Seed a channel whose LAST card is the viewer's own topic, show it. */
const seed = (p) => p.evaluate(async ({ CH }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH)
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  /* the feed is newest first: the OLDER topic is the bottom (last) card */
  const last = await ch.send('phone card menu: my own topic, the last card', undefined, undefined, undefined, 1)
  await ch.send('phone card menu: a newer topic', undefined, undefined, undefined, 1)
  return last.msg_id
}, { CH })

function check(tag, m, { archiveMax }) {
  const ids = m.items.map((i) => i.id)
  const out = m.items.filter((i) => !i.inside).map((i) => `${i.id}@${i.top}-${i.bottom}`)
  const hidden = m.items.filter((i) => !i.reachable).map((i) => i.id)
  ok(`${tag}: every entry inside the visual viewport (${m.vh}px)`, ids.length > 0 && out.length === 0, { out, ids })
  ok(`${tag}: every entry is what a finger at its centre hits (no dock over it)`, ids.length > 0 && hidden.length === 0, { hidden })
  ok(`${tag}: no scrolling inside the sheet to reach an entry`, m.scrolls === false, { scrolls: m.scrolls })
  const ai = ids.indexOf('archive')
  ok(`${tag}: Archive at index <= ${archiveMax} (moved up)`, ai >= 0 && ai <= archiveMax, { ai, ids })
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  /* warm a throwaway page: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  for (const vp of SIZES) {
    const tag = `${vp.width}x${vp.height}`
    await p.setViewport({ ...vp, isMobile: true, hasTouch: true })
    await signIn(p, srv.base)

    /* ---- 1. own topic, the last card: the longest menu ------------------- */
    await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(800)
    const own = await seed(p)
    await p.waitForSelector(`.spool-main article.msg[data-msg-id="${own}"]`, { timeout: 10000 })
    await sleep(400)
    const lastIsOwn = await p.evaluate((id) => {
      const cards = [...document.querySelectorAll('.spool-main article.msg')]
      return cards[cards.length - 1]?.getAttribute('data-msg-id') === id
    }, own)
    ok(`${tag} 1 the seeded own topic is the last card`, lastIsOwn)
    ok(`${tag} 1 the menu opens`, await openLastMenu(p))
    const m1 = await measure(p)
    if (OUT) await p.screenshot({ path: `${OUT}/${tag}-1-own.png` })
    /* old order: reply react open copy-text copy edit kind move-channel merge-topic archive(9) delete-topic */
    check(`${tag} 1 own`, m1, { archiveMax: 6 })
    ok(`${tag} 1 own: Delete stays last`, m1.items.at(-1)?.id === 'delete-topic', m1.items.map((i) => i.id))
    await p.keyboard.press('Escape')
    await sleep(300)

    /* ---- 2. someone else's card: locked entries carry their reason ------- */
    await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
    await p.waitForSelector(`.spool-main article.msg[data-msg-id="${OTHER}"]`, { timeout: NAV_TIMEOUT })
    await sleep(800)
    await p.evaluate((id) => {
      /* make GRK-03's card the last one on screen */
      const card = document.querySelector(`.spool-main article.msg[data-msg-id="${id}"]`)
      const cards = [...document.querySelectorAll('.spool-main article.msg')]
      for (const c of cards) if (c !== card) c.remove()
    }, OTHER)
    ok(`${tag} 2 the menu opens`, await openLastMenu(p))
    const m2 = await measure(p)
    if (OUT) await p.screenshot({ path: `${OUT}/${tag}-2-other.png` })
    check(`${tag} 2 other`, m2, { archiveMax: 6 })
    await p.keyboard.press('Escape')
    await sleep(300)
  }

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-card-menu: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
