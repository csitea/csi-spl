// SPL-2123 (perf round 6, row 01): the closed user menu mounts no panel DOM.
//
// The dropdown panel ([data-test=user-menu-panel]) was v-show: every signed-in
// route painted it hidden (45 nodes at 1440 px, 56 at 390 px on 2026-10-16).
// It is v-if now, so the closed menu has 0 panel nodes, and the trigger names
// the panel in aria-controls only while it is open. The menu still opens on a
// click and on ArrowDown (first item focused), ArrowUp focuses the last item,
// and Escape closes it and gives focus back to the button.
//
// Run:
//   node tests/e2e/user-menu-lazy-mount.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/user-menu-lazy-mount.test.mjs
// Starts `nuxi dev` with the mock tenant when BASE_URL is unset. The mock
// has no session, so the test signs a member in through the session store
// (adopt), the same call a native sign-in makes.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const PANEL = '[data-test=user-menu-panel]'
const TRIGGER = '[data-test=user-menu-trigger]'
const results = []
function check(name, pass, ev) {
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

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** panel element count (the panel and its descendants), the trigger's aria, the focused test id */
const state = (p) => p.evaluate((panel, trigger) => {
  const el = document.querySelector(panel)
  const btn = document.querySelector(trigger)
  return {
    nodes: el ? el.querySelectorAll('*').length + 1 : 0,
    controls: btn?.getAttribute('aria-controls') ?? null,
    expanded: btn?.getAttribute('aria-expanded') ?? null,
    focus: document.activeElement?.getAttribute('data-test') ?? null,
    panelId: el?.id ?? null,
  }
}, PANEL, TRIGGER)

async function run(p, base, width, touch) {
  const tag = `${width}px`
  await p.setViewport({ width, height: 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/lobby`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector(TRIGGER)
  await sleep(400)

  const closed = await state(p)
  check(`${tag}: RED CONTROL the closed menu has 0 panel DOM nodes`, closed.nodes === 0, closed)
  check(`${tag}: the closed trigger has no aria-controls, aria-expanded=false`, closed.controls === null && closed.expanded === 'false', closed)

  await p.click(TRIGGER)
  await p.waitForSelector(PANEL, { visible: true, timeout: 5000 }).catch(() => {})
  await sleep(200)
  const opened = await state(p)
  check(`${tag}: a click mounts the panel, focus on the first item`, opened.nodes > 0 && opened.focus === 'user-menu-settings', opened)
  check(`${tag}: the open trigger names the panel in aria-controls`, opened.controls === opened.panelId && opened.panelId === 'user-menu-panel' && opened.expanded === 'true', opened)

  await p.keyboard.press('Escape')
  await sleep(200)
  const shut = await state(p)
  check(`${tag}: Escape unmounts the panel and focuses the button`, shut.nodes === 0 && shut.focus === 'user-menu-trigger' && shut.controls === null, shut)

  await p.keyboard.press('ArrowUp')
  await sleep(300)
  const last = await state(p)
  check(`${tag}: ArrowUp opens on the last item (Sign out)`, last.nodes > 0 && last.focus === 'user-menu-signout', last)
  await p.keyboard.press('ArrowDown')
  await sleep(200)
  const wrap = await state(p)
  check(`${tag}: ArrowDown wraps to the first item`, wrap.focus === 'user-menu-settings', wrap)
  await p.keyboard.press('Escape')
  await sleep(200)

  await p.focus(TRIGGER)
  await p.keyboard.press('ArrowDown')
  await sleep(300)
  const down = await state(p)
  check(`${tag}: ArrowDown on the button opens on the first item`, down.nodes > 0 && down.focus === 'user-menu-settings', down)
  /* a click outside closes it (desktop: the page; phone: the scrim above
     the bottom sheet, near the top) */
  await p.mouse.click(Math.round(width / 2), touch ? 40 : 450)
  await sleep(300)
  const out = await state(p)
  check(`${tag}: a click outside unmounts the panel`, out.nodes === 0 && out.expanded === 'false', out)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  await run(p, server.base, 1440, false)
  await run(p, server.base, 390, true)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nuser-menu-lazy-mount: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
