// ERR-CLIENT-20261011-071556-99F1 (owner, t1 3b5f7c04) - live probe, signed
// in, against a DEPLOYED WUI + hub. The owner sent a long pasted post
// (paragraphs, links) into a topic open in the RIGHT pane, the topic list in
// the middle, and Vue threw "Failed to execute 'insertBefore' on 'Node'". The
// mock e2e never takes the live send path (the pending row, the WS echo, the
// ack), so this probe drives that path and records, per run:
//   - every insertBefore / removeChild / appendChild that throws, with its JS
//     stack and the parent / reference nodes it named (instrumented before
//     the app boots)
//   - console errors and warnings, page errors
//   - every ErrorNotice and error snackbar item on screen
// with the owner's settings applied in the page only (never saved): newest
// first, composer on top, send with Ctrl+Enter. It WRITES: per run one short
// starter line and one long reply into CHANNEL of a test tenant.
//
//   run A (RUNS times): post a starter, open its topic in the right pane, paste
//     the long post, Ctrl+Enter
//   run B (RUNS times): open the topic of the 3rd middle card (so the reply
//     moves it to the top of the list), paste, Ctrl+Enter
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> CHANNEL=<id>
//     [TENANT=e2e] [RUNS=3] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/insertbefore-send-live.proof.mjs
//
// Exit 0 always (a probe, not a gate); the last line says REPRODUCED n/N.
// OUT/results.json holds every capture, OUT/insertbefore-<run>.png the screen.
// On prd run it only at the e2e tenant's host, never the apex (t1's host,
// SPL-959). The password is read from PW_FILE and never printed.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const CHANNEL = need('CHANNEL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const RUNS = Math.max(1, Number(process.env.RUNS || 3))
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const BOX = 'form.composer.omnibox--global textarea'
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, runs: [] }

/* Before any app code: a DOM call that throws leaves its stack and its nodes. */
function instrument() {
  const desc = (n) => {
    if (!n) return String(n)
    if (n.nodeType === 3) return `#text(${JSON.stringify(String(n.textContent).slice(0, 40))})`
    if (n.nodeType === 8) return `#comment(${JSON.stringify(String(n.textContent).slice(0, 40))})`
    const el = n
    const attrs = ['data-test', 'data-testid', 'data-msg-id', 'data-pane'].map((a) => el.getAttribute && el.getAttribute(a) ? `[${a}=${el.getAttribute(a)}]` : '').join('')
    return `${el.nodeName}${el.id ? '#' + el.id : ''}${typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.') : ''}${attrs}`
  }
  const path = (n) => { const out = []; for (let x = n; x && out.length < 8; x = x.parentNode) out.push(desc(x)); return out.join(' < ') }
  window.__ibFails = []
  for (const name of ['insertBefore', 'removeChild', 'appendChild', 'replaceChild']) {
    const orig = Node.prototype[name]
    Node.prototype[name] = function (...args) {
      try {
        return orig.apply(this, args)
      } catch (e) {
        window.__ibFails.push({
          call: name, at: new Date().toISOString(), error: String(e && e.message),
          parent: path(this), node: path(args[0]), ref: args[1] === undefined ? undefined : path(args[1]),
          refParent: args[1] && args[1].parentNode ? path(args[1].parentNode) : null,
          stack: String(e && e.stack || '').split('\n').slice(1, 40).join('\n'),
        })
        throw e
      }
    }
  }
}

function longPost(tag) {
  const o = BASE
  return [
    `${tag} long pasted post, probe for ERR-CLIENT-20261011-071556-99F1.`,
    `First paragraph with an external link https://example.org/one and the channel ${o}/channel/${CHANNEL} in the middle of the text, lorem ipsum dolor sit amet, consectetur adipiscing elit.`,
    `Second paragraph: [a markdown link](https://example.org/two), **bold**, \`inline code\`, and a time 07:15Z on the reader's clock.`,
    '- a list item with https://example.org/three\n- another one with a link to the help page ' + o + '/help',
    `Third paragraph, long: ${'sed do eiusmod tempor incididunt ut labore et dolore magna aliqua '.repeat(6)}`,
    '```\nsome pasted code\nline 2\n```',
    `Last paragraph with https://example.org/four?q=1&r=2 and the end.`,
  ].join('\n\n')
}

async function nav(p, url) {
  for (let i = 0; i < 4; i++) {
    try { return await p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }) } catch (e) {
      if (!String(e).includes('ERR_NETWORK_CHANGED') || i === 3) throw e
      await sleep(1500)
    }
  }
}

/* the owner's settings, in this page only (the claims mirror; nothing is saved) */
const ownerSettings = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const s = pinia._s.get('session')
  s.claims = { ...(s.claims || {}), message_order: 'newest-first', composer_position: 'top', submit_key: 'ctrl-enter' }
})

