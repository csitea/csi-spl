// Level-1 card clip + 3 height modes — live proof, signed in, against a deployed WUI.
//
// Owner, 2026-09-25 (CLE-34989, specs/033 FR-ML-020..026): a level-1 card in
// the middle pane is clipped at 5 text rows, or at 30% of the screen when a
// picture is on it; a grip drags it taller; a control sets titles (first 90
// chars) / 5 rows (default) / full; the thread pane is never clipped.
//
// Steps (channel surface, n = 1 per run):
//   1. post a 14-line level-1 message -> its card reads data-clip=cut, the body
//      box is <= 5 rows (+2px) of its measured line height, a grip is shown
//   2. drag the grip 120px down -> the box grows by >= 100px
//   3. post a level-1 message with a 300x900 PNG and 14 lines -> the box is
//      30% of the window (+-2px) and taller than 5 rows; the text keeps its own
//      5 rows so the picture is in view (>= 64px of it inside the box)
//   4. titles -> one line (<= 1.7 line heights), text <= 90 chars + ellipsis
//   5. full -> no clip, the box is its whole content (> 5 rows)
//   6. reload -> full is still the mode; rows again, reload -> rows
//   7. open the long card's topic -> the right pane's copy has no clip box
//      and is taller than 5 rows
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/card-clip-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'

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
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
/* Page loads wait for the DOM, then for the element each step needs:
   networkidle never settles while the box's docker network churns. */
/* the desk never types a probe-marked line into a prompt (specs/017 FR-SEC-030) */
const PROBE_MARK = '[spool-probe]'

/* ---- a tall PNG, made here (no binary in the tree) ----------------------- */
function crc32(buf) {
  let c = ~0
  for (const b of buf) {
    c ^= b
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1))
  }
  return ~c >>> 0
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td))
  return Buffer.concat([len, td, crc])
}
function tallPng(w, h) {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4)
  ihdr[8] = 8; ihdr[9] = 2 /* RGB */
  const row = Buffer.alloc(1 + w * 3)
  for (let x = 0; x < w; x++) { row[1 + x * 3] = 40; row[2 + x * 3] = 120; row[3 + x * 3] = 200 }
  const raw = Buffer.concat(Array.from({ length: h }, () => row))
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ])
}

/* ---- in-page reads ------------------------------------------------------ */

/** The middle card whose body starts with `needle`, measured. */
const CARD = (needle) => {
  const pane = document.querySelector('aside.live-pane')
  const ctl = document.querySelector('[data-testid=card-clip-control]')
  const mode = ctl ? ctl.getAttribute('data-mode') : ''
  for (const col of document.querySelectorAll('.feed-col')) {
    if (pane && pane.contains(col)) continue
    for (const el of col.querySelectorAll('article.msg')) {
      if (!(el.innerText || '').includes(needle)) continue
      const box = el.querySelector('[data-testid=card-body]')
      const title = el.querySelector('[data-testid=card-title]')
      const body = el.querySelector('.msg-body')
      const lh = body ? parseFloat(getComputedStyle(body).lineHeight) : 0
      const inner = box ? box.querySelector('.card-body__inner') : null
      return {
        mode,
        task: el.getAttribute('data-task-id') || '',
        /* the optimistic row: the hub's echo replaces it with a new card */
        pending: el.getAttribute('data-pending') === 'true' || !el.getAttribute('data-msg-id'),
        clip: box ? box.getAttribute('data-clip') : null,
        boxH: box ? Math.round(box.getBoundingClientRect().height) : null,
        contentH: inner ? Math.round(inner.scrollHeight) : null,
        grip: !!el.querySelector('[data-testid=card-grip]'),
        title: title ? title.textContent : null,
        titleH: title ? Math.round(title.getBoundingClientRect().height) : null,
        titleLh: title ? parseFloat(getComputedStyle(title).lineHeight) : null,
        lh: lh || (title ? parseFloat(getComputedStyle(title).lineHeight) : 0),
        vh: window.innerHeight,
        picture: !!el.querySelector('[data-test=file-preview] img'),
        /* px of the picture inside the box's visible area (0 = hidden under the cut) */
        picVisible: (() => {
          const img = el.querySelector('[data-test=file-preview] img')
          if (!img || !box) return 0
          const a = img.getBoundingClientRect(), b = box.getBoundingClientRect()
          return Math.max(0, Math.round(Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top)))
        })(),
        textH: body ? Math.round(body.getBoundingClientRect().height) : null,
      }
    }
  }
  return { mode, missing: true }
}

