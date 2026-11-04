// SPL-2083: Monitoring -> Boxes rows must left-align in one column on phone.
// At 412x915 (phone), every row's icon left edge must be equal (max-min <= 1 px),
// and the name must start at the same x on every row. No horizontal scroll.
// SPL-2228: the mock tenant's names are all short (a, b, desk), and a short
// name sits in the same place centred or not; the owner's screenshot has
// `ci-join-<run>-prd` rows. The test seats two long-named boxes in the roster
// store, so a centred row shows as an icon x apart from the others, and the
// longest name must stay inside its row (wraps, never pushes the icon out).
//
// Spec 153 3.18 (SPL-4786, C85-C87): the operator's Agents and Boxes also
// list the boxes and agents the other workspaces have on their own (the
// mock's Customer Space, box mac-01 with CLE-07), one group per workspace;
// CLE-07@box-a and CLE-07@mac-01 are two rows, box-a once with its "also
// seated in" line; the foreign agent's card names its workspace and offers
// no lanes and no Message; a non-operator sees none of it.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-boxes-align
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The owner's long box ids (one realistic, one longer than a phone row) */
const LONG_BOXES = ['ci-join-38522365746-prd', 'ci-join-38522365746-prd-runner-with-a-much-longer-suffix-0123456789']

/** Seat one agent on each long-named box in the roster store, online. */
const seatLongBoxes = (p) => p.evaluate((ids) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const r = pinia.state.value.roster
  ids.forEach((id, i) => {
    r.roster = { ...r.roster, [id]: ['CLE-9' + i] }
    r.boxes = { ...r.boxes, [id]: { online: true, last_hello_at: '2026-09-18T10:00:00Z', seated_at: {} } }
    r.online = [...r.online, 'CLE-9' + i + '@' + id]
  })
}, LONG_BOXES)

/** Icon left edge and name start x for every visible row */
const rowPositions = async (p) => {
  return p.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('[data-test=monitoring-box] .nav-row > .nav-item'))
    return rows.map((row) => {
      const icon = row.querySelector('svg')
      const label = row.querySelector('.label')
      if (!icon || !label) return null
      const iconRect = icon.getBoundingClientRect()
      const labelRect = label.getBoundingClientRect()
      const rowRect = row.getBoundingClientRect()
      return {
        box: row.getAttribute('data-key'),
        iconLeft: Math.round(iconRect.left),
        labelLeft: Math.round(labelRect.left),
        labelRight: Math.round(labelRect.right),
        rowRight: Math.round(rowRect.right),
      }
    }).filter(Boolean)
  })
}

const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)

async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name + '.png') })
}

