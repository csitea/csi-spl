// CLE-3493 proof of the channel properties People AND Agents dropdowns,
// against the mock dev server or a deployed WUI. Both halves run the same
// steps, because adding an agent has to work the way adding a person does:
//   (a) with the query empty the dropdown lists EVERY candidate, and every
//       option is really painted (not clipped by the dialog's scroll box);
//   (b) a partial id narrows the list to the matches; a control query that
//       matches nobody shows 0 options;
//   (c) picking one makes them a member (then they are removed again, so a
//       live tenant ends as it started).
// And #lobby, a default channel, lists every person read-only, and its
// agents are picked like in any channel (owner decision 2026-09-25): the
// agents half runs there too, adding one agent and taking it out again with
// the minus, so the proof leaves #lobby with no agent it invited.
//
//   BASE=<wui> OUT=<dir> [EMAIL=<member> PW_FILE=<0600 file>] [TENANT=t1] \
//     [CHANNEL=<channel id>] [CREATE=1] [ONLY=people|agents|lobby] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/channel-people-live.proof.mjs
//
// Without EMAIL the page is used as served (the mock dev server). The password
// is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = process.env.EMAIL || ''
const TENANT = process.env.TENANT || 't1'
const WANT = process.env.CHANNEL || ''
const ONLY = process.env.ONLY || ''
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

/** The two pickers: same steps, their own test ids and row shapes. */
const HALVES = {
  people: {
    pick: 'channel-invite-pick-',
    options: 'channel-people-options',
    search: 'channel-people-search',
    chevron: 'channel-people-search-button',
    add: 'channel-people-add',
    empty: 'channel-invite-empty',
    rows: '[data-testid="channel-invite-members"] > li > .member-rows__name',
    remove: 'channel-member-remove-',
    api: /\/v1\/channels\/[^/]+\/members/,
  },
  agents: {
    pick: 'channel-agent-invite-',
    options: 'channel-agent-options',
    search: 'channel-agent-search',
    chevron: 'channel-agent-search-button',
    add: 'channel-agent-add',
    empty: 'channel-agent-invite-empty',
    rows: '[data-testid="channel-agents-list"] > li > .member-rows__name',
    remove: 'channel-agent-remove-',
    api: /\/v1\/channels\/[^/]+\/agents/,
  },
}

/** Option ids, and whether the browser really paints each one on top. */
const readOptions = (p, h) => p.evaluate((h) => {
  const out = []
  for (const li of document.querySelectorAll(`[data-testid^="${h.pick}"]:not([data-testid="${h.empty}"])`)) {
    const id = li.getAttribute('data-testid').slice(h.pick.length)
    li.scrollIntoView({ block: 'nearest' })
    const r = li.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + Math.min(20, r.width / 2), r.top + r.height / 2)
    out.push({ id, visible: r.height > 0 && !!hit && (hit === li || li.contains(hit)) })
  }
  const empty = document.querySelector(`[data-testid="${h.empty}"]`)
  // Where the list sits: right under its input, as wide as the field, inside
  // the dialog (the CLE-3493 defect painted it full width at the page bottom).
  const list = document.querySelector(`[data-testid="${h.options}"]`)
  const field = document.querySelector(`[data-testid="${h.search}"]`)?.closest('.invite-add__control')
  const dialog = document.querySelector('[data-testid="ui-dialog"]')
  let placed = null
  if (list && field && dialog) {
    const l = list.getBoundingClientRect()
    const f = field.getBoundingClientRect()
    const d = dialog.getBoundingClientRect()
    placed = {
      gap: Math.round(l.top - f.bottom),
      dx: Math.round(l.left - f.left),
      dw: Math.round(l.width - f.width),
      inDialog: l.left >= d.left && l.right <= d.right,
    }
    placed.ok = placed.gap >= 0 && placed.gap <= 12 && Math.abs(placed.dx) <= 2 && Math.abs(placed.dw) <= 2 && placed.inDialog
  }
  return { options: out, empty: empty ? empty.textContent.trim() : null, placed }
}, { pick: h.pick, empty: h.empty, options: h.options, search: h.search })
/**
 * Every visible people/agent list in the dialog (and an open dropdown): one
 * row per line - each row's top at or below the previous row's bottom - and
 * each row led by its own avatar image.
 */
