// Middle-pane header (SPL-941, CLE-35001) — live proof + screenshots, signed in,
// against a deployed WUI.
//
// Owner, 2026-09-26: the channel / DM / lobby header carried "Msgs", the name,
// the whole description, a "last 30 · tenant-scoped" note and a three-word
// card height control on one wrapping line. This walks the three headers at
// 1440 / 800 / 390 px, screenshots each and measures it.
//
//   EXPECT unset -> report + screenshots only (the "before" run)
//   EXPECT=new   -> assert the SPL-941 header on every surface and width:
//     - one FeedHeader (data-test=feed-header) whose h2 is the channel / peer
//       / lobby name, no "Msgs" label and no "last 30" note
//     - no channel description (owner: it stays in channel Properties only)
//     - the card height control is icons with a tooltip per mode, at the
//       header's right edge, on the SAME row as the title
//     - the document never scrolls sideways
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=<id>] [DM_PEER=<id@box>] [EXPECT=new] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/feed-header-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

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
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const EXPECT = process.env.EXPECT || ''
const WIDTHS = (process.env.WIDTHS || '1440,800,390').split(',').map(Number)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, expect: EXPECT, steps: [], headers: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** goto that retries a navigation the box's network churn killed. */
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

/* Runs in the page: the middle-pane header, measured. Falls back to the
   pre-SPL-941 markup (.feed-header in [data-pane=msgs]) so the before run
   measures the same box. */
const MEASURE = () => {
  const pane = document.querySelector('[data-pane=msgs]')
  const head = pane && (pane.querySelector('[data-test=feed-header]') || pane.querySelector('.feed-header'))
  if (!head) return { missing: true }
  const r = head.getBoundingClientRect()
  const h2 = head.querySelector('h2')
  const about = head.querySelector('[data-test=channel-description]')
  const ctl = head.querySelector('[data-testid=card-clip-control]')
  const cr = ctl && ctl.getBoundingClientRect()
  const hr = h2 && h2.getBoundingClientRect()
  const opts = ctl ? [...ctl.querySelectorAll('label')].map((l) => ({
    title: l.getAttribute('title') || '',
    text: (l.innerText || '').trim(),
    icon: !!l.querySelector('svg'),
  })) : []
  const pad = parseFloat(getComputedStyle(head).paddingRight) || 0
  return {
    missing: false,
    unified: head.getAttribute('data-test') === 'feed-header',
    text: (head.innerText || '').replace(/\s+/g, ' ').trim(),
    height: Math.round(r.height),
    title: h2 ? (h2.innerText || '').trim() : '',
    about: about ? (about.getAttribute('title') || (about.innerText || '')).slice(0, 120) : null,
    ctl: ctl ? {
      rightGap: Math.round(r.right - pad - cr.right),
      sameRow: hr ? Math.abs((cr.top + cr.bottom) / 2 - (hr.top + hr.bottom) / 2) < 8 : false,
      opts,
    } : null,
    xScroll: document.scrollingElement.scrollWidth - innerWidth,
  }
}

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

/* the first non-lobby channel and the first DM in the sidebar */
async function pickTargets(p) {
  await p.waitForSelector('a[href*="/channel/"]', { timeout: 30000 }).catch(() => {})
  await sleep(1500)
  return p.evaluate(() => {
    const ids = (sel, re) => [...document.querySelectorAll(sel)]
      .map((a) => decodeURIComponent((a.getAttribute('href') || '').replace(re, '').split('?')[0]))
      .filter(Boolean)
    return {
      channels: ids('a[href*="/channel/"]', /^.*\/channel\//).filter((c) => c !== 'lobby'),
      dms: ids('a[href*="/dm/"]', /^.*\/dm\//),
    }
  })
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  const p = await signIn(browser)
  const found = await pickTargets(p)
  const channel = process.env.CHANNEL || found.channels[0] || 'lobby'
  const dm = process.env.DM_PEER || found.dms[0] || ''
  const surfaces = [
    { name: 'channel', path: '/channel/' + encodeURIComponent(channel), expectTitle: '#' + channel },
    { name: 'lobby', path: '/lobby', expectTitle: '#lobby' },
  ]
  if (dm) surfaces.push({ name: 'dm', path: '/dm/' + encodeURIComponent(dm), expectTitle: '' })
  else step('a DM exists in the sidebar', false, { found })

  for (const s of surfaces) {
    for (const w of WIDTHS) {
      await p.setViewport({ width: w, height: 900 })
      await nav(p, BASE + s.path)
      await p.waitForSelector('[data-pane=msgs] .feed-header, [data-pane=msgs] [data-test=feed-header]', { timeout: 30000 }).catch(() => {})
      await sleep(1500)
      const m = await p.evaluate(MEASURE)
      res.headers.push({ surface: s.name, width: w, ...m })
      const head = await p.$('[data-pane=msgs] [data-test=feed-header], [data-pane=msgs] .feed-header')
      if (head) await head.screenshot({ path: `${OUT}/${s.name}-${w}.png` }).catch(() => {})
      await p.screenshot({ path: `${OUT}/${s.name}-${w}-page.png` }).catch(() => {})
      console.log('HEADER', s.name, w, JSON.stringify(m))
      if (m.missing) { step(`${s.name}@${w}: header rendered`, false, {}); continue }
      step(`${s.name}@${w}: no horizontal scroll`, m.xScroll <= 0, { xScroll: m.xScroll })
      if (EXPECT !== 'new') continue
      step(`${s.name}@${w}: one FeedHeader`, m.unified, {})
      step(`${s.name}@${w}: no "Msgs" pane label, no "last 30" note`, !/\bMsgs\b/.test(m.text) && !/\b30\b.*tenant/.test(m.text), { text: m.text })
      if (s.expectTitle) step(`${s.name}@${w}: title is the name`, m.title === s.expectTitle, { title: m.title })
      else step(`${s.name}@${w}: title is the peer`, !!m.title && m.title !== 'Msgs', { title: m.title })
      step(`${s.name}@${w}: no channel description in the header`, !m.about, { about: m.about })
      const c = m.ctl
      step(`${s.name}@${w}: card height control = 3 icons with tooltips`, !!c && c.opts.length === 3 && c.opts.every((o) => o.icon && o.title && !o.text), { opts: c && c.opts })
      step(`${s.name}@${w}: control at the right edge, on the title row`, !!c && Math.abs(c.rightGap) <= 2 && c.sameRow, { rightGap: c && c.rightGap, sameRow: c && c.sameRow })
    }
  }
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS', '->', OUT)
  process.exit(failed ? 1 : 0)
}
