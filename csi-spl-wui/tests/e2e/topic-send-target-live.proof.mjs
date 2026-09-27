// SPL-996 - live proof, signed in, against a DEPLOYED WUI + hub: a post made
// while a topic is open goes INTO that topic (is_parent 0), and every message
// is drawn exactly once, where it belongs. It WRITES: 4 short test lines per
// run into CHANNEL of a test tenant (dev t1 test member / prd e2e).
//
//   0 (1440) pane closed, send L1 -> a new topic: one middle card, is_parent 1
//   1 (1440) open L1's topic, then the APP focuses a middle card (a #hash, an
//     edit close - not the reader), send -> is_parent 0 on L1's task, drawn in
//     the right pane only, no born card anywhere
//   2 (1440) the reader clicks the middle list (owner rule 2026-09-25), send ->
//     a new topic, drawn ONCE: a middle card, nothing in the right pane
//   3 (390, 820, touch) tap L1's card (level 3), send from the docked composer
//     -> is_parent 0 on L1's task, not a middle card
//   4 reload: the replies are still not middle cards, L1's card still reads L1
// is_parent is read from the row the hub acked into the page's store, and each
// line's msg_id is written to OUT/results.json so it can be checked in the DB.
// Screenshots OUT/topic-send-target-<w>-<step>.png.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> CHANNEL=<id>
//     [TENANT=e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/topic-send-target-live.proof.mjs
//
// On prd run it only at the e2e tenant's host, never the apex (t1's host,
// SPL-959). The password is read from PW_FILE and never printed.
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
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, checks: [], lines: {} }
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

const state = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
  return {
    last: s['pane-focus'] && s['pane-focus'].last,
    topic: (s.topic && s.topic.open && s.topic.parentTaskId) || (s['live-pane'] && s['live-pane'].taskId) || '',
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'),
  }
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
      middle: byText('.spool-main'),
      right: byText('aside.live-pane'),
      born: document.querySelectorAll('[data-test=born-topics] article.msg').length,
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
    /* aim at the line's own text: the header's badge / time / menu are buttons
       (at 390 px a header tap hit the kind badge and opened its sheet) */
    const range = document.createRange()
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let node = walker.nextNode()
    while (node && !node.textContent.includes(body)) node = walker.nextNode()
    const r = node ? (range.selectNodeContents(node), range.getBoundingClientRect()) : el.getBoundingClientRect()
    return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + r.height / 2) }
  }, text)
}

const tag = `spl996-${Date.now().toString(36)}`
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
  res.host = new URL(p.url()).hostname
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'host', res.host, 'tag', tag)
  const chan = BASE + '/channel/' + encodeURIComponent(CHANNEL)

  /* 0: L1, pane closed */
  await nav(p, chan)
  await p.waitForSelector('.spool-main', { timeout: 60000 })
  await sleep(1500)
  const L1 = `${tag} L1 opening`
  const w0 = await send(p, L1)
  res.lines.L1 = w0
  ok('1440px 0 pane closed: a new topic, is_parent 1, one middle card', w0.is_parent === 1 && w0.middle === 1 && w0.right === 0, w0)

  /* 1: open L1's topic, the app focuses a middle card */
  const c1 = await cardOf(p, L1)
  if (c1) await p.mouse.click(c1.x, c1.y)
  await sleep(1500)
  const s1 = await state(p)
  await p.evaluate((id) => {
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur()
    document.querySelector(`.spool-main article.msg[data-msg-id="${CSS.escape(id)}"]`)?.focus({ preventScroll: true })
  }, c1 ? c1.id : '')
  await sleep(300)
  const s1b = await state(p)
  const R1 = `${tag} R1 reply after an app focus`
  const w1 = await send(p, R1)
  res.lines.R1 = w1
  await p.screenshot({ path: join(OUT, 'topic-send-target-1440-1.png') })
  ok('1440px 1 topic open + an app-made focus in the middle: is_parent 0 into L1\'s topic, right pane only, no born card',
    w1.is_parent === 0 && w1.task_id === w0.task_id && w1.middle === 0 && w1.right === 1 && w1.born === 0, { s1, s1b, w1 })

  /* 2: the reader clicks the middle list */
  const spot = await p.evaluate(() => {
    const h = document.querySelector('.spool-main .feed-header') || document.querySelector('.spool-main')
    const r = h.getBoundingClientRect()
    return { x: Math.round(r.left + r.width - 60), y: Math.round(r.top + r.height / 2) }
  })
  await p.mouse.click(spot.x, spot.y)
  await sleep(300)
  const s2 = await state(p)
  const N2 = `${tag} N2 new topic after a middle click`
  const w2 = await send(p, N2)
  res.lines.N2 = w2
  await p.screenshot({ path: join(OUT, 'topic-send-target-1440-2.png') })
  ok('1440px 2 the reader clicked the middle: a new topic, drawn ONCE (middle card, nothing in the right pane)',
    w2.is_parent === 1 && w2.task_id !== w0.task_id && w2.middle === 1 && w2.right === 0 && w2.born === 0, { s2, w2 })

  /* 3: phones - tap L1's card, send from the dock */
  for (const [w, h] of [[390, 844], [820, 1180]]) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    await nav(p, chan)
    await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: 60000 })
    await sleep(1500)
    const c = await cardOf(p, L1)
    if (c) await p.touchscreen.tap(c.x, c.y)
    await sleep(1500)
    const s3 = await state(p)
    const R3 = `${tag} R3 phone ${w} reply from the dock`
    const w3 = await send(p, R3)
    res.lines[`R3_${w}`] = w3
    await p.screenshot({ path: join(OUT, `topic-send-target-${w}.png`) })
    ok(`${w}px 3 level 3, docked composer: is_parent 0 into L1's topic, drawn in the topic only`,
      s3.level === '3' && w3.is_parent === 0 && w3.task_id === w0.task_id && w3.middle === 0 && w3.right === 1 && w3.born === 0, { s3, w3 })
  }

  /* 4: reload, desktop */
  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, chan)
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: 60000 })
  await sleep(2000)
  const after = await p.evaluate((t) => {
    const cards = [...document.querySelectorAll('.spool-main article.msg')].filter((el) => el.textContent.includes(t))
    return { cards: cards.length, texts: cards.map((el) => (el.textContent.match(/spl996-\w+ (\w+)/) || [])[1]) }
  }, tag)
  ok('1440px 4 reload: the middle holds exactly the 2 openings (L1, N2), no reply as a card', after.cards === 2 && after.texts.includes('L1') && after.texts.includes('N2'), after)
} catch (e) {
  const pages = await browser.pages().catch(() => [])
  const last = pages[pages.length - 1]
  const at = last ? last.url() : ''
  if (last) await last.screenshot({ path: join(OUT, 'topic-send-target-error.png') }).catch(() => {})
  ok('no exception', false, { error: String(e).slice(0, 300), at })
} finally {
  await browser.close()
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
}
const failed = res.checks.filter((c) => !c.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.checks.length}` : `${res.checks.length}/${res.checks.length} checks passed`)
process.exit(failed.length ? 1 : 0)
