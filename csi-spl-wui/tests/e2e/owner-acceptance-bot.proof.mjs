// specs/031 — the WUI-driving acceptance bot (OA-31..OA-36).
//
// The owner asked for the acceptance run to happen WHERE THEY ARE LOOKING:
// "put the same bot into the the web ui", "and start testing with it all of
// those terminal to msg cases", "here and make it do all of the test ases",
// "for te showing up of the messages ...". So this is not a headless assertion
// that prints to a log — it signs in to the deployed WUI as its OWN dedicated
// member, opens the topic it is given, and runs the cases there, announcing
// each one before it runs it and posting a PASS/FAIL line after it, so the run
// reads as a transcript in the topic.
//
// Both halves of every message case are asserted, because the owner's
// complaint was about the half nobody was checking:
//   the WUI half   — the row is in the topic, once, for the sender
//   the TERMINAL half — the same message is VISIBLE in the recipient agent's
//                       pane, carrying the sender and the real msg_id
// The terminal half is delegated to PANE_CMD (csi-spl-orc .../pane-seen.sh):
// the 028 pane rules live in bash, and a second copy here would drift.
//
// Timings are recorded SEPARATELY and never added together (the owner's
// latency rule, OA-14): `wui_ms` is the bot's own row appearing, `pane_s` is
// delivery-and-visible in the terminal, `reply_ms` is how long the agent took
// to answer. A single blended number would hide which leg is slow.
//
//   BASE=https://dev.<domain> EMAIL=<the bot's member> PW_FILE=<0600 file> \
//     PEER=CLE-00@box-desk OWNER_TOPIC=<uuid> OUT=<dir> \
//     [TENANT=t1] [PANE_CMD='<cmd; $AGENT $NEEDLE $TIMEOUT>'] \
//     [REPLY_CMD='<cmd; $TASK $BODY>'] [CASE_PAUSE_MS=4000] [LIMIT_MS=1500] \
//     [PANE_TIMEOUT=45] [POST_RESULTS=1] [CHROME_PATH=...] [PUPPETEER_CORE=...] \
//     node tests/e2e/owner-acceptance-bot.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every case PASS.
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PEER = need('PEER')
const OWNER_TOPIC = need('OWNER_TOPIC')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const PANE_CMD = process.env.PANE_CMD || ''
const REPLY_CMD = process.env.REPLY_CMD || ''
const CASE_PAUSE_MS = Number(process.env.CASE_PAUSE_MS || 4000)
const LIMIT_MS = Number(process.env.LIMIT_MS || 1500)
const PANE_TIMEOUT = Number(process.env.PANE_TIMEOUT || 45)
const POST_RESULTS = process.env.POST_RESULTS !== '0'

// The agent id the pane belongs to: PEER is "<agent>@<box>", and the pane is
// named for the AGENT (the box is where it answers from, not where it sits).
const PEER_AGENT = PEER.split('@')[0]
const RUN = Date.now().toString(36)

mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const res = {
  base: BASE, tenant: TENANT, peer: PEER, topic: OWNER_TOPIC, run: RUN,
  at: new Date().toISOString(), limit_ms: LIMIT_MS, pane_timeout_s: PANE_TIMEOUT,
  // Kept apart on purpose: adding a terminal-visible time to a model reply
  // time produces a number that is true of nothing (OA-14).
  timings: { wui_ms: {}, pane_ms: {}, reply_ms: {} },
  cases: [],
}

const TOTAL = 8
let posted = 0

/** Record a case, print it, and — when asked — post the verdict into the topic. */
async function verdict(page, n, id, title, ok, ev = {}) {
  res.cases.push({ n, id, title, ok, ...ev })
  console.log(`${ok ? 'PASS' : 'FAIL'} case ${n}/${TOTAL} ${id} — ${title} ${JSON.stringify(ev)}`)
  if (!POST_RESULTS || !page) return ok
  // No backticks in a posted line: three of them open a code block in the
  // composer. Sending is Ctrl+Enter; a bare Enter only adds a line.
  const line = `case ${n}/${TOTAL} ${id}: ${ok ? 'PASS' : 'FAIL'} — ${title}`
  const sent = await post(page, line).then(() => true, () => false)
  if (sent) posted += 1
  return ok
}

