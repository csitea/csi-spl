// Spec 043 (SPL-988) — the lead's mobile audit, signed in, against a deployed
// WUI + hub. READ-ONLY: it taps rail tabs, opens a topic, the message menu,
// the emoji picker and the search toggle, then closes them. It never types
// into a composer and never sends or saves.
//
// Per width (default 360x780,390x844,430x932,768x1024,820x1180 with touch
// emulation, plus 1440x900 desktop) it measures, on each route:
//   - panels on screen (sidebar / main / topic-or-issue detail) and the
//     shell's data-mobile-level (spec 043 N1, FR-001)
//   - page x-scroll (FR-010), controls under 44 px and under 24 px (FR-005),
//     controls at opacity 0 = hover-only (FR-006), textareas and where they sit
//     (FR-007: a composer near the bottom)
// and walks the owner's stack once (A2): / -> a channel -> a topic -> Back ->
// Back, reading the level after every step.
// It prints one SCORE line per width x area and writes OUT/results.json plus
// a screenshot per step.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [WIDTHS=360x780,...] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/mobile-audit-live.proof.mjs
//
// On prd run it only at the e2e tenant's host e2e.<domain>, never the apex (t1). The
// password is read from PW_FILE and never printed. Exit 0 = it ran; the
// verdicts are in the SCORE lines (this is a measurement, not a gate).
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
const WIDTHS = (process.env.WIDTHS || '360x780,390x844,430x932,768x1024,820x1180,1440x900')
  .split(',').map((s) => s.split('x').map(Number))
const MOBILE_MAX = 820
/* the prd apex is t1's host (SPL-959): one label = the apex, refused */
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, widths: {}, score: [], console: [] }
const score = (w, area, ok, detail) => {
  const line = `SCORE ${w} ${area} ${ok ? 'ok' : 'BROKEN'} ${detail}`
  res.score.push(line)
  console.log(line)
}

