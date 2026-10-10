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
//   C   t1 ea0af569 (B): a password session gets "Change password" in the
//       account menu and on its OWN profile card; each opens this modal on
//       Sign-in and security with the change-password form. Not on another
//       member's card.
//       CONTROL: the same reader signed in WITHOUT a password (the default
//       mock session, no claim p) sees neither link.
//   I   t1 HUM-10 (msg 44200ea2): Appearance's "Apps on this phone" lists one
//       row per workspace; with no install event the manual step shows, a
//       (mocked) beforeinstallprompt gives an Install button whose click
//       calls prompt() once and then says Installed; running standalone it
//       says Installed.
//   S   t1 f265541a (owner HUM-10): Sign-in and security lists the sign-in
//       emails - the main address active, a pending one with "Confirm with"
//       links for the enabled providers only (a link sign-in, link=1); adding
//       an address says it works once signed in with it at the provider while
//       signed in here; a taken address is a plain message; a pending one is
//       removed after a confirm. CONTROL: the active row has no confirm link,
//       the main address no remove.
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
      /* C: spool.test.signin = the session's sign-in method (claim p), none by default */
      const signIn = localStorage.getItem('spool.test.signin')
      /* I: spool.test.tenants = the session's memberships (claim tenants) */
      const tenants = JSON.parse(localStorage.getItem('spool.test.tenants') || 'null')
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', ...(signIn ? { p: signIn } : {}), ...(tenants ? { active_tenant: 't1', tenants } : {}) }))
      /* I: Chrome itself offers install of this bundle (a real
         beforeinstallprompt, measured on localhost). Stop it before the app
         sees it, so I2 is the no-event browser (Safari, Firefox) and only the
         test's own event (an own `prompt`) reaches the app; note it fired. */
      window.addEventListener('beforeinstallprompt', (e) => {
        if (Object.prototype.hasOwnProperty.call(e, 'prompt')) return
        window.__realInstallEvent = true
        e.stopImmediatePropagation()
      })
      /* I: spool.test.standalone = this page runs as the installed app */
      if (localStorage.getItem('spool.test.standalone')) {
        const mm = window.matchMedia.bind(window)
        window.matchMedia = (q) => (/display-mode:\s*standalone/.test(q) ? { matches: true, media: q, addEventListener() {}, removeEventListener() {} } : mm(q))
      }
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
  const setSignIn = (method) => p.evaluate((m) => {
    if (m) localStorage.setItem('spool.test.signin', m); else localStorage.removeItem('spool.test.signin')
  }, method)
  const menuHas = async (sel) => {
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-settings]', { visible: true, timeout: 5000 })
    const has = await p.$(sel) !== null
    return has
  }
  const onSecurityForm = async () => await waitOpen() && q() === 'security'
    && await p.waitForSelector('[data-testid=ui-dialog] [data-test=change-password]', { visible: true, timeout: 5000 }).then(() => true).catch(() => false)

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

  /* C: "Change password" in the account menu and on the own profile (t1 ea0af569 B) */
  await load(DESKTOP, '/channel/general')
  ok('C0 CONTROL: no password sign-in -> no Change password in the account menu', await menuHas('[data-test=user-menu-settings]') && await p.$('[data-test=user-menu-change-password]') === null)
  await p.keyboard.press('Escape')
  await load(DESKTOP, '/people/HUM-1')
  await p.waitForSelector('[data-test=person-card]', { timeout: 10000 }).catch(() => null)
  ok('C0b CONTROL: no password sign-in -> no Change password on the own card', await p.$('[data-test=person-card]') !== null && await p.$('[data-test=person-change-password]') === null)
  await setSignIn('password')
  await load(DESKTOP, '/channel/general')
  ok('C1 a password session: Change password is in the account menu', await menuHas('[data-test=user-menu-change-password]'))
  await shot('1440-menu-change-password')
  await p.click('[data-test=user-menu-change-password]')
  ok('C2 it opens Settings on Sign-in and security with the change-password form, over the view', await onSecurityForm() && url().pathname.endsWith('/channel/general'), { url: p.url() })
  await p.keyboard.press('Escape')
  await waitClosed()
  await load(DESKTOP, '/people/HUM-1')
  const own = await p.waitForSelector('[data-test=person-change-password]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('C3 the own profile card carries Change password', own)
  await shot('1440-profile-change-password')
  if (own) await p.click('[data-test=person-change-password]')
  ok('C4 it opens the same form', own && await onSecurityForm(), { url: p.url() })
  await load(DESKTOP, '/people/HUM-3')
  await p.waitForSelector('[data-test=person-card]', { timeout: 10000 }).catch(() => null)
  ok('C5 another member\'s card has no Change password', await p.$('[data-test=person-message]') !== null && await p.$('[data-test=person-change-password]') === null)
  await setSignIn('')

  /* I: "Apps on this phone" (t1 HUM-10 msg 44200ea2): the install step */
  const apps = () => p.evaluate(() => {
    const box = document.querySelector('[data-test=settings-apps]')
    const rows = [...document.querySelectorAll('[data-test^=settings-apps-row-]')]
    return {
      box: Boolean(box && box.getBoundingClientRect().width > 0),
      rows: rows.map((r) => r.getAttribute('data-test').slice('settings-apps-row-'.length) + (r.dataset.current === '1' ? '*' : '')),
      install: document.querySelector('[data-test=settings-apps-install]') !== null,
      manual: document.querySelector('[data-test=settings-apps-manual]') !== null,
      installed: document.querySelector('[data-test=settings-apps-installed]') !== null,
    }
  })
  const openApps = async (vp) => {
    await load(vp, '/lobby?settings=appearance&install=1')
    return await waitOpen() && await p.waitForSelector('[data-test=settings-apps]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  }
  /* a browser that offers install: Chrome's event, with a counted prompt() */
  const fireInstallEvent = () => p.evaluate(() => {
    window.__prompts = 0
    const e = new Event('beforeinstallprompt', { cancelable: true })
    e.prompt = () => { window.__prompts += 1; return Promise.resolve() }
    e.userChoice = Promise.resolve({ outcome: 'accepted', platform: 'web' })
    window.dispatchEvent(e)
    return e.defaultPrevented
  })
  await p.evaluate(() => localStorage.setItem('spool.test.tenants', JSON.stringify([{ tenant_id: 't1', name: 'northwind' }, { tenant_id: 't2', name: 'globex' }])))
  ok('I0 CONTROL: Appearance opens with the Apps section', await openApps(PHONE))
  let a = await apps()
  ok('I1 one row per workspace, this one first', a.box && a.rows.join(',') === 't1*,t2', { ...a, realInstallEvent: await p.evaluate(() => Boolean(window.__realInstallEvent)) })
  ok('I2 no install event (Safari, Firefox): the manual step, no dead button', a.manual && !a.install && !a.installed, a)
  ok('I3 another workspace on this one origin (tenant hosts off): "same app", no link', await p.$('[data-test=settings-apps-same-t2]') !== null && await p.$('[data-test=settings-apps-open-t2]') === null)
  await shot('390-apps-manual')
  ok('I4 the install event is kept (preventDefault)', await fireInstallEvent())
  await p.waitForSelector('[data-test=settings-apps-install]', { visible: true, timeout: 5000 }).catch(() => null)
  a = await apps()
  ok('I5 with the event: an Install button, no manual step', a.install && !a.manual, a)
  await shot('390-apps-install')
  await p.click('[data-test=settings-apps-install]')
  await p.waitForSelector('[data-test=settings-apps-installed]', { visible: true, timeout: 5000 }).catch(() => null)
  a = await apps()
  ok('I6 Install calls the browser prompt once, then says Installed', (await p.evaluate(() => window.__prompts)) === 1 && a.installed && !a.install, { ...a, prompts: await p.evaluate(() => window.__prompts) })
  await p.evaluate(() => localStorage.setItem('spool.test.standalone', '1'))
  ok('I7 CONTROL: reopened as the installed app', await openApps(PHONE))
  await fireInstallEvent()
  await sleep(300)
  a = await apps()
  ok('I8 running as the app (display-mode standalone): Installed, no button', a.installed && !a.install && !a.manual, a)
  await shot('390-apps-installed')
  await p.evaluate(() => { localStorage.removeItem('spool.test.standalone'); localStorage.removeItem('spool.test.tenants') })

  /* S: sign-in emails (t1 f265541a) */
  const emails = () => p.evaluate(() => [...document.querySelectorAll('[data-test=signin-emails] [data-test^=signin-emails-row-]')].map((r) => ({
    email: r.querySelector('[data-test=signin-emails-address]')?.textContent.trim(),
    state: r.dataset.state,
    main: r.querySelector('[data-test=signin-emails-main]') !== null,
    confirm: [...r.querySelectorAll('[data-test^=signin-emails-confirm-]')].map((a) => a.getAttribute('data-test').slice('signin-emails-confirm-'.length)),
    link: [...r.querySelectorAll('[data-test^=signin-emails-confirm-]')].every((a) => new URL(a.href).searchParams.get('link') === '1'),
    remove: r.querySelector('[data-test=signin-emails-remove]') !== null,
  })))
  const text = (sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
  await load(DESKTOP, '/lobby?settings=security')
  const listed = await waitOpen() && await p.waitForSelector('[data-test=signin-emails-row-pending] [data-test=signin-emails-confirm-google]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  let em = await emails()
  ok('S0 CONTROL: Sign-in and security shows the sign-in emails', listed && em.length === 2, em)
  ok('S1 the main address is active, marked main, no confirm link, no remove', em[0]?.state === 'active' && em[0].main && em[0].confirm.length === 0 && !em[0].remove, em[0])
  ok('S2 the pending address: Confirm with the enabled providers only, each a link sign-in', em[1]?.state === 'pending' && em[1].confirm.join(',') === 'google,microsoft' && em[1].link && em[1].remove, em[1])
  await p.$eval('[data-test=settings-signin-emails]', (e) => e.scrollIntoView({ block: 'start' }))
  await shot('1440-signin-emails')
  await p.type('[data-test=signin-emails-input]', 'new@example.com')
  await p.click('[data-test=signin-emails-add]')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=signin-emails-row-pending]').length === 2, { timeout: 5000 }).catch(() => null)
  const added = await text('[data-test=signin-emails-notice]')
  ok('S3 an added address is pending and the owner\'s explanation shows', (await emails()).length === 3 && /works once you sign in with it at Google or Microsoft while signed in here/.test(added), { added })
  await p.type('[data-test=signin-emails-input]', 'taken@example.com')
  await p.click('[data-test=signin-emails-add]')
  await p.waitForSelector('[data-test=signin-emails-error]', { visible: true, timeout: 5000 }).catch(() => null)
  const taken = await text('[data-test=signin-emails-error]')
  ok('S4 a taken address is a plain message that names no one', taken === 'This address belongs to another account.' && (await emails()).length === 3, { taken })
  await p.click('[data-test=signin-emails-row-pending] [data-test=signin-emails-remove]')
  await p.waitForSelector('[data-test=signin-emails-remove-yes]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('S5 CONTROL: remove asks first, nothing gone yet', (await emails()).length === 3)
  await p.click('[data-test=signin-emails-remove-yes]')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=signin-emails-row-pending]').length === 1, { timeout: 5000 }).catch(() => null)
  em = await emails()
  ok('S6 the pending address is removed', em.length === 2 && /was removed/.test(await text('[data-test=signin-emails-notice]')), em)
  n = await noScroll()
  ok('S7 1440: no sideways scroll with the list open', n.over <= 0, n)
  await load(PHONE, '/lobby?settings=security')
  await p.waitForSelector('[data-test=signin-emails-row-pending]', { visible: true, timeout: 10000 }).catch(() => null)
  const tap = await p.evaluate(() => [...document.querySelectorAll('[data-test=signin-emails] a, [data-test=signin-emails] button')].filter((b) => b.getBoundingClientRect().width > 0).every((b) => b.getBoundingClientRect().height >= 44))
  n = await noScroll()
  ok('S8 390: no sideways scroll, every button >= 44 px', n.over <= 0 && tap, { ...n, tap })
  await shot('390-signin-emails')

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
