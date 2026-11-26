// Spec 186 row M7 (owner HUM-10, t1 032d8010, msgs 5fdfff6c, 656b2576 and
// 4b3833e7): the multicast flow end to end, select then Multicast, against
// the lde mock (no hub). Rows M3 (the select phase) and M11 (the Multicast
// dialog) on the generated bundle.
//   D  1280x800 desktop: on channel A's page a card's box ticks one topic;
//      on channel B's page Select by title `^release` adds the two topics
//      whose titles start with "release" (not "pre-release"); the bar reads
//      "3 selected in 2 channels"; Multicast opens "Send to 3 topics"; one
//      send puts the card into all three topics with one mc_id; the dialog
//      closes and the selection is empty
//   R  1280x800 desktop: a check that refuses one target keeps Send off with
//      the reason shown; that target's cross removes it, the check runs
//      again and Send is on
//   P  390x844 touch: a thumb held on a topic card opens its menu, whose
//      "Select" ticks the card; taps tick two more; the bar's Multicast opens
//      the full-screen sheet; Send puts the card into the three topics, the
//      sheet closes and the selection is empty; the dock row is still
//      dock-back,attach,send and Attach still opens the OS picker at once
//
// Red control (spec 186 M7): the file fails with the card box, the menu's
// "Select" item, the bar's Multicast button or Select by title removed.
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/multicast-prompt.test.mjs   # what CI does
//   node tests/e2e/multicast-prompt.test.mjs                                 # nuxi dev
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH_A = 's186-mc-a'
const CH_B = 's186-mc-b'
const CH_P = 's186-mc-phone'
/* the mock hub's multicast_check hook (spool-client-mock.mjs, row M11) */
const REFUSE_KEY = 'spool.mock.multicast-refuse'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** fn(arg) in the page until it is truthy, or `ms` runs out. */
async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const shown = (p, sel) => p.evaluate((sel) => [...document.querySelectorAll(sel)].some((e) => e.getClientRects().length), sel)
const mounted = (p) => until(p, () => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia?._s.get('channel')), null, NAV_TIMEOUT)
/** The visible selection bar's count and channel count. */
const bar = (p) => p.evaluate(() => {
  const b = [...document.querySelectorAll('[data-test=topic-select-bar]')].find((e) => e.getClientRects().length)
  return b ? { count: Number(b.getAttribute('data-count')), channels: Number(b.getAttribute('data-channels')), text: b.querySelector('[data-test=topic-select-count]')?.textContent?.trim() || '' } : null
})
/** The visible element `sel`, scrolled into view and settled: its box. */
const boxOf = async (p, sel) => {
  await p.evaluate((sel) => [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)?.scrollIntoView({ block: 'center' }), sel)
  await sleep(300)
  return p.evaluate((sel) => {
    const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
    if (!e) return null
    const r = e.getBoundingClientRect()
    return { x: r.left, y: r.top, w: r.width, h: r.height }
  }, sel)
}
const tapAt = async (p, sel) => {
  const b = await boxOf(p, sel)
  if (b) await p.touchscreen.tap(Math.round(b.x + Math.min(b.w / 2, 30)), Math.round(b.y + b.h / 2))
  return Boolean(b)
}

/** A channel with one own topic per title, in order; their { msg_id, task_id }. */
const seed = (p, ch, titles) => p.evaluate(async ({ ch, titles }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const store = app.config.globalProperties.$pinia._s.get('channel')
  await store.createChannel(ch).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + ch)
  await new Promise((r) => setTimeout(r, 500))
  const out = []
  for (const t of titles) {
    const row = await store.send(t, undefined, undefined, undefined, 1)
    out.push({ msg_id: row.msg_id, task_id: row.task_id })
  }
  store.refresh = async () => {}
  return out
}, { ch, titles })

const signIn = (p) => p.evaluateOnNewDocument(() => {
  try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
})

const toChannel = async (p, ch, first) => {
  await p.evaluate((ch) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/channel/' + ch), ch)
  await p.waitForSelector(card(first), { visible: true, timeout: 10000 })
}

/** The Multicast dialog's facts: title text, target rows, Send's state. */
const dialog = (p) => p.evaluate(() => {
  const d = document.querySelector('[data-test=multicast-dialog]')
  if (!d || !d.getClientRects().length) return null
  const sheet = d.closest('[role=dialog]') || d
  const r = sheet.getBoundingClientRect()
  const send = d.querySelector('[data-test=multicast-composer] [data-testid=send]')
  return {
    title: sheet.textContent.includes('Send to') ? (sheet.querySelector('h1, h2, [data-test=dialog-title], .ui-dialog__title')?.textContent?.trim() || '') : '',
    label: d.querySelector('[data-test=multicast-send-label]')?.textContent?.trim() || '',
    canSend: d.getAttribute('data-can-send') === '1',
    sendOff: Boolean(send && send.getAttribute('aria-disabled') === 'true'),
    targets: [...d.querySelectorAll('[data-test=multicast-target]')].map((t) => ({ task: t.getAttribute('data-task'), ok: t.getAttribute('data-ok') })),
    refused: [...d.querySelectorAll('[data-test=multicast-refused]')].map((e) => e.textContent.trim()),
    rect: { l: Math.round(r.left), t: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) },
  }
})

