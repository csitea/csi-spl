// The tenant drop box, proved in a real browser.
//
// It sits above the Direct messages icon, holds exactly one option, takes
// keyboard focus, and choosing that option does not navigate. Checked at
// 1280x800 and at phone width (390x844), where the sidebar is the 72px rail.
//
// Run:
//   pnpm run test:e2e:tenant-switcher
//   BASE_URL=<generated bundle> pnpm run test:e2e:tenant-switcher
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { applyViewport, setPageViewport, isViewportHarnessError, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VIEWPORTS = [
  { name: '1280x800', width: 1280, height: 800 },
  { name: '390x844', width: 390, height: 844 },
]

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function readBox(p) {
  return p.evaluate(() => {
    const sel = document.querySelector('[data-testid=tenant-switcher-select]')
    const dm = document.querySelector('[data-testid=sidebar-tab-dm]')
    const heading = document.querySelector('[data-testid=sidebar-help-dm]')
    if (!(sel instanceof HTMLSelectElement) || !(dm instanceof HTMLElement)) {
      return { missing: true }
    }
    const er = sel.getBoundingClientRect()
    const dr = dm.getBoundingClientRect()
    const hr = heading instanceof HTMLElement ? heading.getBoundingClientRect() : null
    const sidebar = document.querySelector('.sidebar')
    const sw = sidebar instanceof HTMLElement ? sidebar.getBoundingClientRect().width : 0
    sel.focus()
    return {
      missing: false,
      options: [...sel.options].map((o) => ({ value: o.value, text: (o.textContent || '').trim() })),
      disabled: sel.disabled,
      tabIndex: sel.tabIndex,
      focused: document.activeElement === sel,
      aboveIcon: er.height > 0 && dr.height > 0 && er.bottom <= dr.top + 1,
      aboveHeading: !hr || hr.height < 1 || er.bottom <= hr.top + 1,
      selectWidth: er.width,
      selectHeight: er.height,
      sidebarWidth: sw,
      docOverflow: (document.scrollingElement ? document.scrollingElement.scrollWidth : 0) - window.innerWidth,
      innerWidth: window.innerWidth,
    }
  })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  for (const vp of VIEWPORTS) {
    const tag = vp.name
    try {
      await setPageViewport(p, vp)
      await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, vp)
      await p.waitForSelector('[data-testid=tenant-switcher-select]', { timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV_TIMEOUT })
    } catch (e) {
      ok(tag + ' page ready', false, { error: String(e && e.message || e), harness: isViewportHarnessError(e) })
      continue
    }
    const box = await readBox(p)
    ok(tag + ' one option above the direct-messages icon', box.aboveIcon === true && box.options?.length === 1 && box.options[0].text.length > 0, box)
    ok(tag + ' above the direct-messages heading when that heading is shown', box.aboveHeading === true, box)
    ok(tag + ' keyboard reachable and not disabled', box.focused === true && box.disabled === false && box.tabIndex >= 0, box)
    ok(tag + ' fits the sidebar without page scroll', box.selectWidth > 8 && box.selectWidth <= box.sidebarWidth + 1 && box.docOverflow <= 1, box)
    ok(tag + ' the drop box is compact', box.selectHeight >= 18 && box.selectHeight <= 36 && box.selectWidth <= 160, box)
    const want = process.env.ASSERT_TENANT_LABEL || ''
    if (want) ok(tag + ' option text is ' + want, box.options[0].text === want, box.options)
    const url = p.url()
    const value = box.options[0].value
    await p.focus('[data-testid=tenant-switcher-select]')
    await p.keyboard.press('ArrowDown')
    await p.keyboard.press('Enter')
    if (value !== undefined) {
      await p.select('[data-testid=tenant-switcher-select]', value).catch(() => {})
    }
    const after = await readBox(p)
    ok(tag + ' choosing the option does not navigate', p.url() === url && after.options?.length === 1, { url, now: p.url(), n: after.options?.length })
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
