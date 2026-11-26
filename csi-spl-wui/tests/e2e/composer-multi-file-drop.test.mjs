// SPL-6595 (owner HUM-10, t1 b272081b, msgs 26af2534 and 02c99b68): "if we do
// not support drag and drop multiple files form the file system into a msg or
// topic to result into uploads , we should" - "it should work as the regular
// drag and drop for apps works into web apps , for example if I would like to
// add 10 files as gmail attachments".
//
// In a real browser on the mock tenant, /channel/alerts, a topic open, at 1440
// and at 390 px. A desktop-style drop (dragenter, dragover, drop with a
// DataTransfer of 10 small files: png, pdf, txt) on:
//   A  the open topic's message area (aside.live-pane)
//   B  the composer itself (form.composer.omnibox--global)
// Each case checks:
//   1 dragover and drop are cancelled (defaultPrevented), so the browser does
//     not open the file, and the page is the same document at the same URL
//   2 all 10 files show as picked attachments in the composer, by name
//   3 Send makes ONE message, a reply (is_parent 0) in THAT topic, carrying
//     10 files with 10 distinct file ids and the 10 names
//   4 the mock upload read each dropped file once: 10 upload calls
//   5 the composer is empty after the send; no page error
// CONTROL: PROVE_RED=1 drops only the first file; checks 2, 3 and 4 fail.
//
// Run:
//   pnpm run test:e2e composer-multi-file-drop
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-multi-file-drop   # what CI does
//   PROVE_RED=1 BASE_URL=<generated bundle> node tests/e2e/composer-multi-file-drop.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PROVE_RED = process.env.PROVE_RED === '1'
const PATH = '/channel/alerts'
const FORM = 'form.composer.omnibox--global'
const PANE = 'aside.live-pane'
const N = 10
/* a real 1x1 PNG: a picture the composer previews */
const PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Read until want() holds on the SAME value for `hold` ms, or `max` runs out. */
async function until(read, want = () => true, hold = 300, max = 10000) {
  const end = Date.now() + max
  let key = ''
  let since = 0
  let v = await read()
  while (Date.now() < end) {
    const k = want(v) ? JSON.stringify(v) ?? 'undefined' : ''
    if (!k) { key = ''; since = 0 } else if (k !== key) { key = k; since = Date.now() } else if (Date.now() - since >= hold) return v
    await sleep(100)
    v = await read()
  }
  return v
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the file names of one drop: mixed png, pdf and txt, unique per case */
const namesFor = (tag) => Array.from({ length: N }, (_, i) => `mfd-${tag}-${i}.${['png', 'pdf', 'txt'][i % 3]}`)

/* counts the mock upload's reads (postFile reads each File once with
   arrayBuffer) of the files this test dropped, before any app code runs */
const COUNT_UPLOADS = () => {
  window.__mfdUploads = []
  const orig = Blob.prototype.arrayBuffer
  Blob.prototype.arrayBuffer = function () {
    if (this instanceof File && this.name.startsWith('mfd-')) window.__mfdUploads.push(this.name)
    return orig.call(this)
  }
}

/** A drop from the desktop on `sel`: dragenter, dragover, drop, one DataTransfer. */
const dropFiles = (p, sel, names) => p.evaluate((sel, names, b64) => {
  const el = document.querySelector(sel)
  if (!el) return null
  const png = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  const dt = new DataTransfer()
  for (const name of names) {
    /* unique bytes per file: the mock stores a blob by its sha256 */
    if (name.endsWith('.png')) dt.items.add(new File([png, new TextEncoder().encode(name)], name, { type: 'image/png' }))
    else if (name.endsWith('.pdf')) dt.items.add(new File([`%PDF-1.4\n% ${name}\n%%EOF\n`], name, { type: 'application/pdf' }))
    else dt.items.add(new File([`synthetic text ${name}\n`], name, { type: 'text/plain' }))
  }
  const r = el.getBoundingClientRect()
  const at = { clientX: Math.round(r.left + r.width / 2), clientY: Math.round(r.top + r.height / 2) }
  const fire = (type) => {
    const ev = new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true, composed: true, ...at })
    el.dispatchEvent(ev)
    return ev.defaultPrevented
  }
  window.__mfdMark = 'same-document'
  const href = location.href
  return { enter: fire('dragenter'), over: fire('dragover'), drop: fire('drop'), href, files: dt.files.length }
}, sel, names, PNG_B64)

