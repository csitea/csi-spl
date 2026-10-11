// Spec 062 (owner, t1 25826b7b): the Flow lists only what concerns me (Mine,
// the default), with a Facebook-like number on the Flow tab, proved in a REAL
// browser against the mock bundle. The mock derives HUM-1's flow from its feed
// (one DM to HUM-1, 7a7a...); in live mode the hub counts (FR-008).
//
//   - before the pane opens, the Flow tab shows the number 1 and the title "(1) ..."
//   - opening the Flow clears the number (Q4) and lists Mine: only 7a7a...;
//     the title stays "(1) ..." (spec 079: it sums the unread rows, not Flow)
//   - the chips: DM 1, mention / reply 0 (dimmed, no filter); the DM chip filters
//   - spec 130 Q2 (owner t1 da98036e): no Mine/All switch, the Flow is always Mine
//   - 1440x900 and 390x844 (the phone's level-1 strip carries the number too)
//   - spec 130 L2a: the Flow shows folded lines - one per topic per UTC day
//     and one per UTC day of releases; the summary is 1 line at 1440 and at
//     most 3 at 390 (clamped, an ellipsis beyond); a line's menu (right-click,
//     a long press) is what it points to; the message keys work on a line
//     (owner t1 1cde1dd4); opening a line marks all of it read (t: mark)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e flow-mine
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MINE = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const COUNT = '[data-testid=sidebar-tab-flow-count]'
/* spec 130: the mock's DM topic (its card 7777..., the reply 7a7a... is its newest event) and its releases */
const DM_TOPIC = '77777777-7777-4777-8777-777777777777'
const REL_SHA = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c'
const TOPIC_LINE = `${LIST} [data-testid=left-entry][data-type=dm]`
const REL_LINE = `${LIST} [data-testid=left-entry][data-type=release]`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

function facts(page) {
  return page.evaluate((list, count) => {
    const rows = [...document.querySelectorAll(list + ' [data-testid=left-entry]')]
    const chip = (k) => {
      const el = document.querySelector(`[data-testid=flow-chip-${k}]`)
      return el ? { n: Number(el.getAttribute('data-count')), pressed: el.getAttribute('aria-pressed') } : null
    }
    const c = document.querySelector(count)
    /* owner (t1 f4e6c677): a badge's fill, against the theme's grey and its danger red */
    const fill = (css) => {
      const probe = document.createElement('span')
      probe.style.background = css
      document.body.appendChild(probe)
      const bg = getComputedStyle(probe).backgroundColor
      probe.remove()
      return bg
    }
    const rail = (id) => document.querySelector(`[data-testid=sidebar-tab-${id}-count]`)?.textContent.trim() || ''
    return {
      fill: c ? getComputedStyle(c).backgroundColor : '',
      grey: fill('var(--color-bg-3)'),
      red: fill('var(--color-danger)'),
      dmFill: document.querySelector('[data-testid=sidebar-tab-dm-count]') ? getComputedStyle(document.querySelector('[data-testid=sidebar-tab-dm-count]')).backgroundColor : '',
      rail: { dm: rail('dm'), channels: rail('channels'), channelsPip: Boolean(document.querySelector('[data-testid=sidebar-tab-channels-unread]')) },
      ids: rows.filter((e) => e.getAttribute('data-type') !== 'release').map((e) => e.getAttribute('data-msg-id')),
      count: c ? c.textContent.trim() : '',
      title: document.title,
      switches: document.querySelectorAll('[data-testid^=flow-scope-], [data-testid=flow-head] [role=radiogroup]').length,
      chips: { mention: chip('mention'), reply: chip('reply'), dm: chip('dm') },
    }
  }, LIST, COUNT)
}

