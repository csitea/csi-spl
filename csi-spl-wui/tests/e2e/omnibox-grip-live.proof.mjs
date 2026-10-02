// Owner, t1 (2026-10-02 21:28Z) live: the phone omnibox grip on the deployed
// WUI, signed in, 390x844 touch. The rules and the mock checks are
// tests/e2e/omnibox-grip.test.mjs; this proves the deployed bundle:
//
//   1 the docked box has the grip and starts at the bottom
//   2 a touch drag up: right under the top bar, the panes start under it
//   3 a reload keeps it at the top
//   4 a touch drag right: the bottom-right corner, narrower than the screen
//   5 a touch drag down: full width at the bottom again
//   6 CONTROL: a touch swipe on the feed scrolls it, the box stays put
//   7 the menu: a tap opens it, "Move to top" moves the box
//
// It writes NO message and no account pref: the place lives in this
// browser's localStorage, cleared at the end. Screenshots of the three
// places go to OUT. prd: run it at the e2e tenant host only (the apex is t1):
// it refuses unless the session claim t and the page host both say TENANT.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [CHANNEL=lobby] node tests/e2e/omnibox-grip-live.proof.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const CHANNEL = process.env.CHANNEL || 'lobby'
const KEY = 'spool.omnibox-phone-pos'
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

const facts = (p) => p.evaluate((key) => {
  const f = document.querySelector('form.composer.omnibox--global')
  const g = document.querySelector('[data-testid=omnibox-grip]')
  const bar = document.querySelector('[data-test=top-bar]')
  const shell = document.querySelector('.spool-shell')
  if (!f) return null
  const r = f.getBoundingClientRect()
  const gr = g ? g.getBoundingClientRect() : null
  let stored = null
  try { stored = localStorage.getItem(key) } catch { /* denied */ }
  return {
    pos: f.getAttribute('data-phone-pos'),
    box: { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width), h: Math.round(r.height) },
    grip: gr ? { cx: Math.round(gr.left + gr.width / 2), cy: Math.round(gr.top + gr.height / 2) } : null,
    barBottom: bar ? Math.round(bar.getBoundingClientRect().bottom) : null,
    shellPadTop: shell ? Math.round(parseFloat(getComputedStyle(shell).paddingTop)) : null,
    vw: innerWidth,
    vh: innerHeight,
    stored,
  }
}, KEY)

async function dragGrip(p, x, y) {
  const f = await facts(p)
  const a = { x: f.grip.cx, y: f.grip.cy }
  await p.touchscreen.touchStart(a.x, a.y)
  for (let i = 1; i <= 12; i++) {
    await p.touchscreen.touchMove(a.x + ((x - a.x) * i) / 12, a.y + ((y - a.y) * i) / 12)
    await sleep(16)
  }
  await p.touchscreen.touchEnd()
  await sleep(600)
  return facts(p)
}

async function openFeed(p) {
  await nav(p, `${BASE}/channel/${encodeURIComponent(CHANNEL)}`)
  await p.waitForSelector('[data-testid=omnibox-grip]', { timeout: 30000 })
  await sleep(2000)
}

const scrollerTop = (p) => p.evaluate(() => {
  const el = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40 && /auto|scroll/.test(getComputedStyle(e).overflowY))
  if (!el) return null
  const r = el.getBoundingClientRect()
  return { top: Math.round(el.scrollTop), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
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
  await p.evaluate((key) => { try { localStorage.removeItem(key) } catch { /* denied */ } }, KEY)
  await openFeed(p)

  const f1 = await facts(p)
  ok('1 signed in on the TENANT host; the docked box has the grip and starts at the bottom',
    Boolean(f1 && f1.grip && f1.pos === 'bottom' && f1.box.w === f1.vw && f1.box.bottom >= f1.vh - 60), { build: res.build, f1 })
  await p.screenshot({ path: join(OUT, 'grip-390-bottom.png') })

  const f2 = await dragGrip(p, 195, 140)
  await p.screenshot({ path: join(OUT, 'grip-390-top.png') })
  ok('2 touch drag up: right under the top bar, the panes start under it',
    Boolean(f2 && f2.pos === 'top' && f2.stored === 'top' && Math.abs(f2.box.top - f2.barBottom) <= 2 && Math.abs(f2.shellPadTop - f2.box.h) <= 2), f2)

  await openFeed(p)
  const f3 = await facts(p)
  ok('3 a reload keeps it at the top', Boolean(f3 && f3.pos === 'top' && Math.abs(f3.box.top - f3.barBottom) <= 2), f3)

  const f4 = await dragGrip(p, 370, 640)
  await p.screenshot({ path: join(OUT, 'grip-390-right.png') })
  ok('4 touch drag right: the bottom-right corner, narrower than the screen',
    Boolean(f4 && f4.pos === 'right' && f4.box.right === f4.vw && f4.box.left >= 40 && f4.box.bottom >= f4.vh - 60 && f4.shellPadTop === 0), f4)

  const f5 = await dragGrip(p, 160, 800)
  ok('5 touch drag down: full width at the bottom again', Boolean(f5 && f5.pos === 'bottom' && f5.box.w === f5.vw && f5.box.left === 0), f5)

  /* 6: CONTROL - only the grip takes the finger: the feed still scrolls
     (whatever scrolls in the middle pane: the lobby is a LiveFeed) */
  /* the e2e tenant's channels can be empty: then a DOM-only spacer (no post,
     gone on the next load) gives the middle pane's own scroll box room */
  if (!(await scrollerTop(p))) {
    res.spacer = await p.evaluate(() => {
      const box = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.clientHeight > 200 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      if (!box) return false
      const d = document.createElement('div')
      d.style.height = '3000px'
      d.setAttribute('data-proof', 'grip-spacer')
      box.appendChild(d)
      return box.className || box.tagName
    })
  }
  const s0 = await scrollerTop(p)
  let scroll = null
  if (s0) {
    await p.evaluate(() => {
      const el = [...document.querySelectorAll('.spool-main *')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      if (el) el.scrollTop = el.scrollHeight
    })
    await sleep(500)
    const before = await scrollerTop(p)
    await p.touchscreen.touchStart(before.x, before.y - 150)
    for (let i = 1; i <= 10; i++) {
      await p.touchscreen.touchMove(before.x, before.y - 150 + i * 30)
      await sleep(16)
    }
    await p.touchscreen.touchEnd()
    await sleep(800)
    scroll = { before: before.top, after: (await scrollerTop(p))?.top }
  }
  const f6 = await facts(p)
  ok('6 CONTROL: a touch swipe on the feed scrolls it, the box stays at the bottom',
    Boolean(scroll && scroll.after < scroll.before - 20 && f6.pos === 'bottom'), { scroll, spacer: res.spacer, pos: f6 && f6.pos })

  await p.tap('[data-testid=omnibox-grip]')
  await sleep(400)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=omnibox-grip-menu] [role=menuitemradio]')].map((b) => b.getAttribute('data-pos')))
  await p.screenshot({ path: join(OUT, 'grip-390-menu.png') })
  await p.tap('[data-testid=omnibox-grip-menu] [data-pos=top]')
  await sleep(500)
  const f7 = await facts(p)
  ok('7 the menu: a tap opens top / right / bottom; "Move to top" moves the box', items.length === 3 && f7.pos === 'top', { items, pos: f7.pos })
} finally {
  if (p) await p.evaluate((key) => { try { localStorage.removeItem(key) } catch { /* denied */ } }, KEY).catch(() => {})
  await browser.close()
}
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 2))
console.log(failed ? `FAIL: ${failed}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed ? 1 : 0)
