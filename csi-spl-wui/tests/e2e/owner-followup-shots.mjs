// CLE-77812 owner follow-ups: before/after screenshots (mock tenant, signed-in).
// Topic a3c2cf08 — the sidebar: selected RAIL icon (raised, no ring box) and the
// selected CHANNEL row (bold + 3D, no left bar). Topic c2c4b527 — the emoji
// picker with 👀 as the third glyph. Dark + light; sidebar at 1440 and 390, the
// picker at 1440. Not a test: it prints the proving facts per shot.
//   OUT=/tmp/shots TAG=after node tests/e2e/owner-followup-shots.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const OUT = process.env.OUT || '.'
const TAG = process.env.TAG || 'shot'
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const require = createRequire(import.meta.url)
const puppeteer = (await import(pathToFileURL(require.resolve(process.env.PUPPETEER_CORE || 'puppeteer-core')).href)).default
const server = await startServer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function signedInChannel(p, theme) {
  await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.evaluate((s, t) => { localStorage.setItem('spool.mock.session', s); localStorage.setItem('spool-theme', t) }, MOCK_SESSION, theme)
  await p.reload({ waitUntil: 'networkidle2' })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

try {
  const p = await browser.newPage()
  for (const theme of ['dark', 'light']) {
    // --- topic a3c2cf08: the sidebar (rail + selected channel row) ---
    for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
      await setPageViewport(p, vp)
      await signedInChannel(p, theme)
      await applyViewport(p, vp)
      await p.waitForSelector('.nav-item.active', { visible: true, timeout: 8000 }).catch(() => {})
      await sleep(500)
      const facts = await p.evaluate(() => {
        const row = document.querySelector('.nav-item.active')
        const tab = document.querySelector('.sidebar-tab[aria-selected="true"]')
        const cs = (el) => el ? getComputedStyle(el) : null
        const r = cs(row); const t = cs(tab)
        return {
          row: r && { fontWeight: r.fontWeight, boxShadow: r.boxShadow.slice(0, 90) },
          tab: t && { boxShadow: t.boxShadow.slice(0, 90), svgStroke: (() => { const s = tab.querySelector('svg'); return s ? getComputedStyle(s).strokeWidth : '' })() },
        }
      })
      console.log('sidebar', theme, vp.width, JSON.stringify(facts))
      await p.screenshot({ path: `${OUT}/followup-sidebar-${TAG}-${vp.width}-${theme}.png` })
    }
    // --- topic c2c4b527: the emoji picker (👀 third) ---
    await setPageViewport(p, { width: 1440, height: 900 })
    await signedInChannel(p, theme)
    await applyViewport(p, { width: 1440, height: 900 })
    const btn = 'article.msg[data-msg-id] [data-testid=msg-emoji-btn]'
    await p.waitForSelector(btn, { timeout: 8000 }).catch(() => {})
    await sleep(300)
    await p.click(btn).catch(() => {})
    await sleep(500)
    const order = await p.evaluate(() => {
      const el = document.querySelector('[data-testid=emoji-picker]')
      if (!el) return { found: false }
      const glyphs = [...el.querySelectorAll('.emoji-picker__glyph')].map((b) => b.getAttribute('data-emoji') || '')
      // the ordered choices grid (skip a "recent" grid if present): first 8 of the main grid
      return { found: true, first8: glyphs.slice(0, 8) }
    })
    console.log('emoji', theme, JSON.stringify(order))
    await p.screenshot({ path: `${OUT}/followup-emoji-${TAG}-1440-${theme}.png` })
  }
} finally {
  await browser.close()
  await server.stop()
}
