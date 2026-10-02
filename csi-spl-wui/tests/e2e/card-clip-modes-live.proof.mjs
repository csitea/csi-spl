// Middle-pane card height (owner 2026-09-25, specs/033). Live proof, signed
// in, against a deployed WUI. A fresh browser, so the stored mode starts empty.
//
//   BASE=https://<wui-host> EMAIL=m3-e2e-human@example.com \
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [CHROME_PATH=...] \
//     node tests/e2e/card-clip-modes-live.proof.mjs
//
// EMAIL_FILE may replace EMAIL. The password is read from PW_FILE and never
// printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = process.env.EMAIL || readFileSync(need('EMAIL_FILE'), 'utf8').trim()
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: !!ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
async function goto(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
      return
    } catch (e) {
      last = e
      await sleep(1500)
    }
  }
  throw last
}
async function reload(p) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.reload({ waitUntil: 'domcontentloaded', timeout: 45000 })
      return
    } catch (e) {
      last = e
      await sleep(1500)
    }
  }
  throw last
}

/** Cards in one pane, plus the height control. Runs in the page. */
const READ = (pane) => {
  const root = document.querySelector(pane === 'topic' ? 'aside[data-pane="topic"]' : '[data-pane="msgs"]')
  const vh = window.innerHeight
  const ctl = document.querySelector('[data-testid=card-clip-control]')
  const cards = root ? [...root.querySelectorAll('article.msg')] : []
  const rows = cards.map((card) => {
    const body = card.querySelector('[data-testid=card-body]')
    const title = card.querySelector('[data-testid=card-title]')
    const grip = card.querySelector('[data-testid=card-grip]')
    const msgBody = card.querySelector('.msg-body')
    const cs = msgBody ? getComputedStyle(msgBody) : null
    const lh = cs
      ? parseFloat(cs.lineHeight)
      : (title ? parseFloat(getComputedStyle(title).lineHeight) : 0)
    const box = body ? body.getBoundingClientRect() : null
    const textMax = cs ? parseFloat(cs.maxHeight) : NaN
    return {
      clip: body ? body.getAttribute('data-clip') : null,
      picture: !!(body && body.classList.contains('card-clip--picture')),
      h: box ? Math.round(box.height) : null,
      textClient: msgBody ? msgBody.clientHeight : null,
      textMax: Number.isFinite(textMax) ? Math.round(textMax) : null,
      lh: Number.isFinite(lh) ? Math.round(lh * 10) / 10 : 0,
      title: title ? title.textContent : null,
      titleH: title ? Math.round(title.getBoundingClientRect().height) : null,
      grip: !!grip,
    }
  })
  return {
    vh,
    mode: ctl ? ctl.getAttribute('data-mode') : null,
    aria: ctl ? ctl.getAttribute('aria-label') : null,
    labels: ctl ? [...ctl.querySelectorAll('span')].map((s) => s.textContent) : [],
    stored: (() => { try { return sessionStorage.getItem('spool-card-clip-session-msgs') } catch { return 'ERR' } })(),
    n: rows.length,
    rows,
    topicOpen: !!document.querySelector('aside[data-pane=topic]'),
  }
}

async function read(p, pane) { return p.evaluate(READ, pane) }

