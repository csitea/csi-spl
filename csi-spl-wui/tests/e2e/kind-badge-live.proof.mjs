// SPL-952 live proof of the message kind badges against a deployed WUI.
// Signs in (native form), opens TOPIC, and checks that the message carrying
// MARK shows kind WANT as an icon badge (a blocker on a red fill). With
// PICK=1 it then posts its own line into the lobby, opens that line's badge
// menu, picks `task`, and checks the badge after a reload (the hub stored it).
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     TOPIC=<task_id> MARK=<body text> [WANT=blocker] [PICK=1] [TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/kind-badge-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TOPIC = need('TOPIC')
const MARK = need('MARK')
const WANT = process.env.WANT || 'blocker'
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })

/** The badge of the first card whose body contains text: kind, element, fill. */
const badgeOf = (p, text) => p.evaluate((text) => {
  const card = [...document.querySelectorAll('article[data-msg-id]')].find((a) => a.textContent.includes(text))
  if (!card) return null
  const b = card.querySelector('.kind')
  if (!b) return { msgId: card.dataset.msgId, kind: null }
  const cs = getComputedStyle(b)
  return { msgId: card.dataset.msgId, kind: b.dataset.kind, tag: b.tagName, label: b.getAttribute('aria-label'),
    icon: b.querySelector('svg')?.dataset.icon || null, bg: cs.backgroundColor, color: cs.color }
}, text)
const reddish = (rgb) => { const m = String(rgb).match(/\d+/g); return !!m && +m[0] > 180 && +m[1] < 130 && +m[2] < 130 }

try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!signed, { url: p.url() })

  await p.goto(BASE + '/t/' + encodeURIComponent(TOPIC), { waitUntil: 'networkidle2' })
  let b = null
  for (let i = 0; i < 20 && !(b && b.kind); i++) { await sleep(500); b = await badgeOf(p, MARK) }
  const iconOk = b && b.icon === 'kind-' + WANT
  step(`the message shows kind ${WANT} as an icon badge`, !!b && b.kind === WANT && iconOk, b || {})
  if (WANT === 'blocker') step('the blocker badge is red', !!b && reddish(b.bg), { bg: b?.bg })
  await p.screenshot({ path: `${OUT}/kind-${WANT}.png` })

  if (process.env.PICK === '1') {
    const line = `SPL-952 kind picker proof ${new Date().toISOString()}`
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('.top-bar__omnibox textarea')
    await p.type('.top-bar__omnibox textarea', line)
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
    let own = null
    for (let i = 0; i < 30 && !(own && own.tag === 'BUTTON'); i++) { await sleep(500); own = await badgeOf(p, line) }
    step('my own line has a clickable kind badge (note by default)', !!own && own.tag === 'BUTTON' && own.kind === 'note', own || {})
    if (own && own.tag === 'BUTTON') {
      await p.evaluate((id) => document.querySelector(`article[data-msg-id="${id}"] [data-testid=kind-badge-btn]`).click(), own.msgId)
      const menu = await p.waitForSelector('[data-testid=kind-picker]', { timeout: 5000 }).catch(() => null)
      const focused = await p.evaluate(() => document.activeElement?.dataset?.kind || null)
      step('the badge opens the kind menu, focus on the current kind', !!menu && focused === 'note', { focused })
      await p.screenshot({ path: `${OUT}/kind-picker-open.png` })
      await p.click('[data-testid=kind-picker] [data-kind=task]')
      let after = null
      for (let i = 0; i < 20 && !(after && after.kind === 'task'); i++) { await sleep(300); after = await badgeOf(p, line) }
      step('choosing task re-types the line', !!after && after.kind === 'task', after || {})
      await p.reload({ waitUntil: 'networkidle2' })
      let reload = null
      for (let i = 0; i < 20 && !(reload && reload.kind); i++) { await sleep(500); reload = await badgeOf(p, line) }
      step('after a reload the hub still says task', !!reload && reload.kind === 'task', reload || {})
      await p.screenshot({ path: `${OUT}/kind-picker-after.png` })
    }
  }
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
