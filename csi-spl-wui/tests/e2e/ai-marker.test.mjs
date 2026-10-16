// HUM-24 (csitea ba4696c1) + SPL-2120 (owner HUM-10, t1 28559e83 msgs
// 1c268bf0, 68dd229e, 948febcd) + SPL-2173 (owner HUM-10, t1 57adfdd4 msg
// b0ef4dc4), proved in a REAL browser.
//
// HUM-24: an agent's card carries an "AI" badge (tooltip "AI agent") beside
// the name; a line the owner TYPED at an agent's terminal (specs/036) is the
// human's, so it is NOT marked.
//
// SPL-2120: "in all of the listings ... a lighter, dark, or darker change in
// the background colors" and "something different if it is posted by an
// agent ... except for the icon of a robot"; "the same ... also in the events
// log, in the issues list, and in the event flow". In each of the 4 lists -
// the message feed, the events log, the issues list (table on a desktop,
// cards on a phone) and the Flow - item 1 and item 2 have different computed
// backgrounds and item 1 and item 3 the same. SPL-2173: "the uggly left side
// brackets ... appeared after the alternative colors change - remove it": no
// item, an agent's included, has a left bar - computed border-left-width 0,
// no inset box-shadow, no narrow ::before on its left edge - and a SELECTED
// agent card neither (MessageCard's lift, f8c07156f). 1440x900 and 390x844,
// light and dark. Each list logs the contrast of its two shades, composited
// over the fill under them.
//
// Mock data: topic bbbb... holds HUM-1's opener (2222...) and CLE-07's
// replies (3333...); #lobby holds HUM-1's post (1111...) and CLE-07's row
// typed by HUM-1 (8888...); #alerts holds GRK-03's topic card (6666...). The events log reads 6 stubbed events; the issues
// list seeds 3 issues HUM-1 filed and 2 an agent filed (spool.mock.issues-seed
// / spool.mock.issues-agent); the Flow shows every entry (spool.flow-scope).
// CONTROL: the person's items have no badge, and three rows of one shade fail
// the "1 and 2 differ" check, so a list with no alternation reads red. The
// bar check reads red on ee7a49523 (SPL-2120), which drew the bar as an inset
// box-shadow.
//
// Run:
//   pnpm run test:e2e ai-marker
//   BASE_URL=<generated bundle> pnpm run test:e2e ai-marker     # what CI does
//   SHOT_DIR=/tmp/shots ...                                      # keep the screenshots
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const AGENT = '33333333-3333-4333-8333-333333333333'
const OPENER = '22222222-2222-4222-8222-222222222222'
const HUMAN = '11111111-1111-4111-8111-111111111111'
const TYPED = '88888888-8888-4888-8888-888888888888'
const ALERT = '66666666-6666-4666-8666-666666666666'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const THEMES = ['light', 'dark']
const FLOW_LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })
const EVENTS = Array.from({ length: 6 }, (_, i) => ({
  id: 6 - i, error_id: `e-${6 - i}`, at: '2026-10-15T08:00:00Z', received_at: '2026-10-15T08:00:01Z',
  source: i % 2 ? 'hub' : 'wui', status: i % 2 ? 404 : 500, message: `event ${6 - i}`, route: '/events',
}))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

/** the events log reads its rows from the auth API: a signed-in session and 6 events */
function authAnswer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'hum-1@example.com', email: 'hum-1@example.com', name: 'FirstName LastName',
      hum: 'HUM-1', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'events') return json(200, { events: EVENTS, next_before: 0 })
  return null
}

/**
 * The list's items as the reader sees them: for the first run of three
 * neighbours in no state of their own (selected, focused, checked, new), each
 * one's computed background, its fill composited over what is under it, its
 * left bar, and its agent flag; plus every agent / person item's bar.
 * `item` selects the list's items, `paint` (optional) the element inside an
 * item that carries the fill, `bar` the element that carries the bar.
 */