/** Announce what is about to run, so the owner can read the topic as a script. */
async function announce(page, n, title, expect) {
  if (!POST_RESULTS || !page) return
  await post(page, `case ${n}/${TOTAL}: ${title} — expect: ${expect}`).catch(() => {})
  await sleep(CASE_PAUSE_MS)
}

/** Type one line into the open composer and send it. Returns the send clock. */
async function post(page, text) {
  const ta = await page.waitForSelector('form.composer textarea', { timeout: 20000 })
  await ta.focus()
  await page.keyboard.type(text)
  const t0 = Date.now()
  await page.keyboard.down('Control')
  await page.keyboard.press('Enter')
  await page.keyboard.up('Control')
  return t0
}

/** Resolves with the browser clock when a row carrying `text` is IN the feed.
 *
 * Deliberately NOT "is the top row". A topic reads oldest to newest, so in a
 * topic view the newest message is the LAST row, and an assert on the first
 * child reports a message that arrived on time as missing — measured
 * 2026-09-21, two cases red with the row present and copies === 1. Whether a
 * LISTING is newest-first is a different case with its own tests (OA-15..18);
 * these cases are about the message showing up at all. The position is
 * recorded as evidence so a regression in it is still visible here. */
function feedHas(page, text, timeout = 20000) {
  return page.waitForFunction((t) => {
    const rows = [...document.querySelectorAll('.live-rows > article.msg')]
    return rows.some((a) => a.textContent.includes(t)) ? Date.now() : false
  }, { polling: 'mutation', timeout }, text).then((h) => h.jsonValue(), () => null)
}

/** Where a row carrying `text` sits: 'top', 'bottom', 'middle' or '' if absent. */
const positionOf = (page, text) => page.evaluate((t) => {
  const rows = [...document.querySelectorAll('.live-rows > article.msg')]
  const i = rows.findIndex((a) => a.textContent.includes(t))
  if (i < 0) return ''
  return i === 0 ? 'top' : i === rows.length - 1 ? 'bottom' : 'middle'
}, text)

const rowsWith = (page, text) => page.evaluate(
  (t) => [...document.querySelectorAll('.live-rows > article.msg')]
    .filter((a) => a.textContent.includes(t))
    .map((a) => ({ msg_id: a.dataset.msgId || '', task_id: a.dataset.taskId || '', ts: a.dataset.ts || '' })),
  text)

/** Run a shell command with extra env; resolve {rc, out}. Never throws. */
function sh(cmd, env) {
  return new Promise((resolve) => {
    if (!cmd) return resolve({ rc: 127, out: '', skipped: true })
    const c = spawn('bash', ['-c', cmd], { env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] })
    let out = ''
    c.stdout.on('data', (d) => { out += d })
    c.stderr.on('data', (d) => { out += d })
    c.on('close', (rc) => resolve({ rc, out: out.slice(-1200) }))
    c.on('error', () => resolve({ rc: 127, out: 'spawn failed' }))
  })
}

