// CLE-3493 proof of the channel properties People dropdown, against the mock
// dev server or a deployed WUI:
//   (a) with the query empty the dropdown lists EVERY candidate, and every
//       option is really painted (not clipped by the dialog's scroll box);
//   (b) a partial id narrows the list to the matches; a control query that
//       matches nobody shows 0 options;
//   (c) picking one makes them a member (then they are removed again, so a
//       live tenant ends as it started).
//
//   BASE=<wui> OUT=<dir> [EMAIL=<member> PW_FILE=<0600 file>] [TENANT=t1] \
//     [CHANNEL=<channel id>] [CREATE=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/channel-people-live.proof.mjs
//
// Without EMAIL the page is used as served (the mock dev server). The password
// is read from PW_FILE and never printed. Exit 0 = every step PASS.
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
const EMAIL = process.env.EMAIL || ''
const TENANT = process.env.TENANT || 't1'
const WANT = process.env.CHANNEL || ''
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Option ids, and whether the browser really paints each one on top. */
const readOptions = (p) => p.evaluate(() => {
  const out = []
  for (const li of document.querySelectorAll('[data-testid^="channel-invite-pick-"]')) {
    const id = li.getAttribute('data-testid').slice('channel-invite-pick-'.length)
    li.scrollIntoView({ block: 'nearest' })
    const r = li.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + Math.min(20, r.width / 2), r.top + r.height / 2)
    out.push({ id, visible: r.height > 0 && !!hit && (hit === li || li.contains(hit)) })
  }
  const empty = document.querySelector('[data-testid="channel-invite-empty"]')
  // Where the list sits: right under its input, as wide as the field, inside
  // the dialog (the CLE-3493 defect painted it full width at the page bottom).
  const list = document.querySelector('[data-testid="channel-people-options"]')
  const field = document.querySelector('[data-testid="channel-people-search"]')?.closest('.invite-add__control')
  const dialog = document.querySelector('[data-testid="ui-dialog"]')
  let placed = null
  if (list && field && dialog) {
    const l = list.getBoundingClientRect()
    const f = field.getBoundingClientRect()
    const d = dialog.getBoundingClientRect()
    placed = {
      gap: Math.round(l.top - f.bottom),
      dx: Math.round(l.left - f.left),
      dw: Math.round(l.width - f.width),
      inDialog: l.left >= d.left && l.right <= d.right,
    }
    placed.ok = placed.gap >= 0 && placed.gap <= 12 && Math.abs(placed.dx) <= 2 && Math.abs(placed.dw) <= 2 && placed.inDialog
  }
  return { options: out, empty: empty ? empty.textContent.trim() : null, placed }
})
const members = (p) => p.$$eval('[data-testid="channel-invite-members"] > li > span:first-child', (els) => els.map((s) => s.textContent.trim()))

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let code = 1
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => null)
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  if (EMAIL) {
    const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', EMAIL)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    step('native sign-in', !!trig, { url: p.url() })
    if (!trig) throw new Error('sign-in failed')
  } else {
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  }
  await p.waitForSelector('[data-testid="sidebar-tab-channels"]', { timeout: 30000 })
  await sleep(2000)
  await p.$eval('[data-testid="sidebar-tab-channels"]', (b) => b.click())
  await sleep(500)
  // The mock's channels are all default ones: make a private one to inspect
  // (CREATE=1 does the same on a live TEST tenant that has none).
  if ((!EMAIL && !WANT) || process.env.CREATE === '1') {
    await p.$eval('[data-testid="create-channel"]', (b) => b.click())
    await p.waitForSelector('[data-testid="create-channel-name"]', { timeout: 5000 })
    await p.type('[data-testid="create-channel-name"]', 'people-proof')
    await p.$eval('[data-testid="create-channel-submit"]', (b) => b.click())
    await sleep(1000)
  }
  // The first channel row whose menu offers Properties (or CHANNEL).
  const rows = await p.$$eval('[data-testid="sidebar-panel-channels"] .nav-row', (els) => els.map((e) => e.getAttribute('data-order')))
  let opened = ''
  for (const id of WANT ? [WANT] : rows) {
    const hit = await p.evaluate((key) => {
      const row = document.querySelector(`[data-testid="sidebar-panel-channels"] .nav-row[data-order="${key}"]`)
      if (!row) return false
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }))
      return true
    }, id)
    if (!hit) continue
    const item = await p.waitForSelector('[data-testid="sidebar-row-menu-properties"]', { timeout: 1500 }).catch(() => null)
    if (item) { await item.evaluate((b) => b.click()); opened = id; break }
    await p.keyboard.press('Escape')
  }
  step('channel properties dialog opens', !!opened, { channel: opened, rows })
  if (!opened) throw new Error('no channel with properties')
  await p.waitForSelector('[data-testid="channel-people-search"]', { timeout: 15000 })
  await sleep(1000)
  const before = await members(p)
  res.members = before

  // (a) empty query: the chevron opens the full list
  await p.click('[data-testid="channel-people-search-button"]')
  await sleep(500)
  const all = await readOptions(p)
  await p.screenshot({ path: `${OUT}/a-full-list.png` })
  const ids = all.options.map((o) => o.id)
  const hidden = all.options.filter((o) => !o.visible).map((o) => o.id)
  step('(a) empty query lists every candidate, none clipped', ids.length > 0 && hidden.length === 0 && !ids.some((id) => before.includes(id)),
    { n: ids.length, ids, hidden, empty: all.empty })
  step('(a) the list opens right under its input, inside the dialog', !!all.placed?.ok, { placed: all.placed })
  await p.keyboard.press('Escape')
  await sleep(300)
  step('Escape in the dropdown keeps the dialog open', !!(await p.$('[data-testid="channel-properties"]')))
  if (!(await p.$('[data-testid="channel-properties"]'))) throw new Error('dialog closed')

  // (b) partial query narrows; control query matches nobody
  const target = ids[ids.length - 1] || ''
  const partial = target.replace(/^HUM-/, '')
  const input = await p.$('[data-testid="channel-people-search"]')
  const retype = async (text) => {
    await input.evaluate((el) => el.select())
    await p.keyboard.press('Backspace')
    await input.type(text, { delay: 30 })
    await sleep(400)
  }
  await retype(partial)
  const narrowed = await readOptions(p)
  const nIds = narrowed.options.map((o) => o.id)
  step('(b) a partial id narrows to the matches', nIds.length > 0 && nIds.includes(target) && nIds.every((id) => id.includes(partial)) && narrowed.options.every((o) => o.visible),
    { query: partial, n: nIds.length, ids: nIds })
  await p.screenshot({ path: `${OUT}/b-narrowed.png` })
  await retype('zz-no-such-person')
  const none = await readOptions(p)
  step('(b) control: a query matching nobody shows 0 options', none.options.length === 0 && !!none.empty, { n: none.options.length, empty: none.empty })

  // (c) picking one makes them a member
  await retype(partial)
  const again = await readOptions(p)
  step('(b) typing again after a miss lists the matches again', again.options.some((o) => o.id === target), { query: partial, ids: again.options.map((o) => o.id), empty: again.empty })
  if (!again.options.some((o) => o.id === target)) {
    await p.screenshot({ path: `${OUT}/b-again.png` })
    await p.click('[data-testid="channel-people-search-button"]')
    await sleep(400)
  }
  await p.click(`[data-testid="channel-invite-pick-${target}"]`)
  await sleep(300)
  const addBtn = await p.$('[data-testid="channel-people-add"]')
  const addEnabled = addBtn ? await addBtn.evaluate((b) => !b.disabled) : false
  if (addEnabled) await addBtn.click()
  await p.waitForSelector(`[data-testid="channel-member-remove-${target}"]`, { timeout: 10000 }).catch(() => null)
  const after = await members(p)
  const err = await p.$eval('[data-testid="channel-invite-error"]', (e) => e.textContent.trim()).catch(() => '')
  step('(c) picking one adds them as a member', !!target && after.includes(target), { target, members: after, error: err, needed_add_button: addEnabled })
  await p.screenshot({ path: `${OUT}/c-added.png` })
  if (after.includes(target) && !before.includes(target)) {
    await p.click(`[data-testid="channel-member-remove-${target}"]`)
    await sleep(1500)
    res.restored = !(await members(p)).includes(target)
  }
  code = res.steps.every((s) => s.ok) ? 0 : 1
} catch (e) {
  step('run', false, { error: String((e && e.message) || e) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(code === 0 ? 'ALL PASS' : 'FAILED')
process.exit(code)
