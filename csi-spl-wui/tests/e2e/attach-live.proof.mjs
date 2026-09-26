// Attach — live proof, signed in, against a deployed WUI.
//
// Owner report 2026-09-25: "clicked attach, selected the file: no visible
// result", and a DM line sent from the open right pane was stored with
// files = []. This proof picks files the way the owner does - a click on the
// real Attach control, the file chooser, a click on Send - on every send path:
//
// Per surface (channel, DM, lobby, topics home), n = 1 each:
//   L1  pane closed  -> the chips show, Send POSTs /v1/files 201 per file, the
//                       hub stores the line with both refs, the picture card
//                       previews, the PDF card shows its type icon, both download
//   L2  topic open on the right, the reader clicked in that pane -> the same
//   and first, a file dialog closed with nothing shows the no-file notice
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [PEER=<agent>@<box>] [SURFACES=channel,dm,lobby,home] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/attach-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
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
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const PEER = process.env.PEER || ''
const SURFACES = (process.env.SURFACES || 'channel,dm,lobby,home').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], surfaces: {}, console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
/* Every line this proof posts starts with the probe marker: the desk shows it
   in an agent's notice strip and never types it into a prompt (specs/017
   FR-SEC-030). Unmarked, 'attach L1 lobby <id>' was obeyed as an order by an
   agent on prd 2026-09-25. */
const PROBE_MARK = '[spool-probe]'

/* Two files per send: a real 1x1 PNG (previews) and a tiny PDF (icon only).
   The run id is inside both, so every send uploads new bytes and the hub
   cannot answer from an object that already exists. */
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
function filesFor(tag) {
  const png = `${OUT}/attach-${tag}-${run}.png`
  const pdf = `${OUT}/attach-${tag}-${run}.pdf`
  /* a tEXt-free PNG cannot carry the run id, so the PNG repeats across runs;
     the PDF is unique per send */
  writeFileSync(png, PNG)
  writeFileSync(pdf, `%PDF-1.4\n% attach proof ${tag} ${run}\n%%EOF\n`)
  return { png, pdf, names: [png.split('/').pop(), pdf.split('/').pop()] }
}

async function front(p) { await p.bringToFront().catch(() => {}) }

/** The hub's stored rows for one topic, with their file refs. */
async function hubRows(p, apiRoot, task) {
  return p.evaluate(async (root, id) => {
    const r = await fetch(`${root}/v1/view/topics/${encodeURIComponent(id)}?order=asc&limit=50`, { credentials: 'include', headers: { accept: 'application/json' } })
    if (!r.ok) return { status: r.status }
    const j = await r.json()
    return {
      status: r.status,
      rows: (j.messages || []).map((m) => {
        const msg = (m.env && m.env.msg) || m
        return { body: String(msg.body || m.body || ''), is_parent: m.is_parent, files: (msg.files || m.files || []).map((f) => ({ name: f.name, file_id: f.file_id, bytes: f.bytes })) }
      }),
    }
  }, apiRoot, task)
}

/** GET /v1/files/<id> with the member session: the download path. */
async function download(p, apiRoot, id) {
  return p.evaluate(async (root, fid) => {
    const r = await fetch(`${root}/v1/files/${encodeURIComponent(fid)}`, { credentials: 'include' })
    return { status: r.status, bytes: r.ok ? (await r.arrayBuffer()).byteLength : 0 }
  }, apiRoot, id)
}

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  p.on('request', (req) => {
    const u = req.url()
    const i = u.indexOf('/v1/view/')
    if (i > 0 && !res.apiRoot) res.apiRoot = u.slice(0, i)
  })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

async function closePane(p) {
  await front(p)
  for (let i = 0; i < 3; i++) {
    const btn = await p.$('aside.live-pane [data-test=topic-pane-close], aside.live-pane [data-test=live-topic-close]')
    if (!btn) return
    await btn.click().catch(() => {})
    await sleep(600)
  }
}

