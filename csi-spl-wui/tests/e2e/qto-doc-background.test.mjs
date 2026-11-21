// SPL-6139 (owner HUM-10, t1 60bf4e56, msg 2dda6b09: "make the docs by
// default with white background, but add also the option to specify
// background from the right click menu option, which will open a dialog box
// with some predefined thems"): with a document open,
// - under a light app theme the doc view's page is white with nothing
//   stored; under the dark theme it keeps the app's dark page;
// - the Document actions menu holds Background…, which opens a dialog of
//   five swatches (Default, White, Paper, Light grey, Dark), the current one
//   checked; a pick repaints the page at once, the dialog stays open, the
//   choice survives a reload (localStorage spool-qto-doc-bg) and an explicit
//   pick reads the same under the dark app theme (its own text colour);
// - Done closes the dialog.
// Control: on master 325a47c76 the page is transparent over the light
// theme's #eaf1fb and the menu has no Background entry, so every check FAILS.
//
//   node tests/e2e/qto-doc-background.test.mjs
//   BASE_URL=<generated bundle> SHOT_DIR=<dir> node tests/e2e/qto-doc-background.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const STEP = 15000
const results = []
const ok = (name, pass, ev) => {
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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const shot = (p, name) => (process.env.SHOT_DIR ? p.screenshot({ path: `${process.env.SHOT_DIR}/qto-doc-bg-${name}.png` }) : null)

/** a fresh page under the app theme `theme`, a document open, nothing stored for the doc page */
async function openDoc(theme, vp = { width: 1280, height: 800 }) {
  const p = await browser.newPage()
  await p.setViewport(vp)
  await p.evaluateOnNewDocument((th) => {
    if (sessionStorage.getItem('doc-bg-seeded')) return
    sessionStorage.setItem('doc-bg-seeded', '1')
    localStorage.setItem('spool-theme', th)
    localStorage.removeItem('spool-qto-doc-bg')
  }, theme)
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const id = await p.waitForFunction(() => window.__wsDocTreeCall?.('GET', '').then((r) => r.docs?.[0]?.id || ''), { timeout: STEP })
    .then((h) => h.jsonValue(), () => '')
  await p.goto(`${server.base}/workspace/docs?doc=${id}&view=doc`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  const open = await p.waitForSelector('[data-test=ws-doc-view]', { visible: true, timeout: STEP }).then(Boolean, () => false)
  await p.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP }).catch(() => null)
  ok(`${theme}: a document is open`, open, id)
  return p
}

/** the doc view's page and text colour, the stored choice, the app theme */
const paint = (p) => p.evaluate(() => {
  const v = document.querySelector('[data-test=ws-doc-view]')
  const title = document.querySelector('[data-test=ws-doc-doctitle]')
  return {
    bg: v ? getComputedStyle(v).backgroundColor : '',
    fg: title ? getComputedStyle(title).color : '',
    attr: v?.getAttribute('data-doc-bg') ?? '',
    stored: localStorage.getItem('spool-qto-doc-bg'),
    theme: document.documentElement.getAttribute('data-theme'),
  }
})

/** WCAG contrast of two rgb() strings */
function contrast(a, b) {
  const lum = (s) => {
    const [r, g, bl] = (s.match(/\d+(\.\d+)?/g) || []).slice(0, 3).map(Number).map((c) => {
      const x = c / 255
      return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4
    })
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m)
  return (x + 0.05) / (y + 0.05)
}

async function openDialog(p) {
  await p.waitForFunction(() => !document.querySelector('[data-test=ws-doc-file-menu]'), { timeout: STEP }).catch(() => null)
  await p.click('[data-test=ws-doc-file-btn]').catch(() => null)
  await p.waitForSelector('[data-test=ws-doc-file-menu-background]', { visible: true, timeout: STEP }).catch(() => null)
  await p.click('[data-test=ws-doc-file-menu-background]').catch(() => null)
  return p.waitForSelector('[data-test=ws-doc-bg-dialog]', { visible: true, timeout: STEP }).then(Boolean, () => false)
}

