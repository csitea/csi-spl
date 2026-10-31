// Fleet load (rdb 0118, per-box bands rdb 0134 with their labels and aim SPL-3876, agent types rdb 0149, CI overflow rdb 0185) in a real browser, against
// the mock bundle. Also the same per-box band set from the Boxes view
// (/monitoring/boxes/<id>, t1 05e0fa03).
//
// An admin of the operator workspace sees the card, edits the low and high
// marks, reorders boxes, saves, reloads and sees the values. A workspace
// admin who is not that operator admin does not see the card or the nav
// entry (GET /v1/operator/fleet-load is 403 operator.workspaces). A band
// the hub refuses shows the 400 bad_setting detail.
//
// The mock plays a workspace admin. The operator admin is an opt-in
// (spool.mock.fleet_operator), so the other settings specs stay as they are.
//
// Run:
//   pnpm run test:e2e fleet-load
//   BASE_URL=<generated bundle> pnpm run test:e2e fleet-load
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { FLEET_BAD_SETTING, FLEET_OPERATOR_KEY, FLEET_READS_KEY, FLEET_STORE_KEY } from '../../src/utils/fleet-load.mjs'
import { MOCK_ME_KEY } from '../../src/utils/act-as-mock.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const value = (p, sel) => p.$eval(sel, (e) => e.value)
const order = (p) => p.$$eval('[data-test=tenant-fleet-box]', (els) => els.map((e) => e.getAttribute('data-box')))
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const setField = (p, sel, v) => p.$eval(sel, (el, next) => {
  el.value = next
  el.dispatchEvent(new Event('input', { bubbles: true }))
}, String(v))

