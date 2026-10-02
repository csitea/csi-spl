// Owner, t1 ae24a0ef (2026-10-02): "The border goes inside the white area of
// the text box and it should be just outside the white area of the text box"
// and "fix this both on mobile and on desktop".
//
// The white is .omnibox-field (background --color-composer, 1px border). The
// focus ring was the textarea's :focus-visible outline, and the textarea sits
// inside the field's 8px inline padding, so white showed outside the ring.
// The ring now IS the field's border while its textarea holds the focus.
//
// For the FOCUSED message box, desktop 1440x900 and phone 390x844, dark and
// light, every element of the field (the field itself and the textarea) that
// draws an edge in the --focus-ring colour (an outline, or a border) is
// collected:
//   1 exactly ONE such edge, and it is the field's own border (one ring, owner
//     focus rule: one colour, at most 3 px)
//   2 its outer box equals the white field's outer box (no white outside it)
//   3 the textarea draws no outline of its own (no second, inner ring)
//   CONTROL: before the fix 1-3 fail - the one ring is the textarea outline,
//   8 px inside the field on both inline sides.
//
// Run:
//   pnpm run test:e2e omnibox-focus-ring
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-focus-ring   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
if (SHOTS) mkdirSync(SHOTS, { recursive: true })
const MOCK_SESSION = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Focus the visible box's textarea, then list every focus-ring edge in its field. */
function ring(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    const field = f && f.querySelector('.omnibox-field')
    const ta = f && f.querySelector('textarea')
    if (!field || !ta) return null
    ta.focus()
    /* the resolved --focus-ring colour, as the browser serialises colours */
    const probe = document.createElement('span')
    probe.style.color = 'var(--focus-ring)'
    document.body.appendChild(probe)
    const focusColor = getComputedStyle(probe).color
    probe.remove()
    const px = (v) => parseFloat(v) || 0
    const box = (r) => ({ l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) })
    const edges = []
    for (const [name, el] of [['field', field], ['textarea', ta]]) {
      const cs = getComputedStyle(el)
      const r = el.getBoundingClientRect()
      if (cs.outlineStyle !== 'none' && px(cs.outlineWidth) > 0 && cs.outlineColor === focusColor) {
        const o = px(cs.outlineOffset) + px(cs.outlineWidth)
        edges.push({ el: name, kind: 'outline', w: px(cs.outlineWidth), box: box({ left: r.left - o, top: r.top - o, right: r.right + o, bottom: r.bottom + o }) })
      }
      const sides = ['Top', 'Right', 'Bottom', 'Left']
      if (sides.every((s) => cs[`border${s}Style`] !== 'none' && px(cs[`border${s}Width`]) > 0 && cs[`border${s}Color`] === focusColor)) {
        edges.push({ el: name, kind: 'border', w: px(cs.borderTopWidth), box: box(r) })
      }
    }
    const tcs = getComputedStyle(ta)
    return {
      active: document.activeElement === ta,
      focusColor,
      white: box(field.getBoundingClientRect()),
      edges,
      taOutline: tcs.outlineStyle === 'none' || px(tcs.outlineWidth) === 0 ? null : `${tcs.outlineWidth} ${tcs.outlineStyle}`,
    }
  })
}

async function check(browser, vp, theme, tag) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s, th) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
      localStorage.setItem('spool-theme', th)
    } catch { /* private mode */ }
  }, MOCK_SESSION, theme)
  await p.setViewport(vp)
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.composer.omnibox--global .omnibox-field', { timeout: NAV_TIMEOUT })
  const r = await ring(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `omnibox-focus-ring-${tag.replace(/ /g, '-')}.png`) })
  const e = r ? r.edges : []
  ok(`${tag} 1 the box is focused and draws exactly ONE ring, the field's own border, <= 3 px`,
    Boolean(r && r.active && e.length === 1 && e[0].el === 'field' && e[0].kind === 'border' && e[0].w <= 3), r)
  ok(`${tag} 2 the ring's outer box IS the white field's outer box (no white outside it)`,
    Boolean(r && e.length === 1 && ['l', 't', 'r', 'b'].every((k) => e[0].box[k] === r.white[k])), r && { ring: e.map((x) => x.box), white: r.white })
  ok(`${tag} 3 the textarea draws no outline of its own (no inner ring)`, Boolean(r && r.taOutline === null), r && r.taOutline)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  const warm = await browser.newPage()
  await warm.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await warm.close()
  for (const theme of ['dark', 'light']) {
    await check(browser, { width: 1440, height: 900 }, theme, `1440 ${theme}`)
    await check(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, theme, `390 ${theme}`)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
