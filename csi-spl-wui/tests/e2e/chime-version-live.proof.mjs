// SPL-998 + SPL-999 live proof, signed in, read-only (nothing is posted; the
// note and the bell are per-browser switches in localStorage).
//
// SPL-998: with the page's AudioContext and Notification replaced by
// recorders, a ping with the note OFF makes no oscillator and a SILENT alert;
// with the note ON both sound. Close-ups of the bell and the note side by
// side, both OFF and both ON, in the dark and the light theme (set on the
// page only, never saved to the account).
// SPL-999: the version pop-up at 1440, 820 and 390 px holds the whole sha on
// one line (at <= 390 at most two), inside the screen, with the copy icon.
//
// Run (prd: the e2e tenant host only - the apex is t1's host):
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=... PW_FILE=... OUT=<dir> \
//     node tests/e2e/chime-version-live.proof.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

function recorders() {
  window.__sounds = []
  class FakeCtx {
    constructor() { this.currentTime = 0; this.destination = {} }
    createOscillator() { return { frequency: {}, connect() {}, start: () => window.__sounds.push({ kind: 'osc' }), stop() {} } }
    createGain() { return { gain: {}, connect() {} } }
  }
  window.AudioContext = FakeCtx
  function FakeNotification(title, opts) { window.__sounds.push({ kind: 'alert', silent: Boolean(opts && opts.silent) }) }
  FakeNotification.permission = 'granted'
  FakeNotification.requestPermission = async () => 'granted'
  window.Notification = FakeNotification
}

const ping = (p) => p.evaluate(() => {
  window.__sounds = []
  document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').ping('New message', 'hello')
  return window.__sounds
})

const claimTenant = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?.state?.value?.session
  return (s && s.claims && s.claims.t) || ''
})

