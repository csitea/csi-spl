// SPL-1150: before/after screenshots of the logo dialog (mock tenant), dark
// and light, 1440 and 390. Not a test: it prints the card's box per shot.
//   OUT=/tmp/shots TAG=before node tests/e2e/logo-dialog-shots.mjs
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
      await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
      await p.evaluate((t) => localStorage.setItem('spool-theme', t), theme)
      await p.reload({ waitUntil: 'networkidle2' })
      await applyViewport(p, vp)
      await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
      await new Promise((r) => setTimeout(r, 500))
      await p.click('[data-test=top-bar-logo]')
      await p.waitForSelector('[data-testid=logo-dialog]', { visible: true, timeout: 5000 })
      await new Promise((r) => setTimeout(r, 900))
      const box = await p.evaluate(() => {
        const r = document.querySelector('[data-testid=ui-dialog]').getBoundingClientRect()
        return { w: Math.round(r.width), h: Math.round(r.height), vw: innerWidth, vh: innerHeight }
      })
      console.log(theme, vp.width, JSON.stringify(box))
      await p.screenshot({ path: `${OUT}/logo-${TAG}-${vp.width}-${theme}.png` })
    }
  }
} finally {
  await browser.close()
  await server.stop()
}
