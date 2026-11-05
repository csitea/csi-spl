// SPL-4810 (spec 153 3.20; owner HUM-10, t1 27162335, msgs 038fa412,
// 8dd53bd9 and 3b2ba6f3: "the console output of a lane, ON PER DEMAND click
// ... only after he opens the lane, which will have the lane data in a
// pop-up modal dialog - the same way the issues are opened ... and there at
// the end should be the console output button ... a live feed of the
// console" and "the capability to save that log output to a file locally").
// In a REAL browser, mock bundle, at 1440 and 390:
//
//   1  the Lanes table shows no Console button
//   2  a row's agent opens the lane in a modal dialog (UiDialog), its fields
//      first, the Console button at its end
//   3  a click shows the feed: the mock's screen, masked text included
//   4  Save downloads <agent>@<box>-<UTC>.txt holding exactly the shown lines
//   5  Escape closes the dialog and the feed with it
//   6  the workspace door (a workspace admin, no operator): the same, the box
//      never named
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-lane-console
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined || pass ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const VIEWPORTS = [
  { tag: '1440', vp: { width: 1440, height: 900 } },
  { tag: '390', vp: { width: 390, height: 844, isMobile: true, hasTouch: true } },
]
const PATH = '/monitoring/lanes'
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })
const OPERATOR = { [TOKENS_MOCK_OPERATOR_KEY]: '1' }
const MEMBER = { 'spool.mock.me': JSON.stringify({ role: 'admin', permissions: ['topics.read'] }) }

async function open(browser, vp, seed) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
    /* Save's file: the Blob and the name the page hands the browser */
    window.__saved = []
    const make = URL.createObjectURL.bind(URL)
    URL.createObjectURL = (b) => { const u = make(b); window.__saved.push({ url: u, blob: b }); return u }
    const click = HTMLAnchorElement.prototype.click
    HTMLAnchorElement.prototype.click = function () {
      const hit = window.__saved.find((x) => x.url === this.href)
      if (hit) hit.name = this.download
      return click.call(this)
    }
  }, { 'spool.mock.session': SESSION, ...seed })
  await setPageViewport(p, vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=lanes-row]', { timeout: 15000 }).catch(() => null)
  return { p, ctx, errors }
}

const count = (p, sel) => p.$$eval(sel, (els) => els.length).catch(() => -1)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent || '').catch(() => '')

async function flow(p, tag, door, agent) {
  ok(`1 ${tag} ${door}: the table shows no Console button`, (await count(p, '[data-test=lane-console-toggle]')) === 0)
  await p.click(`[data-test=lanes-row][data-agent="${agent}"] [data-test=lanes-open]`)
  const dlg = await p.waitForSelector('[data-testid=ui-dialog] [data-test=lane-dialog]', { visible: true, timeout: 10000 }).then(() => true, () => false)
  const title = await text(p, '[data-testid=ui-dialog] .ui-dialog__title')
  const order = await p.evaluate(() => {
    const d = document.querySelector('[data-test=lane-dialog]')
    const kids = d ? [...d.children].map((e) => e.className.split(' ')[0]) : []
    return kids.join(',')
  })
  ok(`2 ${tag} ${door}: the row opens the lane in a modal, its fields, then Console`, dlg && title.startsWith(agent) && order.startsWith('ld-fields,ld-console-bar')
    && (await count(p, '[data-testid=ui-dialog] [data-test=lane-console-toggle]')) === 1, { dlg, title, order })

  await p.click('[data-test=lane-console-toggle]')
  const fed = await p.waitForFunction(() => {
    const s = document.querySelector('[data-test=lane-console-screen]')?.textContent || ''
    return s.includes('make test') && s.includes('<redacted:github-token>')
  }, { timeout: 15000 }).then(() => true, () => false)
  const status = await p.$eval('[data-test=lane-console-status]', (e) => e.getAttribute('data-state')).catch(() => '')
  ok(`3 ${tag} ${door}: a click shows the live feed, masked text included`, fed && status === 'live', { status, screen: await text(p, '[data-test=lane-console-screen]') })

  const shown = await text(p, '[data-test=lane-console-screen]')
  await p.click('[data-test=lane-console-save]')
  const saved = await p.waitForFunction(() => window.__saved.some((x) => x.name), { timeout: 5000 }).then(() => p.evaluate(async () => {
    const s = window.__saved.find((x) => x.name)
    return { name: s.name, type: s.blob.type, text: await s.blob.text() }
  }), () => null)
  const nameRe = new RegExp('^' + agent + '(@box-a)?-\\d{8}T\\d{6}Z\\.txt$')
  ok(`4 ${tag} ${door}: Save downloads a .txt holding exactly the shown lines`, !!saved && nameRe.test(saved.name)
    && saved.type.startsWith('text/plain') && saved.text === shown + '\n', saved)

  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/monitoring-lane-console-${door}-${tag}.png` })
  await p.keyboard.press('Escape')
  const closed = await p.waitForFunction(() => !document.querySelector('[data-test=lane-dialog]'), { timeout: 5000 }).then(() => true, () => false)
  ok(`5 ${tag} ${door}: Escape closes the dialog and the feed`, closed && (await count(p, '[data-test=lane-console-screen]')) === 0)
}

const server = await startServer()
const browser = await launch()
try {
  for (const { tag, vp } of VIEWPORTS) {
    const a = await open(browser, vp, OPERATOR)
    await flow(a.p, tag, 'operator', 'c-085')
    ok(`${tag} operator: no page error`, a.errors.length === 0, a.errors)
    await a.ctx.close()

    const m = await open(browser, vp, MEMBER)
    await flow(m.p, tag, 'workspace', 'c-085')
    const leaked = await m.p.evaluate(() => document.body.innerText.includes('box-a'))
    ok(`6 ${tag} workspace: the operator box is never named`, !leaked)
    ok(`${tag} workspace: no page error`, m.errors.length === 0, m.errors)
    await m.ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL monitoring-lane-console: ${failed.length} of ${results.length}` : `OK monitoring-lane-console: ${results.length} checks`)
process.exit(failed.length ? 1 : 0)
