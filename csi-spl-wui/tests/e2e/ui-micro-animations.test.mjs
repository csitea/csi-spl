// SPL-2814, row 09 of csi-spl-doc/doc/md/ui-animations-panel-plan.md (epic
// SPL-2403): one browser test for the micro-animations of rows 01-08, at a
// phone (390x844, touch) and a desktop (1440x900), on the mock bundle.
//
// Every row plays `tap-anim tap-anim--<kind>` (assets/css/tap-anim.css,
// composables/useTapAnim.ts). A MutationObserver installed before the app
// boots logs each tap-anim--<kind> class going on and off, with its time, so
// no check sleeps and hopes. Per row and viewport:
//   T  after the trigger the class goes on, and comes off within
//      max(600 ms, the row's own duration) + MARGIN_MS, and no sooner than
//      most of that duration (the animation really ran; a cancel fails it).
//      The duration is read from tap-anim.css, never typed in here.
//   M3 under prefers-reduced-motion: reduce the same trigger (its own effect
//      is checked, so the step is not vacuous) adds 0 tap-anim classes
//   X  after the trigger: document scrollWidth equals the viewport (0 px)
//   M4 with no trigger, a settled page logs 0 class adds over IDLE_MS and has
//      0 running tap-* animations
//
// The rows and their triggers:
//   01 a section rail tab tap (v-tap-anim; the phone's rail is on level 1)
//   02 Copy link on an open issue: its check draws; on the phone also the
//      status strip's commit copy in its version card
//   03 an emoji picked for a card: its chip pops
//   04 a live DM from a peer (notification countDmLive + ingest, the socket's
//      path, as tests/e2e/dm-badge-total.test.mjs drives it): its row badge
//      swells (the phone's DM list is on level 1)
//   05 the connection dot's reconnect ripple: NOT triggerable here. The mock
//      bundle has no socket; useLive pins its state to 'mock' (always `ok`),
//      so no down -> ok transition exists. Only its idle half is checked:
//      the dot carries no tap-anim class and runs no animation.
//   06 an empty channel's mascot waves once on mount
//   07 the undo snackbar settles in (Archive from a card's menu). Its class
//      is set in the template on purpose and stays (UndoSnackbar.vue), so T
//      reads its CSS animation instead: running on mount, finished within
//      the same limit; M3 reads 0 animations on it.
//   08 ticking a waiting animation in Settings > Appearance pops its ring
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/ui-micro-animations.test.mjs   # what CI does
//   node tests/e2e/ui-micro-animations.test.mjs                               # nuxi dev mock
import { createRequire } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* headroom for a loaded runner: animationend lands on a frame after the end */
const MARGIN_MS = 400
const IDLE_MS = 1500
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const PEER = 'CLE-11@box-desk'

