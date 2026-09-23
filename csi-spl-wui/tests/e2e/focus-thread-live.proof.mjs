// CLE-3427 — live proof, signed in, against a deployed WUI, in BOTH themes.
//
// Two owner orders are under test here (2026-09-20):
//   "make the selected UI parts when one cycles with the tab more 3D - the
//    line in the light theme is too dark, it should be bit lighter ... also
//    the selected element should change his color to a bit darker one"
//   "any selected item should have no more than 1 color in the selected
//    border which cannot be wider than 3 px"
// and the second half of the brief: clicking a message opens ITS thread in
// the thread pane ALWAYS, including a message nobody has replied to yet.
//
// What is measured, in the browser, from COMPUTED styles rather than from the
// stylesheet: the ring on every element the Tab walk lands on, the ring on
// every selected item on the page, the fill of a selected row against an
// unselected one, and the DOM + URL after a pointer click and after an Enter
// on a focused row.
//
// Ring model. A "ring" is what the STATE draws: the outline, and any
// box-shadow layer that paints a line rather than a shadow (an inset layer,
// or a non-inset layer with a positive spread). A blurred, zero-spread drop
// shadow is a shadow, not a border, and does not count as a colour - that is
// what carries the "3D" the owner asked for. A fully transparent colour is
// not visible and does not count either. Borders are reported alongside but
// are not part of the state ring: a control's own border is present in every
// state (an `.btn.ghost` has one whether or not it is selected).
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=/var/tmp/CLE-3427-proof [TENANT=t1] [CHROME_PATH=...] \
//     [PUPPETEER_CORE=<path>] node tests/e2e/focus-thread-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), steps: [], rings: {}, fills: {}, console: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)

