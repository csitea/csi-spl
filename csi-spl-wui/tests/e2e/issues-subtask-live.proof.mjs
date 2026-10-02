// SPL-974 — live proof, signed in: the plus+hierarchy icon opens
// the subtask dialog on a deployed WUI + hub.
//
// Owner, 2026-09-26: "there should be just a plus with hierarchical icon for
// adding subtasks, not an add subtask button, this should open a modal dialog
// with the subtasks UI".
//
// Steps (n = 1 per run):
//   1. an issue (level 2) is created in the UI, or ISSUE=<key> is opened
//   2. the subtasks section has one icon button (aria-label + title), no
//      inline title box and no Add subtask button
//   3. the icon opens a modal; focus is on the title; Tab stays inside;
//      Esc closes it and focus returns to the icon
//   4. a click on the backdrop closes it
//   5. with READ_ONLY=1 the run stops here and writes nothing
//   6. title + Enter creates it: the dialog closes, the subtask lists in the
//      pane at once, and the hub holds it as a level-3 subtask of the issue
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> [ISSUE=<key>] [READ_ONLY=1]
//   (READ_ONLY=1 without ISSUE opens the first level-2 row)
//     node tests/e2e/issues-subtask-live.proof.mjs
//
// Refuses to write unless the session's tenant AND the page host's tenant are
// TENANT. The password is read from PW_FILE and never printed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const run = Date.now().toString(36)
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

/** goto / reload that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      if (url) await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      else await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
}

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
  /* Nothing is written unless BOTH the session's tenant (claim t) and the
     tenant the page writes to are TENANT. With tenant hosts on (SPL-959) the
     WUI writes to the page host's tenant (useSpoolApi hostTenant: the apex is
     t1) whatever the claim says: on 2026-09-26 this proof wrote SPL-967..970
     into prd t1 from the apex, one run with the claim reading e2e. On prd run
     it at https://<tenant>.<domain>. */
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

const ISSUE = process.env.ISSUE || ''
const READ_ONLY = process.env.READ_ONLY === '1'
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
const dialogGone = (p) => p.waitForFunction(() => !document.querySelector('[data-testid=ui-dialog]'), { timeout: 5000 }).then(() => true, () => false)
const onOpener = (p) => p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-test') === 'issues-subtask-open')
async function openDialog(p) {
  await p.click('[data-test=issues-subtask-open]')
  return p.waitForFunction(() => document.activeElement && document.activeElement.getAttribute('data-test') === 'issues-subtask-input', { timeout: 5000 }).then(() => true, () => false)
}