function pathFor(surface) {
  switch (surface) {
    case 'channel': return '/channel/' + encodeURIComponent(CHANNEL)
    case 'dm': return '/dm/' + encodeURIComponent(PEER)
    case 'lobby': return '/lobby'
    case 'home': return '/'
    default: throw new Error('unknown surface ' + surface)
  }
}

/**
 * Type TEXT, attach both files through the real control, click Send.
 * Returns the POST /v1/files statuses seen while it ran.
 */
async function sendWithFiles(p, text, files, tag) {
  await front(p)
  const posts = []
  const onResp = (r) => { if (/\/v1\/files$/.test(r.url()) && r.request().method() === 'POST') posts.push(r.status()) }
  p.on('response', onResp)
  const ta = await p.waitForSelector('[data-test=top-bar] textarea')
  await ta.click({ count: 3 })
  await p.keyboard.press('Backspace')
  await p.keyboard.type(text)
  const [chooser] = await Promise.all([
    p.waitForFileChooser({ timeout: 8000 }).catch(() => null),
    p.click('[data-testid=attach]'),
  ])
  step(`${tag} Attach opens the file chooser`, !!chooser, {})
  if (!chooser) { p.off('response', onResp); return posts }
  await chooser.accept([files.png, files.pdf])
  await sleep(800)
  const chips = await p.$$eval('.file-chips li', (els) => els.map((e) => e.innerText.trim()))
  step(`${tag} both picked files show as chips`, files.names.every((n) => chips.some((c) => c.includes(n))), { chips })
  const thumb = await p.$('.file-chips img[data-test=composer-file-thumb]')
  step(`${tag} the picture chip has a thumbnail`, !!thumb, {})
  step(`${tag} a pick clears the no-file notice`, !(await p.$('[data-testid=attach-nothing]')), {})
  await p.click('[data-testid=send]')
  const end = Date.now() + 15000
  while (posts.length < 2 && Date.now() < end) await sleep(250)
  await sleep(1500)
  p.off('response', onResp)
  return posts
}

/** Wait until the hub holds TEXT under some topic reachable from the page. */
async function findRow(p, task, text, ms = 10000) {
  const end = Date.now() + ms
  let hub = { status: 0 }
  while (Date.now() < end) {
    hub = await hubRows(p, res.apiRoot, task)
    const row = (hub.rows || []).find((r) => r.body.includes(text))
    if (row) return { hub, row }
    await sleep(500)
  }
  return { hub, row: null }
}

async function checkStored(p, tag, task, text, files) {
  const { hub, row } = await findRow(p, task, text)
  const names = row ? row.files.map((f) => f.name) : []
  step(`${tag} hub stores the line with both files`, !!row && files.names.every((n) => names.includes(n)),
    { status: hub.status, stored: names, is_parent: row && row.is_parent })
  if (!row) return
  for (const f of row.files) {
    const d = await download(p, res.apiRoot, f.file_id)
    step(`${tag} ${f.name} downloads`, d.status === 200 && d.bytes === f.bytes, d)
  }
}

async function checkCards(p, tag, files) {
  await front(p)
  const end = Date.now() + 10000
  let cards = []
  while (Date.now() < end) {
    cards = await p.$$eval('.file-card', (els) => els.map((c) => ({
      name: (c.querySelector('.file-card__meta div') || {}).innerText || '',
      preview: !!c.querySelector('[data-test=file-preview] img[src^="data:image/"]'),
      kind: (c.querySelector('[data-test=file-kind]') || { getAttribute: () => '' }).getAttribute('data-kind'),
    })))
    const png = cards.find((c) => c.name === files.names[0])
    if (png && png.preview) break
    await sleep(400)
  }
  const png = cards.find((c) => c.name === files.names[0])
  const pdf = cards.find((c) => c.name === files.names[1])
  step(`${tag} the picture card previews`, !!png && png.preview, { card: png })
  step(`${tag} the PDF card shows its type icon`, !!pdf && pdf.kind === 'pdf', { card: pdf })
}

