// SPL-72 live proof of "Delete channel" against a deployed WUI + hub
// (channels-v1 §5.4). It WRITES: it creates one channel and deletes it (a
// soft delete; do_spl_channel_restore brings it back).
//
// Session B (B_EMAIL, a member of TENANT) signs in first: its human id is
// read from /v1/view/me. Session A (A_EMAIL, holds channels.manage) creates
// a channel through the New channel form and adds B through the API.
//   B: right-click on the channel row opens its menu with Properties but NO
//      Delete channel; DELETE /v1/channels/<c> from B's page is 403, and on
//      #lobby 409.
//   A: right-click on the same row shows Delete channel; it opens a confirm;
//      Confirm deletes; the row leaves A's sidebar, and leaves B's open
//      sidebar WITHOUT a reload (the channel_deleted frame); A's second
//      DELETE and GET members are 404; after a reload B still has no row.
//
//   BASE=https://dev.<domain> API=https://api.dev.<domain> TENANT=t1 \
//   A_EMAIL=<creator test account> A_PW_FILE=<0600 file> \
//   B_EMAIL=<other test account> B_PW_FILE=<0600 file> OUT=<dir> \
//     node tests/e2e/channel-delete-live.proof.mjs
//
// CREATOR_ONLY=1 runs the A steps alone (a tenant with one test member, e.g.
// prd e2e); B_* are then not needed. With CHANNEL=<slug> of a channel A
// already created, the create step is skipped and that channel is deleted.
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
const SLUG = process.env.CHANNEL || 'spl72-proof-' + stamp
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
/** One hub call from inside the page: the session cookie rides along. */
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
/** The ids of the visible items in the open row menu of the channel row. */
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

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  // Metadata only: a node fetch that cannot dial (IPv6 on some boxes) must not stop the proof.
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch((e) => ({ error: String(e) }))
  res.version = await fetch(API + '/version').then((r) => r.json()).catch((e) => ({ error: String(e) }))

  let b = null
  let bId = ''
  if (!CREATOR_ONLY) {
    b = await signIn(await browser.createBrowserContext(), B_EMAIL, 'B_PW_FILE')
    const bMe = await call(b.p, 'GET', '/v1/view/me')
    bId = bMe.json && bMe.json.human_id
    step('B1 other member signs in', b.ok && /^HUM-\d+$/.test(bId || ''), { human_id: bId, role: bMe.json && bMe.json.role })
  }

  const a = await signIn(await browser.createBrowserContext(), A_EMAIL, 'A_PW_FILE')
  const aMe = await call(a.p, 'GET', '/v1/view/me')
  const aId = aMe.json && aMe.json.human_id
  step('A1 creator signs in', a.ok && /^HUM-\d+$/.test(aId || '') && aId !== bId, { human_id: aId, role: aMe.json && aMe.json.role })

  // A creates the channel through the New channel form.
  const existing = process.env.CHANNEL ? await call(a.p, 'GET', `/v1/channels/${SLUG}/members`) : { status: 404 }
  if (existing.status === 200) {
    step('A2 the creator\'s channel already exists (CHANNEL=): not created again', existing.json && existing.json.created_by === aId, { created_by: existing.json && existing.json.created_by })
  } else {
  await channelsTab(a.p)
  await a.p.$eval('[data-testid="create-channel"]', (x) => x.click())
  await a.p.waitForSelector('[data-testid="create-channel-name"]', { visible: true, timeout: 10000 })
  await a.p.type('[data-testid="create-channel-name"]', SLUG)
  await a.p.click('[data-testid="create-channel-submit"]')
  await a.p.waitForFunction((s) => location.pathname.endsWith('/channel/' + s), { timeout: 20000 }, SLUG).catch(() => null)
  step('A2 creator makes the channel in the New channel form', a.p.url().endsWith('/channel/' + SLUG), { url: a.p.url() })
  }
  if (!CREATOR_ONLY) {
  const add = await call(a.p, 'POST', `/v1/channels/${SLUG}/members`, { human_id: bId })
  step('A3 creator adds the other member', add.status === 201, { status: add.status, error: add.error })

  // B: the row is there; its menu has no Delete; the API refuses B.
  await b.p.goto(BASE + '/channel/' + SLUG, { waitUntil: 'networkidle2' })
  await sleep(2500)
  const bItems = await rightClickRow(b.p)
  await b.p.screenshot({ path: `${OUT}/B-row-menu.png` })
  step('B2 CONTROL: the other member right-clicks the row and its menu opens with Properties', Array.isArray(bItems) && bItems.includes('properties'), { items: bItems })
  step('B3 the other member is NOT offered Delete channel', Array.isArray(bItems) && !bItems.includes('delete'), { items: bItems })
  await b.p.keyboard.press('Escape')
  const bDel = await call(b.p, 'DELETE', `/v1/channels/${SLUG}`)
  step('B4 DELETE from the other member is refused 403', bDel.status === 403 && bDel.error === 'forbidden', { status: bDel.status, error: bDel.error })
  const bLobby = await call(b.p, 'DELETE', '/v1/channels/lobby')
  step('B5 DELETE #lobby (a default channel) is refused 409', bLobby.status === 409 && bLobby.error === 'channel_public', { status: bLobby.status, error: bLobby.error })
  step('B6 the refused DELETE left the channel in place', await hasRow(b.p))
  }

  // A: Delete channel, confirm.
  await a.p.goto(BASE + '/channel/lobby', { waitUntil: 'networkidle2' })
  await sleep(2000)
  const aItems = await rightClickRow(a.p)
  await a.p.screenshot({ path: `${OUT}/A-row-menu.png` })
  step('A4 the creator right-clicks the row and sees Delete channel', Array.isArray(aItems) && aItems.includes('delete'), { items: aItems })
  await a.p.evaluate((slug) => {
    const btn = document.querySelector(`[data-testid="sidebar-row-menu"][data-menu-id="ch:${slug}"]`)
    btn.closest('.sidebar-row-menu').querySelector('[data-testid="sidebar-row-menu-delete"]').click()
  }, SLUG)
  const body = await a.p.waitForSelector('[data-testid="delete-channel-body"]', { visible: true, timeout: 10000 }).then((e) => e.evaluate((x) => x.textContent.trim())).catch(() => '')
  await a.p.screenshot({ path: `${OUT}/A-confirm.png` })
  step('A5 Delete channel opens a confirm and deletes nothing yet', body.includes(SLUG) && await hasRow(a.p), { body })
  await a.p.click('[data-testid="delete-channel-confirm"]')
  const aGone = await a.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 15000 }, rowSel).then(() => true).catch(() => false)
  const dialogGone = !(await a.p.$('[data-testid="delete-channel-body"]'))
  await a.p.screenshot({ path: `${OUT}/A-after.png` })
  step('A6 Confirm deletes: the row leaves the creator\'s sidebar and the dialog closes', aGone && dialogGone)

  if (!CREATOR_ONLY) {
  const bGone = await b.p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 15000 }, rowSel).then(() => true).catch(() => false)
  await b.p.screenshot({ path: `${OUT}/B-after-live.png` })
  step('B7 the other member\'s open sidebar drops the row live, without a reload', bGone)
  }

  const again = await call(a.p, 'DELETE', `/v1/channels/${SLUG}`)
  const members = await call(a.p, 'GET', `/v1/channels/${SLUG}/members`)
  step('A7 the deleted channel is gone for the creator too: DELETE 404, GET members 404', again.status === 404 && members.status === 404, { delete: again.status, members: members.status })
  const lobby = await call(a.p, 'DELETE', '/v1/channels/lobby')
  step('A8 DELETE #lobby (a default channel) is refused 409, even for the creator of another channel', lobby.status === 409 && lobby.error === 'channel_public', { status: lobby.status, error: lobby.error })
  if (!CREATOR_ONLY) {
  await b.p.reload({ waitUntil: 'networkidle2' })
  await sleep(2500)
  await channelsTab(b.p)
  step('B8 after a reload the other member still has no row', !(await hasRow(b.p)))
  }
} catch (e) {
  step('proof crashed', false, { error: String(e && e.stack || e) })
} finally {
  await browser.close()
  res.ok = res.steps.length > 0 && res.steps.every((s) => s.ok)
  writeFileSync(`${OUT}/channel-delete-live.json`, JSON.stringify(res, null, 2))
  console.log(res.ok ? 'ALL PASS' : 'FAILED', `${OUT}/channel-delete-live.json`)
  process.exit(res.ok ? 0 : 1)
}