/** goto that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      await p.waitForSelector('.sidebar', { timeout: 45000 })
      await sleep(3000)
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

/* One reading of the page. Passed as the pageFunction (the deployed CSP has no unsafe-eval). */
const MEASURE = () => {
  const vw = innerWidth
  const box = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) } }
  const shown = (el) => {
    if (!el) return false
    const b = el.getBoundingClientRect(); const cs = getComputedStyle(el)
    return b.width > 40 && b.height > 40 && b.right > 1 && b.left < vw - 1 && cs.visibility !== 'hidden' && cs.display !== 'none' && Number(cs.opacity) > 0
  }
  const vis = (el) => { const b = el.getBoundingClientRect(); const cs = getComputedStyle(el); return b.width > 0 && b.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' }
  const label = (el) => {
    const b = el.getBoundingClientRect()
    const n = el.getAttribute('data-testid') || el.getAttribute('data-test') || el.getAttribute('aria-label') || el.textContent.trim().slice(0, 24) || String(el.className).slice(0, 30)
    return `${n} ${Math.round(b.width)}x${Math.round(b.height)}`
  }
  const inMsgText = (el) => !!el.closest('.msg-body, .markdown-block, .topic-subject')
  const inter = [...document.querySelectorAll('a[href], button, input, select, textarea, [role=button], [role=tab], [role=menuitem]')].filter(vis)
  /* a radio / checkbox hidden behind its own visible label (CardClipControl) is not hover-only */
  const labelled = (el) => el.matches('input[type=radio], input[type=checkbox]') && (el.closest('label') || (el.id && document.querySelector(`label[for="${el.id}"]`)))
  const ghost = inter.filter((el) => Number(getComputedStyle(el).opacity) === 0 && !labelled(el))
  /* the hit area of a labelled radio is its label */
  /* controls whose tap target is a wrapping box (SPL-71: the whole tenant box opens the list) */
  const HIT_BOX = { 'tenant-switcher-select': '[data-testid=tenant-switcher-box]' }
  const hit = (el) => {
    const box = HIT_BOX[el.getAttribute('data-testid')]
    const wrap = box && el.closest(box)
    return (wrap || (labelled(el) ? (el.closest('label') || document.querySelector(`label[for="${el.id}"]`)) : el)).getBoundingClientRect()
  }
  /* a hit area grown by a pseudo-element (b36728f6: kind badge ::before) is not in the box: probe the 44 px square's corners */
  const hits44 = (el) => {
    const b = el.getBoundingClientRect(); const cx = b.x + b.width / 2; const cy = b.y + b.height / 2
    return [[-21, -21], [21, -21], [-21, 21], [21, 21]].every(([dx, dy]) => {
      const t = document.elementFromPoint(cx + dx, cy + dy)
      return !!t && (t === el || el.contains(t))
    })
  }
  /* elementFromPoint sees only the viewport: a small box below the fold is counted apart, never as a pass */
  /* ... and so is one whose centre sits under an overlay (the docked composer): it is unreachable until scrolled */
  const inView = (el) => {
    const b = el.getBoundingClientRect()
    if (!(b.top >= 22 && b.bottom <= innerHeight - 22 && b.left >= 22 && b.right <= vw - 22)) return false
    const t = document.elementFromPoint(b.x + b.width / 2, b.y + b.height / 2)
    if (!(t && (t === el || el.contains(t) || t.contains(el)))) return false
    /* a 44 px corner that lands on a fixed/sticky overlay (the dock) is unreachable at this scroll, not a miss */
    const cx = b.x + b.width / 2; const cy = b.y + b.height / 2
    return [[-21, -21], [21, -21], [-21, 21], [21, 21]].every(([dx, dy]) => {
      for (let n = document.elementFromPoint(cx + dx, cy + dy); n && n !== document.body; n = n.parentElement) {
        if (n === el) return true
        const pos = getComputedStyle(n).position
        if (pos === 'fixed' || pos === 'sticky') return false
      }
      return true
    })
  }
  const under = inter.filter((el) => { const b = hit(el); return (b.width < 43.5 || b.height < 43.5) && !inMsgText(el) })
  const unprobed = under.filter((el) => !inView(el))
  const small = under.filter((el) => inView(el) && !hits44(el))
  const tiny = small.filter((el) => { const b = el.getBoundingClientRect(); return b.width < 24 || b.height < 24 })
  const shell = document.querySelector('.spool-shell')
  const panes = {
    sidebar: document.querySelector('.sidebar'),
    main: document.querySelector('.spool-main'),
    detail: document.querySelector('[data-test=topic-section], .live-pane, .topic, .issues-detail'),
  }
  let onScreen = Object.entries(panes).filter(([, el]) => shown(el)).map(([k]) => k)
  /* a full-width panel on top (the level-3 detail over a kept-mounted main, b8c264de) is the one panel seen */
  const cover = ['detail', 'main'].find((k) => onScreen.includes(k) && panes[k].getBoundingClientRect().width >= vw - 1 && getComputedStyle(panes[k]).position !== 'static')
  if (cover) onScreen = [cover]
  const tas = [...document.querySelectorAll('textarea')].filter(vis).map((t) => ({ ph: (t.placeholder || '').slice(0, 24), ...box(t) }))
  return {
    vw, vh: innerHeight, url: location.pathname + location.search,
    level: shell?.dataset.mobileLevel || null,
    onScreen, panes: Object.fromEntries(Object.entries(panes).map(([k, el]) => [k, box(el)])),
    xScroll: document.documentElement.scrollWidth > vw + 1 || document.body.scrollWidth > vw + 1,
    interactive: inter.length, under44: small.length, under24: tiny.length, unprobed: unprobed.length,
    under44Sample: small.slice(0, 12).map(label),
    ghost: ghost.length, ghostSample: ghost.slice(0, 6).map(label),
    textareas: tas,
    composerLow: tas.some((t) => t.y + t.h > innerHeight * 0.6),
  }
}

const levelOf = (p) => p.evaluate(() => document.querySelector('.spool-shell')?.dataset.mobileLevel || null)