async function surfaceRun(p, surface) {
  const ev = {}
  res.surfaces[surface] = ev
  const tag = (n) => `${surface}: ${n}`
  await p.goto(BASE + pathFor(surface), { waitUntil: 'networkidle2' })
  await sleep(1500)
  await closePane(p)

  /* the dialog closed with nothing (owner 2026-09-25: a double-click in the
     GTK dialog lost the pick): the composer says so instead of staying silent */
  await front(p)
  await p.waitForSelector('[data-testid=attach]', { timeout: 20000 })
  const [empty] = await Promise.all([
    p.waitForFileChooser({ timeout: 8000 }).catch(() => null),
    p.click('[data-testid=attach]'),
  ])
  if (empty) await empty.cancel()
  const notice = await p.waitForSelector('[data-testid=attach-nothing]', { timeout: 4000 }).then(() => true, () => false)
  step(tag('an empty file dialog shows the no-file notice'), !!empty && notice, {})

  /* L1: pane closed */
  const t1 = `${PROBE_MARK} attach L1 ${surface} ${run}`
  const f1 = filesFor(`${surface}-l1`)
  const posts1 = await sendWithFiles(p, t1, f1, tag('L1'))
  step(tag('L1 Send uploads both files (POST /v1/files 201)'), posts1.length === 2 && posts1.every((s) => s === 201), { posts: posts1 })
  await sleep(1500)
  const task = await p.evaluate((txt) => {
    for (const el of document.querySelectorAll('article.msg[data-task-id], a.topic-row[data-key]')) {
      if ((el.innerText || '').includes(txt)) return el.getAttribute('data-task-id') || el.getAttribute('data-key') || ''
    }
    return ''
  }, t1)
  ev.task = task
  step(tag('L1 the line is on screen'), !!task, { task })
  if (!task) return
  await checkStored(p, tag('L1'), task, t1, f1)
  if (surface !== 'home') await checkCards(p, tag('L1'), f1)

  /* L2: the topic open on the right, the reader clicked in that pane */
  const card = surface === 'home'
    ? await p.$(`a.topic-row[data-key="${task}"]`)
    : await p.$(`.feed-col article.msg[data-task-id="${task}"]`)
  if (card) {
    const replies = surface === 'home' ? null : await card.$('[data-test=topic-replies]')
    await (replies || card).click()
  }
  const open = await p.waitForSelector('aside.live-pane', { timeout: 10000 }).then(() => true, () => false)
  step(tag('L2 the topic opens on the right'), open, {})
  if (!open) return
  await p.click('aside.live-pane header').catch(() => {})
  await sleep(400)
  const t2 = `${PROBE_MARK} attach L2 ${surface} ${run}`
  const f2 = filesFor(`${surface}-l2`)
  const posts2 = await sendWithFiles(p, t2, f2, tag('L2'))
  step(tag('L2 Send uploads both files (POST /v1/files 201)'), posts2.length === 2 && posts2.every((s) => s === 201), { posts: posts2 })
  await checkStored(p, tag('L2'), task, t2, f2)
  await checkCards(p, tag('L2'), f2)
  await p.screenshot({ path: `${OUT}/${surface}-attach.png` })
  await closePane(p)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await signIn(ctx)
  for (const surface of SURFACES) {
    if (surface === 'dm' && !PEER) { step('dm: PEER is set', false, { hint: 'PEER=<agent>@<box>' }); continue }
    try {
      await surfaceRun(p, surface)
    } catch (e) {
      step(`${surface}: ran to the end`, false, { error: String(e).slice(0, 300) })
      await p.screenshot({ path: `${OUT}/${surface}-error.png` }).catch(() => {})
    }
  }
} catch (e) {
  step('proof ran', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps', '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
