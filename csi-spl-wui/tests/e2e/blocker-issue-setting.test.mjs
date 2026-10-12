// Blocker -> issue: the workspace setting "blocker to issue after N minutes"
// in a REAL browser, against the mock bundle (the mock plays an admin;
// tenant-settings-mock.mjs keeps the key with the hub's range, 0..1440).
//
// Desktop:
//   1  Tenant settings -> General shows the block at the hub default, 3
//   2  set it to 10, save, leave the page and come back: 10
//   3  CONTROL: 1441 is refused (out of range) and nothing is saved; the
//      hub's 400 bad_setting rule is tests/unit/blocker-issue.test.mjs and
//      internal/hub/blocker_issue_test.go
// Phone, 360x780 and 390x844, dark and light, font levels 1, 3, 5:
//   4  no sideways scroll (document and every element: scrollLeft == 0)
//   5  every control 44..48 px tall
// The owner decides (t1 5ea2e615, owner msg db5ed497: "An owner question
// should not become an issue until the owner decides that"), desktop:
//   6  the owner's menu on a blocker offers Make an issue; picking it opens
//      the new issue (todo, label blocker) on the issues sheet
//   7  CONTROL: the owner's menu on a note has no Make an issue
//   8  CONTROL: a developer's menu on the same blocker has none (the hub
//      refuses them too: internal/hub/blocker_issue_owner_test.go)
//
// Plant the defect and watch step 2 go red (the save is never clicked):
//   PROVE_RED=no-save node tests/e2e/blocker-issue-setting.test.mjs
// and step 6 (the blocker is sent as a note, so nothing is offered):
//   PROVE_RED=no-blocker node tests/e2e/blocker-issue-setting.test.mjs
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e blocker-issue-setting
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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

const BLOCK = '[data-test=tenant-blocker-issue]'
const MINUTES = '[data-test=tenant-blocker-issue-minutes]'
const value = (p, sel) => p.$eval(sel, (e) => e.value).catch(() => '')
const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

/** a fresh signed-in admin page */
async function open(browser, vp, path, { theme = 'dark', level = 3 } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
    } catch { /* about:blank */ }
  }, { theme, level })
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx, errors }
}

/* steps 6-8: an agent's blocker to the owner and a note, in #alerts */
const BLOCKER = 'b10c4e00-5ea2-4e15-8db5-000000000001'
const NOTE = 'b10c4e00-5ea2-4e15-8db5-000000000002'
const card = (msg_id, kind, body) => ({
  v: 1, msg_id, task_id: msg_id.replace(/1$|2$/, (d) => String(Number(d) + 4)), ts: '2026-12-01T10:00:00Z', from: 'c-101',
  from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind, body, channel: 'alerts', parent_task_id: null, is_parent: 1, files: [],
})
const EXTRA = [card(BLOCKER, RED === 'no-blocker' ? 'note' : 'blocker', '@HUM-1 Rotate the prd key?'), card(NOTE, 'note', 'FYI the build is green')]
/* the developer's me(): role + permission list, so tenantOwner is false */
const DEVELOPER = { role: 'developer', permissions: ['topics.read', 'notes.send', 'topics.manage'] }

/** the channel with the two cards; me = null (the owner) unless `as` */
async function openAlerts(browser, as) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Owner', email: 'owner@example.com', t: 'mock' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(s.extra))
      if (s.as) localStorage.setItem('spool.mock.me', JSON.stringify(s.as))
    } catch { /* about:blank */ }
  }, { extra: EXTRA, as })
  await setPageViewport(p, { width: 1280, height: 800 })
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${NOTE}"]`, { timeout: NAV_TIMEOUT }).catch(() => null)
  await sleep(500)
  return { p, ctx, errors }
}

/** the item ids of a card's menu, then the menu closed again unless keep */
async function menuOf(p, id, keep = false) {
  await p.evaluate((i) => {
    const b = [...document.querySelectorAll(`article.msg[data-msg-id="${i}"] [data-testid=msg-menu-btn]`)].find((x) => x.getBoundingClientRect().width > 0)
    b?.click()
  }, id)
  await until(p, () => Boolean(document.querySelector('[data-testid^="msg-menu-"][role=menuitem]')), null, 5000)
  const ids = await p.$$eval('[role=menuitem][data-testid^="msg-menu-"]', (els) => els.map((e) => e.getAttribute('data-testid').slice('msg-menu-'.length)))
  if (!keep) await p.keyboard.press('Escape')
  await sleep(200)
  return ids
}

/* away to Performance and back to General: the value is read again from the mock hub */
async function reopen(p) {
  await p.click('[data-test=tenant-settings-nav-performance]')
  await until(p, () => location.pathname.endsWith('/tenant-settings/performance'), null, 10000)
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector(MINUTES, { visible: true, timeout: 10000 }).catch(() => null)
  await sleep(300)
}

