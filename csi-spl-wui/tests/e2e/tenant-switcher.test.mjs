// The tenant drop box, proved in a real browser.
//
// It sits above the Direct messages icon, holds exactly one option, takes
// keyboard focus, and choosing that option does not navigate. Checked at
// 1280x800 and at phone width (390x844), where the sidebar is the 72px rail.
// CLE-34991: one slim row with no visible caption; hovering it shows the
// explanation (the wrapper's title), which names the tenant.
// SPL-71: a drop box - the name and the arrow sit inside one bordered box,
// and a press on the arrow focuses the select as a press on the name does.
//
// Run:
//   pnpm run test:e2e:tenant-switcher
//   BASE_URL=<generated bundle> pnpm run test:e2e:tenant-switcher
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { applyViewport, setPageViewport, isViewportHarnessError, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { tenantNameArrowGapPx } from '../../src/utils/tenant-switcher.mjs'

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
    const wrap = document.querySelector('[data-testid=tenant-switcher]')
    const wr = wrap instanceof HTMLElement ? wrap.getBoundingClientRect() : null
    const label = sel.options[sel.selectedIndex] ? (sel.options[sel.selectedIndex].textContent || '').trim() : ''
    const arrow = document.querySelector('[data-testid=tenant-switcher-arrow]')
    const cs = getComputedStyle(sel)
    const probe = document.createElement('span')
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:nowrap;padding:0;margin:0;border:0;'
    probe.style.font = cs.font
    probe.style.letterSpacing = cs.letterSpacing
    probe.style.wordSpacing = cs.wordSpacing
    probe.style.textTransform = cs.textTransform
    probe.style.fontKerning = cs.fontKerning
    probe.style.fontFeatureSettings = cs.fontFeatureSettings
    probe.style.fontVariant = cs.fontVariant
    document.body.appendChild(probe)
    const drawn = [...sel.options].map((o) => o.textContent || '')
    const widths = drawn.map((text) => { probe.textContent = text; return probe.getBoundingClientRect().width })
    probe.remove()
    const widest = widths.length ? Math.max(...widths) : 0
    const ar = arrow instanceof Element ? arrow.getBoundingClientRect() : null
    const field = document.querySelector('[data-testid=tenant-switcher-box]')
    const fr = field instanceof HTMLElement ? field.getBoundingClientRect() : null
    const fcs = field instanceof HTMLElement ? getComputedStyle(field) : null
    const edges = fcs ? ['Top', 'Right', 'Bottom', 'Left'].map((e) => parseFloat(fcs['border' + e + 'Width']) || 0) : []
    const inside = (r) => !!(fr && r && r.left >= fr.left - 0.5 && r.right <= fr.right + 0.5 && r.top >= fr.top - 0.5 && r.bottom <= fr.bottom + 0.5)
    sel.focus()
    return {
      missing: false,
      wrapHeight: wr ? wr.height : 0,
      captionText: wrap instanceof HTMLElement ? [...wrap.childNodes].filter((n) => {
        if (n instanceof Element && (n.classList.contains('sr-only') || n === sel || n.contains(sel))) return false
        if (n instanceof Element && n.getAttribute('data-testid') === 'tenant-switcher-arrow') return false
        return true
      }).map((n) => (n.textContent || '').trim()).join('') : '?',
      hint: wrap instanceof HTMLElement ? wrap.title : '',
      label,
      ariaLabel: sel.getAttribute('aria-label') || '',
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
      widest,
      padStart: parseFloat(cs.paddingInlineStart) || 0,
      selLeft: er.left,
      selRight: er.right,
      arrowLeft: ar ? ar.left : NaN,
      arrowRight: ar ? ar.right : NaN,
      direction: cs.direction,
      styledWidth: sel.style.width,
      boxBorders: edges,
      boxBorderStyle: fcs ? fcs.borderTopStyle : '',
      boxBorderColor: fcs ? fcs.borderTopColor : '',
      nameAndArrowInBox: inside(er) && inside(ar),
      arrowCenter: ar ? { x: ar.left + ar.width / 2, y: ar.top + ar.height / 2 } : null,
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
      await p.waitForFunction(() => {
        const sel = document.querySelector('[data-testid=tenant-switcher-select]')
        return sel instanceof HTMLSelectElement && sel.style.width.length > 0
      }, { timeout: NAV_TIMEOUT })
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
    ok(tag + ' no visible caption, one slim row', box.captionText === '' && box.wrapHeight > 0 && box.wrapHeight <= 28 && box.ariaLabel.length > 0, box)
    ok(tag + ' hovering explains the tenant, naming it', box.hint.length > 40 && !box.hint.includes('sidebar.') && (!box.label || box.hint.includes(box.label)), box)
    const nameGap = tenantNameArrowGapPx({
      selLeft: box.selLeft, selRight: box.selRight, padStartPx: box.padStart, widestPx: box.widest,
      arrowLeft: box.arrowLeft, arrowRight: box.arrowRight, direction: box.direction,
    })
    ok(tag + ' SPL-980 2px of the box before and after the name', box.padStart === 2 && Math.abs(parseFloat(box.styledWidth) - box.widest - 4) < 0.05, { padStart: box.padStart, styledWidth: box.styledWidth, widest: box.widest })
    ok(tag + ' the arrow sits 3px after the widest name', Number.isFinite(nameGap) && Math.abs(nameGap - 3) <= 0.5, { gap: nameGap, widest: box.widest, styledWidth: box.styledWidth })
    ok(tag + ' SPL-71 a drop box: a bordered box holds the name and the arrow',
      box.boxBorders?.length === 4 && box.boxBorders.every((w) => w >= 1) && box.boxBorderStyle === 'solid'
        && !/rgba\(\d+, \d+, \d+, 0\)|transparent/.test(box.boxBorderColor) && box.nameAndArrowInBox === true,
      { borders: box.boxBorders, style: box.boxBorderStyle, color: box.boxBorderColor, inBox: box.nameAndArrowInBox })
    if (box.arrowCenter) {
      await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
      await p.mouse.click(box.arrowCenter.x, box.arrowCenter.y)
      const focusedByArrow = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') || '')
      await p.keyboard.press('Escape')
      ok(tag + ' SPL-71 a press on the arrow opens the drop box (focuses the select)', focusedByArrow === 'tenant-switcher-select', { focusedByArrow })
    } else {
      ok(tag + ' SPL-71 a press on the arrow opens the drop box (focuses the select)', false, { arrow: 'missing' })
    }
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
