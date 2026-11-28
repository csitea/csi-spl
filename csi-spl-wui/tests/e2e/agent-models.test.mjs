// spec 184 row W1 (SPL-6725): Tenant settings -> Vendor split -> Default
// model per vendor and task kind, proved in a REAL browser against the mock
// bundle (the mock plays an admin, tenant-settings-mock.mjs).
//
// The table shows one row per kind (Every kind first) and one text cell per
// vendor; each cell offers its vendor's latest box reading as choices, and
// the reading line names its box, time and CLI version. A model with a space
// marks its cell, names the rule and keeps Save off. A typed model saves,
// a kind cell shows its vendor's Every kind model as its fallback, and the
// saved cells read back after a section change. The table scrolls inside its
// card: the page never scrolls sideways, at 1400 px or on a phone.
//
// Plant the defect and watch it go red (Save is forced on with "a b" in a
// cell: the click saves nothing, so steps 5 and 6 go red; seen 2026-11-28):
//   PROVE_RED=space-save node tests/e2e/agent-models.test.mjs
//
// Run:
//   pnpm run test:e2e agent-models
//   BASE_URL=<generated bundle> pnpm run test:e2e agent-models
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const value = (p, sel) => p.$eval(sel, (e) => e.value).catch(() => null)
const saveOff = (p) => p.$eval('[data-test=agent-models-save]', (e) => e.disabled)
const pageFits = (p) => p.evaluate(() => ({ vw: innerWidth, sw: document.documentElement.scrollWidth }))
const en = createRequire(import.meta.url)('../../i18n/locales/en.json').tenant_settings

/** Replace a cell's text the way a person does: select all, delete, type, so v-model sees each key. */
async function typeIn(p, sel, s) {
  await p.focus(sel)
  await p.$eval(sel, (e) => e.select())
  await p.keyboard.press('Backspace')
  if (s) await p.type(sel, s)
}

/* spec 061 FR-004: pin the browser's agent-id clock before LEGACY_ID_UNTIL */
const pinAgentIdClock = (p) => p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })

