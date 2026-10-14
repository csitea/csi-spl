// SPL-1871 (owner HUM-10, t1 c3396e3c, msgs bc6b8f4f, 35426028, 360fc226,
// a2d74ddc): "the form is shown even only 5 rows should be visible"; "the
// behaviour shoudl be the same as with the links previews ... if the user has
// 5 rows he see only 5 rows of content", and to see it all he clicks.
//
// A 3-question x 4-radio ```poll form as a topic card in the middle pane at
// the 5-row height (the default): the card shows at most 5 rows and is cut
// (fade + grip, as a card with link previews is); a radio inside the shown
// rows answers; the answers line shows inside the 5 rows; the grip (the
// card's "see all") opens it all in place and a radio of the last question
// answers too. 1440 desktop and 390 phone, no sideways scroll.
//
// Cause (v9.0.2): MessageCard.vue exempted a card holding a ```poll form
// from the clip (SPL-1637 `!hasPoll`), so the form drew at full height.
//
// Run:
//   pnpm run test:e2e poll-card-clip
//   BASE_URL=<generated bundle> pnpm run test:e2e poll-card-clip   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per state there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
const ROWS = 5
const SLACK_PX = 2

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

const q = (n) => `Step ${n}: which way?\n(A) The first way\n(B) The second way\n(C) The third way\n(D) The fourth way`
const POLL = `Waiting for you: 3 step(s)\n\n\`\`\`poll\n${[1, 2, 3].map(q).join('\n')}\n\`\`\``

async function open(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  })
  return { p, errors }
}

/* the form as a new topic card in the channel */
function seedPoll(p) {
  return p.evaluate((body) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const row = { v: 1, msg_id: crypto.randomUUID(), task_id: crypto.randomUUID(), ts: new Date().toISOString(), from: 'CLE-07', to: '@channel', kind: 'note', body, files: [], channel: channel.active || 'alerts', parent_task_id: null, is_parent: 1 }
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, row]
    return row.msg_id
  }, POLL)
}

/* the card as drawn: its body box, the line height, the form, each question
   and the answers line, all relative to the body box's top */
function cardNow(sel) {
  const card = document.querySelector(sel)
  if (!card) return null
  const body = card.querySelector('[data-testid=card-body]')
  const form = card.querySelector('[data-testid=poll-form]')
  if (!body || !form) return null
  const b = body.getBoundingClientRect()
  const lh = parseFloat(getComputedStyle(card.querySelector('.msg-body') || body).lineHeight) || 0
  const rel = (el) => { const r = el.getBoundingClientRect(); return { top: Math.round(r.top - b.top), bottom: Math.round(r.bottom - b.top) } }
  const answers = form.querySelector('[data-testid=poll-answers]')
  return {
    clip: body.dataset.clip || '',
    bodyH: Math.round(b.height),
    lh: Math.round(lh * 100) / 100,
    formH: Math.round(form.getBoundingClientRect().height),
    grip: Boolean(card.querySelector('[data-testid=card-grip]')),
    questions: [...form.querySelectorAll('[data-testid=poll-question]')].map(rel),
    answers: answers ? rel(answers) : null,
    pageX: document.scrollingElement.scrollWidth - document.scrollingElement.clientWidth,
    cardX: card.scrollWidth - card.clientWidth,
  }
}

/* the page at rest: the card reads the same for 12 frames in a row */
async function rest(p, sel) {
  const t0 = Date.now()
  let last = ''
  let still = 0
  while (Date.now() - t0 < NAV_TIMEOUT) {
    const now = JSON.stringify(await p.evaluate(cardNow, sel))
    still = now === last && now !== 'null' ? still + 1 : 0
    if (still >= 12) return JSON.parse(now)
    last = now
    await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())))
  }
  throw new Error(`the card did not come to rest in ${NAV_TIMEOUT} ms`)
}

function replies(p, id) {
  return p.evaluate((id) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    return (pinia.state.value.channel.messages || []).filter((m) => String(m.body || '').includes(`Poll: ${id}`)).length
  }, id)
}

