// 080 T005 (FR-006, FR-007, AC5): while the box holds text, a chip at its
// start names where Enter sends. g-248 A3 found the old "where it goes" line
// empty in every view: it rendered only over the bottom dock, and the
// placeholder that named the target was erased by the first key.
//
//   mock tenant, signed in as HUM-1, 1440x900, /lobby:
//     1 an empty box: no chip (owner, t1 7d777e79: nothing outside the text)
//     2 type `abc` -> the chip reads `#lobby`, inside the box, the text after it
//     3 click a topic card (the right pane opens), type -> `Reply · <title>`
//     4 a line that dispatches (`@CLE-07 do x`) -> still `Reply · <title>`
//       (owner 2026-10-05, t1 dc6d5e3f, decision c3f0f2cf retired SPL-996 B)
//     5 `/search x` -> no chip
//     6 close the pane, pick a topic with `in:` -> `Reply · <that title>`;
//       a click on the chip opens it (spec Q3: /t/<task_id>)
//     7 Settings bottom position: the chip is in the bottom dock too
//     CONTROL: before T005 no [data-test=composer-target-chip] existed (2-4, 6,
//     7 fail); the old line showed only at the bottom and never in the top bar.
//
// Run:
//   pnpm run test:e2e composer-target-chip
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-target-chip   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
if (SHOTS) mkdirSync(SHOTS, { recursive: true })
const MOCK_SESSION = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }
const BOX = 'form.composer.omnibox--global textarea'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = (p, name) => (SHOTS ? p.screenshot({ path: join(SHOTS, `composer-target-chip-${name}.png`) }) : null)

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

/** The visible chip: its words, and whether it sits in the box ahead of the text. */
function chip(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    if (!f) return { form: false }
    const c = [...f.querySelectorAll('[data-test=composer-target-chip]')].find(vis)
    const field = f.querySelector('.omnibox-field')
    const ta = f.querySelector('textarea')
    if (!c || !field || !ta) return { form: true, text: null, bottom: f.classList.contains('omnibox--bottom') }
    const a = c.getBoundingClientRect()
    const b = field.getBoundingClientRect()
    const t = ta.getBoundingClientRect()
    const textStart = t.left + parseFloat(getComputedStyle(ta).paddingLeft)
    return {
      form: true,
      text: c.textContent.trim(),
      mode: c.getAttribute('data-mode'),
      inBox: a.left >= b.left && a.right <= b.right && a.top >= b.top && a.bottom <= b.bottom,
      clear: Math.round(textStart - a.right),
      bottom: f.classList.contains('omnibox--bottom'),
    }
  })
}

async function setText(p, s) {
  await p.$eval(BOX, (el) => { el.focus(); el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  if (s) await p.type(BOX, s)
  await sleep(300)
}

async function firstCard(p) {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
}

const waitMode = (p, mode) => p.waitForFunction((m) => {
  const f = [...document.querySelectorAll('form.composer.omnibox--global')].find((el) => el.getClientRects().length > 0)
  return f && f.getAttribute('data-mode') === m
}, { timeout: 15000 }, mode).then(() => true, () => false)

/** Adopt a member session with a composer position (omnibox-bottom.test.mjs). */
const setPosition = (p, pos) => p.evaluate((pos) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ ...(session.claims || {}), hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', composer_position: pos })
  return true
}, pos)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.removeItem('spool.drafts')
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
    } catch { /* private mode */ }
  }, MOCK_SESSION)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await firstCard(p)
  await waitMode(p, 'new')
  await sleep(400)

  const c1 = await chip(p)
  ok('1 an empty box has no chip', c1.form && c1.text === null, c1)

  await setText(p, 'abc')
  const c2 = await chip(p)
  await shot(p, '2-lobby')
  ok('2 with text on /lobby the chip reads "#lobby", inside the box, the text clear of it',
    c2.text === '#lobby' && c2.inBox === true && c2.clear >= 2 && !c2.bottom, c2)

  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  const opened = await waitMode(p, 'thread')
  /* a reply is another place: T003 parks `abc` under ch:lobby and the box is empty */
  await setText(p, 'def')
  const c3 = await chip(p)
  await shot(p, '3-reply')
  ok('3 a topic card opens the right pane: the chip reads "Reply · <title>"',
    opened && typeof c3.text === 'string' && c3.text.startsWith('Reply · ') && c3.text.length > 'Reply · '.length && c3.mode === 'thread' && c3.inBox, { opened, ...c3 })

  await setText(p, '@CLE-07 do x')
  const c4 = await chip(p)
  ok('4 a line that dispatches stays a reply with the pane open: "Reply · <title>"', c4.text === c3.text && c4.mode === 'thread', { c3: c3.text, ...c4 })

  await setText(p, '/search x')
  const c5 = await chip(p)
  ok('5 /search: no chip', c5.form && c5.text === null, c5)

  /* close the pane: the line goes to #lobby again */
  await setText(p, '')
  await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-test=topic-pane-close],[data-test=live-topic-close]')].find((el) => el.getClientRects().length > 0)
    b?.click()
  })
  await waitMode(p, 'new')
  await setText(p, 'in: ')
  const picked = await p.waitForSelector('[data-test=topic-in-suggestions] button', { visible: true, timeout: 10000 })
    .then(async (b) => {
      const title = await b.$eval('.mention-label', (el) => el.textContent.trim())
      await b.evaluate((el) => el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })))
      return title
    }, () => '')
  await p.type(BOX, 'x')
  await sleep(300)
  const c6 = await chip(p)
  await shot(p, '6-in')
  ok('6 a line that names a topic with in: wears that topic\'s reply chip', Boolean(picked) && c6.text === `Reply · ${picked}`, { picked, ...c6 })
  const before = await p.evaluate(() => location.pathname)
  await p.click('[data-test=composer-target-chip]')
  const went = await p.waitForFunction(() => /\/t\/[^/]+$/.test(location.pathname), { timeout: 15000 }).then(() => true, () => false)
  const after = await p.evaluate(() => location.pathname)
  ok('6 a click on the chip opens that topic (spec Q3)', went && after !== before, { before, after })

  /* 7: the bottom position */
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await firstCard(p)
  const adopted = await setPosition(p, 'bottom')
  await p.waitForSelector('form.composer.omnibox--bottom', { timeout: 10000 }).catch(() => null)
  await setText(p, 'abc')
  const c7 = await chip(p)
  await shot(p, '7-bottom')
  ok('7 bottom position: the same chip, in the dock box', adopted && c7.bottom === true && c7.text === '#lobby' && c7.inBox === true && c7.clear >= 2, { adopted, ...c7 })

  ok('no page error', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