const picked = (p) => p.evaluate((form) =>
  [...document.querySelectorAll(`${form} .file-chips li`)].map((li) => li.textContent.trim()), FORM)

/** The open topic and the row this page sent (found by its text), from pinia. */
const readState = (p, text) => p.evaluate((text) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const s = pinia.state.value
  const msgs = (s.channel && s.channel.messages) || []
  const sent = msgs.filter((m) => String(m.body || '').includes(text))
  return {
    topic: (s.topic && s.topic.open && s.topic.parentTaskId) || '',
    sent: sent.map((m) => ({
      task_id: m.task_id, parent_task_id: m.parent_task_id || '', is_parent: m.is_parent,
      files: (m.files || []).map((f) => ({ id: f.file_id || '', name: f.name || '' })),
    })),
  }
}, text)

async function firstCard(p) {
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + Math.min(20, r.height / 2)) }
  })
}

async function openTopic(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument(COUNT_UPLOADS)
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${FORM} textarea`, { timeout: NAV_TIMEOUT })
  const card = await until(() => firstCard(p), Boolean)
  if (vp.hasTouch) await p.touchscreen.tap(card.x, card.y)
  else await p.mouse.click(card.x, card.y)
  const opened = await until(() => readState(p, '\u0000'), (v) => Boolean(v.topic))
  await p.waitForSelector(PANE, { visible: true, timeout: 10000 }).catch(() => {})
  return { p, errors, topic: opened.topic }
}

async function dropCase(browser, vp, tag, where, sel) {
  const { p, errors, topic } = await openTopic(browser, vp)
  const names = namesFor(`${tag}-${where}`)
  const dropped = PROVE_RED ? names.slice(0, 1) : names
  const d = await dropFiles(p, sel, dropped)
  const chips = await until(() => picked(p), (v) => v.length >= dropped.length, 300, 8000)
  const allNamed = names.every((n) => chips.some((c) => c.includes(n)))
  const kept = await p.evaluate((href) => window.__mfdMark === 'same-document' && location.href === href, d ? d.href : '')
  ok(`${tag} ${where}: dragover and drop are cancelled, the page stays (same document, same URL)`,
    Boolean(d && d.over && d.drop && kept), { d, kept })
  ok(`${tag} ${where}: all ${N} dropped files show as picked attachments`,
    chips.length === N && allNamed, { n: chips.length, chips })

  const text = `mfd ${tag} ${where} ${Date.now()}`
  await p.evaluate(() => { window.__mfdUploads.length = 0 })
  await p.focus(`${FORM} textarea`)
  await p.type(`${FORM} textarea`, text)
  await p.click(`${FORM} [data-testid=send]`)
  const st = await until(() => readState(p, text), (v) => v.sent.length > 0 && v.sent[0].files.length > 0, 500, 15000)
  const m = st.sent[0]
  const ids = new Set((m ? m.files : []).map((f) => f.id).filter(Boolean))
  const sentNames = (m ? m.files : []).map((f) => f.name)
  ok(`${tag} ${where}: Send makes ONE reply in the open topic with ${N} files (${N} distinct ids, every name)`,
    Boolean(topic && st.sent.length === 1 && m.is_parent === 0 && (m.task_id === topic || m.parent_task_id === topic)
      && m.files.length === N && ids.size === N && names.every((n) => sentNames.includes(n))),
    { topic, sent: st.sent.map((x) => ({ ...x, files: x.files.length })), ids: ids.size })
  const uploads = await p.evaluate(() => window.__mfdUploads.slice())
  ok(`${tag} ${where}: ${N} upload calls, one per dropped file`,
    uploads.length === N && names.every((n) => uploads.includes(n)), { n: uploads.length })
  const left = await until(() => picked(p), (v) => v.length === 0, 300, 5000)
  ok(`${tag} ${where}: the composer is empty after the send, no page error`, left.length === 0 && errors.length === 0, { left, errors })
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESK = { width: 1440, height: 900 }
const server = await startServer()
const browser = await launch()
try {
  if (PROVE_RED) console.log('  PROVE_RED=1: each drop carries only the first file')
  for (const [vp, tag] of [[DESK, '1440px'], [PHONE, '390px']]) {
    await dropCase(browser, vp, tag, 'topic', PANE)
    await dropCase(browser, vp, tag, 'composer', FORM)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `composer-multi-file-drop: ${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
