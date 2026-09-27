// SPL-1005 - live proof, signed in, against a DEPLOYED WUI: on phones the
// floating GO at the middle of the right edge is gone, the docked composer's
// bottom-right Send is the GO (go icon, accent, >= 44 px) on every level, and
// `/search <q>` typed in the dock opens /search?q= from levels 1, 2 and 3.
// READ ONLY: it searches and never sends a message.
//
//   per width 360 / 390 / 820 (touch):
//     1 level 1 (/): no floating GO; the docked GO bottom right
//     2 level 2 (CHANNEL): the same
//     3 level 3 (the newest card's thread): the same
//     4 /search from the dock on levels 1, 2, 3 -> /search?q=
//   1440: no dock, no floating GO
// Screenshots OUT/mobile-go-dock-<w>-<step>.png, results OUT/results.json.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> CHANNEL=<id>
//     [TENANT=e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/mobile-go-dock-live.proof.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const CHANNEL = need('CHANNEL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, checks: [] }
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

/* docker veth churn kills Chrome navigations now and then (ERR_NETWORK_CHANGED) */
async function nav(p, url) {
  for (let i = 0; i < 4; i++) {
    try { return await p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }) } catch (e) {
      if (!String(e).includes('ERR_NETWORK_CHANGED') || i === 3) throw e
      await sleep(1500)
    }
  }
}

const look = (p) => p.evaluate(() => {
  const vis = (el) => Boolean(el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden')
  const dock = document.querySelector('form.composer.omnibox--global.composer--dock')
  const go = dock && dock.querySelector('[data-testid=send]')
  const r = go ? go.getBoundingClientRect() : null
  const probe = document.createElement('span')
  probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--color-accent').trim()
  document.body.appendChild(probe)
  const accentRgb = getComputedStyle(probe).color
  probe.remove()
  const W = window.innerWidth, H = window.innerHeight
  const mid = document.elementFromPoint(W - 34, Math.round(H / 2))
  const midBtn = mid && mid.closest('button')
  const dr = dock ? dock.getBoundingClientRect() : null
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    toggle: [...document.querySelectorAll('[data-test=top-bar-search-toggle]')].filter(vis).length,
    midButton: midBtn ? (midBtn.getAttribute('data-test') || midBtn.getAttribute('data-testid') || midBtn.className) : '',
    dock: vis(dock),
    dockBottom: dr ? Math.round(H - dr.bottom) : null,
    goIcon: go ? (go.querySelector('svg[data-icon]')?.getAttribute('data-icon') || '') : '',
    goSize: r ? [Math.round(r.width), Math.round(r.height)] : null,
    goRight: r ? Math.round(W - r.right) : null,
    goAccent: go ? getComputedStyle(go).backgroundColor === accentRgb : false,
  }
})

const goOk = (l) => Boolean(l.dock && l.goIcon === 'go' && l.goAccent && l.goSize && l.goSize[0] >= 44 && l.goSize[1] >= 44
  && l.goRight !== null && l.goRight <= 24 && l.dockBottom !== null && Math.abs(l.dockBottom) <= 1)

async function dockSearch(p, q) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.focus(ta)
  await p.type(ta, `/search ${q}`)
  await p.keyboard.press('Enter')
  for (let i = 0; i < 40; i++) {
    await sleep(250)
    const u = new URL(p.url())
    if (u.pathname.endsWith('/search') && u.searchParams.get('q')) return u.searchParams.get('q')
  }
  const u = new URL(p.url())
  return u.pathname.endsWith('/search') ? (u.searchParams.get('q') || '') : null
}

async function toLevel(p, lv) {
  await nav(p, BASE + (lv === '1' ? '/' : '/channel/' + encodeURIComponent(CHANNEL)))
  await p.waitForSelector('.spool-shell', { timeout: 60000 })
  await sleep(2000)
  if (lv === '3') {
    /* the card's own "N >>" control opens its thread (a tap on the header
       can hit the kind badge and open its sheet instead) */
    const c = await p.evaluate(() => {
      const b = [...document.querySelectorAll('.spool-main article.msg[data-msg-id] [data-test=topic-replies]')].find((e) => e.getClientRects().length > 0)
      if (!b) return null
      b.scrollIntoView({ block: 'center' })
      const r = b.getBoundingClientRect()
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
    })
    if (c) await p.touchscreen.tap(c.x, c.y)
    await sleep(1500)
  }
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
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(1500)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build))
  const d = await look(p)
  ok('1440px: no dock and no floating GO', !d.dock && d.toggle === 0, d)

  for (const [w, h] of [[360, 740], [390, 844], [820, 1180]]) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    for (const lv of ['1', '2', '3']) {
      await toLevel(p, lv)
      const l = await look(p)
      await p.screenshot({ path: join(OUT, `mobile-go-dock-${w}-level${lv}.png`) })
      ok(`${w}px level ${lv}: no floating GO at the middle of the right edge`, l.toggle === 0 && !/search-toggle/.test(l.midButton), { level: l.level, midButton: l.midButton })
      ok(`${w}px level ${lv}: the docked bottom-right button is the accent GO (go icon, >= 44 px)`, l.level === lv && goOk(l), l)
      const q = await dockSearch(p, `spl1005-${w}-l${lv}`)
      ok(`${w}px level ${lv}: /search typed in the dock opens /search?q=`, q === `spl1005-${w}-l${lv}`, { q, url: p.url() })
    }
  }
} catch (e) {
  const pages = await browser.pages().catch(() => [])
  const last = pages[pages.length - 1]
  if (last) await last.screenshot({ path: join(OUT, 'mobile-go-dock-error.png') }).catch(() => {})
  ok('no exception', false, { error: String(e).slice(0, 300), at: last ? last.url() : '' })
} finally {
  await browser.close()
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
}
const failed = res.checks.filter((c) => !c.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed.length ? 1 : 0)
