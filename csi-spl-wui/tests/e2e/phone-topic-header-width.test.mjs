// t1 1d8e647d follow-up: on a phone the /t header title was ~5 characters
// (52 px at 360, 64 px at 390, 81 px at 430 on origin/master before this
// change). The title must take >= 60% of the header row at 360 / 390 / 430,
// stay on one row, and the page must not scroll sideways. The full text is
// the hover title and a long-press tooltip. Desktop keeps Topics /, the
// status, and the card-height control on the row.
//
// Run: node tests/e2e/phone-topic-header-width.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TITLE = 'Review the spool WUI scaffold and keep tests green.'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

async function waitTitle(page) {
  for (let i = 0; i < 40; i++) {
    const found = await page.evaluate(() => !!document.querySelector('[data-test=topic-page-title]')).catch(() => false)
    if (found) return true
    await sleep(500)
  }
  return false
}

async function openTopic(page) {
  const url = `${srv.base}/t/${TOPIC}`
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.goto(url, { waitUntil: 'domcontentloaded' })
    if (await waitTitle(page)) return
  }
  throw new Error('topic title never appeared')
}

function readBox(page) {
  return page.evaluate(() => {
    const box = (el) => {
      if (!el) return null
      const r = el.getBoundingClientRect()
      const s = getComputedStyle(el)
      const visible = s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0
      return {
        w: Math.round(r.width * 10) / 10,
        h: Math.round(r.height * 10) / 10,
        y: Math.round(r.y * 10) / 10,
        visible,
        text: (el.textContent || '').replace(/\s+/g, ' ').trim(),
      }
    }
    const header = document.querySelector('.feed-header')
    const title = document.querySelector('[data-test=topic-page-title]')
    const hr = header ? header.getBoundingClientRect() : null
    const tops = [title, document.querySelector('[data-testid=mobile-back]'), document.querySelector('[data-test=topic-page-more]')]
      .filter(Boolean)
      .map((el) => el.getBoundingClientRect())
      .filter((r) => r.width > 0 && r.height > 0)
    const ys = tops.map((r) => r.y + r.height / 2)
    return {
      inner: window.innerWidth,
      docScroll: document.documentElement.scrollWidth,
      docClient: document.documentElement.clientWidth,
      headerW: hr ? Math.round(hr.width * 10) / 10 : 0,
      headerH: hr ? Math.round(hr.height * 10) / 10 : 0,
      headerScroll: header ? header.scrollWidth : 0,
      headerClient: header ? header.clientWidth : 0,
      title: box(title),
      titleAttr: title ? title.getAttribute('title') : '',
      crumb: box(document.querySelector('.topic-page-crumb')),
      status: box(header ? header.querySelector(':scope > .topic-page-status') : null),
      clip: box(document.querySelector('[data-testid=card-clip-control]')),
      more: box(document.querySelector('[data-test=topic-page-more]')),
      back: box(document.querySelector('[data-testid=mobile-back]')),
      rowSpread: ys.length ? Math.round((Math.max(...ys) - Math.min(...ys)) * 10) / 10 : 999,
    }
  })
}

const SHOT = '/tmp/g-181-phone-topic-border.png'
const THREADS = [
  ['channel', `/channel/lobby?topic=${TOPIC}`],
  ['topics', `/?topic=${TOPIC}`],
]

function readThread(page) {
  return page.evaluate(() => {
    const el = document.querySelector('[data-test=topic-heading]')
    const textEl = el && el.querySelector('.topic-heading__text')
    const label = el && el.querySelector('.topic-heading__label')
    const s = el ? getComputedStyle(el) : null
    const ls = label ? getComputedStyle(label) : null
    const lr = label ? label.getBoundingClientRect() : null
    const clips = [...document.querySelectorAll('[data-clip-pane="thread"] .card-clip-ctl__opt')].filter((n) => {
      const r = n.getBoundingClientRect()
      const cs = getComputedStyle(n)
      return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
    }).length
    return {
      text: textEl ? (textEl.textContent || '').replace(/\s+/g, ' ').trim() : '',
      labelText: label ? (label.textContent || '').replace(/\s+/g, ' ').trim() : '',
      labelOn: !!(ls && ls.display !== 'none' && lr && lr.width > 0 && lr.height > 0),
      border: s ? [s.borderTopWidth, s.borderRightWidth, s.borderBottomWidth, s.borderLeftWidth] : [],
      borderStyle: s ? [s.borderTopStyle, s.borderRightStyle, s.borderBottomStyle, s.borderLeftStyle] : [],
      shadow: s ? s.boxShadow : '',
      clips,
    }
  })
}

