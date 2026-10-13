// SPL-996 (epic SPL-988): a post made while a topic is open goes INTO that
// topic (is_parent 0), and every message is drawn exactly once, where it
// belongs. Measured on prd t1 #spool-hub-mobile (2026-09-27, n=4): follow-ups
// typed while a topic was open became new topics AND were drawn a second
// time at the top of the open topic (BornTopics), which read as messages
// that are "both is_parent=1 and is_parent=0".
//
//   desktop (1440x900, mouse), /channel/alerts:
//     1 open a topic, send -> is_parent 0 into it; shown in the topic, not as a middle card
//     2 open a topic, the APP focuses a middle card (a #hash, an edit close)
//       -> still a reply. CONTROL: before SPL-996 this became a new topic.
//     3 open a topic, the reader CLICKS the middle list -> still a reply into
//       the open topic (owner answer B, 2026-09-27, replaced the 09-25 "last
//       clicked pane decides" rule). CONTROL: before B this became a new topic.
//     4 open a topic, the line starts with `@CLE-07 <task>` -> still a reply
//       into the open topic (owner 2026-10-05, t1 dc6d5e3f, decision c3f0f2cf
//       retired SPL-996 B). CONTROL: under SPL-996 B it became a new topic.
//   phone (360x740, 820x1180, touch): tap a card (level 3), send from the
//     docked composer -> is_parent 0 into the open topic, not a middle card.
//   SPL-1637 poll-control, 1440 and 390: a ```poll radio form posts its answer
//     on the click (no Send), re-answer replaces, "Chat about this" opens the
//     reply box; a checkbox form waits for its lock-in or its Send.
//
// Run:
//   pnpm run test:e2e topic-send-target
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-send-target   # what CI does
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

/** The open topic's task id and the pane-focus state, read from pinia. */
function state(p) {
  return p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const s = pinia.state.value
    return {
      last: s['pane-focus'] && s['pane-focus'].last,
      topic: (s.topic && s.topic.open && s.topic.parentTaskId) || '',
      born: ((s.topic && s.topic.born) || []).length,
    }
  })
}

/** The row this page sent, found by its text, and where it is drawn. */
function sentRow(p, text) {
  return p.evaluate((body) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    const m = msgs.find((x) => String(x.body || '').includes(body))
    if (!m) return null
    const sel = `article.msg[data-msg-id="${CSS.escape(String(m.msg_id))}"]`
    const shown = (root) => [...document.querySelectorAll(`${root} ${sel}`)].filter((el) => el.getClientRects().length > 0).length
    return {
      msg_id: m.msg_id,
      task_id: m.task_id,
      parent_task_id: m.parent_task_id || '',
      is_parent: m.is_parent,
      middle: shown('.spool-main'),
      right: shown('aside.live-pane'),
      bornCards: document.querySelectorAll('[data-test=born-topics] article.msg').length,
    }
  }, text)
}

async function firstCard(p) {
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + Math.min(20, r.height / 2)) }
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

async function desktopCase(browser, n, name, between, expectReply, prefix = '') {
  const { p, errors } = await open(browser, { width: 1440, height: 900 })
  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  await sleep(600)
  const opened = await state(p)
  await between(p, card)
  const before = await state(p)
  const text = `spl996 desktop case ${n} ${Date.now()}`
  /* the stored body drops a leading @mention (it becomes the recipient) */
  await send(p, prefix + text)
  const r = await sentRow(p, text)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `topic-send-target-1440-${n}.png`) })
  if (expectReply) {
    ok(`1440px ${n} ${name}: is_parent 0 into the open topic, drawn in the topic only`,
      Boolean(opened.topic && isReplyInto(r, opened.topic) && r.middle === 0 && r.right === 1 && r.bornCards === 0),
      { opened, before, r })
  } else {
    ok(`1440px ${n} ${name}: a new topic (is_parent 1), drawn ONCE - a middle card, no copy in the right pane`,
      Boolean(opened.topic && r && r.is_parent === 1 && r.task_id !== opened.topic && r.middle === 1 && r.right === 0 && r.bornCards === 0),
      { opened, before, r })
  }
  ok(`1440px ${n} no page error`, errors.length === 0, errors)
  await p.close()
}

async function phoneCase(browser, width, height) {
  const tag = `${width}px`
  const { p, errors } = await open(browser, { width, height, isMobile: true, hasTouch: true })
  const card = await firstCard(p)
  await p.touchscreen.tap(card.x, card.y)
  await sleep(700)
  const opened = await state(p)
  const level = await p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'))
  const text = `spl996 phone ${width} ${Date.now()}`
  await send(p, text)
  const r = await sentRow(p, text)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `topic-send-target-${width}.png`) })
  ok(`${tag} a post from the docked composer on an open topic (level 3) goes into it, drawn there only`,
    Boolean(level === '3' && isReplyInto(r, opened.topic) && r.middle === 0 && r.right === 1 && r.bornCards === 0),
    { level, opened, r })
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

