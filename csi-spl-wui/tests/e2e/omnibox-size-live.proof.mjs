// Owner, t1 (2026-10-02 21:53Z) live: "it should be possible to resize it" -
// the phone omnibox's size handle on the deployed WUI, signed in, 390x844
// touch. The rules and the mock checks are tests/e2e/omnibox-grip.test.mjs;
// this proves the deployed bundle:
//
//   1 the docked box has the size handle; a touch drag up makes the field
//     taller at the bottom
//   2 LIMIT: past the top it stops at half the room under the top bar
//   3 a reload keeps the size
//   4 CONTROL: with the large box a swipe on the feed still scrolls it
//   5 at the top: a drag down grows it, back up is one line
//   6 in the corner: drag left is wider (48 px of the feed kept), drag right
//     is narrower (280 px at least)
//   7 the menu (a tap on the size handle): Small / Medium / Large
//
// It writes NO message and no account pref: place and size live in this
// browser's localStorage, cleared at the end. Screenshots of small and large
// at the bottom and in the corner go to OUT. prd: the e2e tenant host only
// (the apex is t1): it refuses unless the session claim t and the page host
// both say TENANT.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [CHANNEL=lobby] node tests/e2e/omnibox-size-live.proof.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const CHANNEL = process.env.CHANNEL || 'lobby'
const KEYS = ['spool.omnibox-phone-pos', 'spool.omnibox-phone-size']
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, checks: [] }
let failed = 0
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: pass, ev })
  if (!pass) failed++
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

/* docker veth churn kills Chrome navigations now and then (ERR_NETWORK_CHANGED) */
async function nav(p, url) {
  for (let i = 0; i < 4; i++) {
    try { return await p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }) } catch (e) {
      if (!String(e).includes('ERR_NETWORK_CHANGED') || i === 3) throw e
      await sleep(1500)
    }
  }
}

const clear = (p) => p.evaluate((keys) => { try { for (const k of keys) localStorage.removeItem(k) } catch { /* denied */ } }, KEYS)

const facts = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.omnibox--global')
  const g = document.querySelector('[data-testid=omnibox-grip]')
  const z = document.querySelector('[data-testid=omnibox-size]')
  const bar = document.querySelector('[data-test=top-bar]')
  const shell = document.querySelector('.spool-shell')
  if (!f) return null
  const r = f.getBoundingClientRect()
  const gr = g ? g.getBoundingClientRect() : null
  const zr = z ? z.getBoundingClientRect() : null
  const ta = f.querySelector('textarea')
  let size = null
  try { size = JSON.parse(localStorage.getItem('spool.omnibox-phone-size') || 'null') } catch { /* denied */ }
  return {
    pos: f.getAttribute('data-phone-pos'),
    box: { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width), h: Math.round(r.height) },
    grip: gr ? { cx: Math.round(gr.left + gr.width / 2), cy: Math.round(gr.top + gr.height / 2) } : null,
    size: zr ? { cx: Math.round(zr.left + zr.width / 2), cy: Math.round(zr.top + zr.height / 2), w: Math.round(zr.width), h: Math.round(zr.height) } : null,
    field: ta ? Math.round(ta.getBoundingClientRect().height) : null,
    barBottom: bar ? Math.round(bar.getBoundingClientRect().bottom) : null,
    shellPadTop: shell ? Math.round(parseFloat(getComputedStyle(shell).paddingTop)) : null,
    vw: innerWidth,
    vh: innerHeight,
    stored: size,
  }
})
const room = (f) => f.vh - f.barBottom

async function drag(p, handle, x, y) {
  const f = await facts(p)
  const a = { x: f[handle].cx, y: f[handle].cy }
  await p.touchscreen.touchStart(a.x, a.y)
  for (let i = 1; i <= 12; i++) {
    await p.touchscreen.touchMove(a.x + ((x - a.x) * i) / 12, a.y + ((y - a.y) * i) / 12)
    await sleep(16)
  }
  await p.touchscreen.touchEnd()
  await sleep(600)
  return facts(p)
}

async function pick(p, sel) {
  await p.tap('[data-testid=omnibox-grip]')
  await sleep(400)
  await p.tap(`[data-testid=omnibox-grip-menu] ${sel}`)
  await sleep(600)
  return facts(p)
}

async function openFeed(p) {
  await nav(p, `${BASE}/channel/${encodeURIComponent(CHANNEL)}`)
  await p.waitForSelector('[data-testid=omnibox-size]', { timeout: 30000 })
  await sleep(2000)
}

