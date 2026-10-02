// SPL-978 live proof (owner, prd t1 topic d52f0763: "just a button with + the
// google way"): on a deployed WUI the Issues header shows a round accent
// button with only the plus glyph, named "New issue" on aria-label and title,
// with an elevation shadow that grows on hover; a click and the C shortcut
// both open the new-issue form. READ-ONLY: the form is closed with Esc and
// nothing is created. Screenshots and results.json to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issues-new-fab-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const SEL = '[data-test=issues-new]'

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fissues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok)
  if (!ok) throw new Error('not signed in')
  if (!new URL(p.url()).pathname.endsWith('/issues')) await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector(SEL, { visible: true, timeout: 30000 })
  await sleep(1200)

  const look = () => p.$eval(SEL, (e) => {
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    const head = e.closest('header')
    return {
      w: Math.round(r.width), h: Math.round(r.height), radius: cs.borderRadius, bg: cs.backgroundColor, shadow: cs.boxShadow,
      text: e.textContent.trim(), icon: e.querySelector('svg[data-icon="plus"]') ? 'plus' : '',
      label: e.getAttribute('aria-label'), title: e.getAttribute('title'),
      inHeader: !!head && !!head.querySelector('[data-test=issues-heading]'),
      position: cs.position,
    }
  })
  const a = await look()
  step('a round button (width = height, 50%) with only the plus icon, no visible text',
    a.w === a.h && a.w >= 32 && a.radius === '50%' && a.icon === 'plus' && a.text === '', a)
  step('named "New issue" on aria-label and title', a.label === 'New issue' && a.title === 'New issue', { label: a.label, title: a.title })
  step('accent fill with an elevation shadow, in the header beside the heading (not floating)',
    a.shadow !== 'none' && a.bg !== 'rgba(0, 0, 0, 0)' && a.inHeader && a.position !== 'fixed', { bg: a.bg, shadow: a.shadow, inHeader: a.inHeader })
  await p.screenshot({ path: `${OUT}/fab.png`, clip: { x: 0, y: 0, width: 1440, height: 200 } })
  await p.hover(SEL)
  await sleep(400)
  const h = await look()
  step('hover changes the fill and lifts the shadow', h.bg !== a.bg && h.shadow !== a.shadow, { bg: h.bg, shadow: h.shadow })
  await p.screenshot({ path: `${OUT}/fab-hover.png`, clip: { x: 0, y: 0, width: 1440, height: 200 } })

  const formOpen = () => p.evaluate(() => !!document.querySelector('[data-test=issues-create]'))
  await p.click(SEL)
  await sleep(600)
  const byClick = await formOpen()
  step('a click opens the new-issue form', byClick)
  await p.screenshot({ path: `${OUT}/fab-form.png` })
  await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
  await p.keyboard.press('Escape')
  await sleep(400)
  step('Esc closes it; nothing was created', !(await formOpen()))

  await p.mouse.click(700, 600)
  await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
  await p.keyboard.press('c')
  await sleep(600)
  const byC = await formOpen()
  step('the C shortcut still opens the new-issue form', byC)
  await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
  await p.keyboard.press('Escape')
  await sleep(300)
  step('Esc closes it again', !(await formOpen()))
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