/* SPL-1637 poll-control (owner HUM-10, t1 aab3d88b): a ```poll form in a
   post. Radio: a click posts the answer at once, no Send (owner 87b56449);
   every question ends with "Chat about this" (6cd5873a), which opens the
   reply box with the marker. Checkbox: picks lock in 45 s per question after
   the first click, or on Send (8f0da7ca). The answer is a reply into the
   form's topic: `Poll: <msg_id>` + `Answer: ...`; the form shows who answered. */
const POLL_RADIO = 'Pick a deploy path\n\n```poll\nWhich deploy path?\n(A) Deploy now\n(B) Wait for CI\n```'
const POLL_CHECK = 'Pick the envs\n\n```poll\nWhich envs?\n[A] dev\n[B] prd\n[C] staging\n```'

function seedPoll(p, body) {
  return p.evaluate((body) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const id = crypto.randomUUID()
    const row = { v: 1, msg_id: id, task_id: crypto.randomUUID(), ts: new Date().toISOString(), from: 'CLE-07', to: '@channel', kind: 'note', body, files: [], channel: channel.active || 'alerts', parent_task_id: null, is_parent: 1 }
    /* the mock re-reads its feed: the row rides its test hook too, or it is gone a few seconds later */
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, row]
    return { msg_id: id, task_id: row.task_id }
  }, body)
}

/* the reply rows the page posted that answer form `id` */
function pollReplies(p, id) {
  return p.evaluate((id) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    return (pinia.state.value.channel.messages || []).filter((m) => String(m.body || '').includes(`Poll: ${id}`))
      .map((m) => ({ body: m.body, is_parent: m.is_parent, task_id: m.task_id, parent_task_id: m.parent_task_id || '' }))
  }, id)
}

/* open the seeded card's topic by its header, then the form in the right pane */
async function openPoll(p, seeded, touch) {
  const sel = `.spool-main article.msg[data-msg-id="${seeded.msg_id}"]`
  await p.waitForSelector(`${sel} [data-testid=poll-form]`, { timeout: 15000 })
  const spot = await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    el.scrollIntoView({ block: 'center' })
    const r = (el.querySelector('.msg-para') || el).getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(20, r.width / 2)), y: Math.round(r.top + r.height / 2) }
  }, sel)
  if (touch) await p.touchscreen.tap(spot.x, spot.y)
  else await p.mouse.click(spot.x, spot.y)
  const form = `aside.live-pane article.msg[data-msg-id="${seeded.msg_id}"] [data-testid=poll-form]`
  await p.waitForSelector(form, { timeout: 10000 })
  return form
}

async function clickIn(p, sel, touch) {
  const spot = await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return null
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(10, r.width / 2)), y: Math.round(r.top + r.height / 2), w: Math.round(r.width), h: Math.round(r.height) }
  }, sel)
  if (!spot) return null
  if (touch) await p.touchscreen.tap(spot.x, spot.y)
  else await p.mouse.click(spot.x, spot.y)
  await sleep(700)
  return spot
}