/** The thread pane's copy of the root. */
const PANE_ROOT = (needle) => {
  const pane = document.querySelector('aside.live-pane')
  if (!pane) return { open: false }
  for (const el of pane.querySelectorAll('article.msg')) {
    if (!(el.innerText || '').includes(needle)) continue
    const body = el.querySelector('.msg-body')
    return {
      open: true,
      clipBox: !!el.querySelector('.card-clip'),
      title: !!el.querySelector('[data-testid=card-title]'),
      bodyH: body ? Math.round(body.getBoundingClientRect().height) : 0,
      lh: body ? parseFloat(getComputedStyle(body).lineHeight) : 0,
    }
  }
  return { open: true, missing: true }
}

/** goto / reload that retries a navigation the box's network churn killed
    (net::ERR_NETWORK_CHANGED, a timeout) - up to 4 tries. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      if (url) await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      else await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function waitCard(p, needle, pred = (c) => !c.missing, ms = 20000) {
  const end = Date.now() + ms
  let c
  while (Date.now() < end) {
    c = await p.evaluate(CARD, needle)
    if (pred(c)) return c
    await sleep(300)
  }
  return c
}

async function setMode(p, mode) {
  await p.click(`[data-testid=card-clip-control] [data-testid=card-clip-${mode}]`)
  await sleep(700)
}

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

async function closePane(p) {
  for (let i = 0; i < 3; i++) {
    const btn = await p.$('aside.live-pane [data-test=topic-pane-close], aside.live-pane [data-test=live-topic-close]')
    if (!btn) return
    await btn.click().catch(() => {})
    await sleep(600)
  }
}

/** Type into the omnibox and send; `file` attaches first. Shift+Enter makes the lines. */
async function send(p, lines, file) {
  const ta = await p.waitForSelector('[data-test=top-bar] textarea')
  await ta.click({ count: 3 })
  await p.keyboard.press('Backspace')
  for (let i = 0; i < lines.length; i++) {
    if (i) { await p.keyboard.down('Shift'); await p.keyboard.press('Enter'); await p.keyboard.up('Shift') }
    await p.keyboard.type(lines[i])
  }
  if (file) {
    const [chooser] = await Promise.all([
      p.waitForFileChooser({ timeout: 8000 }).catch(() => null),
      p.click('[data-testid=attach]'),
    ])
    step('picture: Attach opens the file chooser', !!chooser, {})
    if (chooser) await chooser.accept([file])
    await sleep(800)
    await p.click('[data-testid=send]')
    return
  }
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

const within = (a, b, tol) => Math.abs(a - b) <= tol

async function proof(p) {
  const path = '/channel/' + encodeURIComponent(CHANNEL)
  await nav(p, BASE + path)
  await p.waitForSelector('[data-testid=card-clip-control]', { timeout: 30000 }).catch(() => {})
  await sleep(1500)
  await closePane(p)
  step('the middle header carries the height control', !!(await p.$('[data-testid=card-clip-control]')), {})
  await setMode(p, 'rows')

  /* 1. a long card is clipped at 5 rows */
  const LONG = `${PROBE_MARK} clip long ${run}`
  const lines = [LONG + ' — the first line of a fourteen line level-1 card, long enough that its title is cut at ninety characters']
  for (let i = 2; i <= 14; i++) lines.push(`line ${i} of the clip proof ${run}`)
  await send(p, lines)
  let c = await waitCard(p, LONG, (x) => !x.missing && !x.pending && x.clip === 'cut' && x.lh > 0)
  const rows5 = c.lh * 5
  step('1 rows: the long card is clipped', c.clip === 'cut' && c.grip, { clip: c.clip, grip: c.grip })
  step('1 rows: box <= 5 text rows', c.boxH != null && c.boxH <= Math.ceil(rows5) + 2 && c.boxH >= Math.floor(rows5) - 2,
    { boxH: c.boxH, lh: c.lh, rows5: Math.round(rows5), contentH: c.contentH })
  res.long = c
  await p.screenshot({ path: `${OUT}/1-rows.png` })

  /* 2. the grip drags the card taller. Step 1 waited for the hub's row (a
     drag on the optimistic row is lost when the echo replaces that card);
     the pause lets the prepend transition settle under the pointer. */
  await sleep(1500)
  c = await p.evaluate(CARD, LONG)
  const before = c.boxH
  const card = await p.evaluateHandle((needle) => {
    for (const el of document.querySelectorAll('.feed-col article.msg')) if ((el.innerText || '').includes(needle)) return el.querySelector('[data-testid=card-grip]')
    return null
  }, LONG)
  const gb = card && (await card.asElement()?.boundingBox())
  if (gb) {
    const x = gb.x + gb.width / 2, y = gb.y + gb.height / 2
    await p.mouse.move(x, y)
    await p.mouse.down()
    for (let i = 1; i <= 6; i++) { await p.mouse.move(x, y + i * 20); await sleep(40) }
    await p.mouse.up()
    await sleep(500)
  }
  c = await p.evaluate(CARD, LONG)
  step('2 the grip drag grows the card', !!gb && c.boxH - before >= 100, { before, after: c.boxH })
  await p.screenshot({ path: `${OUT}/2-dragged.png` })

  /* 3. a picture card is capped at 30% of the window */
  const PIC = `${PROBE_MARK} clip picture ${run}`
  const png = `${OUT}/clip-tall-${run}.png`
  writeFileSync(png, tallPng(300, 900))
  const plines = [PIC]
  for (let i = 2; i <= 14; i++) plines.push(`picture line ${i} ${run}`)
  await send(p, plines, png)
  c = await waitCard(p, PIC, (x) => !x.missing && x.picture && x.clip === 'cut' && x.lh > 0, 30000)
  const cap = Math.round(c.vh * 0.3)
  step('3 picture: box is 30% of the window', c.picture && c.clip === 'cut' && within(c.boxH, cap, 2),
    { boxH: c.boxH, cap, vh: c.vh, picture: c.picture, clip: c.clip, contentH: c.contentH })
  step('3 picture: taller than 5 rows', c.boxH > c.lh * 5, { boxH: c.boxH, rows5: Math.round(c.lh * 5) })
  step('3 picture: its text keeps 5 rows, the picture is in view', c.textH <= Math.ceil(c.lh * 5) + 2 && c.picVisible >= 64,
    { textH: c.textH, rows5: Math.round(c.lh * 5), picVisible: c.picVisible })
  res.picture = c
  await p.screenshot({ path: `${OUT}/3-picture.png` })

  /* 4. titles */
  await setMode(p, 'titles')
  c = await waitCard(p, LONG, (x) => x.title != null)
  const tl = c.title ? Array.from(c.title.replace(/…$/, '')).length : -1
  step('4 titles: one line', c.title != null && c.titleH <= Math.ceil(c.titleLh * 1.7), { titleH: c.titleH, lh: c.titleLh })
  step('4 titles: the first 90 chars, cut with an ellipsis', tl > 0 && tl <= 90 && c.title.endsWith('…') && c.title.startsWith(PROBE_MARK),
    { chars: tl, title: c.title })
  const picT = await p.evaluate(CARD, PIC)
  step('4 titles: the picture card shows no picture', picT.title != null && !picT.picture, { picture: picT.picture })
  await p.screenshot({ path: `${OUT}/4-titles.png` })

  /* 5. full */
  await setMode(p, 'full')
  c = await waitCard(p, LONG, (x) => x.clip == null && x.boxH != null)
  step('5 full: no clip, the whole card', c.clip == null && !c.grip && c.boxH > c.lh * 5 + 20, { boxH: c.boxH, rows5: Math.round(c.lh * 5), clip: c.clip })
  await p.screenshot({ path: `${OUT}/5-full.png` })

  /* 6. the mode survives a reload */
  await nav(p)
  await sleep(2000)
  c = await waitCard(p, LONG, (x) => !x.missing && x.mode === 'full')
  step('6 reload keeps full', c.mode === 'full' && c.clip == null, { mode: c.mode, clip: c.clip })
  await setMode(p, 'rows')
  await nav(p)
  await sleep(2000)
  c = await waitCard(p, LONG, (x) => !x.missing && x.mode === 'rows' && x.clip === 'cut')
  step('6 reload keeps rows', c.mode === 'rows' && c.clip === 'cut', { mode: c.mode, clip: c.clip })

  /* 7. the thread pane is never clipped */
  const task = c.task
  const el = await p.$(`.feed-col article.msg[data-task-id="${task}"]`)
  if (el) await el.click()
  let r = { open: false }
  const end = Date.now() + 15000
  while (Date.now() < end) {
    r = await p.evaluate(PANE_ROOT, LONG)
    if (r.open && !r.missing) break
    await sleep(300)
  }
  step('7 the thread pane shows the root unclipped', r.open && !r.missing && !r.clipBox && !r.title && r.bodyH > r.lh * 5 + 20,
    { ...r, rows5: Math.round((r.lh || 0) * 5) })
  const mid = await p.evaluate(CARD, LONG)
  step('7 the middle copy stays clipped', mid.clip === 'cut', { clip: mid.clip, boxH: mid.boxH })
  await p.screenshot({ path: `${OUT}/7-thread-pane.png` })
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
  try {
    await proof(p)
  } catch (e) {
    step('proof ran to the end', false, { error: String(e).slice(0, 300) })
    await p.screenshot({ path: `${OUT}/error.png` }).catch(() => {})
  }
} catch (e) {
  step('proof ran', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps', '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
