// SPL-1001 — live proof, signed in: the delete confirms on a deployed WUI.
//
// Owner, 2026-09-27 (#spool-hub-bugs d9363508): "The delete msg dialog box is
// ugly" - "should a bit bigger and the text centered properly with more space
// from the end of the dialog". The mock gate is tests/e2e/delete-confirm.test.mjs;
// this one measures the same contract against the real hub and bundle and
// takes the screenshots the owner is shown.
//
//   1. sign in; refuse to write unless the session AND the page host are TENANT
//   2. create a #lobby topic: a card and three replies
//   3. per viewport (1440, 820, 390) and theme (dark, light):
//      - the card's Delete opens the topic confirm; its title names the 3
//        replies (from the hub); Cancel is focused; Enter cancels
//      - a reply's Delete on the thread page opens the message confirm;
//        Escape closes; the reply is still there
//   4. the topic confirm's Delete removes the card and the hub answers 404
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> TENANT=<tenant>
//   EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//   [WIDTHS=1440,820,390] [THEMES=dark,light] node tests/e2e/delete-confirm-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = need('TENANT')
const PHASE = 'live'
const WIDTHS = (process.env.WIDTHS || '1440,820,390').split(',').map(Number)
const THEMES = (process.env.THEMES || 'dark,light').split(',')
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

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

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
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
  step('1 native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* issues-live.proof.mjs's guard: nothing is written unless BOTH the
     session's tenant (claim t) and the tenant the page writes to are TENANT. */
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
  step('1 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

/* A read the box's docker network churn killed (TypeError: Failed to fetch,
   measured on the first dev run) is retried; an HTTP answer never is. */
const hub = (p, method, path) => p.evaluate(async (api, m, pth) => {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(api + pth, { method: m, credentials: 'include' })
      let body = null
      try { body = await r.json() } catch { /* 204 */ }
      return { status: r.status, body }
    } catch (e) {
      last = e
      await new Promise((res) => setTimeout(res, 2000))
    }
  }
  return { status: 0, body: { error: String(last) } }
}, API, method, path)

/** Sends frames over a fresh browser socket (the page's cookies): the WUI's own wire. */
const sendAll = (p, frames) => p.evaluate(async (api, fs) => {
  const ws = new WebSocket(api.replace(/^http/, 'ws') + '/v1/wui/ws')
  const acks = {}
  await new Promise((ok, bad) => {
    const t = setTimeout(() => bad(new Error('no welcome')), 15000)
    ws.onopen = () => ws.send(JSON.stringify({ type: 'hello' }))
    ws.onmessage = (ev) => {
      const f = JSON.parse(ev.data)
      if (f.type === 'welcome') { clearTimeout(t); ok() }
      if (f.type === 'ack') acks[f.msg_id] = true
      if (f.type === 'error') acks['error:' + (f.msg_id || '')] = f
    }
  })
  for (const f of fs) {
    ws.send(JSON.stringify({ type: 'send', kind: 'note', files: [], ...f }))
    const end = Date.now() + 15000
    while (!acks[f.msg_id] && Date.now() < end) await new Promise((r) => setTimeout(r, 100))
  }
  ws.close()
  return acks
}, API, frames)


/** Click the first VISIBLE match. */
const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

const readDialog = (p) => p.evaluate(() => {
  const panel = document.querySelector('[data-testid=ui-dialog]')
  if (!panel) return { open: false }
  const r = panel.getBoundingClientRect()
  const text = panel.querySelector('.ui-confirm__body p')?.getBoundingClientRect()
  const a = document.activeElement
  return {
    open: true,
    title: panel.querySelector('.ui-dialog__title')?.textContent.trim() || '',
    width: Math.round(r.width),
    full: Math.round(r.width) === window.innerWidth && Math.round(r.height) === window.innerHeight,
    inset: text ? Math.round(Math.min(text.left - r.left, r.right - text.right)) : -1,
    focus: a?.getAttribute('data-testid') || '',
  }
})

