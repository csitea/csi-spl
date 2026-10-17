// CLE-77804 (topic 35053f95, HUM-10): every topic card in a channel shows its
// own unread count as "<new>/<total> >>" (per reader, from the reader's read
// position in that topic), cleared to a plain "<total> >>" when the thread is
// opened. Real browser, mock tenant.
// SPL-2422 (HUM-10, t1 89010926): the total counts the topic's first message,
// which is 1 new for a reader who has not seen it, and "<new>/<total>" wears the
// channel row's badge (badge-unread: round, filled), a step smaller.
//
//   control   a never-opened topic from before the channel mark: a PLAIN "4 >>" (3 replies + first)
//   unread    a topic read at 5 replies, now 7: "2/8 >>" in a round filled badge
//   first     a fresh topic after the channel mark, only its opening post: "1/1 >>"
//   style     the badge is the channel badge's, its font smaller, legible (>= 3:1) in dark and light
//   cleared   opening a thread -> the card reads a plain total ("8 >>", "1 >>")
//
// The per-topic read snapshot (t:<task_id> = {..,count}) and the channel mark
// are seeded into the same localStorage the cursors use, before the app boots;
// the topic rows are injected through the channel store, as a live frame would.
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/topic-unread-count.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SEEN = 'seen-topic', OLD = 'old-topic', LONE = 'lone-topic'

const signIn = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** Inject a topic-root card into the channel store with a hub reply total, sent at `ts`. */
const injectTopic = (p, taskId, count, ts) => p.evaluate((taskId, count, ts) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const row = { v: 1, msg_id: `m-${taskId}`, task_id: taskId, topic_row: true, count, is_parent: 1, ts, received_at: ts, from: 'HUM-2', from_box: 'box-wui', to: '@channel', channel: 'alerts', kind: 'note', body: `topic ${taskId}`, files: [] }
  s.messages = [...s.messages, row]
}, taskId, count, ts)

/** The topic-replies counter: its text, the new number, and the badge's look next to a channel badge's. */
const counterOf = (p, taskId) => p.evaluate((taskId) => {
  const card = document.querySelector(`article.msg[data-msg-id="m-${taskId}"]`)
  const btn = card && card.querySelector('[data-test=topic-replies]')
  const badge = btn && btn.querySelector('[data-test=topic-new]')
  const num = badge && badge.querySelector('[data-test=topic-unread]')
  const probe = document.createElement('span')
  probe.className = 'badge-unread'
  probe.textContent = '4'
  document.body.appendChild(probe)
  const ch = getComputedStyle(probe)
  const cs = badge && getComputedStyle(badge)
  const out = {
    text: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null,
    unread: num ? num.textContent.trim() : null,
    badge: cs ? { cls: badge.className, radius: parseFloat(cs.borderRadius), bg: cs.backgroundColor, color: cs.color, font: parseFloat(cs.fontSize) } : null,
    channel: { color: ch.color, font: parseFloat(ch.fontSize) },
  }
  probe.remove()
  return out
}, taskId)

/** WCAG contrast of two computed rgb() colours. */
function contrast(a, b) {
  const lum = (c) => {
    /* rgb(0..255) or, from color-mix, color(srgb 0..1) */
    const unit = /^color\(srgb/.test(c) ? 1 : 255
    const [r, g, bl] = (c.replace(/^color\(srgb/, '').match(/[\d.]+/g) || []).slice(0, 3).map((v) => { const x = Number(v) / unit; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4 })
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

async function run(browser, base, theme) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1200, height: 760, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* the reader last read SEEN (at 09:30, when it had 5 replies) and #alerts at 08:30; OLD and LONE were never opened */
  await p.evaluateOnNewDocument((seen, theme) => {
    try {
      localStorage.setItem('spool-theme', theme)
      localStorage.setItem('spool.read-cursors', JSON.stringify({
        [`t:${seen}`]: { ts: '2026-09-18T09:30:00.000Z', id: '', count: 5 },
        'ch:alerts': { ts: '2026-09-18T08:30:00.000Z', id: '' },
      }))
    } catch { /* */ }
  }, SEEN, theme)

  await p.goto(`${base}/channel/alerts`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })

  await injectTopic(p, OLD, 3, '2026-09-18T08:00:00.000Z')
  await injectTopic(p, SEEN, 7, '2026-09-18T09:00:00.000Z')
  await injectTopic(p, LONE, 0, '2026-09-18T09:10:00.000Z')
  await sleep(800)

  const old = await counterOf(p, OLD)
  check(`${theme}: a never-opened topic from before the channel mark reads a plain "4 >>" (3 replies + its first message)`, old.text === '4 >>' && old.badge === null, old)

  const seen = await counterOf(p, SEEN)
  check(`${theme}: a topic read at 5 replies, now 7, reads "2/8 >>"`, seen.text === '2/8 >>' && seen.unread === '2', seen)
  const b = seen.badge
  check(`${theme}: "<new>/<total>" is the channel badge: badge-unread, round, filled, its number colour`, Boolean(b && /\bbadge-unread\b/.test(b.cls) && b.radius >= 9 && b.bg !== 'rgba(0, 0, 0, 0)' && b.color === seen.channel.color), seen)
  check(`${theme}: a step smaller than the channel badge`, Boolean(b && b.font < seen.channel.font), seen)
  check(`${theme}: its number is legible on its fill (>= 3:1)`, Boolean(b && contrast(b.bg, b.color) >= 3), b && { ratio: contrast(b.bg, b.color) })

  const lone = await counterOf(p, LONE)
  check(`${theme}: a fresh topic with only its unseen opening post reads "1/1 >>"`, lone.text === '1/1 >>' && lone.unread === '1' && Boolean(lone.badge), lone)

  /* open the threads -> their totals are snapshotted -> the cards clear to plain */
  for (const id of [SEEN, LONE]) {
    await p.evaluate((taskId) => document.querySelector(`article.msg[data-msg-id="m-${taskId}"]`).click(), id)
    await sleep(800)
  }
  const after = await counterOf(p, SEEN)
  check(`${theme}: opening the thread clears it to a plain total "8 >>"`, after.text === '8 >>' && after.unread === null, after)
  const loneAfter = await counterOf(p, LONE)
  check(`${theme}: opening the fresh topic marks its first message seen: "1 >>"`, loneAfter.text === '1 >>' && loneAfter.unread === null, loneAfter)

  const errs = await p.evaluate(() => window.__errs || [])
  check(`${theme}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const theme of ['dark', 'light']) await run(browser, server.base, theme)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-unread-count: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
