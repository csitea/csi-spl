// SPL-1226: the Issues right-click / long-press context menu and the cascade
// archive/delete confirm. Mock mode starts with the SPL-1 "random" epic, so a
// row created lands under it; deleting the epic with cascade takes the row too.
//
//   pnpm run test:e2e issues-ctxmenu
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-ctxmenu
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rowSel = (k) => `[data-test=issues-row][data-key="${k}"]`
/* HUM-10 (t1 aedca86a, d8f61702): a Shift + letter on the selected issue row */
async function shiftKey(p, letter) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('Key' + letter)
  await p.keyboard.up('Shift')
}
async function cascadeAsked(p) {
  return p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 3000 })
    .then(() => p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-key')), () => '')
}
async function cancelCascade(p) {
  const btn = await p.$('[data-testid=issues-cascade-cancel]')
  if (btn) await btn.click()
  await p.waitForFunction(() => !document.querySelector('[data-testid=issues-cascade-confirm]'), { timeout: 3000 }).catch(() => {})
}
/* a one-finger drag on the phone (CDP touch, the swipe-archive suite's way) */
async function drag(p, x, y, dx, steps = 12) {
  const cdp = await p.target().createCDPSession()
  const at = (px) => [{ x: Math.round(px), y: Math.round(y), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(x) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(x + (dx * i) / steps) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
}
async function cardBox(p, key) {
  return p.$eval(`[data-test=issues-card][data-key="${key}"]`, (el) => { const b = el.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height } })
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
    geo.vis === 'visible' && geo.left >= 0 && geo.top >= 0 && geo.right <= geo.vw + 1 && geo.bottom <= geo.vh + 1 && Math.abs(geo.left - at.x) < 60
      /* a menu taller than the room under the pointer is clamped up into the viewport */
      && (at.y + (geo.bottom - geo.top) > geo.vh ? geo.top < at.y : Math.abs(geo.top - at.y) < 60), { ...geo, at })
  ok('3 an issue row menu offers open, status, assign, archive, delete',
    ['issues-ctxmenu-open', 'issues-ctxmenu-status', 'issues-ctxmenu-assign', 'issues-ctxmenu-archive', 'issues-ctxmenu-delete'].every((k) => items.includes(k)), items)

  // Escape closes it
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-ctxmenu]'), { timeout: 3000 }).catch(() => {})
  ok('4 Escape closes the menu', !(await menuUp(p)))

  // HUM-10 (t1 aedca86a): the row menu carries what fits from the other
  // lists' menus (copy link, move, priority, label, open parent) and shows
  // the message keys as hints
  await rightClick(p, rowSel(spl3))
  await p.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 5000 })
  const full = await p.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => [e.getAttribute('data-test'), e.getAttribute('aria-keyshortcuts') || '']))
  const hint = Object.fromEntries(full)
  ok('4a the issue row menu also offers copy link and move',
    ['issues-ctxmenu-copy', 'issues-ctxmenu-move'].every((k) => k in hint), full)
  ok('4b its entries name the message keys: archive Shift+A, delete Shift+D, copy link Shift+L, open Shift+O, edit Shift+E, move Shift+M',
    hint['issues-ctxmenu-archive'] === 'Shift+A' && hint['issues-ctxmenu-delete'] === 'Shift+D' && hint['issues-ctxmenu-copy'] === 'Shift+L'
      && hint['issues-ctxmenu-open'] === 'Shift+O' && hint['issues-ctxmenu-edit'] === 'Shift+E' && hint['issues-ctxmenu-move'] === 'Shift+M', hint)
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-ctxmenu]'), { timeout: 3000 }).catch(() => {})

  // the selected row takes the message keys (owner d8f61702: "Shift+A should do archive")
  await p.evaluate(() => { window.__copied = []; try { navigator.clipboard.writeText = async (t) => { window.__copied.push(String(t)) } } catch { /* read-only */ } })
  await p.$eval(rowSel(spl3), (el) => el.focus())
  const selKey = await p.$eval('[data-test=issues-row][data-selected=true]', (el) => el.getAttribute('data-key')).catch(() => '')
  await shiftKey(p, 'A')
  const archAsk = await cascadeAsked(p)
  const archLabel = await p.$eval('[data-testid=issues-cascade-confirm]', (el) => el.textContent.trim()).catch(() => '')
  ok('4c Shift+A on the selected row asks to archive that issue (the menu\'s Archive)', selKey === spl3 && archAsk === spl3 && /archive/i.test(archLabel), { selKey, archAsk, archLabel })
  await cancelCascade(p)
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await shiftKey(p, 'D')
  const delAsk = await cascadeAsked(p)
  ok('4d Shift+D asks to delete it (a confirm, never at once)', delAsk === spl3, { delAsk })
  await cancelCascade(p)
  ok('4e nothing was archived or deleted by the cancelled asks', Boolean(await p.$(rowSel(spl3))))
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await shiftKey(p, 'L')
  await sleep(200)
  const copied = await p.evaluate(() => window.__copied)
  ok('4f Shift+L copies the issue\'s link', copied.some((u) => u.includes(`issue=${spl3}`)), copied)
  // the focused row wins over the selected one (a fresh page selects none)
  await p.$eval(rowSel(spl2), (el) => el.focus())
  await shiftKey(p, 'L')
  await sleep(200)
  const copied2 = await p.evaluate(() => window.__copied)
  const selNow = await p.$eval('[data-test=issues-row][data-selected=true]', (el) => el.getAttribute('data-key')).catch(() => '')
  ok('4f2 a Shift key acts on the FOCUSED row, which becomes the selected one', copied2.some((u) => u.includes(`issue=${spl2}`)) && selNow === spl2, { copied2, selNow })
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await shiftKey(p, 'R')
  const rMenu = await p.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
  ok('4g Shift+R opens the row\'s menu', rMenu)
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-ctxmenu]'), { timeout: 3000 }).catch(() => {})
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await shiftKey(p, 'M')
  const movePick = await p.waitForSelector('[data-test=issues-menu]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
  ok('4h Shift+M opens the move picker', movePick)
  await p.keyboard.press('Escape')
  await sleep(150)
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await p.keyboard.press('a')
  const assignPick = await p.waitForSelector('[data-test=issues-menu]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
  ok('4i CONTROL: a plain a still opens the assignee picker', assignPick)
  await p.keyboard.press('Escape')
  await sleep(150)
  await p.$eval(rowSel(spl3), (el) => el.focus())
  await shiftKey(p, 'O')
  const opened = await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
  ok('4j Shift+O opens the issue', opened && (await p.evaluate(() => location.search)).includes(`issue=${spl3}`))
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 3000 }).catch(() => {})
  if (process.env.SHOT_DIR) {
    await rightClick(p, rowSel(spl3))
    await p.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 5000 })
    await p.setViewport({ width: 1440, height: 900 })
    await sleep(300)
    await p.screenshot({ path: `${process.env.SHOT_DIR}/issues-row-menu-1440.png` })
    await p.keyboard.press('Escape')
    await p.setViewport({ width: 1400, height: 900 })
  }

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

  // HUM-10 (t1 aedca86a, f83f73b9): on the phone an issue card swipes the
  // way a message card does: LEFT archives (the menu's Archive, so its
  // confirm), RIGHT opens the card's menu. 390 x 844, touch.
  const ph = await browser.newPage()
  ph.on('pageerror', (e) => errors.push(String(e && e.message)))
  await ph.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await ph.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await ph.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  for (const title of ['Swipe me left', 'Swipe me right']) {
    await ph.click('[data-test=issues-new]')
    await ph.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await ph.type('[data-test=issues-detail-title]', title)
    await ph.click('[data-test=issues-create]')
    await ph.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
    await ph.click('[data-test=issues-detail-back]')
    await ph.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
  }
  await sleep(500)
  await ph.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 5000 })
  const cards = await ph.$$eval('[data-test=issues-card]', (els) => els.map((e) => e.getAttribute('data-key')))
  const [cLeft, cRight] = cards
  let b = await cardBox(ph, cLeft)
  await drag(ph, b.x + b.w - 20, b.y + b.h / 2, -200)
  const swArch = await cascadeAsked(ph)
  ok('7a phone: a LEFT swipe on an issue card asks to archive that issue', swArch === cLeft, { swArch, cLeft, cards })
  if (process.env.SHOT_DIR) await ph.screenshot({ path: `${process.env.SHOT_DIR}/issues-swipe-left-390.png` })
  await cancelCascade(ph)
  ok('7b phone: the card snaps back after the cancelled archive', await ph.$eval(`[data-test=issues-card][data-key="${cLeft}"]`, (el) => !el.style.transform || /translateX\(0/.test(getComputedStyle(el).transform) || getComputedStyle(el).transform === 'none'))
  b = await cardBox(ph, cRight)
  await drag(ph, b.x + b.w / 2 + 20, b.y + b.h / 2, 150)
  const swMenu = await ph.waitForSelector('[data-test=issues-ctxmenu]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
  const swItems = swMenu ? await ph.$$eval('[data-test=issues-ctxmenu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test'))) : []
  ok('7c phone: a RIGHT swipe opens the card\'s menu with archive, delete and copy link', swMenu && ['issues-ctxmenu-archive', 'issues-ctxmenu-delete', 'issues-ctxmenu-copy'].every((k) => swItems.includes(k)), swItems)
  if (process.env.SHOT_DIR) await ph.screenshot({ path: `${process.env.SHOT_DIR}/issues-swipe-menu-390.png` })
  const stillList = await ph.$('[data-test=issues-detail]')
  ok('7d phone: the swipe did not also open the issue', !stillList)
  await ph.close()

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