async function dialog(p, open) {
  for (let i = 0; i < 60; i++) {
    const d = await readDialog(p)
    if (d.open === open && (!open || d.title)) return d
    await sleep(150)
  }
  return readDialog(p)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  const p0 = await signIn(browser)
  const T = randomUUID()
  const card = randomUUID()
  const replies = [randomUUID(), randomUUID(), randomUUID()]
  const tag = `SPL-1001 proof ${Date.now().toString(36)}`
  const acks = await sendAll(p0, [
    { msg_id: card, task_id: T, channel: 'lobby', body: `${tag}: the card`, is_parent: 1 },
    ...replies.map((id, i) => ({ msg_id: id, task_id: T, channel: 'lobby', body: `${tag}: reply ${i + 1}`, is_parent: 0 })),
  ])
  step('2 the card and three replies are stored (acked)', [card, ...replies].every((id) => acks[id]), { acks: Object.keys(acks).length })
  writeFileSync(`${OUT}/ids.json`, JSON.stringify({ task: T, card, replies }, null, 2))

  for (const width of WIDTHS) {
    for (const theme of THEMES) {
      const at = `${width}px ${theme}`
      const touch = width <= 820
      const p = await browser.newPage()
      await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
      await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch {} }, theme)
      await nav(p, BASE + '/channel/lobby')
      await p.waitForSelector(`article.msg[data-msg-id="${card}"]`, { visible: true, timeout: 30000 }).catch(() => {})
      await sleep(800)
      await click(p, `article.msg[data-msg-id="${card}"] [data-testid=msg-menu-btn]`)
      await sleep(400)
      await click(p, '[data-testid=msg-menu-delete-topic]')
      await p.waitForSelector('[data-testid=topic-delete-count][data-replies="3"]', { timeout: 15000 }).catch(() => {})
      let d = await dialog(p, true)
      step(`3 ${at} topic confirm: names the 3 replies, Cancel focused, inset >= 16`,
        d.open && /3/.test(d.title) && d.focus === 'topic-delete-cancel' && d.inset >= 16 && (width > 600 ? d.width <= 480 : d.full), d)
      await shot(p, `after-topic-${width}-${theme}`)
      await p.keyboard.press('Enter')
      d = await dialog(p, false)
      step(`3 ${at} topic confirm: Enter cancels, the card stays`, !d.open && Boolean(await p.$(`article.msg[data-msg-id="${card}"]`)))

      await nav(p, BASE + '/t/' + T)
      await p.waitForSelector(`article.msg[data-msg-id="${replies[0]}"]`, { visible: true, timeout: 30000 }).catch(() => {})
      await sleep(800)
      await click(p, `article.msg[data-msg-id="${replies[0]}"] [data-testid=msg-menu-btn]`)
      await sleep(400)
      await click(p, '[data-testid=msg-menu-delete]')
      d = await dialog(p, true)
      step(`3 ${at} message confirm: opens, Cancel focused, inset >= 16`,
        d.open && d.focus === 'msg-delete-cancel' && d.inset >= 16 && (width > 600 ? d.width <= 480 : d.full), d)
      await shot(p, `after-message-${width}-${theme}`)
      await p.keyboard.press('Escape')
      d = await dialog(p, false)
      step(`3 ${at} message confirm: Escape closes, the reply stays`, !d.open && Boolean(await p.$(`article.msg[data-msg-id="${replies[0]}"]`)))
      await p.close()
    }
  }

  /* 4. the real delete, through the new confirm - also the cleanup */
  await p0.setViewport({ width: 1440, height: 900 })
  await nav(p0, BASE + '/channel/lobby')
  await p0.waitForSelector(`article.msg[data-msg-id="${card}"]`, { visible: true, timeout: 30000 }).catch(() => {})
  await sleep(800)
  await click(p0, `article.msg[data-msg-id="${card}"] [data-testid=msg-menu-btn]`)
  await sleep(400)
  await click(p0, '[data-testid=msg-menu-delete-topic]')
  await p0.waitForSelector('[data-testid=topic-delete-count][data-replies="3"]', { timeout: 15000 }).catch(() => {})
  await p0.click('[data-testid=topic-delete-confirm]')
  const gone = await until(() => p0.$(`article.msg[data-msg-id="${card}"]`).then((h) => !h), 15000)
  const after = await hub(p0, 'GET', `/v1/view/messages/${card}/topic`)
  step('4 Delete removes the card; the hub answers 404 for it', gone && after.status === 404, { gone, status: after.status })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS')
process.exit(failed ? 1 : 0)
