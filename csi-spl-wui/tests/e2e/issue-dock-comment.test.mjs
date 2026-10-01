// (owner, prd t1 topic 110d842c, 2026-09-28): "In issues on mobile,
// clicking on the omnibox, typing and clicking the GO button does not create
// a comment". /issues registered no omnibox send target, so the phone dock's
// GO returned without a word. Now, in a real browser on the mock tenant:
//   - an issue open on a phone (level 3): the dock says "Commenting on SPL-n",
//     GO posts the line as a comment on that issue (it shows in the issue's
//     discussion, the dock empties, the page stays), `/search` still searches
//   - the list: the dock says it is search-only, GO with plain text searches
//   - 1440: the Omnibox has no dock and sends nothing from /issues (unchanged)
// CONTROL: on the build before CLE-35066 the 'comment' and 'list GO searches'
// checks fail (GO does nothing, the text stays in the box).
//
// Run:
//   pnpm run test:e2e:issue-dock-comment
//   BASE_URL=<generated bundle> pnpm run test:e2e:issue-dock-comment   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const DOCK = 'form.composer.omnibox--global'
const FIELD = `${DOCK} textarea`

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

async function openIssues(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await setPageViewport(p, vp)
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  /* `nuxi dev` floats its devtools button over the bottom of a phone screen */
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  await sleep(500)
  return { p, errors }
}

/** the dock's "where does it go" line, its field and where the page is */
function look(p) {
  return p.evaluate((dockSel) => {
    const dock = document.querySelector(dockSel)
    /* t1 dd98f8d7: no text line over the phone dock - the mode is the
       form's data-mode, the words are the placeholder */
    const line = dock && dock.querySelector('[data-test=dock-target]')
    const vis = (el) => Boolean(el && el.getClientRects().length > 0)
    return {
      docked: Boolean(dock && dock.classList.contains('composer--dock')),
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
      mode: dock ? (dock.getAttribute('data-mode') || '') : '',
      hint: dock ? (dock.querySelector('textarea')?.placeholder || '') : '',
      line: vis(line),
      field: dock ? (dock.querySelector('textarea')?.value || '') : null,
      goDisabled: dock ? dock.querySelector('[data-testid=send]')?.getAttribute('aria-disabled') : null,
      path: location.pathname,
      q: new URLSearchParams(location.search).get('q') || '',
    }
  }, DOCK)
}

async function typeAndGo(p, text) {
  await p.focus(FIELD)
  await p.type(FIELD, text)
  /* GO is [data-testid=send], or [data-test=omnibox-search] once the line is a /search */
  await p.click(`${DOCK} [data-testid=send], ${DOCK} [data-test=omnibox-search]`)
}

/* the mock tenant starts with no issues and keeps them in the page: make
   one (the FAB on a phone, + on a desktop); Create leaves it open */
async function createIssue(p, title) {
  await p.click('[data-test=issues-new]')
  if (await p.evaluate(() => window.innerWidth > 820)) {
    /* SPL-1027: > 820 px a new issue is the sheet's top row, opened as a modal */
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    const key = await p.waitForFunction((want) => {
      const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
      return r ? r.getAttribute('data-key') : false
    }, { timeout: 5000 }, title).then((h) => h.jsonValue())
    await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
    await p.waitForSelector('[data-test=issues-comment-input]', { timeout: 8000 }).catch(() => {})
    await sleep(400)
    return key
  }
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-title]', title)
  await p.click('[data-test=issues-create]')
  await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
  await p.waitForSelector('[data-test=issues-comment-input]', { timeout: 8000 }).catch(() => {})
  await sleep(400)
  return p.$eval('[data-test=issues-detail-key]', (e) => e.textContent.trim())
}

const commentShown = (p, text) => p.waitForFunction(
  (t) => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => c.innerText.includes(t)),
  { timeout: 8000 }, text,
).then(() => true).catch(() => false)

