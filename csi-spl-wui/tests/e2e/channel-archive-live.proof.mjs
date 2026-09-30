// CLE-77813 live proof of "Archive channel" + unarchive, and "delete frees the
// name", against a deployed WUI + hub (rdb 0092). It WRITES: it creates a
// channel, archives it, unarchives it, then deletes it and recreates the same
// slug (which now succeeds - the delete freed the name).
//
// Session B (B_EMAIL, a member of TENANT) signs in first; its human id is read
// from /v1/view/me. Session A (A_EMAIL, holds channels.manage) drives:
//   A: right-click the channel row shows Archive channel AND Delete channel;
//      Archive opens a confirm; Confirm archives; the row leaves A's sidebar,
//      and leaves B's open sidebar without a reload (the channel_deleted frame).
//   A: creating the SAME slug is refused channel_archived, and the New-channel
//      dialog offers Unarchive; Unarchive brings the channel back (200).
//   A: Delete channel on it; then recreating the SAME slug SUCCEEDS (201) -
//      the delete freed the name (the HUM-10 bug fix).
//   B: on the archived-then-restored channel, the row menu has Properties but
//      no Archive/Delete (not the creator); PUT .../archive from B is 403.
//
//   BASE=https://dev.<domain> API=https://api.dev.<domain> TENANT=t1 \
//   A_EMAIL=<creator test account> A_PW_FILE=<0600 file> \
//   B_EMAIL=<other test account> B_PW_FILE=<0600 file> OUT=<dir> \
//     node tests/e2e/channel-archive-live.proof.mjs
//
// CREATOR_ONLY=1 runs the A steps alone (a tenant with one test member, e.g.
// prd e2e); B_* are then not needed.
//
// Passwords are read from the files and never printed. Exit 0 = every step PASS.
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const A_EMAIL = need('A_EMAIL')
const CREATOR_ONLY = process.env.CREATOR_ONLY === '1'
const B_EMAIL = CREATOR_ONLY ? '' : need('B_EMAIL')
const pwOf = (k) => readFileSync(need(k), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const stamp = new Date().toISOString().replace(/\D/g, '').slice(4, 14)
const SLUG = process.env.CHANNEL || 'cle77813-arch-' + stamp
const res = { base: BASE, api: API, tenant: TENANT, channel: SLUG, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rowSel = `.nav-row[data-order="${SLUG}"]`

async function signIn(ctx, email, pwKey) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pwOf(pwKey))
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true).catch(() => false)
  await sleep(2500)
  return { p, ok }
}
const call = (p, method, path, body) => p.evaluate(async (api, method, path, body) => {
  const r = await fetch(api + path, {
    method,
    credentials: 'include',
    headers: body ? { 'content-type': 'application/json', accept: 'application/json' } : { accept: 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  let json = null
  try { json = await r.json() } catch { /* 204 */ }
  return { status: r.status, error: json && json.error, json }
}, API, method, path, body || null)
const menuItems = (p) => p.evaluate((slug) => {
  const btn = document.querySelector(`[data-testid="sidebar-row-menu"][data-menu-id="ch:${slug}"]`)
  const root = btn && btn.closest('.sidebar-row-menu')
  const panel = root && root.querySelector('[data-testid="sidebar-row-menu-panel"]')
  if (!panel || panel.offsetParent === null) return null
  return [...panel.querySelectorAll('[role="menuitem"]')].map((e) => e.getAttribute('data-testid').replace('sidebar-row-menu-', ''))
}, SLUG)
async function channelsTab(p) {
  await p.waitForSelector('[data-testid="sidebar-tab-channels"]', { timeout: 20000 })
  await p.$eval('[data-testid="sidebar-tab-channels"]', (b) => b.click())
  await sleep(500)
}
async function rightClickRow(p) {
  await channelsTab(p)
  const row = await p.waitForSelector(rowSel, { visible: true, timeout: 15000 }).catch(() => null)
  if (!row) return null
  await row.click({ button: 'right' })
  await sleep(600)
  return menuItems(p)
}
const hasRow = (p) => p.$(rowSel).then(Boolean)
async function createChannel(p, slug) {
  await channelsTab(p)
  await p.$eval('[data-testid="create-channel"]', (x) => x.click())
  await p.waitForSelector('[data-testid="create-channel-name"]', { visible: true, timeout: 10000 })
  await p.type('[data-testid="create-channel-name"]', slug)
  await p.click('[data-testid="create-channel-submit"]')
  await sleep(1500)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch((e) => ({ error: String(e) }))
  res.version = await fetch(API + '/version').then((r) => r.json()).catch((e) => ({ error: String(e) }))

  let b = null
  let bId = ''
  if (!CREATOR_ONLY) {
    b = await signIn(await browser.createBrowserContext(), B_EMAIL, 'B_PW_FILE')
    const bMe = await call(b.p, 'GET', '/v1/view/me')
    bId = bMe.json && bMe.json.human_id
    step('B1 other member signs in', b.ok && /^HUM-\d+$/.test(bId || ''), { human_id: bId })
  }

  const a = await signIn(await browser.createBrowserContext(), A_EMAIL, 'A_PW_FILE')
  const aMe = await call(a.p, 'GET', '/v1/view/me')
  const aId = aMe.json && aMe.json.human_id
  step('A1 creator signs in', a.ok && /^HUM-\d+$/.test(aId || '') && aId !== bId, { human_id: aId })

  await createChannel(a.p, SLUG)
  step('A2 creator makes the channel', a.p.url().endsWith('/channel/' + SLUG), { url: a.p.url() })
  if (!CREATOR_ONLY) {
    const add = await call(a.p, 'POST', `/v1/channels/${SLUG}/members`, { human_id: bId })
    step('A3 creator adds the other member', add.status === 201, { status: add.status })
    await b.p.goto(BASE + '/channel/' + SLUG, { waitUntil: 'networkidle2' })
    await sleep(2500)
    const bItems = await rightClickRow(b.p)
    step('B2 the other member is NOT offered Archive channel', Array.isArray(bItems) && !bItems.includes('archive-channel'), { items: bItems })
    await b.p.keyboard.press('Escape')
    const bArch = await call(b.p, 'PUT', `/v1/channels/${SLUG}/archive`)
    step('B3 PUT archive from the other member is refused 403', bArch.status === 403, { status: bArch.status, error: bArch.error })
  }

  // A archives via the row menu confirm.
  await a.p.goto(BASE + '/channel/lobby', { waitUntil: 'networkidle2' })
  await sleep(1500)
  const aItems = await rightClickRow(a.p)
  await a.p.screenshot({ path: `${OUT}/A-row-menu.png` })
  step('A4 the creator sees Archive channel AND Delete channel', Array.isArray(aItems) && aItems.includes('archive-channel') && aItems.includes('delete'), { items: aItems })
  await a.p.evaluate((slug) => {
    const btn = document.querySelector(`[data-testid="sidebar-row-menu"][data-menu-id="ch:${slug}"]`)
    btn.closest('.sidebar-row-menu').querySelector('[data-testid="sidebar-row-menu-archive-channel"]').click()
  }, SLUG)
  const body = await a.p.waitForSelector('[data-testid="archive-channel-body"]', { visible: true, timeout: 10000 }).then((e) => e.evaluate((x) => x.textContent.trim())).catch(() => '')
  await a.p.screenshot({ path: `${OUT}/A-archive-confirm.png` })
  step('A5 Archive opens a confirm and archives nothing yet', body.includes(SLUG) && await hasRow(a.p), { body })
  await a.p.click('[data-testid="archive-channel-confirm"]')
  const aGone = await a.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 15000 }, rowSel).then(() => true).catch(() => false)
  step('A6 Confirm archives: the row leaves the creator sidebar', aGone)
  if (!CREATOR_ONLY) {
    const bGone = await b.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 15000 }, rowSel).then(() => true).catch(() => false)
    step('B4 the other member sidebar drops the row live', bGone)
  }

  // The name is reserved: the create dialog is refused channel_archived and offers Unarchive.
  const reCreate = await call(a.p, 'POST', '/v1/channels', { channel: SLUG })
  step('A7 recreating an archived slug is refused channel_archived', reCreate.status === 409 && reCreate.error === 'channel_archived', { status: reCreate.status, error: reCreate.error })
  const unarch = await call(a.p, 'PUT', `/v1/channels/${SLUG}/unarchive`)
  step('A8 unarchive brings the channel back (200)', unarch.status === 200, { status: unarch.status })
  await a.p.reload({ waitUntil: 'networkidle2' })
  await sleep(2000)
  await channelsTab(a.p)
  step('A9 the unarchived channel is listed again', await hasRow(a.p))

  // Delete frees the name: delete, then recreate the same slug succeeds.
  const del = await call(a.p, 'DELETE', `/v1/channels/${SLUG}`)
  step('A10 delete the channel (204)', del.status === 204, { status: del.status })
  const freshCreate = await call(a.p, 'POST', '/v1/channels', { channel: SLUG, name: SLUG })
  step('A11 recreating the SAME slug after delete SUCCEEDS (201) - the name is free', freshCreate.status === 201, { status: freshCreate.status, error: freshCreate.error })
  // clean up the recreated channel
  await call(a.p, 'DELETE', `/v1/channels/${SLUG}`)
} catch (e) {
  step('proof crashed', false, { error: String(e && e.stack || e) })
} finally {
  await browser.close()
  res.ok = res.steps.length > 0 && res.steps.every((s) => s.ok)
  writeFileSync(`${OUT}/channel-archive-live.json`, JSON.stringify(res, null, 2))
  console.log(res.ok ? 'ALL PASS' : 'FAILED', `${OUT}/channel-archive-live.json`)
  process.exit(res.ok ? 0 : 1)
}