/* ---- each kind's run time (duration x iterations), from the stylesheet ---- */
function readDurations() {
  const css = readFileSync(join(WUI, 'src/assets/css/tap-anim.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  const rule = (sel) => (css.match(new RegExp(`${sel.replace(/[.-]/g, '\\$&')}\\s*\\{([^}]*)\\}`)) || [])[1] || ''
  const prop = (body, name) => (body.match(new RegExp(`${name}:\\s*([^;]+);`)) || [])[1]
  const base = rule('.tap-anim')
  const baseMs = parseFloat(prop(base, 'animation-duration'))
  const ms = {}
  for (const [, kind] of css.matchAll(/\.tap-anim--([a-z]+)\s*\{/g)) {
    const body = rule('.tap-anim--' + kind)
    const dur = parseFloat(prop(body, 'animation-duration') ?? baseMs)
    const n = parseFloat(prop(body, 'animation-iteration-count') ?? prop(base, 'animation-iteration-count') ?? 1)
    ms[kind] = dur * n
  }
  if (!(baseMs > 0) || !(ms.ripple > 0)) throw new Error('tap-anim.css: no durations read')
  return ms
}
const DUR = readDurations()
const limitOf = (kind) => Math.max(600, DUR[kind]) + MARGIN_MS

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* Runs before the app: logs every tap-anim--<kind> class on / off with its
   time, the element's number and the nearest test id above it. */
function recorder() {
  window.__tap = []
  const ids = new WeakMap()
  let n = 0
  const num = (el) => { if (!ids.has(el)) ids.set(el, ++n); return ids.get(el) }
  const kinds = (s) => new Set(String(s || '').split(/\s+/).filter((c) => c.startsWith('tap-anim--')))
  const tag = (el) => {
    const t = el.closest('[data-testid],[data-test]')
    return t ? (t.getAttribute('data-testid') || t.getAttribute('data-test')) : ''
  }
  new MutationObserver((ms) => {
    const t = performance.now()
    for (const m of ms) {
      const was = kinds(m.oldValue)
      const now = kinds(m.target.getAttribute('class'))
      for (const k of now) if (!was.has(k)) window.__tap.push({ t, on: 1, k: k.slice(10), id: num(m.target), tag: tag(m.target) })
      for (const k of was) if (!now.has(k)) window.__tap.push({ t, on: 0, k: k.slice(10), id: num(m.target) })
    }
  }).observe(document, { subtree: true, attributes: true, attributeFilter: ['class'], attributeOldValue: true })
}

const mark = (p) => p.evaluate(() => window.__tap.length)
const since = (p, i) => p.evaluate((i) => window.__tap.slice(i), i)
const running = (p) => p.evaluate(() => document.getAnimations()
  .filter((a) => a.playState === 'running' && String(a.animationName || '').startsWith('tap-')).length)
const overflow = (p) => p.evaluate(() => ({ sw: document.documentElement.scrollWidth, vw: window.innerWidth }))

function until(p, fn, arg, ms = 8000) {
  return p.waitForFunction(fn, { timeout: ms, polling: 50 }, arg).then(() => true, () => false)
}

/** After log index i: `kind` goes on (on an element whose test id matches
    tagRe), then off on the same element; returns the gap, -1 if never. */
async function onOff(p, i, kind, tagRe) {
  const got = await p.waitForFunction((i, kind, re, limit) => {
    const log = window.__tap.slice(i)
    const on = log.find((e) => e.on && e.k === kind && new RegExp(re).test(e.tag))
    if (!on) return false
    const off = log.find((e) => !e.on && e.id === on.id && e.k === kind && e.t >= on.t)
    if (off) return { on: on.tag, ms: Math.round(off.t - on.t) }
    return performance.now() - on.t > limit + 1000 ? { on: on.tag, ms: -1 } : false
  }, { timeout: 8000 + limitOf(kind), polling: 50 }, i, kind, tagRe.source, limitOf(kind)).then((h) => h.jsonValue(), () => null)
  return got || { on: null, ms: -1 }
}

/** T + X for one row: the class on and off in time, no overflow after. */
async function checkPlays(p, W, row, kind, tagRe, trigger) {
  const i = await mark(p)
  const fired = await trigger()
  const r = await onOff(p, i, kind, tagRe)
  const lo = DUR[kind] * 0.8
  ok(`${W} ${row} T ${kind}: on after the trigger, off within ${limitOf(kind)} ms (ran >= ${lo} ms)`,
    fired !== false && r.on !== null && r.ms >= lo && r.ms <= limitOf(kind), { fired, ...r })
  const o = await overflow(p)
  ok(`${W} ${row} X 0 px overflow after the trigger`, o.sw === o.vw, o)
}

/** M3 for one row: the trigger's own effect shows, and no class went on. */
async function checkStill(p, W, row, trigger, effect, arg) {
  const i = await mark(p)
  const fired = await trigger()
  const seen = fired !== false && await until(p, effect, arg)
  /* a class goes on in the same task or a tick later: two frames plus
     300 ms covers a nextTick after an await */
  await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
  await sleep(300)
  const adds = (await since(p, i)).filter((e) => e.on)
  ok(`${W} ${row} M3 reduced motion: the trigger acted, 0 tap-anim classes added`, seen && adds.length === 0, { seen, adds })
}

const store = (p, name, fn, ...args) => p.evaluate((name, fn, args) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get(name)
  return s[fn](...args)
}, name, fn, args)

const push = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/** Click the first rendered element for `sel` (what a tap's click does). */
const clickSel = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return false
  e.click()
  return true
}, sel)

/* ---- the rows' triggers ---- */

