// Spec 130 section 3.1 (owner HUM-10, t1 82dff03c, msgs 47ec5aab and
// 6a0ec650): the Flow has a drop box of every person and agent of the
// workspace; it starts on the signed-in person's own Flow, and the choice
// rides the address (?flow=<id>, owner e04820a5), proved in a REAL browser
// against the mock bundle. The mock's agent GRK-03@box-a has one topic line:
// the DM HUM-1 sent it (7777...; its own reply 7a7a... is no event of its
// own). HUM-2 has no topic line, only the releases everyone gets (Q1).
//
//   - the default is me: the box shows Me, the list is my Flow, no ?flow=
//   - the list: persons, then agents, each under its heading; typing filters
//   - pick an agent: ?flow=GRK-03@box-a, its line, the "someone else's" note,
//     no Mark read in the line menu, and my own numbers do not move
//   - pick a person: ?flow=HUM-2 and its Flow
//   - the URL round trip: a pasted /?flow=GRK-03@box-a opens the Flow tab on
//     it; picking Me drops the parameter; a junk ?flow= is my own Flow
//   - 1440x900 and 390x844, screenshots (the open list, an agent's Flow) into SHOT_DIR
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e flow-member
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const SHOT_DIR = process.env.SHOT_DIR || ''
const MINE = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const AGENTS_LINE = '77777777-7777-4777-8777-777777777777'
const AGENT = 'GRK-03@box-a'
const PERSON = 'HUM-2'
const LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const PICKER = '[data-testid=sidebar-panel-flow] [data-test=flow-member-picker]'
const OPTION = '[data-test=flow-member-option]'
const LINE = `${LIST} [data-testid=left-entry][data-type=dm]`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

function facts(page) {
  return page.evaluate((list, picker, option) => {
    const rows = [...document.querySelectorAll(list + ' [data-testid=left-entry]')]
    const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('flow')
    const rail = (id) => document.querySelector(`[data-testid=sidebar-tab-${id}-count]`)?.textContent.trim() || ''
    const groups = [...document.querySelectorAll('[data-test=flow-member-picker-group]')].map((g) => g.textContent.trim())
    return {
      query: new URLSearchParams(location.search).get('flow'),
      box: document.querySelector(picker)?.value || '',
      options: [...document.querySelectorAll(option)].map((o) => o.getAttribute('data-value')),
      groups,
      ids: rows.filter((e) => e.getAttribute('data-type') !== 'release').map((e) => e.getAttribute('data-msg-id')),
      releases: rows.filter((e) => e.getAttribute('data-type') === 'release').length,
      member: store.member,
      note: Boolean(document.querySelector('[data-testid=flow-member-note]')),
      dmChip: Number(document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('data-count') ?? -1),
      ownUnread: store.unread ? store.unread.total : -1,
      ownCounts: store.counts ? store.counts.total : -1,
      railDm: rail('dm'),
    }
  }, LIST, PICKER, OPTION)
}

/* type into the drop box and take the only row left (Enter) */
async function pick(p, text) {
  /* a fresh focus selects the chosen name (PersonPicker onFocus): the typing replaces it */
  await p.$eval(PICKER, (el) => { el.blur(); el.focus() })
  await p.type(PICKER, text)
  await sleep(150)
  await p.keyboard.press('Enter')
  await sleep(400)
}

async function waitMember(p, want) {
  return p.waitForFunction((w) => {
    const s = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia._s.get('flow')
    return s && s.member === w && !s.mineLoading
  }, { timeout: 8000 }, want).then(() => true, () => false)
}

async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name), fullPage: false })
}

async function rightClickMenu(p) {
  await p.$eval(LINE, (el) => {
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window, clientX: Math.round(r.left + 20), clientY: Math.round(r.top + 10), button: 2, buttons: 2 }))
  })
  await p.waitForSelector('[data-testid=flow-menu]', { visible: true, timeout: 5000 }).catch(() => {})
  const ids = await p.$$eval('[data-testid=flow-menu] [role=menuitem]', (els) => els.map((e) => String(e.getAttribute('data-testid') || '').replace(/^flow-menu-/, ''))).catch(() => [])
  await p.keyboard.press('Escape')
  return ids
}

async function openFlow(p, path) {
  await p.goto(p.__base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=sidebar-tab-flow]', { timeout: NAV_TIMEOUT })
}

