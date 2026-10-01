// CLE-77873 (owner, t1 topic d6c9661e): "the 'setting of the reactions via
// the emoji does not work' bug re-appeared again". The prd hub log shows the
// owner's desktop picking on his own opening card three times in 11 s:
// DELETE, PUT, DELETE, every one 200. Each pick worked and toggled, but no
// chip was ever drawn, so every pick looked like nothing.
//
// The card was in the TITLES view (the header's "-" control). SPL-943 hid the
// reactions in that view when they were a strip under the body; SPL-982 then
// moved the chips INTO the header line, which a titles card keeps, with the
// smile button - and the `!titleOnly` gate stayed. reaction-pane-visible only
// ever ran in the default rows view, so it could not see this.
//
// Runs against the lde mock. Per view (titles, rows) and pane:
//   1440 x 900, light and dark: react on the card in the MIDDLE list, then on
//     the same message in the TOPIC PANE: the chip is painted on that card,
//     inside the pane and on the smile's line
//   390 x 844 touch: react on the middle card: the half-size chip shows
//     inside the Add-emoji button
//
// Run:
//   node tests/e2e/reaction-titles-view.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/reaction-titles-view.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''

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

const seed = (p, channel, text) => p.evaluate(async ({ channel, text }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(channel)
  await app.config.globalProperties.$router.push('/channel/' + channel)
  await new Promise((r) => setTimeout(r, 500))
  /* freeze the mock's 4 s feed re-read: it replaces the rows under a slow run */
  ch.refresh = async () => {}
  const top = await ch.send(text, undefined, undefined, undefined, 1)
  await ch.send(text + ' - a reply', top.task_id, undefined, undefined, 0)
  return { msg_id: top.msg_id, task_id: top.task_id }
}, { channel, text })

/** Pick a header view (titles | rows | full) on the pane that holds `scope`. */
async function setView(p, scope, mode) {
  const done = await p.evaluate((scope, mode) => {
    const root = document.querySelector(scope)
    const btn = root?.querySelector(`[data-testid="card-clip-${mode}"]`)
    if (!btn) return false
    btn.click()
    return true
  }, scope, mode)
  await sleep(300)
  return done
}

/** Where the card's smile and chips are painted: in the card, on its line. */
const chipGeo = (p, sel) => p.evaluate((sel) => {
  const row = document.querySelector(sel)
  if (!row) return null
  const pane = row.closest('.topic') || row.closest('.spool-main') || document.body
  const box = (e) => { const r = e.getBoundingClientRect(); return { l: Math.round(r.left), r: Math.round(r.right), t: Math.round(r.top), b: Math.round(r.bottom), w: Math.round(r.width), h: Math.round(r.height) } }
  const P = box(pane)
  const btn = row.querySelector('[data-testid=msg-emoji-btn]')
  const B = btn ? box(btn) : null
  const chips = [...row.querySelectorAll('[data-testid=msg-reaction]')].map((c) => {
    const b = box(c)
    const cs = getComputedStyle(c)
    return {
      glyph: c.textContent.trim(),
      ...b,
      shown: b.w > 0 && b.h > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0,
      inside: b.l >= P.l - 1 && b.r <= P.r + 1,
      onBtnLine: Boolean(B) && Math.abs((b.t + b.b) / 2 - (B.t + B.b) / 2) <= 12,
    }
  })
  return { clip: row.closest('[data-clip-mode]')?.getAttribute('data-clip-mode') || null, btn: B, chips }
}, sel)

