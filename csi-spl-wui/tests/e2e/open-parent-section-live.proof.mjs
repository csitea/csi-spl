// Open parent section (SPL-15) - live proof, signed in, against a deployed WUI.
//
// Owner, 2026-09-26: from a search result, a thread message's menu opens the
// parent: the parent message selected in the middle, the channel (or DM)
// tab selected on the left, and the thread still open on the right.
//
// Steps (n = 1 per run):
//   1. post a level-1 card in CHANNEL, open it, reply in its thread
//   2. /search for the reply's token -> open the hit -> the thread is on the right
//   3. the reply's menu (keyboard: its menu button, Enter, ArrowDown, Enter)
//      -> Open parent section
//   4. the address is /channel/<CHANNEL>?topic=<task>#<reply>; the Channels
//      rail tab is selected; the parent card is selected and in view in the
//      middle; the thread is open on the right with the reply in it
//   5. (ISSUE=1, default) an issue's comment: search it, open the hit, Open
//      parent section -> /issues?issue=<key> with that issue selected and its
//      detail on the right. The probe issue is then set to canceled.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [ISSUE=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/open-parent-section-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const ISSUE = process.env.ISSUE !== '0'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const run = Date.now().toString(36)
/* the desk never types a probe-marked line into a prompt (specs/017 FR-SEC-030) */
const PROBE_MARK = '[spool-probe]'

/** goto / reload that retries a navigation the box's network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 20000, every = 300) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(every)
  }
  return v
}

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

async function closePane(p) {
  for (let i = 0; i < 3; i++) {
    const btn = await p.$('aside.live-pane [data-test=topic-pane-close], aside.live-pane [data-test=live-topic-close]')
    if (!btn) return
    await btn.click().catch(() => {})
    await sleep(600)
  }
}

async function send(p, text) {
  const ta = await p.waitForSelector('[data-test=top-bar] textarea')
  await ta.click({ count: 3 })
  await p.keyboard.press('Backspace')
  await p.keyboard.type(text)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

/** A row's ids, found by its text, in the middle ('mid') or the right pane ('pane'). */
const ROW = (needle, where) => {
  const pane = document.querySelector('aside.live-pane')
  const rows = where === 'pane'
    ? (pane ? [...pane.querySelectorAll('article.msg')] : [])
    : [...document.querySelectorAll('.spool-main article.msg')]
  const el = rows.find((r) => (r.innerText || '').includes(needle) && r.getAttribute('data-msg-id') && r.getAttribute('data-pending') !== 'true')
  return el ? { msg: el.getAttribute('data-msg-id'), task: el.getAttribute('data-task-id') || '' } : null
}

/** /search for `token` until a messages hit shows (the index may lag the send); open it. */
async function openSearchHit(p, token) {
  let hit = null
  for (let i = 0; i < 6 && !hit; i++) {
    await nav(p, BASE + '/search?q=' + encodeURIComponent(token))
    hit = await p.waitForSelector('[data-test=search-results] .search-row[data-type=messages]', { visible: true, timeout: 15000 }).catch(() => null)
    if (!hit) await sleep(5000)
  }
  step(`search finds ${token}`, !!hit, {})
  if (!hit) throw new Error('no search hit')
  await hit.click()
}

/** The thread line's menu from the keyboard: its menu button, Enter, ArrowDown, Enter. */
async function openParentByKeyboard(p, msgId) {
  const line = `aside.live-pane article.msg[data-msg-id="${msgId}"]`
  const shown = await p.waitForSelector(line, { visible: true, timeout: 20000 }).then(() => true, () => false)
  step('the hit opens its thread on the right', shown, { msgId })
  await p.$eval(`${line} [data-testid=msg-menu-btn]`, (el) => el.focus())
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
  const ids = await p.$$eval('[data-testid=msg-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid')))
  await p.keyboard.press('ArrowDown')
  const focused = await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-testid'))
  step('the menu offers Open parent section after Open, reachable by keyboard', ids[0] === 'msg-menu-open' && ids[1] === 'msg-menu-parent' && focused === 'msg-menu-parent', { ids, focused })
  await p.keyboard.press('Enter')
}

