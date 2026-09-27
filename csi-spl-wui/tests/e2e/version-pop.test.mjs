// SPL-999: the version pop-up in the sidebar footer shows the WHOLE build
// hash and has a copy button.
//
// Owner, 2026-09-27: "the pop-up on the version could be a bit bigger to fit
// the whole hash properly" and "also the copy button should be in it".
// /build.json is served by request interception (lde has none), with a full
// 40-character sha. At 1440, 820, 390 and 360 px the pop-up opens by a click
// and:
//   - the sha is on one line in a monospace font (at <= 390 px it may wrap
//     into two lines, never cut): its text is not clipped, and every corner
//     of it is really painted (elementFromPoint), so no ancestor or screen
//     edge cuts it
//   - the card stays inside the viewport minus 8 px each side
//   - the copy button is the code blocks' copy icon, >= 44 px on phones,
//     copies the full sha, then shows the check icon and "Copied"
//   - the sha stays selectable (user-select: text)
//   - a click / tap anywhere outside the card closes it (owner, topic 82b9c309)
//
// SPL-1023 (owner, topic 82b9c309: "does not close when one clicks
// elsewhere"): a press on the sha keeps it open; a real click / tap outside
// it (on the feed where there is one) closes it; Esc closes it; at 390 px
// Back closes it and leaves the URL and the level as they were.
//
// Run:
//   node tests/e2e/version-pop.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/version-pop.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

/* SPL-1006: the pop-up shows the commit the tab RUNS when the bundle bakes
   one in (window.__BUILD__, CI: GITHUB_SHA); build.json is served with that
   same commit so no newer build is live. lde bakes none: then this one. */
