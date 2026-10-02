// HUM-10 (owner, t1 5a410ad5) - live proof, signed in, against a DEPLOYED WUI
// + hub: on a phone (390 wide, touch) a long press lifts a topic card, the
// finger drags it onto another topic, the release asks to merge, and after
// Confirm topic A's messages show under topic B. The phone's merge call is
// the desktop drag's call: the same POST /v1/messages/{A}/merge-topic with the
// same body ({ to_task }). It WRITES 2 topics + 1 reply per width into CHANNEL
// of a test tenant (dev test member / prd e2e), never the owner's topics.
//
//   0 sign in; refuse to write unless the session AND the page host are TENANT
//   1 1440: drag topic D1 by its handle onto D2, Confirm -> the merge request
//   2 390 touch: a quick swipe on a card lifts nothing (control)
//   3 390 touch: long press P1, drag onto P2 (P2 lit), release -> confirm,
//     Confirm -> the merge request; same path template and body keys as 1
//   4 390: open P2: P1's opening line AND its reply now show in P2's thread
//   5 clean: archive the two topics left (D2, P2; D1 and P1 are inside them)
//
// CHANNEL unset: the first channel of the signed-in session that is not the
// lobby (a read-only pick; only topics this run creates are dragged).
//
//   BASE=https://<test tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [CHANNEL=<name>]
//     [TENANT=e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/merge-touch-live.proof.mjs
//
// The password is never printed. Exit 0 = every check OK.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
let CHANNEL = process.env.CHANNEL || ''
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, checks: [], lines: {}, requests: {} }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: Boolean(pass), ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function nav(p, url) {
  for (let i = 0; i < 4; i++) {
    try { return await p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }) } catch (e) {
      if (!String(e).includes('ERR_NETWORK_CHANGED') || i === 3) throw e
      await sleep(1500)
    }
  }
}

const tenantOf = (p) => p.evaluate(() => {
  const g = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties
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
})

/** A topic (is_parent 1) or a reply on `task`, through the page's own channel store (the hub acks it). */
const post = (p, body, task) => p.evaluate(async ({ body, task }) => {
  const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const m = task ? await ch.send(body, task, undefined, undefined, 0) : await ch.send(body, undefined, undefined, undefined, 1)
  return { msg_id: m.msg_id, task_id: m.task_id }
}, { body, task })

/** The visible card holding `text`, scrolled to the middle; a point on its own text (not a button). */
const cardOf = (p, text) => p.evaluate((body) => {
  const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getClientRects().length > 0 && e.textContent.includes(body))
  if (!el) return null
  el.scrollIntoView({ block: 'center' })
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let node = walker.nextNode()
  while (node && !node.textContent.includes(body)) node = walker.nextNode()
  const range = document.createRange()
  const r = node ? (range.selectNodeContents(node), range.getBoundingClientRect()) : el.getBoundingClientRect()
  const c = el.getBoundingClientRect()
  return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + r.height / 2), left: c.left, top: c.top, h: c.height }
}, text)

const drag = (p) => p.evaluate(() => ({
  lit: [...document.querySelectorAll('article.msg.msg--move-over')].map((e) => e.getAttribute('data-msg-id')),
  ghost: document.querySelector('[data-testid=move-ghost]')?.textContent || null,
  confirm: Boolean(document.querySelector('[data-testid=merge-confirm-confirm]')),
}))

/** Record the next merge-topic request (method, path with ids as placeholders, body). */
function watchMerge(p, ids) {
  let got = null
  const on = (r) => {
    /* the CORS preflight (OPTIONS) is not the call */
    if (got || r.method() === 'OPTIONS' || !/\/merge-topic$/.test(new URL(r.url()).pathname)) return
    let body = null
    try { body = JSON.parse(r.postData() || 'null') } catch { body = r.postData() }
    const path = new URL(r.url()).pathname
    got = { method: r.method(), path, template: path.replace(ids.src, '{src}'), body, bodyKeys: body && typeof body === 'object' ? Object.keys(body).sort() : [], toIsTarget: Boolean(body && body.to_task === ids.dst) }
  }
  p.on('request', on)
  return async () => {
    for (let i = 0; i < 40 && !got; i++) await sleep(250)
    p.off('request', on)
    return got
  }
}