/* step 4: the document and every element under root */
const sideways = (p, root) => p.evaluate((r) => {
  const wide = []
  for (const el of document.querySelector(r)?.querySelectorAll('*') || []) {
    if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.tagName}.${el.className}`)
  }
  const d = document.documentElement
  return { doc: d.scrollWidth - d.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, wide }
}, root)
const flat = (s) => s.doc <= 1 && s.docLeft === 0 && s.wide.length === 0

/* step 5: the visible controls' heights */
const heights = (p, sel) => p.$$eval(sel, (els) => els.filter((e) => e.offsetParent !== null)
  .map((e) => ({ id: e.getAttribute('data-test') || e.tagName, h: Math.round(e.getBoundingClientRect().height * 10) / 10 })))
const tapOk = (hs) => hs.length > 0 && hs.every((c) => c.h >= 44 && c.h <= 48)

const server = await startServer()
const browser = await launch()
try {
  /* ---- desktop ---- */
  const d = await open(browser, { width: 1280, height: 800 }, '/tenant-settings/general')
  const p = d.p
  const shown = await p.waitForSelector(`${BLOCK} ${MINUTES}`, { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  await sleep(300)
  const first = await value(p, MINUTES)
  ok('1 General shows the blocker -> issue block at the hub default, 3', shown && first === '3', { shown, first })

  await p.$eval(MINUTES, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(MINUTES, '10')
  if (RED !== 'no-save') await p.click('[data-test=tenant-blocker-issue-save]')
  const notice = await until(p, (s) => Boolean(document.querySelector(s)), '[data-test=tenant-blocker-issue-notice]', 5000)
  await reopen(p)
  const back = await value(p, MINUTES)
  ok('2 10 is saved and reads back as 10', notice && back === '10', { notice, back })

  await p.$eval(MINUTES, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(MINUTES, '1441')
  const disabled = await p.$eval('[data-test=tenant-blocker-issue-save]', (e) => e.disabled).catch(() => false)
  const overflow = await p.$eval(MINUTES, (e) => e.validity.rangeOverflow).catch(() => false)
  await p.click('[data-test=tenant-blocker-issue-save]').catch(() => {})
  await reopen(p)
  const kept = await value(p, MINUTES)
  ok('3 CONTROL: 1441 is refused (out of range) and nothing is saved', disabled && overflow && kept === '10', { disabled, overflow, kept })
  ok('desktop: no unexpected page errors', d.errors.length === 0, d.errors)
  await d.ctx.close()

  /* ---- the owner decides ---- */
  const o = await openAlerts(browser)
  const noteItems = await menuOf(o.p, NOTE)
  const blockerItems = await menuOf(o.p, BLOCKER, true)
  const offered = blockerItems.includes('make-issue')
  if (offered) await o.p.click('[data-testid=msg-menu-make-issue]')
  const opened = offered && await until(o.p, () => /^\?issue=SPL-\d+$/.test(location.search) && location.pathname.endsWith('/issues'), null, 10000)
  const key = opened ? await o.p.evaluate(() => new URLSearchParams(location.search).get('issue')) : ''
  const where = await o.p.evaluate(() => ({ url: location.pathname + location.search, err: document.querySelector('[data-testid=msg-ai-error]')?.textContent?.trim() || '' }))
  const made = key && await until(o.p, () => Boolean(document.querySelector('[data-test=issues-detail-title]')?.value), null, 10000)
    ? await o.p.evaluate(() => ({
      key: document.querySelector('[data-test=issues-detail-key]')?.textContent?.trim() || '',
      title: document.querySelector('[data-test=issues-detail-title]')?.value || '',
      side: (document.querySelector('[data-test=issues-detail-side]')?.innerText || '').toLowerCase(),
    }))
    : null
  ok('6 the owner: Make an issue on a blocker opens the new issue (todo, label blocker)',
    opened && made?.title === '@HUM-1 Rotate the prd key?' && /status\n(\d+-)?todo\n/.test(made.side) && /labels\n(.*\n)*blocker/.test(made.side),
    { offered, opened, key, made, where })
  ok('7 CONTROL: the owner\'s menu on a note has no Make an issue', noteItems.length > 0 && !noteItems.includes('make-issue'), noteItems)
  ok('owner: no unexpected page errors', o.errors.length === 0, o.errors)
  await o.ctx.close()
  const dev = await openAlerts(browser, DEVELOPER)
  const devItems = await menuOf(dev.p, BLOCKER)
  ok('8 CONTROL: a developer\'s menu on the blocker has no Make an issue', devItems.length > 0 && !devItems.includes('make-issue'), devItems)
  await dev.ctx.close()

  /* ---- phone matrix ---- */
  for (const vp of [{ width: 360, height: 780 }, { width: 390, height: 844 }]) {
    const spec = { ...vp, isMobile: true, hasTouch: true }
    for (const theme of ['dark', 'light']) {
      for (const level of [1, 3, 5]) {
        const tag = `${vp.width}x${vp.height} ${theme} L${level}`
        const g = await open(browser, spec, '/tenant-settings/general', { theme, level })
        const on = await g.p.waitForSelector(`${BLOCK} [data-test=tenant-blocker-issue-save]`, { timeout: NAV_TIMEOUT }).then(() => true, () => false)
        await g.p.$eval(BLOCK, (e) => e.scrollIntoView({ block: 'start' })).catch(() => {})
        await sleep(200)
        const sx = await sideways(g.p, '[data-test=tenant-settings]')
        ok(`4 ${tag}: no sideways scroll`, on && flat(sx), sx)
        const hs = await heights(g.p, `${BLOCK} input, ${BLOCK} button`)
        ok(`5 ${tag}: controls 44..48 px`, tapOk(hs), hs)
        ok(`${tag}: no unexpected page errors`, g.errors.length === 0, g.errors)
        await g.ctx.close()
      }
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nblocker-issue-setting: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
