// t1 3eb98913 (owner 2026-10-10: "I should be able to direct msg any type of
// agents - antigravity, claude, mistral, grok" ... "it dos not even have a msg
// button"). His screenshot was /dm/<agy agent>@<box>: online, "No messages yet.", and
// nothing to click - the DM's composer is the Omnibox. Real browser, mock
// tenant, 1440 and 390, one agent of each kind (a-, c-, g-, m-):
//
//   button   an empty DM shows a Message button (data-test=dm-start-message)
//   focus    a click puts the caret in the Omnibox
//   opened   SPL-2699 (t1 b4f175c7, owner: "cannot send a msg to an offline
//            human" - his screenshot: the caret in the Omnibox, nothing else):
//            the click also marks the Omnibox, keeps it in view and shows a
//            hint naming the reader's own send key (1440 runs as ctrl-enter,
//            the owner's mode; 390 as the default, Enter sends)
//   send     a line typed there and sent reaches that agent: the stored row's
//            to / to_box are the peer, and the button is gone
//
// SPL-2141 (t1 1061f05f msg 4d63f24c, suggestion 2: "a brand-new channel
// shows a blank pane"). The same start, for a channel with no messages
// (#feedback in the mock), in the dark and the light theme:
//
//   empty    the feed says whose start it is, once (role=status), with a
//            button, in view; a filter that matches nothing says how to undo it
//   focus    the button puts the caret in the Omnibox
//   live     the first line sent there takes the empty state away
//
//   BASE_URL=<generated bundle> node tests/e2e/dm-start-message.test.mjs
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const PEERS = ['a-101@box-a', 'c-101@box-a', 'g-101@box-a', 'm-101@box-a']
const OMNI = 'form.omnibox--global textarea'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
/* SPL-2699: the hint the Message click shows, per Settings -> Behaviour mode */
const SUBMIT = {
  1440: { key: 'ctrl-enter', hint: 'Enter for a new line, Ctrl+Enter or Cmd+Enter to send' },
  390: { key: null, hint: 'Enter sends, Shift+Enter adds a line' },
}

const results = []
const check = (name, pass, ev) => {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* in-app, not a reload: a cold /dm/<peer> in the mock lands on / first */
async function openDm(p, peer) {
  await p.evaluate((peer) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/dm/' + encodeURIComponent(peer)), peer)
  await p.waitForFunction((peer) => decodeURIComponent(location.pathname).endsWith('/dm/' + peer), { timeout: NAV }, peer)
  await sleep(800)
}

const startButton = (p) => p.evaluate(() => {
  const b = document.querySelector('[data-test=dm-start-message]')
  if (!b) return null
  const r = b.getBoundingClientRect()
  return { text: b.textContent.trim(), visible: r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight && r.right <= innerWidth }
})

/* SPL-2141: the empty channel's start, read where it shows */
const channelEmpty = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-testid=feed-empty]')
  if (!el) return null
  const r = el.getBoundingClientRect()
  const title = el.querySelector('.feed-empty__title')
  const btn = el.querySelector('[data-testid=feed-empty-start]')
  const br = btn ? btn.getBoundingClientRect() : null
  return {
    role: el.getAttribute('role'),
    statuses: el.querySelectorAll('[role=status]').length,
    search: el.dataset.search === 'true',
    title: title ? title.textContent.trim() : '',
    hint: (el.querySelector('.feed-empty__hint')?.textContent || '').trim(),
    fg: title ? getComputedStyle(title).color : '',
    bg: getComputedStyle(document.body).backgroundColor,
    visible: r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight && r.right <= innerWidth,
    button: br ? br.width > 0 && br.top >= 0 && br.bottom <= innerHeight : false,
  }
})

