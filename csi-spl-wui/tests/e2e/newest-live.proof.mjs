// CLE-3412 live proof of 013 US7 (newest on top, pushed live) against a
// deployed WUI: two signed-in browser sessions A and B. A sends in #lobby, in
// a channel and in a DM; B has the same view open and must show each message
// as its TOP row within LIMIT_MS, without a reload. A's own row must appear at
// once and exactly once (optimistic, then confirmed). B scrolled down keeps
// its place and gets the "new" pill. B on the thread list `/` gets A's new
// channel root on top. With BOX_CMD set, a box `spool send` into the lobby
// (do_spl_box_msg_probe PROBE_TASK=<lobby>) appears on B's top too.
// Screenshots, timings and results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHANNEL=<slug>] [PEER=<agent id>] [LIMIT_MS=1000] \
//     [BOX_CMD='<shell command that sends one box note labelled $NONCE into the lobby>'] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/newest-live.proof.mjs
//
// The password is read from PW_FILE and never printed. BOX_CMD gets the
// label in $NONCE. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
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
const LIMIT_MS = Number(process.env.LIMIT_MS || 1000)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), limit_ms: LIMIT_MS, steps: [], timings: {} }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)

async function signIn(ctx, label, width) {
  const p = await ctx.newPage()
  await p.setViewport({ width, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step(`${label}: native sign-in`, ok, { url: p.url() })
  if (!ok) throw new Error(`${label} not signed in`)
  return p
}

/** Go to a path in-app and wait until the live socket is open and the feed settled. */
async function open(p, path) {
  await p.goto(BASE + path, { waitUntil: 'networkidle2' })
  await p.waitForSelector('form.composer textarea', { timeout: 20000 }).catch(() => {})
  await sleep(1500)
}

/** Resolves with the browser clock when the first row of `sel` contains `text`. */
function topHas(p, sel, text, timeout = 15000) {
  return p.waitForFunction((s, t) => {
    const first = document.querySelector(s)
    return first && first.textContent.includes(t) ? Date.now() : false
  }, { polling: 'mutation', timeout }, sel, text).then((h) => h.jsonValue(), () => null)
}

const countOf = (p, text) => p.evaluate((t) => [...document.querySelectorAll('.live-rows > article.msg')].filter((a) => a.textContent.includes(t)).length, text)

async function send(p, text) {
  const ta = await p.waitForSelector('form.composer textarea')
  await ta.focus()
  await p.keyboard.type(text)
  const t0 = Date.now()
  await p.keyboard.press('Enter')
  return t0
}

/** One A->B leg on `path`: A sends, both must show it on top; B within LIMIT_MS. */
async function leg(name, a, b, path, rowSel = '.live-rows > article.msg') {
  await open(a, path)
  await open(b, path)
  const nonce = `live ${name} ${run}`
  const bSeen = topHas(b, rowSel, nonce)
  const aSeen = topHas(a, rowSel, nonce)
  const t0 = await send(a, nonce)
  const [ta, tb] = await Promise.all([aSeen, bSeen])
  const aMs = ta && ta - t0
  const bMs = tb && tb - t0
  res.timings[name] = { a_own_ms: aMs, b_live_ms: bMs }
  await sleep(1500)
  const dupA = await countOf(a, nonce)
  step(`${name}: A's own send on A's top at once, once after the echo`, ta !== null && dupA === 1, { a_ms: aMs, copies: dupA })
  step(`${name}: B shows it on top without reload within ${LIMIT_MS} ms`, tb !== null && bMs <= LIMIT_MS, { b_ms: bMs })
  await a.screenshot({ path: `${OUT}/${name}-A.png` })
  await b.screenshot({ path: `${OUT}/${name}-B.png` })
  return nonce
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const a = await signIn(await browser.createBrowserContext(), 'A', 1280)
  const b = await signIn(await browser.createBrowserContext(), 'B', 1280)
  /* the element that scrolls the feed, found as utils/scroll-anchor.mjs scrollerOf does */
  await b.evaluateOnNewDocument(() => {
    window.__scroller = () => {
      for (let n = document.querySelector('.live-feed')?.parentElement; n; n = n.parentElement) {
        const oy = getComputedStyle(n).overflowY
        if ((oy === 'auto' || oy === 'scroll') && n.scrollHeight > n.clientHeight + 1) return n
      }
      return document.scrollingElement
    }
  })

  await leg('lobby', a, b, '/lobby')

  /* B scrolled down: reading position kept, pill instead of a jump (short window; a few fillers if the feed cannot scroll yet) */
  await b.setViewport({ width: 1280, height: 480 })
  for (let i = 0; i < 8; i++) {
    const room = await b.evaluate(() => { const s = window.__scroller(); return s.scrollHeight - s.clientHeight })
    if (room >= 400) break
    await send(a, `live filler ${i} ${run}`)
    await sleep(700)
  }
  const scrolled = await b.evaluate(() => {
    const s = window.__scroller()
    if (s.scrollHeight - s.clientHeight < 400) return null
    s.scrollTop = 300
    const edge = s === document.scrollingElement ? 0 : s.getBoundingClientRect().top
    const first = [...document.querySelectorAll('.live-rows > article.msg')].find((r) => r.getBoundingClientRect().top >= edge + 60)
    return { top: s.scrollTop, anchor: first ? first.textContent.slice(0, 80) : '', y: first ? first.getBoundingClientRect().top : 0 }
  })
  if (scrolled) {
    await sleep(300)
    const nonce = `live pill ${run}`
    await send(a, nonce)
    const pill = await b.waitForSelector('[data-testid=new-pill]', { timeout: 5000 }).then(() => true, () => false)
    const after = await b.evaluate((anchor) => {
      const s = window.__scroller()
      const row = [...document.querySelectorAll('.live-rows > article.msg')].find((r) => r.textContent.slice(0, 80) === anchor)
      return { top: s.scrollTop, y: row ? row.getBoundingClientRect().top : null }
    }, scrolled.anchor)
    step('lobby, B scrolled down: reading position kept, "new" pill shown', pill && after.top > scrolled.top && after.y !== null && Math.abs(after.y - scrolled.y) < 4,
      { pill, top_before: scrolled.top, top_after: after.top, anchor_y_before: scrolled.y, anchor_y_after: after.y })
    await b.screenshot({ path: `${OUT}/lobby-B-scrolled-pill.png` })
    await b.click('[data-testid=new-pill]')
    await sleep(800)
    const top = await b.evaluate(() => window.__scroller().scrollTop)
    step('pill jumps back to the newest', top <= 80, { scrollTop: top })
    await b.setViewport({ width: 1280, height: 800 })
  } else {
    step('lobby, B scrolled down: the feed could not be made scrollable', false, {})
  }

  /* a channel other than the lobby */
  /* the test member creates it through the sidebar "+" dialog when the tenant
     lacks it (2026-09-22: the + next to the Channels heading opens a modal
     that takes a title and a description) */
  const channel = process.env.CHANNEL || 'live-proof'
  await open(a, '/channel/lobby')
  const known = await a.evaluate((c) => [...document.querySelectorAll('a[href*="/channel/"]')].some((x) => x.getAttribute('href').endsWith('/channel/' + c)), channel)
  if (!known) {
    await a.click('[data-testid=create-channel]')
    await a.waitForSelector('[data-testid=create-channel-form]', { timeout: 10000 })
    await a.type('[data-testid=create-channel-name]', channel)
    await a.type('[data-testid=create-channel-description]', 'live proof run ' + run)
    await a.click('[data-testid=create-channel-submit]')
    const made = await a.waitForFunction((c) => location.pathname.endsWith('/channel/' + c), { timeout: 15000 }, channel).then(() => true, () => false)
    step(`channel #${channel} created by the test member (sidebar + dialog)`, made, { url: a.url() })
    /* the description the dialog collected is what the channel header says */
    const about = await a.evaluate(() => {
      const el = document.querySelector('[data-test="channel-description"]')
      return el ? el.textContent.trim() : null
    })
    step('the channel header shows the description the dialog collected', about === 'live proof run ' + run, { about })
  }
  await leg(`channel-${channel}`, a, b, `/channel/${encodeURIComponent(channel)}`)

  const peer = process.env.PEER || 'HUM-4'
  await leg(`dm-${peer}`, a, b, `/dm/${encodeURIComponent(peer)}`)

  /* thread list: A starts a new root in the channel, B on `/` shows it on top */
  if (channel) {
    await open(a, `/channel/${encodeURIComponent(channel)}`)
    await b.goto(BASE + '/', { waitUntil: 'networkidle2' })
    await b.waitForSelector('.thread-row', { timeout: 20000 }).catch(() => {})
    await sleep(1500)
    const nonce = `live threads ${run}`
    const seen = topHas(b, '.thread-row', nonce)
    const t0 = await send(a, nonce)
    const tb = await seen
    res.timings.thread_list = { b_live_ms: tb && tb - t0 }
    step(`thread list: a new root shows as B's top row within ${LIMIT_MS} ms`, tb !== null && tb - t0 <= LIMIT_MS, { b_ms: tb && tb - t0 })
    await b.screenshot({ path: `${OUT}/threads-B.png` })
  }

  /* a box send into the lobby */
  if (process.env.BOX_CMD) {
    await open(b, '/lobby')
    const nonce = `box${run}`
    const seen = topHas(b, '.live-rows > article.msg', nonce, 120000)
    const t0 = Date.now()
    const code = await new Promise((resolve) => {
      const c = spawn('bash', ['-c', process.env.BOX_CMD], { env: { ...process.env, NONCE: nonce }, stdio: ['ignore', 'pipe', 'inherit'] })
      let out = ''
      c.stdout.on('data', (d) => { out += d })
      c.on('close', (rc) => { res.box_cmd_tail = out.slice(-400); resolve(rc) })
    })
    const t1 = Date.now()
    const tb = await seen
    res.timings.box = { cmd_ms: t1 - t0, b_seen_after_start_ms: tb && tb - t0, b_seen_before_cmd_end: tb !== null && tb <= t1 }
    step('box spool send into the lobby shows on B\'s top live (before the probe finished its read-back, or within LIMIT_MS of it)',
      code === 0 && tb !== null && tb <= t1 + LIMIT_MS, { rc: code, ...res.timings.box })
    await b.screenshot({ path: `${OUT}/box-B.png` })
  }
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}; timings ${JSON.stringify(res.timings)}`)
process.exit(bad ? 1 : 0)