const THEMES = { white: 'rgb(255, 255, 255)', paper: 'rgb(247, 240, 225)', grey: 'rgb(236, 238, 241)', dark: 'rgb(20, 23, 28)' }

const server = await startServer()
const browser = await launch()
try {
  console.log('-- light app theme: the default page is white')
  const p = await openDoc('light')
  const d0 = await paint(p)
  ok('light: nothing stored, the page is white', d0.theme === 'light' && d0.attr === 'auto' && d0.bg === 'rgb(255, 255, 255)' && d0.stored === null, d0)
  await shot(p, 'light-default')

  ok('light: Background… opens the dialog', await openDialog(p))
  const opts = await p.evaluate(() => [...document.querySelectorAll('[data-test=ws-doc-bg-dialog] [role=radio]')]
    .map((e) => `${e.dataset.test}:${e.getAttribute('aria-checked')}`))
  ok('light: five swatches, Default checked', opts.join() === 'ws-doc-bg-auto:true,ws-doc-bg-white:false,ws-doc-bg-paper:false,ws-doc-bg-grey:false,ws-doc-bg-dark:false', opts)
  await shot(p, 'dialog')

  for (const [id, want] of Object.entries(THEMES)) {
    await p.click(`[data-test=ws-doc-bg-${id}]`).catch(() => null)
    await p.waitForFunction((id) => document.querySelector('[data-test=ws-doc-view]')?.getAttribute('data-doc-bg') === id, { timeout: STEP }, id).catch(() => null)
    const d = await paint(p)
    const still = await p.evaluate(() => Boolean(document.querySelector('[data-test=ws-doc-bg-dialog]')))
    ok(`light: ${id} applies at once and is stored, the dialog stays open`, d.bg === want && d.stored === id && still, d)
    ok(`light: ${id}: the title reads on it (>= 7:1)`, contrast(d.bg, d.fg) >= 7, { ratio: contrast(d.bg, d.fg).toFixed(1), ...d })
  }
  /* the shots with the dialog closed: Done, then reopen for the next */
  await p.click('[data-test=ws-doc-bg-done]').catch(() => null)
  const closed = await p.waitForFunction(() => !document.querySelector('[data-test=ws-doc-bg-dialog]'), { timeout: STEP }).then(() => true, () => false)
  ok('light: Done closes the dialog', closed)
  for (const id of Object.keys(THEMES)) {
    await p.evaluate((id) => localStorage.setItem('spool-qto-doc-bg', id), id)
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=ws-doc-row]', { visible: true, timeout: STEP }).catch(() => null)
    const d = await paint(p)
    ok(`light: ${id} survives a reload`, d.attr === id && d.bg === THEMES[id], d)
    await shot(p, `light-${id}`)
  }
  await p.close()

  console.log('-- dark app theme: the default keeps the dark page, a pick reads the same')
  const q = await openDoc('dark')
  const e0 = await paint(q)
  ok('dark: nothing stored, the page is not white', e0.theme === 'dark' && e0.attr === 'auto' && e0.bg !== 'rgb(255, 255, 255)', e0)
  ok('dark: ... and its title reads (>= 7:1 on the app page)', contrast(await q.evaluate(() => getComputedStyle(document.body).backgroundColor), e0.fg) >= 7, e0)
  await shot(q, 'dark-default')
  ok('dark: Background… opens the dialog', await openDialog(q))
  await q.click('[data-test=ws-doc-bg-white]').catch(() => null)
  await q.waitForFunction(() => document.querySelector('[data-test=ws-doc-view]')?.getAttribute('data-doc-bg') === 'white', { timeout: STEP }).catch(() => null)
  const e1 = await paint(q)
  ok('dark: White makes a white page with dark text (>= 7:1)', e1.bg === 'rgb(255, 255, 255)' && contrast(e1.bg, e1.fg) >= 7, { ratio: contrast(e1.bg, e1.fg).toFixed(1), ...e1 })
  await q.keyboard.press('Escape')
  await q.waitForFunction(() => !document.querySelector('[data-test=ws-doc-bg-dialog]'), { timeout: STEP }).catch(() => null)
  await shot(q, 'dark-white')
  await q.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-doc-background: ${failed} FAILED` : `qto-doc-background: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