async function channelStart(p, width, theme) {
  const tag = `${width} ${theme} #feedback`
  await p.evaluate((theme) => document.documentElement.setAttribute('data-theme', theme), theme)
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/channel/feedback'))
  await p.waitForFunction(() => location.pathname.endsWith('/channel/feedback'), { timeout: NAV })
  await p.waitForFunction(() => document.querySelector('.feed-empty__title') || document.querySelector('article.msg'), { timeout: 15000 }).catch(() => {})
  const e = await channelEmpty(p)
  check(`${tag}: an empty channel says it is the start, in view`, Boolean(e && e.visible && e.title === 'This is the start of #feedback.' && e.hint.length > 0), e)
  check(`${tag}: it is one status a screen reader reads once`, Boolean(e && e.role === 'status' && e.statuses === 0), e && { role: e.role, nested: e.statuses })
  check(`${tag}: its button is in view`, Boolean(e && e.button), e && { button: e.button })
  check(`${tag}: its title is not drawn in the page background colour`, Boolean(e && e.fg && e.fg !== e.bg), e && { fg: e.fg, bg: e.bg })
  if (SHOT_DIR) { mkdirSync(SHOT_DIR, { recursive: true }); await p.screenshot({ path: `${SHOT_DIR}/channel-empty-${width}-${theme}.png` }) }
  /* a filter that matches nothing: the same place says how to undo it */
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').setSearch('zzqx-no-such-word'))
  await sleep(600)
  const f = await channelEmpty(p)
  check(`${tag}: a filter with no match says so and how to clear it`, Boolean(f && f.search && f.title === 'No messages match.' && /Clear/.test(f.hint)), f)
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').setSearch(''))
  await sleep(600)
  if (!e || !e.button) return
  await p.click('[data-testid=feed-empty-start]')
  await sleep(200)
  check(`${tag}: its button puts the caret in the Omnibox`, await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI))
  if (theme !== 'light') return
  /* live: the first line takes it away, no reload */
  await p.keyboard.type(`first post in #feedback at ${width}`)
  await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
  await p.waitForFunction(() => !document.querySelector('[data-testid=feed-empty]'), { timeout: 5000 }).catch(() => {})
  const after = await p.evaluate(() => ({ empty: Boolean(document.querySelector('[data-testid=feed-empty]')), rows: document.querySelectorAll('article.msg').length }))
  check(`${tag}: the first line takes the empty state away, live`, !after.empty && after.rows > 0, after)
}

async function run(browser, base, width) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: width < 600 ? 844 : 900, isMobile: width < 600, hasTouch: width < 600 })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
  }, SUBMIT[width].key ? { ...CLAIMS, submit_key: SUBMIT[width].key } : CLAIMS)
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await sleep(500)

  for (const peer of PEERS) {
    const id = peer.split('@')[0]
    await openDm(p, peer)
    const btn = await startButton(p)
    check(`${width} ${id}: an empty DM shows a Message button, in view`, Boolean(btn && btn.visible && btn.text === 'Message'), btn)
    if (SHOT_DIR) { mkdirSync(SHOT_DIR, { recursive: true }); await p.screenshot({ path: `${SHOT_DIR}/dm-start-${width}-${id}.png` }) }
    if (!btn) continue
    await p.click('[data-test=dm-start-message]')
    await sleep(200)
    const focused = await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI)
    check(`${width} ${id}: Message puts the caret in the Omnibox`, focused)
    const opened = await p.evaluate((sel) => {
      const form = document.querySelector(sel)?.closest('form')
      const r = form ? form.getBoundingClientRect() : null
      const hint = document.querySelector('[data-test=dm-start-hint]')
      return {
        marked: Boolean(form && form.classList.contains('omnibox--called') && getComputedStyle(form).outlineStyle === 'solid'),
        inView: Boolean(r && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight),
        hint: hint ? hint.textContent.trim() : null,
        role: hint ? hint.getAttribute('role') : null,
      }
    }, OMNI)
    check(`${width} ${id}: Message marks the Omnibox, in view`, opened.marked && opened.inView, opened)
    check(`${width} ${id}: a hint names the reader's send key`, opened.hint === SUBMIT[width].hint && opened.role === 'status', opened)
    const line = `DM probe to ${id} at ${width}`
    await p.keyboard.type(line)
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
    await sleep(800)
    const row = await p.evaluate((body) => {
      const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
      const m = ch.messages.find((x) => x.body === body)
      return m ? { to: m.to, to_box: m.to_box || '' } : null
    }, line)
    check(`${width} ${id}: the line goes to ${peer}`, Boolean(row && row.to === id && (!row.to_box || row.to_box === 'box-a')), row)
    check(`${width} ${id}: the button is gone once the DM has a line`, (await startButton(p)) === null)
  }

  for (const theme of ['dark', 'light']) await channelStart(p, width, theme)

  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${width}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 390]) await run(browser, server.base, w)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ndm-start-message: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
