// Topic c6994436 live: Settings -> Behaviour "Message order" x "Omnibox
// position", every combination, on a deployed WUI + hub.
//
//   BASE=https://e2e.<domain> AUTH_BASE=https://api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> TENANT=e2e OUT=<dir> \
//     [WIDTHS=1440,820] [SEND=1] node tests/e2e/message-order-live.proof.mjs
//
// For each of newest-first/top, newest-first/bottom, newest-last/top and
// newest-last/bottom it picks the two radios (a real PUT each, stepping
// through the other value when one is already checked), reloads, and on
// #lobby checks at every width:
//   - the claim and the radios agree after the reload (kept on the account)
//   - the rows run newest first or oldest first by their data-ts
//   - Load more sits under the rows (newest first) or above them (newest last)
//   - newest last opens at the bottom of the feed
//   - the Omnibox sits in the top bar (top) or in the lower part of the
//     screen (bottom; on <= 820 px phones dock it at the bottom either way)
// SEND=1 also sends one line in the newest-last/bottom combination and
// checks it lands as the LAST row with the feed still at its bottom. It
// writes only when the session tenant AND the page host tenant are TENANT.
// The account's two values are put back as found (null = never picked);
// RESTORE=null puts both back to never picked instead (after a crossed run
// on the shared e2e account left a proof's values behind as "found").
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
const WIDTHS = String(process.env.WIDTHS || '1440,820').split(',').map(Number).filter(Boolean)
const SEND = process.env.SEND === '1'
const RESTORE_NULL = process.env.RESTORE === 'null'
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const BOX = 'form.omnibox--global textarea'
const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)
const KEYS = { message_order: ['newest-first', 'newest-last'], composer_position: ['top', 'bottom'] }

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
  /* every window error, from the first document on (the ResizeObserver loop
     error reached the error snackbar on prd e2e, 2026-09-28) */
  await p.evaluateOnNewDocument(() => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
  })
  const errsSeen = []
  const claims = async () => p.evaluate(async (base) => {
    const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
    if (r.status !== 200) return { status: r.status }
    const j = await r.json()
    return { message_order: j.message_order, composer_position: j.composer_position, t: j.t }
  }, AUTH_BASE)
  const checked = async (key) => p.evaluate((k) => document.querySelector(`[data-test=view-pref-${k}] input:checked`)?.value || '', key)
  const pick = async (key, want) => {
    const sel = `[data-test=${key}-${want}]`
    await p.waitForSelector(sel, { timeout: 15000 })
    await sleep(400)
    /* a checked radio fires no change: step through the other value first */
    if (await checked(key) === want) {
      const other = `[data-test=${key}-${KEYS[key].find((v) => v !== want)}]`
      await p.click(other)
      await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, other)
      await sleep(500)
    }
    await p.click(sel)
    await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, sel)
    await sleep(500)
  }
  const measure = () => p.evaluate((box) => {
    const feed = document.querySelector('[data-pane="msgs"] .live-feed')
    let sc = null
    for (let n = feed; n; n = n.parentElement) {
      const oy = getComputedStyle(n).overflowY
      if (oy === 'auto' || oy === 'scroll') { sc = n; break }
    }
    const rows = feed ? [...feed.querySelectorAll('.live-rows > article.msg')] : []
    const ts = rows.map((r) => r.getAttribute('data-ts') || '').filter(Boolean)
    const more = feed?.querySelector('[data-testid=load-more]')
    const list = feed?.querySelector('.live-rows')
    const omni = document.querySelector(box)?.getBoundingClientRect()
    return {
      n: rows.length,
      asc: ts.length > 1 && ts.every((t, i) => i === 0 || ts[i - 1] <= t),
      desc: ts.length > 1 && ts.every((t, i) => i === 0 || ts[i - 1] >= t),
      more: more && list ? (more.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING ? 'above' : 'below') : 'none',
      fromBottom: sc ? Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight) : null,
      scrolls: sc ? sc.scrollHeight > sc.clientHeight + 1 : false,
      omniTop: omni ? Math.round(omni.top) : null,
      vh: window.innerHeight,
      lastKey: rows[rows.length - 1]?.innerText?.slice(0, 200) ?? '',
      host: location.host,
    }
  }, BOX)

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await sleep(4000)
  original = await claims()
  step('signed in; the session answers both layout claims', !original.status && 'message_order' in original && 'composer_position' in original, original)

  for (const order of KEYS.message_order) for (const pos of KEYS.composer_position) {
    const combo = `${order}/${pos}`
    await p.setViewport({ width: 1440, height: 900 })
    await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
    await pick('message_order', order)
    await pick('composer_position', pos)
    const c = await claims()
    step(`${combo}: stored on the account`, c.message_order === order && c.composer_position === pos, c)
    await p.reload({ waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=view-prefs-setting]', { timeout: 15000 })
    await sleep(500)
    step(`${combo}: both radios checked after a reload`, (await checked('message_order')) === order && (await checked('composer_position')) === pos)
    for (const width of WIDTHS) {
      await p.setViewport({ width, height: 900 })
      await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
      await p.waitForSelector('[data-pane="msgs"] .live-rows > article.msg', { timeout: 20000 })
      await sleep(2500)
      const m = await measure()
      const tag = `${combo} @${width}`
      if (order === 'newest-last') {
        step(`${tag}: rows run oldest first`, m.asc && !m.desc, m)
        step(`${tag}: Load more above the rows (or no older rows)`, m.more === 'above' || m.more === 'none', m)
        step(`${tag}: the feed opens at its bottom`, !m.scrolls || m.fromBottom <= 4, m)
      } else {
        step(`${tag}: rows run newest first`, m.desc && !m.asc, m)
        step(`${tag}: Load more under the rows (or no older rows)`, m.more === 'below' || m.more === 'none', m)
      }
      const bottomDock = pos === 'bottom' || width <= 820
      step(`${tag}: the Omnibox is ${bottomDock ? 'in the lower half' : 'in the top bar'}`,
        m.omniTop !== null && (bottomDock ? m.omniTop > m.vh / 2 : m.omniTop < 80), { omniTop: m.omniTop, vh: m.vh })
      await p.screenshot({ path: `${OUT}/${order}-${pos}-${width}.png` })
      /* the browser still raises its benign ResizeObserver loop notice (recorded
         for the result); what must not happen is the reader seeing it */
      const errs = await p.evaluate(() => window.__errs || [])
      errsSeen.push(...errs)
      const snack = await p.evaluate(() => [...document.querySelectorAll('[data-test=error-snackbar-item]')].map((el) => el.innerText))
      step(`${tag}: no ResizeObserver error in the error snackbar`, !snack.some((x) => /ResizeObserver/.test(x)), { snack, windowErrors: errs.length })

      if (SEND && order === 'newest-last' && pos === 'bottom' && width === WIDTHS[0]) {
        const host = m.host.split('.')[0]
        const guard = (await claims()).t === TENANT && host === TENANT
        step(`${tag}: write guard (claim t and host tenant are ${TENANT})`, guard, { host })
        if (guard) {
          const line = `c6994436 newest-last proof ${stamp}`
          await p.click(BOX)
          await p.keyboard.type(line)
          await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
          const landed = await p.waitForFunction((t) => {
            const rows = [...document.querySelectorAll('[data-pane="msgs"] .live-rows > article.msg')]
            return (rows[rows.length - 1]?.innerText || '').includes(t)
          }, { timeout: 20000 }, line).then(() => true).catch(() => false)
          await sleep(800)
          const a = await measure()
          step(`${tag}: our own line lands as the LAST row, the feed at its bottom`, landed && (!a.scrolls || a.fromBottom <= 4), { landed, fromBottom: a.fromBottom })
          await p.screenshot({ path: `${OUT}/${order}-${pos}-${width}-sent.png` })
        }
      }
    }
  }
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  if (p && original && !original.status) {
    try {
      const back = RESTORE_NULL ? { message_order: null, composer_position: null }
        : { message_order: original.message_order ?? null, composer_position: original.composer_position ?? null }
      const st = await p.evaluate(async (base, body) => (await fetch(base + '/api/v1/auth/preferences', {
        method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      })).status, AUTH_BASE, back)
      res.restored = { to: back, status: st }
    } catch (e) { res.restored = { error: String(e) } }
  }
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
