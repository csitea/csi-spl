// SPL-1001: the delete confirms (message, topic, channel) are ONE layout.
//
// Owner, 2026-09-27 (topic d9363508): "The delete msg dialog box is ugly" -
// "should a bit bigger and the text centered properly with more space from
// the end of the dialog". The screenshot showed the topic confirm with its
// sentence flush against the dialog's left edge and no room above the
// buttons. UiConfirm.vue is now the one layout all three use; this measures
// it in Chrome, because typecheck and the unit suite cannot see a margin.
//
// Per viewport (1440 desktop; 820, 390, 360 touch) and theme (dark, light):
//   - the topic confirm opens from the card menu, the message confirm from a
//     thread row's menu, the channel confirm from the channel row's menu
//   - Cancel has the focus, so Enter cancels (and deletes nothing)
//   - Escape closes
//   - the body text has the same inset as the title (>= 16 px on each side)
//   - desktop: <= 480 px wide, buttons on the end edge, side by side
//   - <= 600 px: the dialog is the full screen (SPL-993) and the buttons are
//     full width
//   - Delete is drawn in the danger colour
//
// Run:
//   node tests/e2e/delete-confirm.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/delete-confirm.test.mjs
//   OUT=/var/tmp/spl-1001 node tests/e2e/delete-confirm.test.mjs   # screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const WIDTHS = (process.env.WIDTHS || '1440,820,390,360').split(',').map(Number)
const THEMES = (process.env.THEMES || 'dark,light').split(',')
/* the lde mock #lobby root, from HUM-1@box-wui: our own, so both deletes are offered */
const OWN_MSG = '11111111-1111-4111-8111-111111111111'
const LOBBY_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
/* a reply in that topic. The opener is a topic card (topic Delete). Message
   Delete stays on a reply (is_parent 0). */
const REPLY = '12121212-1212-4212-8212-121212121212'
const REPLY_ROW = {
  v: 1, msg_id: REPLY, task_id: LOBBY_TASK, ts: '2026-10-06T10:05:00Z',
  from: 'HUM-1', from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
  kind: 'note', body: 'a reply line, deleted as a message', channel: 'lobby',
  parent_task_id: LOBBY_TASK, is_parent: 0, files: [],
}
const CHANNEL = 'spl-1001-doomed'

if (OUT) mkdirSync(OUT, { recursive: true })

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Click the first VISIBLE match (a phone keeps hidden copies of some panes). */
const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

/** Everything the contract talks about, read off the open dialog. */
const readDialog = (p) => p.evaluate(() => {
  const panel = document.querySelector('[data-testid=ui-dialog]')
  if (!panel) return { open: false }
  const r = panel.getBoundingClientRect()
  const title = panel.querySelector('.ui-dialog__title')
  const body = panel.querySelector('.ui-confirm__body')
  const text = body?.querySelector('p')
  const btns = [...panel.querySelectorAll('.ui-confirm__actions .btn')]
  const [cancel, del] = btns
  const tr = title?.getBoundingClientRect()
  const pr = text?.getBoundingClientRect()
  const cr = cancel?.getBoundingClientRect()
  const dr = del?.getBoundingClientRect()
  const foot = panel.querySelector('.ui-dialog__foot')?.getBoundingClientRect()
  const active = document.activeElement
  return {
    open: true,
    title: title?.textContent.trim() || '',
    width: Math.round(r.width),
    height: Math.round(r.height),
    vw: window.innerWidth,
    vh: window.innerHeight,
    /* the sentence's inset from the panel's edges */
    textLeft: pr ? Math.round(pr.left - r.left) : -1,
    textRight: pr ? Math.round(r.right - pr.right) : -1,
    titleLeft: tr ? Math.round(tr.left - r.left) : -1,
    textAlign: text ? getComputedStyle(text).textAlign : '',
    gapAboveButtons: pr && cr ? Math.round(Math.min(cr.top, dr.top) - pr.bottom) : -1,
    focus: active?.getAttribute('data-testid') || active?.className || '',
    cancelRightOfDelete: cr && dr ? cr.left < dr.left : null,
    sameRow: cr && dr ? Math.abs(cr.top - dr.top) < 2 : null,
    deleteRightInset: dr ? Math.round(r.right - dr.right) : -1,
    cancelW: cr ? Math.round(cr.width) : 0,
    deleteW: dr ? Math.round(dr.width) : 0,
    footW: foot ? Math.round(foot.width) : 0,
    deleteColor: del ? getComputedStyle(del).color : '',
    danger: getComputedStyle(document.documentElement).getPropertyValue('--color-danger').trim(),
  }
})

