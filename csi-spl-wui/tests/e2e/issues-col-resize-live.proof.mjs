// SPL-1132 live proof (owner, topic beb4024f): the /issues columns resize on
// a DEPLOYED WUI, signed in, 1440 px. READ-ONLY: it never edits an issue;
// the widths it sets are put back to automatic at the end.
//   1 the sheet has a grip per column, no width stored at the start
//   2 dragging the Status edge +100 px widens Status; the body cells follow
//   3 a reload keeps it
//   4 a double-click on the Title edge fits the longest title (none clipped)
//   5 Delete on both grips: automatic again, nothing stored
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [USER_DATA_DIR=<dir>] node tests/e2e/issues-col-resize-live.proof.mjs
// The password is never printed.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), checks: [] }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: Boolean(pass), ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const widths = (p, col) => p.evaluate((col) => {
  const r = (el) => Math.round(el.getBoundingClientRect().width)
  const th = document.querySelector(`[data-test=issues-table] .issues-names th[data-col="${col}"]`)
  return { th: th ? r(th) : 0, tds: [...document.querySelectorAll(`[data-test=issues-row] td[data-col="${col}"]`)].slice(0, 20).map(r) }
}, col)
const gripAt = (p, col) => p.$eval(`[data-test="issues-col-grip-${col}"]`, (g) => { const b = g.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 } })

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  ...(process.env.USER_DATA_DIR ? { userDataDir: process.env.USER_DATA_DIR } : {}),
})
let code = 0
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fissues', { waitUntil: 'networkidle2', timeout: 60000 })
  if (await p.$('[data-test=native-auth-email]')) {
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.keyboard.press('Enter')
    await p.waitForFunction(() => !location.pathname.includes('/login'), { timeout: 60000 })
  }
  await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=issues-table] [data-test=issues-row]', { visible: true, timeout: 60000 })
  await p.evaluate(() => { try { localStorage.removeItem('spool.issues.colw') } catch { /* none */ } })
  await p.reload({ waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=issues-table] [data-test=issues-row]', { visible: true, timeout: 60000 })

  const grips = await p.$$eval('.issues-col-grip', (g) => g.length)
  const s0 = await widths(p, 'status')
  ok('1 a grip per column; automatic widths at the start', grips === 9 && !(await p.$('[data-test=issues-table][class*="issues-w-"]')), { grips, s0: s0.th })

  const g = await gripAt(p, 'status')
  await p.mouse.move(g.x, g.y)
  await p.mouse.down()
  for (let i = 1; i <= 5; i++) await p.mouse.move(g.x + 20 * i, g.y)
  await p.mouse.up()
  await sleep(200)
  const s1 = await widths(p, 'status')
  ok('2 dragging the Status edge +100 px widens it; the body cells follow', Math.abs(s1.th - (s0.th + 100)) <= 3 && s1.tds.length > 0 && s1.tds.every((w) => Math.abs(w - s1.th) <= 1), { before: s0.th, after: s1.th, rows: s1.tds.length })
  await p.screenshot({ path: join(OUT, 'resized.png') }).catch(() => {})

  await p.reload({ waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=issues-table] [data-test=issues-row]', { visible: true, timeout: 60000 })
  await sleep(300)
  const s2 = await widths(p, 'status')
  ok('3 a reload keeps the width', Math.abs(s2.th - s1.th) <= 1, { after_reload: s2.th })

  const t = await gripAt(p, 'title')
  await p.mouse.move(t.x, t.y)
  await p.mouse.down()
  await p.mouse.up()
  await p.mouse.down({ clickCount: 2 })
  await p.mouse.up({ clickCount: 2 })
  await sleep(300)
  const fit = await p.evaluate(() => {
    const spans = [...document.querySelectorAll('[data-test=issues-row] td[data-col="title"] .issues-title')]
    return { th: Math.round(document.querySelector('.issues-names th[data-col="title"]').getBoundingClientRect().width), clipped: spans.filter((s) => s.scrollWidth > s.clientWidth + 1).length, n: spans.length }
  })
  ok('4 a double-click on the Title edge fits the longest title (none clipped, or Title at its 960 px ceiling)', fit.n > 0 && (fit.clipped === 0 || fit.th >= 959), fit)

  for (const col of ['title', 'status']) {
    await p.focus(`[data-test="issues-col-grip-${col}"]`)
    await p.keyboard.press('Delete')
  }
  await sleep(200)
  const back = await p.evaluate(() => localStorage.getItem('spool.issues.colw'))
  ok('5 Delete on the grips: automatic again, nothing stored', back === '{}' || back === null, { stored: back })
  ok('no page errors', errors.length === 0, errors)
} catch (e) {
  ok('harness', false, String(e && e.message || e))
} finally {
  await browser.close()
  if (res.checks.some((c) => !c.ok)) code = 1
  writeFileSync(join(OUT, 'issues-col-resize-live.json'), JSON.stringify(res, null, 2))
  console.log(code ? 'issues-col-resize-live: FAIL' : 'issues-col-resize-live: PASS')
  process.exit(code)
}
