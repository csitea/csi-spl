// SPL-1027 live proof (owner, prd t1 topic 89485c7a): on a deployed WUI +
// hub, at 1440 and 1024, the issue opens as a modal (open, edit, S picker,
// Esc, Back, deep link) and the sheet is CRUD in place (create in the top
// row, title / status / prio / deadline in their cells, delete with the one
// confirm - Cancel first as the control). The rows it makes are its own and
// it deletes them; the hub is asked that a deleted issue reads 404.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//     (prd: BASE=https://<tenant>.<domain> - the apex is t1's host; the run
//     refuses to write unless the session's tenant AND the page host are TENANT)
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [WIDTHS=1440,1024]
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issues-crud-modal-live.proof.mjs
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const WIDTHS = (process.env.WIDTHS || '1440,1024').split(',').map(Number)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const nav = (p, url) => p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 })
const until = async (fn, ms) => { const t0 = Date.now(); for (;;) { const v = await fn().catch(() => null); if (v || Date.now() - t0 > ms) return v; await sleep(300) } }
const row = (key) => `[data-test=issues-row][data-key="${key}"]`
const hubIssue = (p, key) => p.evaluate(async (api, k) => {
  const r = await fetch(`${api}/v1/view/issues/${k}`, { credentials: 'include' })
  return r.ok ? (await r.json()).issue : { status_code: r.status }
}, API, key)

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* the tenant-host guard of issues-live.proof.mjs (6c080b57): nothing is
     written unless the claim AND the page host's tenant are TENANT */
  const where = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const g = app && app.config.globalProperties
    const s = g && g.$pinia && g.$pinia.state.value.session
    const pub = (g && g.$config && g.$config.public) || null
    if (!pub || !s || !s.claims) return null
    const hosts = String(pub.tenantHosts || '0') === '1'
    let page = ''
    if (hosts) {
      const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
      const h = location.hostname.toLowerCase()
      page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
    }
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where, url: p.url() })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
const made = []
let page = null
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  res.hub = await (await fetch(API + '/version')).json().catch(() => null)
  const p = await signIn(browser)
  page = p
  const modalUp = () => p.$('[data-test=issues-detail]').then(Boolean)
  const waitModal = (up) => p.waitForFunction((u) => Boolean(document.querySelector('[data-test=issues-detail]')) === u, { timeout: 8000 }, up).then(() => true, () => false)
  const issueParam = () => p.evaluate(() => new URL(location.href).searchParams.get('issue'))

  for (const W of WIDTHS) {
    await p.setViewport({ width: W, height: 900 })
    await nav(p, BASE + '/issues')
    await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: 30000 })
    await sleep(800)
    const stamp = `spl1027 ${W} ${Date.now().toString(36)}`

    /* CREATE in the top row */
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
    await p.type('[data-test=issues-newrow-title]', stamp)
    await p.select('[data-test=issues-newrow-priority]', '3')
    await p.screenshot({ path: `${OUT}/newrow-${W}.png` })
    await p.focus('[data-test=issues-newrow-title]')
    await p.keyboard.press('Enter')
    const key = await until(() => p.evaluate((want) => {
      const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
      return !document.querySelector('[data-test=issues-newrow]') && r ? r.getAttribute('data-key') : null
    }, stamp), 10000)
    if (key) made.push(key)
    const hubNew = key ? await hubIssue(p, key) : null
    step(`${W} C: + and a title typed in the new top row, Enter: the row is stored (prio set before Enter)`, Boolean(key) && hubNew?.title === stamp && hubNew?.priority === 3, { key, hub: hubNew && { title: hubNew.title, priority: hubNew.priority } })
    if (!key) continue

    /* UPDATE in the cells */
    await p.click(`${row(key)} [data-test=issues-row-title-edit]`)
    await p.waitForSelector('[data-test=issues-row-title-input]', { visible: true, timeout: 5000 })
    await p.keyboard.press('End')
    await p.type('[data-test=issues-row-title-input]', ' edited')
    await p.keyboard.press('Enter')
    await p.click(`${row(key)} [data-test=issues-row-status]`)
    await p.waitForSelector('[data-test=issues-menu-option][data-value="wip"]', { visible: true, timeout: 5000 })
    await p.click('[data-test=issues-menu-option][data-value="wip"]')
    await sleep(600)
    await p.select(`${row(key)} [data-test=issues-row-priority]`, '2')
    await sleep(600)
    await p.click(`${row(key)} [data-test=issues-row-deadline]`)
    await p.waitForSelector('[data-test=issues-row-deadline-input]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-row-deadline-input]', '2026-10-02 07:45')
    await p.keyboard.press('Enter')
    const hubUp = await until(async () => { const i = await hubIssue(p, key); return i && i.title === `${stamp} edited` && i.status === 'wip' && i.priority === 2 && i.deadline ? i : null }, 10000)
    const cells = await p.$eval(row(key), (el) => ({
      title: el.querySelector('.issues-title')?.textContent.trim(), status: el.querySelector('[data-test=issues-row-status]')?.getAttribute('data-status'),
      prio: el.getAttribute('data-priority'), deadline: el.querySelector('[data-test=issues-row-deadline]')?.textContent.trim(),
    }))
    step(`${W} U: title, status, prio and deadline edited in their cells; the hub holds each`,
      Boolean(hubUp) && cells.title === `${stamp} edited` && cells.status === 'wip' && cells.prio === '2' && cells.deadline === '2026-10-02 07:45',
      { cells, hub: hubUp && { title: hubUp.title, status: hubUp.status, priority: hubUp.priority, deadline: hubUp.deadline } })
    await p.screenshot({ path: `${OUT}/sheet-${W}.png` })

    /* the MODAL */
    await p.click(`${row(key)} .issues-c-key`)
    const opened = await waitModal(true)
    const m = await p.evaluate(() => {
      const dlg = document.querySelector('[data-test=issues-detail]')?.closest('[data-testid=ui-dialog]')
      return { modal: dlg?.getAttribute('aria-modal'), title: dlg?.querySelector('.ui-dialog__title')?.textContent.trim(), focusIn: Boolean(dlg && dlg.contains(document.activeElement)),
        divider: Boolean(document.querySelector('[data-testid=pane-divider-issue]')), talk: Boolean(dlg?.querySelector('[data-test=issues-talk]')), w: Math.round(dlg?.getBoundingClientRect().width || 0) }
    })
    step(`${W} M1: a row click opens the issue as a modal (focus inside, discussion in it, no right pane), ?issue= in the URL`,
      opened && m.modal === 'true' && m.title === key && m.focusIn && !m.divider && m.talk && (await issueParam()) === key, m)
    await p.click('[data-test=issues-detail-rendered]')
    await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-body]', `described at ${W}`)
    await p.keyboard.press('Escape')
    const desc = await until(async () => { const i = await hubIssue(p, key); return i && i.description === `described at ${W}` ? i.description : null }, 10000)
    step(`${W} M2: the description is edited in the modal; Esc leaves the field (saved) and the modal stays`, Boolean(desc) && (await modalUp()), { desc })
    await p.keyboard.press('KeyS')
    const menuTop = await p.waitForSelector('[data-test=issues-menu][data-kind="status"]', { visible: true, timeout: 5000 }).then(() => p.evaluate(() => {
      const el = document.querySelector('[data-test=issues-menu]'); const r = el.getBoundingClientRect(); const top = document.elementFromPoint(r.left + r.width / 2, r.top + 12); return Boolean(top && el.contains(top))
    }), () => false)
    await p.screenshot({ path: `${OUT}/modal-${W}.png` })
    await p.keyboard.press('Escape')
    const menuGone = !(await p.$('[data-test=issues-menu]')) && (await modalUp())
    step(`${W} M3: S opens the Status picker above the modal; Esc closes the picker only`, menuTop && menuGone, { menuTop, menuGone })
    await p.waitForFunction((k) => new URL(location.href).searchParams.get('issue') === k, { timeout: 8000 }, key)
    await p.goBack()
    const backClosed = await waitModal(false)
    step(`${W} M4: browser Back closes the modal and stays on /issues`, backClosed && new URL(p.url()).pathname.endsWith('/issues') && (await issueParam()) === null, { url: p.url() })
    await nav(p, BASE + `/issues?issue=${key}`)
    const deep = await waitModal(true)
    await p.keyboard.press('Escape')
    const escClosed = await waitModal(false)
    step(`${W} M5: a deep link ?issue=${key} opens the modal; Esc closes it`, deep && escClosed && (await issueParam()) === null, { deep, escClosed })

    /* DELETE: Cancel (control), then Delete; the hub answers 404 after */
    await p.waitForSelector(`${row(key)} [data-test=issues-row-delete]`, { visible: true, timeout: 8000 })
    await p.click(`${row(key)} [data-test=issues-row-delete]`)
    await p.waitForSelector('[data-testid=issues-delete-cancel]', { visible: true, timeout: 5000 })
    await p.screenshot({ path: `${OUT}/delete-confirm-${W}.png` })
    await p.click('[data-testid=issues-delete-cancel]')
    await sleep(600)
    const kept = (await hubIssue(p, key))?.key === key && Boolean(await p.$(row(key)))
    await p.click(`${row(key)} [data-test=issues-row-delete]`)
    await p.waitForSelector('[data-testid=issues-delete-confirm]', { visible: true, timeout: 5000 })
    await p.click('[data-testid=issues-delete-confirm]')
    const gone = await until(() => p.$(row(key)).then((h) => (h ? null : true)), 8000)
    const hubGone = await hubIssue(p, key)
    if (gone && hubGone?.status_code === 404) made.splice(made.indexOf(key), 1)
    step(`${W} D: the row delete asks first (Cancel keeps it: control), Delete removes it and the hub reads 404`, kept && Boolean(gone) && hubGone?.status_code === 404, { kept, gone, hub: hubGone })
  }
  const noise = res.console.filter((c) => !/favicon|ResizeObserver loop|Failed to load resource/.test(c))
  step('no page errors', noise.length === 0, { noise: noise.slice(0, 5) })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  /* a row this run made and could not delete is named, never left silently */
  res.left_behind = made
  if (made.length) console.log('LEFT BEHIND (delete by hand):', made.join(' '))
  if (page) await page.screenshot({ path: `${OUT}/last.png` }).catch(() => {})
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
console.log(`${res.steps.length - failed}/${res.steps.length} PASS; build ${res.build && res.build.commit}; hub ${res.hub && res.hub.commit}`)
process.exit(failed ? 1 : 0)