async function pollRadioCase(browser, vp, tag) {
  const touch = Boolean(vp.hasTouch)
  const { p, errors } = await open(browser, vp)
  const seeded = await seedPoll(p, POLL_RADIO)
  const form = await openPoll(p, seeded, touch)
  const shape = await p.evaluate((form) => {
    const f = document.querySelector(form)
    const input = f.querySelector('input')
    const r = input.getBoundingClientRect()
    return {
      kind: f.getAttribute('data-poll-kind'),
      radios: f.querySelectorAll('input[type=radio]').length,
      checks: f.querySelectorAll('input[type=checkbox]').length,
      send: f.querySelectorAll('[data-testid=poll-send]').length,
      last: [...f.querySelectorAll('label')].pop()?.textContent.trim(),
      input: { w: Math.round(r.width), h: Math.round(r.height) },
    }
  }, form)
  ok(`${tag} poll: a radio form, radios only, no Send, "Chat about this" last; inputs small (<= 20px)`,
    shape.kind === 'radio' && shape.radios === 3 && shape.checks === 0 && shape.send === 0 && shape.last === 'Chat about this' && shape.input.w <= 20 && shape.input.h <= 20, shape)
  await clickIn(p, `${form} [data-testid=poll-option][data-key=B]`, touch)
  const after = await pollReplies(p, seeded.msg_id)
  const shown = await p.evaluate((form) => ({
    checked: document.querySelector(`${form} input[value=B]`)?.checked,
    answers: [...document.querySelectorAll(`${form} [data-testid=poll-answer]`)].map((e) => e.textContent.trim()),
  }), form)
  ok(`${tag} poll: one click posts the answer at once, a reply into the form's topic with the marker; the form shows it`,
    after.length === 1 && /^Poll: [0-9a-f-]+\nAnswer: B — Wait for CI$/.test(after[0].body) && after[0].is_parent === 0
      && (after[0].parent_task_id === seeded.task_id || after[0].task_id === seeded.task_id)
      && shown.checked === true && shown.answers.length === 1 && /— B$/.test(shown.answers[0]), { after, shown })
  await clickIn(p, `${form} [data-testid=poll-option][data-key=A]`, touch)
  const again = await pollReplies(p, seeded.msg_id)
  const shownAgain = await p.evaluate((form) => [...document.querySelectorAll(`${form} [data-testid=poll-answer]`)].map((e) => e.textContent.trim()), form)
  ok(`${tag} poll: re-answer posts again and replaces the shown answer`,
    again.length === 2 && /Answer: A/.test(again[1].body) && shownAgain.length === 1 && /— A$/.test(shownAgain[0]), { again, shownAgain })
  await clickIn(p, `${form} [data-testid=poll-chat]`, touch)
  const chat = await p.evaluate((form) => ({
    box: document.querySelector('form.composer.omnibox--global textarea')?.value || '',
    focused: document.activeElement?.matches?.('form.composer.omnibox--global textarea') || false,
    checkedA: document.querySelector(`${form} input[value=A]`)?.checked,
    forms: document.querySelectorAll('[data-testid=poll-form]').length,
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'),
  }), form)
  const posted = await pollReplies(p, seeded.msg_id)
  ok(`${tag} poll: "Chat about this" posts no answer, opens the reply box focused with the marker and the question`,
    posted.length === 2 && chat.focused && chat.box.startsWith(`Chat: wants to discuss\nPoll: ${seeded.msg_id}\n> Which deploy path?`) && chat.checkedA === true, chat)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-radio-${tag}.png`) })
  ok(`${tag} poll radio: no page error`, errors.length === 0, errors)
  await p.close()
}

async function pollCheckCase(browser, vp, tag) {
  const touch = Boolean(vp.hasTouch)
  const { p, errors } = await open(browser, vp)
  const seeded = await seedPoll(p, POLL_CHECK)
  const form = await openPoll(p, seeded, touch)
  const kinds = await p.evaluate((form) => ({
    kind: document.querySelector(form).getAttribute('data-poll-kind'),
    radios: document.querySelectorAll(`${form} input[type=radio]`).length,
    checks: document.querySelectorAll(`${form} input[type=checkbox]`).length,
  }), form)
  await clickIn(p, `${form} [data-testid=poll-option][data-key=A]`, touch)
  await clickIn(p, `${form} [data-testid=poll-option][data-key=C]`, touch)
  const held = await pollReplies(p, seeded.msg_id)
  const lock = await p.evaluate((form) => document.querySelector(`${form} [data-testid=poll-lock]`)?.textContent.trim() || '', form)
  ok(`${tag} poll: a checkbox form, checkboxes only; two picks wait for the lock-in (45 s per question), nothing posted yet`,
    kinds.kind === 'checkbox' && kinds.radios === 0 && kinds.checks === 4 && held.length === 0 && /Locks in (4[0-5]) s/.test(lock), { kinds, held, lock })
  await clickIn(p, `${form} [data-testid=poll-send]`, touch)
  const sent = await pollReplies(p, seeded.msg_id)
  const shown = await p.evaluate((form) => [...document.querySelectorAll(`${form} [data-testid=poll-answer]`)].map((e) => e.textContent.trim()), form)
  ok(`${tag} poll: Send locks the multi-select in at once: one reply, Answer: A,C`,
    sent.length === 1 && /\nAnswer: A,C — dev; staging$/.test(sent[0].body) && shown.length === 1 && /— A,C$/.test(shown[0]), { sent, shown })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-check-${tag}.png`) })
  ok(`${tag} poll checkbox: no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 })).p.close()
  await desktopCase(browser, 1, 'topic open, send', async () => {}, true)
  await desktopCase(browser, 2, 'topic open, the app focuses a middle card (not the reader)', async (p, card) => {
    /* the opening click left that card focused: blur first, or focus() fires no focusin */
    await p.evaluate((id) => {
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur()
      document.querySelector(`.spool-main article.msg[data-msg-id="${CSS.escape(id)}"]`)?.focus({ preventScroll: true })
    }, card.id)
    await sleep(200)
  }, true)
  await desktopCase(browser, 3, 'topic open, the reader clicks the middle list, then posts', async (p) => {
    /* a real click in the middle that opens nothing: the feed's header row */
    const spot = await p.evaluate(() => {
      const h = document.querySelector('.spool-main .feed-header') || document.querySelector('.spool-main')
      const r = h.getBoundingClientRect()
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
    })
    await p.mouse.click(spot.x, spot.y)
    await sleep(300)
  }, true)
  await desktopCase(browser, 4, 'topic open, the line dispatches a task (@CLE-07 …) - a reply, the tag does not re-topic (dc6d5e3f)', async () => {}, true, '@CLE-07 ')
  /* e09a72f7 (owner): a leading @ that addresses no task (@test) is an ordinary
     message and replies into the open topic - it must NOT become its own topic.
     The owner typed @test in a thread and each one opened a new topic. */
  await desktopCase(browser, 5, 'topic open, a leading @ that addresses no task (@test) replies into it', async () => {}, true, '@test ')
  await phoneCase(browser, 360, 740)
  await phoneCase(browser, 820, 1180)
  await pollRadioCase(browser, { width: 1440, height: 900 }, '1440px')
  await pollRadioCase(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '390px')
  await pollCheckCase(browser, { width: 1440, height: 900 }, '1440px')
  await pollCheckCase(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '390px')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
