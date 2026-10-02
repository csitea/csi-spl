// Flow in the LEFT panel (topic 635f8072), proved in a REAL browser. The owner:
// "the short things should flow in the left most panel and then open the
// correct topic msg and thread msg from each flow entry"; "the list of the
// agent there, they do not have place there, their direct msgs, yes".
//
// Against the mock bundle: the Flow tab holds one entry per message, newest
// first (8888... on top), the agent DM 7777... (GRK-03) is an entry, and no
// channel / agent / topic row is left in the panel. A click opens the
// message's channel (6666... -> #alerts) and the list stays, with that entry
// selected; ArrowDown moves the selection, Enter opens it. On a phone the
// list is the screen, a tap opens the place, Back returns to the list with
// the same entry selected and the same scroll. 1440x900 and 390x844, light
// and dark.
//
// Run:
//   pnpm run test:e2e flow-left
//   BASE_URL=<generated bundle> pnpm run test:e2e flow-left     # what CI does
//   SHOT_DIR=/tmp/shots ...                                      # keep the screenshots
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const NEWEST = '88888888-8888-4888-8888-888888888888'
const ALERT = '66666666-6666-4666-8666-666666666666'
const DM = '77777777-7777-4777-8777-777777777777'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const THEMES = ['light', 'dark']
const LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const entry = (id) => `${LIST} [data-testid=left-entry][data-msg-id="${id}"]`

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

/** The Flow panel as the reader sees it. */
function facts(page) {
  return page.evaluate((list) => {
    const panel = document.querySelector('[data-testid=sidebar-panel-flow]')
    const box = document.querySelector(list)
    const rows = box ? [...box.querySelectorAll('[data-testid=left-entry]')] : []
    const shell = document.querySelector('.spool-shell')
    const scroller = box ? box.closest('.sidebar-scroll') : null
    const r = box ? box.getBoundingClientRect() : null
    return {
      shown: Boolean(r && r.width > 0 && r.height > 0 && panel && panel.offsetParent !== null),
      ids: rows.map((e) => e.getAttribute('data-msg-id')),
      selected: rows.filter((e) => e.getAttribute('aria-selected') === 'true').map((e) => e.getAttribute('data-msg-id')),
      oldRows: panel ? panel.querySelectorAll('.nav-row, .nav-item').length : -1,
      level: shell ? shell.getAttribute('data-mobile-level') : null,
      path: location.pathname,
      scrollTop: scroller ? scroller.scrollTop : -1,
      clipped: rows.some((e) => e.scrollWidth > e.clientWidth + 1),
    }
  }, LIST)
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const phone = size.width <= 820
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.flow-scope', 'all'); localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
    await setPageViewport(p, size)
    /* warm the dev server's dynamic imports (a cold nuxi dev drops the first one) */
    /* `/` opens at level 1 on a phone: the section chooser + its list */
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: NAV_TIMEOUT })
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForSelector(entry(DM), { visible: true, timeout: NAV_TIMEOUT })

    let f = await facts(p)
    ok(`${tag}: Flow is the shared left list, one entry per message, newest first`, f.shown && f.ids[0] === NEWEST && f.ids.length >= 8, f)
    ok(`${tag}: the agent's DM is an entry`, f.ids.includes(DM), f.ids)
    ok(`${tag}: no channel / agent / topic row is left in the Flow panel`, f.oldRows === 0, f.oldRows)
    ok(`${tag}: entries are one line each, nothing pushes past the panel`, !f.clipped, f)
    for (const theme of THEMES) {
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      if (process.env.SHOT_DIR) {
        mkdirSync(process.env.SHOT_DIR, { recursive: true })
        await p.screenshot({ path: join(process.env.SHOT_DIR, `flow-left-${tag}-${theme}.png`) })
      }
    }

    /* a click opens the original place; the list stays with the entry selected */
    const before = (await facts(p)).scrollTop
    await p.click(entry(ALERT))
    await p.waitForFunction(() => location.pathname.endsWith('/channel/alerts'), { timeout: NAV_TIMEOUT })
    f = await facts(p)
    ok(`${tag}: a click opens #alerts`, f.path.endsWith('/channel/alerts'), f.path)
    const lit = await p.waitForFunction((id) => document.querySelector(`.msg[data-msg-id="${id}"].open-focus`), { timeout: 10000 }, ALERT).then(() => true, () => false)
    ok(`${tag}: the message is highlighted in its place`, lit)
    if (phone) {
      ok(`${tag}: phone - the place is the screen, not the list`, f.level === '2' || f.level === '3', f.level)
      /* Back walks the stack down to the list (the thread first, when one opened) */
      for (let i = 0; i < 3 && (await facts(p)).level !== '1'; i++) {
        await p.goBack({ timeout: NAV_TIMEOUT }).catch(() => {})
        await new Promise((r) => setTimeout(r, 400))
      }
      await p.waitForFunction(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === '1', { timeout: NAV_TIMEOUT })
      f = await facts(p)
      ok(`${tag}: phone - Back returns to the Flow list, same entry selected, same scroll`,
        f.shown && f.selected[0] === ALERT && f.scrollTop === before, { selected: f.selected, scrollTop: f.scrollTop, before, level: f.level })
    } else {
      ok(`${tag}: the Flow list stays beside the place, that entry selected`, f.shown && f.selected.length === 1 && f.selected[0] === ALERT, f.selected)
    }

    /* keyboard: ArrowDown moves the selection, Enter opens it */
    await p.focus(LIST)
    await p.keyboard.press('ArrowDown')
    f = await facts(p)
    const next = f.ids[f.ids.indexOf(ALERT) + 1]
    ok(`${tag}: ArrowDown selects the next entry`, f.selected[0] === next, { selected: f.selected, next })
    await p.keyboard.press('ArrowUp')
    f = await facts(p)
    ok(`${tag}: ArrowUp selects it back`, f.selected[0] === ALERT, f.selected)
    await p.keyboard.press('ArrowDown')
    await p.keyboard.press('Enter')
    /* the next entry (5555...) is a reply in #lobby: Enter opens it in #lobby
       (the thread and the highlight are openMessage's, proved by its own suite) */
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: NAV_TIMEOUT })
    f = await facts(p)
    ok(`${tag}: Enter opens the selected entry in its place (#lobby), the entry stays selected`, f.path.endsWith('/channel/lobby') && f.selected[0] === next, { path: f.path, selected: f.selected, next })
    if (!phone) {
      /* FlowList hands the focus back after openMessage resolves, which is
         after the path changed: wait for it, do not sample the gap (CI is
         slower than a desk, and read the gap as a loss on every run) */
      const kept = await p.waitForFunction(() => Boolean(document.activeElement && document.activeElement.closest('[data-testid=left-list]')), { timeout: 5000 })
        .then(() => true).catch(() => false)
      ok(`${tag}: the keyboard stays on the list after Enter`, kept)
    }

    ok(`${tag}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
