// CLE-77853 (bug 49568e8b; HUM-24 "profile, settings: there is no exit";
// owner pick "B. - a pop-up modal dialog - similar to the one of edit epic"):
// Settings is a large modal OVER the current view, in a real browser, mock
// tenant signed in.
//   G   1440: the gear (user menu -> Settings) opens it over /channel/general
//       - the channel stays behind it, the URL keeps its path and gains
//       ?settings=, the composer draft is untouched
//   E   Escape closes it: the URL is the view again, the draft is still
//       there, focus is back on the user menu button
//   X   the X closes it
//   O   a click outside (on the backdrop) closes it
//   B   a section change replaces the entry, so browser Back closes it
//   D   a cold deep link /settings/security opens the SAME modal on Sign-in
//       and security over the lobby; Back closes it and stays in the app
//   P   phone 390: /settings/notifications is a full-screen sheet with its X
//       shown (no Back chevron), no sideways scroll; the X closes it
//   N   the page never scrolls behind it (scrollX/scrollY 0, no x overflow)
// CONTROL: the dialog is asserted present before every close path, so a close
// that "works" because nothing opened cannot read green.
//
//   node tests/e2e/settings-modal.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/settings-modal.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 844 }
const DRAFT = 'a draft that must survive Settings'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      const theme = localStorage.getItem('spool.test.theme')
      if (theme) localStorage.setItem('spool-theme', theme)
    } catch { /* opaque origin on the very first document */ }
  })

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(600)
  }
  const url = () => new URL(p.url())
  const q = () => url().searchParams.get('settings')
  const dialogOpen = () => p.evaluate(() => {
    const d = document.querySelector('[data-testid=ui-dialog]')
    return Boolean(d && d.querySelector('[data-test=settings]') && d.getBoundingClientRect().width > 0)
  })
  const waitClosed = () => p.waitForFunction(() => !document.querySelector('[data-test=settings]'), { timeout: 5000 }).then(() => true).catch(() => false)
  const waitOpen = () => p.waitForSelector('[data-testid=ui-dialog] [data-test=settings]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const openFromGear = async () => {
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-settings]', { visible: true, timeout: 5000 })
    await p.click('[data-test=user-menu-settings]')
    const opened = await waitOpen()
    await sleep(300)
    return opened
  }
  const draft = () => p.evaluate(() => [...document.querySelectorAll('textarea')].find((t) => !t.closest('[data-testid=ui-dialog]') && t.getBoundingClientRect().width > 0)?.value ?? null)
  const noScroll = () => p.evaluate(() => ({
    sx: window.scrollX,
    sy: window.scrollY,
    over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  }))
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-modal-${name}.png` }) }
  const setTheme = (theme) => p.evaluate((t) => localStorage.setItem('spool.test.theme', t), theme)

  /* G: the gear opens it over the channel */
  await load(DESKTOP, '/channel/general')
  const ta = await p.evaluateHandle(() => [...document.querySelectorAll('textarea')].find((t) => t.getBoundingClientRect().width > 0) || null)
  if (ta.asElement()) await ta.asElement().type(DRAFT)
  const draft0 = await draft()
  ok('G0 CONTROL: the composer holds the draft before Settings opens', draft0 === DRAFT, { draft0 })
  ok('G1 the gear opens Settings as a modal', await openFromGear())
  ok('G2 the URL keeps the view and gains ?settings=', url().pathname.endsWith('/channel/general') && q() === '', { url: p.url() })
  ok('G3 the channel stays behind it, dimmed', await p.evaluate(() => {
    const bd = document.querySelector('[data-testid=ui-dialog-backdrop]')
    return Boolean(document.querySelector('.spool-main') && bd && getComputedStyle(bd).backgroundColor !== 'rgba(0, 0, 0, 0)')
  }))
  ok('G4 Profile is the section on a desktop', await p.$('[data-test=settings-profile]') !== null)
  let n = await noScroll()
  ok('N1 1440: the page never scrolls behind the modal', n.sx === 0 && n.sy === 0 && n.over <= 0, n)
  await shot('1440-open')

  /* E: Escape */
  await p.keyboard.press('Escape')
  ok('E1 Escape closes it', await waitClosed())
  await sleep(300)
  ok('E2 the URL is the view again', url().pathname.endsWith('/channel/general') && q() === null, { url: p.url() })
  ok('E3 the draft is untouched', (await draft()) === DRAFT, { draft: await draft() })
  ok('E4 focus is back on the user menu button', (await p.evaluate(() => document.activeElement?.getAttribute('data-test'))) === 'user-menu-trigger')

  /* X: the X */
  ok('X0 CONTROL: reopened', await openFromGear())
  await p.click('[data-testid=ui-dialog-close]')
  ok('X1 the X closes it', await waitClosed())
  await sleep(300)
  ok('X2 back on the view', q() === null && url().pathname.endsWith('/channel/general'), { url: p.url() })

  /* O: a click outside */
  ok('O0 CONTROL: reopened', await openFromGear())
  await p.mouse.click(6, 450)
  ok('O1 a click outside closes it', await waitClosed())
  await sleep(300)

  /* B: section change, then browser Back */
  ok('B0 CONTROL: reopened', await openFromGear())
  await p.click('[data-test=settings-nav-notifications]')
  await p.waitForSelector('[data-test=settings-notifications]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('B1 a section opens in the same modal', q() === 'notifications' && await dialogOpen(), { url: p.url() })
  await p.goBack({ waitUntil: 'networkidle2' }).catch(() => null)
  ok('B2 browser Back closes it', await waitClosed())
  ok('B3 back on the view, draft kept', url().pathname.endsWith('/channel/general') && q() === null && (await draft()) === DRAFT, { url: p.url() })

  /* D: a cold deep link */
  await load(DESKTOP, '/settings/security')
  ok('D1 /settings/security opens the modal on Sign-in and security', await waitOpen() && await p.$('[data-test=settings-signin]') !== null)
  ok('D2 over the lobby', url().pathname.endsWith('/lobby') && q() === 'security', { url: p.url() })
  await p.goBack({ waitUntil: 'networkidle2' }).catch(() => null)
  ok('D3 Back closes it and stays in the app', await waitClosed() && url().pathname.endsWith('/lobby'), { url: p.url() })

  /* P: phone */
  await load(PHONE, '/settings/notifications')
  ok('P0 CONTROL: the modal is open at 390', await waitOpen())
  const sheet = await p.evaluate(() => {
    const d = document.querySelector('[data-testid=ui-dialog]').getBoundingClientRect()
    const xs = [...document.querySelectorAll('[data-testid=ui-dialog-close]')].filter((x) => x.getBoundingClientRect().width > 0)
    const back = document.querySelector('[data-testid=ui-dialog-back]').getBoundingClientRect()
    return { full: d.left === 0 && d.top === 0 && Math.round(d.width) === innerWidth && Math.round(d.height) === innerHeight, xs: xs.length, xw: xs[0]?.getBoundingClientRect().width ?? 0, back: back.width }
  })
  ok('P1 390: a full-screen sheet', sheet.full, sheet)
  ok('P2 390: one X shown, >= 44 px, no Back chevron', sheet.xs === 1 && sheet.xw >= 44 && sheet.back === 0, sheet)
  n = await noScroll()
  ok('P3 390: no sideways scroll, the page never scrolls', n.sx === 0 && n.sy === 0 && n.over <= 0, n)
  await shot('390-open')
  await p.click('[data-testid=ui-dialog-close]')
  ok('P4 390: the X closes it', await waitClosed() && q() === null, { url: p.url() })

  /* screenshots in the light theme too */
  if (OUT) {
    await setTheme('light')
    await load(DESKTOP, '/channel/general')
    await openFromGear()
    await shot('1440-open-light')
    await load(PHONE, '/settings/notifications')
    await waitOpen()
    await sleep(300)
    await shot('390-open-light')
    await setTheme('dark')
  }

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
