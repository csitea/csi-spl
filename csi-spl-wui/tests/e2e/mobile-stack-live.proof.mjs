// SPL-989 live proof, READ-ONLY: the phone shell on a deployed WUI.
// Signs in (native), then at each width walks level 1 -> 2 (a channel) -> 3
// (a topic from that feed) and back: browser Back 3 -> 2, the chevron 2 -> 1.
// Screenshots per level. Writes nothing to the tenant.
//
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> \
//   OUT=<dir> [WIDTHS=390,820] node tests/e2e/mobile-stack-live.proof.mjs
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} must be set`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
const WIDTHS = (process.env.WIDTHS || '390,820').split(',').map(Number)
mkdirSync(OUT, { recursive: true })
const require = createRequire(import.meta.url)
const puppeteer = require('puppeteer-core')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, pass, ev) => { res.steps.push({ name, pass, ev }); console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${pass ? '' : ' ' + JSON.stringify(ev)}`) }

const state = (p) => p.evaluate(() => {
  const sh = document.querySelector('.spool-shell')
  const vis = (s) => { const e = document.querySelector(s); if (!e) return false; const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0 }
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    side: vis('.spool-shell > .sidebar'), main: vis('.spool-shell > .spool-main'), topic: vis('.spool-shell > .topic'),
    path: location.pathname + location.search, xscroll: document.scrollingElement.scrollWidth > innerWidth,
  }
})
const only = (s, lv) => s.level === String(lv) && s.side === (lv === 1) && s.main === (lv === 2) && s.topic === (lv === 3) && !s.xscroll

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: WIDTHS[0], height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT), { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('.spool-shell', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed, { url: p.url() })
  if (!signed) throw new Error('not signed in')
  const host = new URL(BASE).hostname.split('.')[0]
  step('the page host is the test tenant', host === TENANT, { host })

  for (const width of WIDTHS) {
    await p.setViewport({ width, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    const at = `${width}px`
    await p.goto(BASE + '/', { waitUntil: 'networkidle2', timeout: 60000 })
    await sleep(2500)
    let s = await state(p)
    step(`${at} opens on level 1 only`, only(s, 1), s)
    await p.click('[data-testid=sidebar-tab-channels]')
    await sleep(800)
    await p.screenshot({ path: `${OUT}/${width}-level1.png` })
    await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
    await sleep(2500)
    s = await state(p)
    step(`${at} a channel tap -> level 2`, only(s, 2) && s.path.includes('/channel/'), s)
    await p.screenshot({ path: `${OUT}/${width}-level2.png` })
    const opened = await p.evaluate(() => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      const ch = pinia?._s.get('channel')
      const row = (ch?.messages || []).find((m) => m && m.task_id)
      if (!row) return ''
      pinia._s.get('topic').openTopic(row.task_id)
      return row.task_id
    })
    await sleep(2500)
    s = await state(p)
    step(`${at} a topic -> level 3`, Boolean(opened) && only(s, 3), { opened, ...s })
    await p.screenshot({ path: `${OUT}/${width}-level3.png` })
    await p.goBack()
    await sleep(1500)
    s = await state(p)
    step(`${at} browser Back 3 -> 2`, only(s, 2), s)
    await p.click('.spool-main [data-testid=mobile-back]')
    await sleep(1500)
    s = await state(p)
    step(`${at} the chevron 2 -> 1`, only(s, 1), s)
  }
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
} catch (e) {
  step('run', false, String(e))
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.pass).length
console.log(`mobile-stack-live: ${res.steps.length - failed}/${res.steps.length} PASS, build ${res.build?.commit || '?'}`)
process.exit(failed ? 1 : 0)