const browser = await (await loadPuppeteer()).launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: null,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  const ctx = await browser.createBrowserContext()
  await ctx.overridePermissions(BASE, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument(recorders)
  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  step(`session tenant is ${TENANT}`, (await claimTenant(p)) === TENANT, { t: await claimTenant(p) })
  const build = await p.evaluate(() => fetch('/build.json', { cache: 'no-cache' }).then((r) => r.json()).catch(() => null))
  res.build = build
  console.log('build', JSON.stringify(build))

  // ---- SPL-998 ----
  await p.evaluate(() => { localStorage.setItem('spool.chime', '1'); localStorage.setItem('spool.alerts', '1') })
  await nav(p, BASE + '/lobby')
  await p.waitForSelector('[data-testid=notify-box-rail] [data-testid=notify-chime]', { timeout: 30000 })
  await sleep(1500)
  const loud = await ping(p)
  step('998 note ON: a ping plays the oscillator and a sounding alert (control)', loud.some((s) => s.kind === 'osc') && loud.some((s) => s.kind === 'alert' && !s.silent), { loud })
  const box = '[data-testid=notify-box-rail]'
  const closeUp = async (name) => {
    const r = await p.$eval('.foot-row', (el) => { const b = el.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height } })
    await p.screenshot({ path: `${OUT}/${name}.png`, clip: { x: Math.max(0, r.x), y: Math.max(0, r.y - 4), width: Math.min(260, r.w), height: r.h + 8 } })
  }
  for (const theme of ['dark', 'light']) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await sleep(300)
    await closeUp(`998-${theme}-both-on`)
  }
  await p.click(`${box} [data-testid=notify-chime]`)
  await sleep(300)
  const quiet = await ping(p)
  step('998 note OFF: no oscillator, the alert is silent', !quiet.some((s) => s.kind === 'osc') && quiet.length === 1 && quiet[0].silent === true, { quiet })
  await p.click(`${box} [data-testid=notify-alerts]`)
  await sleep(300)
  const ink = await p.evaluate((box) => {
    const one = (sel) => {
      const b = document.querySelector(`${box} [data-testid=${sel}]`)
      const last = [...b.querySelectorAll('svg path')].at(-1)
      return { icon: b.querySelector('svg').getAttribute('data-icon'), d: last.getAttribute('d'), w: getComputedStyle(last).strokeWidth, color: getComputedStyle(b).color, opacity: getComputedStyle(b).opacity, pressed: b.getAttribute('aria-pressed') }
    }
    return { note: one('notify-chime'), bell: one('notify-alerts') }
  }, box)
  step('998 both OFF: the note strike = the bell strike (path, width, colour)',
    ink.note.icon === 'music-off' && ink.bell.icon === 'bell-off' && ink.note.d === ink.bell.d && ink.note.w === ink.bell.w && ink.note.color === ink.bell.color && ink.note.opacity === ink.bell.opacity, ink)
  for (const theme of ['dark', 'light']) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await sleep(300)
    await closeUp(`998-${theme}-both-off`)
  }
  await nav(p, BASE + '/lobby')
  await p.waitForSelector(`${box} [data-testid=notify-chime]`, { timeout: 30000 })
  await sleep(1500)
  const kept = await p.$eval(`${box} [data-testid=notify-chime]`, (b) => b.getAttribute('aria-pressed'))
  const still = await ping(p)
  step('998 reload: still muted, a ping stays silent', kept === 'false' && !still.some((s) => s.kind === 'osc'), { kept, still })

  // ---- SPL-999 ----
  for (const [w, touch] of [[1440, false], [820, true], [390, true]]) {
    await p.setViewport({ width: w, height: 800, isMobile: touch, hasTouch: touch })
    await nav(p, BASE + (touch ? '/' : '/lobby'))
    await p.waitForSelector('[data-test=app-version-card]', { timeout: 30000 })
    await sleep(1500)
    await p.evaluate(() => document.querySelector('[data-test=app-version-wrap]').click())
    await sleep(500)
    const m = await p.evaluate(() => {
      const card = document.querySelector('[data-test=app-version-card]')
      const sha = card.querySelector('.vs-pop__sha')
      const btn = card.querySelector('[data-test=app-version-copy]')
      const rc = card.getBoundingClientRect(), rs = sha.getBoundingClientRect(), rb = btn.getBoundingClientRect()
      const range = document.createRange(); range.selectNodeContents(sha)
      const painted = [[rs.left + 2, rs.top + 2], [rs.right - 2, rs.top + 2], [rs.left + 2, rs.bottom - 2], [rs.right - 2, rs.bottom - 2]]
        .every(([x, y]) => { const e = document.elementFromPoint(x, y); return Boolean(e && card.contains(e)) })
      return { vw: innerWidth, sha: sha.textContent.trim(), lines: range.getClientRects().length, painted, card: [Math.round(rc.left), Math.round(rc.right)], btn: [Math.round(rb.left), Math.round(rb.right), Math.round(rb.width), Math.round(rb.height)], icon: btn.querySelector('svg')?.getAttribute('data-icon') }
    })
    const lineOk = w > 390 ? m.lines === 1 : m.lines <= 2
    step(`999 ${w}px: the whole ${m.sha.length}-char sha, ${w > 390 ? 'one line' : '<= 2 lines'}, painted, inside the screen, copy icon inside the card`,
      m.sha.length === 40 && lineOk && m.painted && m.card[0] >= 8 && m.card[1] <= m.vw - 8 && m.btn[1] <= m.card[1] && m.icon === 'copy' && (!touch || (m.btn[2] >= 44 && m.btn[3] >= 44)), m)
    await p.screenshot({ path: `${OUT}/999-${w}.png` })
    if (w === 1440) {
      await p.click('[data-test=app-version-copy]')
      await sleep(300)
      const clip = await p.evaluate(() => navigator.clipboard.readText().catch((e) => `ERR ${e.message}`))
      const after = await p.$eval('[data-test=app-version-copy]', (b) => ({ icon: b.querySelector('svg')?.getAttribute('data-icon'), text: b.textContent.trim() }))
      step('999 copy: the full sha on the clipboard, then the check and "Copied"', clip === m.sha && after.icon === 'check' && /copied/i.test(after.text), { clip, after })
      await p.screenshot({ path: `${OUT}/999-1440-copied.png` })
    }
  }
  // leave this browser's switches as a new browser has them
  await p.evaluate(() => { localStorage.removeItem('spool.chime'); localStorage.removeItem('spool.alerts') })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
console.log(`\nchime-version-live: ${res.steps.length - failed}/${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
