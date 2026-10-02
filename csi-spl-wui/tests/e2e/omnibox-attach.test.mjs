// SPL-13 in a real browser, mock tenant.
//
// SPL-13: the Attach button is visible and clickable in the idle Omnibox on
// /, /lobby, /channel/<x> and /dm/<y>, and it comes back after a search: a
// `/search …` line left in the Omnibox kept search mode on every page, and
// search mode renders no Attach.
//
//   pnpm run test:e2e omnibox-attach
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-attach
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const ROUTES = ['/', '/lobby', '/channel/lobby', '/dm/CLE-07%40box-a']
const ATTACH = 'form.omnibox--global [data-testid=attach]'

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

/** Rendered, sized, and the topmost element at its centre (not covered). */
const attachState = (sel) => {
  const form = document.querySelector('form.omnibox--global')
  const e = document.querySelector(sel)
  const text = form?.querySelector('textarea')?.value ?? null
  if (!e) return { form: !!form, attach: false, text }
  const r = e.getBoundingClientRect()
  const top = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)
  const cs = getComputedStyle(e)
  const visible = r.width > 0 && r.height > 0 && cs.visibility === 'visible' && Number(cs.opacity) > 0
    && r.right <= innerWidth && r.bottom <= innerHeight && r.x >= 0 && r.y >= 0
  return { form: true, attach: true, visible, onTop: top === e || e.contains(top), w: Math.round(r.width), h: Math.round(r.height), text }
}

async function clickOpensPicker(p) {
  const [chooser] = await Promise.all([
    p.waitForFileChooser({ timeout: 5000 }).catch(() => null),
    p.click(ATTACH),
  ])
  if (chooser) await chooser.cancel()
  return !!chooser
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  // 1. idle Omnibox on every page: Attach visible, on top, opens the picker
  for (const route of ROUTES) {
    const res = await p.goto(server.base + route, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('form.omnibox--global', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
    const st = await p.evaluate(attachState, ATTACH)
    // a missing button while the omnibox is up is a FAIL, never a skip
    ok(`1 ${route}: Attach visible in the idle omnibox`, res?.status() === 200 && st.form && st.attach && st.visible && st.onTop, { status: res?.status(), ...st })
    ok(`1 ${route}: Attach opens the file picker`, st.attach && await clickOpensPicker(p))
  }

  // 2. after a search, leaving /search brings Attach back
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.click('form.omnibox--global textarea')
  await p.keyboard.type('/search hello')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => /\/search$/.test(location.pathname), { timeout: NAV_TIMEOUT })
  const onSearch = await p.evaluate(attachState, ATTACH)
  ok('2 /search: the omnibox is in search mode (no Attach)', !onSearch.attach && onSearch.text === '/search hello', onSearch)
  // an in-app link, not a reload: a reload would reset the omnibox anyway.
  // CLE-77934: a rail section is built when first opened, so on /search the
  // Channels list (and its lobby link) may not exist yet: then the app's own
  // router makes the same in-app move.
  const left = await p.evaluate(() => {
    const a = document.querySelector('.sidebar a[href$="/channel/lobby"], a[href$="/channel/lobby"]')
    if (a) {
      a.click()
      return 'link'
    }
    const router = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$router
    if (!router) return false
    void router.push('/channel/lobby')
    return 'router'
  })
  await p.waitForFunction(() => /\/channel\/lobby$/.test(location.pathname), { timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForSelector(ATTACH, { visible: true, timeout: 5000 }).catch(() => null)
  const after = await p.evaluate(attachState, ATTACH)
  ok('2 leaving /search clears the search line and Attach is back', left && after.attach && after.visible && after.onTop && after.text === '', { left, ...after })

  // 2b. CONTROL: a send draft survives the same navigation
  await p.click('form.omnibox--global textarea')
  await p.keyboard.type('draft kept')
  await p.evaluate(() => { document.querySelector('a[href$="/lobby"]:not([href$="/channel/lobby"])')?.click() })
  await new Promise((r) => setTimeout(r, 800))
  const draft = await p.evaluate(attachState, ATTACH)
  ok('2b CONTROL: a send draft is not cleared by navigation', draft.text === 'draft kept' && draft.attach, draft)
  await p.evaluate(() => {
    const ta = document.querySelector('form.omnibox--global textarea')
    ta.value = ''
    ta.dispatchEvent(new Event('input', { bubbles: true }))
  })

  ok('3 no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`omnibox-attach: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
