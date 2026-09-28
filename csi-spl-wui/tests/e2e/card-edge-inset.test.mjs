// (owner, prd t1 topics 95adf832 + fd1e5be4, 2026-09-28): on a
// phone "the text content of the cards must not be more than 6 px from the
// left edge of the screen, and likewise no more than 6 px from the right",
// "like the max amount of the screen area must be used", and the header row
// ("the avatar ... the whole row") moves left with it.
//
// Per surface (lobby, channel, topic pane, topic page, DM, issue comments)
// and width it measures, from element rects, every visible card:
//   text: the .msg-body content box - its left edge and its gap to the right
//         window edge (a line wraps inside that box, so it is the text's reach)
//   head: the avatar's left edge, and how many lines the header takes
// Phones (360, 390, 820): text left and right gap 8..10 (the owner: 6 was "a
// bit too much", 1 mm more), the
// avatar at the same inset, no sideways scroll, one header line from 390 px.
// Desktop (1440): unchanged - text starts right of the avatar column.
//
//   pnpm run test:e2e:card-edge-inset
//   BASE_URL=<generated bundle> pnpm run test:e2e:card-edge-inset
//   MEASURE=1 ... prints the numbers without asserting
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MEASURE = !!process.env.MEASURE
/* 6 px was "a bit too much" live (fd1e5be4): 10 px, about 1 mm more */
const MIN = 8
const MAX = 10
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const LOBBY_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const SURFACES = [
  ['lobby', '/lobby'],
  ['channel', '/channel/lobby'],
  ['topic pane', `/channel/lobby?topic=${TASK}`],
  ['topic page', `/t/${LOBBY_TASK}`],
  /* the mock has no DM lines and no issue comments: measured when present,
     proved live (tests/e2e/card-edge-inset-live.proof.mjs) */
  ['dm', '/dm/CLE-07%40box-a', 'optional'],
  ['issue comments', '/issues', 'issue'],
]
const WIDTHS = [[360, 740], [390, 844], [820, 1180], [1440, 900]]

const results = []
const ok = (name, pass, ev) => {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** every visible card: its text box and header, against the window edges */
function edges(page) {
  return page.evaluate(() => {
    const vw = document.documentElement.clientWidth
    const px = (el, p) => parseFloat(getComputedStyle(el)[p]) || 0
    const cards = [...document.querySelectorAll('article.msg[data-msg-id]')].filter((el) => {
      const r = el.getBoundingClientRect()
      return el.getClientRects().length && r.width > 0 && r.bottom > 0 && r.top < innerHeight
    })
    return {
      vw,
      scrollW: document.scrollingElement.scrollWidth,
      cards: cards.map((a) => {
        const body = a.querySelector('.msg-body')
        const b = body && body.getBoundingClientRect()
        const av = a.querySelector(':scope > .avatar')
        const meta = a.querySelector('.msg-meta')
        const items = meta ? [...meta.children].flatMap((el) => (getComputedStyle(el).display === 'contents' ? [...el.children] : [el])) : []
        const mids = items.filter((el) => !el.classList.contains('msg-reactions') && el.getClientRects().length)
          .map((el) => { const r = el.getBoundingClientRect(); return r.top + r.height / 2 })
        return {
          id: a.getAttribute('data-msg-id'),
          textL: b ? Math.round((b.left + px(body, 'paddingLeft') + px(body, 'borderLeftWidth')) * 10) / 10 : null,
          textR: b ? Math.round((vw - (b.right - px(body, 'paddingRight') - px(body, 'borderRightWidth'))) * 10) / 10 : null,
          avatarL: av ? Math.round(av.getBoundingClientRect().left * 10) / 10 : null,
          headRows: mids.length ? 1 + mids.filter((m, i) => i > 0 && m - mids[0] > 12).length : 0,
        }
      }).filter((c) => c.textL != null),
    }
  })
}

const server = await startServer()
const browser = await launch()
let failed = false
try {
  for (const [w, h] of WIDTHS) {
    const phone = w <= 820
    const page = await browser.newPage()
    await page.setViewport({ width: w, height: h, hasTouch: phone, isMobile: phone })
    for (const [name, path, open] of SURFACES) {
      await page.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await page.waitForSelector('article.msg[data-msg-id]', { timeout: open ? 3000 : 15000 }).catch(() => {})
      await sleep(600)
      if (open === 'issue') {
        /* the first issue with a comment: its detail holds the comment cards */
        const rows = await page.$$('[data-test=issues-row]')
        for (const row of rows) {
          await (await row.$('.issues-c-key') ?? row).click().catch(() => {})
          await sleep(500)
          if (await page.$('article.msg[data-test=issues-comment]')) break
        }
      }
      const f = await edges(page)
      const tag = `${w}px ${name}`
      if (!f.cards.length) {
        if (open) console.log(`  --   ${tag}: no card in the mock (measured live)`)
        else ok(`${tag}: a card with text is on screen`, false, f)
        continue
      }
      const worstL = Math.max(...f.cards.map((c) => c.textL))
      const minL = Math.min(...f.cards.map((c) => c.textL))
      const worstR = Math.max(...f.cards.map((c) => c.textR))
      const minR = Math.min(...f.cards.map((c) => c.textR))
      const avatars = f.cards.map((c) => c.avatarL).filter((x) => x != null)
      const rows = Math.max(...f.cards.map((c) => c.headRows))
      const ev = { cards: f.cards.length, textL: [minL, worstL], textR: [minR, worstR], avatarL: avatars.length ? [Math.min(...avatars), Math.max(...avatars)] : null, headRows: rows, scrollW: f.scrollW, vw: f.vw }
      if (MEASURE) { console.log(`  ${tag} ${JSON.stringify(ev)}`); continue }
      if (phone) {
        ok(`${tag}: card text ${MIN}..${MAX}px from the left edge`, minL >= MIN && worstL <= MAX, ev)
        ok(`${tag}: card text ${MIN}..${MAX}px from the right edge`, minR >= MIN && worstR <= MAX, ev)
        ok(`${tag}: the avatar sits at the text inset`, avatars.every((x) => x >= MIN && x <= MAX), ev.avatarL)
        /* at 360 a sender -> recipient card with "via terminal" and a
           replies button needs ~324 px of a 308 px header: it may take a
           second line there; from 390 (the owner's phone) every header is one */
        if (w >= 390) ok(`${tag}: the header is one line`, rows === 1, rows)
        else console.log(`  --   ${tag}: header lines ${rows}`)
        ok(`${tag}: no sideways scroll`, f.scrollW <= f.vw, [f.scrollW, f.vw])
      } else {
        /* desktop keeps the avatar column: the text starts right of it */
        ok(`${tag}: desktop text keeps the avatar column`, f.cards.every((c) => c.avatarL == null || c.textL > c.avatarL + 30), ev)
      }
    }
    await page.close()
  }
} catch (e) {
  failed = true
  console.error(e)
} finally {
  await browser.close()
  await server.stop()
}
const bad = results.filter((r) => !r.ok)
console.log(`\ncard-edge-inset: ${results.length - bad.length}/${results.length} passed`)
process.exit(failed || bad.length ? 1 : 0)