async function tap(p, sel) {
  const h = await p.$(sel)
  if (!h || !(await h.boundingBox())) return false
  await h.tap().catch(() => h.click())
  await sleep(1500)
  return true
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
})
let code = 0
try {
  const p = await browser.newPage()
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(3000)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build))

  /* a channel and a DM to visit, found at desktop width */
  await tap(p, '[data-testid=sidebar-tab-channels]')
  /* #lobby first: a fresh probe channel sorts first and has no topic to open (the walk needs one) */
  const chan = await p.evaluate(() => {
    const hrefs = [...document.querySelectorAll('a[href*="/channel/"]')].map((a) => a.getAttribute('href'))
    return hrefs.find((h) => /\/channel\/lobby$/.test(h)) || hrefs[0] || null
  })
  await tap(p, '[data-testid=sidebar-tab-dm]')
  const dm = await p.evaluate(() => [...document.querySelectorAll('a[href*="/dm/"]')].map((a) => a.getAttribute('href'))[0] || null)
  const routes = ['/', '/lobby', chan, dm, '/issues', '/search?q=spool', '/settings/profile', '/events', '/archive'].filter(Boolean)

  for (const [w, h] of WIDTHS) {
    const key = `${w}x${h}`
    const mobile = w <= MOBILE_MAX
    const W = res.widths[key] = { routes: {}, walk: [], flows: {} }
    await p.emulate({
      viewport: { width: w, height: h, isMobile: mobile, hasTouch: mobile, deviceScaleFactor: mobile ? 2 : 1 },
      userAgent: mobile
        ? 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36'
        : 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36',
    })
    for (const rt of routes) {
      try {
        await nav(p, BASE + rt)
        W.routes[rt] = await p.evaluate(MEASURE)
        await p.screenshot({ path: `${OUT}/${key}${rt.replace(/[^a-z0-9]+/gi, '_')}.png` })
      } catch (e) { W.routes[rt] = { error: String(e).slice(0, 200) } }
    }
    const R = Object.entries(W.routes).filter(([, m]) => !m.error)
    const multi = R.filter(([, m]) => m.onScreen.length !== 1).map(([rt, m]) => `${rt}=${m.onScreen.join('+')}`)
    const xs = R.filter(([, m]) => m.xScroll).map(([rt]) => rt)
    const ghosts = R.reduce((n, [, m]) => n + m.ghost, 0)
    const small = R.map(([rt, m]) => `${rt}:${m.under44}/${m.interactive}`)
    if (mobile) {
      score(key, 'one-panel', multi.length === 0, multi.length ? multi.join(' ') : 'every route')
      score(key, 'hover-only', ghosts === 0, `${ghosts} controls at opacity 0`)
      score(key, 'tap>=44', R.every(([, m]) => m.under44 === 0), small.slice(0, 5).join(' '))
      const chat = R.filter(([rt]) => rt === '/lobby' || rt === chan || rt === dm)
      score(key, 'composer-bottom', chat.length > 0 && chat.every(([, m]) => m.composerLow), chat.map(([rt, m]) => `${rt}:${m.textareas.length ? m.textareas.map((t) => t.y).join('/') : 'none'}`).join(' '))
    } else {
      score(key, 'desktop-3pane', R.filter(([rt]) => rt === '/lobby').every(([, m]) => m.onScreen.includes('sidebar') && m.onScreen.includes('main')), 'sidebar+main on /lobby')
    }
    score(key, 'no-x-scroll', xs.length === 0, xs.length ? xs.join(' ') : 'every route')

    /* A2: / -> a channel -> a topic -> Back -> Back */
    if (mobile) {
      try {
        await nav(p, BASE + '/')
        W.walk.push({ step: 'front door', level: await levelOf(p) })
        await tap(p, '[data-testid=sidebar-tab-channels]')
        const row = chan ? `.sidebar a[href$="${chan}"]` : '.sidebar a[href*="/channel/"]'
        W.walk.push({ step: 'channel row', tapped: await tap(p, row), level: await levelOf(p), url: await p.evaluate(() => location.pathname) })
        await sleep(2000)
        W.walk.push({ step: 'open topic', tapped: await tap(p, '.spool-main [data-test=open-topic], .spool-main [data-test=topic-replies]'), level: await levelOf(p) })
        await p.screenshot({ path: `${OUT}/${key}_walk_topic.png` })
        await p.goBack().catch(() => {}); await sleep(2000)
        W.walk.push({ step: 'back', level: await levelOf(p), url: await p.evaluate(() => location.pathname) })
        await p.goBack().catch(() => {}); await sleep(2000)
        W.walk.push({ step: 'back', level: await levelOf(p), url: await p.evaluate(() => location.pathname) })
        await p.screenshot({ path: `${OUT}/${key}_walk_home.png` })
      } catch (e) { W.walk.push({ error: String(e).slice(0, 200) }) }
      const lv = W.walk.map((s) => s.level ?? '-').join('>')
      score(key, 'walk-1-2-3-2-1', lv === '1>2>3>2>1', lv)

      /* T055 / SPL-994: Back with a dialog open closes the dialog and stays on the page (the new-channel form; nothing is saved) */
      try {
        await nav(p, BASE + '/')
        await tap(p, '[data-testid=sidebar-tab-channels]')
        const opened = await tap(p, '[data-testid=create-channel]')
        const before = await p.evaluate(() => ({ url: location.pathname + location.search, level: document.querySelector('.spool-shell')?.dataset.mobileLevel || null, dialog: !!document.querySelector('[role=dialog]') }))
        await p.goBack().catch(() => {}); await sleep(2000)
        const after = await p.evaluate(() => ({ url: location.pathname + location.search, level: document.querySelector('.spool-shell')?.dataset.mobileLevel || null, dialog: !!document.querySelector('[role=dialog]') }))
        W.flows.dialogBack = { opened, before, after }
        score(key, 'dialog-back', opened && before.dialog && !after.dialog && after.url === before.url && after.level === before.level,
          `opened=${opened} dialog ${before.dialog}->${after.dialog} url ${before.url}->${after.url} level ${before.level}->${after.level}`)
      } catch (e) { W.flows.dialogBack = { error: String(e).slice(0, 200) } }
    }

    /* message actions on /lobby */
    try {
      await nav(p, BASE + '/lobby')
      const mb = await p.$('.spool-main [data-testid=msg-menu-btn]')
      const eb = await p.$('.spool-main [data-testid=msg-emoji-btn]')
      const size = async (hd) => { const b = hd && await hd.boundingBox(); return b ? [Math.round(b.width), Math.round(b.height)] : null }
      W.flows.menuBtn = await size(mb)
      W.flows.emojiBtn = await size(eb)
      if (eb && W.flows.emojiBtn) {
        await eb.tap().catch(() => eb.click()); await sleep(1200)
        W.flows.emoji = await p.evaluate(() => {
          const m = document.querySelector('.emoji-picker')
          if (!m) return { open: false }
          const b = m.getBoundingClientRect()
          return { open: true, rect: [Math.round(b.x), Math.round(b.y), Math.round(b.width), Math.round(b.height)], inView: b.left >= 0 && b.right <= innerWidth + 1 && b.bottom <= innerHeight + 1 }
        })
        await p.keyboard.press('Escape'); await sleep(300)
      }
      if (mobile) {
        const big = (s) => s && s[0] >= 44 && s[1] >= 44
        /* D3: on a phone the emoji button may move into the long-press sheet (8378bab3); absent = ok, present = 44 px and a picker in view */
        const emojiOk = !W.flows.emojiBtn || (big(W.flows.emojiBtn) && W.flows.emoji?.open && W.flows.emoji?.inView)
        score(key, 'msg-actions', !!(big(W.flows.menuBtn) && emojiOk),
          `menu ${W.flows.menuBtn} emoji ${W.flows.emojiBtn} picker ${JSON.stringify(W.flows.emoji || null)}`)
      }
    } catch (e) { W.flows.error = String(e).slice(0, 200) }
  }
} catch (e) {
  code = 1
  console.error('FAIL', String(e).slice(0, 300))
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
  await browser.close()
}
process.exit(code)
