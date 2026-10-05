// Spec 087 T002 (FR-002, AC2): on a phone, Back is one level on every path.
// The spec §3.2 matrix, entry x method x width, one fresh tab per cell:
//
//   entries  tap      the tap path: `/`, Channels, #lobby, a topic (level 3)
//            topic    a fresh tab at level 3 (`/channel/lobby?topic=`)
//            channel  a fresh tab at level 2 (`/channel/lobby`)
//            deep     `/`, then the level-3 deep link
//            login    `/login`, `/`, then the level-3 deep link
//            notify   a notification open (`/m/<msg_id>`, replaces itself)
//            (the resumed place is added by 087 T004)
//   methods  chevron  the header "<" (MobileBack)
//            dock     the dock Back (MessageComposer)
//            edge     a swipe right from x = 8
//            mid      a swipe right from x = 100
//            browser  browser Back (page.goBack)
//            sheet    the avatar sheet open first: browser Back closes it and
//                     the level stays (043 T055), then browser Back walks on
//   widths   360x780, 390x844
//
// A cell passes when every Back moves `data-mobile-level` by exactly one
// (3 -> 2 -> 1), and then browser Back from level 1 (the OS gesture: there is
// no chevron or swipe at level 1) leaves the app with no step showing the
// sign-in page: no `/login` URL, and a MutationObserver that runs from the
// first byte of every document never saw `.login-landing-card`.
//
// Known red, by design (the control): every `login` cell fails today
// (spec §2 row 2: Back from level 1 lands on the stale `/login` entry and
// paints "Signed in as ... Continue"; 087 T003 fixes it). Measured while
// building this file (n = 3, both widths): browser Back from every deep-link
// entry skips levels or leaves the app, because a deep link builds no history
// entries under itself (087 T007). Those cells print KNOWN-RED and do not
// fail the run; a KNOWN_RED cell that PASSES fails it, so the fixing task
// removes its lines in the same commit. KNOWN_RED=strict counts the
// known-red cells as failures (shows the control biting).
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-back-matrix.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
// Narrow: ENTRIES=tap,login METHODS=chevron,browser WIDTHS=360
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'
const SIZES = { 360: 780, 390: 844 }
const ALL_ENTRIES = ['tap', 'topic', 'channel', 'deep', 'login', 'notify']
const ALL_METHODS = ['chevron', 'dock', 'edge', 'mid', 'browser', 'sheet']
const pick = (env, all) => (env ? env.split(',').filter((x) => all.includes(x)) : all)
const ENTRIES = pick(process.env.ENTRIES, ALL_ENTRIES)
const METHODS = pick(process.env.METHODS, ALL_METHODS)
const WIDTHS = (process.env.WIDTHS || '360,390').split(',').map(Number).filter((w) => SIZES[w])
/* The cells red on today's build by design: `entry/method`, `*` for any.
   The task named in each reason removes its line when it lands. */
const KNOWN_RED = {
  'login/*': 'spec 087 §2 row 2: Back from level 1 lands on the stale /login entry; 087 T003',
  'topic/browser': 'a deep link builds no entries under it: browser Back leaves the app; 087 T007',
  'topic/sheet': 'as topic/browser (the sheet column walks with browser Back); 087 T007',
  'channel/browser': 'as topic/browser, from level 2; 087 T007',
  'channel/sheet': 'as channel/browser; 087 T007',
  'deep/browser': 'browser Back from the deep link returns to the `/` document (3 -> 1); 087 T007',
  'deep/sheet': 'as deep/browser; 087 T007',
  'notify/browser': '/m/<id> builds level 2 only: browser Back from it leaves the app; 087 T007',
  'notify/sheet': 'as notify/browser; 087 T007',
}
const knownRed = (entry, method) => KNOWN_RED[`${entry}/${method}`] || KNOWN_RED[`${entry}/*`] || ''
const STRICT = process.env.KNOWN_RED === 'strict'
const MEMBER = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

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

/* Before any app code, on every document of the tab: a signed-in mock member,
   and a watch that records the sign-in page if it is ever painted. */
function boot(member) {
  try { localStorage.setItem('spool.mock.session', JSON.stringify(member)) } catch { /* private mode */ }
  const mark = () => {
    if (!document.querySelector('.login-landing-card')) return
    try { sessionStorage.setItem('e2e.loginPainted', location.pathname) } catch { /* */ }
  }
  new MutationObserver(mark).observe(document, { childList: true, subtree: true })
  mark()
}