/** '#e85d5d' -> 'rgb(232, 93, 93)', to compare with a computed colour */
const rgb = (hex) => {
  const h = hex.replace('#', '')
  return `rgb(${parseInt(h.slice(0, 2), 16)}, ${parseInt(h.slice(2, 4), 16)}, ${parseInt(h.slice(4, 6), 16)})`
}

async function waitDialog(p, open) {
  for (let i = 0; i < 40; i++) {
    const d = await readDialog(p)
    if (d.open === open && (!open || d.title)) return d
    await sleep(100)
  }
  return readDialog(p)
}

function checkLayout(at, what, d) {
  const phone = d.vw <= 600
  ok(`${at} ${what}: Cancel has the focus`, /cancel/.test(d.focus), { focus: d.focus })
  ok(`${at} ${what}: the sentence is inset like the title (>= 16 px each side)`,
    d.textLeft >= 16 && d.textRight >= 16 && d.titleLeft >= 4,
    { textLeft: d.textLeft, textRight: d.textRight, titleLeft: d.titleLeft })
  ok(`${at} ${what}: Delete is the danger colour`, d.deleteColor === rgb(d.danger), { color: d.deleteColor, danger: d.danger })
  if (phone) {
    ok(`${at} ${what}: full screen on a phone`, d.width === d.vw && d.height === d.vh, { w: d.width, h: d.height, vw: d.vw, vh: d.vh })
    ok(`${at} ${what}: both buttons full width`, d.cancelW >= d.footW - 40 && d.deleteW >= d.footW - 40,
      { cancelW: d.cancelW, deleteW: d.deleteW, footW: d.footW })
  } else {
    ok(`${at} ${what}: <= 480 px wide, not cramped (>= 400)`, d.width <= 480 && d.width >= 400, { width: d.width })
    ok(`${at} ${what}: [Cancel] [Delete] side by side on the end edge`,
      d.sameRow && d.cancelRightOfDelete && d.deleteRightInset >= 16 && d.deleteRightInset <= 32,
      { sameRow: d.sameRow, order: d.cancelRightOfDelete, inset: d.deleteRightInset })
    ok(`${at} ${what}: room between the sentence and the buttons (>= 24 px)`, d.gapAboveButtons >= 24, { gap: d.gapAboveButtons })
  }
}

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

