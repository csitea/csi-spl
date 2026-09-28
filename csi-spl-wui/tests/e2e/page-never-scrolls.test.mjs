// SPL-960: the page must never scroll. Open the row menu on the last visible
// message of a long pane and assert the document stays put and the menu is
// inside the viewport.
//
//   node tests/e2e/page-never-scrolls.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/page-never-scrolls.test.mjs
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
        defaultViewport: { width: 1100, height: 640 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

function inside(rect, vw, vh) {
  return rect.top >= -1 && rect.left >= -1 && rect.bottom <= vh + 1 && rect.right <= vw + 1 && rect.height > 8 && rect.width > 8
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1100, height: 640 })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  try {
    await p.waitForSelector('.spool-main .feed-body [data-testid="msg-menu-btn"]', { visible: true, timeout: NAV_TIMEOUT })
  } catch (err) {
    const info = await p.evaluate(() => ({
      url: location.href,
      shell: !!document.querySelector('.spool-shell'),
      feeds: document.querySelectorAll('.feed-body').length,
      buttons: document.querySelectorAll('[data-testid="msg-menu-btn"]').length,
      text: (document.body.innerText || '').slice(0, 600),
    })).catch((e) => String(e))
    console.log('PAGE', JSON.stringify({ info, errors }))
    throw err
  }

  const shell = await p.evaluate(() => {
    const layout = document.querySelector('.layout')
    const r = layout ? layout.getBoundingClientRect() : { height: -1 }
    const se = document.scrollingElement
    return {
      shellH: r.height,
      innerHeight: window.innerHeight,
      overflowY: getComputedStyle(document.documentElement).overflowY,
      scrollTop: se.scrollTop,
    }
  })
  ok('1 the shell is the viewport and the document is not a vertical scroller',
    Math.abs(shell.shellH - shell.innerHeight) <= 1 && shell.overflowY === 'hidden' && shell.scrollTop === 0,
    shell)

  await p.mouse.move(480, 12)
  await p.mouse.wheel({ deltaY: 900 })
  const wheeled = await p.evaluate(() => document.scrollingElement.scrollTop)
  ok('2 a wheel on the top bar does not scroll the document', wheeled === 0, { scrollTop: wheeled })

  // Sit the last visible message's menu button on the bottom edge of its pane,
  // then shrink the window until there is no room below it for the menu.
  for (let i = 0; i < 5; i++) {
    const spot = await p.evaluate(() => {
      const feed = document.querySelector('.spool-main .feed-body')
      if (!feed) return null
      feed.scrollTop = feed.scrollHeight
      const buttons = [...feed.querySelectorAll('[data-testid="msg-menu-btn"]')].filter((b) => {
        const r = b.getBoundingClientRect()
        const fr = feed.getBoundingClientRect()
        return r.width > 0 && r.bottom > fr.top + 1 && r.top < fr.bottom - 1
      })
      const last = buttons[buttons.length - 1]
      if (!last) return null
      const fr = feed.getBoundingClientRect()
      const br = last.getBoundingClientRect()
      feed.scrollTop += br.bottom - (fr.bottom - 6)
      const now = last.getBoundingClientRect()
      return { bottom: now.bottom, n: buttons.length, vh: window.innerHeight }
    })
    if (!spot) break
    if (spot.vh - spot.bottom < 36) break
    const nextH = Math.max(360, Math.ceil(spot.bottom + 18))
    if (Math.abs(nextH - spot.vh) < 4) break
    await p.setViewport({ width: 1100, height: nextH })
  }

  const btn = await p.evaluateHandle(() => {
    const feed = document.querySelector('.spool-main .feed-body')
    const buttons = [...feed.querySelectorAll('[data-testid="msg-menu-btn"]')].filter((b) => {
      const r = b.getBoundingClientRect()
      const fr = feed.getBoundingClientRect()
      return r.width > 0 && r.bottom > fr.top + 1 && r.top < fr.bottom - 1
    })
    return buttons[buttons.length - 1] || null
  })
  const button = btn.asElement()
  if (!button) throw new Error('no visible message menu button')
  const btnBox = await button.boundingBox()
  const scrollBefore = await p.evaluate(() => document.scrollingElement.scrollTop)
  await button.evaluate((el) => el.click())
  await p.waitForSelector('[data-testid="msg-menu"]', { visible: true, timeout: 5000 })
  await p.keyboard.press('ArrowDown')
  const measured = await p.evaluate(() => {
    const se = document.scrollingElement
    const menu = document.querySelector('[data-testid="msg-menu"]').getBoundingClientRect()
    return {
      scrollTop: se.scrollTop,
      scrollHeight: se.scrollHeight,
      clientHeight: se.clientHeight,
      overflowY: getComputedStyle(document.documentElement).overflowY,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      menu: { top: menu.top, left: menu.left, right: menu.right, bottom: menu.bottom, width: menu.width, height: menu.height },
    }
  })
  const menuInside = inside(measured.menu, measured.innerWidth, measured.innerHeight)
  const spaceBelow = measured.innerHeight - (btnBox.y + btnBox.height)
  const flipped = spaceBelow >= measured.menu.height || measured.menu.top < btnBox.y + btnBox.height - 1
  const docFits = measured.scrollHeight <= measured.clientHeight + 2
  const nearButton = measured.menu.left <= btnBox.x + 8 && measured.menu.right >= btnBox.x - 8
  ok('3 the last visible row menu stays inside the viewport and the document scrollTop stays 0',
    scrollBefore === 0 && measured.scrollTop === 0 && measured.overflowY === 'hidden' && menuInside && flipped && docFits && nearButton,
    { scrollBefore, spaceBelow, docFits, nearButton, btn: btnBox, ...measured })

  await p.keyboard.press('Escape')
  await p.waitForSelector('[data-testid="msg-menu"]', { hidden: true, timeout: 5000 })

  const sideMeasured = await p.evaluate(() => {
    const buttons = [...document.querySelectorAll('[data-testid="sidebar-row-menu"]')].filter((b) => {
      const r = b.getBoundingClientRect()
      return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < window.innerHeight
    })
    const btn = buttons[buttons.length - 1]
    if (!btn) return { reason: 'no visible sidebar row menu' }
    btn.click()
    return new Promise((resolve) => {
      setTimeout(() => {
        const openBtn = [...document.querySelectorAll('[data-testid="sidebar-row-menu"]')].find((b) => b.getAttribute('data-open') === 'true')
        const panels = [...document.querySelectorAll('[data-testid="sidebar-row-menu-panel"]')]
        const shown = panels.filter((n) => getComputedStyle(n).display !== 'none')
        const menu = shown[0] ? shown[0].getBoundingClientRect() : null
        const se = document.scrollingElement
        resolve({
          clicked: btn.getAttribute('data-menu-id'),
          open: openBtn ? openBtn.getAttribute('data-menu-id') : '',
          shown: shown.length,
          visibility: shown[0] ? getComputedStyle(shown[0]).visibility : '',
          scrollTop: se.scrollTop,
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight,
          menu: menu && { top: menu.top, left: menu.left, right: menu.right, bottom: menu.bottom, width: menu.width, height: menu.height },
        })
      }, 400)
    })
  })
  const sideOk = sideMeasured.menu
    && sideMeasured.scrollTop === 0
    && sideMeasured.visibility === 'visible'
    && inside(sideMeasured.menu, sideMeasured.innerWidth, sideMeasured.innerHeight)
  ok('4 the sidebar row menu stays inside the viewport and the document scrollTop stays 0', sideOk, sideMeasured)

  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main .feed-body [data-testid="msg-menu-btn"]', { visible: true, timeout: NAV_TIMEOUT })
  const phone = await p.evaluate(() => {
    const feed = document.querySelector('.spool-main .feed-body')
    feed.scrollTop = feed.scrollHeight
    const buttons = [...feed.querySelectorAll('[data-testid="msg-menu-btn"]')].filter((b) => {
      const r = b.getBoundingClientRect()
      const fr = feed.getBoundingClientRect()
      return r.width > 0 && r.bottom > fr.top + 1 && r.top < fr.bottom - 1
    })
    const last = buttons[buttons.length - 1]
    const fr = feed.getBoundingClientRect()
    const br = last.getBoundingClientRect()
    feed.scrollTop += br.bottom - (fr.bottom - 6)
    last.click()
    const shell = document.querySelector('.layout').getBoundingClientRect()
    return new Promise((resolve) => {
      /* measure the sheet where it RESTS: on a phone it slides up 24 px
         (SheetBackdrop touch-sheet-up, .18 s), and a loaded CI runner was
         read mid-slide at a fixed 300 ms (bottom 845.07 / 850.19 vs 844) */
      setTimeout(async () => {
        await Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {})))
        const se = document.scrollingElement
        const menu = document.querySelector('[data-testid="msg-menu"]').getBoundingClientRect()
        const btn = last.getBoundingClientRect()
        resolve({
          scrollTop: se.scrollTop,
          shellH: shell.height,
          innerHeight: window.innerHeight,
          innerWidth: window.innerWidth,
          overscroll: getComputedStyle(document.documentElement).overscrollBehavior,
          btnBottom: btn.bottom,
          menu: { top: menu.top, left: menu.left, right: menu.right, bottom: menu.bottom, width: menu.width, height: menu.height },
        })
      }, 300)
    })
  })
  const phoneInside = inside(phone.menu, phone.innerWidth, phone.innerHeight)
  const phoneNear = phone.menu.left <= phone.innerWidth && phone.menu.right >= 0 && phone.menu.bottom <= phone.innerHeight + 1
  ok('6 a phone viewport keeps the last row menu inside and the document still',
    phone.scrollTop === 0 && Math.abs(phone.shellH - phone.innerHeight) <= 1 && phone.overscroll === 'none' && phoneInside && phoneNear,
    phone)

  await p.keyboard.press('Escape')
  await p.setViewport({ width: 390, height: 500, isMobile: true, hasTouch: true })
  const keyboard = await p.evaluate(() => {
    const shell = document.querySelector('.layout').getBoundingClientRect()
    const se = document.scrollingElement
    return { scrollTop: se.scrollTop, shellH: shell.height, innerHeight: window.innerHeight, innerWidth: window.innerWidth }
  })
  ok('7 a shorter viewport, as when the keyboard is open, still does not scroll the document',
    keyboard.scrollTop === 0 && Math.abs(keyboard.shellH - keyboard.innerHeight) <= 1,
    keyboard)

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('5 no page errors', mine.length === 0, mine)
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
