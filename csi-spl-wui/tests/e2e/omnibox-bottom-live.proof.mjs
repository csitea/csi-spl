// Topic c6994436 lane B live: Settings -> Behaviour "Omnibox position" on the
// deployed WUI. Position only - the four order x position layouts and every
// order check are message-order-live.proof.mjs (lane A). Chosen with the
// page's own radio, read back from the session claim after a reload, then:
//
//   top     1440: the box is in the top bar, the bottom dock is empty
//   bottom  1440: the box is in the dock under the MIDDLE pane only, flush
//                 with the window bottom, the feed ends above it; the @ list
//                 opens UPWARD inside the window; the top bar's search icon
//                 puts "/search " in the bottom box
//   either  820:  the phone dock (SPL-1005), the desktop dock empty
//
// It writes NO message (the @ is typed and cleared, never sent): only the
// test account's composer_position, restored to what it was (null = never
// picked) at the end. prd: run it at the e2e tenant host only (the apex is
// t1): it refuses unless the session claim t and the page host both say
// TENANT.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [CHANNEL=lobby] node tests/e2e/omnibox-bottom-live.proof.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const CHANNEL = process.env.CHANNEL || 'lobby'
mkdirSync(OUT, { recursive: true })

const TA = 'form.composer.omnibox--global textarea'
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

const claims = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  const c = (s && s.claims) || {}
  return { t: c.t || '', composer_position: c.composer_position ?? null }
})

/* the page's own radio; an already-checked radio fires no change, so step
   through the other value first and the stored value is a real write */
async function pick(p, value) {
  await nav(p, `${BASE}/settings/behaviour`)
  const sel = `[data-test="composer_position-${value}"]`
  await p.waitForSelector(sel, { timeout: 20000 })
  await sleep(600)
  if (await p.$eval(sel, (el) => el.checked === true)) {
    await p.click(`[data-test="composer_position-${value === 'top' ? 'bottom' : 'top'}"]`)
    await sleep(1200)
  }
  await p.click(sel)
  await sleep(1200)
}

const measure = (p) => p.evaluate(() => {
  const r = (el) => {
    if (!el || !el.getClientRects().length) return null
    const b = el.getBoundingClientRect()
    return { l: Math.round(b.left), t: Math.round(b.top), r: Math.round(b.right), b: Math.round(b.bottom) }
  }
  const box = document.querySelector('[data-test=top-bar-omnibox]')
  const dock = document.getElementById('spl-omnibox-dock')
  const feed = [...document.querySelectorAll('.spool-main .feed-body, .spool-main [role=feed]')].find((el) => el.getClientRects().length)
  return {
    vw: window.innerWidth,
    vh: window.innerHeight,
    inBar: Boolean(box && box.closest('header.top-bar')),
    inDock: Boolean(box && dock && dock.contains(box)),
    boxes: document.querySelectorAll('form.composer.omnibox--global').length,
    phoneDock: Boolean(document.querySelector('form.composer--dock')),
    search: Boolean(r(document.querySelector('[data-test=top-bar-search]'))),
    dock: r(dock),
    main: r(document.querySelector('.spool-main')),
    rail: r(document.querySelector('.spool-shell > .sidebar')),
    feed: r(feed),
    docScroll: document.scrollingElement.scrollHeight - window.innerHeight,
  }
})