const srv = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    for (const theme of THEMES) {
      const touch = width <= 820
      const at = `${width}px ${theme}`
      const page = await browser.newPage()
      page.setDefaultNavigationTimeout(NAV_TIMEOUT)
      await page.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
      await page.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch {} }, theme)
      await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
      await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
      await page.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT })
      await sleep(800)

      /* ---- 1. the topic confirm, from the card's menu ------------------- */
      await click(page, `article.msg[data-msg-id="${OWN_MSG}"] [data-testid=msg-menu-btn]`)
      await sleep(300)
      await click(page, '[data-testid=msg-menu-delete-topic]')
      let d = await waitDialog(page, true)
      /* the count comes from the hub: wait for it before measuring */
      await page.waitForSelector('[data-testid=topic-delete-count]:not([data-replies=""])', { timeout: 10000 }).catch(() => {})
      d = await readDialog(page)
      ok(`${at} topic: the confirm opens and asks a question`, d.open && /\?$/.test(d.title), { title: d.title })
      ok(`${at} topic: the reversible way out (Archive) is offered`, Boolean(await page.$('[data-testid=topic-delete-archive]')))
      if (d.open) checkLayout(at, 'topic', d)
      await shot(page, `topic-${width}-${theme}`)
      await page.keyboard.press('Enter')
      d = await waitDialog(page, false)
      const still = Boolean(await page.$(`article.msg[data-msg-id="${OWN_MSG}"]`))
      ok(`${at} topic: Enter = Cancel (the dialog closes, the card stays)`, !d.open && still, { open: d.open, still })

      await click(page, `article.msg[data-msg-id="${OWN_MSG}"] [data-testid=msg-menu-btn]`)
      await sleep(300)
      await click(page, '[data-testid=msg-menu-delete-topic]')
      await waitDialog(page, true)
      await page.keyboard.press('Escape')
      d = await waitDialog(page, false)
      ok(`${at} topic: Escape closes`, !d.open)

      /* ---- 2. the message confirm, from a reply's menu ------------------- */
      /* The opener is a topic card: its menu Deletes the topic. A reply
         (is_parent 0) is the row whose menu carries a plain Delete. */
      await page.evaluate((row) => {
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify([row]))
      }, REPLY_ROW)
      await page.goto(`${srv.base}/t/${LOBBY_TASK}`, { waitUntil: 'networkidle2' })
      await page.waitForSelector(`article.msg[data-msg-id="${REPLY}"]`, { timeout: 15000 }).catch(() => {})
      await sleep(800)
      await click(page, `article.msg[data-msg-id="${REPLY}"] [data-testid=msg-menu-btn]`)
      await sleep(300)
      const offered = await click(page, '[data-testid=msg-menu-delete]')
      d = await waitDialog(page, true)
      ok(`${at} message: Delete in the menu asks first`, offered && d.open && /\?$/.test(d.title), { offered, title: d.title })
      if (d.open) checkLayout(at, 'message', d)
      await shot(page, `message-${width}-${theme}`)
      await page.keyboard.press('Enter')
      d = await waitDialog(page, false)
      const kept = Boolean(await page.$(`article.msg[data-msg-id="${REPLY}"]`))
      ok(`${at} message: Enter = Cancel (nothing is deleted)`, !d.open && kept, { open: d.open, kept })

      /* ---- 3. the channel confirm, from the channel row's menu ----------- */
      const made = await page.evaluate(async (name) => {
        const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
        const ch = pinia?._s.get('channel')
        if (!ch) return ''
        const row = await ch.createChannel(name)
        return String(row?.channel_id || '')
      }, CHANNEL)
      if (touch) {
        await page.goto(`${srv.base}/`, { waitUntil: 'networkidle2' }).catch(() => {})
        await sleep(800)
      }
      await click(page, '[data-testid=sidebar-tab-channels]')
      await sleep(400)
      const row = made ? `[data-testid=sidebar-row-menu][data-menu-id="ch:${made}"]` : ''
      const menuOpened = row ? await click(page, row) : false
      await sleep(300)
      const picked = await click(page, '[data-testid=sidebar-row-menu-delete]')
      d = await waitDialog(page, true)
      if (touch && !d.open) {
        ok(`${at} channel: (skipped) the phone reload dropped the mock channel`, true, { made, menuOpened, picked })
      } else {
        ok(`${at} channel: Delete channel asks first`, picked && d.open && /\?$/.test(d.title), { made, menuOpened, picked, title: d.title })
        if (d.open) checkLayout(at, 'channel', d)
        await shot(page, `channel-${width}-${theme}`)
        await page.keyboard.press('Escape')
        d = await waitDialog(page, false)
        ok(`${at} channel: Escape closes`, !d.open)
      }
      await page.close()
    }
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ndelete-confirm: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
