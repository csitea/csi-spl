// SCRATCH red control for SPL-3469 (never for master): a label whose box fits
// its text in Noto Sans but not in the wider DejaVu Sans. With the pinned
// fonts.conf it must fail on the box too.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
// Runs only on GitHub Actions: the box red is measured by hand, and the
// pre-push gate (pinned too) would refuse the throwaway branch otherwise.
if (!process.env.GITHUB_ACTIONS) { console.log('zz-font-plant: skipped off GitHub Actions'); process.exit(0) }
const BOX_PX = Number(process.env.PLANT_BOX_PX ?? 185)
const require = createRequire(import.meta.url)
const puppeteer = (await import(pathToFileURL(require.resolve('puppeteer-core')).href)).default
const server = await startServer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
let rc = 1
try {
  const p = await browser.newPage()
  await p.goto(server.base + '/login', { waitUntil: 'networkidle2', timeout: 60000 })
  const r = await p.evaluate((box) => {
    const s = document.createElement('span')
    s.textContent = 'Selected: 1 of 12 messages'
    s.style.cssText = 'font: 14px var(--font-stack); white-space: nowrap; position: absolute'
    document.body.appendChild(s)
    return { textPx: s.getBoundingClientRect().width, box }
  }, BOX_PX)
  const cdp = await p.target().createCDPSession()
  await cdp.send('DOM.enable'); await cdp.send('CSS.enable')
  const { root } = await cdp.send('DOM.getDocument')
  const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector: 'body > span:last-child' })
  const { fonts } = await cdp.send('CSS.getPlatformFontsForNode', { nodeId })
  const fits = r.textPx <= BOX_PX
  console.log(`  ${fits ? 'OK  ' : 'FAIL'} label fits its ${BOX_PX}px box ${JSON.stringify({ ...r, fonts: fonts.map((f) => f.familyName) })}`)
  rc = fits ? 0 : 1
} finally { await browser.close(); await server.stop() }
console.log(rc ? 'zz-font-plant: 1 FAILED' : 'zz-font-plant: all 1 passed')
process.exit(rc)
