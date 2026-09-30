// CLE-77812: before/after screenshots of the selected (active) channel row in
// the left sidebar (mock tenant), dark and light, 1440 and 390. Not a test: it
// prints the active row's font-weight and box-shadow per shot so the selected
// style is proven, not just pictured.
//   OUT=/tmp/shots TAG=after node tests/e2e/selected-channel-shots.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const OUT = process.env.OUT || '.'
const TAG = process.env.TAG || 'shot'
const require = createRequire(import.meta.url)
const puppeteer = (await import(pathToFileURL(require.resolve(process.env.PUPPETEER_CORE || 'puppeteer-core')).href)).default
const server = await startServer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
try {
  const p = await browser.newPage()
  for (const theme of ['dark', 'light']) {
    for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
      await setPageViewport(p, vp)
      // a real channel is the active one, so its row carries .nav-item.active
      await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
      await p.evaluate((t) => localStorage.setItem('spool-theme', t), theme)
      await p.reload({ waitUntil: 'networkidle2' })
      await applyViewport(p, vp)
      await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
      // on the phone the sidebar is the level-1 screen; on desktop it is always up
      await p.waitForSelector('.nav-item.active', { visible: true, timeout: 8000 }).catch(() => {})
      await new Promise((r) => setTimeout(r, 500))
      const info = await p.evaluate(() => {
        const el = document.querySelector('.nav-item.active')
        if (!el) return { found: false }
        const cs = getComputedStyle(el)
        return { found: true, text: el.textContent.trim().slice(0, 24), fontWeight: cs.fontWeight, boxShadow: cs.boxShadow.slice(0, 80) }
      })
      console.log(theme, vp.width, JSON.stringify(info))
      await p.screenshot({ path: `${OUT}/selected-chan-${TAG}-${vp.width}-${theme}.png` })
    }
  }
} finally {
  await browser.close()
  await server.stop()
}