async function confirmMerge(p) {
  await p.waitForSelector('[data-testid=merge-confirm-confirm]', { timeout: 8000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('[data-testid=merge-confirm-confirm]')?.click())
}

const tag = `hum10-${Date.now().toString(36)}`
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
  const tn = await tenantOf(p)
  const inTenant = Boolean(tn && tn.claim === TENANT && (!tn.hosts || tn.page === TENANT))
  ok('0 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...tn })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'tag', tag)
  if (!CHANNEL) {
    CHANNEL = await p.evaluate(() => {
      const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
      const c = (ch.channels || []).find((x) => x && x.name && x.name !== 'lobby' && !x.archived && !x.archived_at)
      return c ? String(c.name) : ''
    })
    res.channel = CHANNEL
  }
  ok('0 a test channel of the session to write into', Boolean(CHANNEL), { channel: CHANNEL })
  if (!CHANNEL) throw new Error('no channel to write into')
  const chan = BASE + '/channel/' + encodeURIComponent(CHANNEL)

  /* ---- 1. desktop: the handle drag's merge request ----------------------- */
  await nav(p, chan)
  await p.waitForSelector('.spool-main', { timeout: 60000 })
  await sleep(1500)
  const D1 = `${tag} D1 desktop source`
  const D2 = `${tag} D2 desktop target`
  res.lines.D1 = await post(p, D1)
  await sleep(300)
  res.lines.D2 = await post(p, D2)
  await sleep(2000)
  const d1 = await cardOf(p, D1)
  const d2 = await cardOf(p, D2)
  const dWait = watchMerge(p, { src: res.lines.D1.msg_id, dst: res.lines.D2.task_id })
  if (d1 && d2) {
    /* both read BEFORE the press: cardOf scrolls, and nothing may scroll mid-drag */
    const box = (id) => p.evaluate((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return { left: r.left, top: r.top, h: r.height, x: r.left + r.width / 2, y: r.top + r.height / 2 } }, `.spool-main article.msg[data-msg-id="${id}"]`)
    const h = await box(res.lines.D1.msg_id)
    const t = await box(res.lines.D2.msg_id)
    await p.mouse.move(h.left + 5, h.y)
    await p.mouse.down()
    await p.mouse.move(h.left + 15, h.y, { steps: 4 })
    await p.mouse.move(t.x, t.y, { steps: 12 })
    await sleep(150)
    res.desktopDrag = { from: h, to: t, at: await drag(p) }
    await p.screenshot({ path: join(OUT, 'hum10-1440-over-target.png') })
    await p.mouse.up()
    await sleep(600)
    res.desktopDrag.after = { ...(await drag(p)), d2: res.lines.D2.msg_id, toast: await p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent || '') }
    await confirmMerge(p)
    await sleep(1500)
    res.desktopDrag.confirmed = { ...(await drag(p)), toast: await p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent || ''), err: await p.evaluate(() => [...document.querySelectorAll('[role=alert]')].map((e) => e.textContent.trim()).join(' | ')) }
  }
  res.requests.desktop = await dWait()
  ok('1 1440: the handle drag of D1 onto D2 asks, Confirm sends POST .../merge-topic', res.requests.desktop?.method === 'POST' && res.requests.desktop.toIsTarget, res.requests.desktop || res.desktopDrag)

  /* ---- 2..4. phone 390, touch ------------------------------------------- */
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await nav(p, chan)
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: 60000 })
  await sleep(1500)
  const P1 = `${tag} P1 phone source A`
  const P2 = `${tag} P2 phone target B`
  const R1 = `${tag} R1 a reply in A`
  res.lines.P1 = await post(p, P1)
  res.lines.R1 = await post(p, R1, res.lines.P1.task_id)
  await sleep(300)
  res.lines.P2 = await post(p, P2)
  await sleep(2500)

  /* 2. control: a quick swipe lifts nothing */
  const c0 = await cardOf(p, P1)
  await p.touchscreen.touchStart(c0.x, c0.y)
  const seen = []
  for (let i = 1; i <= 5; i++) { await p.touchscreen.touchMove(c0.x, c0.y - i * 25); await sleep(16) }
  seen.push(await drag(p))
  await p.touchscreen.touchEnd()
  await sleep(600)
  seen.push(await drag(p))
  ok('2 390 control: a quick swipe lifts nothing, asks nothing', seen.every((s) => !s.ghost && s.lit.length === 0 && !s.confirm), seen)

  /* 3. long press P1, drag onto P2, release, Confirm */
  const a = await cardOf(p, P1)
  const pWait = watchMerge(p, { src: res.lines.P1.msg_id, dst: res.lines.P2.task_id })
  await p.touchscreen.touchStart(a.x, a.y)
  await sleep(750)
  const lifted = await drag(p)
  const b = await p.evaluate((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return { x: r.left + r.width * 0.5, y: r.top + r.height / 2 } }, `.spool-main article.msg[data-msg-id="${res.lines.P2.msg_id}"]`)
  for (let i = 1; i <= 12; i++) { await p.touchscreen.touchMove(a.x + ((b.x - a.x) * i) / 12, a.y + ((b.y - a.y) * i) / 12); await sleep(30) }
  await sleep(200)
  const over = await drag(p)
  await p.screenshot({ path: join(OUT, 'hum10-390-over-target.png') })
  await p.touchscreen.touchEnd()
  await sleep(600)
  const asked = await drag(p)
  await p.screenshot({ path: join(OUT, 'hum10-390-confirm.png') })
  ok('3 390: the long press lifts P1 (ghost)', new RegExp(`${tag} P1`).test(lifted.ghost || ''), lifted)
  ok('3 390: over P2 exactly P2 is lit', over.lit.length === 1 && over.lit[0] === res.lines.P2.msg_id, over)
  ok('3 390: the release opens the merge confirm', asked.confirm, asked)
  await confirmMerge(p)
  res.requests.phone = await pWait()
  const D = res.requests.desktop || {}
  const P = res.requests.phone || {}
  ok('3 390: Confirm sends POST .../merge-topic for P1 with to_task = P2', P.method === 'POST' && P.toIsTarget, P)
  ok('3 the phone call IS the desktop call: same method, path template, body keys', P.method === D.method && P.template === D.template && JSON.stringify(P.bodyKeys) === JSON.stringify(D.bodyKeys), { desktop: [D.method, D.template, D.bodyKeys], phone: [P.method, P.template, P.bodyKeys] })
  await sleep(2500)
  await p.screenshot({ path: join(OUT, 'hum10-390-merged.png') })

  /* 4. A's messages now show under B */
  const t2 = await cardOf(p, P2)
  if (t2) await p.touchscreen.tap(t2.x, t2.y)
  await sleep(3000)
  const inB = await p.evaluate(({ P1, R1 }) => {
    const rows = [...document.querySelectorAll('aside article.msg')].filter((e) => e.getClientRects().length > 0).map((e) => e.textContent)
    return { opener: rows.some((t) => t.includes(P1)), reply: rows.some((t) => t.includes(R1)), rows: rows.length }
  }, { P1, R1 })
  await p.screenshot({ path: join(OUT, 'hum10-390-B-thread.png') })
  ok('4 390: topic B\'s thread shows A\'s opening line and A\'s reply', inB.opener && inB.reply, inB)

  /* ---- 5. clean: archive what this run left (the card menu's Archive) ---- */
  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, chan)
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: 60000 })
  await sleep(2000)
  const archived = {}
  for (const k of ['D2', 'P2', 'D1', 'P1']) {
    const id = res.lines[k]?.msg_id
    const sel = `.spool-main article.msg[data-msg-id="${id}"]`
    if (!id || !(await p.$(sel))) { archived[k] = 'not a card'; continue }
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    await p.waitForSelector('[data-testid=msg-menu-archive]', { timeout: 6000 }).catch(() => {})
    await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
    let gone = false
    for (let i = 0; i < 20 && !gone; i++) { await sleep(300); gone = !(await p.$(sel)) }
    archived[k] = gone ? 'archived' : 'still listed'
  }
  ok('5 clean: D2 and P2 archived (D1 and P1 live inside them)', archived.D2 === 'archived' && archived.P2 === 'archived', archived)
} catch (e) {
  const pages = await browser.pages().catch(() => [])
  const last = pages[pages.length - 1]
  if (last) await last.screenshot({ path: join(OUT, 'hum10-error.png') }).catch(() => {})
  ok('no exception', false, { error: String(e).slice(0, 300), at: last ? last.url() : '' })
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
const failed = res.checks.filter((c) => !c.ok)
console.log(`\nmerge-touch-live: ${res.checks.length - failed.length}/${res.checks.length} OK`)
process.exit(failed.length ? 1 : 0)