try {
  const p = await signIn(browser)
  let key = ISSUE
  if (key) {
    await nav(p, `${BASE}/issues?issue=${encodeURIComponent(key)}`)
    await p.waitForSelector('[data-test=issues-subtask-open]', { visible: true, timeout: 30000 })
    step('1 the issue opens', true, { key })
  } else if (READ_ONLY) {
    // nothing to write: open the first level-2 row the sheet shows
    await nav(p, BASE + '/issues')
    key = await until(() => p.evaluate(() => {
      const row = document.querySelector('[data-test=issues-row][data-level="2"]')
      return row ? row.getAttribute('data-key') : ''
    }), 30000)
    if (!key) throw new Error('no level-2 issue to open')
    await nav(p, `${BASE}/issues?issue=${encodeURIComponent(key)}`)
    await p.waitForSelector('[data-test=issues-subtask-open]', { visible: true, timeout: 30000 })
    step('1 the first level-2 issue opens (read-only run)', true, { key })
  } else {
    await nav(p, BASE + '/issues')
    await p.waitForSelector('[data-test=issues-new]', { visible: true, timeout: 30000 })
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    const title = `Subtask proof ${run}`
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
    key = await until(() => p.evaluate((want) => {
      const t = document.querySelector('[data-test=issues-detail-title]')
      const k = document.querySelector('[data-test=issues-detail-key]')
      return !document.querySelector('[data-test=issues-create]') && t && t.value === want && k ? k.textContent.trim() : ''
    }, title), 30000)
    const hub = key ? await hubIssue(p, key) : {}
    step('1 an issue created in the UI is level 2', hub.kind === 'issue' && hub.level === 2, { key, kind: hub.kind, level: hub.level })
    if (!key) throw new Error('no key')
  }
  await p.waitForSelector('[data-test=issues-subtask-open]', { visible: true, timeout: 15000 })
  const ui = await p.evaluate(() => {
    const b = document.querySelector('[data-test=issues-subtask-open]')
    const sec = document.querySelector('[data-test=issues-subtasks]')
    const r = b.getBoundingClientRect()
    return { inline: sec.querySelectorAll('input, form').length, label: b.getAttribute('aria-label'), title: b.getAttribute('title'),
      icon: Boolean(b.querySelector('svg[data-icon=subtask-add]')), text: b.textContent.trim(), w: Math.round(r.width), h: Math.round(r.height) }
  })
  step('2 one icon button labelled Add subtask, no inline title box, no Add subtask button',
    ui.inline === 0 && ui.label === 'Add subtask' && ui.title === 'Add subtask' && ui.icon && ui.text === '', ui)
  await shot(p, '01-subtask-icon')

  const focused = await openDialog(p)
  /* where focus actually is, for a FAIL to name its thief */
  const activeAt = await p.evaluate(() => {
    const a = document.activeElement
    return a ? [a.tagName, a.getAttribute('data-test') || a.getAttribute('data-testid') || '', String(a.className || '').slice(0, 60)].join(' ') : ''
  })
  const modal = await p.$eval('[data-testid=ui-dialog]', (el) => ({ role: el.getAttribute('role'), modal: el.getAttribute('aria-modal'),
    title: el.querySelector('.ui-dialog__title').textContent.trim(),
    fields: [...el.querySelectorAll('[data-test^=issues-subtask-]')].map((x) => x.getAttribute('data-test')) }))
  await shot(p, '02-subtask-dialog')
  const trapped = []
  for (let n = 0; n < 9; n++) {
    await p.keyboard.press('Tab')
    trapped.push(await p.evaluate(() => Boolean(document.querySelector('[data-testid=ui-dialog]')?.contains(document.activeElement))))
  }
  await p.keyboard.press('Escape')
  const escClosed = await dialogGone(p)
  const escBack = await onOpener(p)
  const detailKept = Boolean(await p.$('[data-test=issues-detail]'))
  step('3 the icon opens a modal with focus on the title; Tab stays inside; Esc closes it and focus returns to the icon',
    focused && modal.role === 'dialog' && modal.modal === 'true' && trapped.every(Boolean) && escClosed && escBack && detailKept,
    { focused, activeAt, modal, trapped: trapped.filter(Boolean).length + '/' + trapped.length, escClosed, escBack, detailKept })

  await openDialog(p)
  await p.mouse.click(4, 4)
  const backdrop = await dialogGone(p)
  step('4 a click on the backdrop closes it', backdrop, { backdrop })

  if (READ_ONLY) {
    step('5 READ_ONLY: nothing written', true, { key })
  } else {
    await openDialog(p)
    const stitle = `Proof subtask ${run}`
    await p.type('[data-test=issues-subtask-input]', stitle)
    const t0 = Date.now()
    await p.keyboard.press('Enter')
    const enterClosed = await dialogGone(p)
    const skey = await until(() => p.evaluate((want) => {
      const el = [...document.querySelectorAll('[data-test=issues-subtask]')].find((x) => x.textContent.includes(want))
      return el ? el.getAttribute('data-key') : ''
    }, stitle), 15000)
    const listedMs = Date.now() - t0
    const shub = skey ? await hubIssue(p, skey) : {}
    step('6 Enter creates it: the dialog closes, it lists in the pane at once, and the hub holds a level-3 subtask of the issue',
      enterClosed && Boolean(skey) && shub.kind === 'subtask' && shub.parent === key && shub.level === 3,
      { key: skey, listedMs, kind: shub.kind, parent: shub.parent, level: shub.level })
    await sleep(600)
    await shot(p, '03-subtask-listed')
  }
  res.key = key
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
