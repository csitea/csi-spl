// SPL-2087: with the 5-row card setting, every card is the same height (bug).
// A 1-row card and an 8-row card under the 5-row setting must have equal heights.
// The 1-row card gets white space below its text to match the 5-row height.
// Measured on the whole card (article), not only its body: the grip under a
// cut card adds 12 px (desktop) / 28 px (phone), so the body alone can match
// while the cards do not. "full" keeps the natural heights.
// SPL-2104: a card with a "moved from" line over its body is as tall too:
// the note lines come out of the 5-row box.
// SPL-2121 (owner t1 28559e83, msg 5d02bac2): a card with pictures or a link
// preview is as tall too: the picture counts inside the 5-row box, cut to
// fit, and the grip shows all of it (it had a 30%-of-the-window box).
//
// Run:
//   pnpm run test:e2e card-height-rows
//   BASE_URL=<generated bundle> pnpm run test:e2e card-height-rows   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per state there

import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
const ROWS = 5
const SLACK_PX = 1

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const SHORT_BODY = 'Short message: 1 row.'
const LONG_BODY = 'Long message: 8 rows.\n'.repeat(8).trim()

async function open(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  /* SPL-2121: light mode, the owner's view */
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool-theme', 'light') } catch { /* private mode */ } })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  })
  return { p, errors }
}

/* Seed a short and a long card in the channel */
function seedCards(p) {
  return p.evaluate((shortBody, longBody) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const shortRow = {
      v: 1, 
      msg_id: crypto.randomUUID(), 
      task_id: crypto.randomUUID(), 
      ts: new Date().toISOString(), 
      from: 'CLE-07', 
      to: '@channel', 
      kind: 'note', 
      body: shortBody, 
      files: [], 
      channel: channel.active || 'alerts', 
      parent_task_id: null, 
      is_parent: 1
    }
    const longRow = {
      v: 1, 
      msg_id: crypto.randomUUID(), 
      task_id: crypto.randomUUID(), 
      ts: new Date().toISOString(), 
      from: 'CLE-07', 
      to: '@channel', 
      kind: 'note', 
      body: longBody, 
      files: [], 
      channel: channel.active || 'alerts', 
      parent_task_id: null, 
      is_parent: 1
    }
    /* SPL-2104: a short card moved here from another channel carries a
       "moved from" line over its body; the card stays as tall as the others */
    const movedRow = {
      ...shortRow,
      msg_id: crypto.randomUUID(),
      task_id: crypto.randomUUID(),
      moved_at: new Date().toISOString(),
      moved_from_channel: 'elsewhere-2104',
    }
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, shortRow, longRow, movedRow]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, shortRow, longRow, movedRow]
    return { shortId: shortRow.msg_id, longId: longRow.msg_id, movedId: movedRow.msg_id }
  }, SHORT_BODY, LONG_BODY)
}

/* SPL-2121: cards with pictures and a link preview. The pictures are real
   PNGs (drawn on a canvas) sent the way a reader sends them: picked in the
   omnibox's attach input, then Enter. The mock keeps the row and the bytes,
   so a refetch keeps the card and it loads its picture by file id, as on the
   hub. The link preview row rides the mock hook, as the text rows do. */
async function sendPictures(p, body, pics) {
  const form = 'form.omnibox--global'
  await p.waitForSelector(`${form} [data-testid=attach-input]`, { timeout: NAV_TIMEOUT })
  const before = await p.$$eval('.spool-main article.msg[data-msg-id]', (els) => els.map((e) => e.getAttribute('data-msg-id')))
  const chips = await p.evaluate(async (form, pics) => {
    const png = ({ name, w, h, colour }) => new Promise((resolve) => {
      const c = document.createElement('canvas')
      c.width = w
      c.height = h
      const g = c.getContext('2d')
      g.fillStyle = colour
      g.fillRect(0, 0, w, h)
      g.fillStyle = '#fff'
      g.fillRect(w / 4, h / 4, w / 2, h / 2)
      c.toBlob((b) => resolve(new File([b], name, { type: 'image/png' })), 'image/png')
    })
    const dt = new DataTransfer()
    for (const f of pics) dt.items.add(await png(f))
    const input = document.querySelector(`${form} [data-testid=attach-input]`)
    input.files = dt.files
    input.dispatchEvent(new Event('change', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 400))
    return document.querySelectorAll(`${form} .file-chips li`).length
  }, form, pics)
  if (chips !== pics.length) throw new Error(`attach: ${chips} chips for ${pics.length} pictures`)
  await p.focus(`${form} textarea`)
  if (body) await p.keyboard.type(body)
  await p.keyboard.press('Enter')
  const handle = await p.waitForFunction((before) => {
    const seen = new Set(before)
    const row = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
      .find((e) => !seen.has(e.getAttribute('data-msg-id')) && e.getAttribute('data-pending') !== 'true' && e.querySelector('[data-test=file-preview]'))
    return row ? row.getAttribute('data-msg-id') : null
  }, { timeout: 15000 }, before)
  return handle.jsonValue()
}

