// HUM-10 (t1 43ebdf0b) live proof against a deployed WUI: "one should be also
// able to Ctrl + V files in the issues descriptions and the comments, add the
// attach button as well there". Signed in, at 1440 px:
//  C. a picture pasted (Ctrl+V: a clipboard holding a File) into an issue's
//     comment box shows as a chip; Enter posts the comment with it; the
//     comment shows the file card and the picture opens
//  D. a picture pasted into the issue's description editor is stored and named
//     in the description; the saved description shows the file card, it opens
//  plus: both boxes show their attach button
// It creates ONE probe issue ("[spool-probe] issue files <run>") unless ISSUE
// names one in TENANT, and writes only there. Screenshots and results.json to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> [ISSUE=<key in TENANT>]
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issue-files-live.proof.mjs
//
// Writes only when the session's tenant AND the page host's tenant are
// TENANT. The password is read from PW_FILE and never printed.
// Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
let ISSUE = process.env.ISSUE || ''
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
async function until(fn, ms) {
  const end = Date.now() + ms
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() > end) return v
    await sleep(400)
  }
}

const run = Date.now().toString(36)
const COMMENT = '[data-test=issues-comment]'
const INPUT = '[data-test=issues-comment-input]'
const DESC = '[data-test=issues-detail-body]'
const DESC_VIEW = '[data-test=issues-detail-rendered]'
/* a real 1x1 PNG: the card previews it only when the magic bytes say picture */
const PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

/** Ctrl+V of a clipboard that holds one picture, on the element `sel` */
const pasteFile = (p, sel, name) => p.evaluate((sel, name, b64) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.focus()
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  const dt = new DataTransfer()
  dt.items.add(new File([bytes], name, { type: 'image/png' }))
  return !el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }))
}, sel, name, PNG_B64)

/** the last picture card under `scope` opens the viewer, then it closes */
async function pictureOpens(p, scope, shot) {
  const all = await p.$$(`${scope} [data-test=file-preview]`)
  const btn = all[all.length - 1]
  if (!btn) return false
  await btn.click()
  const open = await p.waitForSelector('[data-test=file-viewer] img', { visible: true, timeout: 8000 }).then(() => true, () => false)
  if (open && shot) await p.screenshot({ path: shot })
  await p.click('[data-testid=ui-dialog-close]').catch(() => {})
  await p.waitForSelector('[data-test=file-viewer]', { hidden: true, timeout: 3000 }).catch(() => {})
  return open
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok)
  if (!ok) throw new Error('not signed in')
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
  step('the session AND the page host are in TENANT', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)

  await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: 30000 })
  await sleep(800)
  if (!ISSUE) {
    const title = `[spool-probe] issue files ${run}`
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    ISSUE = await until(() => p.evaluate((want) => {
      const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
      return !document.querySelector('[data-test=issues-newrow]') && r ? r.getAttribute('data-key') : null
    }, title), 15000) || ''
    step('a probe issue is created', Boolean(ISSUE), { issue: ISSUE, title })
    if (!ISSUE) throw new Error('no probe issue')
  }
  res.issue = ISSUE
  await p.goto(BASE + `/issues?issue=${encodeURIComponent(ISSUE)}`, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector(INPUT, { visible: true, timeout: 30000 })
  await sleep(600)
  const buttons = await p.evaluate(() => ({ comment: Boolean(document.querySelector('[data-test=issues-comment-attach]')) }))
  step('the comment box has its attach button', buttons.comment, buttons)

  // C. a picture pasted into the comment box
  const cname = `issue-comment-paste-${run}.png`
  const pasted = await pasteFile(p, INPUT, cname)
  const chip = await until(() => p.evaluate((n) => [...document.querySelectorAll('[data-test=issues-comment-file]')].some((c) => c.textContent.includes(n)), cname), 8000)
  step('C1 Ctrl+V of a picture attaches it to the comment box', pasted && Boolean(chip), { pasted, chip })
  await p.type(INPUT, '[spool-probe] a pasted picture')
  await p.screenshot({ path: `${OUT}/comment-chip.png` })
  await p.keyboard.press('Enter')
  const posted = await until(() => p.evaluate((sel, n) => [...document.querySelectorAll(sel)].some((c) => c.querySelector('.file-card') && c.innerText.includes(n)), COMMENT, cname), 20000)
  step('C2 the posted comment carries the pasted picture', Boolean(posted))
  await sleep(800)
  const last = (await p.$$(COMMENT)).pop()
  if (last) await last.scrollIntoView().catch(() => {})
  await p.screenshot({ path: `${OUT}/comment-with-file.png` })
  step('C3 the comment\'s picture opens', Boolean(posted) && await pictureOpens(p, COMMENT, `${OUT}/comment-file-open.png`))

  // D. a picture pasted into the description editor
  await p.click(DESC_VIEW).catch(() => {})
  await p.waitForSelector(DESC, { visible: true, timeout: 8000 }).catch(() => {})
  const dbtn = await p.$('[data-test=issues-desc-attach]')
  step('the description editor has its attach button', Boolean(dbtn))
  const dname = `issue-desc-paste-${run}.png`
  const dpasted = await pasteFile(p, DESC, dname)
  const named = await until(() => p.evaluate((sel, n) => (document.querySelector(sel)?.value || '').includes(`[${n}](`), DESC, dname), 20000)
  step('D1 Ctrl+V of a picture stores it and names it in the description', dpasted && Boolean(named), { dpasted, named })
  await p.screenshot({ path: `${OUT}/description-editing.png` })
  await p.$eval(DESC, (el) => el.blur()).catch(() => {})
  const shown = await until(() => p.evaluate((n) => [...document.querySelectorAll('[data-test=issues-desc-file]')].some((c) => c.innerText.includes(n)), dname), 20000)
  step('D2 the saved description shows the picture', Boolean(shown))
  await sleep(600)
  await p.screenshot({ path: `${OUT}/description-with-file.png` })
  step('D3 the description\'s picture opens', Boolean(shown) && await pictureOpens(p, '[data-test=issues-desc-file]', `${OUT}/description-file-open.png`))
} catch (e) {
  step('run', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(`${res.steps.length - failed}/${res.steps.length} passed; issue ${res.issue || '-'}; build ${res.build && res.build.commit || '-'}; out ${OUT}`)
  process.exit(failed ? 1 : 0)
}
