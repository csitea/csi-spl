// Issues (specs/039, CLE-34993) — live proof, signed in, against a deployed WUI + hub.
//
// Owner, 2026-09-26: issues "the way Linear shows the issues, keeping still
// this 3 vertical lines structure"; "each issue must have prio, deadline,
// level, title, description (shown only on the right side), the deadline
// must be a calendar control which has also time".
//
// Steps (n = 1 per run):
//   1. Issues is the third rail tab (after Channels) and opens /issues
//   2. create an issue in the UI (title + description) -> it gets a key
//   3. the middle list shows key + title, never the description
//   4. status 03-wip, prio 1, level L, assignee, deadline with
//      time through the right-pane controls -> the row moves to the
//      03-wip group, carries prio 1 / level 4; the hub answers the
//      same values (GET /v1/view/issues/{key}), deadline stored UTC
//   5. a second tab sees a later change live, without a reload
//   6. a comment lands in the issue's discussion
//   7. reload -> grouping, priority, level and deadline are still there
//   8. /issues?issue=<key> opens that issue (the search lane's link)
//   9-12. SPL-18: the level-1 panel, a feature made in the UI, an issue under
//      it, a subtask in the right pane, the panel's count
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [CHROME_PATH=...]
//     [PUPPETEER_CORE=<path>] node tests/e2e/issues-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

/** goto / reload that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      if (url) await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      else await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
}

/** The row of `key`: its group's status and its data attributes. */
const ROW = (key) => {
  const el = document.querySelector(`[data-test=issues-row][data-key="${key}"]`)
  if (!el) return null
  const g = el.closest('.issues-group')
  return {
    status: g ? g.getAttribute('data-status') : '',
    priority: el.getAttribute('data-priority'),
    level: el.getAttribute('data-level'),
    assignee: (el.querySelector('[data-test=issues-row-assignee]') || {}).getAttribute?.('data-assignee') || '',
    text: el.innerText,
  }
}

async function pick(p, trigger, value) {
  await p.click(`[data-test=${trigger}]`)
  await p.waitForSelector('[data-test=issues-menu]', { visible: true, timeout: 5000 })
  /* find + click in one page call: the menu re-renders under a held handle */
  const chosen = await until(() => p.evaluate((v) => {
    const opts = [...document.querySelectorAll('[data-test=issues-menu-option]')]
    const opt = v === null ? opts.find((o) => o.getAttribute('data-value')) : opts.find((o) => o.getAttribute('data-value') === v)
    if (!opt) return ''
    opt.click()
    return opt.getAttribute('data-value')
  }, value), 5000)
  await sleep(1200)
  return chosen
}

const hubIssue = (p, key) => p.evaluate(async (api, k) => {
  const r = await fetch(`${api}/v1/view/issues/${k}`, { credentials: 'include' })
  return r.ok ? (await r.json()).issue : { status_code: r.status }
}, API, key)

