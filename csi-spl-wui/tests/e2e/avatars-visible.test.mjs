// Avatars are visible for people AND agents, proved in a REAL browser (owner,
// prd t1 177db6cf + 432769d8, 2026-09-26: "the avatars for the users and the
// bots are not visible" / "they disappear from time to time"; his screenshot
// was the Topics list, whose rows drew no avatar at all).
//
// At 1440 and 390 px, light and dark, against the mock bundle:
//   1. Topics (/, desktop: a phone opens on the sections, where the Topics
//      tab is a text list like the channels): every row on screen paints its
//      starter's avatar, never the broadcast address ALL-0's;
//   2. a person's card (#lobby) and an agent's card (#alerts, scrolled into
//      view) each paint one;
//   3. both kinds are really painted: loaded (naturalWidth > 0), at least
//      16 px, inside the viewport, not hidden, not transparent, and the
//      topmost element at their centre (nothing laid over them).
//
// CONTROLS - plant the defect and watch it go red:
//   PROVE_RED=no-row-avatar pnpm run test:e2e avatars   (the Topics rows lose it)
//   PROVE_RED=hidden        pnpm run test:e2e avatars   (every avatar visibility:hidden)
//
// Run:
//   pnpm run test:e2e avatars
//   BASE_URL=<generated bundle> pnpm run test:e2e avatars     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const WIDTHS = [1440, 390]
const THEMES = ['light', 'dark']

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The planted defects, applied after the page has rendered. */
async function plant(page) {
  if (RED === 'no-row-avatar') await page.evaluate(() => document.querySelectorAll('[data-test=topic-row-avatar]').forEach((e) => e.remove()))
  if (RED === 'hidden') await page.addStyleTag({ content: '.spool-avatar { visibility: hidden !important; }' })
}

/**
 * Every avatar inside `scope` that is on screen, with what decides whether a
 * person can see it. `kind` is read from the alt text the avatar carries:
 * an agent is named <PREFIX>-<n>@<box>, everyone else is a person.
 */
function avatars(page, scope) {
  return page.evaluate((sel) => {
    const out = []
    for (const root of document.querySelectorAll(sel)) {
      const r0 = root.getBoundingClientRect()
      if (r0.bottom <= 0 || r0.top >= innerHeight || r0.width === 0) continue
      const img = root.querySelector('img.spool-avatar')
      if (!img) { out.push({ row: true, missing: true }); continue }
      const r = img.getBoundingClientRect()
      const cs = getComputedStyle(img)
      const cx = r.left + r.width / 2
      const cy = r.top + r.height / 2
      const top = cx >= 0 && cy >= 0 && cx < innerWidth && cy < innerHeight ? document.elementFromPoint(cx, cy) : null
      let opaque = null
      try {
        const c = document.createElement('canvas')
        c.width = 16; c.height = 16
        const g = c.getContext('2d')
        g.drawImage(img, 0, 0, 16, 16)
        const px = g.getImageData(0, 0, 16, 16).data
        let n = 0
        for (let i = 3; i < px.length; i += 4) if (px[i] > 0) n++
        opaque = n
      } catch { /* a tainted canvas: the other checks still hold */ }
      const alt = img.getAttribute('alt') || ''
      out.push({
        alt,
        kind: /^avatar of [A-Z]{2,4}-\d+@/.test(alt) && !/^avatar of (HUM|GST)-/.test(alt) ? 'agent' : 'person',
        nat: img.naturalWidth,
        w: Math.round(r.width),
        h: Math.round(r.height),
        inView: r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight,
        visible: cs.visibility === 'visible' && cs.display !== 'none' && Number(cs.opacity) > 0,
        onTop: top === img,
        opaque,
      })
    }
    return out
  }, scope)
}

/* Open `path`, wait for `sel`, plant, measure. `nuxi dev` reloads the page
   once while it warms up, which destroys the context mid-measure: open again.
   Runner network churn gets one more try; the page errors it caused go. */
function measureAt(page, path, sel, errors) {
  const before = errors.length
  return retryOnNetworkChanged(path, () => measureOnce(page, path, sel), { onRetry: () => errors.splice(before) })
}

async function measureOnce(page, path, sel) {
  for (let i = 0; ; i++) {
    try {
      await page.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await page.waitForSelector(sel, { visible: true, timeout: NAV_TIMEOUT })
      await sleep(800)
      /* an agent's card is somewhere in the feed: bring the first one on screen */
      const scrolled = await page.evaluate((s) => {
        const card = [...document.querySelectorAll(s)].find((el) => {
          const alt = el.querySelector('img.spool-avatar')?.getAttribute('alt') || ''
          return /^avatar of [A-Z]{2,4}-\d+@/.test(alt)
        })
        if (card && s === 'article.msg') card.scrollIntoView({ block: 'center', behavior: 'instant' })
        return Boolean(card)
      }, sel)
      if (scrolled) await sleep(600)
      await plant(page)
      return await avatars(page, sel)
    } catch (e) {
      if (i >= 2 || !/context was destroyed|detached|navigation/i.test(String(e))) throw e
    }
  }
}

const painted = (a) => !a.missing && a.nat > 0 && a.w >= 16 && a.h >= 16 && a.visible && a.onTop && (a.opaque === null || a.opaque > 0)

const server = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    for (const theme of THEMES) {
      const at = `${width}px ${theme}`
      const touch = width <= 820
      const p = watchPage(await browser.newPage(), at)
      const errors = []
      p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
      await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
      await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
      await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)

      // 1. the Topics list
      if (!touch) {
        const rows = await measureAt(p, '/', '.topic-row', errors)
        ok(`1 ${at}: every Topics row on screen paints its starter's avatar`,
          rows.length > 0 && rows.every(painted) && !rows.some((a) => /ALL-0/.test(a.alt || '')),
          { rows: rows.length, bad: rows.filter((a) => !painted(a) || /ALL-0/.test(a.alt || '')).slice(0, 3) })
      }

      // 2. #lobby cards: a person and an agent
      const cards = await measureAt(p, '/lobby', 'article.msg', errors)
      const person = cards.find((a) => a.kind === 'person')
      /* the mock's agent posts: #alerts */
      const agentCards = await measureAt(p, '/channel/alerts', 'article.msg', errors)
      const agent = agentCards.find((a) => a.kind === 'agent')
      ok(`2 ${at}: a person's card paints their avatar`, Boolean(person) && painted(person), person)
      ok(`3 ${at}: an agent's card paints its avatar`, Boolean(agent) && painted(agent), agent || { cards: agentCards.length, alts: agentCards.map((a) => a.alt).slice(0, 8) })
      ok(`4 ${at}: no page error`, errors.length === 0, errors)
      await p.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
