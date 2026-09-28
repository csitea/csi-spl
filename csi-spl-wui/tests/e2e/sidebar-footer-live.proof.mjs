// SPL-1146 live proof: on a DEPLOYED WUI, signed in, the sidebar footer is
// its own opaque bar and the last row of each sidebar list (Issues epics,
// Channels, DMs, Topics, Flow) scrolls fully into view above it - at 1440,
// 1280 and 1024 px and on the phone level-1 screen. READ-ONLY: it clicks
// tabs and scrolls, nothing else. One screenshot per size (the Issues tab).
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [USER_DATA_DIR=<dir>] node tests/e2e/sidebar-footer-live.proof.mjs
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

const SIZES = (process.env.SIZES ? (s) => s.filter((x) => process.env.SIZES.split(',').includes(x.name)) : (s) => s)([
  { name: '1440', width: 1440, height: 560, mobile: false },
  { name: '1280', width: 1280, height: 520, mobile: false },
  { name: '1024', width: 1024, height: 480, mobile: false },
  { name: '390', width: 390, height: 640, mobile: true },
])
const TABS = ['issues', 'channels', 'dm', 'topics', 'flow']

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

const measure = (p, tab) => p.evaluate((tab) => {
  const panel = document.getElementById('sidebar-panel-' + tab)
  const foot = panel?.closest('.sidebar')?.querySelector('.sidebar-foot')
  if (!panel || !foot || panel.offsetParent === null) return { missing: !panel ? 'panel' : !foot ? 'foot' : 'hidden' }
  const rows = [...panel.querySelectorAll('.nav-row, .epic-row')].filter((e) => e.getClientRects().length)
  const row = rows.at(-1)
  if (!row) return { rows: 0 }
  const scroller = panel.querySelector('.sidebar-scroll')
  if (scroller) scroller.scrollTop = scroller.scrollHeight
  const rr = row.getBoundingClientRect()
  const fr = foot.getBoundingClientRect()
  const hit = document.elementFromPoint(rr.left + rr.width / 2, rr.top + rr.height / 2)
  const cs = getComputedStyle(foot)
  const alpha = /rgba?\(([^)]+)\)/.exec(cs.backgroundColor)?.[1].split(/[ ,/]+/).filter(Boolean)[3]
  return {
    rows: rows.length,
    overflow: scroller ? scroller.scrollHeight > scroller.clientHeight + 1 : panel.scrollHeight > panel.clientHeight + 1,
    rowBottom: Math.round(rr.bottom),
    footTop: Math.round(fr.top),
    /* 1 px: a fractional scroller height against an integer scrollTop;
       the scroller clips that sliver, it never paints under the footer */
    clear: rr.bottom <= fr.top + 1,
    rowHit: Boolean(hit && row.contains(hit)),
    bar: (alpha === undefined || Number(alpha) === 1) && parseFloat(cs.borderTopWidth) >= 1,
  }
}, tab)

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
  /* sign in through the WUI form; again whenever a page lands on /login */
  const signIn = async () => {
    const field = await p.waitForSelector('[data-test=native-auth-email]', { visible: true, timeout: 30000 }).catch(() => null)
    if (!field) return
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.keyboard.press('Enter')
    await p.waitForFunction(() => !location.pathname.includes('/login'), { timeout: 60000 })
  }
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fissues', { waitUntil: 'networkidle2', timeout: 60000 })
  await signIn()
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build))
  for (const s of SIZES) {
    console.log(`-- ${s.name}x${s.height}`)
    await p.setViewport({ width: s.width, height: s.height, isMobile: s.mobile, hasTouch: s.mobile })
    await p.goto(BASE + (s.mobile ? '/' : '/issues'), { waitUntil: 'networkidle2', timeout: 60000 })
    if (new URL(p.url()).pathname.includes('/login')) await signIn()
    /* phone: the sidebar is level 1; an account may land deeper - Back */
    for (let i = 0; s.mobile && i < 3; i++) {
      const level = await p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'))
      if (level === '1') break
      await p.click('.mobile-back').catch(() => null)
      await sleep(600)
    }
    await p.waitForSelector('.sidebar-foot', { visible: true, timeout: 60000 })
    for (const tab of TABS) {
      const btn = await p.waitForSelector(`[data-testid=sidebar-tab-${tab}]`, { visible: true, timeout: 15000 }).catch(() => null)
      if (!btn) { ok(`${s.name} ${tab}: tab present`, false); continue }
      await btn.click()
      await sleep(600)
      if (tab === 'issues') {
        if (s.mobile) {
          await p.waitForSelector('[data-test=issues-back]', { visible: true, timeout: 30000 }).catch(() => null)
          await p.click('[data-test=issues-back]').catch(() => null)
        }
        await p.waitForSelector('[data-testid=sidebar-epic]', { visible: true, timeout: 30000 }).catch(() => null)
        await sleep(400)
      }
      const m = await measure(p, tab)
      if (!m.rows) { console.log(`  --   ${s.name} ${tab}: no rows to measure ${JSON.stringify(m)}`); continue }
      ok(`${s.name} ${tab}: last row fully above the footer, hit at its centre, footer an opaque bordered bar`, m.clear && m.rowHit && m.bar, m)
      if (tab === 'issues') await p.screenshot({ path: join(OUT, `issues-${s.name}.png`) }).catch(() => {})
    }
  }
} catch (e) {
  console.error('ERROR', e.message)
  const p = (await browser.pages()).at(-1)
  if (p) {
    console.error('at', p.url(), await p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level')).catch(() => null))
    await p.screenshot({ path: join(OUT, 'error.png') }).catch(() => {})
  }
  code = 1
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 2))
const failed = res.checks.filter((c) => !c.ok)
console.log(`${res.checks.length - failed.length}/${res.checks.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