const FALLBACK_SHA = '0123456789abcdef0123456789abcdef01234567'
let SHA = FALLBACK_SHA
const TAP = 44
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const measure = (p) => p.evaluate(() => {
  const card = document.querySelector('[data-test=app-version-card]')
  const sha = card?.querySelector('.vs-pop__sha')
  const btn = card?.querySelector('[data-test=app-version-copy]')
  if (!card || !sha || !btn) return null
  const box = (el) => { const r = el.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), r: Math.round(r.right), b: Math.round(r.bottom) } }
  const range = document.createRange()
  range.selectNodeContents(sha)
  const lines = [...range.getClientRects()].map((r) => Math.round(r.width))
  const rs = sha.getBoundingClientRect()
  const painted = [[rs.left + 2, rs.top + 2], [rs.right - 2, rs.top + 2], [rs.left + 2, rs.bottom - 2], [rs.right - 2, rs.bottom - 2]]
    .every(([x, y]) => { const e = document.elementFromPoint(x, y); return Boolean(e && card.contains(e)) })
  const cs = getComputedStyle(sha)
  return {
    vw: window.innerWidth,
    card: box(card),
    shown: getComputedStyle(card).visibility === 'visible',
    sha: { ...box(sha), text: sha.textContent.trim(), lines: lines.length, clipped: sha.scrollWidth > sha.clientWidth + 1, font: cs.fontFamily, select: cs.userSelect || cs.webkitUserSelect },
    painted,
    btn: { ...box(btn), icon: btn.querySelector('svg')?.getAttribute('data-icon') || null, label: btn.getAttribute('aria-label'), text: btn.textContent.trim() },
  }
})

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const ctx = await browser.createBrowserContext()
  await ctx.overridePermissions(new URL(base).origin, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  const p = await ctx.newPage()
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname === '/build.json') {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: SHA, built_at: '2026-09-27T10:30:00Z', run: '36312554957' }) })
    }
    req.continue()
  })
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  // on a phone the sidebar is level 1 at / (SPL-989); /lobby is level 2
  await p.goto(`${base}${touch ? '/' : '/lobby'}`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  const baked = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '')
  if (baked && baked !== SHA) {
    SHA = baked
    await p.reload({ waitUntil: 'load' })
    await p.waitForSelector('[data-test=top-bar]')
  }
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector('[data-test=app-version-card]', { timeout: 15000 })
  await sleep(400)
  await p.evaluate(() => document.querySelector('[data-test=app-version-wrap]').click())
  await sleep(400)
  const m = await measure(p)
  if (!m) { check(`${tag}: the pop-up renders`, false); await ctx.close(); return }
  check(`${tag}: the pop-up opens`, m.shown, m.card)
  check(`${tag}: it holds the whole 40-character sha`, m.sha.text === SHA, m.sha.text)
  check(`${tag}: monospace`, /mono/i.test(m.sha.font), m.sha.font)
  const lineOk = width > 390 ? m.sha.lines === 1 : m.sha.lines <= 2
  check(`${tag}: the sha on ${width > 390 ? 'one line' : 'at most two lines'}, not clipped`, lineOk && !m.sha.clipped, m.sha)
  check(`${tag}: every corner of the sha is painted (no ancestor cuts it)`, m.painted, m.sha)
  check(`${tag}: the card stays inside the viewport minus 8 px`, m.card.x >= 8 && m.card.r <= m.vw - 8, { card: m.card, vw: m.vw })
  check(`${tag}: the sha stays selectable`, m.sha.select === 'text', m.sha.select)
  check(`${tag}: the copy button sits inside the card`, m.btn.x >= m.card.x && m.btn.r <= m.card.r, { btn: m.btn, card: m.card })
  check(`${tag}: the copy button is the copy icon`, m.btn.icon === 'copy' && Boolean(m.btn.label), m.btn)
  if (touch) check(`${tag}: copy >= ${TAP} px`, m.btn.w >= TAP && m.btn.h >= TAP, m.btn)
  await p.click('[data-test=app-version-copy]')
  await sleep(250)
  const clip = await p.evaluate(() => navigator.clipboard.readText().catch((e) => `ERR ${e.message}`))
  check(`${tag}: copy puts the full sha on the clipboard`, clip === SHA, clip)
  const after = await measure(p)
  check(`${tag}: then the check icon and "Copied"`, after?.btn.icon === 'check' && /copied/i.test(after.btn.text), after?.btn)
  check(`${tag}: the pop-up stays open after the copy`, after?.shown === true)
  // owner 2026-09-27 (topic 82b9c309): a click / tap anywhere outside closes it
  // the middle of the top bar: outside the card, and nothing there navigates
  const away = await p.evaluate(() => {
    const r = document.querySelector('[data-test=top-bar]').getBoundingClientRect()
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
  })
  if (touch) await p.touchscreen.tap(away.x, away.y)
  else await p.mouse.click(away.x, away.y)
  await sleep(900)
  const outside = await measure(p)
  check(`${tag}: a ${touch ? 'tap' : 'click'} outside closes it`, outside?.shown === false, { shown: outside?.shown, at: away })

  /* SPL-1023: inside keeps it, outside / Esc / Back close it */
  const press = async (x, y) => { if (touch) await p.touchscreen.tap(x, y); else await p.mouse.click(x, y) }
  const state = () => p.evaluate(() => {
    const w = document.querySelector('[data-test=app-version-wrap]')
    const c = document.querySelector('[data-test=app-version-card]')
    return { expanded: w?.getAttribute('aria-expanded'), shown: c ? getComputedStyle(c).visibility === 'visible' : false }
  })
  const openIt = async () => {
    await p.evaluate(() => document.querySelector('[data-test=app-version-wrap]').click())
    await sleep(300)
  }
  await openIt()
  const sha = await p.evaluate(() => { const r = document.querySelector('[data-test=app-version-card] .vs-pop__sha').getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 } })
  await press(sha.x, sha.y)
  await sleep(700)
  const inside = await state()
  check(`${tag}: a press on the sha keeps it open`, inside.shown && inside.expanded === 'true', inside)
  /* a plain spot outside the card: the feed when there is one, never a control */
  const spot = await p.evaluate(() => {
    const w = document.querySelector('[data-test=app-version-wrap]')
    const plain = (x, y) => {
      const e = document.elementFromPoint(x, y)
      return e && !w.contains(e) && !e.closest('a,button,input,select,textarea,label,summary,[role=button],[role=tab],[role=option],[tabindex],[contenteditable=true],[data-test=top-bar]') ? e : null
    }
    const main = document.querySelector('main')
    const areas = [main?.getBoundingClientRect(), { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight }].filter((r) => r && r.right - r.left > 40)
    for (const r of areas) {
      for (let y = r.top + 20; y < r.bottom - 20; y += 23) {
        for (let x = r.left + 20; x < r.right - 20; x += 31) {
          const e = plain(x, y)
          if (e) return { x, y, in: e.closest('main') ? 'main' : e.className || e.tagName }
        }
      }
    }
    return null
  })
  if (!spot) check(`${tag}: a plain spot outside the pop-up exists`, false)
  else {
    const url0 = p.url()
    await press(spot.x, spot.y)
    await sleep(900)
    const out = await state()
    check(`${tag}: a ${touch ? 'tap' : 'click'} outside (${spot.in}) closes it`, !out.shown && out.expanded === 'false' && p.url() === url0, { ...out, spot })
  }
  await openIt()
  const reopened = await state()
  await p.keyboard.press('Escape')
  await sleep(900)
  const esc = await state()
  check(`${tag}: Esc closes it`, reopened.shown && !esc.shown && esc.expanded === 'false', { reopened, esc })
  if (width === 390) {
    const level = () => p.evaluate(() => ({ url: location.pathname + location.search, rail: Boolean(document.querySelector('[data-testid=sidebar-tab-dm]')?.getBoundingClientRect().width) }))
    const before = await level()
    await openIt()
    const opened = await state()
    await p.goBack()
    await sleep(900)
    const back = await state()
    const afterBack = await level()
    check(`${tag}: Back closes it, the URL and the level stay`, opened.shown && !back.shown && back.expanded === 'false' && afterBack.url === before.url && afterBack.rail === before.rail, { opened, back, before, afterBack })
  }
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [390, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nversion-pop: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
