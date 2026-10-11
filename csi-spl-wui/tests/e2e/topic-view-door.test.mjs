// t1 e4bfddb1 (c-201, 2026-10-11): after the Topics view went, /t/<id> no
// longer showed the view-token door prompt: it came from the removed Topics
// list's load (viewer.loadTopics). A signed-in member whose session does not
// open the hub's view door (view-v1 section 2, a 401 view_door) opening
// /t/<id> gets the door prompt again (ViewTokenForm), not an empty or failed
// thread; a view token opens the thread in place. Signed-out visitors go to
// the login landing before any of this (68c36a36e).
//
// The mock stands in for the hub's door: localStorage `spool.mock.view-door`
// ({ detail }) makes its topic read answer 401 view_door until a view token
// is set (spool-client-mock.mjs mockGetTopic).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-view-door
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 390, height: 844 }, { width: 1440, height: 900 }]
const TASK = '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e'
const EXTRA = [
  { v: 1, msg_id: TASK, task_id: TASK, ts: '2026-09-18T11:00:00Z', from: 'GRK-03', from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind: 'note', body: 'the door topic opener', channel: 'alerts', parent_task_id: null, files: [] },
]
const DOOR = '[data-testid=view-door]'
const CARD = `[data-test=topic-browse-thread] .msg[data-msg-id="${TASK}"]`

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

/* a signed-in member (the mock session); door = the hub's 401 detail, or null for an open door */
async function fresh(browser, size, door) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra, d) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      if (d) localStorage.setItem('spool.mock.view-door', JSON.stringify(d))
    } catch { /* about:blank */ }
  }, EXTRA, door)
  await setPageViewport(p, size)
  return { ctx, p, errors }
}

/* the element is drawn: in the DOM and with a box (a hidden phone level has none) */
function shown(p, sel) {
  return p.evaluate((s) => [...document.querySelectorAll(s)].some((e) => e.getBoundingClientRect().width > 0), sel)
}

const pageErrors = (errors) => errors.filter((e) => !/dynamically imported module/.test(e))

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`

    /* 1. the door is closed to this member: the prompt, not the thread */
    {
      const { ctx, p, errors } = await fresh(browser, size, { detail: 'a view token or a member session is required' })
      await p.goto(server.base + '/t/' + TASK, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(DOOR, { visible: true, timeout: 15000 }).catch(() => {})
      ok(`${tag} closed door: /t/<id> shows the view-token door prompt`, await shown(p, DOOR))
      ok(`${tag} closed door: the prompt offers the token field`, await shown(p, `${DOOR} input[type=password]`))
      ok(`${tag} closed door: no thread card behind it`, !(await shown(p, CARD)))
      ok(`${tag} closed door: the page stays on /t/<id>`, new URL(p.url()).pathname.endsWith('/t/' + TASK), p.url())

      /* 2. a view token opens the thread in place */
      await p.type(`${DOOR} input[type=password]`, 'vt-example-token')
      await p.click(`${DOOR} button[type=submit]`)
      await p.waitForSelector(CARD, { visible: true, timeout: 15000 }).catch(() => {})
      ok(`${tag} token: the thread opens`, await shown(p, CARD))
      ok(`${tag} token: the prompt goes`, !(await shown(p, DOOR)))
      ok(`${tag} closed door: no page error`, pageErrors(errors).length === 0, errors)
      await ctx.close()
    }

    /* 3. the door is open to this member (the usual case): no prompt */
    {
      const { ctx, p, errors } = await fresh(browser, size, null)
      await p.goto(server.base + '/t/' + TASK, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(CARD, { visible: true, timeout: 15000 }).catch(() => {})
      ok(`${tag} open door: the thread shows`, await shown(p, CARD))
      ok(`${tag} open door: no door prompt`, !(await shown(p, DOOR)))
      ok(`${tag} open door: no page error`, pageErrors(errors).length === 0, errors)
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-view-door: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
