// SPL-1234 control: Escape closes the channel Properties dialog.
// SPL-1684: the Settings tab's AI agents switch (section 3), with a desktop
// and a 390 px screenshot into SHOT_DIR when it is set.
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

/** Read until want() holds on the SAME value for `hold` ms, or `max` runs out;
    returns the last read. */
async function until(read, want = () => true, hold = 300, max = 8000) {
  const end = Date.now() + max
  let key = ''
  let since = 0
  let v = await read()
  while (Date.now() < end) {
    const k = want(v) ? JSON.stringify(v) ?? 'undefined' : ''
    if (!k) { key = ''; since = 0 } else if (k !== key) { key = k; since = Date.now() } else if (Date.now() - since >= hold) return v
    await sleep(100)
    v = await read()
  }
  return v
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

const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

const dialogOpen = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=channel-properties]')))
/* closed, and still closed 300 ms later; an Escape that does nothing times out open */
const closes = async (p) => !(await until(() => dialogOpen(p), (open) => !open, 300, 3000))
/* the dialog has its focus inside the panel (UiDialog's focus-on-open, the lazy tab loaded) */
const focused = (p) => until(() => p.evaluate(() => Boolean(document.activeElement?.closest('[role=dialog]')?.querySelector('[data-testid=channel-properties]'))), Boolean, 300, 3000)
/* a control is on screen to click */
const shown = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 5000 }).catch(() => null)

async function openProperties(page, channelId) {
  await click(page, '[data-testid=sidebar-tab-channels]')
  await shown(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${channelId}"]`)
  await click(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${channelId}"]`)
  await shown(page, '[data-testid=sidebar-row-menu-properties]')
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
  await until(() => page.evaluate(() => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel'))), Boolean, 0)

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
  await focused(page)
  await page.keyboard.press('Escape')
  ok('Escape closes the Properties dialog (focus in panel)', await closes(page))

  if (await dialogOpen(page)) await click(page, '[data-testid=ui-dialog-close]')
  await closes(page)

  /* ---- 1b. Escape closes even with focus OUTSIDE the panel (the control) ---
     This is the owner's case: focus had left the dialog (teleport / async-load
     timing), so the panel's own keydown never fired. Fails today; the
     window-level handler (SPL-1234) closes it. */
  ok('Properties opens (for the focus-outside Escape check)', await openProperties(page, made))
  /* focus-on-open first, so the blur below is not undone by it */
  await focused(page)
  await page.evaluate(() => { document.activeElement?.blur?.(); document.body.focus?.() })
  await page.keyboard.press('Escape')
  ok('Escape closes the Properties dialog when focus is outside the panel (SPL-1234)', await closes(page))

  if (await dialogOpen(page)) await click(page, '[data-testid=ui-dialog-close]')
  await closes(page)

  /* ---- 2. the X still closes (the owner says this path works) ------------- */
  ok('Properties opens (for the X check)', await openProperties(page, made))
  await shown(page, '[data-testid=ui-dialog-close]')
  await click(page, '[data-testid=ui-dialog-close]')
  ok('the X closes the Properties dialog', await closes(page))

  /* ---- 3. SPL-1684: the AI agents switch ----------------------------------
     The creator sees it on (the mock workspace default), switches it off;
     the Agents tab then says so, and a reopen reads it back off. */
  const aiState = () => page.evaluate(() => {
    const box = document.querySelector('[data-testid=channel-ai-agents]')
    return box ? { checked: box.checked, disabled: box.disabled } : null
  })
  ok('Properties opens (for the AI agents switch)', await openProperties(page, made))
  await click(page, '[data-testid=channel-properties-tab-settings]')
  const before = await until(aiState, Boolean)
  ok('the AI agents switch is on and the creator may change it', before?.checked === true && before?.disabled === false, before)
  await click(page, '[data-testid=channel-ai-agents]')
  /* the switch and its hint once they have stopped changing */
  const { after, offHint } = await until(async () => ({ after: await aiState(), offHint: await page.evaluate(() => document.querySelector('[data-testid=channel-ai-agents-hint]')?.textContent || '') }), (v) => v.after?.checked !== before?.checked)
  ok('switched off, the hint says agents do not read the channel', after?.checked === false && /do not read/.test(offHint), { after, offHint })
  const shotDir = process.env.SHOT_DIR || ''
  if (shotDir) await page.screenshot({ path: `${shotDir}/spl-1684-ai-agents-desktop.png` })
  await click(page, '[data-testid=channel-properties-tab-agents]')
  ok('the Agents tab says the AI agents are off', Boolean(await shown(page, '[data-testid=channel-ai-agents-off-note]')))
  await click(page, '[data-testid=ui-dialog-close]')
  await closes(page)
  ok('Properties reopens (switch read back)', await openProperties(page, made))
  await click(page, '[data-testid=channel-properties-tab-settings]')
  ok('a reopen reads the switch back off', (await until(aiState, Boolean))?.checked === false)
  if (shotDir) {
    await page.setViewport({ width: 390, height: 844 })
    await sleep(600)
    await page.screenshot({ path: `${shotDir}/spl-1684-ai-agents-phone-390.png` })
    await page.setViewport({ width: 1440, height: 900 })
  }
  await click(page, '[data-testid=ui-dialog-close]')

  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-properties-esc: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