const scrollerTop = (p) => p.evaluate(() => {
  const el = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40 && /auto|scroll/.test(getComputedStyle(e).overflowY))
  if (!el) return null
  const r = el.getBoundingClientRect()
  return { top: Math.round(el.scrollTop), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + 20) }
})

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let p
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport(PHONE)
  await nav(p, `${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`)
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.spool-shell'), { timeout: 60000 })
  await sleep(1500)
  const t = await p.evaluate(() => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')?.claims?.t || '')
  const host = new URL(BASE).hostname.split('.')[0]
  if (t !== TENANT || host !== TENANT) {
    console.error(`FATAL refusing: claim t=${t} host=${host}, both must be ${TENANT}`)
    process.exit(3)
  }
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  await clear(p)
  await openFeed(p)

  const f0 = await facts(p)
  await p.screenshot({ path: join(OUT, 'size-390-bottom-small.png') })
  const f1 = await drag(p, 'size', f0.size.cx, f0.size.cy - 250)
  ok('1 signed in on the TENANT host; the size handle is on the box; a drag up makes the field taller',
    Boolean(f0.pos === 'bottom' && f0.size && f0.size.w >= 44 && f1.field >= f0.field + 200 && f1.stored?.bottom > 0), { build: res.build, f0: f0.field, f1: f1.field, stored: f1.stored })

  const f2 = await drag(p, 'size', f1.size.cx, 0)
  await p.screenshot({ path: join(OUT, 'size-390-bottom-large.png') })
  ok('2 LIMIT: past the top it stops at half the room under the top bar',
    Boolean(f2.stored?.bottom === 0.5 && Math.abs(f2.field - room(f2) / 2) <= 3 && f2.box.top > f2.barBottom + 100), { field: f2.field, room: room(f2), box: f2.box })

  await openFeed(p)
  const f3 = await facts(p)
  ok('3 a reload keeps the size', Math.abs(f3.field - f2.field) <= 2, { before: f2.field, after: f3.field })

  /* 4: CONTROL. The e2e tenant's channels can be empty: a DOM-only spacer
     (no post, gone on the next load) gives the middle pane room to scroll */
  if (!(await scrollerTop(p))) {
    res.spacer = await p.evaluate(() => {
      const box = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.clientHeight > 100 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      if (!box) return false
      const d = document.createElement('div')
      d.style.height = '3000px'
      d.setAttribute('data-proof', 'size-spacer')
      box.appendChild(d)
      return box.className || box.tagName
    })
  }
  let scroll = null
  if (await scrollerTop(p)) {
    await p.evaluate(() => {
      const el = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      if (el) el.scrollTop = el.scrollHeight
    })
    await sleep(500)
    const before = await scrollerTop(p)
    await p.touchscreen.touchStart(before.x, before.y)
    for (let i = 1; i <= 8; i++) {
      await p.touchscreen.touchMove(before.x, before.y + i * 25)
      await sleep(16)
    }
    await p.touchscreen.touchEnd()
    await sleep(800)
    scroll = { before: before.top, after: (await scrollerTop(p))?.top }
  }
  const f4 = await facts(p)
  ok('4 CONTROL: with the large box a swipe on the feed still scrolls it, the size stays',
    Boolean(scroll && scroll.after < scroll.before - 20 && Math.abs(f4.field - f3.field) <= 2), { scroll, spacer: res.spacer })

  const f5a = await pick(p, '[data-pos=top]')
  const f5b = await drag(p, 'size', f5a.size.cx, f5a.size.cy + 200)
  await p.screenshot({ path: join(OUT, 'size-390-top-taller.png') })
  const f5c = await drag(p, 'size', f5b.size.cx, f5b.size.cy - 400)
  ok('5 at the top: a drag down grows it (the panes start under it), back up is one line',
    Boolean(f5a.pos === 'top' && f5b.field >= f5a.field + 150 && Math.abs(f5b.shellPadTop - f5b.box.h) <= 2 && f5c.stored?.top === 0 && f5c.field <= 50),
    { a: f5a.field, b: f5b.field, c: f5c.field })

  const f6a = await pick(p, '[data-pos=right]')
  const f6b = await drag(p, 'size', 0, f6a.size.cy)
  await p.screenshot({ path: join(OUT, 'size-390-right-large.png') })
  const f6c = await drag(p, 'size', f6b.size.cx + 380, f6b.size.cy)
  await p.screenshot({ path: join(OUT, 'size-390-right-small.png') })
  ok('6 in the corner: left is wider (48 px of the feed kept), right is narrower (280 px at least)',
    Boolean(f6a.pos === 'right' && f6b.box.w === f6b.vw - 48 && f6b.box.right === f6b.vw && Math.abs(f6c.box.w - 280) <= 1), { a: f6a.box, b: f6b.box, c: f6c.box })

  await p.tap('[data-testid=omnibox-size]')
  await sleep(400)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=omnibox-grip-menu] [data-size]')].map((b) => b.getAttribute('data-size')))
  await p.screenshot({ path: join(OUT, 'size-390-menu.png') })
  await p.tap('[data-testid=omnibox-grip-menu] [data-size=large]')
  await sleep(500)
  const f7a = await facts(p)
  const f7b = await pick(p, '[data-pos=bottom]')
  const f7c = await pick(p, '[data-size=small]')
  ok('7 the menu from the size handle: Small / Medium / Large set it',
    Boolean(items.join() === 'small,medium,large' && f7a.box.w === f7a.vw - 48 && f7b.field > 300 && f7c.field <= 50), { items, a: f7a.box.w, b: f7b.field, c: f7c.field })
} finally {
  if (p) await clear(p).catch(() => {})
  await browser.close()
}
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 2))
console.log(failed ? `FAIL: ${failed}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed ? 1 : 0)
