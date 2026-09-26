// SPL-942 — live proof. Card, Tab, replies link, Tab, row menu.
// Shift+Tab walks back. The link is painted just left of the icons, with
// the emoji between it and the menu. A card with no replies link tabs to
// its next control (the menu), not a stray element.
//
//   BASE=https://<wui-host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] [CHANNEL=lobby]
//     node tests/e2e/replies-tab-live.proof.mjs
//
// The password is read from PW_FILE and never printed.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable')
}

const need = (k) => {
  if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) }
  return process.env[k]
}
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: !!ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function settle(p) {
  let last = Date.now()
  const mark = () => { last = Date.now() }
  p.on('framenavigated', mark)
  const t0 = Date.now()
  while (Date.now() - t0 < 8000) {
    if (Date.now() - last > 700) break
    await sleep(150)
  }
  p.off('framenavigated', mark)
}

async function goto(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
      await settle(p)
      return
    } catch (e) { last = e; await sleep(1500) }
  }
  throw last
}

async function pressTab(p, shift) {
  if (shift) await p.keyboard.down('Shift')
  await p.keyboard.press('Tab')
  if (shift) await p.keyboard.up('Shift')
  await sleep(40)
}

const focusOf = () => {
  const el = document.activeElement
  const card = el && el.closest ? el.closest('article.msg') : null
  return {
    tag: el && el.tagName,
    test: el && el.getAttribute && el.getAttribute('data-test'),
    testid: el && el.getAttribute && el.getAttribute('data-testid'),
    msgId: card ? card.getAttribute('data-msg-id') : (el && el.getAttribute && el.getAttribute('data-msg-id')),
    isCard: !!(el && el.matches && el.matches('article.msg')),
  }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 90000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--force-device-scale-factor=1'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await goto(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/channel/' + CHANNEL))
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 20000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('signed in', signedIn, { url: p.url().replace(BASE, '') })
  if (!signedIn) throw new Error('not signed in')

  for (const vp of [{ width: 1280, height: 800, name: 'desktop' }, { width: 390, height: 844, name: 'phone' }]) {
    await p.setViewport(vp)
    await goto(p, BASE + '/channel/' + encodeURIComponent(CHANNEL))
    const has = await p.waitForSelector('article.msg [data-test=topic-replies]', { timeout: 20000 }).then(() => true, () => false)
    step(`${vp.name}: a channel card has a replies link`, has)
    if (!has) throw new Error('no replies')
    const focused = await p.evaluate(() => {
      const card = [...document.querySelectorAll('article.msg')].find((a) => a.querySelector('[data-test=topic-replies]'))
      card.focus({ preventScroll: true })
      return { msgId: card.getAttribute('data-msg-id'), onCard: document.activeElement === card }
    })
    step(`${vp.name}: the card took focus`, focused.onCard, focused)
    await pressTab(p, false)
    const first = await p.evaluate(focusOf)
    step(`${vp.name}: Tab lands on that card's replies link`,
      first.test === 'topic-replies' && first.msgId === focused.msgId, { ...first, want: focused.msgId })
    await pressTab(p, false)
    const menu = await p.evaluate(focusOf)
    step(`${vp.name}: the next Tab is that card's row menu`,
      menu.testid === 'msg-menu-btn' && menu.msgId === focused.msgId, menu)
    await pressTab(p, true)
    const back = await p.evaluate(focusOf)
    step(`${vp.name}: Shift+Tab returns to the replies link`, back.test === 'topic-replies' && back.msgId === focused.msgId, back)
    await pressTab(p, true)
    const card = await p.evaluate(focusOf)
    step(`${vp.name}: Shift+Tab returns to the card`, card.isCard && card.msgId === focused.msgId, card)
    const box = await p.evaluate((id) => {
      const root = document.querySelector(`article.msg[data-msg-id="${id}"]`)
      const link = root && root.querySelector('[data-test=topic-replies]')
      const emoji = root && root.querySelector('[data-testid=msg-emoji-btn]')
      const menuBtn = root && root.querySelector('[data-testid=msg-menu-btn]')
      if (!link || !emoji || !menuBtn) return { missing: true }
      const b = link.getBoundingClientRect()
      const e = emoji.getBoundingClientRect()
      const m = menuBtn.getBoundingClientRect()
      return {
        linkThenEmoji: b.right <= e.left + 2,
        emojiThenMenu: e.right <= m.left + 2,
        sameRow: Math.abs((b.top + b.height / 2) - (m.top + m.height / 2)) < 10,
      }
    }, focused.msgId)
    step(`${vp.name}: the link sits just left of the icons, emoji between it and the menu`,
      !box.missing && box.linkThenEmoji && box.emojiThenMenu && box.sameRow, box)
    await p.screenshot({ path: `${OUT}/${vp.name}-replies.png` }).catch(() => {})

    await goto(p, BASE + '/lobby')
    const bare = await p.waitForFunction(() => [...document.querySelectorAll('[data-pane=msgs] article.msg')].some((c) => !c.querySelector('[data-test=topic-replies]')), { timeout: 20000 }).then(() => true, () => false)
    step(`${vp.name}: a card without a replies link is on screen`, bare)
    if (!bare) continue
    const ctrl = await p.evaluate(() => {
      const card = [...document.querySelectorAll('[data-pane=msgs] article.msg')].find((c) => !c.querySelector('[data-test=topic-replies]'))
      card.focus({ preventScroll: true })
      const next = card.querySelector('button:not([disabled])')
      return {
        onCard: document.activeElement === card,
        msgId: card.getAttribute('data-msg-id'),
        next: next ? (next.getAttribute('data-testid') || next.getAttribute('data-test') || next.tagName) : null,
      }
    })
    await pressTab(p, false)
    const landed = await p.evaluate(focusOf)
    step(`${vp.name}: Tab on a card without replies lands on its menu`,
      landed.msgId === ctrl.msgId && landed.testid === 'msg-menu-btn' && landed.testid === ctrl.next, { ...landed, want: ctrl.next })
    await p.screenshot({ path: `${OUT}/${vp.name}-bare.png` }).catch(() => {})
  }
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e).slice(0, 800) })
} finally {
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
if (failed) { console.error(`FAIL ${failed} step(s)`); process.exit(1) }
console.log('PASS replies first tab stop')
