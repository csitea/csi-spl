// Phone tap on a link inside a message body (topic pane, level 3).
//
// A finger-up on the anchor must open the link even when the click never
// arrives: the card is user-select:none and a draggable anchor lets the
// browser drop that click. The CONTROL installs a capture click listener
// that cancels every click, which is that drop. Without the pointerup open,
// the tap stays on the topic. Desktop clicks stay on the click path.
//
// An archived topic is the same anchor. The tap opens it: HUM-10 (t1
// 36ea84a6) no link opens the Topics view, so /t/<id> goes through /m/<id>,
// which says the topic is archived and where it went. Resolving an id into a link is not this test.
//
// Run: node tests/e2e/phone-message-link-tap.test.mjs
//      BASE_URL=<generated mock bundle> node tests/e2e/phone-message-link-tap.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'
const SHA = 'abcdef1'
const EXT = 'https://example.com/outside-note'
const ARCH_MSG = '11111111-1111-4111-8111-111111111111'
const ARCH_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

function mdBody(origin) {
  return `## Release notes\n\n- dev ${EXT}\n- prd ${origin}/releases/${SHA}\n\nEnd of note.\n`
}

function archBody(origin) {
  return `## Archived\n\nThe old thread is ${origin}/t/${ARCH_TASK}\n\nEnd of note.\n`
}

async function prep(page) {
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem('spool-card-clip-thread', 'full')
    localStorage.setItem('spool-card-clip', 'full')
    sessionStorage.setItem('spool-card-clip-session-thread', 'full')
    window.__opens = []
    window.open = (url) => {
      window.__opens.push(String(url))
      return { closed: false, opener: null }
    }
  })
}

async function setBody(page, body) {
  await page.evaluate((id, text) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    ch.messages = ch.messages.map((m) => (m.msg_id === id ? { ...m, body: text } : m))
  }, REPLY, body)
  // The feed slides the rows under a changed body. For that fifth of a
  // second the sliding row is painted over the link, and a click there
  // hits the row. Wait until the slide is gone.
  await page.evaluate(() => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  }))
  await page.waitForFunction(
    () => !document.querySelector('.prepend-move, .append-move'),
    { timeout: 2000 },
  ).catch(() => {})
}

async function openPost(page, base, body) {
  await page.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  await sleep(800)
  await setBody(page, body)
}

/** Where a visible topic link sits, and whether the finger would hit the anchor. */
async function linkPoint(page, part) {
  let last = null
  for (let i = 0; i < 5; i++) {
    last = await page.evaluate((needle) => {
    const list = [...document.querySelectorAll('.spool-shell > .topic a.msg-link')]
    const a = list.find((el) => (el.getAttribute('href') || '').includes(needle))
    if (!a) return null
    a.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' })
    const r = a.getBoundingClientRect()
    let x = 0
    let y = 0
    let hit = null
    let hitA = null
    outer: for (let yy = Math.ceil(r.top) + 1; yy < r.bottom; yy += 2) {
      for (let xx = Math.ceil(r.left) + 1; xx < r.right; xx += 2) {
        const at = document.elementFromPoint(xx, yy)
        const link = at && at.closest ? at.closest('a.msg-link') : null
        if (link === a) { x = Math.round(xx); y = Math.round(yy); hit = at; hitA = link; break outer }
      }
    }
    return {
      x, y,
      href: a.getAttribute('href'),
      draggable: a.getAttribute('draggable'),
      markdown: Boolean(a.closest('[data-testid=md-block]')),
      target: a.getAttribute('target'),
      hit: hitA === a,
      hitTag: hit ? `${hit.tagName}.${String(hit.className || '').slice(0, 40)}` : null,
    }
    }, part)
    if (last && last.hit && last.x > 0) return last
    await sleep(150)
  }
  return last
}

async function touchTap(page, x, y) {
  const cdp = await page.createCDPSession()
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] })
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach()
}

async function tapLink(page, part) {
  const pt = await linkPoint(page, part)
  if (!pt || !pt.hit || !(pt.x > 0)) return { pt, tapped: false }
  await touchTap(page, pt.x, pt.y)
  return { pt, tapped: true }
}

/** Capture-phase cancel of every click: the phone drop the pointerup path has to beat. */
async function swallowClicks(page, on) {
  await page.evaluate((enable) => {
    const fn = window.__swallowClicks || ((e) => {
      e.preventDefault()
      e.stopImmediatePropagation()
    })
    window.__swallowClicks = fn
    window.removeEventListener('click', fn, true)
    if (enable) window.addEventListener('click', fn, true)
  }, on)
}

/** Archive the welcome card from its menu. A generated bundle does not expose
    the component api, and a reload after this drops the mock's archived set,
    so the caller stays in this document. */
