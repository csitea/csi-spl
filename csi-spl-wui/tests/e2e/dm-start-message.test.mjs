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
//   marked   SPL-4696 (csitea 597318eb: a member read the caret alone as "the
//            channel is empty, the discussion does not open"; owner HUM-10
//            msg 1bfcbc43: "some effect or animation that shows the user to
//            start typing and where the focus is"): the button, and a Reply's
//            composer-focus event, mark the Omnibox with the one-colour ring
//            and its pulse, in view; under reduced motion the ring holds
//            still. CONTROL: before the fix the button only called focus(),
//            so the form had no .omnibox--called and no outline
//   live     the first line sent there takes the empty state away
//
// SPL-5037 (c-216, msg 07f8dce4: wf 10 run 42338524374 red on two clicks here,
// the same sha green on the next run). The mock bundle's 4 s poll set `loading`,
// which unmounted both empty states for 7..67 ms each beat, and a click in that
// gap threw:
//
//   beat     a start button stays mounted over a poll, and a click after it
//            lands. A remount is too short to hit on demand, so heldBeat holds
//            it open: only if the button was really removed does it keep
//            `loading` up until the click has been tried. CONTROL: before the
//            fix this click threw "No element found" (commit body)
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

/* SPL-2699 / SPL-4696: is the Omnibox marked as called, and in view? */
const marked = (p) => p.evaluate((sel) => {
  const ta = document.querySelector(sel)
  const form = ta ? ta.closest('form') : null
  if (!form) return null
  const cs = getComputedStyle(form)
  const r = form.getBoundingClientRect()
  return {
    focused: document.activeElement === ta,
    called: form.classList.contains('omnibox--called'),
    outline: cs.outlineStyle,
    width: parseFloat(cs.outlineWidth) || 0,
    anim: cs.animationName,
    inView: r.height > 0 && r.top >= 0 && r.bottom <= innerHeight,
  }
}, OMNI)
const pulsed = (m) => Boolean(m && m.focused && m.called && m.outline === 'solid' && m.width > 0 && m.width <= 3 && m.inView)

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

/* SPL-5037: one real poll beat with `sel` on screen; a removal is held open
   until the click has been tried. reads 0 = no poll ran, so the check proves nothing and fails. */
async function heldBeat(p, sel, tag) {
  await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    const w = window.__beat = { reads: 0, removed: false }
    let held = false
    const offAction = store.$onAction(({ name }) => { if (name === 'refresh') w.reads++ })
    const offState = store.$subscribe(() => { if (held && !store.loading) store.loading = true }, { flush: 'sync' })
    const seen = new MutationObserver(() => {
      if (el.isConnected || held) return
      held = true
      w.removed = true
      store.loading = true
    })
    seen.observe(document.body, { subtree: true, childList: true })
    w.release = () => { held = false; seen.disconnect(); offAction(); offState(); store.loading = false }
  }, sel)
  await p.waitForFunction(() => window.__beat.reads > 0, { timeout: 6000 }).catch(() => {})
  await sleep(150)
  const clicked = await p.click(sel).then(() => 'ok', (e) => String(e.message).split('\n')[0])
  const w = await p.evaluate(() => { window.__beat.release(); return { reads: window.__beat.reads, removed: window.__beat.removed } })
  check(`${tag}: its button stays mounted over a poll, and a click lands`, clicked === 'ok' && !w.removed && w.reads > 0, { clicked, ...w })
}

const START = '[data-testid=feed-empty-start]'
const startDisabled = (p) => p.evaluate((sel) => document.querySelector(sel)?.disabled ?? null, START)
const blurAll = (p) => p.evaluate(() => document.activeElement?.blur())
const omniHasCaret = (p) => p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI)

/* SPL-5183: the button follows real focus, however the caret got there */
async function focusFollowed(p, tag) {
  check(`${tag}: its button is disabled once it has put the caret in the Omnibox`, await startDisabled(p) === true)
  await p.click(START)
  await sleep(100)
  check(`${tag}: a click on the disabled button leaves the caret in the Omnibox`, await omniHasCaret(p))
  await p.click('.feed-empty__title')
  await sleep(100)
  check(`${tag}: a click elsewhere enables it again`, await startDisabled(p) === false && !(await omniHasCaret(p)))
  await p.click(OMNI)
  await sleep(100)
  check(`${tag}: a click into the Omnibox disables it, without the button`, await startDisabled(p) === true)
  /* the element replaced under the caret: no blur to rely on, then a new one */
  const swap = await p.evaluate((sel) => {
    const old = document.querySelector(sel)
    const fresh = old.cloneNode()
    old.replaceWith(fresh)
    window.__omniSwap = { old, fresh }
  }, OMNI).then(() => sleep(100)).then(() => startDisabled(p))
  check(`${tag}: the Omnibox replaced under the caret enables it`, swap === false, { swap })
  const refocused = await p.evaluate(() => window.__omniSwap.fresh.focus()).then(() => sleep(100)).then(() => startDisabled(p))
  check(`${tag}: focus in the replacement disables it`, refocused === true, { refocused })
  await p.evaluate(() => { const { old, fresh } = window.__omniSwap; fresh.replaceWith(old); delete window.__omniSwap })
  await sleep(100)
  await blurAll(p)
  await sleep(100)
  check(`${tag}: focus gone with the box put back: enabled`, await startDisabled(p) === false)
}

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
  /* SPL-5183 (owner HUM-10, t1 bb025917 msg b78bf9ad): "Whenever the cursor is
     on the omnibox, the button should be disabled." A click needs it enabled */
  await blurAll(p)
  check(`${tag}: its button is enabled while the caret is elsewhere`, await startDisabled(p) === false)
  if (theme === 'dark') { await heldBeat(p, START, tag); await blurAll(p) }
  /* a mark left by the DM steps clears first, so the one read below is this click's */
  await p.waitForFunction(() => !document.querySelector('form.omnibox--called'), { timeout: 5000 }).catch(() => {})
  await p.click('[data-testid=feed-empty-start]')
  await sleep(200)
  check(`${tag}: its button puts the caret in the Omnibox`, await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI))
  const m = await marked(p)
  check(`${tag}: its button marks the Omnibox with a pulsing ring, in view`, pulsed(m) && m.anim === 'omnibox-called', m)
  await focusFollowed(p, tag)
  /* a Reply (card menu, r shortcut, poll "Chat about this") sends the same event */
  await p.waitForFunction(() => !document.querySelector('form.omnibox--called'), { timeout: 5000 }).catch(() => {})
  await p.evaluate(() => { document.activeElement?.blur(); window.dispatchEvent(new CustomEvent('spool:composer-focus')) })
  await sleep(200)
  const r = await marked(p)
  check(`${tag}: a Reply's composer-focus marks the Omnibox too`, pulsed(r) && r.anim === 'omnibox-called', r)
  if (theme !== 'light') {
    await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
    await blurAll(p)
    await sleep(100)
    await p.click(START)
    await sleep(200)
    const s = await marked(p)
    await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])
    /* motion back on restarts the phone's mobile-panel-in slide (translateX
       24px): let it end, or the next theme's "in view" reads it mid-slide */
    await p.waitForFunction(() => document.getAnimations().every((a) => a.playState !== 'running'), { timeout: 5000 }).catch(() => {})
    check(`${tag}: reduced motion: the ring holds still, no pulse`, pulsed(s) && s.anim === 'none', s)
    return
  }
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
    if (peer === PEERS[0]) await heldBeat(p, '[data-test=dm-start-message]', `${width} ${id}`)
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