function listFacts(page, sel) {
  return page.evaluate((s) => {
    const rgba = (c) => {
      const m = /rgba?\(([^)]+)\)/.exec(c || '')
      if (!m) return [0, 0, 0, 0]
      const v = m[1].split(/[ ,/]+/).filter(Boolean).map(Number)
      return [v[0], v[1], v[2], v.length > 3 ? v[3] : 1]
    }
    /* the fill as painted: this element's background over its ancestors' */
    const painted = (el) => {
      const layers = []
      for (let e = el; e; e = e.parentElement) {
        const c = rgba(getComputedStyle(e).backgroundColor)
        if (c[3] > 0) layers.push(c)
        if (c[3] >= 1) break
      }
      let out = [255, 255, 255]
      for (const c of layers.reverse()) out = out.map((v, i) => v * (1 - c[3]) + c[i] * c[3])
      return out
    }
    const lum = (rgb) => {
      const [r, g, b] = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 })
      return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return Math.round(((x + 0.05) / (y + 0.05)) * 1000) / 1000 }
    const items = [...document.querySelectorAll(s.item)].filter((e) => e.getBoundingClientRect().height > 0)
    const fillOf = (e) => (s.paint ? e.querySelector(s.paint) : e) || e
    const markOf = (e) => (s.bar ? e.querySelector(s.bar) : e) || e
    const isAi = (e) => e.getAttribute('data-ai') === 'true' || markOf(e).getAttribute('data-ai') === 'true'
    /* a left bar, however drawn: a left border, an inset shadow, or a narrow ::before down the left edge */
    const barOf = (e) => {
      const el = markOf(e)
      const cs = getComputedStyle(el)
      const why = []
      if (parseFloat(cs.borderLeftWidth) > 0 && cs.borderLeftStyle !== 'none') why.push(`border-left ${cs.borderLeftWidth}`)
      if (/inset/.test(cs.boxShadow)) why.push(`box-shadow ${cs.boxShadow}`)
      const b = getComputedStyle(el, '::before')
      if (b.content !== 'none' && b.content !== 'normal') {
        const w = parseFloat(b.width) || 0
        const h = parseFloat(b.height) || 0
        if (w > 0 && w <= 8 && h >= el.getBoundingClientRect().height / 2) why.push(`::before ${b.width}x${b.height}`)
      }
      return why.length ? why.join('; ') : false
    }
    const busy = (e) => e.matches('.selected, .active, .msg--new, .open-focus, .search-focus, [data-selected=true], [data-checked=true], [aria-selected=true], .events-row--focus')
      || Boolean(e.querySelector('[data-selected=true], [data-checked=true]')) || e.contains(document.activeElement)
    let at = -1
    for (let i = 0; i + 2 < items.length; i++) {
      if (![0, 1, 2].some((k) => busy(items[i + k]))) { at = i; break }
    }
    const three = at < 0 ? [] : items.slice(at, at + 3)
    const bg = three.map((e) => getComputedStyle(fillOf(e)).backgroundColor)
    const fill = three.map((e) => painted(fillOf(e)))
    return {
      n: items.length,
      at,
      bg,
      contrast: fill.length === 3 ? ratio(fill[0], fill[1]) : 0,
      /* only items in no state of their own: a selected / focused item's marker is the shared SELECTED look */
      agents: items.filter((e) => isAi(e) && !busy(e)).map(barOf),
      people: items.filter((e) => !isAi(e) && !busy(e)).map(barOf),
    }
  }, sel)
}

/** item 1 and 2 differ, 1 and 3 match; no item has a left bar, agents included (where `authors`) */
function judge(tag, list, f, authors) {
  ok(`${tag} ${list}: items 1 and 2 have different backgrounds, 1 and 3 the same`,
    f.bg.length === 3 && f.bg[0] !== f.bg[1] && f.bg[0] === f.bg[2], { at: f.at, n: f.n, bg: f.bg, contrast: f.contrast })
  if (!authors) return
  ok(`${tag} ${list}: SPL-2173 no agent item has a left bar`, f.agents.length > 0 && f.agents.every((s) => !s), { agents: f.agents })
  ok(`${tag} ${list}: no person's item has a left bar`, f.people.length > 0 && f.people.every((s) => !s), { people: f.people })
}

/** One feed row: the AI flag and the badge (text, tooltip, shown). */
function rowFacts(page, id) {
  return page.evaluate((msgId) => {
    const row = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
    if (!row) return null
    const badge = row.querySelector('[data-testid=msg-ai-badge]')
    const r = badge ? badge.getBoundingClientRect() : null
    return {
      ai: row.getAttribute('data-ai'),
      badge: badge ? badge.textContent.trim() : null,
      title: badge ? badge.getAttribute('title') : null,
      shown: Boolean(r && r.width > 0 && r.height > 0),
    }
  }, id)
}