async function archiveWelcome(page, base) {
  await page.goto(`${base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: 15000 })
  await sleep(500)
  const sel = `article.msg[data-msg-id="${ARCH_MSG}"]`
  const card = await page.waitForSelector(sel, { timeout: 10000 }).catch(() => null)
  if (!card) return { ok: false, archived: false, reason: 'no-card' }
  let opened = false
  for (let i = 0; i < 3 && !opened; i++) {
    await page.evaluate((s) => {
      document.querySelector(`${s} [data-testid=msg-menu-btn]`)?.click()
    }, sel)
    opened = await page.waitForSelector('[data-testid=msg-menu-archive]', { timeout: 2000 }).then(() => true).catch(() => false)
  }
  if (!opened) return { ok: false, archived: false, reason: 'no-menu' }
  const click = await page.evaluate(() => {
    const el = document.querySelector('[data-testid=msg-menu-archive]')
    if (!el) return { ok: false, reason: 'no-item' }
    if (el.getAttribute('aria-disabled') === 'true') return { ok: false, reason: 'disabled' }
    el.click()
    return { ok: true }
  })
  if (!click.ok) return { ok: false, archived: false, reason: click.reason }
  const gone = await page.waitForFunction((s) => !document.querySelector(s), { timeout: 8000 }, sel).then(() => true).catch(() => false)
  return { ok: gone, archived: gone, task_id: ARCH_TASK, reason: gone ? 'archived' : 'card-stayed' }
}

/** Stay on the same document so the archive above is still in the mock. */
async function openTopicClient(page, body) {
  await page.evaluate(async (from) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    await app.config.globalProperties.$router.push({ path: '/channel/lobby', query: { topic: from } })
  }, FROM)
  await page.waitForFunction((id) => location.search.includes('topic=' + id), { timeout: 8000 }, FROM)
  await page.waitForSelector('.spool-shell > .topic', { timeout: 8000 })
  await sleep(600)
  await setBody(page, body)
}

/** Click a pixel with the anchor on both sides.
    The first uncovered pixel of a wrapped URL is a one-pixel sliver on the
    generated-bundle runner, and a mouse click there misses the anchor. */
async function clickLink(page, part) {
  const point = await page.evaluate((needle) => {
    const list = [...document.querySelectorAll('.spool-shell > .topic a.msg-link')]
    const a = list.find((el) => (el.getAttribute('href') || '').includes(needle))
    if (!a) return { hit: false, reason: 'no-anchor' }
    a.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' })
    const owns = (x, y) => {
      const at = document.elementFromPoint(x, y)
      return Boolean(at && at.closest && at.closest('a.msg-link') === a)
    }
    const rects = [...a.getClientRects()].filter((r) => r.width >= 8 && r.height >= 8)
    const pts = []
    for (const r of rects) {
      for (let y = Math.ceil(r.top) + 1; y < r.bottom; y += 2) {
        for (let x = Math.ceil(r.left) + 1; x < r.right; x += 2) {
          if (owns(x, y)) pts.push([x, y])
        }
      }
    }
    if (!pts.length) {
      const sample = rects.slice(0, 3).map((r) => {
        const x = r.left + r.width / 2
        const y = r.top + r.height / 2
        const at = document.elementFromPoint(x, y)
        return {
          w: Math.round(r.width), h: Math.round(r.height),
          at: at ? at.tagName + '.' + String(at.className || '').slice(0, 24) : null,
        }
      })
      return { hit: false, reason: 'no-pixel', n: rects.length, sample }
    }
    let best = pts[0]
    let bestScore = -1
    for (const [x, y] of pts) {
      let score = 0
      for (let d = 2; d <= 16; d += 2) {
        if (owns(x - d, y)) score++
        if (owns(x + d, y)) score++
      }
      if (score > bestScore) { bestScore = score; best = [x, y] }
    }
    return {
      hit: true,
      x: Math.round(best[0]),
      y: Math.round(best[1]),
      score: bestScore,
      n: pts.length,
    }
  }, part)
  if (!point || !point.hit) return point || { hit: false, reason: 'no-point' }
  try {
    await page.mouse.click(point.x, point.y)
  } catch (e) {
    return { hit: false, reason: String(e && e.message || e), x: point.x, y: point.y }
  }
  return { hit: true, x: point.x, y: point.y, score: point.score, n: point.n }
}

const state = (page) => page.evaluate(() => {
  const vis = (sel) => {
    const e = document.querySelector(sel)
    if (!e) return false
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  }
  return {
    path: location.pathname + location.search,
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
    pane: vis('.spool-shell > .topic'),
    releases: vis('[data-test=releases-page]'),
    topicPage: vis('[data-test=topic-root]'),
    archived: Boolean(document.querySelector('[data-test=archived-badge]')),
    archivedNotice: vis('[data-testid=open-msg-notice][data-reason=archived]'),
    opens: (window.__opens || []).slice(),
    hist: history.length,
  }
})

async function waitPath(page, part) {
  try {
    await page.waitForFunction((needle) => location.pathname.includes(needle), { timeout: 8000 }, part)
  } catch { /* the assertion reports the path */ }
}

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await prep(phone)
  const origin = new URL(srv.base).origin
  await openPost(phone, srv.base, mdBody(origin))
  await phone.waitForFunction(() => {
    const a = document.querySelector('.spool-shell > .topic [data-testid=md-block][data-rendered=true] a.msg-link')
    if (!a) return false
    const r = a.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }, { timeout: 15000 })

  const ext = await linkPoint(phone, 'example.com/outside-note')
  const inner = await linkPoint(phone, `/releases/${SHA}`)
  ok('markdown body renders both links, not draggable, under the finger',
    Boolean(ext && inner && ext.markdown && inner.markdown && ext.draggable === 'false' && inner.draggable === 'false' && ext.hit && inner.hit && ext.target === '_blank' && !inner.target),
    { ext, inner })

  await swallowClicks(phone, true)
  await phone.evaluate(() => { window.__opens = [] })
  const extTap = await tapLink(phone, 'example.com/outside-note')
  await sleep(400)
  let s = await state(phone)
  ok('CONTROL: a tap on an external link opens it when the click is swallowed',
    extTap.tapped && s.opens.some((u) => u.includes('example.com/outside-note')) && s.path.includes(`topic=${FROM}`) && s.pane,
    s)

  const relTap = await tapLink(phone, `/releases/${SHA}`)
  await waitPath(phone, `/releases/${SHA}`)
  s = await state(phone)
  ok('CONTROL: a tap on an internal link opens it when the click is swallowed',
    relTap.tapped && s.path.includes(`/releases/${SHA}`) && s.releases && !s.pane,
    s)

  await swallowClicks(phone, false)
  await openPost(phone, srv.base, `Read the note at ${origin}/releases/${SHA}`)
  await phone.waitForFunction((sha) => {
    const a = document.querySelector('.spool-shell > .topic a.msg-link')
    if (!a || a.closest('[data-testid=md-block]')) return false
    const r = a.getBoundingClientRect()
    return (a.getAttribute('href') || '').includes(`/releases/${sha}`) && r.width > 0 && r.height > 0
  }, { timeout: 8000 }, SHA)
  await swallowClicks(phone, true)
  const plain = await linkPoint(phone, `/releases/${SHA}`)
  ok('a plain body link is MessageRuns and under the finger',
    Boolean(plain && plain.hit && !plain.markdown && plain.draggable === 'false'), plain)
  const plainTap = await tapLink(phone, `/releases/${SHA}`)
  await waitPath(phone, `/releases/${SHA}`)
  s = await state(phone)
  ok('CONTROL: a tap on a plain-body link opens it when the click is swallowed',
    plainTap.tapped && s.path.includes(`/releases/${SHA}`) && s.releases && !s.pane,
    s)

  await swallowClicks(phone, false)
  const archived = await archiveWelcome(phone, srv.base)
  await openTopicClient(phone, archBody(origin))
  await phone.waitForFunction((id) => {
    const a = [...document.querySelectorAll('.spool-shell > .topic a.msg-link')]
      .find((el) => (el.getAttribute('href') || '').includes(`/t/${id}`))
    if (!a) return false
    const r = a.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }, { timeout: 8000 }, ARCH_TASK)
  await swallowClicks(phone, true)
  const archTap = await tapLink(phone, `/t/${ARCH_TASK}`)
  await waitPath(phone, `/m/${ARCH_TASK}`)
  try {
    await phone.waitForFunction(() => {
      const e = document.querySelector('[data-testid=open-msg-notice][data-reason=archived]')
      if (!e) return false
      const r = e.getBoundingClientRect()
      return r.width > 0 && r.height > 0
    }, { timeout: 8000 })
  } catch { /* the assertion reports the badge */ }
  s = await state(phone)
  ok('CONTROL: a tap on a link to an archived topic opens that topic',
    archived.ok === true && archived.archived === true && archived.task_id === ARCH_TASK
      && archTap.tapped && s.path.includes(`/m/${ARCH_TASK}`) && s.archivedNotice && !s.topicPage,
    { archive: archived, tap: archTap.pt, page: s })
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await prep(desk)
  await openPost(desk, srv.base, mdBody(origin))
  await desk.waitForFunction(() => {
    const a = document.querySelector('.spool-shell > .topic [data-testid=md-block][data-rendered=true] a.msg-link')
    if (!a) return false
    const r = a.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }, { timeout: 15000 })
  const beforeOpens = await desk.evaluate(() => (window.__opens || []).length)
  const dpt = await linkPoint(desk, `/releases/${SHA}`)
  const clicked = await clickLink(desk, `/releases/${SHA}`)
  await waitPath(desk, `/releases/${SHA}`)
  s = await state(desk)
  ok('desktop: a click on the markdown link opens it in this tab',
    Boolean(dpt && dpt.hit && clicked && clicked.hit) && s.path.includes(`/releases/${SHA}`) && s.releases && s.opens.length === beforeOpens,
    { dpt, clicked, ...s })
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-message-link-tap: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
