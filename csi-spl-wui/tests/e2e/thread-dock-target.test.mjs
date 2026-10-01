// SPL-1003 (epic SPL-988): on a phone, a post made while a thread is open goes
// INTO that thread (is_parent 0, the thread's task), and the docked composer
// says so before the send. The owner (prd t1 #spool-hub-mobile, 12:10:52Z,
// 2026-09-27): "When I write to the right most pane for the msgs aka threads
// on mobile it does not add the msg to the threads but on the topic pane" -
// that line itself was stored is_parent 1, a new topic.
//
//   phone (390x844, 820x1180, touch), /channel/alerts:
//     1 level 2 (the list): the dock reads "New topic in #alerts"
//     2 tap a card (level 3, its thread): the dock reads "Replying in the
//       open thread"; post -> is_parent 0 on that thread's task, drawn in the
//       thread only, not as a card in the list
//     3 Back (level 2): the dock reads "New topic" again; post -> is_parent 1,
//       a new card in the list
//     CONTROL: before SPL-1003 the dock named no target at all (1-3 fail on
//     the hint).
//   desktop (1440x900): no dock hint anywhere, the thread still takes the post.
//   t1 dd98f8d7 (owner, 2026-10-01): on a phone the dock says it with its
//   accent edge (data-mode) and placeholder only - no text line above it.
//
// Run:
//   pnpm run test:e2e thread-dock-target
//   BASE_URL=<generated bundle> pnpm run test:e2e thread-dock-target   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'

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

/** The open thread, the phone level and the dock's mode as drawn. Since the
 *  owner's t1 dd98f8d7 ("remove also all of the texts on mobile above the
 *  omnibox") the phone dock draws NO line: its mode is the form's data-mode
 *  (the accent edge) and its target the placeholder. `line` is any visible
 *  text line over a composer - it must stay null on a phone. */
function state(p) {
  return p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
    const line = [...document.querySelectorAll('[data-test=dock-target]')].find((el) => el.getClientRects().length > 0)
    const dock = document.querySelector('form.composer[data-docked=true]')
    return {
      thread: (s.topic && s.topic.open && s.topic.parentTaskId) || (s['live-pane'] && s['live-pane'].taskId) || '',
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
      hint: dock ? { mode: dock.getAttribute('data-mode'), text: dock.querySelector('textarea')?.placeholder || '' } : null,
      line: line ? line.textContent.trim() : null,
    }
  })
}

/** The row this page sent, found by its text, and where it is drawn. */
function sentRow(p, text) {
  return p.evaluate((body) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
    const pools = [s.channel && s.channel.messages, s['live-pane'] && s['live-pane'].messages].filter(Array.isArray)
    const m = pools.flat().find((x) => String(x.body || '').includes(body))
    if (!m) return null
    const sel = `article.msg[data-msg-id="${CSS.escape(String(m.msg_id))}"]`
    const shown = (root) => [...document.querySelectorAll(`${root} ${sel}`)].filter((el) => el.getClientRects().length > 0).length
    return {
      task_id: m.task_id,
      parent_task_id: m.parent_task_id || '',
      is_parent: m.is_parent,
      list: document.querySelectorAll(`.spool-main ${sel}`).length,
      thread: shown('aside.live-pane'),
    }
  }, text)
}

async function firstCard(p) {
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    /* the line's own text: the header's badge / time / menu are buttons */
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
}

async function send(p, text) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.focus(ta)
  await p.type(ta, text)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(800)
}

async function open(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(400)
  return { p, errors }
}

const isReplyInto = (r, task) => Boolean(r && task && r.is_parent === 0 && (r.task_id === task || r.parent_task_id === task))

async function phoneCase(browser, width, height) {
  const tag = `${width}px`
  const { p, errors } = await open(browser, { width, height, isMobile: true, hasTouch: true })
  const s1 = await state(p)
  ok(`${tag} 1 the list (level 2): the dock says a post starts a new topic in #alerts`,
    s1.level === '2' && Boolean(s1.hint && s1.hint.mode === 'new' && s1.hint.text.includes('#alerts')) && s1.line === null, s1)

  const card = await firstCard(p)
  await p.touchscreen.tap(card.x, card.y)
  await sleep(700)
  const s2 = await state(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `thread-dock-target-${width}-thread.png`) })
  const inThread = `spl1003 in thread ${width} ${Date.now()}`
  await send(p, inThread)
  const r2 = await sentRow(p, inThread)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `thread-dock-target-${width}-sent.png`) })
  ok(`${tag} 2 a thread open (level 3): the dock says the post replies in the open thread`,
    s2.level === '3' && Boolean(s2.thread) && Boolean(s2.hint && s2.hint.mode === 'thread' && s2.hint.text.startsWith('Reply')) && s2.line === null, s2)
  ok(`${tag} 2 the post is stored is_parent 0 on the thread's task, drawn in the thread, not as a list card`,
    isReplyInto(r2, s2.thread) && r2.thread === 1 && r2.list === 0, { thread: s2.thread, r2 })

  await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-testid=mobile-back]')].find((el) => el.getClientRects().length > 0)
    b && b.click()
  })
  await sleep(700)
  const s3 = await state(p)
  const fresh = `spl1003 after back ${width} ${Date.now()}`
  await send(p, fresh)
  const r3 = await sentRow(p, fresh)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `thread-dock-target-${width}-back.png`) })
  ok(`${tag} 3 Back (level 2): the dock says new topic again`,
    s3.level === '2' && !s3.thread && Boolean(s3.hint && s3.hint.mode === 'new') && s3.line === null, s3)
  ok(`${tag} 3 the post after Back is a new topic (is_parent 1), a card in the list`,
    Boolean(r3 && r3.is_parent === 1 && r3.task_id !== s2.thread && r3.list === 1), r3)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

async function desktopCase(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 })
  const s0 = await state(p)
  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  await sleep(600)
  const s1 = await state(p)
  const text = `spl1003 desktop ${Date.now()}`
  await send(p, text)
  const r = await sentRow(p, text)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'thread-dock-target-1440.png') })
  ok('1440px no dock hint on the desktop (list, or a thread open)', s0.hint === null && s1.hint === null
    && (await p.$$('[data-test=dock-target]')).length === 0, { s0, s1 })
  ok('1440px the open thread still takes the post (is_parent 0), drawn there only', isReplyInto(r, s1.thread) && r.thread === 1 && r.list === 0, r)
  ok('1440px no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 })).p.close()
  await phoneCase(browser, 390, 844)
  await phoneCase(browser, 820, 1180)
  await phoneCase(browser, 360, 740)
  await desktopCase(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