const FEED = { item: '.live-rows > article.msg' }
const EVENTS_LIST = { item: '[data-test=events-table] tbody > tr[data-test=events-row]' }
const ISSUES_TABLE = { item: '[data-test=issues-row]', paint: 'td:not(.issues-c-key)', bar: 'td' }
const ISSUES_CARDS = { item: '.issues-card-li', paint: '.issues-card', bar: '.issues-card' }
const FLOW = { item: `${FLOW_LIST} [data-testid=left-entry]` }

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const phone = size.width <= 820
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument((session) => {
      try {
        localStorage.setItem('spool.mock.session', session)
        localStorage.setItem('spool.flow-scope', 'all')
        localStorage.setItem('spool.mock.issues-seed', '3')
        localStorage.setItem('spool.mock.issues-agent', '2')
      } catch { /* about:blank */ }
    }, MOCK_SESSION)
    await p.setRequestInterception(true)
    p.on('request', (req) => {
      const a = authAnswer(req)
      if (a) req.respond(a).catch(() => {})
      else req.continue().catch(() => {})
    })
    await setPageViewport(p, size)
    const go = async (path, wait) => {
      await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(wait, { timeout: NAV_TIMEOUT })
    }
    const paint = async (theme) => {
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      /* the pointer away from every item, no focus on one, so none reads its hover or focus fill */
      await p.mouse.move(1, 1)
      await p.evaluate(() => { if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur() })
      await new Promise((r) => setTimeout(r, 150))
    }
    const shot = async (name) => {
      if (!process.env.SHOT_DIR) return
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `ai-marker-${name}.png`) })
    }

    /* 1. the message feed (HUM-24 badge + SPL-2120 shading and bar) */
    await go(`/t/${TOPIC}`, `article.msg[data-msg-id="${AGENT}"]`)
    for (const theme of THEMES) {
      await paint(theme)
      const agent = await rowFacts(p, AGENT)
      const human = await rowFacts(p, OPENER)
      ok(`${tag} ${theme}: the agent card carries the "AI" badge with the "AI agent" tooltip`,
        agent?.ai === 'true' && agent.badge === 'AI' && agent.title === 'AI agent' && agent.shown, agent)
      ok(`${tag} ${theme}: CONTROL a person's card has no marker`, human?.ai === null && human.badge === null, human)
      judge(`${tag} ${theme}`, 'topic feed', await listFacts(p, FEED), true)
      await shot(`${tag}-${theme}-topic`)
    }
    /* SPL-2173: a SELECTED agent card has no left bar under its lift either (ee7a49523 drew one);
       #alerts opens on GRK-03's topic card, selected by a click as in selected-topic-card */
    await go('/channel/alerts', `article.msg[data-msg-id="${ALERT}"]`)
    await p.$eval(`article.msg[data-msg-id="${ALERT}"]`, (el) => el.click())
    await p.waitForSelector(`article.msg.selected[data-msg-id="${ALERT}"]`, { timeout: NAV_TIMEOUT }).catch(() => {})
    for (const theme of THEMES) {
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await p.mouse.move(1, 1)
      await new Promise((r) => setTimeout(r, 150))
      const sel = await p.evaluate((id) => {
        const el = document.querySelector(`article.msg.selected[data-msg-id="${id}"]`)
        if (!el) return null
        const cs = getComputedStyle(el)
        return { shadow: cs.boxShadow, left: cs.borderLeftWidth, right: cs.borderRightWidth, before: getComputedStyle(el, '::before').content }
      }, ALERT)
      ok(`${tag} ${theme}: SPL-2173 the selected agent card has no left bar`,
        sel && !/inset/.test(sel.shadow) && sel.left === sel.right && (sel.before === 'none' || sel.before === 'normal'), sel)
    }
    await go('/lobby', `article.msg[data-msg-id="${TYPED}"]`)
    for (const theme of THEMES) {
      await paint(theme)
      const typed = await rowFacts(p, TYPED)
      ok(`${tag} ${theme}: CONTROL a line typed at the agent terminal stays the human's`,
        typed?.ai === null && typed.badge === null, typed)
      /* #lobby's only agent line was typed by a person: no agent item here, so the bar is checked on the topic */
      const lobby = await listFacts(p, FEED)
      judge(`${tag} ${theme}`, 'channel feed', lobby, false)
      ok(`${tag} ${theme}: CONTROL no item of #lobby (people only) has the bar`, lobby.agents.length === 0 && lobby.people.every((x) => !x), lobby.people)
      await shot(`${tag}-${theme}-feed`)
    }

    /* 2. the events log: no author, shading only */
    await go('/events', '[data-test=events-row]')
    for (const theme of THEMES) {
      await paint(theme)
      judge(`${tag} ${theme}`, 'events log', await listFacts(p, EVENTS_LIST), false)
      await shot(`${tag}-${theme}-events`)
    }

    /* 3. the issues list: the table on a desktop, the cards on a phone */
    /* keyed on the list, not on data-ai: a build without the bar reports FAIL, it does not time out */
    await go('/issues', phone ? '[data-test=issues-card]' : '[data-test=issues-row]')
    await p.waitForFunction((sel) => document.querySelectorAll(sel).length >= 5, { timeout: NAV_TIMEOUT }, phone ? '[data-test=issues-card]' : '[data-test=issues-row]')
    for (const theme of THEMES) {
      await paint(theme)
      judge(`${tag} ${theme}`, phone ? 'issues cards' : 'issues table', await listFacts(p, phone ? ISSUES_CARDS : ISSUES_TABLE), true)
      await shot(`${tag}-${theme}-issues`)
    }

    /* 4. the Flow (the left list; every entry, so each has its author) */
    await go('/', '[data-testid=sidebar-tab-flow]')
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForFunction((sel) => document.querySelectorAll(sel).length >= 3, { timeout: NAV_TIMEOUT }, FLOW.item)
    for (const theme of THEMES) {
      await paint(theme)
      judge(`${tag} ${theme}`, 'flow', await listFacts(p, FLOW), true)
      await shot(`${tag}-${theme}-flow`)
    }
    ok(`${tag}: no page error`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
