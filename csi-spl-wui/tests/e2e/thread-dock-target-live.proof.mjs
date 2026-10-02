// SPL-1003 - live proof, signed in, against a DEPLOYED WUI + hub: on a phone a
// post made while a thread is open goes INTO that thread (is_parent 0), the
// dock says so before the send, and after Back the dock says "new topic" and
// the post is one (is_parent 1). It WRITES: 1 + 2 short test lines per width
// into CHANNEL of a test tenant (dev t1 test member / prd e2e).
//
//   0 (1440) L opening, pane closed -> a new topic (is_parent 1)
//   per width 390 / 820 (touch):
//     1 the list (level 2): dock reads "new topic"
//     2 tap L's card (level 3): dock reads "thread"; post R -> is_parent 0 on
//       L's task, drawn in the thread only
//     3 Back (level 2): dock reads "new topic"; post N -> is_parent 1, a card
//   1440: no dock hint anywhere
// is_parent is read from the row the hub acked into the page; every line's
// msg_id goes to OUT/results.json so the stored row can be checked in the DB
// (do_spl_db_query). Screenshots OUT/thread-dock-target-<w>-<step>.png.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> CHANNEL=<id>
//     [TENANT=e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/thread-dock-target-live.proof.mjs
//
// Nothing is written unless the session claim t AND the page host's tenant are
// TENANT (SPL-959: the apex writes to t1). The password is never printed.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const CHANNEL = need('CHANNEL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, checks: [], lines: {} }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: pass, ev })
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

const state = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
  const hint = [...document.querySelectorAll('[data-test=dock-target]')].find((el) => el.getClientRects().length > 0)
  return {
    thread: (s.topic && s.topic.open && s.topic.parentTaskId) || (s['live-pane'] && s['live-pane'].taskId) || '',
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    hint: hint ? { mode: hint.getAttribute('data-mode'), text: hint.textContent.trim() } : null,
  }
})

/** Where the page tenant is: the session claim and the page host's tenant. */
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

/** The row the page holds for this line (the hub ack replaced the pending one), and where it is drawn. */
function where(p, text) {
  return p.evaluate((body) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
    const pools = [s.channel && s.channel.messages, s['live-pane'] && s['live-pane'].messages].filter(Array.isArray)
    const m = pools.flat().find((x) => String(x.body || '').includes(body) && !x.pending)
    const byText = (root) => [...document.querySelectorAll(`${root} article.msg`)]
      .filter((el) => el.getClientRects().length > 0 && el.textContent.includes(body)).length
    return {
      msg_id: m ? m.msg_id : '',
      task_id: m ? m.task_id : '',
      is_parent: m ? m.is_parent : null,
      list: byText('.spool-main'),
      thread: byText('aside.live-pane'),
    }
  }, text)
}

async function send(p, text) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.waitForSelector(ta, { timeout: 30000 })
  await p.focus(ta)
  await p.type(ta, text)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  for (let i = 0; i < 20; i++) {
    await sleep(500)
    const w = await where(p, text)
    if (w.msg_id) return w
  }
  return where(p, text)
}

async function cardOf(p, text) {
  return p.evaluate((body) => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.textContent.includes(body))
    if (!el) return null
    el.scrollIntoView({ block: 'center' })
    /* aim at the line's own text: the header's badge / time / menu are buttons */
    const range = document.createRange()
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node = walker.nextNode()
    while (node && !node.textContent.includes(body)) node = walker.nextNode()
    const r = node ? (range.selectNodeContents(node), range.getBoundingClientRect()) : el.getBoundingClientRect()
    return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + r.height / 2) }
  }, text)
}

const tag = `spl1003-${Date.now().toString(36)}`
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
  ok('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...tn })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'tag', tag)
  const chan = BASE + '/channel/' + encodeURIComponent(CHANNEL)

  await nav(p, chan)
  await p.waitForSelector('.spool-main', { timeout: 60000 })
  await sleep(1500)
  const L = `${tag} L opening`
  const w0 = await send(p, L)
  res.lines.L = w0
  const d0 = await state(p)
  ok('1440px 0 pane closed: a new topic (is_parent 1); no dock hint on the desktop', w0.is_parent === 1 && w0.list === 1 && d0.hint === null, { w0, d0 })

  for (const [w, h] of [[390, 844], [820, 1180]]) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    await nav(p, chan)
    await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: 60000 })
    await sleep(1500)
    const s1 = await state(p)
    await p.screenshot({ path: join(OUT, `thread-dock-target-${w}-1-list.png`) })
    ok(`${w}px 1 the list (level 2): the dock says new topic`, s1.level === '2' && Boolean(s1.hint && s1.hint.mode === 'new'), s1)

    const c = await cardOf(p, L)
    if (c) await p.touchscreen.tap(c.x, c.y)
    await sleep(1500)
    const s2 = await state(p)
    await p.screenshot({ path: join(OUT, `thread-dock-target-${w}-2-thread.png`) })
    const R = `${tag} R ${w} reply in the open thread`
    const r2 = await send(p, R)
    res.lines[`R_${w}`] = r2
    await sleep(800)
    await p.screenshot({ path: join(OUT, `thread-dock-target-${w}-2-sent.png`) })
    ok(`${w}px 2 a thread open (level 3): the dock says thread`, s2.level === '3' && s2.thread === w0.task_id && Boolean(s2.hint && s2.hint.mode === 'thread'), s2)
    ok(`${w}px 2 the post is is_parent 0 on L's task, drawn in the thread only`, r2.is_parent === 0 && r2.task_id === w0.task_id && r2.list === 0 && r2.thread === 1, r2)

    await p.evaluate(() => {
      const b = [...document.querySelectorAll('[data-testid=mobile-back]')].find((el) => el.getClientRects().length > 0)
      b && b.click()
    })
    await sleep(1500)
    const s3 = await state(p)
    const N = `${tag} N ${w} after Back`
    const r3 = await send(p, N)
    res.lines[`N_${w}`] = r3
    await sleep(800)
    await p.screenshot({ path: join(OUT, `thread-dock-target-${w}-3-back.png`) })
    ok(`${w}px 3 Back (level 2): the dock says new topic`, s3.level === '2' && !s3.thread && Boolean(s3.hint && s3.hint.mode === 'new'), s3)
    ok(`${w}px 3 the post after Back is a new topic (is_parent 1), a list card`, r3.is_parent === 1 && r3.task_id !== w0.task_id && r3.list === 1, r3)
  }
} catch (e) {
  const pages = await browser.pages().catch(() => [])
  const last = pages[pages.length - 1]
  if (last) await last.screenshot({ path: join(OUT, 'thread-dock-target-error.png') }).catch(() => {})
  ok('no exception', false, { error: String(e).slice(0, 300), at: last ? last.url() : '' })
} finally {
  await browser.close()
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
}
const failed = res.checks.filter((c) => !c.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed.length ? 1 : 0)
