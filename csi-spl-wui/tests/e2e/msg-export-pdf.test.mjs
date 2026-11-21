// SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020): "add
// the export to pdf entry in the right click menu of each msg card, which will
// export only the msg card content into pdf (including the pics in it) add
// also the export to pdf for a whole topic". On the mock bundle, 1440 px.
//
// The PDF is the browser's own print (Save as PDF), so the test stubs
// window.print and reads the print render it was called on; with print media
// emulated it also writes the two PDFs when SHOTS_DIR is set.
//
// Cases:
//   card  right-click card A (a picture and a line of text), reach "Export to
//         PDF" with the arrow keys, Enter: print runs once on a render that
//         holds exactly card A - its text, its picture loaded - and nothing
//         of its neighbour card B; the document is named <topic>-<msg8>
//   topic (SPL-6205, owner t1 f798e9aa msg a1ca02fb) right-click topic card A
//         in the channel, "Export topic to PDF" (right after Export to PDF):
//         the render holds the topic title and every post of the topic, first
//         to last (A's picture included, B absent); the document is named
//         after the topic. Inside the open topic: no header button, and a
//         reply's menu has its own Export to PDF only
//   long  (SPL-6023, SPL-6205) a topic of 41 posts, more than the pane's
//         first read (opener + 30): the channel card's menu prints all 41,
//         first to last, several A4 pages, the link of every post in the PDF;
//         the single-card PDF is one page
//
// Red controls (each seen RED on a bundle with the planted defect):
//   - useCardExportPdf printing every channel row (rows: channel.messages):
//     "card: exactly that card" and "card: nothing of the neighbour" FAIL
//   - TopicExportPdf printing every channel row (rows: channel.messages):
//     "topic: exactly the cards shown, in order" and "topic: the reply and
//     the picture print, the neighbour does not" FAIL
//   - MessagePrint.vue's print styles without the html/body reset (the
//     screen's overflow: hidden + height: 100dvh): "long topic: the PDF has
//     more than one page", "the last printed card is in the PDF" and
//     "every card is in the PDF" FAIL
//   (dropping rowsInShownOrder alone stays green here: this pane's rows are
//   already in shown order; tests/unit/msg-print.test.mjs holds its control)
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/msg-export-pdf.test.mjs
//   SHOTS_DIR=<dir> ... also writes card.pdf, topic.pdf and topic-long.pdf
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, writeFileSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS_DIR || ''
const CH = 'pdf-export-5888'
if (SHOTS) mkdirSync(SHOTS, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 10000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`

/* a channel with topic A (text + one real PNG, drawn on a canvas), its reply,
   and topic B, the neighbour that must never print with A */
const seed = (p, tag) => p.evaluate(async ({ CH, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const png = await new Promise((resolve) => {
    const c = document.createElement('canvas')
    c.width = 320
    c.height = 120
    const g = c.getContext('2d')
    g.fillStyle = '#2a6'
    g.fillRect(0, 0, 320, 120)
    g.fillStyle = '#fff'
    g.fillRect(80, 30, 160, 60)
    c.toBlob((b) => resolve(new File([b], 'pdf-pic.png', { type: 'image/png' })), 'image/png')
  })
  const a = await ch.send(`PDF-A ${tag} the card to export`, undefined, [png], CH, 1)
  const r = await ch.send(`PDF-A-REPLY ${tag} a reply in topic A`, a.task_id, [], CH, 0)
  const b = await ch.send(`PDF-B ${tag} the neighbour card`, undefined, [], CH, 1)
  return { a: { msg_id: a.msg_id, task_id: a.task_id }, r: { msg_id: r.msg_id }, b: { msg_id: b.msg_id } }
}, { CH, tag })

/* what the stubbed print was called on */
const printed = (p) => p.evaluate(() => {
  const host = document.querySelector('[data-test=msg-print-host][data-ready=true]')
  if (!host) return null
  const imgs = [...host.querySelectorAll('[data-test=msg-print-img] img')]
  return {
    calls: window.__printCalls,
    printing: document.documentElement.classList.contains('msg-printing'),
    docTitle: document.title,
    heading: host.querySelector('[data-test=msg-print-title]')?.textContent?.trim() || '',
    ids: [...host.querySelectorAll('[data-test=msg-print-card]')].map((e) => e.getAttribute('data-msg-id')),
    text: host.textContent || '',
    imgs: imgs.map((i) => ({ loaded: i.complete && i.naturalWidth > 0, alt: i.alt })),
  }
})

/* page.pdf prints with print media, as Save as PDF does (it also fires afterprint) */
async function savePdf(p, name) {
  const buf = Buffer.from(await p.pdf({ format: 'A4', printBackground: true }))
  if (SHOTS) writeFileSync(`${SHOTS}/${name}.pdf`, buf)
  return buf
}

/* card: the right-click menu, reached by keyboard */
async function cardCase(p, ids, tag) {
  await p.waitForSelector(midCard(ids.a.msg_id), { timeout: 10000 })
  await until(p, (sel) => Boolean(document.querySelector(`${sel} [data-test=file-preview] img`)), midCard(ids.a.msg_id))
  /* on the text: the picture is a button, which keeps the browser's own menu */
  await p.click(`${midCard(ids.a.msg_id)} .msg-body`, { button: 'right' })
  const opened = await until(p, () => document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]').length > 0)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  ok('card: the right-click menu lists Export to PDF', opened && items.includes('msg-menu-export-pdf'), items)
  let reached = false
  for (let i = 0; i < items.length + 1 && !reached; i++) {
    await p.keyboard.press('ArrowDown')
    reached = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') === 'msg-menu-export-pdf')
  }
  ok('card: the arrow keys reach Export to PDF', reached)
  if (reached) await p.keyboard.press('Enter')
  else await p.evaluate(() => document.querySelector('[data-testid=msg-menu-export-pdf]')?.click())
  await until(p, () => Boolean(document.querySelector('[data-test=msg-print-host][data-ready=true]')), undefined, 20000)
  const got = await printed(p)
  ok('card: print runs once, on the print render', got?.calls === 1 && got.printing, got && { calls: got.calls, printing: got.printing })
  ok('card: exactly that card', JSON.stringify(got?.ids) === JSON.stringify([ids.a.msg_id]), got?.ids)
  ok('card: its text', Boolean(got?.text.includes(`PDF-A ${tag}`)))
  ok('card: nothing of the neighbour (nor of its own reply)', got && !got.text.includes('PDF-B') && !got.text.includes('PDF-A-REPLY'))
  ok('card: its picture, loaded', got?.imgs.length === 1 && got.imgs[0].loaded && got.imgs[0].alt === 'pdf-pic.png', got?.imgs)
  ok('card: the file is <topic>-<msg8>', got?.docTitle === `pdf-a-${tag}-the-card-to-export-${ids.a.msg_id.replace(/-/g, '').slice(0, 8)}`, got?.docTitle)
  const pdf = await savePdf(p, 'card')
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))
  ok('card: after the print the render is gone', await until(p, () => !document.querySelector('[data-test=msg-print-host]') && !document.documentElement.classList.contains('msg-printing')))
  return pdf
}

/* SPL-6205 (owner HUM-10, t1 f798e9aa msg a1ca02fb): the topic card's menu in
   the channel prints the whole topic, first to last; no header button */
async function topicMenuExport(p, rootId) {
  await p.waitForSelector(midCard(rootId), { timeout: 10000 })
  await p.click(`${midCard(rootId)} .msg-body`, { button: 'right' })
  const opened = await until(p, () => document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]').length > 0)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  const label = await p.evaluate(() => document.querySelector('[data-testid=msg-menu-export-topic-pdf]')?.textContent?.trim() || '')
  await p.evaluate(() => { window.__printCalls = 0 })
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-export-topic-pdf]')?.click())
  const ready = await until(p, () => Boolean(document.querySelector('[data-test=msg-print-host][data-ready=true]')), undefined, 20000)
  return { opened, items, label, ready }
}

async function topicCase(p, ids, tag) {
  const m = await topicMenuExport(p, ids.a.msg_id)
  ok('topic: the channel topic card menu lists Export topic to PDF after Export to PDF', m.opened && m.items.indexOf('msg-menu-export-topic-pdf') === m.items.indexOf('msg-menu-export-pdf') + 1, m.items)
  ok('topic: the entry is labelled', m.label === 'Export topic to PDF', m.label)
  const got = await printed(p)
  ok('topic: print runs once', m.ready && got?.calls === 1, got?.calls)
  ok('topic: every post of the topic, first to last', JSON.stringify(got?.ids) === JSON.stringify([ids.a.msg_id, ids.r.msg_id]), got?.ids)
  ok('topic: the title heads it', Boolean(got?.heading) && got.heading.includes(`PDF-A ${tag}`), got?.heading)
  ok('topic: the reply and the picture print, the neighbour does not', got && got.text.includes(`PDF-A-REPLY ${tag}`) && got.imgs.length === 1 && got.imgs[0].loaded && !got.text.includes('PDF-B'), got && { imgs: got.imgs })
  ok('topic: the file is named after the topic', Boolean(got?.docTitle) && !/-[0-9a-f]{8}$/.test(got.docTitle) && got.docTitle.startsWith('pdf-a-'), got?.docTitle)
  await savePdf(p, 'topic')
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))
  await until(p, () => !document.querySelector('[data-test=msg-print-host]'))
  /* inside the open topic: no topic export, a post keeps its own */
  await p.evaluate((task) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').openTopic(task), ids.a.task_id)
  const sel = `[data-test=topic-root] article.msg[data-msg-id="${ids.r.msg_id}"]`
  const shown = await until(p, (s) => Boolean(document.querySelector(s)), sel)
  ok('topic pane: no header button', shown && await p.evaluate(() => !document.querySelector('[data-test=topic-export-pdf]')))
  await p.click(`${sel} .msg-body`, { button: 'right' })
  await until(p, () => document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]').length > 0)
  const inner = await p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  ok('topic pane: a reply offers its own Export to PDF, not the topic one', inner.includes('msg-menu-export-pdf') && !inner.includes('msg-menu-export-topic-pdf'), inner)
  await p.keyboard.press('Escape')
  await until(p, () => !document.querySelector('[data-testid=msg-menu]'))
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').close())
}

/* SPL-6023: a topic longer than one A4 page prints every page. The screen
   styles keep html/body at the viewport's height with overflow hidden; in
   print they clipped the export to page 1. */
const LONG_CARDS = 40
const LONG_LINE = 'a line of text long enough to wrap across the width of an A4 page in the print render, '

/* pages of a PDF; Chrome's PDF writes one /Type /Page object per page */
const pdfPages = (buf) => (buf.toString('latin1').match(/\/Type\s*\/Page(?![s\w])/g) || []).length
/* a link's target, written as a /URI annotation only where the link is painted */
const pdfHasUri = (buf, uri) => buf.toString('latin1').includes(`(${uri})`)

const longUri = (tag, i) => `https://example.com/pdf-long-${tag}-${i}`

/* every card (the root is 0) carries its own link, so the PDF shows which cards it painted */
const seedLong = (p, tag) => p.evaluate(async ({ CH, tag, n, line }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  const root = await ch.send(`PDF-LONG ${tag} a topic longer than one page https://example.com/pdf-long-${tag}-0`, undefined, [], CH, 1)
  const ids = { [root.msg_id]: 0 }
  for (let i = 1; i <= n; i++) {
    const r = await ch.send(`PDF-LONG-${i} ${tag} ${line.repeat(3)} https://example.com/pdf-long-${tag}-${i}`, root.task_id, [], CH, 0)
    ids[r.msg_id] = i
  }
  return { task_id: root.task_id, ids }
}, { CH, tag, n: LONG_CARDS, line: LONG_LINE })

/* long topic: page.pdf (print media, as Save as PDF) holds several pages and the last card */
async function longTopicCase(p, tag, cardPdf) {
  ok('card: the single-card PDF is one page', pdfPages(cardPdf) === 1, pdfPages(cardPdf))
  const long = await seedLong(p, tag)
  const cards = Object.keys(long.ids)
  /* SPL-6205: 41 posts, more than the pane's first read (opener + 30): the
     channel card's menu prints them all, first to last, no pane opened */
  const root = cards.find((id) => long.ids[id] === 0)
  const m = await topicMenuExport(p, root)
  const got = await printed(p)
  const order = cards.slice().sort((x, y) => long.ids[x] - long.ids[y])
  ok('long topic: the menu export prints all 41 posts, first to last', m.ready && JSON.stringify(got?.ids) === JSON.stringify(order), got && { n: got.ids.length })
  ok('long topic: the page is in print mode with the render', Boolean(got?.printing), got && { printing: got.printing })
  const lastI = long.ids[got?.ids.at(-1)]
  const buf = Buffer.from(await p.pdf({ format: 'A4', printBackground: true }))
  if (SHOTS) writeFileSync(`${SHOTS}/topic-long.pdf`, buf)
  const pages = pdfPages(buf)
  const missing = Object.values(long.ids).filter((i) => !pdfHasUri(buf, longUri(tag, i)))
  ok('long topic: the PDF has more than one page', pages > 1, pages)
  ok('long topic: the last printed card is in the PDF (its link is painted)', lastI !== undefined && pdfHasUri(buf, longUri(tag, lastI)), { pages, lastI })
  ok('long topic: every card is in the PDF', missing.length === 0, { missing: missing.length })
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))
}

const srv = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument(() => {
    window.__printCalls = 0
    window.print = () => { window.__printCalls++ }
  })
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  const tag = Math.random().toString(36).slice(2, 8)
  const ids = await seed(p, tag)
  const cardPdf = await cardCase(p, ids, tag)
  await topicCase(p, ids, tag)
  await longTopicCase(p, tag, cardPdf)
  ok('no page error', errors.length === 0, errors)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await srv.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nmsg-export-pdf: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