/** The visible clip box, not the text's full layout height under overflow:hidden. */
function fiveRows(row) {
  if (!row.lh || row.h == null) return true
  return row.h <= row.lh * 5 + 4
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 90000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))

  await goto(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('0 native sign-in', signedIn, { url: p.url().replace(BASE, '') })
  if (!signedIn) throw new Error('not signed in')

  await p.waitForSelector('[data-testid=card-clip-control]', { timeout: 20000 })
  await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 20000 }).catch(() => {})
  await sleep(600)
  let s = await read(p, 'msgs')
  const rawKey = (s.aria || '').includes('feed.clip') || s.labels.some((t) => String(t).includes('feed.clip'))
  step('8 control shows words, not key paths', !rawKey && s.labels.length === 3 && !!s.aria, {
    aria: s.aria, labels: s.labels, mode: s.mode, n: s.n,
  })
  step('1 default mode is 5 rows', s.mode === 'rows' && s.stored === null, { mode: s.mode, stored: s.stored })
  const textCards = s.rows.filter((r) => !r.picture)
  const overText = textCards.filter((r) => !fiveRows(r))
  step('1 text cards are at most 5 rows', textCards.length > 0 && overText.length === 0, {
    n: textCards.length, over: overText.slice(0, 3), sample: textCards.slice(0, 2),
  })
  const pics = s.rows.filter((r) => r.picture)
  const cap30 = Math.round(s.vh * 0.3) + 4
  const overPic = pics.filter((r) => {
    const textCap = r.lh ? r.lh * 5 + 4 : Infinity
    const textOk = r.textClient == null || r.textClient <= textCap
    const capInstalled = r.textMax != null && r.textMax <= textCap
    return r.h > cap30 || !textOk || !capInstalled
  })
  step('2 picture cards stay within 30% and their text within 5 rows', pics.length > 0 && overPic.length === 0, {
    n: pics.length, vh: s.vh, cap: Math.round(s.vh * 0.3), over: overPic.slice(0, 3), sample: pics.slice(0, 2),
  })
  await p.screenshot({ path: `${OUT}/1-rows.png` })

  const grip = await p.$('[data-pane=msgs] [data-testid=card-grip]')
  if (!grip) {
    step('3 a grip is on a clipped card', false, { n: s.rows.filter((r) => r.grip).length, clips: s.rows.map((r) => r.clip) })
  } else {
    const before = await p.evaluate(() => {
      const g = document.querySelector('[data-pane=msgs] [data-testid=card-grip]')
      const body = g && g.closest('article')?.querySelector('[data-testid=card-body]')
      return body ? Math.round(body.getBoundingClientRect().height) : 0
    })
    const box = await grip.boundingBox()
    await p.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
    await p.mouse.down()
    await p.mouse.move(box.x + box.width / 2, box.y + 90, { steps: 10 })
    await p.mouse.up()
    await sleep(300)
    const after = await p.evaluate(() => {
      const g = document.querySelector('[data-pane=msgs] [data-testid=card-grip]')
      const body = g && g.closest('article')?.querySelector('[data-testid=card-body]')
      return body ? Math.round(body.getBoundingClientRect().height) : 0
    })
    step('3 grip drag grows a clipped card', after > before + 8, { before, after })
  }
  await p.screenshot({ path: `${OUT}/3-grip.png` })

  await p.click('[data-testid=card-clip-titles]')
  await sleep(400)
  s = await read(p, 'msgs')
  const longTitle = s.rows.filter((r) => r.title && [...r.title].length > 91)
  const multi = s.rows.filter((r) => r.titleH && r.lh && r.titleH > r.lh * 1.8)
  step('4 titles mode is one line of at most 90 characters plus the ellipsis',
    s.mode === 'titles' && s.n > 0 && longTitle.length === 0 && multi.length === 0 && s.rows.every((r) => r.title),
    { mode: s.mode, n: s.n, long: longTitle.length, multi: multi.length, sample: s.rows.slice(0, 2).map((r) => r.title) })
  await p.screenshot({ path: `${OUT}/4-titles.png` })

  await reload(p)
  await p.waitForSelector('[data-testid=card-clip-control]', { timeout: 20000 })
  await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 20000 })
  await sleep(400)
  s = await read(p, 'msgs')
  step('7 titles mode survives a reload', s.mode === 'titles' && s.stored === 'titles' && s.n > 0, { mode: s.mode, stored: s.stored, n: s.n })
  await p.screenshot({ path: `${OUT}/7-reload.png` })

  await p.click('[data-testid=card-clip-full]')
  await p.waitForFunction(() => document.querySelector('[data-testid=card-clip-control]')?.getAttribute('data-mode') === 'full')
  await sleep(300)
  s = await read(p, 'msgs')
  const stillClipped = s.rows.filter((r) => r.clip || r.grip)
  step('5 full mode does not clip', s.mode === 'full' && s.n > 0 && stillClipped.length === 0, {
    mode: s.mode, clipped: stillClipped.length, n: s.n,
  })
  await p.screenshot({ path: `${OUT}/5-full.png` })

  await p.click('[data-testid=card-clip-rows]')
  await p.waitForFunction(() => document.querySelector('[data-testid=card-clip-control]')?.getAttribute('data-mode') === 'rows')
  await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 20000 })
  await sleep(300)
  const replies = await p.$('[data-pane=msgs] [data-test=topic-replies]')
  let opened = false
  if (replies) {
    await replies.click()
    opened = true
  } else {
    const card = await p.$('[data-pane=msgs] article.msg')
    const box = card && await card.boundingBox()
    if (box) {
      await p.mouse.click(box.x + Math.min(120, box.width / 2), box.y + 24)
      opened = true
    }
  }
  const paneShown = await p.waitForSelector('aside[data-pane=topic]', { timeout: 15000 }).then(() => true, () => false)
  await p.waitForSelector('aside[data-pane=topic] article.msg', { timeout: 8000 }).catch(() => {})
  await sleep(400)
  const topic = await read(p, 'topic')
  const topicText = await p.evaluate(() => (document.querySelector('aside[data-pane=topic]')?.innerText || '').slice(0, 240))
  /* SPL-945: the thread pane has its own control and stored mode; in full
     nothing in it is clipped, whatever the middle pane's mode is */
  const threadCtl = await p.$('aside[data-pane=topic] [data-testid=card-clip-control][data-clip-pane=thread]')
  if (threadCtl) {
    await p.click('aside[data-pane=topic] [data-testid=card-clip-full]')
    await sleep(500)
  }
  const topicFull = await read(p, 'topic')
  const clipped = topicFull.rows.filter((r) => r.clip || r.grip).length
  const midMode = await p.evaluate(() => document.querySelector('[data-pane=msgs] [data-testid=card-clip-control]')?.getAttribute('data-mode'))
  step('6 the thread pane has its own control; in full it clips nothing, the middle pane keeps rows', opened && paneShown && !!threadCtl && topic.n > 0 && clipped === 0 && midMode === 'rows', {
    opened, paneShown, threadCtl: !!threadCtl, n: topic.n, clipped, midMode, topicText,
  })
  await p.screenshot({ path: `${OUT}/6-topic.png` })
  await p.click('aside[data-pane=topic] [data-testid=card-clip-rows]').catch(() => {})

  await p.click('[data-testid=card-clip-rows]').catch(() => {})
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', 'console', res.console.length)
  process.exitCode = failed ? 1 : 0
} finally {
  await browser.close()
}
