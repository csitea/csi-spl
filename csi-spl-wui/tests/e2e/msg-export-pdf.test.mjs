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
//   topic open A's topic, press the header's "Export topic to PDF": the
//         render holds the topic title and exactly the cards the pane shows,
//         in that order (A's picture included, B absent); the document is
//         named after the topic
//
// Red controls (each seen RED on a bundle with the planted defect):
//   - useCardExportPdf printing every channel row (rows: channel.messages):
//     "card: exactly that card" and "card: nothing of the neighbour" FAIL
//   - TopicExportPdf printing every channel row (rows: channel.messages):
//     "topic: exactly the cards shown, in order" and "topic: the reply and
//     the picture print, the neighbour does not" FAIL
//   (dropping rowsInShownOrder alone stays green here: this pane's rows are
//   already in shown order; tests/unit/msg-print.test.mjs holds its control)
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/msg-export-pdf.test.mjs
//   SHOTS_DIR=<dir> ... also writes card.pdf and topic.pdf
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
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
  if (SHOTS) await p.pdf({ path: `${SHOTS}/${name}.pdf`, format: 'A4', printBackground: true })
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
  await savePdf(p, 'card')
  await p.evaluate(() => window.dispatchEvent(new Event('afterprint')))
  ok('card: after the print the render is gone', await until(p, () => !document.querySelector('[data-test=msg-print-host]') && !document.documentElement.classList.contains('msg-printing')))
}

/* topic: the header's button prints the pane, as shown */
async function topicCase(p, ids, tag) {
  await p.evaluate((task) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').openTopic(task), ids.a.task_id)
  const shown = await until(p, (id) => Boolean(document.querySelector(`[data-test=topic-root] article.msg[data-msg-id="${id}"]`)), ids.r.msg_id)
  const btn = await until(p, () => Boolean(document.querySelector('[data-test=topic-export-pdf]')))
  ok('topic: the pane shows the reply and the header has Export topic to PDF', shown && btn)
  const label = await p.evaluate(() => document.querySelector('[data-test=topic-export-pdf]')?.getAttribute('aria-label') || '')
  ok('topic: the button is labelled', label === 'Export topic to PDF', label)
  const want = await p.evaluate(() => [...document.querySelectorAll('[data-test=topic-root] article.msg[data-msg-id]')].map((e) => e.getAttribute('data-msg-id')))
  const heading = await p.evaluate(() => document.querySelector('[data-test=topic-heading] .topic-heading__text')?.textContent?.trim() || '')
  await p.evaluate(() => { window.__printCalls = 0 })
  await p.focus('[data-test=topic-export-pdf]')
  await p.keyboard.press('Enter')
  await until(p, () => Boolean(document.querySelector('[data-test=msg-print-host][data-ready=true]')), undefined, 20000)
  const got = await printed(p)
  ok('topic: print runs once (Enter on the focused button)', got?.calls === 1, got?.calls)
  ok('topic: exactly the cards shown, in order', want.length >= 2 && JSON.stringify(got?.ids) === JSON.stringify(want), { want, got: got?.ids })
  ok('topic: the title heads it', Boolean(heading) && got?.heading === heading, { heading, got: got?.heading })
  ok('topic: the reply and the picture print, the neighbour does not', got && got.text.includes(`PDF-A-REPLY ${tag}`) && got.imgs.length === 1 && got.imgs[0].loaded && !got.text.includes('PDF-B'), got && { imgs: got.imgs })
  ok('topic: the file is named after the topic', Boolean(got?.docTitle) && !/-[0-9a-f]{8}$/.test(got.docTitle) && got.docTitle.startsWith('pdf-a-'), got?.docTitle)
  await savePdf(p, 'topic')
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
  await cardCase(p, ids, tag)
  await topicCase(p, ids, tag)
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
