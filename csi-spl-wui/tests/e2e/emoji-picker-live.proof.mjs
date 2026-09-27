// SPL-1002 acceptance proof against a deployed WUI (owner, prd t1 topic
// 9c10b31f): signed in as a member, with a remembered 'recent' list seeded,
// the emoji picker on a phone (390 and 820 px, touch) and on the desktop
// (1440 px) shows every glyph once, offers exactly EMOJI_CHOICES, ends with a
// full row and draws ink in every cell. Read-only: it opens the picker and
// never chooses a glyph. A screenshot per width to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant>
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/emoji-picker-live.proof.mjs
//
// Passwords are read from files and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { EMOJI_CHOICES } from '../../src/utils/emoji.mjs'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const RECENT = ['😡', '👍', '🔥']
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  if (!ok) { await p.screenshot({ path: `${OUT}/signin-failed.png` }).catch(() => {}); throw new Error(`not signed in: ${EMAIL}`) }
  await p.evaluate((list) => { localStorage.setItem('spool.emoji-recent', JSON.stringify(list)) }, RECENT)
  await p.close()
}

function facts(page) {
  return page.evaluate(() => {
    const el = document.querySelector('[data-testid=emoji-picker]')
    if (!el) return null
    const glyphs = [...el.querySelectorAll('.emoji-picker__glyph')]
    const grids = [...el.querySelectorAll('.emoji-picker__grid')].map((g) => {
      const cols = getComputedStyle(g).gridTemplateColumns.split(' ').filter(Boolean).length
      const n = g.querySelectorAll('.emoji-picker__glyph').length
      return { cols, n, empty: cols ? (cols - (n % cols)) % cols : -1 }
    })
    const cv = document.createElement('canvas')
    cv.width = 64
    cv.height = 64
    const cx = cv.getContext('2d', { willReadFrequently: true })
    const blank = []
    for (const b of glyphs) {
      cx.clearRect(0, 0, 64, 64)
      cx.font = `32px ${getComputedStyle(b).fontFamily}`
      cx.textBaseline = 'middle'
      cx.fillText(b.textContent || '', 8, 32)
      const d = cx.getImageData(0, 0, 64, 64).data
      let ink = 0
      for (let i = 3; i < d.length; i += 4) if (d[i]) ink++
      if (ink < 20) blank.push(b.getAttribute('data-emoji'))
    }
    const min = glyphs.length ? Math.min(...glyphs.map((b) => Math.round(Math.min(b.getBoundingClientRect().width, b.getBoundingClientRect().height)))) : 0
    return { sheet: el.classList.contains('touch-sheet'), shown: glyphs.map((b) => b.getAttribute('data-emoji') || ''), grids, blank, min }
  })
}

async function view(ctx, width, height, touch) {
  const tag = `${width}px`
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch, deviceScaleFactor: touch ? 2 : 1 })
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  const sel = 'article.msg[data-msg-id] [data-testid=msg-emoji-btn]'
  await p.waitForSelector(sel, { timeout: 60000 })
  await sleep(500)
  if (touch) await p.tap(sel)
  else await p.click(sel)
  await sleep(600)
  const f = await facts(p)
  const seen = new Map()
  for (const e of (f ? f.shown : [])) seen.set(e, (seen.get(e) || 0) + 1)
  const twice = [...seen].filter(([, n]) => n > 1).map(([e]) => e)
  const missing = EMOJI_CHOICES.filter((e) => !seen.has(e))
  const extra = [...seen.keys()].filter((e) => !EMOJI_CHOICES.includes(e))
  step(`${tag} picker open (${touch ? 'sheet' : 'popover'})`, Boolean(f) && f.sheet === touch, f && { sheet: f.sheet })
  step(`${tag} every glyph once (recent ${RECENT.join(' ')} seeded)`, Boolean(f) && !twice.length, { twice, n: f && f.shown.length })
  step(`${tag} offers exactly the ${EMOJI_CHOICES.length} choices`, Boolean(f) && !missing.length && !extra.length, { missing, extra })
  step(`${tag} the grid ends full`, Boolean(f) && f.grids.length === 1 && f.grids[0].empty === 0, f && { grids: f.grids })
  step(`${tag} every glyph draws ink`, Boolean(f) && !f.blank.length, f && { blank: f.blank })
  if (touch) step(`${tag} glyphs >= 44 px`, Boolean(f) && f.min >= 44, f && { min: f.min })
  await p.screenshot({ path: `${OUT}/emoji-picker-live-${width}.png` })
  await p.close()
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  const ctx = await browser.createBrowserContext()
  await signIn(ctx)
  await view(ctx, 390, 844, true)
  await view(ctx, 820, 1180, true)
  await view(ctx, 1440, 900, false)
} catch (e) {
  step('run', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/emoji-picker-live.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok)
console.log(failed.length ? `FAIL ${failed.length}/${res.steps.length}` : `PASS ${res.steps.length}/${res.steps.length}`)
process.exit(failed.length ? 1 : 0)