async function waitReplies(p, id, n) {
  const t0 = Date.now()
  while (Date.now() - t0 < 10000) {
    if (await replies(p, id) >= n) return n
    await sleep(100)
  }
  return replies(p, id)
}

/* where option `key` of question `qi` is, and whether its middle is inside the body box */
function optionSpot(p, sel, qi, key) {
  return p.evaluate((sel, qi, key) => {
    const card = document.querySelector(sel)
    const b = card.querySelector('[data-testid=card-body]').getBoundingClientRect()
    const o = card.querySelectorAll('[data-testid=poll-question]')[qi].querySelector(`[data-testid=poll-option][data-poll-key=${key}]`)
    const r = o.getBoundingClientRect()
    const x = Math.round(r.left + Math.min(10, r.width / 2))
    const y = Math.round(r.top + r.height / 2)
    return { x, y, inside: y > b.top && y < b.bottom }
  }, sel, qi, key)
}

async function tap(p, spot, touch) {
  if (touch) await p.touchscreen.tap(spot.x, spot.y)
  else await p.mouse.click(spot.x, spot.y)
}

async function clipCase(browser, vp, tag) {
  const touch = Boolean(vp.hasTouch)
  const { p, errors } = await open(browser, vp)
  const id = await seedPoll(p)
  const sel = `.spool-main article.msg[data-msg-id="${id}"]`
  await p.waitForSelector(`${sel} [data-testid=poll-form]`, { timeout: 15000 })
  await p.evaluate((sel) => document.querySelector(sel).scrollIntoView({ block: 'center' }), sel)
  const cut = await rest(p, sel)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-card-clip-${tag}-cut.png`) })
  const maxH = ROWS * cut.lh + SLACK_PX
  ok(`${tag}: the card with a 3-question form shows at most ${ROWS} rows, cut, with the grip`, cut.clip === 'cut' && cut.lh > 0 && cut.bodyH <= maxH && cut.formH > cut.bodyH && cut.grip, { ...cut, maxH })
  ok(`${tag}: no sideways scroll (page and card)`, cut.pageX <= 0 && cut.cardX <= 0, { pageX: cut.pageX, cardX: cut.cardX })

  /* a radio inside the shown rows answers, as it does today */
  const a = await optionSpot(p, sel, 0, 'A')
  await tap(p, a, touch)
  const n1 = await waitReplies(p, id, 1)
  const answered = await rest(p, sel)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-card-clip-${tag}-answered.png`) })
  ok(`${tag}: a radio inside the ${ROWS} rows answers (one reply)`, a.inside && n1 === 1, { a, n1 })
  ok(`${tag}: the answered form shows its answers line within the ${ROWS} rows`, answered.clip === 'cut' && answered.bodyH <= maxH && Boolean(answered.answers) && answered.answers.bottom <= answered.bodyH, { answers: answered.answers, bodyH: answered.bodyH })

  /* see all: the grip opens the whole card in place */
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=card-grip]`)?.click(), sel)
  const all = await rest(p, sel)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-card-clip-${tag}-all.png`) })
  const last = all.questions[all.questions.length - 1]
  ok(`${tag}: the grip shows all of it: every question inside the card`, all.clip === 'fits' && all.questions.length === 3 && Boolean(last) && last.bottom <= all.bodyH, { clip: all.clip, bodyH: all.bodyH, last })
  const c = await optionSpot(p, sel, 2, 'C')
  await tap(p, c, touch)
  const n2 = await waitReplies(p, id, 2)
  ok(`${tag}: after see all, a radio of the last question answers`, c.inside && n2 === 2, { c, n2 })
  const after = await rest(p, sel)
  ok(`${tag}: no sideways scroll after see all`, after.pageX <= 0 && after.cardX <= 0, { pageX: after.pageX, cardX: after.cardX })
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESKTOP = { width: 1440, height: 900 }
const server = await startServer()
const browser = await launch()
try {
  await clipCase(browser, DESKTOP, '1440px')
  await clipCase(browser, PHONE, '390px')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