async function openThread(page, path) {
  const url = `${srv.base}${path}`
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.goto(url, { waitUntil: 'domcontentloaded' })
    for (let i = 0; i < 40; i++) {
      const text = await page.evaluate(() => {
        const el = document.querySelector('[data-test=topic-heading] .topic-heading__text')
        return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''
      }).catch(() => '')
      if (text === TITLE) return
      await sleep(500)
    }
  }
  throw new Error(`thread title never appeared: ${path}`)
}

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(60000)
  for (const width of [360, 390, 430]) {
    await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
    await openTopic(page)
    await sleep(300)
    const m = await readBox(page)
    const ratio = m.headerW ? m.title.w / m.headerW : 0
    console.log(`MEASURE ${width} title=${m.title.w} header=${m.headerW} ratio=${ratio.toFixed(3)} headerH=${m.headerH}`)
    ok(`${width}px viewport applied`, m.inner === width, m.inner)
    ok(`${width}px title is >= 60% of the header row`, ratio >= 0.6, { title: m.title.w, header: m.headerW, ratio })
    ok(`${width}px the title is the topic text, not the id`, m.title.text === TITLE && m.titleAttr === TITLE, m.title)
    ok(`${width}px one row (header under 72px, controls share a centre)`, m.headerH <= 72 && m.rowSpread <= 20, { headerH: m.headerH, rowSpread: m.rowSpread })
    ok(`${width}px no sideways scroll`, m.docScroll <= m.docClient + 1 && m.headerScroll <= m.headerClient + 1, m)
    ok(`${width}px Topics / is not on the row`, m.crumb && !m.crumb.visible, m.crumb)
    ok(`${width}px the status line is not on the row`, m.status && !m.status.visible, m.status)
    ok(`${width}px the card-height control is not on the row`, m.clip && !m.clip.visible, m.clip)
    ok(`${width}px the overflow button is a 44px target`, m.more && m.more.visible && m.more.w >= 44 && m.more.h >= 44, m.more)

    await page.evaluate(() => {
      const el = document.querySelector('[data-test=topic-page-title]')
      const r = el.getBoundingClientRect()
      el.dispatchEvent(new PointerEvent('pointerdown', {
        bubbles: true, pointerType: 'touch', isPrimary: true, clientX: r.x + 8, clientY: r.y + 8,
      }))
    })
    await sleep(650)
    const tip = await page.evaluate(() => {
      const el = document.querySelector('[data-test=topic-page-title-full]')
      return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''
    })
    ok(`${width}px a long-press shows the full title`, tip === TITLE, tip)
    await page.evaluate(() => {
      document.querySelector('[data-test=topic-page-title]')?.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerType: 'touch', isPrimary: true }))
    })

    await page.click('[data-test=topic-page-more]')
    await sleep(200)
    const open = await readBox(page)
    const openRatio = open.headerW ? open.title.w / open.headerW : 0
    ok(`${width}px the overflow shows the card-height control`, open.clip && open.clip.visible, open.clip)
    ok(`${width}px opening the overflow keeps the title >= 60%`, openRatio >= 0.6, { title: open.title.w, header: open.headerW })
    ok(`${width}px opening the overflow does not scroll sideways`, open.docScroll <= open.docClient + 1, open)
  }

  await page.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await openTopic(page)
  await sleep(300)
  const desk = await readBox(page)
  console.log(`MEASURE 1280 title=${desk.title.w} header=${desk.headerW} ratio=${(desk.title.w / desk.headerW).toFixed(3)}`)
  ok('1280px viewport applied', desk.inner === 1280, desk.inner)
  ok('1280px Topics / stays on the row', desk.crumb && desk.crumb.visible && desk.crumb.text === 'Topics', desk.crumb)
  ok('1280px the status stays on the row', desk.status && desk.status.visible, desk.status)
  ok('1280px the card-height control stays on the row', desk.clip && desk.clip.visible, desk.clip)
  ok('1280px the overflow button is not shown', desk.more && !desk.more.visible, desk.more)
  ok('1280px there is no back arrow', !desk.back || !desk.back.visible, desk.back)
  ok('1280px the title still shows the topic text', desk.title.text === TITLE, desk.title)
  ok('1280px no sideways scroll', desk.docScroll <= desk.docClient + 1, desk)

  const four = (b) => b.length === 4 && b.every((w) => w === '1px')
  const none = (b) => b.length === 4 && b.every((w) => w === '0px')
  const solid = (st) => st.length === 4 && st.every((w) => w === 'solid')
  for (const width of [360, 390, 430]) {
    await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
    for (const [name, path] of THREADS) {
      await openThread(page, path)
      await sleep(300)
      const h = await readThread(page)
      console.log(`THREAD ${width} ${name} text=${JSON.stringify(h.text)} label=${h.labelOn} border=${h.border} shadow=${h.shadow} clips=${h.clips}`)
      ok(`${width}px ${name} title has no Topic: prefix`, h.text === TITLE && !h.labelOn && !h.text.startsWith('Topic:'), h)
      ok(`${width}px ${name} title has a four-side 1px border`, four(h.border) && solid(h.borderStyle) && h.shadow === 'none', h)
      ok(`${width}px ${name} the three clip buttons stay`, h.clips === 3, h.clips)
      if (width === 390 && name === 'channel') {
        await page.screenshot({ path: SHOT })
        console.log(`SHOT ${SHOT}`)
      }
    }
  }

  await page.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  for (const [name, path] of THREADS) {
    await openThread(page, path)
    await sleep(300)
    const h = await readThread(page)
    console.log(`THREAD 1280 ${name} label=${JSON.stringify(h.labelText)} border=${h.border} shadow=${h.shadow}`)
    ok(`1280px ${name} keeps the Topic: label`, h.text === TITLE && h.labelOn && h.labelText === 'Topic:', h)
    ok(`1280px ${name} keeps the left selection bar`, none(h.border) && h.shadow.includes('inset'), h)
    ok(`1280px ${name} the three clip buttons stay`, h.clips === 3, h.clips)
  }
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-topic-header-width: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
