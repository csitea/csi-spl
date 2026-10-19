// SPL-2169 (repo review suggestion 6): what the WUI keeps across a reload
// and a closed tab, the persistence strategy of
// csi-spl-doc/specs/005-spool-wui/client-state.md, pinned on the mock bundle.
//
//   mock tenant, signed in as HUM-1 (spool.mock.session), 1440x900, on
//   /channel/feedback:
//     set  a composer draft (localStorage spool.drafts), a theme pick
//          (localStorage spool-theme), a view token (sessionStorage
//          spool.view_token) and a Pinia-only flag (editMode.isEditing)
//     RELOAD the same tab:
//       S1 the URL (channel) is the same
//       S2 the draft is back in the box
//       S3 the theme pick is applied
//       S4 the view token is still in this tab's sessionStorage
//       S5 the Pinia-only flag is back to its default (memory only)
//       S6 the session is rebuilt (the session store reads HUM-1 again)
//       S7 no localStorage value holds the view token
//     CLOSE the tab, open a new one on the same URL (same browser profile):
//       C1 the draft and the theme pick are back (localStorage is per profile)
//       C2 the view token is gone (sessionStorage is per tab)
//       C3 the Pinia-only flag is at its default
//     SIGN OUT (session store logout), then sign in as HUM-2 (SPL-2556):
//       O1 the read cursors (localStorage spool.read-cursors) are gone, so
//          HUM-2 does not start from HUM-1's read marks
//       O2 the view token is gone from this tab's sessionStorage
//
//   CONTROL: STATE_CONTROL=1 also copies the view token into localStorage, as
//   a regression that kept the secret per profile would: S7 and C2 go red.
//
// Run:
//   pnpm run test:e2e client-state-reload
//   BASE_URL=<generated bundle> pnpm run test:e2e client-state-reload   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CONTROL = process.env.STATE_CONTROL === '1'
const HUM = 'HUM-1'
const NEXT_HUM = 'HUM-2'
const CURSOR_KEY = 'spool.read-cursors'
const BOX = 'form.composer.omnibox--global textarea'
const PATH = '/channel/feedback'
const DRAFT = 'kept across reload'
const TOKEN = 'e2e-view-token-not-a-secret'
/* the composer keeps a draft 300 ms after the last key */
const SAVE_WAIT = 700

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function settle(p) {
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
}

async function open(browser, base, errors) {
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)
  return p
}

/** Everything the checks read, in one evaluate. */
const snapshot = (p, token) => p.evaluate((token) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const st = pinia?.state?.value || {}
  const local = {}
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i)
    local[k] = localStorage.getItem(k)
  }
  return {
    path: location.pathname,
    box: document.querySelector('form.composer.omnibox--global textarea')?.value ?? null,
    theme: document.documentElement.getAttribute('data-theme'),
    viewToken: sessionStorage.getItem('spool.view_token'),
    editing: st.editMode ? st.editMode.isEditing : null,
    hum: st.session?.claims?.hum ?? null,
    cursors: localStorage.getItem('spool.read-cursors'),
    tokenInLocal: Object.keys(local).filter((k) => String(local[k]).includes(token)),
  }
}, token)

const server = await startServer()
const browser = await launch()
try {
  const errors = []
  const p = await open(browser, server.base, errors)
  /* a signed-in mock member (see act-as.test.mjs); a fresh profile otherwise */
  await p.evaluate((hum) => {
    localStorage.removeItem('spool.drafts')
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum, name: 'Admin', email: 'admin@example.com', t: 'mock' }))
  }, HUM)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)

  /* the theme the page did not start with, so S3 / C1 see the pick */
  const startTheme = await p.evaluate(() => document.documentElement.getAttribute('data-theme'))
  const picked = startTheme === 'dark' ? 'light' : 'dark'
  await p.evaluate((picked, token, control) => {
    localStorage.setItem('spool-theme', picked)
    sessionStorage.setItem('spool.view_token', token)
    if (control) localStorage.setItem('spool.control-leak', token)
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    pinia?._s.get('editMode')?.setEditing(true)
  }, picked, TOKEN, CONTROL)
  await p.focus(BOX)
  await p.type(BOX, DRAFT)
  await sleep(SAVE_WAIT)
  const before = await snapshot(p, TOKEN)
  ok('setup: draft typed, token in sessionStorage, Pinia flag set, signed in',
    before.box === DRAFT && before.viewToken === TOKEN && before.editing === true && before.hum === HUM, before)

  /* RELOAD */
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)
  const r = await snapshot(p, TOKEN)
  ok('S1 reload: the URL (channel) is the same', r.path === PATH, { path: r.path })
  ok('S2 reload: the composer draft is back', r.box === DRAFT, { box: r.box })
  ok('S3 reload: the theme pick is applied', r.theme === picked, { theme: r.theme, picked })
  ok('S4 reload: the view token is still in this tab\'s sessionStorage', r.viewToken === TOKEN, { viewToken: r.viewToken })
  ok('S5 reload: the Pinia-only flag is back to its default', r.editing === false, { editing: r.editing })
  ok('S6 reload: the session is rebuilt (session store reads HUM-1)', r.hum === HUM, { hum: r.hum })
  ok('S7 no localStorage value holds the view token', r.tokenInLocal.length === 0, { keys: r.tokenInLocal })
  await p.close()

  /* CLOSE the tab, open a new one */
  const q = await open(browser, server.base, errors)
  const c = await snapshot(q, TOKEN)
  ok('C1 new tab: the draft and the theme pick are back', c.box === DRAFT && c.theme === picked, { box: c.box, theme: c.theme })
  ok('C2 new tab: the view token is gone', !c.viewToken && c.tokenInLocal.length === 0, { viewToken: c.viewToken, keys: c.tokenInLocal })
  ok('C3 new tab: the Pinia-only flag is at its default', c.editing === false, { editing: c.editing })

  /* SIGN OUT on this tab, then the next member signs in on the same browser */
  await q.evaluate((token) => sessionStorage.setItem('spool.view_token', token), TOKEN)
  const a = await snapshot(q, TOKEN)
  ok('sign-out setup: HUM-1 has read cursors and a view token',
    Boolean(a.cursors && a.cursors !== '{}') && a.viewToken === TOKEN, { cursors: a.cursors, viewToken: a.viewToken })
  await q.evaluate(async () => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    await pinia?._s.get('session')?.logout()
  })
  await q.waitForFunction(() => location.pathname.endsWith('/login'), { timeout: NAV_TIMEOUT })
  const out = await q.evaluate((key) => ({
    cursors: localStorage.getItem(key),
    viewToken: sessionStorage.getItem('spool.view_token'),
  }), CURSOR_KEY)
  await q.evaluate((hum) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum, name: 'Member', email: 'member@example.com', t: 'mock' }))
  }, NEXT_HUM)
  await q.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(q)
  const b = await snapshot(q, TOKEN)
  ok('O1 sign-out: HUM-1\'s read cursors are gone before HUM-2 signs in', out.cursors === null && b.hum === NEXT_HUM,
    { atSignOut: out.cursors, hum: b.hum })
  ok('O2 sign-out: the view token is gone from this tab', out.viewToken === null && !b.viewToken,
    { atSignOut: out.viewToken, afterSignIn: b.viewToken })
  ok('no page error', errors.length === 0, errors)
  await q.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
