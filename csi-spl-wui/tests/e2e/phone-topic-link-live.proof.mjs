// t1 6e21c7d8 live proof, READ-ONLY: a topic link inside a post opens on the
// phone. Signs in (native) at 390 px, opens a #lobby topic in the topic pane
// (level 3), turns that topic's rows IN THE PAGE'S OWN STORE into the link post
// ("Moved to the new discussion: <origin>/t/<other topic>") - nothing is sent
// to the hub - taps the link, and checks the linked topic is on screen and
// Back returns to the post. Writes nothing to the tenant.
//
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> \
//   OUT=<dir> node tests/e2e/phone-topic-link-live.proof.mjs
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} must be set`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
mkdirSync(OUT, { recursive: true })
const require = createRequire(import.meta.url)
const puppeteer = require('puppeteer-core')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, pass, ev) => { res.steps.push({ name, pass, ev }); console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${pass ? '' : ' ' + JSON.stringify(ev)}`) }

/* the topic link, never another link the post already carries */
const LINK = '.spool-shell > .topic a.msg-link[href*="/t/"]'
const state = (p) => p.evaluate((link) => {
  const sh = document.querySelector('.spool-shell')
  const vis = (s) => { const e = document.querySelector(s); if (!e) return false; const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0 }
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    main: vis('.spool-shell > .spool-main'), pane: vis('.spool-shell > .topic'),
    page: vis('.spool-main [data-test=topic-root]'), link: vis(link),
    path: location.pathname + location.search,
  }
}, LINK)

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
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
  if (host !== TENANT) throw new Error('refusing: page host is not the test tenant')

  /* the lobby's topic pane (the live 'pane' store): its rows are store state */
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await sleep(3000)
  const ids = await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const main = pinia?._s.get('live-main')
    const rows = (main?.lobbyRows || main?.messages || []).filter((m) => m && m.task_id)
    const tasks = [...new Set(rows.map((m) => m.task_id))]
    return { from: tasks[0] || '', to: tasks[1] || '' }
  })
  step('two topics in the lobby', Boolean(ids.from && ids.to), ids)
  /* a row tap writes ?topic= (useTopicRoute); open it the same way */
  await p.goto(`${BASE}/lobby?topic=${ids.from}`, { waitUntil: 'networkidle2', timeout: 60000 })
  await sleep(3000)
  const href = `${new URL(BASE).origin}/t/${ids.to}`
  const patched = await p.evaluate((body) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const pane = pinia._s.get('live-pane')
    pane.messages = pane.messages.map((m) => ({ ...m, body }))
    return pane.messages.length
  }, `Moved to the new discussion: ${href}`)
  step('the pane rows hold the link post (page store only, nothing sent)', patched > 0, { patched })
  await p.waitForSelector(LINK, { visible: true, timeout: 10000 }).catch(() => {})
  let s = await state(p)
  step('the link post shows in the topic pane, level 3', s.level === '3' && s.pane && !s.main && s.link, s)
  await p.screenshot({ path: `${OUT}/390-before-tap.png` })

  await p.tap(LINK)
  await sleep(3000)
  s = await state(p)
  step('a tap on the topic link opens that topic on screen', s.path.startsWith(`/t/${ids.to}`) && s.page && !s.pane, s)
  await p.screenshot({ path: `${OUT}/390-after-tap.png` })

  await p.goBack()
  await sleep(3000)
  s = await state(p)
  step('Back returns to the post the link was tapped in', s.path.startsWith('/lobby') && s.path.includes(`topic=${ids.from}`) && s.level === '3' && s.pane && !s.main, s)
  await p.screenshot({ path: `${OUT}/390-after-back.png` })
} catch (e) {
  step('proof ran to the end', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
}
process.exit(res.steps.every((x) => x.pass) ? 0 : 1)
