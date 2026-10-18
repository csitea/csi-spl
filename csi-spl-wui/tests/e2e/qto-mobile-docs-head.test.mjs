// Owner HUM-10 (t1 a1b42c34, msg 02749694): the "Documents" title is
// unneeded, the icons go up into one small bar at the top. Qto reading panel plan v1.0 row 01 (SPL-2515): at <= 820 px
// with a document open the /workspace/docs header is ONE strip: it does not
// wrap (<= 46 px tall), the "Documents" heading takes no room (kept for
// screen readers) and the + sits inside the strip instead of floating
// (position: static, not fixed). A desktop keeps its header (one
// <= 70 px row, heading shown: 58..128 px on master c5e1fa432; the plan's
// 115 px is the /docs page).
// Control: on the earlier master at 412x915 and 800x915 the header wraps to
// 2+ rows (>= 88 px), the heading is visible and .wsdocs-fab is fixed, so
// every phone check FAILS.
//
//   node tests/e2e/qto-mobile-docs-head.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/qto-mobile-docs-head.test.mjs
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

/** the header's geometry with a document open */
const measure = (p) => p.evaluate(() => {
  const head = document.querySelector('[data-test=ws-docs-page] .wsdocs-head')
  const h2 = document.querySelector('[data-test=ws-docs-heading]')
  const fab = document.querySelector('[data-test=ws-docs-new]')
  if (!head || !h2 || !fab) return null
  const hb = head.getBoundingClientRect()
  const fb = fab.getBoundingClientRect()
  return {
    headTop: Math.round(hb.top),
    headBottom: Math.round(hb.bottom),
    headH: Math.round(hb.height),
    headOverflow: head.scrollWidth - head.clientWidth,
    pageOverflow: document.documentElement.scrollWidth - window.innerWidth,
    h2H: Math.round(h2.getBoundingClientRect().height),
    h2Pos: getComputedStyle(h2).position,
    h2Text: h2.textContent.trim(),
    fabPos: getComputedStyle(fab).position,
    fabIn: fb.top >= hb.top - 0.5 && fb.bottom <= hb.bottom + 0.5 && fb.left >= hb.left - 0.5 && fb.right <= hb.right + 0.5,
    fabW: Math.round(fb.width),
  }
})

async function openDoc(p, vp) {
  await p.setViewport(vp)
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  /* the first page of a cold dev server compiles for a while */
  await p.waitForSelector('[data-test=ws-docs-page]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const id = await p.waitForFunction(() => window.__wsDocTreeCall?.('GET', '').then((r) => r.docs?.[0]?.id || ''), { timeout: STEP })
    .then((h) => h.jsonValue(), () => '')
  ok(`${vp.width}: the mock lists a document`, Boolean(id), id)
  await p.goto(`${server.base}/workspace/docs?doc=${id}&view=doc`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return p.waitForSelector('[data-test=ws-doc-view]', { visible: true, timeout: STEP }).then(Boolean, () => false)
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ width: 412, height: 915 }, { width: 800, height: 915 }]) {
    console.log(`-- ${vp.width}x${vp.height} phone, a document open`)
    const p = await browser.newPage()
    ok(`${vp.width}: the document view is open`, await openDoc(p, vp))
    const m = await measure(p)
    ok(`${vp.width}: the header is measured`, Boolean(m), m)
    if (m) {
      ok(`${vp.width}: the header is one strip, <= 46 px tall`, m.headH <= 46, m.headH)
      ok(`${vp.width}: nothing in the strip runs past its edge`, m.headOverflow <= 0 && m.pageOverflow <= 0, { head: m.headOverflow, page: m.pageOverflow })
      /* the sr-only pattern: out of the flow, a 1 px box */
      ok(`${vp.width}: the "Documents" heading takes no room`, m.h2Pos === 'absolute' && m.h2H <= 1, { h: m.h2H, pos: m.h2Pos })
      ok(`${vp.width}: ... and stays for screen readers`, m.h2Text.length > 0, m.h2Text)
      ok(`${vp.width}: the + is not floating (position static)`, m.fabPos === 'static', m.fabPos)
      ok(`${vp.width}: the + sits inside the strip`, m.fabIn, m)
    }
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/qto-mobile-head-${vp.width}.png` })
    await p.close()
  }

  console.log('-- 1280x800 desktop, a document open (unchanged)')
  const d = await browser.newPage()
  const vp = { width: 1280, height: 800 }
  ok('1280: the document view is open', await openDoc(d, vp))
  const m = await measure(d)
  ok('1280: the header is measured', Boolean(m), m)
  if (m) {
    /* master c5e1fa432 measured 58..128 (a 70 px row); the row 01 change is phone only */
    ok('1280: the header row is unchanged, one row <= 70 px', m.headH <= 70, { top: m.headTop, bottom: m.headBottom, h: m.headH })
    ok('1280: the "Documents" heading is shown', m.h2H > 0, m.h2H)
    ok('1280: the + sits in the header row', m.fabIn, m)
  }
  await d.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `qto-mobile-docs-head: ${failed} FAILED` : `qto-mobile-docs-head: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
