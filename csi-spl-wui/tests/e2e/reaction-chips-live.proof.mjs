// SPL-1007 live proof (owner, prd t1 topic 70c82b54): on a phone the reaction
// chips are half as big and sit right next to the Add-emoji ("set emoji")
// icon, 3 px after it on the header line; a message from today shows only its
// time. Per width it finds the first in-view card with reactions on /lobby and
// measures: the Add-emoji button and glyph, the first chip's pill (height,
// glyph font size), its gap after the glyph, whether it shares the glyph's
// line, and the card's time text. It writes a header close-up per width
// (OUT/reaction-chips-<w>.png) and OUT/results.json.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [WIDTHS=390x844,820x1180,1440x900] [EXPECT=after]
//     [REACT=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/reaction-chips-live.proof.mjs
//
// READ-ONLY unless REACT=1 and no card in view has a reaction: it then adds
// ONE reaction to the first in-view card, and only when the session's tenant
// AND the page host's tenant are TENANT. On prd run it only at the e2e
// tenant's host, never the apex (t1's host, SPL-959). The password is read
// from PW_FILE and never printed. Without EXPECT it measures (exit 0); with
// EXPECT=after every phone width must pass the SPL-1007 checks.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const WIDTHS = (process.env.WIDTHS || '390x844,820x1180,1440x900').split(',').map((s) => s.split('x').map(Number))
const EXPECT = process.env.EXPECT || ''
const TAP = 44
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, expect: EXPECT, checks: [], widths: {} }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: pass, ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

/* the first in-view card with a reaction chip: its header geometry */
const facts = (p) => p.evaluate(() => {
  const rnd = (n) => Math.round(n * 10) / 10
  const box = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: rnd(b.left), y: rnd(b.top), w: rnd(b.width), h: rnd(b.height) } }
  const rows = [...document.querySelectorAll('article.msg[data-msg-id]')]
    .filter((el) => { const r = el.getBoundingClientRect(); return r.top > 60 && r.bottom < innerHeight - 60 })
  const row = rows.find((el) => el.querySelector('[data-testid=msg-reaction]'))
  if (!row) return { found: false, cards: rows.length }
  const btn = row.querySelector('[data-testid=msg-emoji-btn]')
  const glyph = btn && btn.querySelector('svg')
  const chip = row.querySelector('[data-testid=msg-reaction]')
  const time = row.querySelector('.msg-time')
  const g = box(glyph); const c = box(chip); const t = box(time)
  const chipGlyph = chip && chip.querySelector('span')
  /* what a finger lands on: the 44 px square around the target's centre */
  const hits = (el) => {
    if (!el) return false
    const b = el.getBoundingClientRect(); const cx = b.x + b.width / 2; const cy = b.y + b.height / 2
    return [[-21, -21], [21, -21], [-21, 21], [21, 21]].every(([dx, dy]) => { const h = document.elementFromPoint(cx + dx, cy + dy); return !!h && (h === el || el.contains(h)) })
  }
  const target = chip && chip.closest('button')
  const r = row.getBoundingClientRect()
  return {
    found: true,
    id: row.getAttribute('data-msg-id'),
    vw: innerWidth,
    card: { top: rnd(r.top), height: rnd(r.height) },
    button: box(btn),
    glyph: g,
    chip: c,
    chipFont: chipGlyph ? parseFloat(getComputedStyle(chipGlyph).fontSize) : null,
    chips: row.querySelectorAll('[data-testid=msg-reaction]').length,
    gap: g && c ? rnd(c.x - (g.x + g.w)) : null,
    sameLine: g && c ? Math.abs((c.y + c.h / 2) - (g.y + g.h / 2)) <= 4 : null,
    timeGap: g && t ? rnd(g.x - (t.x + t.w)) : null,
    time: time ? time.textContent.trim() : '',
    timeTitle: time ? time.getAttribute('title') || '' : '',
    btnHit44: hits(btn),
    chipTarget: target ? { testid: target.getAttribute('data-testid'), hit44: hits(target), ...box(target) } : null,
    scrollW: document.scrollingElement.scrollWidth,
  }
})

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
})
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(2000)
  res.host = new URL(p.url()).hostname
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'host', res.host)

  for (const [w, h] of WIDTHS) {
    const phone = w <= 820
    await p.setViewport({ width: w, height: h, isMobile: phone, hasTouch: phone, deviceScaleFactor: 2 })
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
    await p.waitForSelector('article.msg[data-msg-id]', { timeout: 60000 })
    await sleep(1500)
    let f = await facts(p)
    if (!f.found && process.env.REACT === '1') {
      /* nothing is written unless BOTH the claim and the page host are TENANT */
      const where = await p.evaluate(() => {
        const g = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties
        const s = g && g.$pinia && g.$pinia.state.value.session
        const pub = (g && g.$config && g.$config.public) || {}
        const hosts = String(pub.tenantHosts || '0') === '1'
        const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
        const hn = location.hostname.toLowerCase()
        const page = hn === site ? String(pub.tenant || '') : hn.endsWith('.' + site) ? hn.slice(0, -site.length - 1) : '?'
        return { claim: String(s?.claims?.t || ''), hosts, page }
      }).catch(() => null)
      const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
      ok('REACT: the session AND the page host are in TENANT before anything is written', inTenant, where)
      if (inTenant) {
        await p.click('article.msg[data-msg-id] [data-testid=msg-emoji-btn]')
        await sleep(800)
        await p.click('[data-testid=emoji-picker] .emoji-picker__glyph')
        await sleep(2500)
        f = await facts(p)
      }
    }
    res.widths[w] = f
    console.log(`${w}px`, JSON.stringify(f))
    if (f.found) {
      const top = Math.max(0, f.card.top - 6)
      await p.screenshot({ path: join(OUT, `reaction-chips-${w}.png`), clip: { x: 0, y: top, width: w, height: Math.min(f.card.height + 12, 120) } })
    }
    await p.screenshot({ path: join(OUT, `reaction-chips-${w}-page.png`) })
    if (EXPECT === 'after' && phone) {
      ok(`${w}px chip pill half size (<= 24 px tall, glyph <= 12 px)`, Boolean(f.found && f.chip.h <= 24 && f.chipFont <= 12), { chip: f.chip, font: f.chipFont })
      ok(`${w}px first chip 3 px after the Add-emoji glyph, on its line`, Boolean(f.found && Math.abs(f.gap - 3) <= 1 && f.sameLine), { gap: f.gap, sameLine: f.sameLine })
      ok(`${w}px Add-emoji glyph ~5 px after the time`, Boolean(f.found && Math.abs(f.timeGap - 5) <= 2), { timeGap: f.timeGap })
      ok(`${w}px the chips' tap target is a 44 px square`, Boolean(f.found && f.btnHit44 && f.chipTarget && f.chipTarget.hit44 && f.chipTarget.h >= TAP), { btn: f.btnHit44, target: f.chipTarget })
      ok(`${w}px no sideways scroll`, Boolean(f.found && f.scrollW <= f.vw), { scrollW: f.scrollW, vw: f.vw })
    }
  }
} finally {
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
  await browser.close()
}
const failed = res.checks.filter((c) => !c.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed.length ? 1 : 0)