async function phoneCase(browser, width, height) {
  const tag = `${width}px`
  const vp = { width, height, isMobile: true, hasTouch: true }

  /* the list: search-only, and GO says so by searching */
  {
    const { p, errors } = await openIssues(browser, vp)
    const l = await look(p)
    ok(`${tag} list: the dock says it is search-only`, l.docked && l.mode === 'search' && l.hint.length > 0 && !l.line, l)
    const q = `cle35066list${width}`
    await typeAndGo(p, q)
    await p.waitForFunction(() => location.pathname.endsWith('/search'), { timeout: 8000 }).catch(() => {})
    const after = await look(p)
    ok(`${tag} list: GO with plain text opens /search?q=<text> (never nothing)`, after.path.endsWith('/search') && after.q === q, after)
    ok(`${tag} list: no page error`, errors.length === 0, errors)
    await p.close()
  }

  /* an open issue: GO comments on it */
  {
    const { p, errors } = await openIssues(browser, vp)
    const key = await createIssue(p, 'Dock comment target')
    const l = await look(p)
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `issue-dock-comment-${width}-open.png`) })
    ok(`${tag} issue open (level 3): the dock says "Commenting on <key>"`, l.docked && l.level === '3' && l.mode === 'comment' && l.hint.includes(key) && !l.line, { key, ...l })
    /* two earlier comments first: the discussion then runs below the dock,
       as it does on a real issue, so the on-screen check below can fail */
    for (const n of [1, 2]) {
      const warm = `cle35066 warm-up ${n} ${width}`
      await typeAndGo(p, warm)
      await commentShown(p, warm)
    }
    const note = `cle35066 dock comment ${width} ${Date.now()}`
    await typeAndGo(p, note)
    const shown = await commentShown(p, note)
    const after = await look(p)
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `issue-dock-comment-${width}-sent.png`) })
    ok(`${tag} issue open: GO posts the line as a comment on the open issue`, shown, after)
    /* the new comment is scrolled into view, clear of the dock - an empty dock alone reads as nothing happened */
    const seen = await p.evaluate((t, dockSel) => {
      const c = [...document.querySelectorAll('[data-test=issues-comment]')].find((x) => x.innerText.includes(t))
      const r = c && c.getBoundingClientRect()
      const dockTop = document.querySelector(dockSel)?.getBoundingClientRect().top ?? innerHeight
      return r ? { top: Math.round(r.top), bottom: Math.round(r.bottom), dockTop: Math.round(dockTop), onScreen: r.top >= 0 && r.top < dockTop } : null
    }, note, DOCK)
    ok(`${tag} issue open: the new comment is on screen above the dock`, Boolean(seen && seen.onScreen), seen)
    ok(`${tag} issue open: the dock empties and the page stays on the issue`, after.field === '' && after.path.endsWith('/issues') && after.level === '3', after)
    /* /search from the same dock still searches */
    await typeAndGo(p, '/search cle35066l3')
    await p.waitForFunction(() => location.pathname.endsWith('/search'), { timeout: 8000 }).catch(() => {})
    const s = await look(p)
    ok(`${tag} issue open: '/search <q>' from the dock still opens /search?q=`, s.path.endsWith('/search') && s.q === 'cle35066l3', s)
    ok(`${tag} issue open: no page error`, errors.length === 0, errors)
    await p.close()
  }
}

async function desktopCase(browser) {
  const { p, errors } = await openIssues(browser, { width: 1440, height: 900 })
  await createIssue(p, 'Desktop omnibox stays search')
  const l = await look(p)
  ok('1440px issue open: no dock and no "where it goes" line', !l.docked && l.mode === '', l)
  const note = `cle35066 desktop ${Date.now()}`
  await p.focus(FIELD)
  await p.type(FIELD, note)
  await p.keyboard.press('Enter')
  await sleep(800)
  const posted = await p.evaluate((t) => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => c.innerText.includes(t)), note)
  const after = await look(p)
  ok('1440px issue open: the top Omnibox still sends nothing from /issues (unchanged)', !posted && after.path.endsWith('/issues'), { posted, ...after })
  ok('1440px: no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await openIssues(browser, { width: 1440, height: 900 })).p.close()
  await phoneCase(browser, 390, 844)
  await phoneCase(browser, 820, 1180)
  await desktopCase(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