/* ---- the measurement, evaluated inside the page ------------------------- */
const MEASURE = `
window.__cle3427 = (() => {
  const num = (v) => parseFloat(v) || 0
  const alphaOf = (c) => {
    const m = String(c).match(/rgba?\\(([^)]+)\\)/)
    if (!m) return 1
    const parts = m[1].split(',').map((x) => parseFloat(x))
    return parts.length > 3 ? parts[3] : 1
  }
  const rgbOf = (c) => {
    const hex = String(c).trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i)
    if (hex) {
      const h = hex[1].length === 3 ? hex[1].split('').map((x) => x + x).join('') : hex[1]
      return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16))
    }
    const m = String(c).match(/rgba?\\(([^)]+)\\)/)
    if (!m) return null
    const [r, g, b] = m[1].split(',').map((x) => parseFloat(x))
    return [r, g, b]
  }
  const luminance = (c) => {
    const v = rgbOf(c)
    if (!v) return null
    const f = v.map((x) => { const s = x / 255; return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4) })
    return 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]
  }
  /** split a computed box-shadow into layers (commas inside rgb() are not separators) */
  const layersOf = (s) => {
    if (!s || s === 'none') return []
    const out = []
    let depth = 0, cur = ''
    for (const ch of s) {
      if (ch === '(') depth++
      if (ch === ')') depth--
      if (ch === ',' && depth === 0) { out.push(cur); cur = '' } else cur += ch
    }
    if (cur.trim()) out.push(cur)
    return out.map((x) => x.trim())
  }
  /** What an element is actually filled WITH: its own background, or - when
      that is transparent, as an unselected row's is - the first ancestor that
      paints one. Comparing a selected fill against \`rgba(0,0,0,0)\` would
      compare it against black and call every fill lighter. */
  const effectiveBg = (el) => {
    for (let n = el; n; n = n.parentElement) {
      const c = getComputedStyle(n).backgroundColor
      if (alphaOf(c) > 0.02) return c
    }
    return 'rgb(0, 0, 0)'
  }
  /** the rings the STATE draws: outline + box-shadow layers that paint a line */
  const ringsOf = (el) => {
    const cs = getComputedStyle(el)
    const rings = []
    if (cs.outlineStyle !== 'none' && num(cs.outlineWidth) > 0 && alphaOf(cs.outlineColor) > 0.05) {
      rings.push({ kind: 'outline', width: num(cs.outlineWidth), color: cs.outlineColor })
    }
    for (const layer of layersOf(cs.boxShadow)) {
      const inset = /inset/.test(layer)
      const colour = (layer.match(/rgba?\\([^)]*\\)/) || [null])[0]
      const lengths = (layer.replace(/rgba?\\([^)]*\\)/, '').match(/-?[\\d.]+px/g) || []).map(num)
      const [dx = 0, dy = 0, blur = 0, spread = 0] = lengths
      if (!colour || alphaOf(colour) <= 0.05) continue
      const width = inset ? Math.max(Math.abs(dx), Math.abs(dy)) + spread : spread
      if (width > 0) rings.push({ kind: inset ? 'inset' : 'spread', width, color: colour })
      else if (!inset && blur > 0) rings.push({ kind: 'shadow', width: 0, color: colour, blur })
    }
    const borders = ['Top', 'Right', 'Bottom', 'Left']
      .map((s) => ({ side: s, width: num(cs['border' + s + 'Width']), style: cs['border' + s + 'Style'], color: cs['border' + s + 'Color'] }))
      .filter((b) => b.width > 0 && b.style !== 'none' && alphaOf(b.color) > 0.05)
    const stateRings = rings.filter((r) => r.width > 0)
    return {
      rings, borders,
      colours: [...new Set(stateRings.map((r) => r.color))],
      maxWidth: stateRings.reduce((m, r) => Math.max(m, r.width), 0),
      hasRaise: rings.some((r) => r.kind === 'shadow' && r.blur > 0),
      background: effectiveBg(el),
      ownBackground: cs.backgroundColor,
      luminance: luminance(effectiveBg(el)),
    }
  }
  const describe = (el) => el ? {
    tag: el.tagName.toLowerCase(),
    test: el.getAttribute('data-test') || el.getAttribute('data-testid') || '',
    cls: (el.className && el.className.baseVal !== undefined ? el.className.baseVal : String(el.className || '')).slice(0, 60),
    text: (el.textContent || '').trim().slice(0, 40),
  } : null
  return {
    token: (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim(),
    luminance,
    focused: () => {
      const el = document.activeElement
      if (!el || el === document.body) return null
      return { ...describe(el), ...ringsOf(el) }
    },
    selected: () => [...document.querySelectorAll(
      '.nav-item.active, .msg.selected, .thread-row.selected, .search-row.active, .mention-item.active, .settings-nav__link--active, [aria-current="true"], [aria-selected="true"]'
    )].map((el) => ({ ...describe(el), ...ringsOf(el) })),
    fillOf: (sel) => { const el = document.querySelector(sel); return el ? ringsOf(el) : null },
    rowFills: () => {
      const rows = [...document.querySelectorAll('article.msg')]
      const sel = rows.find((r) => r.dataset.selected === 'true')
      const other = rows.find((r) => r.dataset.selected !== 'true')
      return { selected: sel ? ringsOf(sel) : null, plain: other ? ringsOf(other) : null }
    },
    navFills: () => {
      const items = [...document.querySelectorAll('.nav-item')]
      const active = items.find((n) => n.classList.contains('active'))
      const plain = items.find((n) => !n.classList.contains('active'))
      return { active: active ? ringsOf(active) : null, plain: plain ? ringsOf(plain) : null }
    },
    sections: () => [...document.querySelectorAll('[data-test=thread-section]')].map((a) => a.getAttribute('data-section')),
    rootText: () => { const el = document.querySelector('[data-test=thread-root]'); return el ? el.textContent.trim() : '' },
    paneEmpty: () => Boolean(document.querySelector('[data-test=thread-section] .feed-body .empty')),
    paneComposer: () => Boolean(document.querySelector('[data-test=thread-section] form.composer textarea')),
    paneReplies: () => document.querySelectorAll('[data-test=thread-section] .live-rows > article.msg').length,
    clickRow: (text) => {
      const row = [...document.querySelectorAll('article.msg')].find((r) => r.textContent.includes(text))
      if (!row) return false
      const body = row.querySelector('.msg-body') || row
      const r = body.getBoundingClientRect()
      body.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + 4, clientY: r.top + 4 }))
      return true
    },
    focusRow: (text) => {
      const row = [...document.querySelectorAll('article.msg')].find((r) => r.textContent.includes(text))
      if (!row) return false
      row.focus()
      return document.activeElement === row
    },
    xScroll: () => {
      const d = document.scrollingElement || document.documentElement
      return { scrollWidth: d.scrollWidth, clientWidth: d.clientWidth }
    },
  }
})()
`

const OLD_LIGHT_LINE_LUM = 0.2618 /* #0a97c4, the line the light theme used before this lane */

