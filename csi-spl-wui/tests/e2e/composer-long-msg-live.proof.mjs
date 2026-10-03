// Owner, t1 d3bbe2c2 (2026-10-03) live: "I cannot see the last part of the
// msg WHERE AM I typing", "something with the scroll, resets it up" - the
// phone Omnibox on the deployed WUI, signed in, 390x844 touch with the
// keyboard up (the viewport 340 px shorter). The rules and the mock checks
// are tests/e2e/composer-long-msg.test.mjs; this proves the deployed bundle:
//
//   1 IME typing (a phone keyboard composes each word) past the cap: after
//     every word the caret line at the end is inside the box
//   2 once at its cap the box's scroll never moves back up; the page never
//     scrolls
//
// The build it ran on (build.json) goes to OUT/result.json. It SENDS nothing and writes no pref: the text is cleared at the end.
//
//   BASE=https://<host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [RUNS=1] \
//     node tests/e2e/composer-long-msg-live.proof.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const RUNS = Number(process.env.RUNS || 1)
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
const KEYBOARD = 340
const BOX = 'form.composer.omnibox--global textarea'
const LONG = Array.from({ length: 40 }, (_, i) => `word${i} lorem ipsum dolor`).join(' ')
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

const sample = (p) => p.evaluate((sel) => {
  const ta = document.querySelector(sel)
  const padB = parseFloat(getComputedStyle(ta).paddingBottom) || 0
  return {
    h: Math.round(ta.getBoundingClientRect().height),
    hidden: Math.max(0, Math.round(ta.scrollHeight - ta.clientHeight - ta.scrollTop - padB)),
    over: ta.scrollHeight - ta.clientHeight,
    atEnd: ta.selectionEnd === ta.value.length,
    y: Math.round(scrollY),
  }
}, BOX)

async function run(p, n) {
  await p.setViewport(PHONE)
  await nav(p, `${BASE}/channel/${encodeURIComponent(CHANNEL)}`)
  await p.waitForSelector(BOX, { timeout: 30000 })
  await sleep(1500)
  await p.focus(BOX)
  await p.setViewport({ ...PHONE, height: PHONE.height - KEYBOARD })
  await sleep(400)
  await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    window.__longMsg = { box: [], page: 0 }
    ta.addEventListener('scroll', () => window.__longMsg.box.push([Math.round(ta.scrollTop), Math.round(ta.getBoundingClientRect().height)]))
    document.addEventListener('scroll', (e) => { if (e.target !== ta) window.__longMsg.page++ }, true)
  }, BOX)
  const cdp = await p.createCDPSession()
  const rows = []
  for (const w of LONG.split(/(?<= )/)) {
    for (let k = 1; k <= w.length; k++) await cdp.send('Input.imeSetComposition', { text: w.slice(0, k), selectionStart: k, selectionEnd: k })
    await cdp.send('Input.insertText', { text: w })
    await sleep(30)
    rows.push(await sample(p))
  }
  const ev = await p.evaluate(() => window.__longMsg)
  await p.screenshot({ path: join(OUT, `long-msg-390-run${n}.png`) })
  /* nothing is sent: clear the draft */
  await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    ta.value = ''
    ta.dispatchEvent(new Event('input', { bubbles: true }))
  }, BOX)
  await cdp.detach()
  const cap = Math.max(...rows.map((r) => r.h))
  const lost = rows.filter((r) => r.atEnd && r.hidden > 0)
  let backs = 0
  for (let i = 1; i < ev.box.length; i++) if (ev.box[i][1] >= cap && ev.box[i - 1][1] >= cap && ev.box[i][0] < ev.box[i - 1][0]) backs++
  ok(`1 run ${n}/${RUNS}: IME typing, after every word the caret line at the end is inside the box`,
    rows.length > 0 && lost.length === 0, { words: rows.length, lost: lost.length, worstHiddenPx: Math.max(0, ...rows.map((r) => r.hidden)) })
  ok(`2 run ${n}/${RUNS}: at the cap the box never scrolls back up; the page never scrolls`,
    rows.some((r) => r.over > 0 && r.h === cap) && backs === 0 && ev.page === 0 && rows.every((r) => r.y === 0),
    { cap, scrollBacksAtCap: backs, pageScrolls: ev.page })
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
try {
  const p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport(PHONE)
  await nav(p, `${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`)
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.spool-shell'), { timeout: 60000 })
  await sleep(1500)
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  console.log('  build', JSON.stringify(res.build))
  for (let n = 1; n <= RUNS; n++) await run(p, n)
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'result.json'), JSON.stringify(res, null, 2))
console.log(failed ? `FAIL: ${failed}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed ? 1 : 0)
