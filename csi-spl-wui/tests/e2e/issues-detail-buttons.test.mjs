// CLE-77854 (owner, topic 643330e5): "convert those right-click menu options
// [to] separate buttons, but at the end of the existing right side controls".
// The open issue's ☰ menu (Copy link / Archive / Delete) is gone; the three are
// their own icon buttons in the dialog header (> 820 px) and in the phone's top
// bar, each labelled, and each does what its menu item did: Copy link copies
// and says so, Archive asks the shared archive confirm, Delete asks the
// single-issue confirm. A regular member sees the same three (the hub is the
// authority, as it was for the menu). No horizontal scroll at 390.
//
//   pnpm run test:e2e:issues-detail-buttons
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues-detail-buttons
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, setPageViewport, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const WIDTHS = [1440, 390]
const BUTTONS = ['issues-detail-copy', 'issues-detail-archive', 'issues-detail-delete']
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* > 820 px: the header +, the new top row's title, Enter. A phone: the FAB
   opens the full-screen form, Create makes it, Back returns to the list. */
async function newIssue(p, W, title) {
  if (W <= 820) {
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
    const key = await p.waitForFunction(() => {
      const k = document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''
      return /^SPL-\d+$/.test(k) ? k : false
    }, { timeout: 5000 }).then((h) => h.jsonValue())
    await p.click('[data-test=issues-detail-back]')
    await waitModal(p, false)
    return key
  }
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
}
/* the issue's row (> 820 px) or card (a phone) */
const row = (key) => `[data-test=issues-row][data-key="${key}"], [data-test=issues-card][data-key="${key}"]`
const waitModal = (p, up) => p.waitForFunction((u) => Boolean(document.querySelector('[data-test=issues-detail]')) === u, { timeout: 5000 }, up).then(() => true, () => false)
async function openIssue(p, W, key) {
  await p.click(W > 820 ? `[data-test=issues-row][data-key="${key}"] .issues-c-key` : `[data-test=issues-card][data-key="${key}"]`)
  return waitModal(p, true)
}
async function closeIssue(p, W) {
  if (W > 820) await p.keyboard.press('Escape')
  else await p.click('[data-test=issues-detail-back]')
  return waitModal(p, false)
}
/* the header's action buttons, in DOM order, with their labels, and where they
   sit against the header's other controls */
const header = (p) => p.evaluate(() => {
  const group = document.querySelector('[data-test=issues-detail-actions]')
  if (!group) return null
  const btns = [...group.querySelectorAll('button')]
  const head = group.closest('header')
  const ctrls = head ? [...head.querySelectorAll('button')].filter((b) => b.offsetParent !== null) : []
  const last = ctrls.filter((b) => !b.classList.contains('ui-dialog__close')).at(-1)
  return {
    ids: btns.map((b) => b.getAttribute('data-test')),
    labels: btns.map((b) => [b.getAttribute('aria-label') || '', b.getAttribute('title') || '']),
    inHeader: Boolean(head),
    atEnd: Boolean(last) && group.contains(last),
    hamburger: Boolean(document.querySelector('[data-test=issues-detail] [aria-haspopup=menu], .ui-dialog__tools [aria-haspopup=menu]')),
    xScroll: document.documentElement.scrollWidth > window.innerWidth,
    allVisible: btns.every((b) => { const r = b.getBoundingClientRect(); return r.width > 0 && r.right <= window.innerWidth && r.left >= 0 }),
  }
})
const setMe = (p, me) => p.evaluate((me) => {
  const access = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')
  if (!access) return false
  access.me = me
  return true
}, me)