const cell = (kind, v) => `[data-test=agent-model-${kind}-${v}]`

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await pinAgentIdClock(p)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.goto(server.base + '/tenant-settings/split', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(cell('all', 'claude'), { visible: true, timeout: NAV_TIMEOUT })

  // 1. the table: Every kind then the seven kinds, six vendor cells each, all empty = CLI default
  const shape = await p.evaluate(() => {
    const rows = [...document.querySelectorAll('[data-test=agent-models] tbody tr')]
    return { rows: rows.map((r) => r.getAttribute('data-test').slice(12)), cells: rows.map((r) => r.querySelectorAll('input').length),
      filled: [...document.querySelectorAll('[data-test=agent-models] tbody input')].filter((i) => i.value !== '').length }
  })
  const ph = await p.$eval(cell('tests', 'grok'), (e) => e.placeholder)
  ok('1 eight rows (Every kind first), six vendor cells each, all empty = CLI default',
    shape.rows.join() === 'all,specs_and_docs,tests,simple_coding,complex_coding,i18n,secret,orchestration' && shape.cells.every((n) => n === 6) && shape.filled === 0 && ph === en.models_cli_default, { ...shape, ph })

  // 2. N1: the choices are the latest box reading, with its box, time and CLI version
  const choices = await p.$$eval('#agent-models-grok option', (os) => os.map((o) => o.value))
  const grokLine = await text(p, '[data-test=agent-model-reading-grok]')
  const codexLine = await text(p, '[data-test=agent-model-reading-codex]')
  const list = await p.$eval(cell('tests', 'grok'), (e) => e.getAttribute('list'))
  ok('2 grok offers its newest reading (box-b, 2026-11-27 18:02 UTC, CLI 1.0.92); codex has none yet',
    list === 'agent-models-grok' && choices.join() === 'grok-4.7,grok-4.6' && grokLine === 'Grok: models read 2026-11-27 18:02 UTC on box-b, CLI 1.0.92' &&
    codexLine === 'Codex: no box has read its models yet', { list, choices, grokLine, codexLine })

  // 3. CONTROL: a model with a space marks the cell, names the rule and keeps Save off
  await typeIn(p, cell('all', 'claude'), 'a b')
  await p.waitForSelector('[data-test=agent-models-bad]', { visible: true, timeout: 5000 }).catch(() => null)
  const bad = { off: await saveOff(p), line: await text(p, '[data-test=agent-models-bad]'), invalid: await p.$eval(cell('all', 'claude'), (e) => e.getAttribute('aria-invalid')) }
  ok('3 CONTROL: "a b" names the rule, marks the cell and keeps Save off', bad.off === true && bad.line === en.error.bad_model && bad.invalid === 'true', bad)

  // 4. a typed model: the kind cells of that vendor show it as their fallback
  await typeIn(p, cell('all', 'claude'), RED === 'space-save' ? 'a b' : 'sonnet')
  await typeIn(p, cell('complex_coding', 'claude'), 'opus')
  await typeIn(p, cell('tests', 'grok'), 'grok-4.6')
  const fallback = await p.$eval(cell('tests', 'claude'), (e) => e.placeholder)
  ok('4 a kind cell shows its vendor\'s Every kind model as its fallback', RED === 'space-save' || fallback === 'sonnet', fallback)

  // 5. Save; a section change and back reads the cells from the (mock) hub
  if (RED === 'space-save') await p.$eval('[data-test=agent-models-save]', (e) => { e.disabled = false })
  await p.click('[data-test=agent-models-save]')
  await p.waitForSelector('[data-test=agent-models-notice], [data-test=agent-models-error]', { visible: true, timeout: 5000 }).catch(() => null)
  const notice = await text(p, '[data-test=agent-models-notice]')
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-nav-split]')
  await p.waitForSelector(cell('all', 'claude'), { visible: true, timeout: 10000 })
  await p.waitForFunction((s) => document.querySelector(s)?.value === 'opus', { timeout: 5000 }, cell('complex_coding', 'claude')).catch(() => null)
  const back = { all: await value(p, cell('all', 'claude')), cc: await value(p, cell('complex_coding', 'claude')), grok: await value(p, cell('tests', 'grok')), off: await saveOff(p) }
  ok('5 the models save and read back after a section change', notice === en.saved && back.all === 'sonnet' && back.cc === 'opus' && back.grok === 'grok-4.6' && back.off === true, { notice, ...back })

  // 6. emptied, a cell drops back to the CLI default
  await typeIn(p, cell('tests', 'grok'), '')
  await p.click('[data-test=agent-models-save]')
  await p.waitForFunction(() => document.querySelector('[data-test=agent-models-save]')?.disabled === true, { timeout: 5000 }).catch(() => null)
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-nav-split]')
  await p.waitForSelector(cell('complex_coding', 'claude'), { visible: true, timeout: 10000 })
  await p.waitForFunction((s) => document.querySelector(s)?.value === 'opus', { timeout: 5000 }, cell('complex_coding', 'claude')).catch(() => null)
  const cleared = { v: await value(p, cell('tests', 'grok')), ph: await p.$eval(cell('tests', 'grok'), (e) => e.placeholder), cc: await value(p, cell('complex_coding', 'claude')) }
  ok('6 an emptied cell saves as the CLI default, the others stay', cleared.v === '' && cleared.ph === en.models_cli_default && cleared.cc === 'opus', cleared)

  // 7. the table scrolls inside its card, never the page (1400 px and a phone)
  const wide = await pageFits(p)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/tenant-settings/split', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(cell('all', 'claude'), { visible: true, timeout: NAV_TIMEOUT })
  const phone = await pageFits(p)
  ok('7 no sideways page scroll at 1400 px or 390 px', wide.sw <= wide.vw && phone.sw <= phone.vw, { wide, phone })
  ok('8 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