/* a link preview needs a topic the mock holds in its own data (a row this
   test adds is read in only at the mock's next list call): #alerts' topic
   in utils/mock-data.mjs */
const MOCK_ALERTS_TOPIC = 'ffffffff-ffff-4fff-8fff-ffffffffffff'

async function seedPictureCards(p) {
  const previewId = await p.evaluate((topic) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const row = {
      v: 1,
      msg_id: crypto.randomUUID(),
      task_id: crypto.randomUUID(),
      ts: new Date().toISOString(),
      from: 'CLE-07',
      to: '@channel',
      kind: 'note',
      body: `the plan is [here](/t/${topic})`,
      files: [],
      channel: channel.active || 'alerts',
      parent_task_id: null,
      is_parent: 1,
    }
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, row]
    return row.msg_id
  }, MOCK_ALERTS_TOPIC)
  const oneId = await sendPictures(p, '', [{ name: 'one.png', w: 800, h: 600, colour: '#3a6ea5' }])
  const threeId = await sendPictures(p, '', [
    { name: 'a.png', w: 640, h: 480, colour: '#a53a3a' },
    { name: 'b.png', w: 480, h: 640, colour: '#3aa55a' },
    { name: 'c.png', w: 600, h: 600, colour: '#a5933a' },
  ])
  const textId = await sendPictures(p, 'A picture with text under the 5-row cap.', [{ name: 't.png', w: 1024, h: 768, colour: '#5a3aa5' }])
  return { oneId, threeId, previewId, textId }
}

/* every picture of the card is on it and the first has loaded; the ones
   under the cut are loading="lazy" and may wait for the grip */
function picturesLoaded(p, sel, want) {
  return p.waitForFunction((sel, want) => {
    const imgs = [...document.querySelectorAll(`${sel} img`)]
    return imgs.length >= want && imgs[0].complete && imgs[0].naturalWidth > 0
  }, { timeout: 15000 }, sel, want)
}

/* Set the middle pane's clip mode, 'rows' (the 5-row cap) or 'full', the way
   the reader does: the radio of the pane's card-height control (on the phone
   it sits in a menu, so it is clicked in the page, not by the pointer) */
async function setClipMode(p, mode = 'rows') {
  const ctl = '[data-testid=card-clip-control][data-clip-pane=msgs]'
  await p.waitForSelector(`${ctl} [data-testid=card-clip-${mode}]`, { timeout: 15000 })
  await p.evaluate((sel) => document.querySelector(sel).click(), `${ctl} [data-testid=card-clip-${mode}]`)
  await p.waitForFunction((ctl, mode) => document.querySelector(ctl)?.getAttribute('data-mode') === mode, { timeout: 15000 }, ctl, mode)
}

/* Get the height of a card's body box */
function cardHeight(p, sel) {
  return p.evaluate((sel) => {
    const card = document.querySelector(sel)
    if (!card) return null
    const body = card.querySelector('[data-testid=card-body]')
    if (!body) return null
    const b = body.getBoundingClientRect()
    return {
      height: Math.round(b.height),
      card: Math.round(card.getBoundingClientRect().height),
      clip: body.dataset.clip || '',
      grip: Boolean(card.querySelector('[data-testid=card-grip]')),
    }
  }, sel)
}

/* The page at rest: the card reads the same for 12 frames in a row */
async function rest(p, sel) {
  const t0 = Date.now()
  let last = ''
  let still = 0
  while (Date.now() - t0 < NAV_TIMEOUT) {
    const now = JSON.stringify(await cardHeight(p, sel))
    still = now === last && now !== 'null' ? still + 1 : 0
    if (still >= 12) return JSON.parse(now)
    last = now
    await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())))
  }
  throw new Error(`the card did not come to rest in ${NAV_TIMEOUT} ms: ${sel} last ${last}`)
}