/* spec 130 FR-001: every summary box against its line height; a long text shows the clamp is live */
function clampFacts(page, lines) {
  return page.evaluate((list, lines) => {
    const boxes = [...document.querySelectorAll(list + ' [data-testid=left-entry] .side-hit__text')]
    const one = (el) => {
      const cs = getComputedStyle(el)
      const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.35
      return { lines: Math.round(el.clientHeight / lh), clamp: cs.webkitLineClamp || cs.getPropertyValue('-webkit-line-clamp') }
    }
    const before = boxes.map(one)
    /* a long summary in the first box: the clamp holds it to `lines`, the rest overflows */
    const el = boxes[0]
    let live = null
    if (el) {
      const keep = el.textContent
      el.textContent = 'Flow v2 line '.repeat(60)
      const f = one(el)
      live = { ...f, overflow: el.scrollHeight > el.clientHeight, ellipsis: getComputedStyle(el).textOverflow }
      el.textContent = keep
    }
    return { n: boxes.length, before, live, want: lines }
  }, LIST, lines)
}

/* a one-finger long press on the phone (CDP touch, the swipe suites' way) */
async function longPress(p, sel) {
  const box = await p.$eval(sel, (el) => { const b = el.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + Math.min(20, b.height / 2) } })
  const cdp = await p.target().createCDPSession()
  const at = [{ x: Math.round(box.x), y: Math.round(box.y), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at })
  await sleep(900)
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
}

async function rightClick(p, sel) {
  return p.$eval(sel, (el) => {
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window, clientX: Math.round(r.left + 20), clientY: Math.round(r.top + 10), button: 2, buttons: 2 }))
  })
}

const menuIds = (p) => p.$$eval('[data-testid=flow-menu] [role=menuitem]', (els) => els.map((e) => [String(e.getAttribute('data-testid') || '').replace(/^flow-menu-/, ''), e.getAttribute('aria-keyshortcuts') || '']))
async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-testid=flow-menu]'), { timeout: 3000 }).catch(() => {})
}
async function shiftKey(p, letter) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('Key' + letter)
  await p.keyboard.up('Shift')
}

