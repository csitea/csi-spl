// Fleet load (rdb 0118, per-box bands rdb 0134, agent types rdb 0149) in a real browser, against
// the mock bundle. Also the same per-box band set from the Boxes view
// (/boxes/<id>, t1 05e0fa03).
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
import { FLEET_BAD_SETTING, FLEET_OPERATOR_KEY, FLEET_STORE_KEY } from '../../src/utils/fleet-load.mjs'

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

  await p.setViewport({ width: 390, height: 800 })
  await p.waitForSelector('[data-test=tenant-settings-fleet-load]', { visible: true, timeout: NAV_TIMEOUT })
  const phone = await p.$eval('[data-test=tenant-settings-fleet-load]', (e) => ({
    overflow: e.scrollWidth - e.clientWidth,
    wide: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  }))
  ok('11 phone: the card fits the width', phone.overflow <= 1 && phone.wide <= 1, phone)

  await p.setViewport({ width: 1400, height: 900 })
  await p.click('[data-test=tenant-fleet-bands-reset]')
  await p.click('[data-test=tenant-fleet-save]')
  await p.waitForSelector('[data-test=tenant-fleet-notice]', { visible: true, timeout: NAV_TIMEOUT })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-fleet-bands-empty]', { timeout: NAV_TIMEOUT })
  ok('16 reset clears every per-box band', (await bands(p)).length === 0)

  // t1 05e0fa03: the same per-box band, set from the Boxes view (/boxes/<id>).
  // One hub row: box-desk 40..70 set there is listed on the Fleet load page, and
  // its reset removes it there. Only the operator admin sees and saves it.
  const openBox = async () => {
    await p.goto(server.base + '/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=box-band]', { visible: true, timeout: NAV_TIMEOUT })
  }
  await openBox()
  const fleetLine = await text(p, '[data-test=box-band-fleet]')
  ok('17 /boxes/box-desk shows the band block on the fleet band (50..80)',
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
  ok('21b /boxes/box-desk shows its own runner CPU cap', /60 %/.test(await text(p, '[data-test=box-band-cpu]')), await text(p, '[data-test=box-band-cpu]'))
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

  await openBox()
  await p.evaluate((op) => localStorage.removeItem(op), FLEET_OPERATOR_KEY)
  await setField(p, '[data-test=box-band-low]', '40')
  await setField(p, '[data-test=box-band-high]', '70')
  await p.click('[data-test=box-band-save]')
  await p.waitForSelector('[data-test=box-band-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('22 CONTROL: a non-admin cannot save (the hub refuses, nothing stored)',
    (await p.$eval('[data-test=box-band]', (e) => e.getAttribute('data-own'))) === '0' &&
    !(await p.evaluate((k) => localStorage.getItem(k) || '', FLEET_STORE_KEY)).includes('box-desk'))
  await p.goto(server.base + '/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
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