async function channelProof(p) {
  await nav(p, BASE + '/channel/' + encodeURIComponent(CHANNEL))
  await p.waitForSelector('[data-testid=card-clip-control]', { timeout: 30000 }).catch(() => {})
  await sleep(1500)
  await closePane(p)

  /* 1. a card and a reply in its thread */
  const ROOT = `${PROBE_MARK} parent root ${run}`
  const TOKEN = `ppsreply${run}`
  await send(p, ROOT)
  const root = await until(() => p.evaluate(ROW, ROOT, 'mid'))
  step('1 the level-1 card is posted', !!root, root || {})
  if (!root) throw new Error('no root card')
  await p.click(`.spool-main article.msg[data-msg-id="${root.msg}"]`)
  await p.waitForSelector('aside.live-pane', { visible: true, timeout: 15000 })
  await sleep(800)
  await send(p, `${PROBE_MARK} ${TOKEN} a reply in the thread`)
  const reply = await until(() => p.evaluate(ROW, TOKEN, 'pane'))
  step('1 the reply is in the thread', !!reply, reply || {})
  if (!reply) throw new Error('no reply')
  await closePane(p)

  /* 2-3. search -> hit -> Open parent section */
  await openSearchHit(p, TOKEN)
  await openParentByKeyboard(p, reply.msg)

  /* 4. where it lands */
  await until(() => p.evaluate((ch) => location.pathname.endsWith('/channel/' + ch), CHANNEL), 15000)
  const url = new URL(p.url())
  step('4 the address is the channel, the topic and the reply',
    url.pathname.endsWith('/channel/' + CHANNEL) && url.searchParams.get('topic') === root.task && url.hash === '#' + reply.msg,
    { url: p.url(), task: root.task })
  const tab = await p.waitForSelector('[data-testid=sidebar-tab-channels][aria-selected="true"]', { timeout: 10000 }).then(() => true, () => false)
  step('4 the Channels rail tab is selected', tab)
  const card = `.spool-main article.msg[data-msg-id="${root.msg}"][data-selected="true"]`
  const sel = await p.waitForSelector(card, { visible: true, timeout: 20000 }).then(() => true, () => false)
  const inView = sel && await p.$eval(card, (el) => {
    const r = el.getBoundingClientRect()
    const s = el.closest('.feed-body').getBoundingClientRect()
    return r.top >= s.top - 1 && r.top < s.bottom
  })
  step('4 the parent card is selected and in view in the middle', Boolean(sel && inView), { sel, inView })
  const thread = `aside.live-pane[data-section="channel"] article.msg[data-msg-id="${reply.msg}"]`
  const open = await p.waitForSelector(thread, { visible: true, timeout: 20000 }).then(() => true, () => false)
  step('4 the thread is open on the right with the reply in it', open, {})
  await sleep(800)
  await p.screenshot({ path: `${OUT}/1-channel-parent.png` })
}

async function issueProof(p) {
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-new]', { visible: true, timeout: 30000 })
  const TITLE = `${PROBE_MARK} parent issue ${run}`
  const TOKEN = `ppsissue${run}`
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail-title]', { clickCount: 3 })
  await p.type('[data-test=issues-detail-title]', TITLE)
  /* SPL-18: an issue needs an epic - take the first one the tenant has */
  if (await p.$eval('[data-test=issues-create]', (el) => el.disabled)) {
    await p.click('[data-test=issues-epic]')
    const first = await p.waitForSelector('[data-test=issues-menu-option]', { visible: true, timeout: 5000 }).catch(() => null)
    if (first) await first.click()
    await sleep(400)
  }
  await p.click('[data-test=issues-create]')
  const key = await until(() => p.evaluate((t) => {
    const el = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    return el && el.value === t && k && /^[A-Z]+-\d+$/.test(k.textContent.trim()) ? k.textContent.trim() : ''
  }, TITLE), 15000)
  step('5 the probe issue is created', !!key, { key })
  if (!key) throw new Error('no issue')
  await p.waitForSelector('[data-test=issues-comment-input]', { visible: true, timeout: 10000 })
  await p.type('[data-test=issues-comment-input]', `${PROBE_MARK} ${TOKEN} a comment on the issue`)
  await p.keyboard.press('Enter') /* SPL-973: Enter sends, there is no Comment button */
  const commented = await until(() => p.evaluate((t) => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => c.innerText.includes(t)), TOKEN), 15000)
  step('5 the comment is posted', !!commented)

  await openSearchHit(p, TOKEN)
  const msgId = await until(() => p.evaluate(ROW, TOKEN, 'pane'))
  step('5 the comment opens on the right', !!msgId, msgId || {})
  if (!msgId) throw new Error('no comment in the pane')
  await openParentByKeyboard(p, msgId.msg)
  await until(() => p.evaluate(() => location.pathname.endsWith('/issues')), 15000)
  const url = new URL(p.url())
  step('5 the address is the Issues tab with that issue', url.pathname.endsWith('/issues') && url.searchParams.get('issue') === key, { url: p.url() })
  const tab = await p.waitForSelector('[data-testid=sidebar-tab-issues][aria-selected="true"]', { timeout: 10000 }).then(() => true, () => false)
  step('5 the Issues rail tab is selected', tab)
  const rowSel = await p.waitForSelector(`[data-test=issues-row][data-key="${key}"][data-selected="true"]`, { timeout: 15000 }).then(() => true, () => false)
  const detail = await until(() => p.evaluate((k) => {
    const d = document.querySelector('[data-test=issues-detail-key]')
    return Boolean(d && d.textContent.trim() === k)
  }, key), 15000)
  step('5 the issue is selected and its detail is on the right', rowSel && !!detail, { rowSel, detail: !!detail })
  await sleep(800)
  await p.screenshot({ path: `${OUT}/2-issue-parent.png` })

  /* tidy: the probe issue goes to canceled */
  await p.click('[data-test=issues-status]').catch(() => {})
  const opt = await p.waitForSelector('[data-test=issues-menu-option][data-value="canceled"]', { visible: true, timeout: 5000 }).catch(() => null)
  if (opt) await opt.click()
  res.issue = key
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await signIn(ctx)
  try {
    await channelProof(p)
  } catch (e) {
    step('channel proof ran to the end', false, { error: String(e).slice(0, 300) })
    await p.screenshot({ path: `${OUT}/error-channel.png` }).catch(() => {})
  }
  if (ISSUE) {
    try {
      await issueProof(p)
    } catch (e) {
      step('issue proof ran to the end', false, { error: String(e).slice(0, 300) })
      await p.screenshot({ path: `${OUT}/error-issue.png` }).catch(() => {})
    }
  }
} catch (e) {
  step('proof ran', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps', '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