const shot = process.env.SHOT_DIR || '/tmp'
const server = await startServer()
const browser = await launch()
try {
  for (const W of WIDTHS) {
    console.log(`-- ${W} px`)
    const p = await browser.newPage()
    const vp = W > 820 ? { width: W, height: 900 } : { width: W, height: 844 }
    await setPageViewport(p, vp)
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e && e.message)))
    await p.evaluateOnNewDocument(() => {
      try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
    })
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
    const a = await newIssue(p, W, `buttons A ${W}`)
    const b = await newIssue(p, W, `buttons B ${W}`)

    // 1) the three buttons, in order, labelled, at the end of the header; no ☰
    await openIssue(p, W, a)
    const h = await header(p)
    await p.screenshot({ path: `${shot}/CLE-77854-issue-buttons-${W}.png` })
    ok(`1 ${W}: Copy link / Archive / Delete are header buttons, in order, at the end; no ☰ menu; no x-scroll`,
      Boolean(h) && JSON.stringify(h.ids) === JSON.stringify(BUTTONS) && h.inHeader && h.atEnd && !h.hamburger && !h.xScroll && h.allVisible, h)
    ok(`2 ${W}: each button has a tooltip and an aria-label`,
      Boolean(h) && JSON.stringify(h.labels.map(([l, t]) => l === t && l.length > 0)) === '[true,true,true]', h && h.labels)

    // 3) Copy link copies the issue's link and says so (a check + "Copied")
    await p.evaluate(() => {
      window.__copied = ''
      try { Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: (s) => { window.__copied = s; return Promise.resolve() } } }) } catch { /* read-only */ }
    })
    await p.click('[data-test=issues-detail-copy]')
    const copy = await p.waitForFunction(() => document.querySelector('[data-test=issues-detail-copy]')?.getAttribute('data-copied') === 'true', { timeout: 3000 })
      .then(() => p.evaluate(() => ({ text: window.__copied, label: document.querySelector('[data-test=issues-detail-copy]').getAttribute('aria-label') })), () => null)
    ok(`3 ${W}: Copy link copies ?issue=<key> and confirms`, Boolean(copy) && copy.text.endsWith(`/issues?issue=${a}`) && copy.label === 'Copied', copy)

    // 4) Archive asks the archive confirm for this issue; confirming removes it
    await p.click('[data-test=issues-detail-archive]')
    await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
    const archKey = await p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-key'))
    await p.click('[data-testid=issues-cascade-confirm]')
    await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"], [data-test=issues-card][data-key="${k}"]`), { timeout: 5000 }, a).catch(() => {})
    const archived = !(await p.$(row(a)))
    const closed = await waitModal(p, false)
    ok(`4 ${W}: Archive confirms for the open issue, then archives it and closes the dialog`, archKey === a && archived && closed, { archKey, archived, closed })

    // 5) Delete asks the single-issue confirm; confirming deletes it
    await openIssue(p, W, b)
    await p.click('[data-test=issues-detail-delete]')
    await p.waitForSelector('[data-testid=issues-delete-confirm]', { visible: true, timeout: 5000 })
    const delKey = await p.$eval('[data-testid=issues-delete-body]', (el) => el.getAttribute('data-key'))
    await p.click('[data-testid=issues-delete-confirm]')
    await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"], [data-test=issues-card][data-key="${k}"]`), { timeout: 5000 }, b).catch(() => {})
    const deleted = !(await p.$(row(b)))
    ok(`5 ${W}: Delete confirms for the open issue, then deletes it`, delKey === b && deleted, { delKey, deleted })
    if (await p.$('[data-test=issues-detail]')) await closeIssue(p, W)

    // 6) a regular member: the same three buttons (the hub decides, as for the menu)
    const c = await newIssue(p, W, `buttons C ${W}`)
    const set = await setMe(p, { humanId: 'HUM-1', role: 'regular_user', tenantOwner: false, permissions: ['topics.read'], channelOrder: null })
    await openIssue(p, W, c)
    const hm = await header(p)
    ok(`6 ${W}: a regular member sees Copy link / Archive / Delete`, set && Boolean(hm) && JSON.stringify(hm.ids) === JSON.stringify(BUTTONS), hm && hm.ids)
    await closeIssue(p, W)

    const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
    ok(`7 ${W}: no page errors`, mine.length === 0, mine)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
