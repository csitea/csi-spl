// SPL-1234 control: Escape closes the channel Properties dialog.
//
// Owner HUM-10 (prd t1 topic 33db8915): "The properties pop-up does not close
// when it is opened and one presses the Esc button; the click on the X works."
// UiDialog owns Escape (onKeydown on the panel) and focus-on-open, but the
// ChannelPropertiesDialog opens on the People tab whose search is a headlessui
// Combobox; if focus/keys are captured there, Escape never reaches the dialog.
// This opens Properties through the real row menu, presses Escape, and asserts
// the dialog closes (control: fails today). The X close is checked too, since
// the owner says that path works.
//
// Run:
//   node tests/e2e/channel-properties-esc.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/channel-properties-esc.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = 'spl-1234-esc'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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

const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

const dialogOpen = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=channel-properties]')))

async function openProperties(page, channelId) {
  await click(page, '[data-testid=sidebar-tab-channels]')
  await sleep(400)
  await click(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${channelId}"]`)
  await sleep(300)
  await click(page, '[data-testid=sidebar-row-menu-properties]')
  return Boolean(await page.waitForSelector('[data-testid=channel-properties]', { timeout: 10000 }).catch(() => null))
}

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  const made = await page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const row = await ch.createChannel(name)
    return String(row?.channel_id || '')
  }, CHANNEL)
  ok('a channel is created to open Properties on', Boolean(made), { made })

  /* ---- 1. Escape closes with focus inside the panel ----------------------- */
  ok('Properties opens (for the Escape check)', await openProperties(page, made))
  await sleep(400)
  await page.keyboard.press('Escape')
  await sleep(400)
  ok('Escape closes the Properties dialog (focus in panel)', !(await dialogOpen(page)))

  if (await dialogOpen(page)) await click(page, '[data-testid=ui-dialog-close]')
  await sleep(300)

  /* ---- 1b. Escape closes even with focus OUTSIDE the panel (the control) ---
     This is the owner's case: focus had left the dialog (teleport / async-load
     timing), so the panel's own keydown never fired. Fails today; the
     window-level handler (SPL-1234) closes it. */
  ok('Properties opens (for the focus-outside Escape check)', await openProperties(page, made))
  await sleep(400)
  await page.evaluate(() => { document.activeElement?.blur?.(); document.body.focus?.() })
  await page.keyboard.press('Escape')
  await sleep(400)
  ok('Escape closes the Properties dialog when focus is outside the panel (SPL-1234)', !(await dialogOpen(page)))

  if (await dialogOpen(page)) await click(page, '[data-testid=ui-dialog-close]')
  await sleep(300)

  /* ---- 2. the X still closes (the owner says this path works) ------------- */
  ok('Properties opens (for the X check)', await openProperties(page, made))
  await sleep(300)
  await click(page, '[data-testid=ui-dialog-close]')
  await sleep(400)
  ok('the X closes the Properties dialog', !(await dialogOpen(page)))

  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-properties-esc: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
