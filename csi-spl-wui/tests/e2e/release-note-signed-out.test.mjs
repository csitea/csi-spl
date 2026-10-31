// A release link opened signed out shows its note (owner HUM-10, t1 topic
// 2e46fcb6 msg daf6efcf, answering poll 85db75eb row 7, SPL-4530: "A -
// Release notes are public: the page shows the note without signing in").
//
// A settled signed-out visitor (the mock opts into it, MOCK_SIGNED_OUT_KEY)
// opens /releases/<sha> cold: the page stays on /releases (no /login), the
// note's lay and technical text show, and the page logs 0 console errors, 0
// page errors and no 4xx/5xx answer; "Back to the list" lists the versions
// (the dialog reads the list first), and a version link shows its changes.
// CONTROL: the same visitor on a doc that is not public is still sent to
// /login, so the run really is signed out.
//
// The mock tenant answers release notes in the page (no hub), so this guards
// the signed-out page, not the hub's door: the 401 this fixes is held red by
// the hub's TestReleaseNotesVisitorRead (release_notes_test.go).
//
// Run: node tests/e2e/release-note-signed-out.test.mjs
//      BASE_URL=<generated mock bundle> node tests/e2e/release-note-signed-out.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { watchPage, printPageLog } from './lib/page-log.mjs'
import { MOCK_SIGNED_OUT_KEY } from '../../src/utils/act-as-mock.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the mock tenant's first release note (release-notes-api.mjs mockNote(0)) */
const SHA = '00000001'.repeat(5)
const VERSION = 'v0.1.69'
const MEMBERS_DOC = 'csi-spl-doc/doc/md/csi-spl.feature.md'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
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

/** A signed-out page that records its console errors, page errors and bad answers. */
async function visitorPage(browser) {
  const p = watchPage(await browser.newPage(), 'signed-out')
  const seen = { console: [], page: [], bad: [] }
  p.on('console', (m) => { if (m.type() === 'error') seen.console.push(m.text().slice(0, 200)) })
  p.on('pageerror', (e) => seen.page.push(String(e?.message ?? e).slice(0, 200)))
  p.on('response', (r) => { if (r.status() >= 400) seen.bad.push(`${r.status()} ${new URL(r.url()).pathname}`) })
  await p.setViewport({ width: 1280, height: 800 })
  await p.setBypassServiceWorker(true)
  await p.evaluateOnNewDocument((key) => { try { localStorage.setItem(key, 'true') } catch { /* no storage: the checks below fail */ } }, MOCK_SIGNED_OUT_KEY)
  return { p, seen }
}

const noteText = (p) => p.evaluate(() => ({
  path: location.pathname,
  lay: document.querySelector('[data-test=release-note-lay]')?.textContent.replace(/\s+/g, ' ').trim() || '',
  tech: document.querySelector('[data-test=release-note-tech]')?.textContent.replace(/\s+/g, ' ').trim() || '',
}))

const server = await startServer()
const browser = await launch()
try {
  const { p, seen } = await visitorPage(browser)
  await p.goto(`${server.base}/releases/${SHA}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=release-note-lay]', { timeout: 15000 }).catch(() => {})
  const n = await noteText(p)
  ok('signed out, /releases/<sha> stays on the page', n.path.endsWith(`/releases/${SHA}`), n.path)
  ok('signed out, the note\'s lay text shows', /Change number 1 makes something easier to use/.test(n.lay), n.lay)
  ok('signed out, the note\'s technical text shows', /Mock module 1 handles the case/.test(n.tech), n.tech)

  /* the dialog reads the list first (ReleaseNotesDialog start()): "Back to
     the list" shows it */
  const back = await p.$('[data-test=release-note-back]')
  if (back) await back.click()
  await p.waitForFunction(() => document.querySelectorAll('[data-test=release-notes] .rn-ver__name').length > 1, { timeout: 15000 }).catch(() => {})
  const listed = await p.$$eval('[data-test=release-notes] .rn-ver__name', (els) => els.length).catch(() => 0)
  ok('signed out, "Back to the list" lists the versions', listed > 1, { back: !!back, listed })

  await p.goto(`${server.base}/releases/${VERSION}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=release-notes]', { timeout: 15000 }).catch(() => {})
  const v = await p.evaluate(() => ({ path: location.pathname, text: document.querySelector('[data-test=release-notes]')?.textContent || '' }))
  ok('signed out, /releases/<version> shows that version\'s changes', v.path.endsWith(`/releases/${VERSION}`) && /mock change 3/.test(v.text), { path: v.path, text: v.text.slice(0, 160) })

  ok('signed out, 0 console errors', seen.console.length === 0, seen.console)
  ok('signed out, 0 page errors', seen.page.length === 0, seen.page)
  ok('signed out, no 4xx/5xx answer', seen.bad.length === 0, seen.bad)

  /* CONTROL: the run is signed out: a doc that is not public goes to /login
     (tests/e2e/docs.test.mjs, owner HUM-10 e3ce4c34) */
  await p.goto(`${server.base}/docs/${MEMBERS_DOC}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => location.pathname.endsWith('/login'), { timeout: 15000 }).catch(() => {})
  ok('CONTROL signed out, a members-only doc goes to /login', new URL(p.url()).pathname.endsWith('/login'), p.url())
  await p.close()
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nrelease-note-signed-out: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
