// CLE-35065 live proof (owner, prd t1 topics 95adf832 + fd1e5be4): on a phone
//   - a message from the viewer's today shows only HH:MM, read on the
//     VIEWER's clock (TZ, default Europe/Helsinki: the owner's), other days
//     keep their date - checked against every card's data-ts
//   - card text sits <= 6 px from the left and the right window edge, the
//     avatar at the same inset, the header on one line
// on the lobby, the first topic, the first DM and the first issue with
// comments. Writes OUT/<surface>-<w>.png and OUT/results.json.
//
//   BASE=https://<tenant>.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [TZ_VIEW=Europe/Helsinki] [WIDTHS=360x740,390x844,820x1180]
//     [EXPECT=after] [PUPPETEER_CORE=<path>] node tests/e2e/card-edge-inset-live.proof.mjs
//
// READ-ONLY: it signs in, navigates and measures; it never posts. On prd run
// it at the e2e tenant's host, never the apex (t1's host, SPL-959).
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
const TZ_VIEW = process.env.TZ_VIEW || 'Europe/Helsinki'
const WIDTHS = (process.env.WIDTHS || '360x740,390x844,820x1180').split(',').map((s) => s.split('x').map(Number))
const EXPECT = process.env.EXPECT || ''
const MAX = 6
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tz: TZ_VIEW, expect: EXPECT, checks: [], surfaces: {} }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: pass, ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

/* every visible card: text box, avatar, header lines, and its time against data-ts */
const facts = (p) => p.evaluate(() => {
  const vw = document.documentElement.clientWidth
  const px = (el, k) => parseFloat(getComputedStyle(el)[k]) || 0
  const pad = (n) => String(n).padStart(2, '0')
  const day = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
  const now = new Date()
  const cards = [...document.querySelectorAll('article.msg[data-msg-id]')].filter((el) => {
    const r = el.getBoundingClientRect()
    return el.getClientRects().length && r.width > 0 && r.bottom > 0 && r.top < innerHeight
  })
  return {
    vw,
    scrollW: document.scrollingElement.scrollWidth,
    url: location.pathname + location.search,
    cards: cards.map((a) => {
      const body = a.querySelector('.msg-body')
      const b = body && body.getBoundingClientRect()
      const av = a.querySelector(':scope > .avatar')
      const meta = a.querySelector('.msg-meta')
      const items = meta ? [...meta.children].flatMap((el) => (getComputedStyle(el).display === 'contents' ? [...el.children] : [el])) : []
      const mids = items.filter((el) => !el.classList.contains('msg-reactions') && el.getClientRects().length)
        .map((el) => { const r = el.getBoundingClientRect(); return r.top + r.height / 2 })
      const ts = a.getAttribute('data-ts')
      const d = ts ? new Date(ts) : null
      const time = a.querySelector('.msg-time')?.textContent.trim() || ''
      return {
        textL: b ? Math.round((b.left + px(body, 'paddingLeft')) * 10) / 10 : null,
        textR: b ? Math.round((vw - (b.right - px(body, 'paddingRight'))) * 10) / 10 : null,
        avatarL: av ? Math.round(av.getBoundingClientRect().left * 10) / 10 : null,
        headRows: mids.length ? 1 + mids.filter((m, i) => i > 0 && m - mids[0] > 12).length : 0,
        time,
        today: d ? day(d) === day(now) : null,
        localHm: d ? `${pad(d.getHours())}:${pad(d.getMinutes())}` : null,
      }
    }),
  }
})

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'] })
try {
  const p = await browser.newPage()
  await p.emulateTimezone(TZ_VIEW)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(1500)
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  /* the routes to measure, found on the desktop page */
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await sleep(1500)
  const found = await p.evaluate(() => {
    const hrefs = [...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href'))
    const task = document.querySelector('article.msg[data-task-id]')?.getAttribute('data-task-id')
    return { dm: hrefs.find((h) => /^\/dm\//.test(h)) || null, topic: task ? '/t/' + task : null }
  })
  const surfaces = [['lobby', '/lobby'], ['topic', found.topic], ['dm', found.dm], ['issue', '/issues']].filter(([, u]) => u)
  console.log('build', JSON.stringify(res.build), 'tz', TZ_VIEW, 'surfaces', JSON.stringify(surfaces))

  for (const [w, h] of WIDTHS) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    for (const [name, url] of surfaces) {
      await p.goto(BASE + url, { waitUntil: 'networkidle2', timeout: 60000 })
      await sleep(2000)
      if (name === 'issue') {
        for (const row of (await p.$$('[data-test=issues-row]')).slice(0, 12)) {
          await ((await row.$('.issues-c-key')) ?? row).click().catch(() => {})
          await sleep(1500)
          if (await p.$('article.msg[data-test=issues-comment]')) break
          await p.goto(BASE + url, { waitUntil: 'networkidle2', timeout: 60000 })
          await sleep(1000)
        }
      }
      const f = await facts(p)
      const tag = `${w}px ${name}`
      res.surfaces[tag] = f
      await p.screenshot({ path: join(OUT, `${name}-${w}.png`) })
      const cards = f.cards.filter((c) => c.textL != null)
      if (!cards.length) { console.log(`  --   ${tag}: no card with text on screen (${f.url})`); continue }
      const L = cards.map((c) => c.textL); const R = cards.map((c) => c.textR)
      const A = cards.map((c) => c.avatarL).filter((x) => x != null)
      ok(`${tag}: text <= ${MAX}px from the left`, Math.min(...L) >= 0 && Math.max(...L) <= MAX, [Math.min(...L), Math.max(...L)])
      ok(`${tag}: text <= ${MAX}px from the right`, Math.min(...R) >= 0 && Math.max(...R) <= MAX, [Math.min(...R), Math.max(...R)])
      ok(`${tag}: avatar at the text inset`, A.every((x) => x >= 0 && x <= MAX), A.length ? [Math.min(...A), Math.max(...A)] : null)
      ok(`${tag}: one header line`, cards.every((c) => c.headRows === 1), cards.map((c) => c.headRows))
      ok(`${tag}: no sideways scroll`, f.scrollW <= f.vw, [f.scrollW, f.vw])
      const timed = f.cards.filter((c) => c.today != null && c.time)
      const wrong = timed.filter((c) => (c.today ? !c.time.startsWith(c.localHm) : !/^\d{2}(\d{2})?-\d{2}/.test(c.time)))
      ok(`${tag}: today = HH:MM on the ${TZ_VIEW} clock, other days keep the date`, wrong.length === 0,
        { today: timed.filter((c) => c.today).map((c) => c.time).slice(0, 4), older: timed.filter((c) => !c.today).map((c) => c.time).slice(0, 3), wrong })
    }
  }
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
const bad = res.checks.filter((c) => !c.ok)
console.log(`\ncard-edge-inset-live: ${res.checks.length - bad.length}/${res.checks.length} passed`)
process.exit(EXPECT === 'after' && bad.length ? 1 : 0)