const state = (p) => p.evaluate(() => {
  const vis = (s) => [...document.querySelectorAll(s)].some((e) => {
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden' && r.width > 0 && r.height > 0
  })
  let painted = null
  try { painted = sessionStorage.getItem('e2e.loginPainted') } catch { /* */ }
  return {
    level: Number(document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || 0),
    path: location.protocol === 'about:' ? 'about:blank' : location.pathname + location.search,
    login: /(^|\/)login\/?$/.test(location.pathname) || Boolean(document.querySelector('.login-landing-card')),
    painted,
    menu: vis('[data-test=user-menu-panel]'),
  }
}).catch(() => ({ level: 0, path: 'about:blank', login: false, painted: null, menu: false }))

/** Poll until `want(state)` holds, then settle and read again (an overshoot shows). */
async function until(p, want, ms = 4000) {
  const t0 = Date.now()
  let s = await state(p)
  while (!want(s) && Date.now() - t0 < ms) {
    await sleep(100)
    s = await state(p)
  }
  await sleep(350)
  return state(p)
}

const click = (p, sel) => p.evaluate((q) => {
  const e = [...document.querySelectorAll(q)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e || e.disabled) return false
  e.click()
  return true
}, sel)

async function swipe(p, x0) {
  const cdp = await p.target().createCDPSession()
  const t = (type, x) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y: 420 }] })
  await t('touchStart', x0)
  for (let i = 1; i <= 6; i++) { await t('touchMove', x0 + i * 25); await sleep(16) }
  await t('touchEnd', x0 + 150)
  await cdp.detach()
}

const goBack = (p) => p.goBack({ timeout: 8000 }).catch(() => null)

/** One Back by `method`; false when its control is not there to press. */
async function back(p, method) {
  if (method === 'chevron') return click(p, '[data-testid=mobile-back]')
  if (method === 'dock') return click(p, '[data-testid=dock-back]')
  if (method === 'edge') { await swipe(p, 8); return true }
  if (method === 'mid') { await swipe(p, 100); return true }
  await goBack(p)
  return true
}

const shellAt = (p, lv) => until(p, (s) => s.level === lv, 8000)
const load = async (p, base, path) => {
  await p.goto(base + path, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('.spool-shell, .login-landing-card', { timeout: NAV_TIMEOUT })
}

/** Open the entry; resolve to the level it starts on. */
async function enter(p, base, entry) {
  const deep = `/channel/lobby?topic=${TASK}`
  if (entry === 'tap') {
    await load(p, base, '/')
    await shellAt(p, 1)
    await click(p, '[data-testid=sidebar-tab-channels]')
    await sleep(300)
    await p.evaluate(() => {
      const row = [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].find((e) => (e.getAttribute('href') || '').endsWith('/channel/lobby'))
      row?.click()
    })
    await shellAt(p, 2)
    await p.evaluate((id) => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      pinia?._s.get('topic')?.openTopic(id)
    }, TASK)
  } else if (entry === 'topic') {
    await load(p, base, deep)
  } else if (entry === 'channel') {
    await load(p, base, '/channel/lobby')
    return (await shellAt(p, 2)).level
  } else if (entry === 'deep') {
    await load(p, base, '/')
    await shellAt(p, 1)
    await load(p, base, deep)
  } else if (entry === 'login') {
    await load(p, base, '/login')
    await sleep(800)
    await load(p, base, '/')
    await shellAt(p, 1)
    await load(p, base, deep)
  } else if (entry === 'notify') {
    await load(p, base, `/m/${REPLY}`)
  }
  return (await shellAt(p, 3)).level
}

