// CLE-3429 — in a real browser, the shell shows at most ONE thread section.
//
// The bug: layouts/default.vue mounted <ThreadPane /> and <LiveThreadPane />
// side by side, each with its own v-if over its own pinia store. The stores
// are not reset on a route change, so arming one while the other was armed
// put two `aside.thread` sections on screen — and they stayed for every later
// route. Measured on this harness before the fix (mock tenant, nuxi dev):
//   /channel/lobby, open a thread          -> 1
//   SPA-nav to /lobby, open a thread there -> 2   <- the owner's report
//   SPA-nav to /                           -> 2
//
// This gate walks the reproduced transitions and asserts the DOM count of
// [data-test=thread-section] is never above 1, and is exactly 1 whenever a
// thread is open — at desktop AND mobile width, in both themes, and across
// a divider resize.
//
// Sections are opened through the page's own pinia stores, which is what the
// click handlers themselves call (MessageFeed -> thread.openThread, the /
// and /lobby rows -> useLiveFeed('pane').open). Driving the store is the same
// pattern scroll-anchor.test.mjs uses, and it removes the dependence on which
// mock fixture happens to carry a clickable reply button.
//
// Run:
//   pnpm test:e2e:thread-pane
//   BASE_URL=https://dev.<domain> pnpm test:e2e:thread-pane
//   OUT=/var/tmp/CLE-3429-proof pnpm test:e2e:thread-pane   # screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { applyViewport, setPageViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TASK_A = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TASK_B = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'

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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** The shell's own stores, reached the way the page's click handlers reach them. */
const drive = (p, fn, arg) => p.evaluate((fn, arg) => {
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const pinia = app?.config?.globalProperties?.$pinia
  if (!pinia) return 'no-pinia'
  const live = pinia._s.get('live-pane')
  const thread = pinia._s.get('thread')
  if (!live || !thread) return 'no-store'
  if (fn === 'openLive') void live.open(arg)
  if (fn === 'closeLive') live.close()
  if (fn === 'openChannel') thread.openThread(arg)
  if (fn === 'closeChannel') thread.close()
  return 'ok'
}, fn, arg)

/** What the reader actually sees: how many thread sections are in the DOM. */
const sections = (p) => p.evaluate(() => {
  const byHook = [...document.querySelectorAll('[data-test=thread-section]')]
  return {
    n: byHook.length,
    /* the class the CSS styles, in case a pane ever loses the hook */
    byClass: document.querySelectorAll('aside.thread').length,
    which: byHook.map((el) => el.getAttribute('data-section')),
    path: location.pathname + location.search,
  }
})

/** SPA navigation through the shell's own links — a full load would reset the stores. */
async function spaNav(p, href) {
  const went = await p.evaluate((href) => {
    const a = [...document.querySelectorAll('a')].find((el) => (el.getAttribute('href') || '').replace(/\/+$/, '') === href.replace(/\/+$/, ''))
    if (!a) return false
    a.click()
    return true
  }, href)
  await sleep(1200)
  return went
}

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)

  for (const vp of [{ name: 'desktop 1280x800', width: 1280, height: 800 }, { name: 'mobile 390x844', width: 390, height: 844 }]) {
    await setPageViewport(page, vp)
    await page.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
    await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await applyViewport(page, vp)
    await sleep(1200)

    const seen = []
    const step = async (label) => {
      const s = await sections(page)
      seen.push({ label, ...s })
      ok(`${vp.name} — ${label}: ${s.n} thread section(s) ${JSON.stringify(s.which)}`, s.n <= 1 && s.byClass <= 1, s.n > 1 ? s : undefined)
      return s
    }

    await step('/channel/lobby, nothing open')

    /* 1. a channel thread — the store MessageFeed's @open-thread calls */
    await drive(page, 'openChannel', TASK_A)
    await sleep(800)
    let s = await step('opened a thread on /channel/lobby')
    ok(`${vp.name} — the channel thread is the section on screen`, s.n === 1 && s.which[0] === 'channel', s.which)

    /* 2. route change must not add one: the stores survive an SPA nav */
    await spaNav(page, '/lobby')
    await step('SPA-nav to /lobby with the channel thread still open')

    /* 3. open a live-pane thread there — this is where the second aside appeared */
    await drive(page, 'openLive', TASK_A)
    await sleep(1200)
    s = await step('opened a thread from the /lobby rows (the reported bug)')
    ok(`${vp.name} — the live pane replaced the channel thread, it did not join it`, s.n === 1 && s.which[0] === 'live', s.which)
    if (OUT) await page.screenshot({ path: `${OUT}/e2e-one-section-${vp.width}.png` })

    /* 4. carry on through the routes the owner named */
    await spaNav(page, '/')
    await step('SPA-nav to /')
    await spaNav(page, '/channel/lobby')
    await step('SPA-nav back to /channel/lobby')

    /* 5. and back the other way: a channel thread must outrank a stale live pane */
    await drive(page, 'openChannel', TASK_B)
    await sleep(800)
    s = await step('opened a channel thread while the live pane was still armed')
    ok(`${vp.name} — the section the reader opened LAST is the one shown`, s.n === 1 && s.which[0] === 'channel', s.which)

    /* 6. rapid alternating clicks — no frame may leave two behind */
    for (let i = 0; i < 6; i++) {
      await drive(page, i % 2 ? 'openChannel' : 'openLive', i % 2 ? TASK_B : TASK_A)
      await sleep(120)
    }
    await sleep(900)
    await step('after 6 rapid alternating opens')

    /* 7. a divider resize must not duplicate the pane (GRK-3366's --thread-w) */
    await page.evaluate(() => {
      const d = document.querySelector('[data-testid=pane-divider-thread]')
      if (!d) return
      d.focus()
    })
    await page.keyboard.press('ArrowLeft')
    await page.keyboard.press('ArrowLeft')
    await sleep(600)
    await step('after a divider resize')

    /* 8. both themes */
    for (const theme of ['dark', 'light']) {
      await page.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await sleep(300)
      await step(`in the ${theme} theme`)
    }

    /* 9. closing leaves none, and reopening leaves one */
    await drive(page, 'closeChannel')
    await drive(page, 'closeLive')
    await sleep(800)
    s = await step('after closing both')
    ok(`${vp.name} — closing everything leaves no thread section`, s.n === 0, s)

    const worst = Math.max(...seen.map((x) => Math.max(x.n, x.byClass)))
    ok(`${vp.name} — the 1..1 invariant held over ${seen.length} states (worst count ${worst})`, worst <= 1, worst > 1 ? seen.filter((x) => x.n > 1) : undefined)
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nthread-pane-single: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