/** 06: a new, empty channel opens on its mascot */
async function emptyChannel(p, name) {
  await p.evaluate(async (name) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    await app.config.globalProperties.$pinia._s.get('channel').createChannel(name)
    await app.config.globalProperties.$router.push('/channel/' + name)
  }, name)
  return until(p, () => Boolean(document.querySelector('[data-testid=feed-empty-mascot]')), null, 15000)
}
const mascotShown = () => Boolean(document.querySelector('[data-testid=feed-empty-mascot]'))

/** a topic card of our own in the open channel; returns its msg id */
async function ownCard(p, body) {
  const id = await p.evaluate(async (body) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    return (await ch.send(body, undefined, undefined, undefined, 1)).msg_id
  }, body)
  await p.waitForSelector(`article.msg[data-msg-id="${id}"]`, { timeout: 10000 })
  return id
}

/** 03: the card's emoji button, then the picker's first glyph */
async function pickEmoji(p, id) {
  const card = `article.msg[data-msg-id="${id}"]`
  if (!await p.evaluate((sel) => { const b = document.querySelector(`${sel} [data-testid=msg-emoji-btn]`); b?.click(); return Boolean(b) }, card)) return false
  if (!await until(p, () => Boolean(document.querySelector('[data-testid=emoji-picker] .emoji-picker__glyph, [data-testid=emoji-grid] button')), null, 5000)) return false
  return clickSel(p, '[data-testid=emoji-picker] .emoji-picker__glyph, [data-testid=emoji-grid] button')
}
const chipShown = (id) => Boolean(document.querySelector(`article.msg[data-msg-id="${id}"] [data-testid=msg-reaction]`))

/** 07: Archive from the card's menu; true once the snackbar is up */
async function archiveCard(p, id) {
  const card = `article.msg[data-msg-id="${id}"]`
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), card)
    if (await until(p, () => Boolean(document.querySelector('[data-testid=msg-menu-archive]')), null, 3000)) break
  }
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  return until(p, () => Boolean(document.querySelector('.undo-snackbar')), null, 5000)
}
/** the snackbar root's settle animation: running at mount, then finished */
const settle = (p) => p.evaluate(async () => {
  const el = document.querySelector('.undo-snackbar')
  if (!el) return { el: false }
  const a = el.getAnimations().find((x) => x.animationName === 'tap-settle')
  if (!a) return { el: true, ran: false, anims: el.getAnimations().length }
  const t0 = performance.now() - (Number(a.currentTime) || 0)
  await a.finished.catch(() => {})
  return { el: true, ran: true, ms: Math.round(performance.now() - t0), state: a.playState }
})
const settleAnims = () => {
  const el = document.querySelector('.undo-snackbar')
  return el ? el.getAnimations().length : -1
}

/** 04: one more DM line from the peer, through the socket's handlers */
let dmSec = 10
async function liveDm(p) {
  dmSec += 1
  const ts = new Date(Date.UTC(2026, 9, 22, 9, 0, dmSec)).toISOString()
  const m = { v: 1, msg_id: `anim-dm-${dmSec}`, task_id: 'anim-dm-topic', kind: 'note', body: 'anim dm ' + dmSec, files: [],
    ts, received_at: ts, from: 'CLE-11', from_box: 'box-desk', to: 'HUM-1', to_box: 'box-wui', channel: null }
  await store(p, 'notification', 'countDmLive', m, 'HUM-1')
  await store(p, 'notification', 'ingest', [m], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  return true
}
const dmBadge = (peer) => [...document.querySelectorAll('a.nav-item')].find((e) => e.getAttribute('data-key') === peer)?.querySelector('[data-test=dm-badge]')?.textContent.trim() || ''
const dmBadgeMoved = ([peer, before]) => ([...document.querySelectorAll('a.nav-item')].find((e) => e.getAttribute('data-key') === peer)?.querySelector('[data-test=dm-badge]')?.textContent.trim() || '') !== before

/** 02: a new issue, open in its detail view (the phone's create lands there) */
async function openNewIssue(p, phone, title) {
  await push(p, '/issues')
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-test=issues-new]')
  if (phone) {
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
  } else {
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    const key = await p.waitForFunction((want) => {
      const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
      return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
    }, { timeout: 5000 }, title).then((h) => h.jsonValue())
    await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  }
  await p.waitForSelector('[data-test=issues-detail-copy]', { visible: true, timeout: 8000 })
  await p.evaluate(() => {
    try { Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: () => Promise.resolve() } }) } catch { /* read-only */ }
  })
}
const copied = () => document.querySelector('[data-test=issues-detail-copy]')?.getAttribute('data-copied') === 'true'

