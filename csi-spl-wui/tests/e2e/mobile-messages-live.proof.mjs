// SPL-991 (lane M3) - the phone message area on a DEPLOYED WUI + hub, signed
// in. READ-ONLY: it long-presses a card and closes the sheet again; it never
// types into the composer, never sends, never picks a menu item.
//
// Per width (default 390x844 and 820x1180, touch emulation) on /lobby:
//   1 the composer is docked: full width, bottom on the window's bottom edge,
//     Send / Attach / Camera >= 44 px
//   2 a long press on a card opens the message menu as a bottom sheet with
//     44 px items and Reply first; the topic did not open
//   3 a tap on the dimmed page closes it
//   4 every in-view kind badge (26x18 drawn) is hit across a 42 px square (its ::before)
// and writes OUT/mobile-messages-<w>.png (+ -sheet.png) and OUT/results.json.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [WIDTHS=390x844,820x1180] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/mobile-messages-live.proof.mjs
//
// On prd run it only at the e2e tenant's host e2e.<domain>, never the apex
// (the apex is t1's host, SPL-959). The password is read from PW_FILE and
// never printed. Exit 0 = every check passed.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const WIDTHS = (process.env.WIDTHS || '390x844,820x1180').split(',').map((s) => s.split('x').map(Number))
const TAP = 44
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, checks: [] }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: pass, ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
  /* the writes-nowhere guard still checks where it is: the page host's tenant */
  res.host = new URL(p.url()).hostname
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'host', res.host)

  for (const [w, h] of WIDTHS) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
    await p.waitForSelector('article.msg[data-msg-id]', { timeout: 60000 })
    await sleep(1500)
    const c = await p.evaluate(() => {
      const f = document.querySelector('form.composer.omnibox--global')
      if (!f) return null
      const r = f.getBoundingClientRect()
      const box = (sel) => { const el = f.querySelector(sel); if (!el) return null; const b = el.getBoundingClientRect(); return [Math.round(b.width), Math.round(b.height)] }
      return { docked: f.getAttribute('data-docked') === 'true', left: Math.round(r.left), width: Math.round(r.width), bottom: Math.round(r.bottom), vw: innerWidth, vh: innerHeight, send: box('[data-testid=send]'), attach: box('[data-testid=attach]'), camera: box('[data-testid=attach-camera]') }
    })
    ok(`${w}px 1 composer docked at the bottom, 44 px controls`,
      Boolean(c && c.docked && c.left === 0 && c.width === c.vw && Math.abs(c.bottom - c.vh) <= 1
        && [c.send, c.attach, c.camera].every((b) => b && b[0] >= TAP && b[1] >= TAP)), c)
    await p.screenshot({ path: join(OUT, `mobile-messages-${w}.png`) })
    /* the kind badge draws 26x18; its 44 px hit area is a ::before - probe it */
    const kind = await p.evaluate(() => {
      /* every in-view badge (a sheet or the dock may cover the fold) */
      const all = [...document.querySelectorAll('[data-testid=kind-badge-btn]')].filter((el) => { const r = el.getBoundingClientRect(); return r.top > 130 && r.bottom < innerHeight - 130 })
      if (!all.length) return null
      const pts = [[-21, -21], [21, -21], [-21, 21], [21, 21], [0, -21], [0, 21], [-21, 0], [21, 0]]
      const out = all.map((b) => {
        const r = b.getBoundingClientRect()
        const cx = r.left + r.width / 2
        const cy = r.top + r.height / 2
        return pts.filter(([dx, dy]) => !document.elementFromPoint(cx + dx, cy + dy)?.closest('[data-testid=kind-badge-btn]'))
          .map(([dx, dy]) => { const el = document.elementFromPoint(cx + dx, cy + dy); return `${dx},${dy}:${el ? el.tagName.toLowerCase() + '.' + String(el.className || '').split(' ')[0] : 'none'}` })
      })
      return { badges: all.length, missed: out.reduce((a, l) => a + l.length, 0), by: [...new Set(out.flat())].slice(0, 8) }
    })
    ok(`${w}px 4 every in-view kind badge answers a finger across a 42 px square`,
      Boolean(kind && kind.missed === 0), kind)

    const card = await p.evaluate(() => {
      const row = [...document.querySelectorAll('article.msg[data-msg-id]')]
        .find((el) => { const r = el.getBoundingClientRect(); return r.height > 40 && r.top > 120 && r.bottom < innerHeight - 120 })
      if (!row) return null
      const r = row.getBoundingClientRect()
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + Math.min(r.height / 2, 40)) }
    })
    const url0 = p.url()
    if (card) {
      await p.touchscreen.touchStart(card.x, card.y)
      await sleep(800)
      await p.touchscreen.touchEnd()
      await sleep(400)
    }
    const m = await p.evaluate(() => {
      const el = document.querySelector('[data-testid=msg-menu]')
      if (!el) return null
      const r = el.getBoundingClientRect()
      const items = [...el.querySelectorAll('[role=menuitem]')]
      return { sheet: el.classList.contains('touch-sheet'), width: Math.round(r.width), bottom: Math.round(r.bottom), vw: innerWidth, vh: innerHeight, minItem: Math.min(...items.map((b) => Math.round(b.getBoundingClientRect().height))), ids: items.map((b) => b.getAttribute('data-testid')) }
    })
    ok(`${w}px 2 long press: menu as a bottom sheet, 44 px items, Reply first, topic not opened`,
      Boolean(card && m && m.sheet && m.width === m.vw && Math.abs(m.bottom - m.vh) <= 1 && m.minItem >= TAP
        && m.ids[0] === 'msg-menu-reply' && p.url() === url0), { card, m, url: p.url() })
    if (m) await p.screenshot({ path: join(OUT, `mobile-messages-${w}-sheet.png`) })
    await p.touchscreen.tap(Math.round(w / 2), 30)
    await sleep(400)
    const gone = await p.evaluate(() => !document.querySelector('[data-testid=msg-menu]'))
    ok(`${w}px 3 a tap on the dimmed page closes the sheet`, gone && p.url() === url0, { gone, url: p.url() })
  }
} finally {
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
  await browser.close()
}
const failed = res.checks.filter((c) => !c.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed.length ? 1 : 0)