/** Type `text` into the dialog's own composer. */
async function typeInDialog(p, text) {
  const field = '[data-test=multicast-composer] textarea'
  await p.waitForSelector(field, { visible: true, timeout: 5000 })
  await p.focus(field)
  await p.keyboard.type(text)
  await until(p, (t) => document.querySelector('[data-test=multicast-composer] textarea')?.value === t, text, 3000)
}

/**
 * Each target topic ({ ch, msg_id, task_id }) holds a card with `text`, seen
 * in the open topic's pane, opened from its own channel's page;
 * the copies share one mc_id is the hub's column (7.1.3), so it is not on the
 * card: the e2e reads the topics, the unit test (multicast-send) the frames.
 */
async function copiesIn(p, targets, text) {
  const seen = []
  for (const t of targets) {
    /* a topic opens in its own channel's page */
    await toChannel(p, t.ch, t.msg_id)
    await p.evaluate((id) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').openTopic(id), t.task_id)
    const got = await until(p, ({ text }) => [...document.querySelectorAll('.topic article.msg')].some((e) => e.getClientRects().length && e.textContent.includes(text)), { text }, 8000)
    seen.push(got)
    await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').close?.())
    await sleep(200)
  }
  return seen
}

async function desktop(browser, base) {
  const d = await browser.newPage()
  const errors = []
  d.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  d.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(d)
  await d.setViewport({ width: 1280, height: 800 })
  await d.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(d)
  const [b1, b2, b3] = await seed(d, CH_B, ['release one notes', 'Release two plan', 'pre-release three check'])
  const [a1] = await seed(d, CH_A, ['mc-desk-a topic'])
  await d.waitForSelector(card(a1.msg_id), { visible: true, timeout: 10000 })

  /* D: tick one topic on channel A's page with its box */
  await d.hover(card(a1.msg_id))
  const hit = await d.evaluate((sel) => { const h = document.querySelector(sel)?.getBoundingClientRect(); return h ? { x: h.left + h.width / 2, y: h.top + h.height / 2 } : null }, `${card(a1.msg_id)} [data-test=topic-select-hit]`)
  if (hit) await d.mouse.click(hit.x, hit.y)
  ok('D desktop: the card box on channel A ticks the topic, "1 selected"', await until(d, () => document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count') === '1', null, 4000), { hit, bar: await bar(d) })

  /* D: channel B, Select by title `^release` from the bar */
  await toChannel(d, CH_B, b1.msg_id)
  ok('D desktop: the selection is still there on channel B\'s page', (await bar(d))?.count === 1, await bar(d))
  const byTitle = '[data-test=topic-select-bar] [data-test=topic-select-by-title]'
  const hasByTitle = await shown(d, byTitle)
  if (hasByTitle) await d.click(byTitle)
  ok('D desktop: the bar offers Select by title', hasByTitle && await until(d, () => Boolean(document.querySelector('[data-test=topic-select-patterns-field]')), null, 4000))
  if (hasByTitle) {
    await d.type('[data-test=topic-select-patterns-field]', '^release')
    await d.click('[data-test=topic-select-apply]')
  }
  ok('D desktop: `^release` adds "release one" and "Release two", not "pre-release": the bar reads 3 in 2 channels',
    await until(d, () => { const b = document.querySelector('[data-test=topic-select-bar]'); return b?.getAttribute('data-count') === '3' && b.getAttribute('data-channels') === '2' }, null, 5000), await bar(d))
  const b = await bar(d)
  ok('D desktop: the bar says "3 selected in 2 channels"', /3 selected/.test(b?.text || '') && /in 2 channels/.test(b?.text || ''), b)
  ok('D desktop: "pre-release three check" is not ticked', !(await d.evaluate((sel) => Boolean(document.querySelector(sel)?.classList.contains('msg--ticked')), card(b3.msg_id))))

  /* D: Multicast, "Send to 3 topics", send once */
  const mcBtn = '[data-test=topic-select-bar] [data-test=topic-select-act-multicast]'
  const hasMc = await shown(d, mcBtn)
  if (hasMc) await d.click(mcBtn)
  ok('D desktop: the bar\'s Multicast opens the dialog', hasMc && await until(d, () => Boolean(document.querySelector('[data-test=multicast-dialog]')), null, 4000))
  ok('D desktop: the dialog checks all three and Send is on', await until(d, () => document.querySelector('[data-test=multicast-dialog]')?.getAttribute('data-can-send') === '1', null, 5000), await dialog(d))
  const dd = await dialog(d)
  ok('D desktop: it reads "Send to 3 topics", three targets', Boolean(dd && dd.label === 'Send to 3 topics' && dd.targets.length === 3), dd)
  const text = `mc-desk ${Date.now().toString(36)}`
  let sentDesk = false
  if (dd) {
    await typeInDialog(d, text)
    ok('D desktop: with text typed, Send is on', await until(d, () => document.querySelector('[data-test=multicast-composer] [data-testid=send]')?.getAttribute('aria-disabled') === 'false', null, 3000), await dialog(d))
    await d.click('[data-test=multicast-composer] [data-testid=send]')
    sentDesk = await until(d, () => !document.querySelector('[data-test=multicast-dialog]'), null, 8000)
  }
  ok('D desktop: every copy acked: the dialog closes', sentDesk, await dialog(d))
  ok('D desktop: ... and the selection is empty (no bar)', sentDesk && await until(d, () => !document.querySelector('[data-test=topic-select-bar]'), null, 3000), await bar(d))
  const seen = await copiesIn(d, [{ ...a1, ch: CH_A }, { ...b1, ch: CH_B }, { ...b2, ch: CH_B }], text)
  ok('D desktop: the card is in all three topics', seen.length === 3 && seen.every(Boolean), seen)
  const notIn = await copiesIn(d, [{ ...b3, ch: CH_B }], text)
  ok('D desktop: ... and not in "pre-release three check"', notIn[0] === false, notIn)

  /* R: a refused target keeps Send off with its reason; its cross re-checks and Send is on */
  await toChannel(d, CH_B, b1.msg_id)
  await d.evaluate(({ key, title }) => localStorage.setItem(key, JSON.stringify({ [title]: 'topic_archived' })), { key: REFUSE_KEY, title: 'Release two plan' })
  /* by title, not two box clicks: a mouse click on a second card's box while
     the first one has the focus misses it (reported to the dispatch holder) */
  await d.click('[data-test=feed-header] [data-test=topic-select-by-title]')
  await d.waitForSelector('[data-test=topic-select-patterns-field]', { visible: true, timeout: 4000 })
  await d.type('[data-test=topic-select-patterns-field]', '^release')
  await d.click('[data-test=topic-select-apply]')
  ok('R desktop: `^release` selects "release one notes" and "Release two plan"', await until(d, () => document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count') === '2', null, 4000), await bar(d))
  if (await shown(d, mcBtn)) await d.click(mcBtn)
  const refusedShown = await until(d, () => document.querySelectorAll('[data-test=multicast-refused]').length === 1, null, 5000)
  /* text typed: only the refusal can keep Send off now */
  if (refusedShown) await typeInDialog(d, 'mc-desk refused')
  await sleep(600)
  const rd = await dialog(d)
  ok('R desktop: the check refuses "Release two plan": its reason is shown', refusedShown && Boolean(rd?.refused[0]?.includes('topic_archived')), rd)
  ok('R desktop: ... and with text typed Send stays off', Boolean(rd && !rd.canSend && rd.sendOff), rd)
  if (rd) await d.click(`[data-test=multicast-target][data-task="${b2.task_id}"] [data-test=multicast-remove]`)
  ok('R desktop: removing that target re-runs the check: every target ok, "Send to 1 topics"', await until(d, () => document.querySelector('[data-test=multicast-dialog]')?.getAttribute('data-can-send') === '1', null, 5000)
    && (await dialog(d))?.targets.length === 1 && (await dialog(d))?.label === 'Send to 1 topics', await dialog(d))
  ok('R desktop: ... and Send is on', await until(d, () => document.querySelector('[data-test=multicast-composer] [data-testid=send]')?.getAttribute('aria-disabled') === 'false', null, 3000), await dialog(d))
  await d.evaluate((key) => localStorage.removeItem(key), REFUSE_KEY)
  await d.keyboard.press('Escape')
  await until(d, () => !document.querySelector('[data-test=multicast-dialog]'), null, 3000)
  ok('D+R desktop: no page errors', errors.length === 0, errors)
  await d.close()
}

/** The phone's docked composer row, left to right (dock-buttons.test.mjs's read). */
const dockRow = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.omnibox--global')
  if (!f) return null
  const ids = [...(f.querySelector('.composer-row')?.querySelectorAll('button') || [])]
    .filter((b) => b.getClientRects().length)
    .map((b) => ({ id: b.getAttribute('data-testid'), cx: b.getBoundingClientRect().left }))
    .sort((a, b) => a.cx - b.cx)
    .map((b) => b.id)
  return { docked: f.getAttribute('data-docked') === 'true', ids: ids.join(',') }
})

/** A thumb held still on card `id`'s time for `ms` (phone-longpress-select.test.mjs's hold). */
async function holdOnCard(p, id, ms = 900) {
  const b = await boxOf(p, `${card(id)} .msg-time`)
  if (!b) return false
  const cdp = await p.target().createCDPSession()
  const pt = { x: Math.round(b.x + b.w / 2), y: Math.round(b.y + b.h / 2) }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [pt] })
  await sleep(ms)
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
  await sleep(400)
  return true
}

async function phone(browser, base) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(p)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(p)
  const ts = await seed(p, CH_P, ['mc-phone one', 'mc-phone two', 'mc-phone three'])
  await p.waitForSelector(card(ts[2].msg_id), { visible: true, timeout: 10000 })

  /* P: a held thumb opens the card's menu; its "Select" ticks the card */
  await holdOnCard(p, ts[0].msg_id)
  const menu = await until(p, () => [...document.querySelectorAll('[data-testid=msg-menu]')].some((e) => e.getClientRects().length), null, 3000)
  ok('P 390: a thumb held on a topic card opens its menu', menu)
  const hasSelect = await until(p, () => [...document.querySelectorAll('[data-testid=msg-menu-topic-select]')].some((e) => e.getClientRects().length), null, 3000)
  ok('P 390: the card menu offers "Select"', hasSelect)
  if (hasSelect) await tapAt(p, '[data-testid=msg-menu-topic-select]')
  ok('P 390: "Select" ticks the card; the bar reads 1', await until(p, () => document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count') === '1', null, 4000), await bar(p))

  /* P: two taps tick two more cards */
  for (const t of [ts[1], ts[2]]) {
    await tapAt(p, `${card(t.msg_id)} .msg-para`)
    await sleep(400)
  }
  ok('P 390: two taps tick two more: the bar reads 3', await until(p, () => document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count') === '3', null, 4000), await bar(p))

  /* P: the bar's Multicast opens the full-screen sheet */
  const mcBtn = '[data-test=topic-select-bar] [data-test=topic-select-act-multicast]'
  const hasMc = await shown(p, mcBtn)
  if (hasMc) await tapAt(p, mcBtn)
  const opened = hasMc && await until(p, () => document.querySelector('[data-test=multicast-dialog]')?.getAttribute('data-can-send') === '1', null, 6000)
  const pd = await dialog(p)
  ok('P 390: the bar\'s Multicast opens the sheet, "Send to 3 topics", Send on', Boolean(opened && pd && pd.label === 'Send to 3 topics' && pd.targets.length === 3), pd)
  ok('P 390: the sheet is full-screen (390 x 844, +-2 px)', Boolean(pd && pd.rect.l <= 2 && pd.rect.t <= 2 && pd.rect.w >= 388 && pd.rect.h >= 842), pd?.rect)
  const text = `mc-phone ${Date.now().toString(36)}`
  let sent = false
  if (opened) {
    await typeInDialog(p, text)
    await until(p, () => document.querySelector('[data-test=multicast-dialog]')?.getAttribute('data-can-send') === '1', null, 3000)
    await tapAt(p, '[data-test=multicast-composer] [data-testid=send]')
    sent = await until(p, () => !document.querySelector('[data-test=multicast-dialog]'), null, 8000)
  }
  ok('P 390: Send: every copy acked, the sheet closes and the selection is empty', sent && await until(p, () => !document.querySelector('[data-test=topic-select-bar]'), null, 3000), { dialog: await dialog(p), bar: await bar(p) })
  const seen = await copiesIn(p, ts.map((t) => ({ ...t, ch: CH_P })), text)
  ok('P 390: the card is in all three topics', seen.length === 3 && seen.every(Boolean), seen)

  /* P: the page composer's dock row and Attach are untouched (S1) */
  await toChannel(p, CH_P, ts[0].msg_id)
  await until(p, () => Boolean(document.querySelector('form.composer.omnibox--global [data-testid=dock-back]')), null, 4000)
  const row = await dockRow(p)
  ok('P 390: the dock row is still dock-back,attach,send', Boolean(row && row.docked && row.ids === 'dock-back,attach,send'), row)
  const [chooser] = await Promise.all([
    p.waitForFileChooser({ timeout: 5000 }).catch(() => null),
    p.tap('form.composer.omnibox--global [data-testid=attach]').catch(() => null),
  ])
  if (chooser) await chooser.cancel()
  ok('P 390: Attach still opens the OS picker at once', Boolean(chooser))
  ok('P 390: no page errors', errors.length === 0, errors)
  await p.close()
}

const srv = await startServer()
const browser = await launch()
try {
  await desktop(browser, srv.base)
  await phone(browser, srv.base)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmulticast-prompt: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