async function newPage(browser, vp) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.evaluateOnNewDocument(recorder)
  await p.evaluateOnNewDocument((peer) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
      /* the DM rows' own count, as dm-badge-total.test.mjs reads it */
      localStorage.setItem('spool.mock.flow-keys', 'off')
      localStorage.setItem('spool.read-cursors', JSON.stringify({ [`dm:${peer}`]: { ts: '2026-10-22T09:00:00.000Z', id: '' } }))
    } catch { /* about:blank */ }
  }, PEER)
  /* a build.json, so the phone strip's version card has a commit to copy */
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname === '/build.json') {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: '0123456789abcdef0123456789abcdef01234567', built_at: '2026-10-22T09:00:00Z', run: '1' }) })
    }
    return req.continue()
  })
  return { ctx, p, errors }
}

async function viewport(browser, base, vp) {
  const W = String(vp.width)
  const phone = vp.width < 800
  const { ctx, p, errors } = await newPage(browser, vp)
  try {
    await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })

    /* M4: the load settled, then an idle window with no trigger */
    await until(p, () => !document.getAnimations().some((a) => a.playState === 'running' && String(a.animationName || '').startsWith('tap-')), null, 5000)
    await sleep(500)
    const i0 = await mark(p)
    await sleep(IDLE_MS)
    const idleAdds = (await since(p, i0)).filter((e) => e.on)
    const idleRun = await running(p)
    ok(`${W} M4 idle ${IDLE_MS} ms, no trigger: 0 tap-anim classes added, 0 tap animations running`,
      idleAdds.length === 0 && idleRun === 0, { idleAdds, running: idleRun })
    /* 05: no reconnect in the mock (see the header); the dot is still */
    const dot = await p.evaluate((sel) => {
      const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
      return e ? { cls: e.getAttribute('class'), anims: e.getAnimations().length } : null
    }, phone ? '.status-strip__dot' : '.health-dot')
    ok(`${W} 05 M4 the connection dot is still at idle (its reconnect is not triggerable on the mock bundle)`,
      Boolean(dot) && !/tap-anim/.test(dot.cls) && dot.anims === 0, dot)
    const o0 = await overflow(p)
    ok(`${W} X 0 px overflow at idle`, o0.sw === o0.vw, o0)

    for (const reduce of [false, true]) {
      const M = reduce ? `${W} reduced` : W
      if (reduce) await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])

      /* 06 mascot, then 03 reaction and 07 snackbar on cards in that channel */
      const chan = `anim-r09-${W}-${reduce ? 'still' : 'moving'}`
      if (!reduce) await checkPlays(p, M, '06', 'greeting', /feed-empty-mascot/, () => emptyChannel(p, chan))
      else await checkStill(p, M, '06', () => emptyChannel(p, chan), mascotShown)
      const card = await ownCard(p, `row 09 react ${M}`)
      if (!reduce) await checkPlays(p, M, '03', 'pop', /msg-reaction/, () => pickEmoji(p, card))
      else await checkStill(p, M, '03', () => pickEmoji(p, card), chipShown, card)
      const card2 = await ownCard(p, `row 09 archive ${M}`)
      const up = await archiveCard(p, card2)
      if (!reduce) {
        const s = await settle(p)
        ok(`${M} 07 T settle: runs on the snackbar's mount, done within ${limitOf('settle')} ms (ran >= ${DUR.settle * 0.8} ms)`,
          up && s.ran === true && s.ms >= DUR.settle * 0.8 && s.ms <= limitOf('settle'), { up, ...s })
        const o = await overflow(p)
        ok(`${M} 07 X 0 px overflow after the trigger`, o.sw === o.vw, o)
      } else {
        const n = await p.evaluate(settleAnims)
        ok(`${M} 07 M3 reduced motion: the snackbar is up and runs 0 animations`, up && n === 0, { up, anims: n })
      }

      /* 04: a live DM, and 01: a rail tab tap. The desktop lists the DM rows
         beside the feed; a phone shows the rail and the rows on level 1 */
      if (phone) {
        await push(p, '/')
        await until(p, () => [...document.querySelectorAll('[data-testid=sidebar-tab-dm]')].some((e) => e.getClientRects().length), null, 8000)
      }
      await clickSel(p, '[data-testid=sidebar-tab-dm]')
      await until(p, (peer) => [...document.querySelectorAll('a.nav-item')].some((e) => e.getAttribute('data-key') === peer && e.getClientRects().length), PEER)
      const before = await p.evaluate(dmBadge, PEER)
      if (!reduce) await checkPlays(p, M, '04', 'swell', /dm-badge/, () => liveDm(p))
      else await checkStill(p, M, '04', () => liveDm(p), dmBadgeMoved, [PEER, before])
      const tab = '[data-testid=sidebar-tab-channels]'
      const onTab = () => [...document.querySelectorAll('[data-testid=sidebar-tab-channels]')].some((e) => e.getClientRects().length && e.getAttribute('aria-selected') === 'true')
      if (!reduce) await checkPlays(p, M, '01', 'bubble', /sidebar-tab-channels/, () => clickSel(p, tab))
      else await checkStill(p, M, '01', () => clickSel(p, tab), onTab)

      /* 02 (phone): the status strip's commit copy, in its version card */
      if (phone) {
        await push(p, `/channel/${chan}`)
        await until(p, () => Boolean(document.querySelector('[data-test=status-strip-version]')), null, 8000)
        await clickSel(p, '[data-test=status-strip-version]')
        await until(p, () => Boolean(document.querySelector('[data-test=status-strip-version-copy]')), null, 5000)
        await p.evaluate(() => {
          try { Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: () => Promise.resolve() } }) } catch { /* read-only */ }
        })
        const stripCopy = () => clickSel(p, '[data-test=status-strip-version-copy]')
        if (!reduce) await checkPlays(p, M, '02 strip', 'draw', /status-strip-version-copy/, stripCopy)
        else await checkStill(p, M, '02 strip', stripCopy, () => /copied/i.test(document.querySelector('[data-test=status-strip-version-copy]')?.getAttribute('aria-label') || ''))
        await clickSel(p, '[data-test=status-strip-version]')
      }

      /* 08: tick a waiting animation in Settings > Appearance */
      await push(p, `/channel/${chan}?settings=appearance`)
      await p.waitForSelector('[data-test=await-anim-setting] input[type=checkbox]', { timeout: NAV_TIMEOUT })
      const box = await p.evaluate(() => {
        const i = [...document.querySelectorAll('[data-test=await-anim-setting] input[type=checkbox]')].find((x) => !x.checked && !x.disabled)
        return i ? i.getAttribute('data-test') : null
      })
      /* the effect is the tick's change event: the mock's stub API refuses
         the save, so the box can be unticked again before a poll sees it */
      const tick = async () => {
        if (!box) return false
        await p.evaluate(() => {
          window.__ticked = false
          document.addEventListener('change', (e) => { if (e.target?.checked) window.__ticked = true }, { capture: true, once: true })
        })
        return clickSel(p, `[data-test=${box}]`)
      }
      if (!reduce) await checkPlays(p, M, '08', 'pop', /await-anim/, tick)
      else await checkStill(p, M, '08', tick, () => window.__ticked === true)

      /* 02: Copy link on a new issue */
      await openNewIssue(p, phone, `row 09 copy ${M}`)
      const copy = () => clickSel(p, '[data-test=issues-detail-copy]')
      if (!reduce) await checkPlays(p, M, '02', 'draw', /issues-detail-copy/, copy)
      else await checkStill(p, M, '02', copy, copied)
    }

    ok(`${W} no page error`, errors.length === 0, errors)
  } finally {
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
let crashed = false
try {
  console.log('run time per kind from tap-anim.css (ms):', JSON.stringify(DUR))
  for (const vp of [
    { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 },
    { width: 1440, height: 900, isMobile: false, hasTouch: false, deviceScaleFactor: 1 },
  ]) {
    console.log(`-- ${vp.width} px`)
    await viewport(browser, server.base, vp)
  }
} catch (e) {
  crashed = true
  console.error(e)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nui-micro-animations: ${results.length - failed.length}/${results.length} passed`)
if (crashed || failed.length || !results.length) {
  for (const f of failed) console.log(`FAIL ${f.name}`)
  process.exit(1)
}
