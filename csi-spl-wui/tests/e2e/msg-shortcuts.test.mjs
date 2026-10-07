// HUM-10 (t1 topic ae2e5093): Shift + letter acts on the selected message,
// desktop only. Each key runs the same handler as its right-click menu item,
// the menu shows each item's key, Shift + ? lists them, j / k move the
// selection, and Settings -> Behaviour -> Keyboard shortcuts off stops all of it.
//
// Against the lde mock (no hub), a 1280x800 desktop, no touch:
//   - Shift + ? opens msg-shortcuts-help, naming Hide from flow for H
//   - the reply's right-click menu shows "⇧H" (msg-menu-key-hide-flow) and "⇧L"
//   - j / k move the selection between the starter and the reply
//   - Shift + H on the selected reply hides it (the hidden-cards line stands in)
//   - Shift + A on a selected middle card archives it (it leaves, Archived · Undo)
//   - Shift + E in the composer types a capital E and edits nothing
//   - Shift + B on a reply in the topic pane (3rd panel) selects its topic's
//     first message in the centre list (2nd panel), in view; Shift + U goes
//     back to that same reply - in the channel view, the topic view (/t, the
//     topic row) and a direct message (t1 29c3b055, owner "yes , do it that
//     way"). Shift + B on the first message or on a middle card (no topic of
//     its own) does nothing. SHOT_DIR set: 1440 light screenshots of each step
//   - the setting (settings-keyboard-shortcuts) off: Shift + H, Shift + ?
//     and the menu hints do nothing / are gone, Shift + B moves nothing
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/msg-shortcuts.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'ae2e5093-e878-4b8f-bfba-52e153b30a01'
const R1 = 'ae2e5093-e878-4b8f-bfba-52e153b30a02'
const T2 = 'ae2e5093-e878-4b8f-bfba-52e153b30a03'
const R2 = 'ae2e5093-e878-4b8f-bfba-52e153b30a04'
/* a direct-message topic with two replies (t1 29c3b055) */
const DM_PEER = 'CLE-11@box-desk'
const DMT = 'ae2e5093-e878-4b8f-bfba-52e153b30a05'
const DR1 = 'ae2e5093-e878-4b8f-bfba-52e153b30a06'
const DR2 = 'ae2e5093-e878-4b8f-bfba-52e153b30a07'
const dm = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: DMT, ts: `2026-10-04T11:0${min}:00Z`, from: 'CLE-11', from_box: 'box-desk',
  to: 'HUM-1', to_box: 'box-wui', kind: 'note', body, channel: null, parent_task_id: null, is_parent, files: [],
})
const row = (msg_id, task_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id, ts: `2026-10-04T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, TASK, 0, 'shortcuts topic starter', 1),
  row(R1, TASK, 1, 'shortcuts reply one', 0),
  row(T2, T2, 2, 'shortcuts archive me', 1),
  row(R2, TASK, 3, 'shortcuts reply two', 0),
  dm(DMT, 0, 'dm jump topic starter', 1),
  dm(DR1, 1, 'dm jump reply one', 0),
  dm(DR2, 2, 'dm jump reply two', 0),
]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.topic article.msg[data-msg-id="${id}"]`
const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const line = '[data-testid=hidden-cards-line]'
const help = '[data-testid=msg-shortcuts-help]'
const visible = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))
const has = (p, sel) => p.evaluate(visible, sel)
const activeId = (p) => p.evaluate(() => document.activeElement?.closest?.('article.msg')?.getAttribute('data-msg-id') || '')

/** Select a card the way a click does: the row takes the focus (no topic opens for a thread row). */
const select = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.scrollIntoView({ block: 'center' })
  el.focus({ preventScroll: true })
  return document.activeElement === el
}, sel)

async function shiftKey(p, key) {
  await p.keyboard.down('Shift')
  await p.keyboard.press(key)
  await p.keyboard.up('Shift')
}

async function rightClick(p, sel) {
  return p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true, cancelable: true, view: window,
      clientX: Math.round(r.left + r.width / 2),
      clientY: Math.round(r.top + Math.min(20, r.height / 2)),
      button: 2, buttons: 2,
    }))
    return true
  }, sel)
}

async function menuKeys(p, sel) {
  if (!(await rightClick(p, `${sel} .msg-body`))) return null
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 }).catch(() => {})
  await sleep(150)
  const keys = await p.evaluate(() => Object.fromEntries([...document.querySelectorAll('[data-testid=msg-menu] [data-testid^="msg-menu-key-"]')]
    .filter((k) => k.getBoundingClientRect().width > 0)
    .map((k) => [k.getAttribute('data-testid'), getComputedStyle(k, '::after').content.replace(/^"|"$/g, '')])))
  /* the hint is drawn, not text: the entry still reads as the action's name alone */
  const hide = await p.$eval('[data-testid=msg-menu-hide-flow]', (e) => e.textContent.trim()).catch(() => '')
  if (hide) keys['hide-flow-text'] = hide
  await p.keyboard.press('Escape')
  await p.waitForSelector('[data-testid=msg-menu]', { hidden: true, timeout: 5000 }).catch(() => {})
  return keys
}

