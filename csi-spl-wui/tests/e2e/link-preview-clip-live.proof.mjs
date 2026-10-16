// Owner t1 c7ddbf83 ("5 rows should always be 5 rows in size"): a card with
// link previews stays inside the message list's "5 rows" box, and is one
// line in "Titles only". Live proof, signed in, against a deployed WUI, on
// desktop (1440x900) and phone (390x844). It reads and clicks, never posts.
//
//   BASE=https://<wui-host> EMAIL=<e2e member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=e2e] [PAGE=/lobby] [MSG_ID=<uuid>] [CHROME_PATH=...] \
//     node tests/e2e/link-preview-clip-live.proof.mjs
//
// PAGE is a message list (lobby, /channel/<name>, /dm/<peer>) holding a card
// whose body links a topic or message of the workspace; MSG_ID picks that
// card, else the first card in the list with link previews is used. The
// password is read from PW_FILE and never printed. Exit 0 = every step PASS.
// Screenshots: <OUT>/<1440|390>-<rows|titles>.png, numbers in result.json.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = process.env.EMAIL || readFileSync(need('EMAIL_FILE'), 'utf8').trim()
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const PAGE = process.env.PAGE || '/lobby'
const MSG_ID = process.env.MSG_ID || ''
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, page: PAGE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: !!ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
async function goto(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
      return
    } catch (e) {
      last = e
      await sleep(1500)
    }
  }
  throw last
}

/** The card (by id, else the first with previews) in the message list: its body on screen, in rows. */
const READ = (id) => {
  const pane = document.querySelector('[data-pane="msgs"]') || document
  const cards = [...pane.querySelectorAll('article.msg')]
  const card = id
    ? cards.find((c) => c.getAttribute('data-msg-id') === id)
    : cards.find((c) => c.querySelector('[data-test=link-previews]'))
  if (!card) return { found: false, n: cards.length }
  card.scrollIntoView({ block: 'center' })
  const body = card.querySelector('[data-testid=card-body]')
  const title = card.querySelector('[data-testid=card-title]')
  const box = body || title
  const previews = card.querySelector('[data-test=link-previews]')
  const inside = !!(previews && body && body.contains(previews))
  const top = box ? box.getBoundingClientRect().top : 0
  const bottoms = box ? [box.getBoundingClientRect().bottom] : [0]
  if (previews && !inside) bottoms.push(previews.getBoundingClientRect().bottom)
  const text = card.querySelector('.msg-body') || title
  const lh = text ? parseFloat(getComputedStyle(text).lineHeight) || 0 : 0
  const h = Math.round(Math.max(...bottoms) - top)
  return {
    found: true,
    id: card.getAttribute('data-msg-id'),
    h,
    lh: Math.round(lh * 10) / 10,
    rows: lh ? Math.round((h / lh) * 10) / 10 : null,
    clip: body ? body.getAttribute('data-clip') : null,
    previews: card.querySelectorAll('[data-test=link-preview]').length,
    inside,
    grip: !!card.querySelector('[data-testid=card-grip]'),
    title: !!title,
  }
}

/** The message list's mode for this tab (the session override the control writes), then a reload. */
async function setMode(p, mode) {
  await p.evaluate((m) => { try { sessionStorage.setItem('spool-card-clip-session-msgs', m) } catch { /* private */ } }, mode)
  await goto(p, BASE + PAGE)
  await p.waitForSelector('article.msg', { timeout: 30000 }).catch(() => {})
}

async function waitCard(p, id, pred, ms = 20000) {
  let last = null
  for (const start = Date.now(); Date.now() - start < ms; await sleep(400)) {
    last = await p.evaluate(READ, id).catch(() => last)
    if (last && last.found && pred(last)) break
  }
  await sleep(600)
  return (await p.evaluate(READ, id).catch(() => last)) || last
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 90000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  for (const [label, vp] of [['1440', { width: 1440, height: 900 }], ['390', { width: 390, height: 844, isMobile: true, hasTouch: true }]]) {
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport(vp)
    p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
    p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))

    await goto(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent(PAGE))
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
    step(`${label} native sign-in`, signedIn, { url: p.url().replace(BASE, '') })
    if (!signedIn) { await ctx.close(); continue }

    await setMode(p, 'rows')
    const r = await waitCard(p, MSG_ID, (x) => x.previews > 0 && !!x.clip)
    step(`${label} rows: a card with link previews is on the page`, !!(r && r.found && r.previews > 0), r)
    const id = (r && r.id) || MSG_ID
    if (r && r.found && r.previews > 0) {
      step(`${label} rows: the previews sit inside the card's clip box`, r.inside, r)
      const cap = r.lh * 5
      step(`${label} rows: text + previews fit the 5-row box`, r.h <= Math.round(cap) + 4, { ...r, cap: Math.round(cap) })
    }
    await p.screenshot({ path: `${OUT}/${label}-rows.png` })

    if (id) {
      await setMode(p, 'titles')
      const t = await waitCard(p, id, (x) => x.title)
      step(`${label} titles: the card is one line, no preview`, !!(t && t.found && t.title && t.previews === 0 && t.lh && t.h <= Math.ceil(t.lh * 1.5)), t)
      await p.screenshot({ path: `${OUT}/${label}-titles.png` })
      await setMode(p, 'rows')
    }
    await ctx.close()
  }
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', 'console', res.console.length)
  process.exitCode = failed ? 1 : 0
} finally {
  await browser.close()
}
