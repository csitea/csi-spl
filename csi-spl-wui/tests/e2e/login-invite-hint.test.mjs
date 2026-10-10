// SPL-1231: an invitee arriving from the invite link (/login?...&login_hint=<the
// invited address>) is told which address was invited and which sign-in owns
// it, the matching provider button is drawn emphasised and carries the hint to
// /start (it pre-selects that account at Google / Microsoft), and the email +
// password form is pre-filled. Without login_hint the page is unchanged.
// HUM-10 (topic 3e5b850b): where the email link lands, Chrome's install event
// shows an "Install app" strip; Install calls its prompt(), "Not now" is
// remembered on the device (section 5). SHOT_DIR=<dir> keeps its screenshots.
// Proved in a REAL browser against the mock bundle (/providers is answered here:
// nothing serves it under nuxi dev).
//
//   node tests/e2e/login-invite-hint.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/login-invite-hint.test.mjs
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
let failed = 0
const ok = (name, cond, extra) => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${JSON.stringify(extra ?? '')}`) }
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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname.endsWith('/api/v1/auth/providers')) {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ providers: ['google', 'facebook', 'microsoft'], native: true }) })
    }
    return req.continue()
  })
  const open = async (q) => {
    await p.goto(server.base + '/login' + q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=social-auth-google]', { visible: true, timeout: NAV_TIMEOUT })
  }
  const text = (sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')

  // 1. a Gmail invitee: named, Google suggested + carrying the hint, form pre-filled
  await open('?tenant=t1&redirect=%2Flobby&login_hint=Invitee%40Googlemail.com')
  await p.waitForSelector('[data-test=login-invite-hint]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('1 the invited address is named', /invitee@googlemail\.com/.test(await text('[data-test=login-invite-email]')), await text('[data-test=login-invite-email]'))
  ok('1b Google is the suggested sign-in', Boolean(await p.$('[data-test=login-invite-use-google]')))
  const g = await p.$eval('[data-test=social-auth-google]', (e) => ({ href: e.getAttribute('href'), s: e.getAttribute('data-suggested') }))
  ok('1c the Google button is emphasised and carries login_hint', g.s === 'true' && /[?&]login_hint=invitee%40googlemail\.com(&|$)/.test(g.href) && /[?&]tenant=t1(&|$)/.test(g.href), g)
  const fb = await p.$eval('[data-test=social-auth-facebook]', (e) => e.getAttribute('data-suggested'))
  ok('1d other buttons are not emphasised', fb === null, fb)
  await p.waitForFunction(() => document.querySelector('[data-test=native-auth-email]')?.value === 'invitee@googlemail.com', { timeout: 10000 }).catch(() => null)
  ok('1e the email + password form is pre-filled', await p.$eval('[data-test=native-auth-email]', (e) => e.value).catch(() => '') === 'invitee@googlemail.com')

  // 2. a work-domain invitee: no single provider guessed, the generic advice
  await open('?tenant=t1&login_hint=office%40acme.example')
  await p.waitForSelector('[data-test=login-invite-use-any]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('2 a work address gets the generic advice, no button emphasised',
    Boolean(await p.$('[data-test=login-invite-use-any]')) && !(await p.$('[data-suggested=true]')))

  // 3. CONTROL: no login_hint = the page as before (no hint, no hint on /start)
  await open('?tenant=t1')
  const plain = await p.$eval('[data-test=social-auth-google]', (e) => e.getAttribute('href'))
  ok('3 CONTROL: without login_hint there is no hint block and no login_hint on /start',
    !(await p.$('[data-test=login-invite-hint]')) && !/login_hint=/.test(plain), plain)

  // 4. CONTROL: a value that is not an address is ignored
  await open('?tenant=t1&login_hint=%3Cscript%3E')
  ok('4 CONTROL: a non-address login_hint is ignored', !(await p.$('[data-test=login-invite-hint]')))

  // 5. HUM-10: the install offer on /login, only after Chrome's install event.
  // A real event (headless Chrome may find the bundle installable) is counted
  // and stopped, so each check fires its own synthetic one.
  await p.evaluateOnNewDocument(() => {
    addEventListener('beforeinstallprompt', (e) => {
      if (e.isTrusted) { window.__realInstallEvent = 1; e.stopImmediatePropagation() }
    })
  })
  const fireInstallEvent = () => p.evaluate(() => {
    window.__prompts = 0
    const e = new Event('beforeinstallprompt', { cancelable: true })
    e.prompt = () => { window.__prompts += 1; return Promise.resolve() }
    e.userChoice = Promise.resolve({ outcome: 'accepted', platform: 'web' })
    dispatchEvent(e)
    return e.defaultPrevented
  })
  const offer = () => p.$eval('[data-test=pwa-install-offer]', (e) => e.getBoundingClientRect().width > 0).catch(() => false)
  const waitOffer = () => p.waitForSelector('[data-test=pwa-install-offer]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const shot = async (name) => {
    if (!process.env.SHOT_DIR) return
    mkdirSync(process.env.SHOT_DIR, { recursive: true })
    await p.screenshot({ path: join(process.env.SHOT_DIR, `pwa-offer-${name}.png`) })
  }
  await open('?tenant=t1&login_hint=office%40acme.example')
  await p.evaluate(() => localStorage.removeItem('spool:pwa-offer-off'))
  await open('?tenant=t1&login_hint=office%40acme.example')
  ok('5a CONTROL: no install event (Safari, Firefox), no offer', !(await offer()), { realInstallEvent: await p.evaluate(() => Boolean(window.__realInstallEvent)) })
  ok('5b the install event is kept (preventDefault)', await fireInstallEvent())
  ok('5c with the event: the offer shows on /login', await waitOffer())
  await shot('1280-login')
  await p.setViewport({ width: 390, height: 844 })
  const fits = await p.$eval('[data-test=pwa-install-offer]', (e) => { const r = e.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth }).catch(() => false)
  ok('5d on a phone it fits the screen', fits)
  await shot('390-login')
  await p.click('[data-test=pwa-install-offer-install]')
  await p.waitForSelector('[data-test=pwa-install-offer]', { hidden: true, timeout: 5000 }).catch(() => null)
  ok('5e Install calls the browser prompt once, then the offer is gone', (await p.evaluate(() => window.__prompts)) === 1 && !(await offer()), { prompts: await p.evaluate(() => window.__prompts) })
  await p.setViewport({ width: 1280, height: 900 })
  await open('?tenant=t1')
  await fireInstallEvent()
  ok('5f CONTROL: a new page, a new event: the offer again', await waitOffer())
  await p.click('[data-test=pwa-install-offer-dismiss]')
  await p.waitForSelector('[data-test=pwa-install-offer]', { hidden: true, timeout: 5000 }).catch(() => null)
  ok('5g Not now hides it, no prompt', !(await offer()) && (await p.evaluate(() => window.__prompts)) === 0)
  await open('?tenant=t1')
  await fireInstallEvent()
  await new Promise((r) => setTimeout(r, 1000))
  ok('5h Not now is remembered on this device', !(await offer()) && (await p.evaluate(() => localStorage.getItem('spool:pwa-offer-off'))) === '1')
  await p.evaluate(() => localStorage.removeItem('spool:pwa-offer-off'))
  // Off the sign-in page the strip covered the phone back button, the docs
  // tree and the avatars (headless Chrome fires a real event; wf 10 run
  // 38060764458): it is offered on /login only.
  await p.goto(server.base + '/blog', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await fireInstallEvent()
  await new Promise((r) => setTimeout(r, 1000))
  ok('5i CONTROL: off /login the event shows no offer', !(await offer()) && (await p.evaluate(() => localStorage.getItem('spool:pwa-offer-off'))) === null)

  ok('6 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
if (failed) { console.error(`FAIL: ${failed} check(s) failed`); process.exit(1) }
console.log('all login-invite-hint checks passed')
