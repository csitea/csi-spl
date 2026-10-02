// SPL-1133 / SPL-1150 live: Settings -> Behaviour -> "Close buttons" moves
// every close X - Mac style (top left) is the default, Windows style (top
// right) is kept on the account and survives a reload - and the logo dialog
// is the compact card with what spool-hub is, the version and the links.
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] OUT=<dir> \
//     node tests/e2e/close-buttons-live.proof.mjs
//
// It writes ONLY the account's close_buttons value, and puts back the value
// it found (null = never picked). Run it as the dev test member (t1) or in
// the prd e2e tenant host. One sign-in per run (the login rate limit).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
/* optional: put THIS back at the end instead of the value found
   ('null' | 'mac' | 'windows'), for an account a crashed run left changed */
const RESTORE_TO = process.env.RESTORE_TO
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let original
let p
const claim = async () => p.evaluate(async (base) => {
  const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
  return r.status === 200 ? (await r.json()).close_buttons : `status ${r.status}`
}, AUTH_BASE)
const put = async (v) => p.evaluate(async (base, v) => {
  const r = await fetch(base + '/api/v1/auth/preferences', {
    method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ close_buttons: v }),
  })
  return r.status
}, AUTH_BASE, v)
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const root = async () => p.evaluate(() => document.documentElement.getAttribute('data-close-buttons'))
  /* the logo dialog's X against its title, at the current viewport */
  const dialogX = async () => {
    await p.click('[data-test=top-bar-logo]')
    await p.waitForSelector('[data-testid=logo-dialog]', { visible: true, timeout: 10000 })
    await sleep(600)
    const g = await p.evaluate(() => {
      const panel = document.querySelector('[data-testid=ui-dialog]')
      const x = panel.querySelector('[data-testid=ui-dialog-close]')
      const back = panel.querySelector('[data-testid=ui-dialog-back]')
      const title = panel.querySelector('.ui-dialog__title').getBoundingClientRect()
      const pr = panel.getBoundingClientRect()
      const xr = x?.getBoundingClientRect()
      const br = back?.getBoundingClientRect()
      return {
        panel: { w: Math.round(pr.width), h: Math.round(pr.height) },
        xShown: Boolean(xr && xr.width > 0),
        xLeftOfTitle: Boolean(xr && xr.right <= title.left + 1),
        xRightOfTitle: Boolean(xr && xr.left >= title.right - 1),
        backShown: Boolean(br && br.width > 0 && br.left < 60),
        about: Boolean(panel.querySelector('[data-testid=logo-dialog-about]')?.textContent.trim()),
        version: panel.querySelector('[data-testid=logo-dialog-version] code')?.textContent.trim() || '',
        source: panel.querySelector('[data-testid=logo-dialog-source]')?.getAttribute('href') || '',
        docs: panel.querySelector('[data-testid=logo-dialog-docs]')?.getAttribute('href') || '',
      }
    })
    return g
  }
  const closeDialog = async () => {
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => !document.querySelector('[data-testid=ui-dialog]'), { timeout: 5000 }).catch(() => {})
    await sleep(300)
  }
  const pick = async (v) => {
    await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
    const sel = `[data-test=close_buttons-${v}]`
    await p.waitForSelector(sel, { timeout: 15000 })
    await sleep(600)
    await p.click(sel)
    await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, sel)
    await sleep(800)
  }

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await sleep(4000)
  original = await claim()
  step('signed in; the session answers close_buttons', original === null || original === 'mac' || original === 'windows', { close_buttons: original })

  /* default: never picked = Mac style */
  step('clear to never picked (PUT null)', (await put(null)) === 200)
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  step('never picked: <html data-close-buttons="mac">', (await root()) === 'mac', { root: await root() })
  let g = await dialogX()
  step('never picked, 1440: the logo dialog X is top left (before the title)', g.xShown && g.xLeftOfTitle, g)
  step('SPL-1150: the logo dialog is the compact card (<= 720 px wide) with about, version and links',
    g.panel.w <= 720 && g.about && g.version.length > 0 && /github\.com\/csitea\/csi-spl$/.test(g.source) && /csi-spl-doc\/doc\/help$/.test(g.docs), g)
  await p.screenshot({ path: `${OUT}/01-1440-mac-default.png` })
  await closeDialog()

  /* Windows style, through Settings -> Behaviour */
  await pick('windows')
  step('Windows style: stored on the account', (await claim()) === 'windows')
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  step('Windows style after a reload: <html data-close-buttons="windows">', (await root()) === 'windows', { root: await root() })
  g = await dialogX()
  step('Windows style, 1440: the logo dialog X is top right (after the title)', g.xShown && g.xRightOfTitle, g)
  await p.screenshot({ path: `${OUT}/02-1440-windows.png` })
  await closeDialog()

  /* a phone keeps Back at the top left, no X */
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  g = await dialogX()
  step('Windows style, 390: Back top left, no X', g.backShown && !g.xShown, g)
  await p.screenshot({ path: `${OUT}/03-390-windows.png` })
  await closeDialog()

  /* back to Mac style through Settings, at 390 */
  await pick('mac')
  step('Mac style: stored on the account', (await claim()) === 'mac')
} catch (e) {
  step('run', false, { error: String(e && e.message) })
} finally {
  /* only a value the session really answered is put back */
  const back = RESTORE_TO === undefined ? original : (RESTORE_TO === 'null' ? null : RESTORE_TO)
  if (p && (back === null || back === 'mac' || back === 'windows')) {
    const st = await put(back).catch(() => 0)
    step(`restore the account to ${JSON.stringify(back)}`, st === 200 && (await claim().catch(() => 'x')) === back, { status: st })
  }
  writeFileSync(`${OUT}/close-buttons-live.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(failed ? `FAILED ${failed}` : `ALL PASS ${res.steps.length}`)
process.exit(failed ? 1 : 0)