/** The row is selected (holds the focus) and its pane shows it. */
const selectedInView = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el || document.activeElement !== el) return false
  const a = el.getBoundingClientRect()
  const pane = (el.closest('.feed-body') || document.documentElement).getBoundingClientRect()
  return a.height > 0 && a.bottom > pane.top + 1 && a.top < pane.bottom - 1
}, sel)

const focusedSel = (p) => p.evaluate(() => {
  const a = document.activeElement
  return a?.getAttribute?.('data-msg-id') || a?.getAttribute?.('data-key') || a?.className || ''
})

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  await p.screenshot({ path: `${process.env.SHOT_DIR}/${name}.png` })
}

/** Shift + B from the older reply in the topic pane to the topic's row in the centre list, Shift + U back, and the no-op control, in one view. */
async function jumpRoundTrip(p, view, opener, reply, listRow) {
  const tag = view.replace(/\W+/g, '-')
  ok(`${view}: the reply is selected`, await select(p, card(reply)))
  await shot(p, `${tag}-1-reply-selected`)
  await shiftKey(p, 'B')
  ok(`${view}: Shift + B selects the topic's first message in the 2nd panel (centre list), in view`, await until(p, (s) => {
    const el = document.querySelector(s)
    return Boolean(el && document.activeElement === el)
  }, listRow, 4000) && await selectedInView(p, listRow), await focusedSel(p))
  await shot(p, `${tag}-2-after-shift-b`)
  await shiftKey(p, 'U')
  ok(`${view}: Shift + U goes back to the same reply`, await until(p, (s) => {
    const el = document.querySelector(s)
    return Boolean(el && document.activeElement === el)
  }, card(reply), 4000) && await selectedInView(p, card(reply)), await activeId(p))
  await shot(p, `${tag}-3-after-shift-u`)
  await select(p, card(opener))
  await shiftKey(p, 'B')
  await sleep(300)
  ok(`${view}: Shift + B on the first message does nothing`, (await activeId(p)) === opener, await activeId(p))
}

