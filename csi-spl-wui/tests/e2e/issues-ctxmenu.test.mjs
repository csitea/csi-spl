// SPL-1226: the Issues right-click / long-press context menu and the cascade
// archive/delete confirm. Mock mode starts with the SPL-1 "random" epic, so a
// row created lands under it; deleting the epic with cascade takes the row too.
//
//   pnpm run test:e2e:issues-ctxmenu
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues-ctxmenu
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
async function rightClick(p, selector) {
  const box = await p.$eval(selector, (el) => { const b = el.getBoundingClientRect(); return { x: b.x + Math.min(40, b.width / 2), y: b.y + b.height / 2 } })
  await p.mouse.click(box.x, box.y, { button: 'right' })
  return box
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })

  const spl2 = await newIssue(p, 'Row under the epic')
  const spl3 = await newIssue(p, 'Second under the epic')
  ok('1 two rows exist under the SPL-1 epic', Boolean(spl2) && Boolean(spl3), { spl2, spl3 })

  // a right-click opens the menu AT the pointer, inside the viewport
  const at = await rightClick(p, `[data-test=issues-row][data-key="${spl2}"]`)
  await p.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 5000 })
  const geo = await p.$eval('[data-test=issues-ctxmenu]', (el) => {
    const b = el.getBoundingClientRect()
    return { left: b.left, top: b.top, right: b.right, bottom: b.bottom, vw: innerWidth, vh: innerHeight, vis: getComputedStyle(el).visibility }
  })
  const items = await p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
  ok('2 the menu opens at the pointer, clamped in the viewport, visible',
    geo.vis === 'visible' && geo.left >= 0 && geo.top >= 0 && geo.right <= geo.vw + 1 && geo.bottom <= geo.vh + 1 && Math.abs(geo.left - at.x) < 60 && Math.abs(geo.top - at.y) < 60, geo)
  ok('3 an issue row menu offers open, status, assign, archive, delete',
    ['issues-ctxmenu-open', 'issues-ctxmenu-status', 'issues-ctxmenu-assign', 'issues-ctxmenu-archive', 'issues-ctxmenu-delete'].every((k) => items.includes(k)), items)

  // Escape closes it
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-ctxmenu]'), { timeout: 3000 }).catch(() => {})
  ok('4 Escape closes the menu', !(await menuUp(p)))

  // Delete a leaf issue: the confirm has no cascade count, and the row goes
  await rightClick(p, `[data-test=issues-row][data-key="${spl2}"]`)
  await p.waitForSelector('[data-test=issues-ctxmenu-delete]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-ctxmenu-delete]')
  await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
  const leafCount = await p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-count'))
  await p.click('[data-testid=issues-cascade-confirm]')
  await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"]`), { timeout: 5000 }, spl2)
  ok('5 deleting a leaf issue asks with no cascade count and removes the row', leafCount === '0' && !(await p.$(`[data-test=issues-row][data-key="${spl2}"]`)), { leafCount })

  // Archive the whole epic from the sidebar: the confirm states the count and
  // the cascade removes the epic's remaining child from the list
  await p.waitForSelector('[data-testid=sidebar-epic][data-key="SPL-1"]', { visible: true, timeout: 5000 })
  await rightClick(p, '[data-testid=sidebar-epic][data-key="SPL-1"]')
  await p.waitForSelector('[data-test=issues-ctxmenu-archive]', { visible: true, timeout: 5000 })
  const epicItems = await p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
  await p.click('[data-test=issues-ctxmenu-archive]')
  await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
  const epicCount = await p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-count'))
  await p.click('[data-testid=issues-cascade-confirm]')
  await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"]`), { timeout: 5000 }, spl3).catch(() => {})
  const childGone = !(await p.$(`[data-test=issues-row][data-key="${spl3}"]`))
  ok('6 an epic menu offers only open, archive, delete', ['issues-ctxmenu-open', 'issues-ctxmenu-archive', 'issues-ctxmenu-delete'].every((k) => epicItems.includes(k)) && !epicItems.includes('issues-ctxmenu-status'), epicItems)
  ok('7 archiving the epic states its issue count and cascades to the child', Number(epicCount) >= 1 && childGone, { epicCount, childGone })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('8 no page errors', mine.length === 0, mine)
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