async function signIn(p, base) {
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((op, store) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem(op)
    localStorage.removeItem(store)
  }, FLEET_OPERATOR_KEY, FLEET_STORE_KEY)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await signIn(p, server.base)

  await p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-testid=tenant-settings-open]')
  await p.waitForSelector('[data-test=tenant-settings-nav]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-settings-nav-members]', { visible: true, timeout: NAV_TIMEOUT })
  const nav = await p.$$eval('[data-test^=tenant-settings-nav-]', (els) => els.map((e) => e.getAttribute('data-test')))
  ok('1 a workspace admin does not see Fleet load in the nav', !nav.includes('tenant-settings-nav-fleet-load'), nav)

  await p.goto(server.base + '/tenant-settings/fleet-load', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-root][data-state=forbidden]', { timeout: NAV_TIMEOUT })
  ok('2 a workspace admin does not see the Fleet load card', !(await p.$('[data-test=tenant-settings-fleet-load]')))

  // SPL-4451 (row 3 of SPL-4422): a member /v1/view/me names no operator
  // admin (operator_admin false) is never read GET /v1/operator/fleet-load
  // on the pages that probed it into a 403 console line. The mock counts its
  // answers under FLEET_READS_KEY. CONTROL: the operator admin's same pages
  // read it, so the zeros are the gate, not a counter that never counts.
  const reads = async (path, sel) => {
    await p.evaluate((k) => localStorage.setItem(k, '0'), FLEET_READS_KEY)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(sel, { timeout: NAV_TIMEOUT })
    await new Promise((r) => setTimeout(r, 300))
    return p.evaluate((k) => Number(localStorage.getItem(k)) || 0, FLEET_READS_KEY)
  }
  const probePages = [
    ['/tenant-settings/members', '[data-test=tenant-settings-nav]'],
    ['/users', '[data-test=tenant-settings-nav]'],
    ['/monitoring/boxes', '[data-test=monitoring-boxes]'],
    ['/monitoring/boxes/box-desk', '[data-test=box-band-hidden]'],
  ]
  await p.evaluate((k) => localStorage.setItem(k, JSON.stringify({ role: 'admin', permissions: ['tenant.settings', 'members.invite', 'members.roles', 'topics.read'] })), MOCK_ME_KEY)
  const memberReads = {}
  for (const [path, sel] of probePages) memberReads[path] = await reads(path, sel)
  ok('2b a non-operator member reads GET /v1/operator/fleet-load 0 times on settings, users and boxes',
    Object.values(memberReads).every((n) => n === 0), memberReads)
  // SPL-4514 (round 2 of the console errors): the card itself, opened by its
  // URL, shows the forbidden state with no read either.
  const cardReads = await reads('/tenant-settings/fleet-load', '[data-test=tenant-fleet-root][data-state=forbidden]')
  ok('2f a non-operator member on /tenant-settings/fleet-load reads it 0 times and sees no card',
    cardReads === 0 && !(await p.$('[data-test=tenant-settings-fleet-load]')), cardReads)
  // GET /v1/tenant/box-stats is audit.read on the hub: this member lacks it,
  // so the Boxes list reads no stats and box-desk's disk line stays empty.
  const diskOf = async () => {
    await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=monitoring-box-facts][data-box=box-desk] [data-test=mbf-disk]', { timeout: NAV_TIMEOUT })
    await new Promise((r) => setTimeout(r, 300))
    return text(p, '[data-test=monitoring-box-facts][data-box=box-desk] [data-test=mbf-disk]')
  }
  const noAudit = await diskOf()
  ok('2d a member without audit.read reads no box stats on /monitoring/boxes (no disk line)', noAudit === '—', noAudit)
  await p.evaluate((k) => {
    const me = JSON.parse(localStorage.getItem(k))
    localStorage.setItem(k, JSON.stringify({ ...me, permissions: me.permissions.concat('audit.read') }))
  }, MOCK_ME_KEY)
  const withAudit = await diskOf()
  ok('2e CONTROL: with audit.read the same page reads them (box-desk shows its disk)', withAudit !== '—' && withAudit !== '', withAudit)
  await p.evaluate((op) => localStorage.setItem(op, '1'), FLEET_OPERATOR_KEY)
  const opReads = {}
  for (const [path, sel] of probePages.slice(0, 3)) opReads[path] = await reads(path, sel)
  opReads['/monitoring/boxes/box-desk'] = await reads('/monitoring/boxes/box-desk', '[data-test=box-band]')
  opReads['/tenant-settings/fleet-load'] = await reads('/tenant-settings/fleet-load', '[data-test=tenant-fleet-root][data-state=ready]')
  ok('2c CONTROL: the operator admin reads it on each of those pages', Object.values(opReads).every((n) => n >= 1), opReads)
  await p.evaluate((op, me) => { localStorage.removeItem(op); localStorage.removeItem(me) }, FLEET_OPERATOR_KEY, MOCK_ME_KEY)

  await p.evaluate((op) => localStorage.setItem(op, '1'), FLEET_OPERATOR_KEY)
  await p.goto(server.base + '/tenant-settings/members', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-settings-nav-fleet-load]', { visible: true, timeout: NAV_TIMEOUT })
  ok('3 an operator admin sees the Fleet load nav entry', true)
  await p.click('[data-test=tenant-settings-nav-fleet-load]')
  await p.waitForSelector('[data-test=tenant-settings-fleet-load]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-low]', { visible: true, timeout: NAV_TIMEOUT })
  const opened = { low: await value(p, '[data-test=tenant-fleet-low]'), high: await value(p, '[data-test=tenant-fleet-high]') }
  ok('4 the card opens on the defaults, 50 and 75', opened.low === '50' && opened.high === '75', opened)
  ok('4b the low mark says it is using the default', await p.$eval('[data-test=tenant-fleet-low]', (e) => e.getAttribute('data-using-default')) === '1')

  await setField(p, '[data-test=tenant-fleet-low]', '80')
  await setField(p, '[data-test=tenant-fleet-high]', '70')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-error]', { visible: true, timeout: NAV_TIMEOUT })
  const detail = await text(p, '[data-test=tenant-fleet-error]')
  ok('5 a refused band shows the hub bad_setting detail', detail === FLEET_BAD_SETTING, detail)

  await setField(p, '[data-test=tenant-fleet-low]', '40')
  await setField(p, '[data-test=tenant-fleet-high]', '80')
  await setField(p, '[data-test=tenant-fleet-input]', 'box-b')
  await p.click('[data-test=tenant-fleet-add]')
  await setField(p, '[data-test=tenant-fleet-input]', 'box-a')
  await p.click('[data-test=tenant-fleet-add]')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=tenant-fleet-box]').length === 2, { timeout: NAV_TIMEOUT })
  const before = await order(p)
  ok('6 two boxes are listed in the order they were added', before.join() === 'box-b,box-a', before)
  const ups = await p.$$('[data-test=tenant-fleet-up]')
  await ups[1].click()
  const moved = await order(p)
  ok('7 moving the second box up reorders the list', moved.join() === 'box-a,box-b', moved)
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  ok('8 save confirms', /saved/i.test(await text(p, '[data-test=tenant-fleet-notice]')))

  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-low]', { visible: true, timeout: NAV_TIMEOUT })
  const kept = {
    low: await value(p, '[data-test=tenant-fleet-low]'),
    high: await value(p, '[data-test=tenant-fleet-high]'),
    order: await order(p),
  }
  ok('9 a reload shows the saved band and the box order', kept.low === '40' && kept.high === '80' && kept.order.join() === 'box-a,box-b', kept)

  await p.click('[data-test=tenant-fleet-low-reset]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-low][data-using-default="1"]', { timeout: NAV_TIMEOUT })
  const reset = {
    low: await value(p, '[data-test=tenant-fleet-low]'),
    high: await value(p, '[data-test=tenant-fleet-high]'),
    order: await order(p),
  }
  ok('10 reset to default clears the low mark and keeps the rest', reset.low === '50' && reset.high === '80' && reset.order.join() === 'box-a,box-b', reset)

  // rdb 0134: a per-box band. Adding a box starts it on the fleet band; the
  // admin edits it, saves, and a reload shows it. A band with low >= high is
  // refused in the form. Reset clears every band.
  const bands = (q) => q.$$eval('[data-test=tenant-fleet-band]', (els) => els.map((e) => ({
    box: e.getAttribute('data-box'),
    low: e.querySelector('[data-test=tenant-fleet-band-low]').value,
    high: e.querySelector('[data-test=tenant-fleet-band-high]').value,
  })))
  ok('12 no per-box band at first', !!(await p.$('[data-test=tenant-fleet-bands-empty]')))
  await setField(p, '[data-test=tenant-fleet-band-input]', 'box-s')
  await p.click('[data-test=tenant-fleet-band-add]')
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-s]', { timeout: NAV_TIMEOUT })
  const added = await bands(p)
  ok('13 a new band starts on the fleet band in force (50..80)', JSON.stringify(added) === '[{"box":"box-s","low":"50","high":"80"}]', added)
  await setField(p, '[data-test=tenant-fleet-band-low]', '90')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-form-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('14 a band with low above high is refused in the form', true)
  await setField(p, '[data-test=tenant-fleet-band-low]', '60')
  await setField(p, '[data-test=tenant-fleet-band-high]', '90')
  await setField(p, '[data-test=tenant-fleet-band-input]', 'box-t')
  await p.click('[data-test=tenant-fleet-band-add]')
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-t]', { timeout: NAV_TIMEOUT })
  const tnkLow = (await p.$$('[data-test=tenant-fleet-band-low]'))[1]
  const tnkHigh = (await p.$$('[data-test=tenant-fleet-band-high]'))[1]
  for (const [el, v] of [[tnkLow, '20'], [tnkHigh, '40']]) {
    await el.evaluate((e, next) => { e.value = next; e.dispatchEvent(new Event('input', { bubbles: true })) }, v)
  }
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-t]', { timeout: NAV_TIMEOUT })
  const keptBands = await bands(p)
  ok('15 a reload shows both per-box bands; the fleet band is unchanged',
    JSON.stringify(keptBands) === '[{"box":"box-s","low":"60","high":"90"},{"box":"box-t","low":"20","high":"40"}]' &&
    (await value(p, '[data-test=tenant-fleet-high]')) === '80', keptBands)

  // SPL-3876 (owner HUM-10, t1 f456ecd5): every per-box box carries a visible
  // label naming it, and a band takes an aim, low <= aim <= high.
  const LABELS = ['Low %', 'Aim %', 'High %', 'Runner CPU cap %', 'CI runner CPUs']
  const bandLabels = (q) => q.$$eval('[data-test=tenant-fleet-band]', (els) => els.map((row) =>
    [...row.querySelectorAll('input[type=number]')].map((inp) => {
      const lab = inp.closest('label')
      const span = lab && lab.querySelector('[data-test=tenant-fleet-band-label]')
      const r = span ? span.getBoundingClientRect() : null
      const vis = !!(r && r.width > 0 && r.height > 0 && getComputedStyle(span).visibility !== 'hidden' && r.right <= document.documentElement.clientWidth + 1)
      return { text: span ? span.textContent.trim() : '', vis, above: !!(r && r.bottom <= inp.getBoundingClientRect().top + 1) }
    })))
  const labelsOk = (rows) => rows.length === 2 && rows.every((r) => JSON.stringify(r.map((x) => x.text)) === JSON.stringify(LABELS) && r.every((x) => x.vis && x.above))
  const desk = await bandLabels(p)
  ok('15b desktop: each per-box input has a visible label above it naming it (Low %, Aim %, High %, Runner CPU cap %, CI runner CPUs)', labelsOk(desk), desk[0])
  if (process.env.SHOT_DIR) {
    const { mkdirSync } = await import('node:fs')
    mkdirSync(process.env.SHOT_DIR, { recursive: true })
    const el = await p.$('[data-test=tenant-fleet-bands]')
    if (el) await el.screenshot({ path: `${process.env.SHOT_DIR}/fleet-load-bands-1400.png` })
  }
  await setField(p, '[data-test=tenant-fleet-band-aim]', '95')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-form-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('15c an aim above its band (95 on 60..90) is refused in the form', /aim/i.test(await text(p, '[data-test=tenant-fleet-form-error]')),
    await text(p, '[data-test=tenant-fleet-form-error]'))
  await setField(p, '[data-test=tenant-fleet-band-aim]', '80')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-s]', { timeout: NAV_TIMEOUT })
  const aims = await p.$$eval('[data-test=tenant-fleet-band-aim]', (els) => els.map((e) => e.value))
  ok('15d an aim of 80 on 60..90 saves and a reload shows it; box-t keeps none', JSON.stringify(aims) === '["80",""]', aims)

  await p.setViewport({ width: 390, height: 800 })
  await p.waitForSelector('[data-test=tenant-settings-fleet-load]', { visible: true, timeout: NAV_TIMEOUT })
  const phone = await p.$eval('[data-test=tenant-settings-fleet-load]', (e) => ({
    overflow: e.scrollWidth - e.clientWidth,
    wide: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  }))
  ok('11 phone: the card fits the width', phone.overflow <= 1 && phone.wide <= 1, phone)
  const phoneLabels = await bandLabels(p)
  ok('11b phone: each per-box input keeps its visible label above it, inside the width', labelsOk(phoneLabels), phoneLabels[0])
  if (process.env.SHOT_DIR) {
    const el = await p.$('[data-test=tenant-fleet-bands]')
    if (el) await el.screenshot({ path: `${process.env.SHOT_DIR}/fleet-load-bands-390.png` })
  }

  await p.setViewport({ width: 1400, height: 900 })
  await p.click('[data-test=tenant-fleet-bands-reset]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-bands-empty]', { timeout: NAV_TIMEOUT })
  ok('16 reset clears every per-box band', (await bands(p)).length === 0)

  // t1 05e0fa03: the same per-box band, set from the Boxes view (/monitoring/boxes/<id>, SPL-2075).
  // One hub row: box-desk 40..70 set there is listed on the Fleet load page, and
  // its reset removes it there. Only the operator admin sees and saves it.
  const openBox = async () => {
    await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=box-band]', { visible: true, timeout: NAV_TIMEOUT })
  }
  await openBox()
  const fleetLine = await text(p, '[data-test=box-band-fleet]')
  ok('17 /monitoring/boxes/box-desk shows the band block on the fleet band (50..80)',
    (await p.$eval('[data-test=box-band]', (e) => e.getAttribute('data-own'))) === '0' && /50\.\.80/.test(fleetLine) &&
    (await value(p, '[data-test=box-band-low]')) === '50' && (await value(p, '[data-test=box-band-high]')) === '80', fleetLine)
  ok('17b the block says who may edit it', /admin/i.test(await text(p, '[data-test=box-band-who]')))
  await setField(p, '[data-test=box-band-low]', '70')
  await setField(p, '[data-test=box-band-high]', '40')
  await p.click('[data-test=box-band-save]')
  await p.waitForSelector('[data-test=box-band-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('18 CONTROL: low >= high on the box is refused, nothing stored',
    (await p.$eval('[data-test=box-band]', (e) => e.getAttribute('data-own'))) === '0' &&
    !(await p.evaluate((k) => localStorage.getItem(k) || '', FLEET_STORE_KEY)).includes('box-desk'))
  await setField(p, '[data-test=box-band-low]', '40')
  await setField(p, '[data-test=box-band-high]', '70')
  await p.click('[data-test=box-band-save]')
  await p.waitForSelector('[data-test=box-band][data-own="1"]', { timeout: NAV_TIMEOUT })
  const ownLine = await text(p, '[data-test=box-band-own]')
  ok('19 saving box-desk 40..70 says it overrides the fleet band 50..80', /50\.\.80/.test(ownLine), ownLine)
  if (process.env.SHOT_DIR) {
    await p.setViewport({ width: 1440, height: 900 })
    await p.evaluate(() => localStorage.setItem('spool-theme', 'light'))
    await openBox()
    await p.screenshot({ path: `${process.env.SHOT_DIR}/box-band-1440-light.png` })
    await p.setViewport({ width: 1400, height: 900 })
  }

  await p.goto(server.base + '/tenant-settings/fleet-load', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-desk]', { timeout: NAV_TIMEOUT })
  const listed = { bands: await bands(p), high: await value(p, '[data-test=tenant-fleet-high]'), order: await order(p) }
  ok('20 the Fleet load page lists box-desk 40..70; the fleet band and the order are untouched',
    JSON.stringify(listed.bands) === '[{"box":"box-desk","low":"40","high":"70"}]' && listed.high === '80' && listed.order.join() === 'box-a,box-b', listed)

  await openBox()
  await p.click('[data-test=box-band-reset]')
  await p.waitForSelector('[data-test=box-band][data-own="0"]', { timeout: NAV_TIMEOUT })
  await p.goto(server.base + '/tenant-settings/fleet-load', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-bands-empty]', { timeout: NAV_TIMEOUT })
  ok('21 reset on the box removes it from the Fleet load page', (await bands(p)).length === 0)

  // rdb 0152 (t1 338e5258): runner_cpu_pct. A box's own cap set by the CLI
  // survives a band save on the Boxes view (the hub replaces the whole map);
  // the Fleet load page shows and edits the fleet cap and the box's cap.
  const storedRow = () => p.evaluate((k) => JSON.parse(localStorage.getItem(k) || '{}'), FLEET_STORE_KEY)
  await p.evaluate((key) => {
    const row = JSON.parse(localStorage.getItem(key) || '{}')
    row.boxes = { 'box-desk': { low: 40, high: 70, runner_cpu_pct: 60 } }
    localStorage.setItem(key, JSON.stringify(row))
  }, FLEET_STORE_KEY)
  await openBox()
  ok('21b /monitoring/boxes/box-desk shows its own runner CPU cap', /60 %/.test(await text(p, '[data-test=box-band-cpu]')), await text(p, '[data-test=box-band-cpu]'))
  await setField(p, '[data-test=box-band-low]', '45')
  await p.click('[data-test=box-band-save]')
  await p.waitForSelector('[data-test=box-band-notice]', { visible: true, timeout: NAV_TIMEOUT })
  const afterBand = (await storedRow()).boxes
  ok('21c saving the box band keeps its runner_cpu_pct', JSON.stringify(afterBand) === '{"box-desk":{"low":45,"high":70,"runner_cpu_pct":60}}', afterBand)

  await p.goto(server.base + '/tenant-settings/fleet-load', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-desk]', { timeout: NAV_TIMEOUT })
  const cpuOpen = { fleet: await value(p, '[data-test=tenant-fleet-cpu]'), box: await value(p, '[data-test=tenant-fleet-band-cpu]') }
  ok('21d the page shows the fleet cap (default 80) and box-desk\'s own 60',
    cpuOpen.fleet === '80' && cpuOpen.box === '60' && (await p.$eval('[data-test=tenant-fleet-cpu]', (e) => e.getAttribute('data-using-default'))) === '1', cpuOpen)
  await setField(p, '[data-test=tenant-fleet-cpu]', '0')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-form-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('21e CONTROL: a fleet cap of 0 is refused in the form, nothing stored', (await storedRow()).runner_cpu_pct == null)
  await setField(p, '[data-test=tenant-fleet-cpu]', '70')
  await setField(p, '[data-test=tenant-fleet-band-high]', '75')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-desk]', { timeout: NAV_TIMEOUT })
  const cpuKept = { fleet: await value(p, '[data-test=tenant-fleet-cpu]'), row: await storedRow() }
  ok('21f the fleet cap 70 and box-desk\'s band edit survive a reload; its cap 60 is kept',
    cpuKept.fleet === '70' && cpuKept.row.runner_cpu_pct === 70 && JSON.stringify(cpuKept.row.boxes) === '{"box-desk":{"low":45,"high":75,"runner_cpu_pct":60}}', cpuKept)
  await setField(p, '[data-test=tenant-fleet-band-cpu]', '')
  await p.click('[data-test=tenant-fleet-cpu-reset]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  const cleared = await storedRow()
  ok('21g clearing the box cap and resetting the fleet cap store neither', cleared.runner_cpu_pct == null &&
    JSON.stringify(cleared.boxes) === '{"box-desk":{"low":45,"high":75}}', cleared)
  await p.$$eval('[data-test=tenant-fleet-band-remove]', (els) => els.forEach((e) => e.click()))
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForFunction((k) => !(localStorage.getItem(k) || '').includes('box-desk'), { timeout: NAV_TIMEOUT }, FLEET_STORE_KEY)

  // rdb 0185 (t1 f67e3656): the CI overflow switch (default on) and the CI
  // runner cores (default 0 = the cnf share), fleet-wide and per box.
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-overflow]', { visible: true, timeout: NAV_TIMEOUT })
  const ovOpen = {
    on: await p.$eval('[data-test=tenant-fleet-overflow]', (e) => e.checked),
    onDefault: await p.$eval('[data-test=tenant-fleet-overflow]', (e) => e.getAttribute('data-using-default')),
    cpus: await value(p, '[data-test=tenant-fleet-cpus]'),
  }
  ok('31 CI overflow opens on and runner CPUs on 0, both the default', ovOpen.on && ovOpen.onDefault === '1' && ovOpen.cpus === '0', ovOpen)
  await setField(p, '[data-test=tenant-fleet-cpus]', '300')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-form-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('32 CONTROL: 300 runner CPUs is refused in the form, nothing stored', (await storedRow()).runner_cpus == null)
  await p.click('[data-test=tenant-fleet-overflow]')
  await setField(p, '[data-test=tenant-fleet-cpus]', '12')
  await setField(p, '[data-test=tenant-fleet-band-input]', 'box-ci')
  await p.click('[data-test=tenant-fleet-band-add]')
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-ci] [data-test=tenant-fleet-band-cpus]', { timeout: NAV_TIMEOUT })
  await setField(p, '[data-test=tenant-fleet-band][data-box=box-ci] [data-test=tenant-fleet-band-cpus]', '4')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-band][data-box=box-ci]', { timeout: NAV_TIMEOUT })
  const ovKept = {
    on: await p.$eval('[data-test=tenant-fleet-overflow]', (e) => e.checked),
    cpus: await value(p, '[data-test=tenant-fleet-cpus]'),
    box: await value(p, '[data-test=tenant-fleet-band][data-box=box-ci] [data-test=tenant-fleet-band-cpus]'),
    row: await storedRow(),
  }
  ok('33 overflow off, 12 runner CPUs and box-ci\'s own 4 survive a reload',
    !ovKept.on && ovKept.cpus === '12' && ovKept.box === '4' && ovKept.row.ci_overflow === false && ovKept.row.runner_cpus === 12 &&
    ovKept.row.boxes['box-ci'].runner_cpus === 4, ovKept)
  await p.click('[data-test=tenant-fleet-overflow-reset]')
  await p.click('[data-test=tenant-fleet-cpus-reset]')
  await p.click('[data-test=tenant-fleet-band][data-box=box-ci] [data-test=tenant-fleet-band-remove]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForFunction((k) => !(localStorage.getItem(k) || '').includes('box-ci'), { timeout: NAV_TIMEOUT }, FLEET_STORE_KEY)
  const ovReset = await storedRow()
  ok('34 reset stores neither: overflow back on, runner CPUs back to 0', ovReset.ci_overflow == null && ovReset.runner_cpus == null &&
    (await p.$eval('[data-test=tenant-fleet-overflow]', (e) => e.checked)), ovReset)

  await openBox()
  await p.evaluate((op) => localStorage.removeItem(op), FLEET_OPERATOR_KEY)
  await setField(p, '[data-test=box-band-low]', '40')
  await setField(p, '[data-test=box-band-high]', '70')
  await p.click('[data-test=box-band-save]')
  await p.waitForSelector('[data-test=box-band-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('22 CONTROL: a non-admin cannot save (the hub refuses, nothing stored)',
    (await p.$eval('[data-test=box-band]', (e) => e.getAttribute('data-own'))) === '0' &&
    !(await p.evaluate((k) => localStorage.getItem(k) || '', FLEET_STORE_KEY)).includes('box-desk'))
  await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=box-band-hidden]', { timeout: NAV_TIMEOUT })
  ok('23 a non-admin does not see the band block', !(await p.$('[data-test=box-band]')))

  // rdb 0149 (t1 41fa1f2d): one on/off per agent type, and a box's pause.
  const kindsOn = (q) => q.$$eval('[data-test=tenant-fleet-kind]', (els) => els.map((e) => `${e.getAttribute('data-kind')}=${e.getAttribute('data-on')}`).join(' '))
  const toggle = (q, k) => q.click(`[data-test=tenant-fleet-kind][data-kind=${k}] [data-test=tenant-fleet-kind-toggle]`)
  await p.evaluate((op, key) => {
    localStorage.setItem(op, '1')
    const row = JSON.parse(localStorage.getItem(key) || '{}')
    row.agent_kinds_paused = { agy: { until: '2099-01-01T00:00:00Z', reason: 'usage limit', box: 'box-t' } }
    localStorage.setItem(key, JSON.stringify(row))
  }, FLEET_OPERATOR_KEY, FLEET_STORE_KEY)
  await p.goto(server.base + '/tenant-settings/fleet-load', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-kinds]', { visible: true, timeout: NAV_TIMEOUT })
  ok('24 every agent type is on at first', (await kindsOn(p)) === 'claude=1 grok=1 agy=1 qwen=1 mistral=1', await kindsOn(p))
  const pausedLine = await text(p, '[data-test=tenant-fleet-kind][data-kind=agy] [data-test=tenant-fleet-kind-paused]')
  ok('25 a box\'s pause shows "paused: usage limit until <time>" on agy only',
    /^Paused: usage limit until 209[89]-\d\d-\d\d \d\d:\d\d$/.test(pausedLine) && (await p.$$('[data-test=tenant-fleet-kind-paused]')).length === 1, pausedLine)
  await toggle(p, 'grok')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-kind][data-kind=grok][data-on="0"]', { timeout: NAV_TIMEOUT })
  ok('26 grok switched off survives a reload; the others stay on and the band is untouched',
    (await kindsOn(p)) === 'claude=1 grok=0 agy=1 qwen=1 mistral=1' && (await value(p, '[data-test=tenant-fleet-high]')) === '80', await kindsOn(p))
  await toggle(p, 'claude')
  await toggle(p, 'agy')
  await toggle(p, 'qwen')
  const lastOn = await p.$eval('[data-test=tenant-fleet-kind][data-kind=mistral] [data-test=tenant-fleet-kind-toggle]', (e) => e.disabled)
  ok('27 CONTROL: the last type on (mistral, spec 110) cannot be switched off', lastOn && (await kindsOn(p)) === 'claude=0 grok=0 agy=0 qwen=0 mistral=1', await kindsOn(p))
  await toggle(p, 'claude')
  await toggle(p, 'agy')
  await toggle(p, 'qwen')
  await p.click('[data-test=tenant-fleet-kind][data-kind=agy] [data-test=tenant-fleet-kind-resume]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-kinds]', { visible: true, timeout: NAV_TIMEOUT })
  ok('28 resume lifts the agy pause; grok stays off',
    !(await p.$('[data-test=tenant-fleet-kind-paused]')) && (await kindsOn(p)) === 'claude=1 grok=0 agy=1 qwen=1 mistral=1', await kindsOn(p))
  await p.focus('[data-test=tenant-fleet-kind][data-kind=grok] [data-test=tenant-fleet-kind-toggle]')
  await p.keyboard.press('Space')
  await p.waitForSelector('[data-test=tenant-fleet-kind][data-kind=grok][data-on="1"]', { timeout: NAV_TIMEOUT })
  ok('29 the switch works from the keyboard', true)
  await p.setViewport({ width: 390, height: 800 })
  const kindsPhone = await p.$eval('[data-test=tenant-fleet-kinds]', (e) => e.scrollWidth - e.clientWidth)
  ok('30 phone: the agent types fit the width', kindsPhone <= 1, kindsPhone)
  await p.setViewport({ width: 1400, height: 900 })

  // SPL-2031 (t1 dbf2f39b, d8f64bc3 / d4cdda5f / 22472356 / 6cab186b):
  // Monitoring -> Boxes shows each box's system facts and the admins'
  // allocation, read-only, every set value "(planned)"; desktop and phone.
  await p.evaluate((op, key) => {
    localStorage.setItem(op, '1')
    localStorage.setItem(key, JSON.stringify({ low: 40, high: 80, box_order: ['box-desk', 'box-a'], boxes: { 'box-desk': { low: 20, high: 60 } }, agent_kinds_off: ['qwen'] }))
  }, FLEET_OPERATOR_KEY, FLEET_STORE_KEY)
  /* SPL-2075: the boxes list's search filter (from the old Boxes section) reads, never writes */
  const editables = (q, sel) => q.$$eval(sel + ' input:not([data-test=boxes-filter][type=search]), ' + sel + ' select, ' + sel + ' textarea, ' + sel + ' button', (els) => els.length)
  const unmarked = (q) => q.$$eval('[data-test=alloc-value]', (els) => els.filter((e) => !/^\(.+\)$/.test(e.querySelector('[data-test=alloc-planned]')?.textContent.trim() || '')).map((e) => e.getAttribute('data-key')))
  const boxFacts = '[data-test=monitoring-box-facts][data-box=box-desk]'
  for (const [w, h] of [[1400, 900], [390, 844]]) {
    const tag = `${w}x${h}`
    await p.setViewport({ width: w, height: h })
    await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=monitoring-allocation]', { visible: true, timeout: NAV_TIMEOUT })
    await p.waitForSelector(boxFacts + ' [data-test=mbf-allocation]', { visible: true, timeout: NAV_TIMEOUT })
    ok(`31 ${tag}: the Boxes tab shows box-desk's OS, hardware, load and run-times`,
      /Debian GNU\/Linux 13/.test(await text(p, boxFacts + ' [data-test=mbf-os]'))
      && /Example CPU/.test(await text(p, boxFacts + ' [data-test=mbf-hardware]'))
      && /0\.42/.test(await text(p, boxFacts + ' [data-test=mbf-load]'))
      && /node/.test(await text(p, boxFacts + ' [data-test=mbf-runtimes]')))
    const fleetBand = await text(p, '[data-test=alloc-fleet-rows] [data-test=alloc-value][data-key=fleet-band]')
    ok(`32 ${tag}: the allocation block reads the fleet band, the order, the bands, the types, the split`,
      /^40\.\.80 % of cores\s*\(planned\)$/.test(fleetBand)
      && (await p.$$eval('[data-test=alloc-order-rows] [data-test=alloc-value]', (els) => els.map((e) => e.textContent.replace(/\(planned\)/, '').trim()))).join(',') === 'box-desk,box-a'
      && /20\.\.60/.test(await text(p, '[data-test=alloc-band-rows] [data-key=band-box-desk]'))
      && /^Off/.test(await text(p, '[data-test=alloc-kind-rows] [data-key=kind-qwen]'))
      && (await p.$$('[data-test=alloc-split-rows] [data-test=alloc-value]')).length === 5, fleetBand)
    const own = await text(p, boxFacts + ' [data-test=mbf-allocation-rows] [data-key=box-band]')
    const place = await text(p, boxFacts + ' [data-test=mbf-allocation-rows] [data-key=box-place]')
    ok(`33 ${tag}: box-desk shows its own band and its place in the order`, /20\.\.60/.test(own) && /^1 of 2/.test(place), { own, place })
    ok(`34 ${tag}: no input, select, textarea or button in the allocation or the facts`,
      (await editables(p, '[data-test=monitoring-allocation]')) === 0 && (await editables(p, '[data-test=monitoring-boxes]')) === 0)
    const values = (await p.$$('[data-test=alloc-value]')).length
    ok(`35 ${tag}: every set value carries "(planned)"`, values >= 20 && (await unmarked(p)).length === 0, { values, unmarked: await unmarked(p) })
    ok(`36 ${tag}: the edit links go to Workspace settings`,
      (await p.$eval('[data-test=alloc-edit-fleet]', (e) => e.getAttribute('href'))).endsWith('/tenant-settings/fleet-load')
      && (await p.$eval('[data-test=alloc-edit-split]', (e) => e.getAttribute('href'))).endsWith('/tenant-settings/split'))
    ok(`37 ${tag}: no sideways scroll`, await p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1))
    if (process.env.SHOT_DIR) {
      const { mkdirSync } = await import('node:fs')
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-boxes-allocation-${w}.png`, fullPage: true })
      const card = await p.$('[data-test=monitoring-box][data-box=box-desk]')
      if (card) await card.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-boxes-facts-${w}.png` })
    }
  }
  await p.evaluate((op) => localStorage.removeItem(op), FLEET_OPERATOR_KEY)
  await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(boxFacts + ' [data-test=mbf-os]', { visible: true, timeout: NAV_TIMEOUT })
  ok('38 not the operator admin: the facts show, no allocation (owner decision A)',
    !(await p.$('[data-test=monitoring-allocation]')) && !(await p.$('[data-test=mbf-allocation]')))
  await p.setViewport({ width: 1400, height: 900 })

  ok('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const bad = results.filter((r) => !r.ok)
if (bad.length) {
  console.error(`\n${bad.length} failure(s)`)
  process.exit(1)
}
console.log(`\nAll ${results.length} fleet-load checks passed.`)