/** Spec 153 3.18: the operator's cross-workspace rows (C85-C87), desktop. */
async function crossWorkspace() {
  console.log('-- 1440x900 operator: other workspaces\' own boxes and agents')
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message || e)))
  await setPageViewport(p, { width: 1440, height: 900 })
  await p.goto(server.base + '/monitoring/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.fleet_operator', '1'))
  await p.goto(server.base + '/monitoring/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=monitoring-agents-workspace]', { timeout: 15000 }).catch(() => null)
  const agents = await p.evaluate(() => Array.from(document.querySelectorAll('[data-test=monitoring-agents] a.nav-item')).map((a) => (a.getAttribute('data-key') || '') + '|' + (a.getAttribute('data-workspace') || '')))
  const head = await p.$eval('[data-test=monitoring-agents-workspace] .agents-ws__head', (x) => x.textContent || '').catch(() => '')
  ok('C85 Agents: CLE-07@box-a and CLE-07@mac-01 are two rows, the second under Customer Space',
    agents.filter((k) => k === 'CLE-07@box-a|').length === 1 && agents.filter((k) => k === 'CLE-07@mac-01|tcust01').length === 1 && head.includes('Customer Space'), { agents, head })

  await p.click('[data-test=monitoring-agents-workspace] a.nav-item[data-key="CLE-07@mac-01"]')
  await p.waitForSelector('[data-test=agent-foreign-note]', { timeout: 15000 }).catch(() => null)
  const card = await p.evaluate(() => ({
    url: location.pathname + location.search,
    ws: document.querySelector('[data-test=agent-workspace]')?.textContent || '',
    note: document.querySelector('[data-test=agent-foreign-note]')?.textContent || '',
    tabs: Boolean(document.querySelector('[data-test=agent-tabs]')),
    message: Boolean(document.querySelector('[data-test=agent-message]')),
    selected: document.querySelector('[data-test=monitoring-agents] a.nav-item.active')?.getAttribute('data-workspace') || '',
  }))
  ok('C86 the foreign card names its workspace, says so, no tabs, no Message',
    card.url.includes('ws=tcust01') && card.ws === 'Customer Space' && card.note.includes('Customer Space') && !card.tabs && !card.message && card.selected === 'tcust01', card)
  await p.goto(server.base + '/monitoring/agents/' + encodeURIComponent('CLE-07@mac-01') + '?ws=tnosuch', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=agent-foreign-missing]', { timeout: 15000 }).catch(() => null)
  ok('C86 an unknown workspace: one line, no card', Boolean(await p.$('[data-test=agent-foreign-missing]')) && !(await p.$('[data-test=agent-foreign-note]')))

  await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=boxes-group-workspace]', { timeout: 15000 }).catch(() => null)
  const boxes = await p.evaluate(() => Array.from(document.querySelectorAll('[data-test=monitoring-box]')).map((b) => (b.getAttribute('data-box') || '') + '|' + (b.getAttribute('data-workspace') || '')))
  const seated = await p.$eval('[data-box="box-a"] [data-test=boxes-also-seated]', (x) => ({ text: x.textContent || '', title: x.getAttribute('title') || '' })).catch(() => null)
  ok('C85 Boxes: mac-01 once under Customer Space, box-a once with its also-seated line',
    boxes.filter((k) => k === 'mac-01|tcust01').length === 1 && boxes.filter((k) => k.startsWith('box-a|')).length === 1 && Boolean(seated && seated.text.includes('1') && seated.title === 'Customer Space'), { boxes, seated })
  await p.type('[data-test=boxes-filter]', 'customer')
  await sleep(300)
  const filtered = await p.evaluate(() => Array.from(document.querySelectorAll('[data-test=monitoring-box]')).map((b) => b.getAttribute('data-box')))
  ok('C85 the Boxes filter matches the workspace name', filtered.length === 1 && filtered[0] === 'mac-01', { filtered })

  await p.evaluate(() => localStorage.removeItem('spool.mock.fleet_operator'))
  await p.goto(server.base + '/monitoring/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=monitoring-agents] a.nav-item', { timeout: 15000 }).catch(() => null)
  await sleep(500)
  ok('C87 a non-operator sees no other workspace', !(await p.$('[data-test=monitoring-agents-workspace]')))
  ok('C85-C87 no page errors', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 412x915 ${theme} (phone)`)
    const vp = { width: 412, height: 915 }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=monitoring-box]', { timeout: NAV_TIMEOUT })
    await seatLongBoxes(p)
    await p.waitForFunction((n) => document.querySelectorAll('[data-test=monitoring-box]').length >= n, { timeout: NAV_TIMEOUT }, 2 + LONG_BOXES.length)
    await sleep(600) // Wait for layout

    const positions = await rowPositions(p)
    const iconLefts = positions.map((pos) => pos.iconLeft)
    const labelLefts = positions.map((pos) => pos.labelLeft)
    const iconMin = Math.min(...iconLefts)
    const iconMax = Math.max(...iconLefts)
    const labelMin = Math.min(...labelLefts)
    const labelMax = Math.max(...labelLefts)

    ok(`${theme}: at least 4 rows visible, the long names among them`, positions.length >= 4 && LONG_BOXES.every((id) => positions.some((pos) => pos.box === id)), { rows: positions.length })
    const shortIcon = positions.filter((pos) => !LONG_BOXES.includes(pos.box)).map((pos) => pos.iconLeft)
    const longIcon = positions.filter((pos) => LONG_BOXES.includes(pos.box)).map((pos) => pos.iconLeft)
    ok(`${theme}: a long name's icon starts at the short rows' icon x`, longIcon.length > 0 && longIcon.every((x) => shortIcon.every((y) => Math.abs(x - y) <= 1)), { shortIcon, longIcon })
    const longest = positions.find((pos) => pos.box === LONG_BOXES[1])
    ok(`${theme}: the longest name stays inside its row`, Boolean(longest) && longest.labelRight <= longest.rowRight + 1, longest)
    ok(`${theme}: every row's icon left edge is equal (max-min <= 1 px)`, (iconMax - iconMin) <= 1, { iconMin, iconMax })
    ok(`${theme}: every row's name starts at the same x`, (labelMax - labelMin) <= 1, { labelMin, labelMax })
    ok(`${theme}: no horizontal page scroll`, await noXScroll(p))
    await shot(p, `monitoring-boxes-align-412-${theme}`)
    await p.close()
  }
  await crossWorkspace()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