/** Paste the text as a browser does (a paste event, then the text at the caret), then Ctrl+Enter. */
async function pasteAndSend(p, text) {
  await p.waitForSelector(BOX, { timeout: 30000 })
  await p.focus(BOX)
  await p.evaluate((sel, t) => {
    const el = document.querySelector(sel)
    const dt = new DataTransfer()
    dt.setData('text/plain', t)
    const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true })
    if (el.dispatchEvent(ev)) {
      el.setRangeText(t, el.selectionStart, el.selectionEnd, 'end')
      el.dispatchEvent(new Event('input', { bubbles: true }))
    }
  }, BOX, text)
  await sleep(400)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

async function typeAndSend(p, text) {
  await p.waitForSelector(BOX, { timeout: 30000 })
  await p.focus(BOX)
  await p.type(BOX, text)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

/** Click the middle card whose text holds `text`, or the nth visible card. */
async function openCard(p, { text = '', nth = 0 } = {}) {
  const at = await p.evaluate((body, n) => {
    const cards = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].filter((e) => e.getBoundingClientRect().height > 20)
    const el = body ? cards.find((e) => e.textContent.includes(body)) : cards[n]
    if (!el) return null
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    return { id: el.getAttribute('data-msg-id'), x: Math.round(r.left + Math.min(60, r.width / 2)), y: Math.round(r.top + Math.min(14, r.height / 2)) }
  }, text, nth)
  if (!at) return null
  await p.mouse.click(at.x, at.y)
  await sleep(1500)
  return at
}

const capture = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const s = pinia.state.value
  return {
    fails: window.__ibFails.slice(),
    notices: [...document.querySelectorAll('.error-notice')].map((e) => ({ test: e.getAttribute('data-test'), text: e.textContent.replace(/\s+/g, ' ').trim().slice(0, 300) })),
    snack: [...document.querySelectorAll('[data-test=error-snackbar-item]')].map((e) => e.textContent.replace(/\s+/g, ' ').trim().slice(0, 300)),
    topic: (s.topic && s.topic.open && s.topic.parentTaskId) || '',
    rightCards: document.querySelectorAll('aside.live-pane article.msg').length,
    boxLeft: (document.querySelector('form.composer.omnibox--global textarea') || {}).value?.length ?? -1,
  }
})

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
})
const tagBase = `ib-${Date.now().toString(36)}`
let reproduced = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.evaluateOnNewDocument(instrument)
  let logs = []
  p.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warn' || m.type() === 'warning') logs.push(`${m.type()}: ${m.text().slice(0, 600)}`) })
  p.on('pageerror', (e) => logs.push(`pageerror: ${String(e && e.stack || e).slice(0, 1200)}`))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(1500)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build), 'tag', tagBase)
  const chan = BASE + '/channel/' + encodeURIComponent(CHANNEL)

  for (let i = 0; i < 2 * RUNS; i++) {
    const kind = i < RUNS ? 'A' : 'B'
    const tag = `${tagBase}-${kind}${i % RUNS + 1}`
    logs = []
    await nav(p, chan)
    await p.waitForSelector('.spool-main', { timeout: 60000 })
    await sleep(1200)
    await ownerSettings(p)
    await p.evaluate(() => { window.__ibFails.length = 0 })
    let opened
    if (kind === 'A') {
      await typeAndSend(p, `${tag} starter`)
      await sleep(2500)
      opened = await openCard(p, { text: `${tag} starter` })
    } else {
      opened = await openCard(p, { nth: 2 })
    }
    const before = await capture(p)
    await pasteAndSend(p, longPost(tag))
    await sleep(6000)
    const after = await capture(p)
    await p.screenshot({ path: join(OUT, `insertbefore-${tag}.png`) })
    const hit = after.fails.length > 0 || after.notices.some((n) => /insertBefore|not a child/i.test(n.text)) || after.snack.some((t) => /insertBefore|not a child/i.test(t)) || logs.some((l) => /insertBefore|not a child/i.test(l))
    if (hit) reproduced++
    const run = { tag, kind, opened, before: { topic: before.topic, rightCards: before.rightCards }, after, logs, reproduced: hit }
    res.runs.push(run)
    console.log(`  ${hit ? 'REPRO' : 'clean'} run ${tag}: topic=${after.topic ? after.topic.slice(0, 8) : '-'} right=${after.rightCards} box=${after.boxLeft} fails=${after.fails.length} notices=${after.notices.length} snack=${after.snack.length} console=${logs.length}`)
    for (const f of after.fails) console.log(`    ${f.call} THREW ${f.error}\n      parent ${f.parent}\n      node   ${f.node}\n      ref    ${f.ref}\n      refParent ${f.refParent}\n      stack\n${f.stack.split('\n').map((l) => '        ' + l).join('\n')}`)
    for (const n of after.notices) console.log(`    notice ${n.test}: ${n.text}`)
    for (const t of after.snack) console.log(`    snackbar: ${t}`)
    for (const l of logs) console.log(`    ${l}`)
  }
} finally {
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(`REPRODUCED ${reproduced}/${2 * RUNS} (results: ${join(OUT, 'results.json')})`)