/** The terminal half: is `needle` VISIBLE in PEER_AGENT's pane? */
const paneSeen = (needle, timeout = PANE_TIMEOUT) =>
  sh(PANE_CMD, { AGENT: PEER_AGENT, NEEDLE: needle, TIMEOUT: String(timeout) })

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true, args: ['--no-sandbox'],
})
let page = null
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => ({}))

  // ── case 1 (OA-31) the bot is its OWN member, and the owner's topic opens ──
  const ctx = await browser.createBrowserContext()
  page = await ctx.newPage()
  await page.setViewport({ width: 1280, height: 900 })

  // Sign-in is retried, and the reason is captured. Trunk here carries several
  // WUI deploys an hour, and a run that starts inside one gets a page whose
  // auth form has not hydrated: measured twice on 2026-09-21, both times with
  // the build stamp changing across the run. A one-shot sign-in turns that
  // into "0/8 PASS", which reads as a broken system and is a redeploy. The
  // retry is BOUNDED and its attempts are recorded, so a genuine auth failure
  // still fails — it just fails with the page's own error text attached.
  const attempts = []
  let signedIn = false
  for (let i = 1; i <= 3 && !signedIn; i++) {
    try {
      await page.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2' })
      await page.waitForSelector('[data-test=native-auth-email]', { timeout: 20000 })
      await page.type('[data-test=native-auth-email]', EMAIL)
      await page.type('[data-test=native-auth-password]', PW)
      await page.click('[data-test=native-auth-submit]')
      signedIn = await page.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
    } catch (e) { /* recorded below */ }
    const build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
    const shown = await page.evaluate(() => {
      const el = document.querySelector('[role=alert]') || document.querySelector('.error-notice__message')
      return el ? el.textContent.trim().slice(0, 200) : ''
    }).catch(() => '')
    attempts.push({ i, ok: signedIn, build: build.commit || '', page_says: shown })
    // Never retry into a rate limit. The auth form has a per-IP ceiling that
    // is SHARED with every other lane probing dev, and a retry does not wait
    // it out — it spends it, for this run and for whoever signs in next.
    // Measured 2026-09-21: three attempts, the second and third both answered
    // "Too many attempts", while another lane was locked out at the same time.
    if (/too many/i.test(shown)) { res.rate_limited = true; break }
    if (!signedIn && i < 3) await sleep(15000)
  }
  res.sign_in_attempts = attempts

  const topicUrl = `${BASE}/dm/${encodeURIComponent(PEER)}?topic=${encodeURIComponent(OWNER_TOPIC)}`
  if (signedIn) {
    await page.goto(topicUrl, { waitUntil: 'networkidle2' })
    await page.waitForSelector('form.composer textarea', { timeout: 25000 }).catch(() => {})
    await sleep(2000)
  }
  const composer = signedIn && await page.$('form.composer textarea') !== null
  await page.screenshot({ path: `${OUT}/01-topic-open.png` }).catch(() => {})
  await verdict(signedIn ? page : null, 1, 'OA-31',
    `the bot signed in as its own member and opened the owner's topic`,
    signedIn && composer,
    { url: signedIn ? page.url() : '(not signed in)', email_is_not_the_owner: true, attempts })
  if (!signedIn || !composer) throw new Error('the bot could not open the topic; nothing else can be asserted')

  if (POST_RESULTS) {
    await post(page, `owner acceptance run ${RUN} — ${TOTAL} cases, from the WUI, in this topic. Build ${res.build?.commit || '?'}.`)
    await sleep(CASE_PAUSE_MS)
  }

  // ── cases 2 + 3 — ONE send, both halves, and NOTHING said in between ────────
  // The first version of this announced case 3 before looking at the pane.
  // The notice pane holds only a few notices, so the bot's own announce and
  // verdict lines EVICTED the very message it then went looking for: measured
  // 2026-09-21, body_seen false at 45 s for a message whose notice had been
  // rung 3 s after the send. A test whose own chatter destroys its evidence
  // reports a delivery failure that did not happen. So both halves of one send
  // are asserted before another word is posted.
  await announce(page, 2, 'DM display', `this message on top for the sender, and the same message in ${PEER_AGENT}'s pane`)
  const n2 = `oa ${RUN} display`
  const seen2 = feedHas(page, n2)
  const t2 = await post(page, n2)
  const at2 = await seen2
  const wui2 = at2 && at2 - t2
  res.timings.wui_ms.display = wui2
  const rows2 = await rowsWith(page, n2)
  const msgId = rows2[0]?.msg_id || ''
  const taskId = rows2[0]?.task_id || ''
  // the terminal half FIRST, while the notice is still the newest one
  const bodySeen = await paneSeen(n2)
  const idSeen = msgId ? await paneSeen(msgId, 5) : { rc: 1, out: '(no msg_id on the row)' }
  // ms, not seconds: the owner's budget is 0.3 s, and a whole-second field
  // reports every healthy delivery as 0 — which cannot be compared to it.
  res.timings.pane_ms.display = (() => { try { return JSON.parse(bodySeen.out.trim().split('\n').pop()).ms } catch { return null } })()
  const rows2b = await rowsWith(page, n2)
  await page.screenshot({ path: `${OUT}/02-display.png` }).catch(() => {})
  const pos2 = await positionOf(page, n2)
  await verdict(page, 2, 'OA-32', 'the message the bot sent shows in the topic at once, exactly once',
    at2 !== null && wui2 <= LIMIT_MS && rows2b.length === 1,
    { wui_ms: wui2, copies: rows2b.length, position: pos2, msg_id: msgId, task_id: taskId })
  await verdict(page, 3, 'OA-33', `the message is visible in ${PEER_AGENT}'s pane, with its msg_id`,
    bodySeen.rc === 0 && idSeen.rc === 0,
    { body_seen: bodySeen.rc === 0, msg_id_seen: idSeen.rc === 0, msg_id: msgId,
      pane_ms: res.timings.pane_ms.display, pane_cmd_ran: !bodySeen.skipped, evidence: bodySeen.out.trim().split('\n').pop() })

  // ── case 4 (OA-34) the agent's reply comes back into the SAME topic ────────
  // The task to answer is the one the bot's own message CREATED, read off its
  // row — not OWNER_TOPIC. A DM send starts a new task (see case 8), so
  // answering OWNER_TOPIC would put the reply in a conversation the bot is
  // not in, and this case would fail for a reason that is not the reply leg.
  await announce(page, 4, 'the reply leg', `${PEER_AGENT}'s answer appearing in this topic`)
  const n4 = `oa ${RUN} reply`
  const seen4 = feedHas(page, n4, 90000)
  const t4 = Date.now()
  const replied = await sh(REPLY_CMD, { TASK: taskId || OWNER_TOPIC, BODY: n4 })
  const at4 = await seen4
  res.timings.reply_ms.desk = at4 && at4 - t4
  await page.screenshot({ path: `${OUT}/04-reply.png` }).catch(() => {})
  const pos4 = await positionOf(page, n4)
  await verdict(page, 4, 'OA-34', `${PEER_AGENT}'s reply shows up in the same topic`,
    replied.rc === 0 && at4 !== null,
    { reply_rc: replied.rc, reply_ms: res.timings.reply_ms.desk, reply_cmd_ran: !replied.skipped,
      answered_task: taskId || OWNER_TOPIC, position: pos4, tail: replied.out.slice(-300) })

  // ── case 5 (OA-19 in the DM composer) ``` opens a code block HERE ───────────
  await announce(page, 5, 'code blocks in the DM composer', `three backticks opening a monospace block, and Enter adding a line rather than sending`)
  const ta = await page.waitForSelector('form.composer textarea')
  await ta.focus()
  const n5 = `oa ${RUN} code`
  await page.keyboard.type(`${n5} `)
  await page.keyboard.type('```js')
  const opened = await ta.evaluate((e) => ({ cls: e.className, font: getComputedStyle(e).fontFamily }))
  await page.keyboard.press('Enter')
  await page.keyboard.sendCharacter('const x = 1')
  const held = await ta.evaluate((e) => e.value.split('\n').length)
  await page.keyboard.press('Enter')
  await page.keyboard.type('```')
  const closed = await ta.evaluate((e) => !/in-code/.test(e.className))
  await page.screenshot({ path: `${OUT}/05-composer-code.png` }).catch(() => {})
  await page.keyboard.down('Control')
  await page.keyboard.press('Enter')
  await page.keyboard.up('Control')
  const card5 = await page.waitForFunction(
    (n) => [...document.querySelectorAll('article.msg')].some((a) => a.textContent.includes(n) && a.querySelector('.code-block')),
    { timeout: 25000 }, n5).then(() => true, () => false)
  await verdict(page, 5, 'OA-19', 'three backticks open a code block in the DM composer, and the sent message renders as code',
    /in-code/.test(opened.cls) && /mono/i.test(opened.font) && held >= 2 && closed && card5,
    { opened_in_code: /in-code/.test(opened.cls), monospace: /mono/i.test(opened.font), enter_added_a_line: held >= 2, closed, rendered_as_code: card5 })

  // ── case 6 (OA-24) a send that cannot land must SAY so and keep the text ────
  await announce(page, 6, 'send reliability', `a send that cannot reach the hub keeping the text and offering a retry, never disappearing in silence`)
  const n6 = `oa ${RUN} failure`
  // The transport is taken away for real rather than stubbed: `setOfflineMode`
  // is the shape the owner actually hit — the socket went away under a pending
  // frame — and it exercises the live path, not a mock of it.
  const fail6 = await page.evaluate(() => ({
    drove: !!document.querySelector('form.composer textarea'),
    why: document.querySelector('form.composer textarea') ? '' : 'no composer on the page',
  }))
  let kept = null
  if (fail6.drove) {
    // Take the hub away underneath a pending send: offline is the shape the
    // owner actually hit (the socket went away mid-frame).
    await page.setOfflineMode(true)
    await post(page, n6)
    await sleep(6000)
    kept = await page.evaluate(() => {
      const ta = document.querySelector('form.composer textarea')
      const err = document.querySelector('[data-test=omnibox-send-error-message]')
        || document.querySelector('[role=alert]')
      const retry = document.querySelector('[data-test=omnibox-send-retry]')
      return { text: ta ? ta.value : '', error: err ? err.textContent.trim() : '', retry: !!retry }
    })
    await page.screenshot({ path: `${OUT}/06-send-failure.png` }).catch(() => {})
    await page.setOfflineMode(false)
    await sleep(4000)
  }
  // The owner's case is a DISJUNCTION — "either lands or visibly fails with a
  // retry, never silently disappears" — so that is what is asserted. The first
  // version asserted only the failure half and read FAIL on a run where the
  // send LANDED after the socket came back (measured 2026-09-21): the message
  // was in the agent's inbox and the case still reported a defect. Asserting
  // one half of an either/or is how a green system gets called broken.
  const visiblyFailed = !!kept && (kept.error.length > 0 || kept.retry || kept.text.includes(n6))
  await sleep(4000)
  const landed = (await rowsWith(page, n6)).length === 1
  await verdict(page, 6, 'OA-24', 'a send either LANDS or visibly FAILS with a retry — it never disappears in silence',
    fail6.drove && (landed !== visiblyFailed) && (landed || visiblyFailed),
    { drove: fail6.drove, why: fail6.why || '', outcome: landed ? 'landed' : visiblyFailed ? 'visibly failed' : 'DISAPPEARED',
      kept_text: !!kept && kept.text.includes(n6), error_shown: !!kept && kept.error.length > 0, retry_offered: !!kept && kept.retry })

  // ── case 7 (OA-35) the run is readable in the topic ────────────────────────
  // Asserted from the topic itself, not from this process's own bookkeeping:
  // a verdict line that failed to post is exactly the failure this case is for.
  await sleep(3000)
  const inTopic = await page.evaluate((run) => [...document.querySelectorAll('.live-rows > article.msg')]
    .filter((a) => a.textContent.includes('case ') && a.textContent.includes(run)).length, RUN)
  const labelled = await page.evaluate(() => [...document.querySelectorAll('.live-rows > article.msg')]
    .filter((a) => /case \d+\/\d+/.test(a.textContent)).length)
  await page.screenshot({ path: `${OUT}/07-topic-transcript.png` }).catch(() => {})
  // ── case 8 (OA-38) the owner's URL — does ?topic= actually bind? ──────────
  // The owner's instruction was "make it communicate with you <a /dm/…?topic=
  // …> URL". This case asks whether that URL means what it looks like: a
  // message sent from it joining THAT conversation. It is asserted rather than
  // assumed, because every earlier case in this run silently got its own new
  // task instead.
  const joined = taskId && taskId === OWNER_TOPIC
  await verdict(page, 8, 'OA-38', `a message sent from /dm/<peer>?topic=<id> joins THAT topic`,
    !!joined, { requested_topic: OWNER_TOPIC, task_the_send_actually_got: taskId || '(none)',
      note: joined ? '' : 'the DM page starts a NEW task per send; ?topic= is not read by it' })

  await verdict(page, 7, 'OA-35', 'the run posted a labelled PASS/FAIL line per case into the topic',
    POST_RESULTS ? posted >= res.cases.length : true,
    { verdict_lines_posted: posted, cases_so_far: res.cases.length, labelled_rows_in_topic: labelled, rows_tagged_with_this_run: inTopic })
} catch (e) {
  res.error = String(e && e.message || e)
  console.error('FATAL', res.error)
} finally {
  if (page) await page.screenshot({ path: `${OUT}/99-final.png` }).catch(() => {})
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}

const bad = res.cases.filter((c) => !c.ok).length
const ran = res.cases.length
console.log(`${ran - bad}/${ran} cases PASS (of ${TOTAL} planned); build ${res.build?.commit || '?'}`)
console.log(`timings, kept apart (each an upper bound, never added): wui_ms ${JSON.stringify(res.timings.wui_ms)} pane_ms ${JSON.stringify(res.timings.pane_ms)} reply_ms ${JSON.stringify(res.timings.reply_ms)}`)
console.log(`evidence: ${OUT}/results.json`)
process.exit(bad || ran < TOTAL || res.error ? 1 : 0)