async function react(p, sel, touch) {
  await p.evaluate((s) => document.querySelector(s)?.scrollIntoView({ block: 'center' }), sel)
  if (!touch) await p.hover(sel)
  const btn = await p.$(`${sel} [data-testid=msg-emoji-btn]`)
  if (!btn) return ''
  const bb = await btn.boundingBox()
  if (touch) await p.touchscreen.tap(bb.x + bb.width / 2, bb.y + bb.height / 2)
  else await p.mouse.click(bb.x + bb.width / 2, bb.y + bb.height / 2)
  await p.waitForSelector('[data-testid=emoji-picker]', { visible: true, timeout: 8000 })
  const cell = (await p.$$('[data-testid=emoji-grid] button'))[0]
  const label = await cell.evaluate((e) => e.textContent.trim())
  const cb = await cell.boundingBox()
  if (touch) await p.touchscreen.tap(cb.x + cb.width / 2, cb.y + cb.height / 2)
  else await p.mouse.click(cb.x + cb.width / 2, cb.y + cb.height / 2)
  await sleep(800)
  return label
}

const painted = (g, label) => Boolean(g) && g.chips.some((c) => c.glyph.includes(label) && c.shown && c.inside && c.onBtnLine)

const srv = await startServer()
const browser = await launch()
try {
  const errors = []
  let n = 0

  /* ---- desktop: middle list, then the topic pane; light and dark -------- */
  for (const scheme of ['light', 'dark']) {
    for (const view of ['titles', 'rows']) {
      const p = await browser.newPage()
      p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
      p.setDefaultNavigationTimeout(NAV_TIMEOUT)
      await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
      await p.setViewport({ width: 1440, height: 900 })
      await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
      await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      await sleep(600)
      const s = await seed(p, `cle-77873-${scheme}-${view}-${++n}`, `CLE-77873 react in ${view} (${scheme})`)
      await p.waitForSelector(midCard(s.msg_id), { timeout: 10000 })

      const tag = `1440 ${scheme} ${view}`
      ok(`${tag}: the middle list is in the ${view} view`, await setView(p, '.spool-main', view))
      const l1 = await react(p, midCard(s.msg_id), false)
      const g1 = await chipGeo(p, midCard(s.msg_id))
      ok(`${tag}: a pick on the middle card paints its chip there, on the smile's line`, Boolean(l1) && painted(g1, l1), { label: l1, g: g1 })
      await shot(p, `${scheme}-${view}-middle`)

      /* the same card's topic in the right pane, that pane in the same view */
      await p.evaluate((sel) => document.querySelector(sel)?.click(), midCard(s.msg_id))
      await p.waitForSelector(paneRow(s.msg_id), { timeout: 10000 })
      await sleep(400)
      ok(`${tag}: the topic pane is in the ${view} view`, await setView(p, '.topic', view))
      const g2 = await chipGeo(p, paneRow(s.msg_id))
      ok(`${tag}: ... and the topic pane paints the same chip`, painted(g2, l1), { g: g2 })

      /* a reply, picked in the pane itself */
      const reply = await p.evaluate((id) => [...document.querySelectorAll('.topic article.msg[data-msg-id]')].map((e) => e.dataset.msgId).find((x) => x !== id), s.msg_id)
      const l3 = reply ? await react(p, paneRow(reply), false) : ''
      const g3 = reply ? await chipGeo(p, paneRow(reply)) : null
      ok(`${tag}: a pick on a reply in the topic pane paints its chip there`, Boolean(l3) && painted(g3, l3), { reply, label: l3, g: g3 })
      await shot(p, `${scheme}-${view}-pane`)
      await p.close()
    }
  }

  /* ---- phone: the chips sit inside the Add-emoji button ------------------ */
  for (const view of ['titles', 'rows']) {
    const p = await browser.newPage()
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
    await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(600)
    const s = await seed(p, `cle-77873-phone-${view}-${++n}`, `CLE-77873 phone react in ${view}`)
    await p.waitForSelector(midCard(s.msg_id), { timeout: 10000 })
    ok(`390 ${view}: the list is in the ${view} view`, await setView(p, '.spool-main', view))
    const l = await react(p, midCard(s.msg_id), true)
    const g = await chipGeo(p, midCard(s.msg_id))
    ok(`390 ${view}: a tap-pick paints the chip inside the Add-emoji button`, Boolean(l) && painted(g, l), { label: l, g })
    await shot(p, `phone-${view}`)
    await p.close()
  }

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nreaction-titles-view: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