async function suite(p, size) {
  const tag = `${size.width}`
  const phone = size.width < 821

  /* the default is me */
  await openFlow(p, '/')
  await p.click('[data-testid=sidebar-tab-flow]')
  await p.waitForSelector(`${LIST} [data-testid=left-entry][data-msg-id="${MINE}"]`, { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector(PICKER, { visible: true, timeout: 5000 }).catch(() => {})
  let f = await facts(p)
  ok(`${tag}: the default is me: the box reads Me, my Flow, no ?flow=`, f.box === 'Me' && f.member === '' && f.query === null && f.ids.includes(MINE) && !f.note, f)
  const own = { dmChip: f.dmChip, unread: f.ownUnread, railDm: f.railDm }

  /* the list: persons, then agents */
  await p.click(PICKER)
  await sleep(200)
  await shot(p, `flow-member-list-${tag}.png`)
  f = await facts(p)
  const agentAt = f.options.indexOf(AGENT)
  const lastPerson = Math.max(...f.options.map((id, i) => (/^HUM-/.test(id) ? i : -1)))
  ok(`${tag}: every person and agent, me first, persons before agents, each group headed`,
    f.options[0] === 'HUM-1' && f.options.includes(PERSON) && f.options.includes('CLE-07@box-a') && agentAt > lastPerson && f.groups.join('|') === 'People|Agents', { options: f.options, groups: f.groups })
  await p.type(PICKER, 'grk')
  await sleep(150)
  f = await facts(p)
  ok(`${tag}: typing filters the list (grk -> ${AGENT})`, f.options.length === 1 && f.options[0] === AGENT, f.options)
  await p.keyboard.press('Escape')

  /* pick an agent */
  await pick(p, 'grk')
  const onAgent = await waitMember(p, AGENT)
  await p.waitForSelector(LINE, { visible: true, timeout: 5000 }).catch(() => {})
  f = await facts(p)
  ok(`${tag}: pick an agent: ?flow=${AGENT}, its line, the note`, onAgent && f.query === AGENT && f.box === AGENT && f.ids.length === 1 && f.ids[0] === AGENTS_LINE && f.note, f)
  ok(`${tag}: viewing another moves none of my numbers`, f.ownUnread === own.unread && f.railDm === own.railDm, { own, now: { unread: f.ownUnread, railDm: f.railDm } })
  if (!phone) {
    const ids = await rightClickMenu(p)
    ok(`${tag}: another member's line offers no Mark read`, ids.includes('open') && !ids.includes('read'), ids)
  }
  await shot(p, `flow-member-agent-${tag}.png`)

  /* pick a person */
  await pick(p, PERSON)
  const onPerson = await waitMember(p, PERSON)
  f = await facts(p)
  ok(`${tag}: pick a person: ?flow=${PERSON}, their Flow (no topic line, the releases everyone gets)`, onPerson && f.query === PERSON && f.box === PERSON && f.ids.length === 0 && f.releases > 0 && f.note, f)

  /* back to me: the parameter goes, my Flow and my numbers are as they were */
  await pick(p, 'Me')
  const onMe = await waitMember(p, '')
  await p.waitForSelector(`${LIST} [data-testid=left-entry][data-msg-id="${MINE}"]`, { visible: true, timeout: 5000 }).catch(() => {})
  f = await facts(p)
  ok(`${tag}: pick Me: no ?flow=, my Flow, my DM chip as before`, onMe && f.query === null && f.ids.includes(MINE) && f.dmChip === own.dmChip && !f.note, { ...f, own })

  /* the URL round trip: a pasted address opens that Flow */
  await openFlow(p, '/?flow=' + encodeURIComponent(AGENT))
  const pasted = await waitMember(p, AGENT)
  await p.waitForSelector(LINE, { visible: true, timeout: 8000 }).catch(() => {})
  f = await facts(p)
  ok(`${tag}: a pasted /?flow=${AGENT} opens the Flow tab on it`, pasted && f.box === AGENT && f.ids.length === 1 && f.ids[0] === AGENTS_LINE, f)
  if (!phone) await shot(p, `flow-member-url-${tag}.png`)
  await openFlow(p, '/?flow=not-a-member')
  await p.click('[data-testid=sidebar-tab-flow]')
  await p.waitForSelector(PICKER, { visible: true, timeout: 8000 }).catch(() => {})
  f = await facts(p)
  ok(`${tag}: a junk ?flow= is my own Flow`, f.member === '' && f.box === 'Me', f)
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const p = await browser.newPage()
    p.__base = server.base
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument(() => {
      try {
        localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
        localStorage.setItem('spool-theme', 'light')
        localStorage.removeItem('spool.flow-scope')
      } catch { /* about:blank */ }
    })
    await setPageViewport(p, size)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await suite(p, size)
    ok(`${size.width}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
