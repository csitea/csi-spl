// The topic view (/t/:id) is two panels. On a phone one shows at a time:
// the thread, then Back to the list, then the row back to the thread.
// Desktop shows both, the sidebar stays hidden, and a channel still has it.
// The thread title is the topic text inside a four-side 1px border.
//
// Run: node tests/e2e/phone-topic-header-width.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
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

async function waitThread(page) {
  for (let i = 0; i < 40; i++) {
    const text = await page.evaluate(() => {
      const el = document.querySelector('[data-test=topic-browse-thread] [data-test=topic-heading] .topic-heading__text')
      return el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : ''
    }).catch(() => '')
    if (text === TITLE) return true
    await sleep(500)
  }
  return false
}

async function openTopic(page) {
  const url = `${srv.base}/t/${TOPIC}`
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.goto(url, { waitUntil: 'domcontentloaded' })
    if (await waitThread(page)) return
  }
  throw new Error('topic title never appeared')
}

function readBrowse(page) {
  return page.evaluate(() => {
    const box = (el) => {
      if (!el) return null
      const r = el.getBoundingClientRect()
      const s = getComputedStyle(el)
      const visible = s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0
      return {
        w: Math.round(r.width * 10) / 10,
        visible,
        text: (el.textContent || '').replace(/\s+/g, ' ').trim(),
      }
    }
    const shell = document.querySelector('.spool-shell')
    const root = document.querySelector('[data-test=topic-browse]')
    const title = document.querySelector('[data-test=topic-browse-thread] [data-test=topic-heading] .topic-heading__text')
    return {
      inner: window.innerWidth,
      docScroll: document.documentElement.scrollWidth,
      docClient: document.documentElement.clientWidth,
      phone: root ? root.getAttribute('data-phone') || '' : '',
      list: box(document.querySelector('[data-test=topic-browse-list]')),
      thread: box(document.querySelector('[data-test=topic-browse-thread]')),
      title: title ? (title.textContent || '').replace(/\s+/g, ' ').trim() : '',
      sidebar: box(shell ? shell.querySelector(':scope > .sidebar') : null),
      sections: document.querySelectorAll('[data-test=topic-section]').length,
    }
  })
}

const SHOT_DIR = mkdtempSync(join(tmpdir(), 'topic-border-'))
const THREADS = [
  ['channel', `/channel/lobby?topic=${TOPIC}`],
  ['topics', `/?topic=${TOPIC}`],
  ['topic-view', `/t/${TOPIC}`],
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
    const m = await readBrowse(page)
    console.log(`MEASURE ${width} phone=${m.phone} title=${JSON.stringify(m.title)} list=${m.list && m.list.visible} thread=${m.thread && m.thread.visible}`)
    ok(`${width}px viewport applied`, m.inner === width, m.inner)
    ok(`${width}px the thread is the panel on screen`, m.phone === 'thread' && m.thread && m.thread.visible && m.list && !m.list.visible, m)
    ok(`${width}px the title is the topic text`, m.title === TITLE, m.title)
    ok(`${width}px one topic section`, m.sections === 1, m.sections)
    ok(`${width}px no sideways scroll`, m.docScroll <= m.docClient + 1, m)

    await page.click('[data-test=topic-browse-thread] [data-testid=mobile-back]')
    await sleep(400)
    const back = await readBrowse(page)
    ok(`${width}px Back returns to the topic list`, back.phone === 'list' && back.list && back.list.visible && back.thread && !back.thread.visible, back)

    await page.click(`[data-test=topic-browse-list] [data-key="${TOPIC}"]`)
    await sleep(400)
    const again = await readBrowse(page)
    ok(`${width}px the row opens the thread again`, again.phone === 'thread' && again.title === TITLE, again)
  }

  await page.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await openTopic(page)
  await sleep(300)
  const desk = await readBrowse(page)
  console.log(`MEASURE 1280 list=${desk.list && desk.list.w} thread=${desk.thread && desk.thread.w} sections=${desk.sections}`)
  ok('1280px viewport applied', desk.inner === 1280, desk.inner)
  ok('1280px both panels are on screen', desk.list && desk.list.visible && desk.thread && desk.thread.visible, desk)
  ok('1280px the thread is wider than the list', desk.thread.w > desk.list.w, { thread: desk.thread.w, list: desk.list.w })
  ok('1280px the sidebar is not a third panel', desk.sidebar && !desk.sidebar.visible, desk.sidebar)
  ok('1280px one topic section', desk.sections === 1, desk.sections)
  ok('1280px the title is the topic text', desk.title === TITLE, desk.title)
  ok('1280px no sideways scroll', desk.docScroll <= desk.docClient + 1, desk)

  await page.goto(`${srv.base}/channel/lobby`, { waitUntil: 'domcontentloaded' })
  let channel = { visible: false }
  for (let i = 0; i < 40; i++) {
    channel = await page.evaluate(() => {
      const el = document.querySelector('.spool-shell > .sidebar')
      if (!el) return { visible: false, path: location.pathname }
      const r = el.getBoundingClientRect()
      const s = getComputedStyle(el)
      return {
        visible: s.display !== 'none' && r.width > 0,
        w: Math.round(r.width),
        path: location.pathname,
        browse: document.querySelector('.spool-shell')?.getAttribute('data-topic-browse') || '',
      }
    })
    if (channel.visible && channel.w > 40) break
    await sleep(250)
  }
  ok('1280px the channel view still shows the sidebar', channel.visible && channel.w > 40, channel)

  const four = (b) => b.length === 4 && b.every((w) => w === '1px')
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
        const shot = join(SHOT_DIR, 'phone-topic-border.png')
        await page.screenshot({ path: shot })
        console.log(`SHOT ${shot}`)
      }
    }
  }

  await page.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  for (const [name, path] of THREADS) {
    await openThread(page, path)
    await sleep(300)
    const h = await readThread(page)
    console.log(`THREAD 1280 ${name} text=${JSON.stringify(h.text)} label=${h.labelOn} border=${h.border} shadow=${h.shadow} clips=${h.clips}`)
    ok(`1280px ${name} title has no Topic: prefix`, h.text === TITLE && !h.labelOn && !h.text.startsWith('Topic:'), h)
    ok(`1280px ${name} title has a four-side 1px border`, four(h.border) && solid(h.borderStyle) && h.shadow === 'none', h)
    ok(`1280px ${name} the three clip buttons stay`, h.clips === 3, h.clips)
    if (name === 'channel') {
      const shot = join(SHOT_DIR, 'desktop-topic-border.png')
      const head = await page.$('[data-test=topic-section] header')
      if (head) await head.screenshot({ path: shot })
      else await page.screenshot({ path: shot })
      console.log(`SHOT ${shot}`)
    }
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