async function openFeed(p, vp) {
  await p.setViewport(vp)
  await nav(p, `${BASE}/channel/${encodeURIComponent(CHANNEL)}`)
  await p.waitForSelector(TA, { timeout: 30000 })
  await sleep(2000)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let original = null
let p
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, `${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`)
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(1500)
  original = await claims(p)
  const host = new URL(BASE).hostname.split('.')[0]
  if (original.t !== TENANT || host !== TENANT) {
    console.error(`FATAL refusing: claim t=${original.t} host=${host}, both must be ${TENANT}`)
    process.exit(3)
  }
  ok('signed in on the TENANT host; the session carries composer_position', 'composer_position' in original, original)

  for (const pos of ['top', 'bottom']) {
    await pick(p, pos)
    await p.reload({ waitUntil: 'networkidle2' })
    await sleep(800)
    const c = await claims(p)
    ok(`${pos}: stored on the account (claim after a reload)`, c.composer_position === pos, c)

    await openFeed(p, { width: 1440, height: 900 })
    const m = await measure(p)
    await p.screenshot({ path: join(OUT, `${pos}-1440.png`) })
    if (pos === 'top') {
      ok('top @1440: the box is in the top bar, the dock is empty, no bar search icon',
        m.inBar && !m.inDock && m.dock === null && !m.search && m.boxes === 1, m)
    } else {
      ok('bottom @1440: the box is in the dock under the MIDDLE pane only, flush with the bottom',
        m.inDock && !m.inBar && m.boxes === 1 && Boolean(m.dock && m.main && m.dock.l >= m.main.l - 1 && m.dock.r <= m.main.r + 1
          && Math.abs(m.dock.b - m.vh) <= 1 && (!m.rail || m.dock.l >= m.rail.r - 1)), m)
      ok('bottom @1440: the feed ends above the dock (nothing under the box)', Boolean(m.feed && m.dock && m.feed.b <= m.dock.t + 1), { feed: m.feed, dock: m.dock })
      /* @ opens the picker UPWARD; typed and cleared, never sent */
      await p.$eval(TA, (el) => { el.focus(); el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
      await p.type(TA, '@')
      await sleep(800)
      const at = await p.evaluate(() => {
        const l = document.querySelector('[data-test=mention-list]')
        const f = document.querySelector('form.composer.omnibox--global .omnibox-field')
        if (!l || !f) return null
        const a = l.getBoundingClientRect(), b = f.getBoundingClientRect()
        return { listTop: Math.round(a.top), listBottom: Math.round(a.bottom), fieldTop: Math.round(b.top) }
      })
      await p.screenshot({ path: join(OUT, 'bottom-1440-mention.png') })
      ok('bottom @1440: the @ list opens UP over the feed, inside the window', Boolean(at && at.listBottom <= at.fieldTop + 1 && at.listTop >= 0), at)
      await p.keyboard.press('Escape')
      await p.$eval(TA, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
      await p.click('[data-test=top-bar-search]')
      await sleep(400)
      const s = await p.evaluate((sel) => ({ v: document.querySelector(sel).value, focused: document.activeElement === document.querySelector(sel) }), TA)
      ok('bottom @1440: the top bar search icon puts "/search " in the bottom box', s.v === '/search ' && s.focused, s)
      await p.$eval(TA, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })); el.blur() })
    }
    ok(`${pos} @1440: the page never scrolls`, m.docScroll <= 0, { docScroll: m.docScroll })

    await openFeed(p, { width: 820, height: 1180, isMobile: true, hasTouch: true })
    const ph = await measure(p)
    await p.screenshot({ path: join(OUT, `${pos}-820.png`) })
    ok(`${pos} @820: the phone dock, the desktop dock empty`, ph.phoneDock && !ph.inDock && ph.dock === null, { phoneDock: ph.phoneDock, dock: ph.dock })
  }
} finally {
  /* put the account back as it was (null = never picked) */
  if (p && original) {
    const back = await p.evaluate(async (v) => {
      const r = await fetch('/api/v1/auth/preferences', {
        method: 'PUT',
        credentials: 'include',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ composer_position: v }),
      })
      return r.status
    }, original.composer_position).catch((e) => String(e))
    console.log('restored composer_position', JSON.stringify(original.composer_position), back)
    res.restored = { composer_position: original.composer_position, status: back }
  }
  await browser.close()
}
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 2))
console.log(failed ? `FAIL: ${failed}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed ? 1 : 0)
