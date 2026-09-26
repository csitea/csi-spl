// SPL-981 + SPL-982 live proof against a deployed WUI (owner, prd t1 topics
// 5cf46197 and 8296eeec):
//  A. a DM thread: every card shows only its sender - no "→", no receiver
//     avatar, no receiver name
//  B. a channel: an opening card's replies link reads exactly "n >>" (no word)
//     and keeps "n replies - Open topic" on aria-label and title
//  C. every card on those pages: the emoji glyph sits about 5px after the
//     time, level with it
//  D. the issue discussion: a comment is a message card with the same rule
//     (ONE comment is posted on ISSUE in TENANT; the only write)
// Screenshots and results.json to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> ISSUE=<key in TENANT>
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [CHANNEL=lobby]
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/card-header-live.proof.mjs
//
// Writes only when the session's tenant AND the page host's tenant are
// TENANT. The password is read from PW_FILE and never printed.
// Exit 0 = every step PASS.
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
const TENANT = need('TENANT')
const ISSUE = need('ISSUE')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const CHANNEL = process.env.CHANNEL || 'lobby'
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function until(fn, ms) {
  const end = Date.now() + ms
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() > end) return v
    await sleep(400)
  }
}

/* per card: the emoji glyph's distance after the time, and how level it is */
const cardGeometry = (p, sel) => p.$$eval(sel, (els) => els.map((a) => {
  if (!a.offsetParent) return null
  const t = a.querySelector('.msg-time')
  const e = a.querySelector('[data-testid=msg-emoji-btn] svg')
  if (!t || !e) return null
  const tr = t.getBoundingClientRect()
  const er = e.getBoundingClientRect()
  return { gap: Math.round(er.left - tr.right), dy: Math.round((er.top + er.height / 2) - (tr.top + tr.height / 2)), w: Math.round(a.getBoundingClientRect().width), text: (a.querySelector('.msg-meta')?.innerText || '').slice(0, 60) }
}).filter(Boolean))
const inRange = (x) => x.gap >= 3 && x.gap <= 7 && Math.abs(x.dy) <= 4
const emojiOk = (g) => g.length > 0 && g.every(inRange)
const outliers = (g) => g.filter((x) => !inRange(x)).slice(0, 5)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok)
  if (!ok) throw new Error('not signed in')
  const where = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const g = app && app.config.globalProperties
    const s = g && g.$pinia && g.$pinia.state.value.session
    const pub = (g && g.$config && g.$config.public) || null
    if (!pub || !s || !s.claims) return null
    const hosts = String(pub.tenantHosts || '0') === '1'
    let page = ''
    if (hosts) {
      const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
      const h = location.hostname.toLowerCase()
      page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
    }
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('the session AND the page host are in TENANT', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)
  await sleep(1500)

  // A. a DM thread
  await p.click('[data-testid=sidebar-tab-dm]').catch(() => {})
  await sleep(1000)
  /* the first DM thread that holds messages */
  const dmHrefs = await p.evaluate(() => [...new Set([...document.querySelectorAll('a[href*="/dm/"]')].map((x) => x.getAttribute('href')))])
  let dmHref = ''
  let dmCards = 0
  for (const h of dmHrefs.slice(0, 12)) {
    await p.goto(new URL(h, BASE).href, { waitUntil: 'networkidle2', timeout: 60000 })
    dmCards = await until(async () => { const n = await p.$$eval('article.msg', (els) => els.length); return n > 0 ? n : 0 }, 6000) || 0
    if (dmCards > 0) { dmHref = h; break }
  }
  const dm = await p.$$eval('article.msg', (els) => els.map((a) => ({
    arrow: !!a.querySelector('.msg-to-arrow'),
    toAvatar: !!a.querySelector('.avatar--to'),
    badges: a.querySelectorAll('.msg-meta .agent-badge, .msg-meta [data-testid=agent-badge]').length,
  })))
  step('A a DM thread: every card shows only its sender (no →, no receiver avatar)',
    !!dmHref && dmCards > 0 && dm.every((c) => !c.arrow && !c.toAvatar), { dm: dmHref, cards: dm.length, withArrow: dm.filter((c) => c.arrow).length })
  const gDm = await cardGeometry(p, 'article.msg')
  step('C1 DM cards: the emoji glyph ~5px after the time, level with it', emojiOk(gDm), { n: gDm.length, sample: gDm.slice(0, 3), outliers: outliers(gDm) })
  await p.screenshot({ path: `${OUT}/A-dm-thread.png` })

  // B. a channel
  await p.goto(BASE + '/channel/' + encodeURIComponent(CHANNEL), { waitUntil: 'networkidle2', timeout: 60000 })
  await until(async () => (await p.$$eval('article.msg', (els) => els.length)) > 0, 20000)
  await sleep(1200)
  const links = await p.$$eval('[data-test=topic-replies]', (els) => els.map((b) => ({ text: b.textContent.trim(), label: b.getAttribute('aria-label'), title: b.getAttribute('title') })))
  const withN = links.filter((l) => /^\d+ >>$/.test(l.text))
  step('B a channel opening card reads exactly "n >>", no word "replies"',
    links.length > 0 && links.every((l) => /^\d+ >>$/.test(l.text)) && !links.some((l) => /repl/i.test(l.text)), { n: links.length, sample: links.slice(0, 3) })
  step('B the link keeps "n replies - Open topic" on aria-label and title',
    withN.length > 0 && withN.every((l) => /^\d+ repl(y|ies) - Open topic$/.test(l.label || '') && l.label === l.title), { sample: withN.slice(0, 2) })
  const gCh = await cardGeometry(p, 'article.msg')
  step('C2 channel cards: the emoji glyph ~5px after the time, level with it', emojiOk(gCh), { n: gCh.length, sample: gCh.slice(0, 3), outliers: outliers(gCh) })
  const card = await p.$('article.msg [data-test=topic-replies]')
  const art = card && await card.evaluateHandle((b) => b.closest('article.msg'))
  if (art) await art.asElement().screenshot({ path: `${OUT}/B-channel-card.png` })
  await p.screenshot({ path: `${OUT}/B-channel.png` })

  // D. the issue discussion
  await p.goto(BASE + `/issues?issue=${encodeURIComponent(ISSUE)}`, { waitUntil: 'networkidle2', timeout: 60000 })
  const talk = await p.waitForSelector('[data-test=issues-comment-input]', { visible: true, timeout: 30000 }).catch(() => null)
  step('D the issue opens with its discussion', !!talk, { issue: ISSUE })
  const note = `SPL-982 card proof ${Date.now().toString(36)}`
  await p.click('[data-test=issues-comment-input]')
  await p.type('[data-test=issues-comment-input]', note)
  /* SPL-973 removed the Comment button: the text field sends (SPL-976 Behaviour: Enter, or Ctrl+Enter) */
  await p.keyboard.press('Enter')
  await sleep(1500)
  if (!(await p.evaluate((n) => [...document.querySelectorAll('[data-test=issues-comment]')].some((x) => x.innerText.includes(n)), note))) {
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
  }
  const said = await until(() => p.evaluate((n) => {
    const c = [...document.querySelectorAll('[data-test=issues-comment]')].find((x) => x.innerText.includes(n))
    return c ? { tag: c.tagName, card: c.classList.contains('msg'), emoji: !!c.querySelector('[data-testid=msg-emoji-btn]'), time: !!c.querySelector('.msg-time') } : null
  }, note), 20000)
  step('D a comment is a message card (header, time, emoji)', !!said && said.card && said.emoji && said.time, said || {})
  const gIs = await cardGeometry(p, '[data-test=issues-comment]')
  step('C3 issue comments: the emoji glyph ~5px after the time, level with it', emojiOk(gIs), { n: gIs.length, sample: gIs.slice(0, 3), outliers: outliers(gIs) })
  await p.screenshot({ path: `${OUT}/D-issue-comments.png` })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