async function heightCase(browser, vp, tag) {
  const { p, errors } = await open(browser, vp)
  const { shortId, longId, movedId } = await seedCards(p)
  const pics = await seedPictureCards(p)
  await setClipMode(p)
  
  const shortSel = `.spool-main article.msg[data-msg-id="${shortId}"]`
  const longSel = `.spool-main article.msg[data-msg-id="${longId}"]`
  const movedSel = `.spool-main article.msg[data-msg-id="${movedId}"]`
  
  await p.waitForSelector(`${shortSel} [data-testid=card-body]`, { timeout: 15000 })
  await p.waitForSelector(`${longSel} [data-testid=card-body]`, { timeout: 15000 })
  await p.waitForSelector(`${movedSel} [data-testid=msg-moved]`, { timeout: 15000 })
  
  await p.evaluate((shortSel, longSel) => {
    document.querySelector(shortSel).scrollIntoView({ block: 'center' })
    document.querySelector(longSel).scrollIntoView({ block: 'center' })
  }, shortSel, longSel)
  
  const shortCard = await rest(p, shortSel)
  const longCard = await rest(p, longSel)
  const movedCard = await rest(p, movedSel)
  
  if (SHOTS) {
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-short.png`) })
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-long.png`) })
  }
  
  const maxDiff = SLACK_PX
  const heightDiff = Math.abs(shortCard.height - longCard.height)
  
  ok(`${tag}: 1-row and 8-row card bodies have equal heights (±${maxDiff}px)`, heightDiff <= maxDiff, {
    shortHeight: shortCard.height,
    longHeight: longCard.height,
    diff: heightDiff
  })

  const cardDiff = Math.abs(shortCard.card - longCard.card)
  ok(`${tag}: 1-row and 8-row whole cards have equal heights (±${maxDiff}px)`, cardDiff <= maxDiff, {
    shortCard: shortCard.card,
    longCard: longCard.card,
    diff: cardDiff
  })
  
  const movedDiff = Math.abs(movedCard.card - shortCard.card)
  ok(`${tag}: a card with a "moved from" line is as tall as the others (±${maxDiff}px)`, movedDiff <= maxDiff, {
    movedCard: movedCard.card,
    shortCard: shortCard.card,
    diff: movedDiff
  })

  ok(`${tag}: 8-row card is clipped and shows the grip`, longCard.clip === 'cut' && longCard.grip, {
    clip: longCard.clip, 
    grip: longCard.grip
  })
  
  ok(`${tag}: 1-row card is not clipped and has no grip`, shortCard.clip === 'fits' && !shortCard.grip, {
    clip: shortCard.clip, 
    grip: shortCard.grip
  })
  
  /* SPL-2121: pictures and a link preview count inside the same 5-row box */
  const picCases = [
    { key: 'one', id: pics.oneId, imgs: 1, label: '1 picture' },
    { key: 'three', id: pics.threeId, imgs: 3, label: '3 pictures' },
    { key: 'text', id: pics.textId, imgs: 1, label: 'picture + text' },
    { key: 'preview', id: pics.previewId, imgs: 0, label: 'link preview' },
  ]
  const picSel = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
  for (const c of picCases) {
    await p.waitForSelector(`${picSel(c.id)} [data-testid=card-body]`, { timeout: 15000 })
    await p.evaluate((sel) => document.querySelector(sel).scrollIntoView({ block: 'center' }), picSel(c.id))
    if (c.imgs) await picturesLoaded(p, picSel(c.id), c.imgs)
    else await p.waitForSelector(`${picSel(c.id)} [data-test=link-preview]`, { timeout: 15000 })
    c.rows = await rest(p, picSel(c.id))
    const diff = Math.abs(c.rows.card - shortCard.card)
    ok(`${tag}: a card with ${c.label} is as tall as a 1-row card (±${maxDiff}px)`, diff <= maxDiff, {
      card: c.rows.card,
      shortCard: shortCard.card,
      diff,
    })
  }
  for (const c of picCases.filter((x) => x.imgs)) {
    ok(`${tag}: the ${c.label} card is cut and shows the grip`, c.rows.clip === 'cut' && c.rows.grip, { clip: c.rows.clip, grip: c.rows.grip })
  }
  if (SHOTS) {
    await p.evaluate((sel) => document.querySelector(sel).scrollIntoView({ block: 'center' }), picSel(pics.oneId))
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-pictures.png`) })
    /* the last picture card at the top: the text cards after it fill the rest */
    await p.evaluate((ids) => {
      const cards = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
      const last = cards.filter((c) => ids.includes(c.getAttribute('data-msg-id'))).pop()
      last.scrollIntoView({ block: 'start' })
    }, [pics.oneId, pics.threeId, pics.textId])
    await sleep(300)
    await p.screenshot({ path: join(SHOTS, `card-height-rows-${tag}-text-and-pictures.png`) })
  }
  /* the grip under a cut picture card opens all of it, like a long text card */
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=card-grip]`).click(), picSel(pics.oneId))
  const oneOpen = await rest(p, picSel(pics.oneId))
  ok(`${tag}: the grip opens the whole picture card`, oneOpen.clip === 'fits' && oneOpen.card > picCases[0].rows.card + 100, {
    open: oneOpen.card,
    rowsCard: picCases[0].rows.card,
    clip: oneOpen.clip,
  })

  await setClipMode(p, 'full')
  const shortFull = await rest(p, shortSel)
  const longFull = await rest(p, longSel)
  ok(`${tag}: full mode keeps the natural heights (1-row card shorter)`, shortFull.card + 20 < longFull.card, {
    shortCard: shortFull.card,
    longCard: longFull.card,
  })
  await p.evaluate((sel) => document.querySelector(sel)?.scrollIntoView({ block: 'center' }), picSel(pics.oneId))
  const oneFull = await rest(p, picSel(pics.oneId))
  ok(`${tag}: full mode keeps the natural heights (1-picture card taller than 5 rows)`, oneFull.card > picCases[0].rows.card + 20 && oneFull.clip === '', {
    pictureCard: oneFull.card,
    rowsCard: picCases[0].rows.card,
  })

  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESKTOP = { width: 1440, height: 900 }
const server = await startServer()
const browser = await launch()
try {
  await heightCase(browser, DESKTOP, '1440px')
  await heightCase(browser, PHONE, '390px')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)