/** Spec 130 L2a: the folded lines, their clamp, their menu and keys, and the open that marks them read. */
async function foldedLines(p, size, tag) {
  const phone = size.width < 821
  const lineFacts = await p.evaluate((topic, rel) => {
    const t = document.querySelector(topic)
    const r = document.querySelector(rel)
    const text = (el) => (el ? el.querySelector('.side-hit__text')?.textContent.trim() || '' : '')
    return { topic: Boolean(t), topicText: text(t), rel: Boolean(r), relText: text(r), unread: Boolean(t && t.querySelector('[data-testid=left-entry-unread]')) }
  }, TOPIC_LINE, REL_LINE)
  ok(`${tag}: the DM topic folds into one line naming its title (spec 130 section 2.1)`, lineFacts.topic && /Direct ping/.test(lineFacts.topicText), lineFacts)
  ok(`${tag}: the day's releases fold into one release line with the version span`, lineFacts.rel && lineFacts.relText === 'v1.3.400 .. v1.3.402 (3 versions)', lineFacts)

  const c = await clampFacts(p, phone ? 3 : 1)
  ok(`${tag}: every Flow summary box is ${phone ? 'at most 3 lines' : '1 line'} high`, c.n >= 2 && c.before.every((b) => (phone ? b.lines <= 3 : b.lines === 1)), c)
  ok(`${tag}: the clamp is live: a long summary stays ${phone ? 3 : 1} line(s) and overflows (ellipsis)`, Boolean(c.live && c.live.lines === (phone ? 3 : 1) && c.live.overflow && String(c.live.clamp) === String(phone ? 3 : 1)), c.live)

  if (!phone) {
    /* owner t1 1cde1dd4 f4b6977e: a line's menu is what it points to; the entries show their message key */
    await rightClick(p, TOPIC_LINE)
    await p.waitForSelector('[data-testid=flow-menu]', { visible: true, timeout: 5000 }).catch(() => {})
    const topicMenu = Object.fromEntries(await menuIds(p).catch(() => []))
    ok(`${tag}: a topic line's menu: Open discussion (Shift+O), Copy link (Shift+L), Copy text (Shift+C), Mark read; no release log`,
      topicMenu.open === 'Shift+O' && topicMenu.copy === 'Shift+L' && topicMenu['copy-text'] === 'Shift+C' && 'read' in topicMenu && !('release' in topicMenu), topicMenu)
    await closeMenu(p)
    await rightClick(p, REL_LINE)
    await p.waitForSelector('[data-testid=flow-menu]', { visible: true, timeout: 5000 }).catch(() => {})
    const relMenu = Object.fromEntries(await menuIds(p).catch(() => []))
    ok(`${tag}: a release line's menu: Open release log (Shift+O), Copy link; no discussion, no AI actions`,
      relMenu.release === 'Shift+O' && 'copy' in relMenu && !('open' in relMenu) && !Object.keys(relMenu).some((k) => k.startsWith('ai-')), relMenu)
    await closeMenu(p)

    /* the message keys on the selected line (owner t1 1cde1dd4 f9300a98) */
    await p.evaluate(() => { window.__copied = []; try { navigator.clipboard.writeText = async (t) => { window.__copied.push(String(t)) } } catch { /* read-only */ } })
    /* select without opening: an open would mark the line read before the Mark read check below */
    await p.$eval(LIST, (el) => el.focus())
    const topicKey = await p.$eval(TOPIC_LINE, (el) => el.getAttribute('data-key'))
    await p.evaluate((key) => { const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia; pinia._s.get('flow').select(key) }, topicKey)
    await sleep(100)
    await shiftKey(p, 'L')
    await sleep(300)
    const copied = await p.evaluate(() => window.__copied)
    ok(`${tag}: Shift+L on the selected line copies its link (/t/<topic>#<newest msg>)`, copied.some((u) => u.includes('/t/' + DM_TOPIC + '#' + MINE)), copied)
    await shiftKey(p, 'R')
    const rMenu = await p.waitForSelector('[data-testid=flow-menu]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
    ok(`${tag}: Shift+R opens the selected line's menu`, rMenu)
    await closeMenu(p)
    await p.keyboard.down('Shift')
    await p.keyboard.press('Slash')
    await p.keyboard.up('Shift')
    const help = await p.waitForSelector('[data-testid=flow-shortcuts-help]', { visible: true, timeout: 3000 }).then(Boolean, () => false)
    ok(`${tag}: Shift+? lists the Flow line keys`, help)
    await p.keyboard.press('Escape')
    await sleep(300)
  } else {
    await longPress(p, TOPIC_LINE)
    const sheet = await p.waitForSelector('[data-testid=flow-menu]', { visible: true, timeout: 5000 }).then(Boolean, () => false)
    const ids = sheet ? (await menuIds(p)).map(([id]) => id) : []
    ok(`${tag}: a long press opens the line's menu (Open discussion, Copy link, Mark read)`, sheet && ['open', 'copy', 'read'].every((k) => ids.includes(k)), ids)
  }

  /* spec 130 FR-009: opening the line writes t:<task_id>: the DM chip and the dot go
     (the phone picks Mark read in the sheet the long press opened) */
  const before = await p.$eval('[data-testid=flow-chip-dm]', (el) => Number(el.getAttribute('data-count'))).catch(() => -1)
  if (!phone) await rightClick(p, TOPIC_LINE)
  const readShown = await p.waitForSelector('[data-testid=flow-menu-read]', { visible: true, timeout: 5000 }).then(() => true, () => false)
  await sleep(300)
  const readClicked = await p.click('[data-testid=flow-menu-read]').then(() => true, (e) => String(e).slice(0, 120))
  await p.waitForFunction(() => document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('data-count') === '0', { timeout: 5000 }).catch(() => {})
  const after = await p.evaluate((topic) => ({
    chip: Number(document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('data-count')),
    dot: Boolean(document.querySelector(topic + ' [data-testid=left-entry-unread]')),
  }), TOPIC_LINE)
  ok(`${tag}: Mark read clears the whole line (t:<topic> mark): its dot goes, the DM chip ${before} -> 0`, before === 1 && after.chip === 0 && !after.dot, { before, ...after, readShown, readClicked })

  if (!phone) {
    /* Shift+O on a release line opens its release log */
    const relKey = await p.$eval(REL_LINE, (el) => el.getAttribute('data-key'))
    await p.evaluate((key) => { const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia; pinia._s.get('flow').select(key) }, relKey)
    await p.$eval(LIST, (el) => el.focus())
    await shiftKey(p, 'O')
    const onRel = await p.waitForFunction((sha) => location.pathname.endsWith('/releases/' + sha), { timeout: 8000 }, REL_SHA).then(() => true, () => false)
    ok(`${tag}: Shift+O on the release line opens /releases/<sha>`, onRel, await p.evaluate(() => location.pathname))
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
    await setPageViewport(p, size)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.evaluate(() => { try { localStorage.removeItem('spool.flow-scope') } catch { /* none */ } })
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)

    /* FR-005: the number before the pane opens */
    const shown = await p.waitForSelector(COUNT, { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
    let f = await facts(p)
    ok(`${tag}: the Flow tab shows the hub's number before the pane opens`, shown && f.count === '1', { count: f.count })
    ok(`${tag}: the tab title leads with it (FR-013)`, f.title.startsWith('(1) '), { title: f.title })
    ok(`${tag}: the Flow number is the theme grey, not the red (t1 f4e6c677)`, f.fill === f.grey && f.fill !== f.red, { fill: f.fill, grey: f.grey, red: f.red })
    ok(`${tag}: Direct messages carries the red number of my new DMs`, f.rail.dm === '1' && f.dmFill === f.red, { rail: f.rail, dmFill: f.dmFill })
    ok(`${tag}: Channels shows no number (nothing new in my discussions) and no pip`, f.rail.channels === '' && !f.rail.channelsPip, f.rail)

    /* Q4: opening the pane clears it; Mine (Q1 default) lists only my event */
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForSelector(`${LIST} [data-testid=left-entry][data-msg-id="${MINE}"]`, { visible: true, timeout: NAV_TIMEOUT })
    await p.waitForFunction((c) => !document.querySelector(c), { timeout: 5000 }, COUNT).catch(() => {})
    f = await facts(p)
    ok(`${tag}: no Mine/All switch (spec 130 Q2)`, f.switches === 0, { switches: f.switches })
    ok(`${tag}: Mine lists only what concerns me`, f.ids.length === 1 && f.ids[0] === MINE, f.ids)
    ok(`${tag}: opening the Flow clears the number`, f.count === '', { count: f.count })
    /* spec 079 FR-006 (Q1, Q4): the title is the sum of the unread rows, not the
       Flow number, so the still-unread DM keeps it at (1) */
    ok(`${tag}: opening the Flow keeps the title on the unread DM row`, f.title.startsWith('(1) '), { title: f.title })
    ok(`${tag}: opening the Flow keeps the DM number (it counts unread, not unseen)`, f.rail.dm === '1', f.rail)
    ok(`${tag}: the chips split the unread (DM 1, mention 0, reply 0)`, f.chips.dm?.n === 1 && f.chips.mention?.n === 0 && f.chips.reply?.n === 0, f.chips)

    /* a 0 chip does not filter; the DM chip does, and a second click clears it */
    await p.click('[data-testid=flow-chip-mention]')
    f = await facts(p)
    ok(`${tag}: a 0 chip does not filter`, f.chips.mention?.pressed === 'false' && f.ids.length === 1, f.chips.mention)
    await p.click('[data-testid=flow-chip-dm]')
    await p.waitForFunction(() => document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('aria-pressed') === 'true', { timeout: 5000 }).catch(() => {})
    f = await facts(p)
    ok(`${tag}: the DM chip filters to DMs`, f.chips.dm?.pressed === 'true' && f.ids.length === 1 && f.ids[0] === MINE, { ids: f.ids, dm: f.chips.dm })
    await p.click('[data-testid=flow-chip-dm]')
    await p.waitForFunction(() => document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('aria-pressed') === 'false', { timeout: 5000 }).catch(() => {})
    f = await facts(p)
    ok(`${tag}: the DM chip again shows every kind`, f.chips.dm?.pressed === 'false' && f.ids.length === 1, f.chips.dm)

    await foldedLines(p, size, tag)

    ok(`${tag}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
