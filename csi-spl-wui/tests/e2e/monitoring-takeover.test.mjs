// SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4): "If now we have all of
// the data in the Monitoring tab ... then remove the Agents and the Boxes
// icons both from mobile and on desktop. If there is something to be added
// still, then add it first and then remove them."
//
// The step-1 table (c-002, t1 msg 990746ed) listed what the old Agents and
// Boxes sections had that Monitoring lacked. One check per such row, each
// reached from Monitoring alone:
//   - Agents: the agent's card (kind, liveness, box, last seen, Message -> DM)
//   - Boxes list: the filter, the count, the Online / Offline groups
//   - Box card: kind, liveness, id, last seen, seated people / agents counts
//     (each opening its list), Now, the resources (6), a resource's
//     statistics (`?r=`), the agents and people seated (each a link), the
//     admins' load band (operator workspace admins only, as on the old page:
//     the mock plays one with spool.mock.fleet_operator, else it is hidden)
// plus: the rail has no Agents and no Boxes item at 390x844 and 1400x900, and
// every old URL (/agents, /agents/<id@box>, /boxes, /boxes/<id>?r=..#..)
// lands on the matching Monitoring route.
//
// RED CONTROL: on origin/master before SPL-2075 the parity rows FAIL (no
// /monitoring/agents/<id> or /monitoring/boxes/<id> card, no filter), the
// rail draws Agents and Boxes, and the old URLs stay where they are.
//
// Screenshots of the rail for the owner post land in $SHOT_DIR when set.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-takeover
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

const AGENT = 'CLE-07@box-a'
const shown = (p, sel) => p.evaluate((s) => {
  const el = document.querySelector(s)
  if (!el) return false
  const r = el.getBoundingClientRect()
  return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none'
}, sel)
const textOf = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const count = (p, sel) => p.$$eval(sel, (els) => els.length)
const where = (p) => p.evaluate(() => ({ path: decodeURIComponent(location.pathname), search: location.search, hash: location.hash }))
const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)
/* wait for a selector; false (not a throw) when it never shows */
const has = (p, sel, timeout = 15000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
const at = (p, want, timeout = 15000) => p.waitForFunction((w) => decodeURIComponent(location.pathname) === w, { timeout }, want).then(() => true, () => false)
async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name + '.png') })
}

