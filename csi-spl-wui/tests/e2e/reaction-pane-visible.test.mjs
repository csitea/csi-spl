// CLE-77840 (owner, t1 topic d837af50): "the icon gets set on the thread card
// of the first msg, but not as before also on the topic level pane next to
// the emoji setting icon" - and "the new behaviour should be preserved, but
// the old behaviour restored". The chip WAS in the topic pane's DOM, but the
// card header is one non-wrapping line (51007d2a) whose time ("2026-09-27
// 11:16:01 sent 94h 23m") never shrank, so in a narrow pane the smile button
// and the chips after it ran past the pane's edge and were clipped (measured
// on dev: pane right 1440, chip 1450..1487).
//
// Runs against the lde mock. Desktop 1440x900, a topic open in the right pane:
//   1  react on the topic's card in the MIDDLE list: its chip shows there (new)
//   2  ... and on the same message in the TOPIC PANE (old), inside the pane
//   3  the pane's smile button is inside the pane too
//   4  the same at a narrow pane (280 px) and a long time label
//
// Run:
//   node tests/e2e/reaction-pane-visible.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/reaction-pane-visible.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77840-react'

if (OUT) mkdirSync(OUT, { recursive: true })

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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const paneRow = (id) => `.topic article.msg[data-msg-id="${id}"]`

/** Where the pane row's smile button and chips sit, against the pane's box. */
const paneGeo = (p, id) => p.evaluate((sel) => {
  const row = document.querySelector(sel)
  const pane = row?.closest('.topic')
  if (!row || !pane) return null
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: Math.round(r.left), r: Math.round(r.right) } }
  const P = box(pane)
  const inside = (e) => { const b = box(e); return b.l >= P.l - 1 && b.r <= P.r + 1 }
  const btn = row.querySelector('[data-testid=msg-emoji-btn]')
  const chips = [...row.querySelectorAll('[data-testid=msg-reaction]')]
  return { pane: P, btn: btn ? box(btn) : null, btnInside: Boolean(btn) && inside(btn), chips: chips.map((c) => ({ t: c.textContent.trim(), ...box(c), inside: inside(c) })) }
}, paneRow(id))

const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send('CLE-77840 react on me', undefined, undefined, undefined, 1)
  await ch.send('CLE-77840 a reply', top.task_id, undefined, undefined, 0)
  return { msg_id: top.msg_id, task_id: top.task_id }
}, { A })

async function reactInMiddle(p, id) {
  const sel = midCard(id)
  await p.hover(sel)
  const btn = await p.$(`${sel} [data-testid=msg-emoji-btn]`)
  const bb = await btn.boundingBox()
  await p.mouse.click(bb.x + bb.width / 2, bb.y + bb.height / 2)
  await p.waitForSelector('[data-testid=emoji-picker]', { visible: true, timeout: 5000 })
  const cell = (await p.$$('[data-testid=emoji-grid] button'))[0]
  const label = await cell.evaluate((e) => e.textContent.trim())
  const cb = await cell.boundingBox()
  await p.mouse.click(cb.x + cb.width / 2, cb.y + cb.height / 2)
  await sleep(800)
  return label
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  const s = await seed(p)
  await p.waitForSelector(midCard(s.msg_id), { timeout: 10000 })
  await p.evaluate((sel) => document.querySelector(sel)?.click(), midCard(s.msg_id))
  await p.waitForSelector(paneRow(s.msg_id), { timeout: 10000 })
  await sleep(400)

  /* ---- 1-3. react in the middle list; the pane shows it too ------------- */
  const label = await reactInMiddle(p, s.msg_id)
  const mid = await p.evaluate((sel) => [...document.querySelectorAll(`${sel} [data-testid=msg-reaction]`)].map((e) => e.textContent.trim()), midCard(s.msg_id))
  ok('1 the chip shows on the card in the middle list', mid.some((t) => t.includes(label)), { label, mid })
  const g = await paneGeo(p, s.msg_id)
  ok('2 ... and on the same message in the topic pane, inside the pane', Boolean(g) && g.chips.some((c) => c.t.includes(label) && c.inside), g)
  ok('3 the pane\'s smile button is inside the pane', Boolean(g) && g.btnInside, g && { btn: g.btn, pane: g.pane })
  await shot(p, '1-pane-chip')

  /* ---- 4. a narrow pane and a long time label (prd: "... sent 94h 23m") - */
  await p.evaluate((sel) => {
    const pane = document.querySelector(sel)?.closest('.topic')
    if (pane) pane.style.width = '280px'
    for (const t of document.querySelectorAll(`${sel} .msg-time`)) t.textContent = '2026-09-27 11:16:01 sent 94h 23m'
  }, paneRow(s.msg_id))
  await sleep(300)
  const n = await paneGeo(p, s.msg_id)
  ok('4 narrow pane + long time: the smile button and the chip stay inside the pane', Boolean(n) && n.btnInside && n.chips.length > 0 && n.chips.every((c) => c.inside), n)
  await shot(p, '4-narrow')

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nreaction-pane-visible: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