/** One cell: a fresh tab, the entry, then Back to the start of history. */
async function cell(browser, base, width, entry, method) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const steps = []
  const fails = []
  try {
    await p.setViewport({ width, height: SIZES[width], isMobile: true, hasTouch: true })
    await p.evaluateOnNewDocument(boot, MEMBER)
    const want = entry === 'channel' ? 2 : 3
    const start = await enter(p, base, entry)
    steps.push(`L${start}`)
    if (start !== want) {
      fails.push(`entry opened level ${start}, not ${want}`)
      return { steps, fails }
    }
    /* the entry itself may visit /login (the login entry): watch from here */
    await p.evaluate(() => { try { sessionStorage.removeItem('e2e.loginPainted') } catch { /* */ } })

    if (method === 'sheet') {
      await click(p, '[data-test=user-menu-trigger]')
      let s = await until(p, (x) => x.menu, 3000)
      if (!s.menu) {
        fails.push('the avatar sheet did not open')
        return { steps, fails }
      }
      await goBack(p)
      s = await until(p, (x) => !x.menu)
      steps.push(s.menu ? 'sheet!' : `sheet>L${s.level}`)
      if (s.menu || s.level !== start) fails.push(`Back with the sheet open: menu=${s.menu} level ${start} -> ${s.level}`)
    }

    const how = method === 'sheet' ? 'browser' : method
    for (let lv = start; lv > 1 && !fails.length; lv--) {
      if (!(await back(p, how))) {
        fails.push(`no ${how} control at level ${lv}`)
        break
      }
      const s = await until(p, (x) => x.level !== lv || x.login)
      steps.push(s.login ? 'LOGIN' : `L${s.level}`)
      if (s.login || s.painted) fails.push(`Back at level ${lv} showed the sign-in page (${s.path})`)
      else if (s.level !== lv - 1) fails.push(`Back at level ${lv} went to level ${s.level} (${s.path})`)
    }

    /* level 1: browser Back (the OS gesture) until the tab leaves the app */
    for (let i = 0; i < 4 && !fails.length; i++) {
      await goBack(p)
      await sleep(400)
      const s = await state(p)
      if (s.path === 'about:blank') { steps.push('out'); break }
      steps.push(s.login ? 'LOGIN' : `L${s.level}`)
      if (s.login || s.painted) fails.push(`Back from level 1 showed the sign-in page (${s.path}, painted=${s.painted})`)
      else if (i === 3) fails.push(`still in the app after 4 Backs from level 1 (${s.path})`)
    }
  } catch (e) {
    fails.push(`error: ${e.message}`)
  } finally {
    await p.close().catch(() => {})
  }
  return { steps, fails }
}

const srv = await startServer()
const browser = await launch()
const cells = []
try {
  for (const width of WIDTHS) {
    for (const entry of ENTRIES) {
      for (const method of METHODS) {
        const r = await cell(browser, srv.base, width, entry, method)
        const known = Boolean(knownRed(entry, method))
        const verdict = r.fails.length ? (known && !STRICT ? 'KNOWN-RED' : 'FAIL') : (known ? 'XPASS' : 'OK')
        cells.push({ width, entry, method, verdict, ...r })
        console.log(`  ${verdict.padEnd(9)} ${width} ${entry.padEnd(7)} ${method.padEnd(7)} ${r.steps.join('>')}${r.fails.length ? '  ' + r.fails.join('; ') : ''}`)
      }
    }
  }
} finally {
  await browser.close()
  await srv.stop()
}

/* the matrix, one table per width */
const mark = { OK: 'ok', FAIL: 'FAIL', 'KNOWN-RED': 'red*', XPASS: 'XPASS' }
for (const width of WIDTHS) {
  console.log(`\n${width}x${SIZES[width]}  ${'entry'.padEnd(8)}${METHODS.map((m) => m.padEnd(8)).join('')}`)
  for (const entry of ENTRIES) {
    const row = METHODS.map((m) => mark[cells.find((c) => c.width === width && c.entry === entry && c.method === m)?.verdict] || '-')
    console.log(`         ${entry.padEnd(8)}${row.map((v) => v.padEnd(8)).join('')}`)
  }
}
console.log('red* = known red by design, see KNOWN_RED (login: 087 T003; deep-link browser Back: 087 T007)')

const n = (v) => cells.filter((c) => c.verdict === v).length
const failed = cells.filter((c) => c.verdict === 'FAIL' || c.verdict === 'XPASS')
console.log(`\nphone-back-matrix: ${n('OK')}/${cells.length} passed, ${n('KNOWN-RED')} known red, ${failed.length} failed`)
if (!cells.length) {
  console.log('  FAILED: no cell selected')
  process.exit(1)
}
if (failed.length) {
  for (const f of failed) {
    console.log(`  FAILED: ${f.width} ${f.entry} ${f.method} ${f.verdict === 'XPASS' ? `passes but is KNOWN_RED (${knownRed(f.entry, f.method)}): remove its KNOWN_RED line` : f.fails.join('; ')}`)
  }
  process.exit(1)
}