const server = await startServer()
const browser = await launch()
try {
  /* 1. the rail: no Agents, no Boxes; Monitoring is there */
  for (const [w, h] of [[1400, 900], [390, 844]]) {
    const vp = { width: w, height: h }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV_TIMEOUT })
    await sleep(500)
    const ids = await p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    ok(`${w}x${h}: the section bar has no Agents and no Boxes item`, !ids.includes('agents') && !ids.includes('boxes')
      && await count(p, '[data-testid=sidebar-tab-agents], [data-testid=sidebar-tab-boxes]') === 0, ids)
    ok(`${w}x${h}: Monitoring stays in the bar`, ids.includes('monitoring'), ids)
    await shot(p, `monitoring-takeover-bar-${w}`)
    await p.close()
  }

  /* 2. the old URLs land on Monitoring, ?r= and the hash kept */
  {
    const p = await browser.newPage()
    await p.setViewport({ width: 1400, height: 900 })
    for (const [from, to] of [
      ['/agents', '/monitoring/agents'],
      ['/agents/' + encodeURIComponent(AGENT), '/monitoring/agents/' + AGENT],
      ['/boxes', '/monitoring/boxes'],
      ['/boxes/box-desk', '/monitoring/boxes/box-desk'],
    ]) {
      await p.goto(server.base + from, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      ok(`${from} redirects to ${to}`, await at(p, to), await where(p))
    }
    await p.goto(server.base + '/boxes/box-desk?r=system#box-people', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await at(p, '/monitoring/boxes/box-desk')
    const w = await where(p)
    ok('/boxes/<id>?r=..#.. keeps the resource and the seat hash', w.path === '/monitoring/boxes/box-desk' && w.search === '?r=system' && w.hash === '#box-people', w)
    /* same permission as the old page: not the operator admin, no load band */
    await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await has(p, '[data-test=box-card]')
    await sleep(1500)
    ok('the load band stays hidden for a reader who is not the operator admin', await has(p, '[data-test=box-card]', 1000) && !(await shown(p, '[data-test=box-band]')))
    await p.close()
  }

  /* 3. parity, at desktop and phone width: each row reached from Monitoring */
  for (const [w, h] of [[1400, 900], [390, 844]]) {
    const tag = `${w}x${h}`
    const vp = { width: w, height: h }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    /* a signed-in workspace admin who is also the operator admin (fleet-load.test.mjs) */
    await p.evaluateOnNewDocument(() => {
      try {
        localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
        localStorage.setItem('spool.mock.fleet_operator', '1')
      } catch { /* private mode */ }
    })

    /* Agents: the row opens the card under Monitoring */
    await p.goto(server.base + '/monitoring/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    const agentRow = `[data-test=monitoring-agents] a[data-key="${AGENT}"]`
    if (await has(p, agentRow)) await p.click(agentRow)
    ok(`${tag}: agents - a row opens the agent's card in Monitoring`, await at(p, '/monitoring/agents/' + AGENT) && await has(p, '[data-test=agent-card]'), await where(p))
    ok(`${tag}: agents - kind`, /Claude/i.test(await textOf(p, '[data-test=agent-kind]')), await textOf(p, '[data-test=agent-kind]'))
    ok(`${tag}: agents - liveness`, (await textOf(p, '[data-test=agent-status]')).length > 0)
    ok(`${tag}: agents - the box it runs on`, await textOf(p, '[data-test=agent-box]') === 'box-a')
    ok(`${tag}: agents - last seen`, (await textOf(p, '[data-test=agent-last-seen]')).length > 0)
    if (await has(p, '[data-test=agent-message]', 5000)) await p.click('[data-test=agent-message]')
    ok(`${tag}: agents - Message opens the DM`, await at(p, '/dm/' + AGENT), await where(p))

    /* Boxes list: filter, count, groups */
    await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const list = await has(p, '[data-test=monitoring-boxes] [data-test=boxes-filter]')
    ok(`${tag}: boxes - the list has a filter`, list)
    const rows = await count(p, '[data-test=monitoring-boxes] [data-test=monitoring-box]')
    ok(`${tag}: boxes - the count says how many`, list && (await textOf(p, '[data-test=boxes-count]')).includes(String(rows)) && rows >= 2, { rows, count: await textOf(p, '[data-test=boxes-count]') })
    ok(`${tag}: boxes - grouped Online / Offline`, await count(p, '[data-test=boxes-group-online] [data-test=monitoring-box]') >= 1
      && await count(p, '[data-test=boxes-group-offline] [data-test=monitoring-box]') >= 1)
    if (list) {
      await p.type('[data-test=boxes-filter]', 'desk')
      await sleep(300)
      const left = await p.$$eval('[data-test=monitoring-boxes] [data-test=monitoring-box]', (els) => els.map((e) => e.getAttribute('data-box')))
      ok(`${tag}: boxes - the filter narrows the list`, left.length === 1 && left[0] === 'box-desk', left)
    } else ok(`${tag}: boxes - the filter narrows the list`, false)
    ok(`${tag}: boxes - no sideways scroll`, await noXScroll(p))

    /* Box card under Monitoring */
    const boxRow = '[data-test=monitoring-boxes] a[data-key="box-desk"]'
    if (await has(p, boxRow)) await p.click(boxRow)
    ok(`${tag}: box - a row opens the box's card in Monitoring`, await at(p, '/monitoring/boxes/box-desk') && await has(p, '[data-test=box-card]'), await where(p))
    ok(`${tag}: box - kind, liveness, id, last seen`, (await textOf(p, '[data-test=box-kind]')).length > 0 && (await textOf(p, '[data-test=box-status]')).length > 0
      && await textOf(p, '[data-test=box-id]') === 'box-desk' && (await textOf(p, '[data-test=box-last-hello]')).length > 0)
    ok(`${tag}: box - Now (the latest sample)`, await has(p, '[data-test=box-now-load]'))
    ok(`${tag}: box - the six resources`, await count(p, '[data-test^=box-resource-]:not([data-test^=box-resource-sum])') === 6)
    ok(`${tag}: box - the admins' load band`, await has(p, '[data-test=box-band]'))
    ok(`${tag}: box - the seated counts`, await has(p, '[data-test=box-people-count]') && await has(p, '[data-test=box-agents-count]'))
    if (await has(p, '[data-test=box-agents-count]', 3000)) await p.$eval('[data-test=box-agents-count]', (e) => e.click())
    await p.waitForFunction(() => location.hash === '#box-agents', { timeout: 15000 }).catch(() => null)
    ok(`${tag}: box - the agents count opens its list`, (await where(p)).hash === '#box-agents' && await has(p, '[data-test=box-agents-list]'))
    const agentHref = await p.$eval('[data-test=box-agents-list] [data-test=box-agent]', (e) => decodeURIComponent(e.getAttribute('href') || '')).catch(() => '')
    ok(`${tag}: box - a seated agent links to its Monitoring card`, /\/monitoring\/agents\/CLE-11@box-desk$/.test(agentHref), agentHref)
    /* the people seated: each a link to People (box-desk may seat nobody: then it says so) */
    const people = await count(p, '[data-test=box-people-list] [data-test=box-person]')
    const personHref = await p.$eval('[data-test=box-people-list] [data-test=box-person]', (e) => e.getAttribute('href') || '').catch(() => '')
    ok(`${tag}: box - the people seated, each linking to People`, await has(p, '[data-test=box-people-list]')
      && (people > 0 ? /\/people\//.test(personHref) : await has(p, '[data-test=box-no-people]', 3000)), { people, personHref })
    /* a resource's statistics, from a fresh card (no seat hash scrolled) */
    await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    if (await has(p, '[data-test=box-resource-system]')) await p.$eval('[data-test=box-resource-system]', (e) => e.click())
    await p.waitForFunction(() => location.search === '?r=system', { timeout: 15000 }).catch(() => null)
    ok(`${tag}: box - a resource opens its statistics (?r=)`, (await where(p)).search === '?r=system' && await has(p, '[data-test=box-stats-system]'), await where(p))
    ok(`${tag}: box - no sideways scroll`, await noXScroll(p))
    await shot(p, `monitoring-takeover-box-${w}`)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