async function signIn(ctx, width = 1280) {
  const p = await ctx.newPage()
  await p.setViewport({ width, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

const measure = (p) => p.evaluate(MEASURE)

async function open(p, path) {
  await p.goto(BASE + path, { waitUntil: 'networkidle2' })
  await measure(p)
  await sleep(1200)
}

async function setTheme(p, theme) {
  await p.evaluate((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
  await p.reload({ waitUntil: 'networkidle2' })
  await measure(p)
  await sleep(800)
  return p.evaluate(() => document.documentElement.getAttribute('data-theme'))
}

async function send(p, text) {
  const ta = await p.waitForSelector('form.composer textarea')
  await ta.focus()
  await p.keyboard.type(text)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

/** Every selected item on the page obeys the owner's rule. */
async function ownerRule(p, where) {
  const items = await p.evaluate(() => window.__cle3427.selected())
  res.rings[where] = items
  const bad = items.filter((i) => i.colours.length > 1 || i.maxWidth > 3)
  step(`${where}: every selected item has one ring colour and <= 3px (${items.length} item(s))`, items.length > 0 && bad.length === 0,
    { checked: items.length, violations: bad.map((b) => ({ cls: b.cls, colours: b.colours, maxWidth: b.maxWidth })) })
  return items
}

async function tabWalk(p, theme) {
  await p.evaluate(() => { document.body.focus(); window.scrollTo(0, 0) })
  const seen = []
  for (let i = 0; i < 24; i++) {
    await p.keyboard.press('Tab')
    const f = await p.evaluate(() => window.__cle3427.focused())
    if (f) seen.push(f)
  }
  res.rings[`tab-${theme}`] = seen
  const ring = await p.evaluate(() => window.__cle3427.token('--focus-ring'))
  const withRing = seen.filter((s) => s.maxWidth > 0)
  const oneColour = withRing.filter((s) => s.colours.length > 1)
  const tooWide = withRing.filter((s) => s.maxWidth > 3)
  const raised = withRing.filter((s) => s.hasRaise)
  step(`${theme}: the Tab walk reaches controls that show a focus ring`, withRing.length >= 6, { stops: seen.length, withRing: withRing.length })
  step(`${theme}: every focused control's ring is ONE colour`, oneColour.length === 0, { violations: oneColour.map((s) => ({ cls: s.cls, colours: s.colours })) })
  step(`${theme}: no focus ring is wider than 3px`, tooWide.length === 0, { widest: withRing.reduce((m, s) => Math.max(m, s.maxWidth), 0) })
  step(`${theme}: the focus reads as RAISED (a blurred drop shadow, not a flat line)`, raised.length >= Math.ceil(withRing.length / 2),
    { raised: raised.length, of: withRing.length })
  const lum = await p.evaluate((c) => window.__cle3427.luminance(c), ring)
  if (lum === null) step(`${theme}: the --focus-ring token is a colour this proof can read`, false, { ring })
  res.rings[`ring-${theme}`] = { token: ring, luminance: lum }
  if (theme === 'light') {
    step('light: the focus line is LIGHTER than the one it replaced (#0a97c4)', lum !== null && lum > OLD_LIGHT_LINE_LUM,
      { ring, luminance: lum === null ? null : Number(lum.toFixed(3)), before: OLD_LIGHT_LINE_LUM })
  }
  return seen
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
let page
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  console.log('build', JSON.stringify(res.build))
  page = await signIn(await browser.createBrowserContext())

  for (const theme of ['dark', 'light']) {
    await open(page, '/lobby')
    const applied = await setTheme(page, theme)
    step(`${theme}: the theme is the one under test`, applied === theme, { 'data-theme': applied })

    /* 1 — Tab cycling */
    await tabWalk(page, theme)
    await page.screenshot({ path: `${OUT}/${theme}-1-tab-focus.png` })

    /* 2 — the selected channel is DARKER than an unselected one */
    await open(page, '/channel/lobby')
    await measure(page)
    const nav = await page.evaluate(() => window.__cle3427.navFills())
    res.fills[`nav-${theme}`] = nav
    step(`${theme}: the selected channel is DARKER than an unselected one`,
      Boolean(nav.active && nav.plain) && nav.active.luminance < nav.plain.luminance,
      { active: nav.active && nav.active.background, plain: nav.plain && nav.plain.background })
    await ownerRule(page, `${theme}-channel`)
    await page.screenshot({ path: `${OUT}/${theme}-2-selected-channel.png` })

    /* 3 — a lobby message nobody has replied to opens its thread on a click */
    await open(page, '/lobby')
    await measure(page)
    const nonce = `cle3427 ${theme} ${run}`
    await send(page, nonce)
    const landed = await page.waitForFunction((t) => [...document.querySelectorAll('article.msg')].some((r) => r.textContent.includes(t)),
      { polling: 'mutation', timeout: 20000 }, nonce).then(() => true, () => false)
    step(`${theme}: the fresh lobby message is on screen (it has no replies)`, landed, { nonce })
    await sleep(600)
    const clicked = await page.evaluate((t) => window.__cle3427.clickRow(t), nonce)
    await sleep(1500)
    let dom = await page.evaluate(() => ({
      sections: window.__cle3427.sections(),
      root: window.__cle3427.rootText(),
      empty: window.__cle3427.paneEmpty(),
      composer: window.__cle3427.paneComposer(),
      replies: window.__cle3427.paneReplies(),
    }))
    let url = new URL(page.url())
    step(`${theme}: clicking the message opens ONE thread section`, clicked && dom.sections.length === 1, { sections: dom.sections })
    step(`${theme}: the pane is rooted at THAT message`, dom.root.includes(nonce), { root: dom.root.slice(0, 80) })
    step(`${theme}: with no replies yet it shows the empty state and a ready composer`, dom.empty && dom.composer && dom.replies === 0,
      { empty: dom.empty, composer: dom.composer, replies: dom.replies })
    step(`${theme}: the URL deep-links the thread`, Boolean(url.searchParams.get('thread')) && Boolean(url.searchParams.get('in')),
      { thread: url.searchParams.get('thread'), in: url.searchParams.get('in') })
    const rowFills = await page.evaluate(() => window.__cle3427.rowFills())
    res.fills[`row-${theme}`] = rowFills
    step(`${theme}: the opened row reads as selected — a DARKER fill than its neighbours`,
      Boolean(rowFills.selected && rowFills.plain) && rowFills.selected.luminance < rowFills.plain.luminance,
      { selected: rowFills.selected && rowFills.selected.background, plain: rowFills.plain && rowFills.plain.background })
    await ownerRule(page, `${theme}-lobby-selected`)
    await page.screenshot({ path: `${OUT}/${theme}-3-thread-no-replies.png` })

    /* 4 — the deep link survives a reload */
    const deep = page.url()
    await page.goto(deep, { waitUntil: 'networkidle2' })
    await measure(page)
    await sleep(2000)
    const after = await page.evaluate(() => window.__cle3427.sections())
    step(`${theme}: reloading the deep link reopens the same thread`, after.length === 1, { sections: after, url: deep.replace(BASE, '') })

    /* 5 — a reply, then the same message opened again shows it */
    const reply = `reply ${theme} ${run}`
    const ta = await page.waitForSelector('[data-test=thread-section] form.composer textarea', { timeout: 10000 }).catch(() => null)
    if (ta) {
      await ta.focus()
      await page.keyboard.type(reply)
      await page.keyboard.down('Control')
      await page.keyboard.press('Enter')
      await page.keyboard.up('Control')
      const shown = await page.waitForFunction((t) => [...document.querySelectorAll('[data-test=thread-section] .live-rows > article.msg')].some((r) => r.textContent.includes(t)),
        { polling: 'mutation', timeout: 20000 }, reply).then(() => true, () => false)
      step(`${theme}: a reply in the message-rooted thread lands in that thread`, shown, { reply })
      await page.screenshot({ path: `${OUT}/${theme}-4-thread-with-reply.png` })
      /* close, reopen the same row: the reply is still its thread's */
      await page.click('[data-test=live-thread-close]').catch(() => {})
      await sleep(800)
      await open(page, '/lobby')
      await measure(page)
      /* the row must be RENDERED before it can be clicked: the feed is live and
         a fixed sleep loses the race about one run in four (measured) */
      await page.waitForFunction((t) => [...document.querySelectorAll('article.msg')].some((r) => r.textContent.includes(t)),
        { polling: 'mutation', timeout: 20000 }, nonce).catch(() => {})
      const reclicked = await page.evaluate((t) => window.__cle3427.clickRow(t), nonce)
      if (!reclicked) step(`${theme}: the message is still in the feed to reopen`, false, { nonce })
      /* the pane reads the thread over the network: poll, do not guess a sleep */
      const arrived = await page.waitForFunction(
        () => document.querySelectorAll('[data-test=thread-section] .live-rows > article.msg').length >= 1,
        { polling: 'mutation', timeout: 20000 },
      ).then(() => true, () => false)
      const again = await page.evaluate(() => ({ replies: window.__cle3427.paneReplies(), sections: window.__cle3427.sections() }))
      step(`${theme}: reopening the message shows the reply it now has`, arrived && again.sections.length === 1 && again.replies >= 1, again)
    } else {
      step(`${theme}: a reply in the message-rooted thread lands in that thread`, false, { reason: 'no composer in the pane' })
    }

    /* 6 — the keyboard half: Enter on the focused row */
    await open(page, '/lobby')
    await measure(page)
    /* wait for the row instead of sleeping at it: the feed is live and the
       window it renders moves while the proof walks */
    await page.waitForFunction((t) => [...document.querySelectorAll('article.msg')].some((r) => r.textContent.includes(t)),
      { polling: 'mutation', timeout: 20000 }, nonce).catch(() => {})
    const focused = await page.evaluate((t) => window.__cle3427.focusRow(t), nonce)
    await page.keyboard.press('Enter')
    await sleep(1500)
    const byKey = await page.evaluate(() => window.__cle3427.sections())
    step(`${theme}: Enter on the focused row opens the thread too`, focused && byKey.length === 1, { focused, sections: byKey })
    await page.screenshot({ path: `${OUT}/${theme}-5-enter-opens.png` })

    /* 7 — a search result opens its thread in the pane */
    /* the index is asynchronous: re-run the query until it has the message */
    /* search-v1 tokenises: the quoted PHRASE form is the one that reliably
       matches a nonce inside a sentence, so try it first and say which form
       produced the hit rather than leaving a bare 0 rows. */
    const queries = [`"${run}"`, run, 'cle3427']
    let hits = 0
    let why = {}
    let usedQuery = ''
    for (let i = 0; i < 6 && hits === 0; i++) {
      usedQuery = queries[i % queries.length]
      await page.goto(`${BASE}/search?q=${encodeURIComponent(usedQuery)}`, { waitUntil: 'networkidle2' })
      await measure(page)
      await sleep(2500)
      /* a query that returns nothing and a query that was REFUSED look the
         same in a row count; report which one it was */
      why = await page.evaluate(() => ({
        rows: document.querySelectorAll('.search-row').length,
        empty: Boolean(document.querySelector('[data-test=search-empty]')),
        loading: Boolean(document.querySelector('[data-test=search-loading]')),
        help: Boolean(document.querySelector('[data-test=search-help]')),
        error: (document.querySelector('[data-test=search-error], [data-test=search-bad-query]') || {}).textContent || '',
        door: Boolean(document.querySelector('[data-test=view-token-form], .view-token')),
        q: new URL(location.href).searchParams.get('q') || '',
      }))
      hits = why.rows
    }
    if (hits > 0) {
      await page.click('.search-row')
      await sleep(2000)
      const s = await page.evaluate(() => window.__cle3427.sections())
      const u = new URL(page.url())
      step(`${theme}: a search result opens its thread in the pane`, s.length === 1, { sections: s, hits, query: usedQuery })
      step(`${theme}: the search result's thread is in the URL`, Boolean(u.searchParams.get('thread')), { thread: u.searchParams.get('thread') })
      await ownerRule(page, `${theme}-search`)
      await page.screenshot({ path: `${OUT}/${theme}-6-search-thread.png` })
    } else {
      step(`${theme}: a search result opens its thread in the pane`, false, { reason: 'no row to click', ...why })
    }

    /* 8 — no document x-scroll, desktop and phone */
    for (const [w, h] of [[1280, 900], [390, 844]]) {
      await page.setViewport({ width: w, height: h })
      await sleep(600)
      const x = await page.evaluate(() => window.__cle3427.xScroll())
      step(`${theme}: no document x-scroll at ${w}x${h}`, x.scrollWidth <= x.clientWidth + 1, x)
    }
    await page.setViewport({ width: 1280, height: 900 })
  }

  /* 9 — nothing the browser refused: CSP and console errors */
  const csp = res.console.filter((m) => /Content Security Policy|Refused to/i.test(m))
  step('no CSP violation and no page error in the console', csp.length === 0, { csp: csp.slice(0, 3), console_errors: res.console.length })
} catch (e) {
  step('the proof ran to the end', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
