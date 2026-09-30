// CLE-77786 (owner, prd t1 topic 110d842c): an issue comment is a message card
// like any other, so its author should reach the same affordances a channel
// message has, and the box should save like the issue description does.
//
// In a real browser on the mock tenant, 1440 px:
//   - typing a comment and clicking ELSEWHERE (blur) posts it - not only Enter,
//     mirroring the issue description autosave
//   - right-click on a comment opens the shared card menu WITH Edit (and Delete)
//   - double-click on a comment opens its editor in place
//
// CONTROL: on the build before this change the comment MessageCard got no
// :editable, so the menu had no Edit item and double-click did nothing; and the
// box saved only on Enter, so the blur check posted nothing. All three fail.
//
// Run:
//   node tests/e2e/issue-comment-edit.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/issue-comment-edit.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const COMMENT = '[data-test=issues-comment]'
const INPUT = '[data-test=issues-comment-input]'

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
        headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const commentShown = (p, text) => p.waitForFunction(
  (sel, t) => [...document.querySelectorAll(sel)].some((c) => c.innerText.includes(t)),
  { timeout: 8000 }, COMMENT, text,
).then(() => true).catch(() => false)

/* the desktop create flow (issue-dock-comment.test.mjs), then the issue is open
   with its discussion box on screen */
async function createIssue(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  const key = await p.waitForFunction((want) => {
    const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
    return r ? r.getAttribute('data-key') : false
  }, { timeout: 8000 }, title).then((h) => h.jsonValue())
  await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  await p.waitForSelector(INPUT, { timeout: 8000 })
  await sleep(400)
  return key
}

/** dispatch a real bubbling mouse event on the nth comment card. */
const fireOnComment = (p, type, idx = 0) => p.evaluate((sel, type, idx) => {
  const c = document.querySelectorAll(sel)[idx]
  if (!c) return false
  const r = c.getBoundingClientRect()
  c.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX: Math.round(r.left + 20), clientY: Math.round(r.top + 10) }))
  return true
}, COMMENT, type, idx)

/* Double-click the nth comment's BODY. The event's target is the rendered text
   element (a body child), exactly as a real double-click lands - puppeteer's
   clickCount:2 does not emit a `dblclick` in headless Chrome, so this fires the
   real DOM event the card listens for. */
const dblClickCommentBody = (p, idx = 0) => p.evaluate((sel, idx) => {
  const c = document.querySelectorAll(sel)[idx]
  const body = c?.querySelector('[data-testid=card-body]')
  if (!body) return false
  const target = body.querySelector('*') || body
  target.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, button: 0 }))
  return true
}, COMMENT, idx)

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic
     import (issue-dock-comment.test.mjs does the same) */
  {
    const w = await browser.newPage()
    await w.goto(`${server.base}/issues`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => {})
    await w.waitForSelector('[data-test=issues-page]', { timeout: NAV_TIMEOUT }).catch(() => {})
    await sleep(300)
    await w.close()
  }
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/issues`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await sleep(400)
  await createIssue(p, 'Comment affordances')

  /* seed one comment (the Enter path, which always worked) to act on later */
  const seed = `seed comment ${Date.now()}`
  await p.focus(INPUT)
  await p.type(INPUT, seed)
  await p.keyboard.press('Enter')
  ok('seed comment posts on Enter', await commentShown(p, seed))

  /* ---- A1: a comment saves when the box loses focus (a click elsewhere) ---- */
  const blurNote = `blur comment ${Date.now()}`
  await p.focus(INPUT)
  await p.type(INPUT, blurNote)
  await p.$eval(INPUT, (el) => el.blur())
  const blurShown = await commentShown(p, blurNote)
  const emptied = await p.$eval(INPUT, (el) => el.value === '')
  ok('A1 comment posts on blur (click elsewhere), not only Enter', blurShown, { blurShown })
  ok('A1 the box empties after the blur post', emptied, { emptied })

  /* two comments now (seed + blur). A3 and A4 act on SEPARATE cards, and A4
     runs first: opening one card's editor must not decide the other card's
     menu, and the right-click menu is only asked once no editor is open. */
  await p.waitForFunction((sel) => document.querySelectorAll(sel).length >= 2, { timeout: 5000 }, COMMENT).catch(() => {})
  const nComments = await p.$$eval(COMMENT, (els) => els.length)
  ok('two comments are on screen', nComments >= 2, { nComments })

  /* ---- A4: double-click the first comment opens its editor in place ---- */
  await dblClickCommentBody(p, 0)
  const editBox = await p.waitForFunction(
    (sel) => document.querySelectorAll(`${sel}`)[0]?.querySelector('[data-test=msg-edit-box]'),
    { timeout: 5000 }, COMMENT,
  ).then(() => true).catch(() => false)
  ok('A4 double-click opens the comment editor', editBox)

  /* ---- A3: right-click the SECOND comment -> the shared card menu, with Edit ---- */
  await fireOnComment(p, 'contextmenu', 1)
  const menuUp = await p.waitForSelector('[data-testid=msg-menu]', { timeout: 5000 }).then(() => true).catch(() => false)
  const hasEdit = await p.evaluate(() => !!document.querySelector('[data-testid=msg-menu-edit]'))
  const hasDelete = await p.evaluate(() => !!document.querySelector('[data-testid=msg-menu-delete]'))
  ok('A3 right-click opens the shared card menu', menuUp)
  ok('A3 the menu offers Edit on the author\'s own comment', hasEdit, { hasEdit })
  ok('A2/A3 the menu offers Delete too', hasDelete, { hasDelete })
  await p.keyboard.press('Escape')
  await sleep(200)

  /* the generated bundle CI runs against never hits this; `nuxi dev` under a
     loaded box can drop a chunk's first dynamic import, which is not our bug */
  const realErrors = errors.filter((e) => !/dynamically imported module|Importing a module script failed/.test(e))
  ok('no page error', realErrors.length === 0, realErrors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `issue-comment-edit: ${results.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
