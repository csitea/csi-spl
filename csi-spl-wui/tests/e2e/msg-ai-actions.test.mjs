// t1 b6c742f0 (HUM-10; csitea 41261a3f HUM-24): a message has an "AI
// actions" group in its right-click menu - Debate, Spec, Implement, Analyse,
// Turn into an issue, Find risks, Add to calendar. HUM-10 643c30a8: an
// agent's message too, and every card with a right-click menu. Analyse posts
// the instruction, quoting the message, as the member's reply in the same
// topic; Add to calendar creates a calendar event from it and opens its week
// on /calendar.
//
// Against the lde mock (no hub), a 1280x800 desktop:
//   - a right-click on a person's reply lists the group and its 7 items
//   - a right-click on an agent's reply lists them too (643c30a8)
//   - control: a still-pending (unsent) row lists none of them
//   - Analyse adds a post "AI action: Analyse" quoting the reply
//   - Add to calendar lands on /calendar with an item titled from the reply
//   - a 390 px phone sheet has one AI actions entry (Delete stays last);
//     picking it turns the sheet into the seven actions
//
// HUM-10 14dc0232 ("good add those same actions to every msg card in every
// view"), the same group in every other view, an agent's message too:
//   - views/dm: the DM card (HUM-1's) has it; views/thread: its thread reply
//     in the right pane (GRK-03's) has it
//   - views/issue: an issue discussion comment has it
//   - views/flow: a Flow entry's menu has it, a person's and an agent's;
//     Analyse opens the DM and posts there
//   - views/search: a person's hit has it, an agent's too
//
// HUM-10 643c30a8 ("actually add them to every card which has right click
// menu"), one check per newly covered card kind:
//   - cards/home-topic: a topic row of the home list (/) ends with the group;
//     Analyse opens the topic and posts on its opening message
//   - cards/sidebar-topic: a row of the sidebar Topics tab ends with it
//   - cards/issue: an issue row's menu ends with six (no "Turn into an
//     issue"); Analyse posts in the issue's discussion
//   - cards/epic: an epic in the sidebar ends with the six
//   - views/phone: the Flow sheet has one AI actions entry that turns into
//     the seven
//
// Control: before this change there is no msg-menu-ai-analyse, so every
// check after the first menu FAILS; before 14dc0232 the Flow entry had no
// menu and the search row menu no AI entries, so every views/flow and
// views/search check FAILS; before 643c30a8 every agent check and every
// cards/* check FAILS.
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
const PENDING = 'b6c742f0-e1cc-4080-89ed-8eb30d76a303'
const row = (msg_id, min, body, is_parent, from, from_box) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-06T10:0${min}:00Z`, from, from_box,
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'ai-actions topic starter', 1, 'HUM-1', 'box-wui'),
  row(HUMAN, 1, 'Export the weekly report as PDF', 0, 'HUM-2', 'box-wui'),
  row(AGENT, 2, 'ai-actions agent reply', 0, 'c-007', 'box-a'),
  { ...row(PENDING, 3, 'ai-actions still sending', 0, 'HUM-1', 'box-wui'), pending: true, waiting: true },
]
const AI_IDS = ['ai-debate', 'ai-spec', 'ai-implement', 'ai-analyse', 'ai-issue', 'ai-risks', 'ai-calendar']
/* an issue / epic is not turned into an issue (643c30a8) */
const AI_ISSUE_IDS = AI_IDS.filter((id) => id !== 'ai-issue')
/* the mock tenant (src/utils/mock-data.mjs) */
const DM_TOPIC = '99999999-9999-4999-8999-999999999999'
const DM_CARD = '77777777-7777-4777-8777-777777777777'
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const ALERT = '66666666-6666-4666-8666-666666666666'
const DM_PATH = '/dm/' + encodeURIComponent('GRK-03@box-a')
const FLOW = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const flowEntry = (id) => `${FLOW} [data-testid=left-entry][data-msg-id="${id}"]`
const HIT = '[data-test=search-results] [data-test=search-row][data-type=messages]'


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
    /* the first one on screen (a card can sit in the middle list and a pane) */
    const all = [...document.querySelectorAll(sel)]
    const el = all.find((e) => e.getClientRects().length) || all[0]
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

/** right-click `sel`; the ids of the menu `testid` opened, null when none opened */
async function menuOf(p, sel, testid) {
  if (!(await rightClick(p, sel))) return null
  const menu = `[data-testid=${testid}]`
  if (!(await p.waitForSelector(menu, { visible: true, timeout: 5000 }).then(() => true, () => false))) return null
  await sleep(300)
  const ids = await p.$$eval(`${menu} [role=menuitem]`, (els) => els.map((e) => String(e.getAttribute('data-testid') || '')))
  return ids.map((id) => (id.startsWith(`${testid}-`) ? id.slice(testid.length + 1) : id))
}

async function closeMenuOf(p, testid) {
  await p.keyboard.press('Escape')
  await p.waitForSelector(`[data-testid=${testid}]`, { hidden: true, timeout: 5000 }).catch(() => {})
}

/** right-click `sel`; the ids of the left-pane row menu it opened, once its
    lazy AI entries had time to arrive; null when none opened */
async function rowMenuOf(p, sel) {
  if (!(await rightClick(p, sel))) return null
  const panel = '[data-testid=sidebar-row-menu-panel]'
  if (!(await p.waitForSelector(panel, { visible: true, timeout: 5000 }).then(() => true, () => false))) return null
  await p.waitForSelector(`${panel} [data-testid=sidebar-row-menu-ai-debate]`, { timeout: 4000 }).catch(() => {})
  await sleep(200)
  return p.$$eval(`${panel} [role=menuitem]`, (els) => els.map((e) => String(e.getAttribute('data-testid') || '').replace(/^sidebar-row-menu-/, '')))
}

const hasIssueGroup = (ids) => Array.isArray(ids) && JSON.stringify(ids.slice(-6)) === JSON.stringify(AI_ISSUE_IDS)
const hasGroup = (ids) => Array.isArray(ids) && JSON.stringify(ids.slice(-7)) === JSON.stringify(AI_IDS)
const noAi = (ids) => Array.isArray(ids) && ids.length > 0 && !ids.some((id) => id.startsWith('ai-'))

async function go(p, path, sel) {
  await p.goto(srv.base + path, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return sel ? p.waitForSelector(sel, { visible: true, timeout: 15000 }).then(() => true, () => false) : true
}

/* `/` (a phone opens it at level 1, the section chooser + its list), then
   the Flow tab; a second try when the first load lost a lazy chunk */
async function openFlow(p) {
  for (let i = 0; i < 2; i++) {
    await go(p, '/')
    const tab = await p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: 20000 }).then(() => true, () => false)
    if (!tab) continue
    await p.click('[data-testid=sidebar-tab-flow]')
    if (await p.waitForSelector(flowEntry(DM_CARD), { visible: true, timeout: 15000 }).then(() => true, () => false)) return true
  }
  return false
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
  ok('an agent\'s message lists the 7 AI actions too, last in the menu', Array.isArray(agent) && JSON.stringify(agent.slice(-7)) === JSON.stringify(AI_IDS), agent)
  const agentGroup = await p.$eval('[data-testid=msg-menu-group-ai-debate]', (el) => el.textContent.trim()).catch(() => '')
  ok('and the AI actions heading', agentGroup === 'AI actions', agentGroup)
  await closeMenu(p)

  /* control: a still-pending (unsent) row - the card shows it is sending - has none */
  const pendingShown = await until(p, (s) => Boolean(document.querySelector(s)), `${card(PENDING)} [data-test=msg-sending]`, 6000)
  const pending = pendingShown ? await menuItems(p, `${card(PENDING)} .msg-body`) : null
  ok('control: a pending row (shown as sending) has no AI action', pendingShown && (pending === null || noAi(pending) || pending.length === 0), { pendingShown, pending })
  if (pending) await closeMenu(p)

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

  /* HUM-10 643c30a8: a topic row of the home list (/) - the row menu ends with the group */
  const homeRow = `.topic-row-wrap:has(a.topic-row[data-key="${TASK}"])`
  ok('cards/home-topic: the home list shows the topic', await go(p, '/', homeRow))
  const home = await rowMenuOf(p, homeRow)
  ok('cards/home-topic: the topic row menu ends with the 7 AI actions', hasGroup(home), home)
  const homeHead = await p.$eval('[data-testid=sidebar-row-menu-group-ai-debate]', (el) => el.textContent.trim()).catch(() => '')
  ok('cards/home-topic: the group is headed AI actions', homeHead === 'AI actions', homeHead)
  await p.click('[data-testid=sidebar-row-menu-ai-analyse]').catch(() => {})
  const topicPosted = await until(p, () => [...document.querySelectorAll('article.msg')].some((e) => e.getClientRects().length
    && /AI action: Analyse/.test(e.textContent) && /ai-actions topic starter/.test(e.textContent)), null, 10000)
  ok('cards/home-topic: Analyse opens the topic and posts on its opening message', topicPosted)
  ok('cards/home-topic: no AI action error shows', !(await p.$('[data-testid=msg-ai-error]')))

  /* the sidebar Topics tab: its rows share the menu */
  await go(p, '/')
  const topicsTab = await p.waitForSelector('[data-testid=sidebar-tab-topics]', { visible: true, timeout: 15000 }).then(() => true, () => false)
  if (topicsTab) await p.click('[data-testid=sidebar-tab-topics]')
  const sideRow = `#sidebar-panel-topics .nav-row:has(a.nav-item[data-key="${TASK}"])`
  ok('cards/sidebar-topic: the Topics tab lists the topic', topicsTab && await p.waitForSelector(sideRow, { visible: true, timeout: 10000 }).then(() => true, () => false))
  const side = await rowMenuOf(p, sideRow)
  ok('cards/sidebar-topic: the row menu ends with the 7 AI actions', hasGroup(side), side)
  await p.keyboard.press('Escape')

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

  /* HUM-10 14dc0232: the same group in every other view, on a fresh page */
  const v = await browser.newPage()
  v.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  v.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await v.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.flow-scope', 'all')
    } catch { /* private mode */ }
  })
  await v.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  /* 1. a direct message, and its thread in the right pane */
  const dmCard = `.spool-main article.msg[data-msg-id="${DM_CARD}"]`
  ok('views/dm: the DM opens with its topic and thread', await go(v, `${DM_PATH}?topic=${DM_TOPIC}`, dmCard)
    && await v.waitForSelector(`aside.live-pane [data-msg-id="${DM_REPLY}"]`, { visible: true, timeout: 10000 }).then(() => true, () => false))
  const dm = await menuOf(v, `${dmCard} .msg-body`, 'msg-menu')
  ok('views/dm: a person\'s DM card lists the 7 AI actions, last in the menu', hasGroup(dm), dm)
  await closeMenuOf(v, 'msg-menu')
  const thread = await menuOf(v, `aside.live-pane article.msg[data-msg-id="${DM_REPLY}"] .msg-body`, 'msg-menu')
  ok('views/thread: an agent\'s reply in the thread pane lists the 7 AI actions', hasGroup(thread), thread)
  await closeMenuOf(v, 'msg-menu')

  /* 2. an issue's discussion: a comment is a message card */
  await go(v, '/issues', '[data-test=issues-page]')
  await sleep(400)
  await v.click('[data-test=issues-new]')
  await v.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
  await v.type('[data-test=issues-newrow-title]', 'AI actions on a comment')
  await v.keyboard.press('Enter')
  const key = await v.waitForFunction(() => {
    const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === 'AI actions on a comment')
    return r ? r.getAttribute('data-key') : false
  }, { timeout: 8000 }).then((h) => h.jsonValue(), () => '')
  if (key) await v.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  await v.waitForSelector('[data-test=issues-comment-input]', { timeout: 8000 }).catch(() => {})
  await sleep(400)
  await v.focus('[data-test=issues-comment-input]').catch(() => {})
  await v.type('[data-test=issues-comment-input]', 'Plan the export for Friday').catch(() => {})
  await v.keyboard.press('Enter')
  const commented = await until(v, () => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => /Plan the export for Friday/.test(c.textContent)), null, 8000)
  ok('views/issue: a comment posts in the discussion', commented)
  const issue = await menuOf(v, '[data-test=issues-comment] .msg-body', 'msg-menu')
  ok('views/issue: a person\'s comment lists the 7 AI actions', hasGroup(issue), issue)
  await closeMenuOf(v, 'msg-menu')

  /* HUM-10 643c30a8: the issue row menu and the epic menu end with six (no "Turn into an issue") */
  /* the mock keeps a created issue in this page only: close its dialog, stay on the list */
  for (let i = 0; i < 3 && await v.$('[data-test=issues-comment-input]'); i++) {
    await v.keyboard.press('Escape')
    await sleep(300)
  }
  const issueRow = await menuOf(v, `[data-test=issues-row][data-key="${key}"]`, 'issue-menu')
  ok('cards/issue: an issue row menu keeps Edit first, then the 6 AI actions', Array.isArray(issueRow) && issueRow[0] === 'edit' && hasIssueGroup(issueRow) && !issueRow.includes('ai-issue'), issueRow)
  await v.click('[data-testid=issue-menu-ai-analyse]').catch(() => {})
  await sleep(600)
  await v.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`).catch(() => {})
  const issuePosted = await until(v, () => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => /AI action: Analyse/.test(c.textContent) && /AI actions on a comment/.test(c.textContent)), null, 10000)
  ok('cards/issue: Analyse posts in the issue\'s discussion, quoting it', issuePosted)
  ok('cards/issue: no AI action error shows', !(await v.$('[data-test=issues-list-error]')))
  await v.keyboard.press('Escape')
  await go(v, '/issues', '[data-testid=sidebar-epic][data-key="SPL-1"]')
  const epic = await menuOf(v, '[data-testid=sidebar-epic][data-key="SPL-1"]', 'issue-menu')
  ok('cards/epic: an epic\'s menu ends with the 6 AI actions', hasIssueGroup(epic), epic)
  await closeMenuOf(v, 'issue-menu')

  /* 3. Flow, the left panel: an entry's own menu */
  ok('views/flow: the Flow list holds a person\'s and an agent\'s entry', (await openFlow(v)) && Boolean(await v.$(flowEntry(ALERT))))
  const flowP = await menuOf(v, flowEntry(DM_CARD), 'flow-menu')
  ok('views/flow: a person\'s entry menu offers Open original, then the 7 AI actions', Array.isArray(flowP) && flowP[0] === 'original' && hasGroup(flowP), flowP)
  const head = await v.$eval('[data-testid=flow-menu-group-ai-debate]', (el) => el.textContent.trim()).catch(() => '')
  ok('views/flow: the group is headed AI actions', head === 'AI actions', head)
  await closeMenuOf(v, 'flow-menu')
  const flowA = await menuOf(v, flowEntry(ALERT), 'flow-menu')
  ok('views/flow: an agent\'s entry lists the 7 AI actions', Array.isArray(flowA) && flowA[0] === 'original' && hasGroup(flowA), flowA)
  await closeMenuOf(v, 'flow-menu')
  await menuOf(v, flowEntry(DM_CARD), 'flow-menu')
  await v.click('[data-testid=flow-menu-ai-analyse]')
  const flowOnDm = await until(v, (path) => decodeURIComponent(location.pathname).endsWith(decodeURIComponent(path)), DM_PATH, 10000)
  const flowPosted = await until(v, () => [...document.querySelectorAll('article.msg')].some((e) => e.getClientRects().length
    && /AI action: Analyse/.test(e.textContent) && /Direct ping/.test(e.textContent)), null, 10000)
  ok('views/flow: Analyse opens the message\'s DM and posts there, quoting it', flowOnDm && flowPosted, { flowOnDm, flowPosted, path: await v.evaluate(() => location.pathname) })
  ok('views/flow: no AI action error shows', !(await v.$('[data-testid=msg-ai-error]')))

  /* 4. search results */
  await go(v, '/search?q=' + encodeURIComponent('Direct ping'), HIT)
  const hitP = await menuOf(v, HIT, 'search-row-menu')
  ok('views/search: a person\'s hit menu keeps its entries, then the 7 AI actions', Array.isArray(hitP) && hitP[0] === 'original' && hasGroup(hitP), hitP)
  await closeMenuOf(v, 'search-row-menu')
  await go(v, '/search?q=' + encodeURIComponent('is online'), HIT)
  const hitA = await menuOf(v, HIT, 'search-row-menu')
  ok('views/search: an agent\'s hit lists the 7 AI actions', Array.isArray(hitA) && hitA[0] === 'original' && hasGroup(hitA), hitA)
  await closeMenuOf(v, 'search-row-menu')

  /* 5. phone: the Flow sheet has one AI actions entry that turns into the seven */
  await v.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
  ok('views/phone: the Flow list opens', await openFlow(v))
  await sleep(400)
  const flowSheet = await menuOf(v, flowEntry(DM_CARD), 'flow-menu')
  ok('views/phone: the Flow sheet has one AI actions entry, not the seven', Array.isArray(flowSheet) && flowSheet.includes('ai-more') && !flowSheet.includes('ai-analyse'), flowSheet)
  await v.click('[data-testid=flow-menu-ai-more]').catch(() => {})
  const flowSwapped = await until(v, () => Boolean(document.querySelector('[data-testid=flow-menu-ai-analyse]')), null, 4000)
  const flowNow = flowSwapped ? await v.$$eval('[data-testid=flow-menu] [role=menuitem]', (els) => els.map((e) => String(e.getAttribute('data-testid') || '').replace(/^flow-menu-/, ''))) : []
  ok('views/phone: picking it shows the seven actions in the same sheet', JSON.stringify(flowNow) === JSON.stringify(AI_IDS), flowNow)
  await closeMenuOf(v, 'flow-menu')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmsg-ai-actions: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