async function openTopic(p) {
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return p.waitForSelector(card(R1), { visible: true, timeout: 15000 }).then(() => true, () => false)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  /* the mock has no hub: answer the preferences save as the hub would */
  const saved = []
  await p.setRequestInterception(true)
  p.on('request', (r) => {
    if (r.isInterceptResolutionHandled()) return
    if (r.method() === 'PUT' && /\/preferences$/.test(new URL(r.url()).pathname)) {
      saved.push(r.postData() || '')
      return r.respond({ status: 200, contentType: 'application/json', body: '{}' })
    }
    return r.continue()
  })
  await p.evaluateOnNewDocument((extra, light) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      if (light) localStorage.setItem('spool-theme', 'light')
    } catch { /* private mode */ }
  }, EXTRA, Boolean(process.env.SHOT_DIR))
  /* the proof screenshots (SHOT_DIR) are 1440 wide, light */
  await p.setViewport({ width: process.env.SHOT_DIR ? 1440 : 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { try { localStorage.removeItem('spool.hidden-cards') } catch { /* */ } })

  ok('the topic view opens with its starter and reply', await openTopic(p))
  await sleep(400)

  /* ---- Shift + ? : the list ---- */
  ok('the reply is selected', await select(p, card(R1)))
  await shiftKey(p, '?')
  ok('Shift + ? opens msg-shortcuts-help', await until(p, visible, help, 4000))
  const helpH = await p.$eval('[data-testid=msg-shortcuts-help-H]', (e) => e.textContent.trim()).catch(() => '')
  ok('the list names H Hide from flow', helpH === 'Hide from flow', helpH)
  await p.keyboard.press('Escape')
  ok('Esc closes the list', await until(p, (s) => !document.querySelector(s), help, 4000))

  /* ---- the menu shows each item's key ---- */
  const keys = await menuKeys(p, card(R1))
  ok('the reply menu shows ⇧H on Hide from flow and ⇧L on Copy link', keys && keys['msg-menu-key-hide-flow'] === '⇧H' && keys['msg-menu-key-copy'] === '⇧L' && keys['hide-flow-text'] === 'Hide from flow', keys)

  /* ---- j / k move the selection, in the feed's own (DOM) order, as ArrowDown / ArrowUp ---- */
  const order = await p.evaluate(() => [...document.querySelectorAll('.topic [role="feed"] article.msg')].map((e) => e.getAttribute('data-msg-id')))
  const [first, second] = order
  await select(p, card(first))
  await p.keyboard.press('j')
  const afterJ = await activeId(p)
  await p.keyboard.press('k')
  const afterK = await activeId(p)
  ok('j selects the next message, k the previous', order.length >= 2 && afterJ === second && afterK === first, { order, afterJ, afterK })

  /* ---- Shift + B / Shift + U: reply -> first message -> back (t1 29c3b055) ---- */
  await jumpRoundTrip(p, 'channel', TASK, R1, midCard(TASK))
  ok('channel: a middle card is there', await until(p, visible, midCard(T2), 6000))
  await select(p, midCard(T2))
  await shiftKey(p, 'B')
  await sleep(300)
  ok('channel: Shift + B on a middle card (no reply of a topic) does nothing', (await activeId(p)) === T2, await activeId(p))
  await p.goto(`${srv.base}/t/${TASK}`, { waitUntil: 'networkidle2' })
  ok('topic view: the reply is there', await p.waitForSelector(card(R1), { visible: true, timeout: 15000 }).then(() => true, () => false))
  await sleep(400)
  await jumpRoundTrip(p, 'topic view', TASK, R1, `.topic-browse__list a.topic-row[data-key="${TASK}"]`)
  await p.goto(`${srv.base}/dm/${DM_PEER}?topic=${DMT}`, { waitUntil: 'networkidle2' })
  ok('direct message: the reply is there', await p.waitForSelector(card(DR1), { visible: true, timeout: 15000 }).then(() => true, () => false))
  await sleep(400)
  await jumpRoundTrip(p, 'direct message', DMT, DR1, midCard(DMT))
  ok('the topic view opens again', await openTopic(p))
  await sleep(400)

  /* ---- Shift + H hides the selected reply ---- */
  await select(p, card(R1))
  await shiftKey(p, 'H')
  ok('Shift + H hides the selected reply', await until(p, (s) => !document.querySelector(s) || ![...document.querySelectorAll(s)].some((e) => e.getClientRects().length), card(R1), 4000))
  ok('the hidden line stands in its place', await has(p, `.topic ${line}`))
  await p.click(`.topic ${line}`)
  ok('the reply comes back from the line', await until(p, visible, card(R1), 4000))

  /* ---- Shift + E inside the composer only types ---- */
  const typed = await p.evaluate(() => {
    const box = document.querySelector('textarea')
    if (!box) return ''
    box.focus()
    return 'focused'
  })
  if (typed) {
    await shiftKey(p, 'E')
    const val = await p.evaluate(() => document.activeElement?.value ?? '')
    ok('Shift + E in a text field types E and opens no editor', /E$/.test(val) && !(await has(p, '.msg-edit textarea, [data-testid=msg-edit]')), val)
    await p.evaluate(() => { const b = document.activeElement; if (b && 'value' in b) { b.value = ''; b.dispatchEvent(new Event('input', { bubbles: true })) } b?.blur() })
  }

  /* ---- Shift + A archives the selected middle card ---- */
  ok('the middle card to archive is there', await until(p, visible, midCard(T2), 6000))
  ok('the middle card is selected', await select(p, midCard(T2)))
  await shiftKey(p, 'A')
  ok('Shift + A archives it: the card leaves the feed', await until(p, (s) => !document.querySelector(s), midCard(T2), 6000))
  ok('... and Archived · Undo is offered', await until(p, (s) => Boolean(document.querySelector(s)), '[data-testid=archive-toast]', 3000))
  await until(p, (s) => !document.querySelector(s), '[data-testid=archive-toast]', 4000)

  /* ---- the setting off: nothing fires, no hints ---- */
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}&settings=behaviour`, { waitUntil: 'networkidle2' })
  const sw = '[data-testid=settings-keyboard-shortcuts]'
  ok('Settings → Behaviour shows settings-keyboard-shortcuts, on by default', await until(p, (s) => document.querySelector(s)?.checked === true, sw, 10000))
  await p.click(sw)
  ok('clicking it turns it off and saves keyboard_shortcuts false', (await until(p, (s) => document.querySelector(s)?.checked === false, sw, 4000)) && saved.some((b) => /"keyboard_shortcuts":false/.test(b)), saved)
  await p.keyboard.press('Escape')
  await until(p, () => !document.querySelector('[role=dialog][aria-modal=true]'), null, 4000)
  await p.waitForSelector(card(R1), { visible: true, timeout: 10000 }).catch(() => {})
  await select(p, card(R1))
  await shiftKey(p, 'H')
  await sleep(500)
  ok('off: Shift + H hides nothing', (await has(p, card(R1))) && !(await has(p, `.topic ${line}`)))
  await select(p, card(R1))
  await shiftKey(p, 'B')
  await sleep(400)
  ok('off: Shift + B moves nothing', (await activeId(p)) === R1, await activeId(p))
  await shiftKey(p, '?')
  await sleep(400)
  ok('off: Shift + ? opens no list', !(await has(p, help)))
  const offKeys = await menuKeys(p, card(R1))
  ok('off: the menu shows no key hints', offKeys && Object.keys(offKeys).filter((k) => k.startsWith('msg-menu-key-')).length === 0, offKeys)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmsg-shortcuts: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