const readLayout = (p) => p.evaluate(() => {
  const dlg = document.querySelector('[data-testid="channel-properties"]')
  const lists = [...dlg.querySelectorAll('ul.member-rows, [data-testid$="-options"]')].filter((ul) => ul.offsetParent !== null)
  const out = []
  for (const ul of lists) {
    const lis = [...ul.children].filter((li) => li.tagName === 'LI' && !li.matches('.invite-add__empty'))
    let stacked = true
    let avatars = 0
    let prev = null
    for (const li of lis) {
      const r = li.getBoundingClientRect()
      if (prev && r.top < prev.bottom - 1) stacked = false
      prev = r
      const first = li.firstElementChild
      if (first && first.matches('img.spool-avatar') && first.getBoundingClientRect().width > 0) avatars++
    }
    out.push({ list: ul.getAttribute('data-testid'), rows: lis.length, stacked, avatars })
  }
  return out
})
const layoutOk = (lay) => lay.length > 0 && lay.every((l) => l.stacked && l.avatars === l.rows)
const rowsOf = (p, h) => p.$$eval(h.rows, (els) => els.map((s) => s.textContent.trim()))

/** (a) full list, (b) narrow + control, (c) pick + Add, (d) minus undoes it. */
async function runHalf(p, kind, hub, where = '') {
  const h = HALVES[kind]
  const tag = (x) => `${where ? where + ': ' : ''}${kind} ${x}`
  const key = where ? `${where}_${kind}` : kind
  const before = await rowsOf(p, h)
  res[key] = { before }

  await p.click(`[data-testid="${h.chevron}"]`)
  await sleep(500)
  const all = await readOptions(p, h)
  await p.screenshot({ path: `${OUT}/${kind}-a-full-list.png` })
  const ids = all.options.map((o) => o.id)
  const hidden = all.options.filter((o) => !o.visible).map((o) => o.id)
  step(tag('(a) empty query lists every candidate, none clipped'), ids.length > 0 && hidden.length === 0,
    { n: ids.length, ids, hidden, empty: all.empty })
  step(tag('(a) the list opens right under its input, inside the dialog'), !!all.placed?.ok, { placed: all.placed })
  const layA = await readLayout(p)
  step(tag('(a) every list is vertical, one avatar per row'), layoutOk(layA), { lists: layA })
  await p.keyboard.press('Escape')
  await sleep(300)
  const stillOpen = !!(await p.$('[data-testid="channel-properties"]'))
  step(tag('Escape in the dropdown keeps the dialog open'), stillOpen)
  if (!stillOpen || ids.length === 0) return

  // (b) partial query narrows; control query matches nobody
  const target = ids[ids.length - 1]
  const partial = target.replace(/^[A-Z]+-/, '')
  const input = await p.$(`[data-testid="${h.search}"]`)
  const retype = async (text) => {
    await input.evaluate((el) => el.select())
    await p.keyboard.press('Backspace')
    await input.type(text, { delay: 30 })
    await sleep(400)
  }
  await retype(partial)
  const narrowed = await readOptions(p, h)
  const nIds = narrowed.options.map((o) => o.id)
  step(tag('(b) a partial id narrows to the matches'), nIds.includes(target) && nIds.length <= ids.length && narrowed.options.every((o) => o.visible),
    { query: partial, n: nIds.length, ids: nIds })
  await retype('zz-no-such-one')
  const none = await readOptions(p, h)
  step(tag('(b) control: a query matching nobody shows 0 options'), none.options.length === 0 && !!none.empty, { n: none.options.length, empty: none.empty })

  // (c) pick + Add makes them a member; the hub answers 2xx
  await retype(partial)
  await p.click(`[data-testid="${h.pick}${target}"]`)
  await sleep(300)
  const shown = await input.evaluate((el) => el.value)
  const addBtn = await p.$(`[data-testid="${h.add}"]`)
  const addEnabled = addBtn ? await addBtn.evaluate((b) => !b.disabled) : false
  step(tag('(c) the pick fills the input and enables Add'), addEnabled && shown.startsWith(target), { shown, addEnabled })
  hub.length = 0
  if (addEnabled) await addBtn.click()
  await p.waitForSelector(`[data-testid="${h.remove}${target}"]`, { timeout: 10000 }).catch(() => null)
  await sleep(300)
  const after = await rowsOf(p, h)
  const err = await p.$eval('[data-testid="channel-invite-error"]', (e) => e.textContent.trim()).catch(() => '')
  const posts = hub.filter((r) => r.method === 'POST' && h.api.test(r.url)).map((r) => r.status)
  step(tag('(c) Add makes them a member'), after.includes(target) && !err && (EMAIL ? posts.length > 0 && posts.every((s) => s >= 200 && s < 300) : true),
    { target, rows: after, error: err, hub_post: posts })
  await p.screenshot({ path: `${OUT}/${kind}-c-added.png` })
  const layC = await readLayout(p)
  step(tag('(c) the member list is vertical, one avatar per row'), layoutOk(layC) && layC.some((l) => l.rows > 0), { lists: layC })
  if (after.includes(target) && !before.includes(target)) {
    hub.length = 0
    await p.click(`[data-testid="${h.remove}${target}"]`)
    await sleep(1500)
    const left = await rowsOf(p, h)
    const dels = hub.filter((r) => r.method === 'DELETE' && h.api.test(r.url)).map((r) => r.status)
    res[key].restored = !left.includes(target)
    step(tag('(d) the minus takes them out again'), !left.includes(target) && (EMAIL ? dels.length > 0 && dels.every((s) => s >= 200 && s < 300) : true),
      { target, rows: left, hub_delete: dels })
  }
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let code = 1
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => null)
  const p = await browser.newPage()
  const hub = []
  p.on('response', (r) => { const q = r.request(); if (q.method() !== 'GET' && q.method() !== 'OPTIONS') hub.push({ method: q.method(), url: r.url(), status: r.status() }) })
  await p.setViewport({ width: 1280, height: 800 })
  if (EMAIL) {
    const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', EMAIL)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    step('native sign-in', !!trig, { url: p.url() })
    if (!trig) throw new Error('sign-in failed')
  } else {
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  }
  await p.waitForSelector('[data-testid="sidebar-tab-channels"]', { timeout: 30000 })
  await sleep(2000)
  await p.$eval('[data-testid="sidebar-tab-channels"]', (b) => b.click())
  await sleep(500)
  // The mock's channels are all default ones: make a private one to inspect
  // (CREATE=1 does the same on a live TEST tenant that has none).
  if ((!EMAIL && !WANT) || process.env.CREATE === '1') {
    await p.$eval('[data-testid="create-channel"]', (b) => b.click())
    await p.waitForSelector('[data-testid="create-channel-name"]', { timeout: 5000 })
    await p.type('[data-testid="create-channel-name"]', 'people-proof')
    await p.$eval('[data-testid="create-channel-submit"]', (b) => b.click())
    await sleep(1000)
  }
  // Properties of one channel, through ITS row menu: every row's panel is in
  // the DOM (v-show), so the item is looked up inside the row, never globally.
  const openProps = async (id) => {
    const ok = await p.evaluate((key) => {
      const row = document.querySelector(`[data-testid="sidebar-panel-channels"] .nav-row[data-order="${key}"]`)
      if (!row) return false
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }))
      const item = row.querySelector('[data-testid="sidebar-row-menu-properties"]')
      if (!item) return false
      item.click()
      return true
    }, id)
    if (!ok) { await p.keyboard.press('Escape'); return false }
    return !!(await p.waitForSelector('[data-testid="channel-properties"]', { timeout: 10000 }).catch(() => null))
  }
  const closeDialog = async () => {
    await p.$eval('[data-testid="ui-dialog-close"]', (b) => b.click()).catch(() => {})
    await sleep(500)
  }
  const rows = await p.$$eval('[data-testid="sidebar-panel-channels"] .nav-row', (els) => els.map((e) => e.getAttribute('data-order')))
  const DEFAULTS = ['lobby', 'alerts', 'feedback']

  // A default channel: every person read-only, nobody removable; its agents
  // are picked with the created channel's picker and minus (2026-09-25).
  if (!ONLY || ONLY === 'lobby') {
    const openedLobby = await openProps('lobby')
    step('lobby: Properties opens', openedLobby, { rows })
    if (openedLobby) {
      await p.waitForSelector('[data-testid="channel-default-note"], [data-testid="channel-invite-error"]', { timeout: 15000 }).catch(() => null)
      await sleep(500)
      const lobby = await p.evaluate(() => {
        const dlg = document.querySelector('[data-testid="channel-properties"]')
        const txt = (sel) => [...dlg.querySelectorAll(sel)].map((e) => e.textContent.trim())
        return {
          note: !!dlg.querySelector('[data-testid="channel-default-note"]'),
          people: txt('[data-testid="channel-default-people"] > li > .member-rows__name'),
          agents: txt('[data-testid="channel-agents-list"] > li > .member-rows__name'),
          personRemoves: dlg.querySelectorAll('[data-testid^="channel-member-remove-"]').length,
          personPickers: dlg.querySelectorAll('[data-testid="channel-people-search"]').length,
          agentPickers: dlg.querySelectorAll('[data-testid="channel-agent-search"]').length,
          error: dlg.querySelector('[data-testid="channel-invite-error"]')?.textContent.trim() || '',
        }
      })
      res.lobby = lobby
      await p.screenshot({ path: `${OUT}/lobby-default.png` })
      const layL = await readLayout(p)
      step('lobby: people and agents are vertical, one avatar per row', layoutOk(layL) && layL.length >= 1, { lists: layL })
      step('lobby: lists every person, with the note', lobby.note && lobby.people.length > 0 && !lobby.error,
        { n_people: lobby.people.length, people: lobby.people, n_agents: lobby.agents.length, agents: lobby.agents, error: lobby.error })
      step('lobby: people stay read-only (0 person minus, 0 person picker)', lobby.personRemoves === 0 && lobby.personPickers === 0,
        { removes: lobby.personRemoves, pickers: lobby.personPickers })
      step('lobby: agents have the picker', lobby.agentPickers === 1, { pickers: lobby.agentPickers })
      if (lobby.agentPickers === 1) await runHalf(p, 'agents', hub, 'lobby')
      // The Agents tab mirrors the same list.
      await p.$eval('[data-testid="channel-properties-tab-agents"]', (b) => b.click())
      await sleep(400)
      const layT = await readLayout(p)
      await p.screenshot({ path: `${OUT}/lobby-agents-tab.png` })
      const tabNone = !!(await p.$('[data-testid="channel-agents-none"]'))
      const tabList = layT.some((l) => l.list === 'channel-agents-readonly')
      step('lobby: the Agents tab is vertical, one avatar per row (or says No agents)', (tabList || tabNone) && layT.every((l) => l.stacked && l.avatars === l.rows),
        { lists: layT, none: tabNone })
      await p.$eval('[data-testid="channel-properties-tab-people"]', (b) => b.click())
      await closeDialog()
    }
  }
  // A private channel for the add flows: CHANNEL, else the first non-default one.
  if (ONLY !== 'lobby') {
    let opened = ''
    for (const id of WANT ? [WANT] : rows.filter((r) => !DEFAULTS.includes(r))) {
      if (await openProps(id)) { opened = id; break }
    }
    step('channel properties dialog opens', !!opened, { channel: opened, rows })
    if (!opened) throw new Error('no private channel with properties')
    await p.waitForSelector('[data-testid="channel-people-search"]', { timeout: 15000 })
    await sleep(1000)
    for (const kind of ONLY ? [ONLY] : ['people', 'agents']) await runHalf(p, kind, hub)
  }
  code = res.steps.every((s) => s.ok) ? 0 : 1
} catch (e) {
  step('run', false, { error: String((e && e.message) || e) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(code === 0 ? 'ALL PASS' : 'FAILED')
process.exit(code)
