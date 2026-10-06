// t1 b6c742f0 (HUM-10; csitea 41261a3f HUM-24): a person's message has an
// "AI actions" group in its right-click menu - Debate, Spec, Implement,
// Analyse, Turn into an issue, Find risks, Add to calendar. An agent's
// message has none. Analyse posts the instruction, quoting the message, as
// the member's reply in the same topic; Add to calendar creates a calendar
// event from it and opens its week on /calendar.
//
// Against the lde mock (no hub), a 1280x800 desktop:
//   - a right-click on a person's reply lists the group and its 7 items
//   - a right-click on an agent's reply lists none of them
//   - Analyse adds a post "AI action: Analyse" quoting the reply
//   - Add to calendar lands on /calendar with an item titled from the reply
//   - a 390 px phone sheet has one AI actions entry (Delete stays last);
//     picking it turns the sheet into the seven actions
//
// Control: before this change there is no msg-menu-ai-analyse, so every
// check after the first menu FAILS.
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/msg-ai-actions.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'b6c742f0-e1cc-4080-89ed-8eb30d76a300'
const HUMAN = 'b6c742f0-e1cc-4080-89ed-8eb30d76a301'
const AGENT = 'b6c742f0-e1cc-4080-89ed-8eb30d76a302'
const row = (msg_id, min, body, is_parent, from, from_box) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-06T10:0${min}:00Z`, from, from_box,
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'ai-actions topic starter', 1, 'HUM-1', 'box-wui'),
  row(HUMAN, 1, 'Export the weekly report as PDF', 0, 'HUM-2', 'box-wui'),
  row(AGENT, 2, 'ai-actions agent reply', 0, 'c-007', 'box-a'),
]
const AI_IDS = ['ai-debate', 'ai-spec', 'ai-implement', 'ai-analyse', 'ai-issue', 'ai-risks', 'ai-calendar']

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.topic article.msg[data-msg-id="${id}"]`
const menu = '[data-testid=msg-menu]'

async function rightClick(p, sel) {
  return p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true, cancelable: true, view: window,
      clientX: Math.round(r.left + r.width / 2),
      clientY: Math.round(r.top + Math.min(20, r.height / 2)),
      button: 2, buttons: 2,
    }))
    return true
  }, sel)
}

async function menuItems(p, sel) {
  if (!(await rightClick(p, sel))) return null
  if (!(await p.waitForSelector(menu, { visible: true, timeout: 5000 }).then(() => true, () => false))) return null
  await sleep(300)
  return p.$$eval(`${menu} [role=menuitem]`, (els) => els.map((e) => String(e.getAttribute('data-testid') || '').replace(/^msg-menu-/, '')))
}

async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await p.waitForSelector(menu, { hidden: true, timeout: 5000 }).catch(() => {})
}

async function openTopic(p) {
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return p.waitForSelector(card(HUMAN), { visible: true, timeout: 15000 }).then(() => true, () => false)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { try { localStorage.removeItem('spool.mock.calendar-added') } catch { /* */ } })

  ok('the topic view opens with a person\'s and an agent\'s reply', (await openTopic(p)) && (await until(p, (s) => Boolean(document.querySelector(s)), card(AGENT), 8000)))
  await sleep(400)

  const human = await menuItems(p, `${card(HUMAN)} .msg-body`)
  ok('a person\'s message lists the 7 AI actions, in order, last in the menu', Array.isArray(human) && JSON.stringify(human.slice(-7)) === JSON.stringify(AI_IDS), human)
  const group = await p.$eval('[data-testid=msg-menu-group-ai-debate]', (el) => el.textContent.trim()).catch(() => '')
  ok('the group is headed AI actions', group === 'AI actions', group)
  const label = await p.$eval('[data-testid=msg-menu-ai-issue]', (el) => el.textContent.trim()).catch(() => '')
  ok('the issue action reads Turn into an issue', label === 'Turn into an issue', label)
  await closeMenu(p)

  const agent = await menuItems(p, `${card(AGENT)} .msg-body`)
  ok('an agent\'s message has no AI action', Array.isArray(agent) && agent.length > 0 && !agent.some((id) => id.startsWith('ai-')), agent)
  ok('and no AI actions heading', !(await p.$('[data-testid^=msg-menu-group-]')))
  await closeMenu(p)

  await menuItems(p, `${card(HUMAN)} .msg-body`)
  await p.click('[data-testid=msg-menu-ai-analyse]')
  const posted = await until(p, () => [...document.querySelectorAll('article.msg')].some((e) => e.getClientRects().length
    && /AI action: Analyse/.test(e.textContent) && /Export the weekly report as PDF/.test(e.textContent)), null, 8000)
  ok('Analyse adds a post that carries the instruction and quotes the message', posted)
  const post = await p.evaluate(() => {
    const el = [...document.querySelectorAll('article.msg')].find((e) => /AI action: Analyse/.test(e.textContent))
    return el ? { task: el.closest('[data-task-id]')?.getAttribute('data-task-id') || '', text: el.textContent.replace(/\s+/g, ' ').slice(0, 400) } : null
  })
  ok('the post names its source message', Boolean(post && post.text.includes('reply with an analysis of this message') && post.text.includes(HUMAN)), post)
  ok('no AI action error shows', !(await p.$('[data-testid=msg-ai-error]')))

  await menuItems(p, `${card(HUMAN)} .msg-body`)
  await p.click('[data-testid=msg-menu-ai-calendar]')
  const onCal = await until(p, () => /\/calendar/.test(location.pathname), null, 8000)
  ok('Add to calendar opens /calendar', onCal)
  const item = await p.waitForFunction(() => [...document.querySelectorAll('[data-test=calendar-item]')].find((e) => /Export the weekly report as PDF/.test(e.textContent)), { timeout: 10000 }).then(() => true, () => false)
  ok('the calendar shows the new event, titled from the message', item)

  /* the phone sheet opens WHOLE, Delete last (t1 7a6be5a3): one "AI actions"
     entry before Delete turns the same sheet into the seven actions */
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
  ok('phone: the topic view opens', await openTopic(p))
  await sleep(400)
  const sheet = await menuItems(p, `${card(HUMAN)} .msg-body`)
  ok('phone: the sheet has one AI actions entry, not the seven', Array.isArray(sheet) && sheet.includes('ai-more') && !sheet.includes('ai-analyse'), sheet)
  const del = Array.isArray(sheet) ? sheet.findIndex((id) => id === 'delete' || id === 'delete-topic') : -1
  ok('phone: Delete, when offered, stays last', del < 0 || del === sheet.length - 1, sheet)
  await p.click('[data-testid=msg-menu-ai-more]').catch(() => {})
  const swapped = await until(p, () => Boolean(document.querySelector('[data-testid=msg-menu-ai-analyse]')), null, 4000)
  const now = swapped ? await p.$$eval(`${menu} [role=menuitem]`, (els) => els.map((e) => String(e.getAttribute('data-testid') || '').replace(/^msg-menu-/, ''))) : []
  ok('phone: picking it shows the seven actions in the same sheet', JSON.stringify(now) === JSON.stringify(AI_IDS), now)
  await closeMenu(p)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmsg-ai-actions: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