async function signIn(browser) {
  const p = await browser.newPage()
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

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  const p = await signIn(browser)

  // 1. the rail
  const rail = await p.$$eval('[role=tab][data-testid^=sidebar-tab-]', (els) => els.map((e) => e.getAttribute('data-testid')))
  step('1 Issues is the third rail tab, after Channels', rail[1] === 'sidebar-tab-channels' && rail[2] === 'sidebar-tab-issues', { rail })
  await p.click('[data-testid=sidebar-tab-issues]')
  const page = await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: 30000 }).then(() => true, () => false)
  /* owner 2026-09-26: statuses 01-eval .. 09-done (topic f2c32da2), no title
     filter (topic d81cbf47) */
  const statusOpts = await p.$$eval('[data-test=issues-filter-status] option', (els) => els.slice(1).map((e) => e.textContent.trim()))
  step('1b the status filter offers the owner\'s six statuses; no title filter', JSON.stringify(statusOpts) ===
    JSON.stringify(['01-eval', '02-todo', '03-wip', '03-diss', '07-qas', '09-done']) && !(await p.$('[data-test=issues-search]')), { statusOpts })
  step('1 the tab opens /issues', page && new URL(p.url()).pathname.endsWith('/issues'), { url: p.url() })
  await sleep(1500)
  await shot(p, '01-issues-tab')

  // 2. create
  const title = `Live proof ${run}: rotate the relay key`
  const descr = `Description ${run} - only in the right pane`
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail-title]', { clickCount: 3 })
  await p.type('[data-test=issues-detail-title]', title)
  await p.click('[data-test=issues-detail-body]')
  await p.type('[data-test=issues-detail-body]', descr)
  await p.click('[data-test=issues-create]')
  const key = await until(() => p.evaluate((want) => {
    const t = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    const creating = !!document.querySelector('[data-test=issues-create]')
    return !creating && t && t.value === want && k && /^[A-Z][A-Z0-9]*-\d+$/.test(k.textContent.trim()) ? k.textContent.trim() : ''
  }, title), 30000)
  step('2 created in the UI, the hub gave it a key', !!key, { key })
  if (!key) throw new Error('no key')

  // 3. list shows key + title, never the description
  const row0 = await until(() => p.evaluate(ROW, key), 30000)
  step('3 the list row shows the key and the title, not the description',
    !!row0 && row0.text.includes(key) && row0.text.includes(title) && !row0.text.includes(descr), { row: row0 && row0.text.slice(0, 160) })

  // 4. attributes from the right pane
  await pick(p, 'issues-status', 'wip')
  await pick(p, 'issues-priority', '1')
  await pick(p, 'issues-level', '4')
  const who = await pick(p, 'issues-assignee', null)
  const local = await p.evaluate(() => {
    const d = new Date(Date.now() + 2 * 86400000)
    const pad = (n) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T15:30`
  })
  /* owner 2026-09-26 (topic 32a56460): a date plus a 24-hour time, 07-22 */
  const dlType = await p.$eval('[data-test=issues-deadline]', (el) => el.type)
  const times = await p.$$eval('[data-test=issues-deadline-time] option', (els) => els.map((e) => e.textContent.trim()))
  step('4 the deadline is a date plus a 24-hour time from 07:00 to 22:00 (no AM/PM)', dlType === 'date' && times[0] === '07:00' &&
    times[times.length - 1] === '22:00' && !times.some((x) => /am|pm/i.test(x)), { type: dlType, first: times[0], last: times[times.length - 1], n: times.length })
  const setField = (sel, v) => p.$eval(sel, (el, val) => {
    el.value = val
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
  }, v)
  await setField('[data-test=issues-deadline]', local.slice(0, 10))
  await sleep(1500)
  await setField('[data-test=issues-deadline-time]', local.slice(11))
  await sleep(1200)
  const row1 = await until(() => p.evaluate((k) => {
    const r = ((key) => {
      const el = document.querySelector(`[data-test=issues-row][data-key="${key}"]`)
      if (!el) return null
      const g = el.closest('.issues-group')
      return { status: g && g.getAttribute('data-status'), priority: el.getAttribute('data-priority'), level: el.getAttribute('data-level') }
    })(k)
    return r && r.status === 'wip' && r.priority === '1' && r.level === '4' ? r : null
  }, key))
  step('4 the row moved to 03-wip with prio 1 and level L', !!row1, { row: row1 })
  const wantUTC = await p.evaluate((v) => new Date(v).toISOString().replace(/\.\d{3}Z$/, 'Z'), local)
  /* the deadline PATCH goes out on change and takes 1-3 s from this box:
     poll the hub for it rather than read once after a fixed wait */
  let hub = {}
  await until(async () => {
    hub = await hubIssue(p, key)
    return hub.deadline === wantUTC && hub.assignee === who
  }, 15000)
  step('4 the hub holds the same values; the deadline is the calendar+time value in UTC',
    hub.status === 'wip' && hub.priority === 1 && hub.level === 4 && hub.assignee === who && hub.deadline === wantUTC &&
    hub.description === descr && dlType === 'date',
    { status: hub.status, priority: hub.priority, level: hub.level, assignee: hub.assignee, deadline: hub.deadline, want: wantUTC, control: dlType })
  await shot(p, '02-edited-detail')

  // 5. a second tab sees a change live
  const p2 = await browser.newPage()
  await p2.setViewport({ width: 1440, height: 900 })
  await nav(p2, BASE + '/issues')
  await until(() => p2.evaluate(ROW, key), 30000)
  /* the row comes from the REST read; frames need the tab's socket open */
  const sockOpen = await until(() => p2.evaluate(() => !!document.querySelector('[data-testid=connection-health] .health-dot.ok')), 30000)
  res.second_tab_socket_open = !!sockOpen
  /* a background tab gets no animation frames, and a click waits for one */
  await p.bringToFront()
  await pick(p, 'issues-status', 'qas')
  await p2.bringToFront()
  const live = await until(() => p2.evaluate((k) => {
    const el = document.querySelector(`[data-test=issues-row][data-key="${k}"]`)
    const g = el && el.closest('.issues-group')
    return g && g.getAttribute('data-status') === 'qas'
  }, key), 15000)
  step('5 a second tab moves the row to 07-qas without a reload', !!live, { socket_open: !!sockOpen })
  await shot(p2, '03-second-tab-live')
  await p2.close()
  await p.bringToFront()

  // 6. discussion
  const note = `progress ${run}: dev done, prd next`
  await p.click('[data-test=issues-comment-input]')
  await p.type('[data-test=issues-comment-input]', note)
  await p.click('[data-test=issues-comment-send]')
  const said = await until(() => p.evaluate((n) => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => c.innerText.includes(n)), note), 15000)
  step('6 a comment lands in the issue discussion', !!said, {})

  // 7. reload keeps it
  await nav(p)
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: 30000 })
  const row2 = await until(() => p.evaluate((k) => {
    const el = document.querySelector(`[data-test=issues-row][data-key="${k}"]`)
    const g = el && el.closest('.issues-group')
    return el ? { status: g && g.getAttribute('data-status'), priority: el.getAttribute('data-priority'), level: el.getAttribute('data-level') } : null
  }, key), 30000)
  step('7 after a reload the row is still 07-qas, prio 1, level L',
    !!row2 && row2.status === 'qas' && row2.priority === '1' && row2.level === '4', { row: row2 })
  await p.click(`[data-test=issues-row][data-key="${key}"]`)
  await p.waitForSelector('[data-test=issues-deadline]', { visible: true, timeout: 10000 })
  const dlAfter = await p.evaluate(() => document.querySelector('[data-test=issues-deadline]').value + 'T' + document.querySelector('[data-test=issues-deadline-time]').value)
  const rowWhen = await p.evaluate((k) => (document.querySelector(`[data-test=issues-row][data-key="${k}"] .issues-when`) || {}).textContent || '', key)
  step('7 the deadline control shows the same local date and time; the list shows it 24-hour', dlAfter === local && rowWhen.includes('15:30') && !/am|pm/i.test(rowWhen),
    { got: dlAfter, want: local, row: rowWhen })
  await sleep(1500)
  await shot(p, '04-after-reload')

  // 8. a link to the issue opens it (search rows and shared links use it)
  await nav(p, BASE + '/issues?issue=' + encodeURIComponent(key))
  const opened = await until(() => p.evaluate(() => {
    const k = document.querySelector('[data-test=issues-detail-key]')
    return k ? k.textContent.trim() : ''
  }), 30000)
  step('8 /issues?issue=<key> opens that issue in the right pane', opened === key, { got: opened })
  res.key = key

  // 9-12 SPL-18: epics and features in the left-most panel, issues under
  // them, subtasks in the right pane (owner 2026-09-26 09:08)
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: 30000 })
  /* an empty list is truthy: wait for rows, not for an answer */
  const panel0 = await until(() => p.evaluate(() => {
    const keys = [...document.querySelectorAll('[data-testid=sidebar-epic]')].map((e) => e.getAttribute('data-key'))
    return keys.length ? keys : null
  }), 20000)
  step('9 the left-most panel lists the level-1 rows (epics and features)', Array.isArray(panel0) && panel0.length > 0, { n: panel0 && panel0.length })
  const ftitle = `Proof feature ${run}`
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-title]', ftitle)
  for (let i = 0; i < 3; i++) {
    if (await p.$eval('[data-test=issues-kind]', (el) => el.getAttribute('data-kind')) === 'feature') break
    await p.click('[data-test=issues-kind]')
  }
  await p.click('[data-test=issues-create]')
  const fkey = await until(() => p.evaluate((want) => {
    const t = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    return !document.querySelector('[data-test=issues-create]') && t && t.value === want && k ? k.textContent.trim() : ''
  }, ftitle), 30000)
  const frow = await until(() => p.evaluate((k) => {
    const el = document.querySelector(`[data-testid=sidebar-epic][data-key="${k}"]`)
    return el ? el.querySelector('.epic-row__kind').getAttribute('data-kind') : ''
  }, fkey), 20000)
  step('10 a feature made in the UI is a level-1 row of the panel', !!fkey && frow === 'feature', { key: fkey, kind: frow })
  await p.click(`[data-testid=sidebar-epic][data-key="${fkey}"]`)
  await until(() => p.evaluate(() => new URL(location.href).searchParams.get('epic')), 15000)
  await sleep(1200)
  const ititle = `Proof issue ${run}`
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-title]', ititle)
  await p.click('[data-test=issues-create]')
  const ikey = await until(() => p.evaluate((want) => {
    const t = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    return !document.querySelector('[data-test=issues-create]') && t && t.value === want && k ? k.textContent.trim() : ''
  }, ititle), 30000)
  const ihub = ikey ? await hubIssue(p, ikey) : {}
  step('11 an issue filed with the feature selected lands under it (level 2)', ihub.kind === 'issue' && ihub.epic === fkey, { key: ikey, kind: ihub.kind, epic: ihub.epic })
  await p.waitForSelector('[data-test=issues-subtask-input]', { visible: true, timeout: 10000 })
  await p.type('[data-test=issues-subtask-input]', `Proof subtask ${run}`)
  await p.click('[data-test=issues-subtask-add]')
  const skey = await until(() => p.evaluate(() => {
    const el = document.querySelector('[data-test=issues-subtask]')
    return el ? el.getAttribute('data-key') : ''
  }), 20000)
  const shub = skey ? await hubIssue(p, skey) : {}
  const count = await until(() => p.evaluate((k) => {
    const el = document.querySelector(`[data-testid=sidebar-epic][data-key="${k}"] [data-testid=sidebar-epic-count]`)
    return el && el.textContent.trim() === '0/1' ? el.textContent.trim() : ''
  }, fkey), 15000)
  step('12 a subtask added in the right pane is level 3 under the issue; the panel counts the issue',
    shub.kind === 'subtask' && shub.parent === ikey && shub.epic === fkey && count === '0/1', { key: skey, kind: shub.kind, parent: shub.parent, epic: shub.epic, count })
  await sleep(800)
  await shot(p, '05-epics-features-subtasks')
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
