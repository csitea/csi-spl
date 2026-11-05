// SPL-4853 (HUM-10, t1 9bba75f1): on a /t/<uuid> topic page "Open in channels
// view" went to #lobby, and the topic's last message had no right-click menu.
// The owner: "from this link I cannot run the "open in channels view"" and
// "it goes to the lobby - and the last msg does not have "a right click menu"".
//
// Against the mock bundle, at 1440 and 390 px: /t/ffff... is the mock #alerts
// topic, one message (its opening card 6666...), the shape of the prd topic.
// Checks: (1) the last message of the topic opens the card menu (a right
// click; a long press on the phone); (2) its "Open in channels view" lands on
// /channel/alerts, never on #lobby or the front door; (3) the card is there,
// selected: an opening card's jump stops at the topic level (HUM-10, topic
// c15b557e, utils/parent-section-open.mjs). CONTROL: before the jump the
// page is /t/<topic> with its thread.
//
//   pnpm run test:e2e topic-page-open-in-channels
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-page-open-in-channels
//   SHOT_DIR=/tmp/shots ...                          (keep the screenshots)
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the mock tenant (utils/mock-data.mjs): the #alerts topic and its one card */
const TOPIC = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
const CARD = '66666666-6666-4666-8666-666666666666'
const CHANNEL = 'alerts'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const THREAD_CARD = `aside.live-pane article.msg[data-msg-id="${CARD}"]`

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

function facts(p) {
  return p.evaluate((card) => {
    const u = new URL(location.href)
    return {
      path: decodeURIComponent(u.pathname),
      topic: u.searchParams.get('topic'),
      pane: Boolean(document.querySelector(`aside.live-pane article.msg[data-msg-id="${card}"]`)),
      cardFocused: document.activeElement === document.querySelector(`.spool-main article.msg[data-msg-id="${card}"]`),
      menu: Boolean(document.querySelector('[data-testid=msg-menu]')),
      activeChannel: document.querySelector('[data-testid=sidebar-panel-channels] .nav-item.active')?.getAttribute('data-key') || null,
    }
  }, CARD)
}

/** Open the card's menu the way a reader does: a right click, or a long press
    on a phone (on the avatar: a press on the body's text selects it, HUM-10). */
async function openMenu(p, phone) {
  const box = await (await p.$(THREAD_CARD + (phone ? ' .avatar' : ' .msg-body'))).boundingBox()
  const x = box.x + Math.min(20, box.width / 2)
  const y = box.y + box.height / 2
  if (phone) {
    await p.touchscreen.touchStart(x, y)
    await sleep(900)
    await p.touchscreen.touchEnd()
  } else {
    await p.mouse.click(x, y, { button: 'right' })
  }
  return p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 }).then(() => true, () => false)
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const phone = size.width <= 820
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
    await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
    await setPageViewport(p, size)
    /* warm the dev server's dynamic imports (a cold nuxi dev drops the first one) */
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.goto(server.base + '/t/' + TOPIC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.waitForSelector(THREAD_CARD, { visible: true, timeout: NAV_TIMEOUT })
    await sleep(500)
    let f = await facts(p)
    ok(`${tag}: CONTROL - the page is /t/<topic> with its thread`, f.path.endsWith('/t/' + TOPIC) && f.pane, f)

    const opened = await openMenu(p, phone)
    ok(`${tag}: 1 the topic's last message opens its menu`, opened, await facts(p))
    const label = opened ? await p.$eval('[data-testid=msg-menu-parent]', (el) => el.textContent.trim()).catch(() => '') : ''
    ok(`${tag}: the menu reads "Open in channels view"`, label === 'Open in channels view', { label })
    if (label) {
      await p.click('[data-testid=msg-menu-parent]')
      await p.waitForFunction((c) => location.pathname.endsWith('/channel/' + c), { timeout: 10000 }, CHANNEL).catch(() => null)
      await sleep(1500)
      f = await facts(p)
    }
    ok(`${tag}: 2 it lands on /channel/${CHANNEL}, not #lobby`, Boolean(label) && f.path.endsWith('/channel/' + CHANNEL) && (phone || f.activeChannel === CHANNEL), f)
    ok(`${tag}: 3 its card is selected there`, Boolean(label) && f.path.endsWith('/channel/' + CHANNEL) && f.cardFocused, f)

    /* the thread's X on /t still leaves for the front door (the page's own close) */
    if (!phone) {
      await p.goto(server.base + '/t/' + TOPIC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector(THREAD_CARD, { visible: true, timeout: NAV_TIMEOUT })
      await p.click('[data-test=topic-pane-close]')
      await p.waitForFunction(() => !location.pathname.includes('/t/'), { timeout: 10000 }).catch(() => null)
      f = await facts(p)
      ok(`${tag}: 4 the thread's X on /t goes to the front door`, !f.path.includes('/t/'), f)
    }

    if (process.env.SHOT_DIR) {
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `topic-page-open-in-channels-${tag}.png`) })
    }
    const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
    ok(`${tag}: no page errors`, mine.length === 0, mine)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
