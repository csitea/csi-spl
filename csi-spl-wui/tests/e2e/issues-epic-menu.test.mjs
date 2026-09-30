// CLE-77800 (owner b82f3853): the epic/feature actions button on the Issues
// title row. On /issues?epic=SPL-1 the epic has no row of its own (the table
// shows only its children), so a right-click can never target it and delete /
// archive "did nothing". The title-row button acts on the epic the view is
// filtered to: Copy link, Archive, Delete (cascade + count confirm). It is
// disabled with a tooltip when the view is not filtered to one epic.
//
//   pnpm run test:e2e:issues-epic-menu
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues-epic-menu
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function newIssue(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
}
const menuUp = (p) => p.$('[data-test=issues-ctxmenu]').then(Boolean)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  // 1) with no epic filter the button is present but disabled, with a tooltip,
  //    and a click opens nothing
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-epic-menu]', { visible: true, timeout: 5000 })
  const off = await p.$eval('[data-test=issues-epic-menu]', (el) => ({ disabled: el.getAttribute('data-disabled'), title: el.getAttribute('title') }))
  ok('1 the actions button is disabled with a tooltip when no epic is selected', off.disabled === 'true' && Boolean(off.title), off)
  await p.click('[data-test=issues-epic-menu]')
  await new Promise((r) => setTimeout(r, 200))
  ok('2 clicking the disabled button opens no menu', !(await menuUp(p)))

  // 2) on the epic-filtered view the button is enabled; create a child so the
  //    cascade has something to remove
  await p.goto(server.base + '/issues?epic=SPL-1', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  const child = await newIssue(p, 'A child under the filtered epic')
  const on = await p.$eval('[data-test=issues-epic-menu]', (el) => el.getAttribute('data-disabled'))
  ok('3 the actions button is enabled on the epic-filtered view', on === null || on === undefined, { disabled: on })

  // 3) the button opens the shared menu, targeting the epic: copy / archive /
  //    delete, but no Open (already the view) and no per-issue status / assign
  await p.click('[data-test=issues-epic-menu]')
  await p.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 5000 })
  const items = await p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
  ok('4 the button menu offers copy, archive, delete - not open / status / assign',
    ['issues-ctxmenu-copy', 'issues-ctxmenu-archive', 'issues-ctxmenu-delete'].every((k) => items.includes(k))
    && !items.includes('issues-ctxmenu-open') && !items.includes('issues-ctxmenu-status') && !items.includes('issues-ctxmenu-assign'), items)

  // 4) Copy link closes the menu without a page error (clipboard itself is an
  //    insecure-origin fallback in headless; the wiring is what we prove)
  await p.click('[data-test=issues-ctxmenu-copy]')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-ctxmenu]'), { timeout: 3000 }).catch(() => {})
  ok('5 Copy link runs and closes the menu', !(await menuUp(p)))

  // 5) Archive the epic from the button: the confirm states the child count and
  //    the cascade removes the child row from the filtered list
  await p.click('[data-test=issues-epic-menu]')
  await p.waitForSelector('[data-test=issues-ctxmenu-archive]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-ctxmenu-archive]')
  await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
  const count = await p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-count'))
  await p.click('[data-testid=issues-cascade-confirm]')
  await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"]`), { timeout: 5000 }, child).catch(() => {})
  const gone = !(await p.$(`[data-test=issues-row][data-key="${child}"]`))
  ok('6 archiving the epic from the button states its count and cascades to the child', Number(count) >= 1 && gone, { count, gone })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('7 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
