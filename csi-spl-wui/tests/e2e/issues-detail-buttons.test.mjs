// CLE-77854 (owner, topic 643330e5): "convert those right-click menu options
// [to] separate buttons, but at the end of the existing right side controls".
// The open issue's ☰ menu (Copy link / Archive / Delete) is gone; the three are
// their own icon buttons in the dialog header (> 820 px) and in the phone's top
// bar, each labelled, and each does what its menu item did: Copy link copies
// and says so, Archive asks the shared archive confirm, Delete asks the
// single-issue confirm. A regular member sees the same three (the hub is the
// authority, as it was for the menu). No horizontal scroll at 390.
// HUM-10 (t1 40c135cb): archiving or deleting an issue with a live sub-issue
// said only "That change did not save" (the hub's 409 issue_has_children).
// Every entry point now states the open sub-issues and offers the cascade in
// the one confirm, the count in its button (cases 8-10).
//
//   pnpm run test:e2e issues-detail-buttons
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-detail-buttons
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
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
/* a sub-issue under the open issue, from its subtasks section */
async function addSub(p, title) {
  /* a phone's docked composer covers a + at the bottom edge: centre it first */
  await p.$eval('[data-test=issues-subtask-open]', (el) => el.scrollIntoView({ block: 'center' }))
  await p.click('[data-test=issues-subtask-open]')
  await p.waitForSelector('[data-test=issues-subtask-input]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-subtask-input]')
  await p.type('[data-test=issues-subtask-input]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => [...document.querySelectorAll('[data-test=issues-subtask]')].some((s) => s.textContent.includes(want)), { timeout: 5000 }, title).then(() => true, () => false)
}
/* the open issue scrolled to its top, as just opened: is the subtask + covered
   where it lies (in sight, another element at its centre), and does a
   tap on it open the subtask dialog. puppeteer's click scrolls only what is
   out of view, as a finger does; the dialog is closed again with Escape. */
async function subtaskTap(p) {
  await p.evaluate(() => new Promise((res) => {
    const d = document.querySelector('aside.issues-detail')
    if (d) d.scrollTop = 0
    requestAnimationFrame(() => requestAnimationFrame(res))
  }))
  const at = await p.$eval('[data-test=issues-subtask-open]', (el) => {
    const r = el.getBoundingClientRect()
    const x = r.left + r.width / 2, y = r.top + r.height / 2
    /* in view: inside the viewport and inside the phone's scrolling frame (a
       + below the frame's fold is out of sight, not covered) */
    const frame = el.closest('aside.issues-detail')
    const f = frame ? frame.getBoundingClientRect() : { top: 0, bottom: window.innerHeight }
    const inView = y > Math.max(0, f.top) && y < Math.min(window.innerHeight, f.bottom)
    const hit = inView ? document.elementFromPoint(x, y) : null
    const dock = document.querySelector('form.composer--dock')?.getBoundingClientRect()
    return { y: Math.round(r.top), bottom: Math.round(r.bottom), inView, scrollTop: frame ? Math.round(frame.scrollTop) : null,
      frameBottom: Math.round(f.bottom), dockTop: dock ? Math.round(dock.top) : null,
      on: !hit ? '' : el.contains(hit) ? 'plus' : hit.closest('form') ? 'composer' : hit.tagName.toLowerCase() }
  })
  const clear = !at.inView || at.on === 'plus'
  await p.click('[data-test=issues-subtask-open]')
  const opened = await p.waitForSelector('[data-test=issues-subtask-input]', { visible: true, timeout: 3000 }).then(() => true, () => false)
  if (opened) {
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => !document.querySelector('[data-test=issues-subtask-input]'), { timeout: 3000 }).catch(() => {})
  }
  return { ...at, clear, opened }
}
/* a phone: grow the docked composer with a multi-line draft (lines > 0) or
   empty it (0); returns the dock's height once it settled */
async function growDock(p, lines = 6) {
  const before = await p.evaluate(() => document.querySelector('form.composer--dock')?.getBoundingClientRect().height || 0)
  await p.evaluate((n) => {
    const ta = document.querySelector('form.composer--dock textarea')
    if (!ta) return
    ta.value = n ? Array.from({ length: n }, (_, i) => `line ${i + 1}`).join('\n') : ''
    ta.dispatchEvent(new Event('input', { bubbles: true }))
  }, lines)
  if (lines) await p.waitForFunction((h) => (document.querySelector('form.composer--dock')?.getBoundingClientRect().height || 0) > h, { timeout: 3000 }, before).catch(() => {})
  await new Promise((r) => setTimeout(r, 200))
  return p.evaluate(() => Math.round(document.querySelector('form.composer--dock')?.getBoundingClientRect().height || 0))
}
/* the cascade confirm as shown: its key, count, body text, button and error */
const cascadeAsk = (p) => p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
  .then(() => p.waitForFunction(() => document.querySelector('[data-testid=issues-cascade-body]')?.getAttribute('data-count') !== '0', { timeout: 3000 }).catch(() => {}))
  .then(() => p.evaluate(() => {
    const body = document.querySelector('[data-testid=issues-cascade-body]')
    return { key: body?.getAttribute('data-key') || '', count: body?.getAttribute('data-count') || '', text: body?.textContent.trim() || '',
      button: document.querySelector('[data-testid=issues-cascade-confirm]')?.textContent.trim() || '',
      error: document.querySelector('[data-testid=issues-cascade-error]')?.textContent.trim() || '' }
  }), () => null)
/* confirm the cascade; the row goes, the confirm closes, no error shows */
async function confirmCascade(p, key) {
  await p.click('[data-testid=issues-cascade-confirm]')
  const gone = await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 5000 }, row(key)).then(() => true, () => false)
  const closed = await p.waitForFunction(() => !document.querySelector('[data-testid=issues-cascade-confirm]'), { timeout: 5000 }).then(() => true, () => false)
  const error = await p.$eval('[data-testid=issues-cascade-error]', (el) => el.textContent.trim()).catch(() => '')
  return { gone, closed, error }
}
const offers = (a, key, verb) => Boolean(a) && a.key === key && a.count === '1' && a.text.includes(`${key} has 1 open subtask`)
  && a.button === `${verb} with its 1 subtask` && !a.error
const setMe = (p, me) => p.evaluate((me) => {
  const access = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')
  if (!access) return false
  access.me = me
  return true
}, me)

// a private per-run dir by default: a fixed name in the shared /tmp is owned by
// whichever OS user ran first, and the next user's screenshot fails EACCES.
const shot = process.env.SHOT_DIR || mkdtempSync(join(tmpdir(), 'spl-e2e-'))
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

    // 4) Archive asks the archive confirm for this issue; confirming removes it.
    //    SPL-2783 (owner, t1 ff23df68 f702164e): on a phone it archives at once.
    await p.click('[data-test=issues-detail-archive]')
    let archKey = a
    if (W > 820) {
      await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 5000 })
      archKey = await p.$eval('[data-testid=issues-cascade-body]', (el) => el.getAttribute('data-key'))
      await p.click('[data-testid=issues-cascade-confirm]')
    } else if (await p.waitForSelector('[data-testid=issues-cascade-confirm]', { visible: true, timeout: 1500 }).then(() => true, () => false)) archKey = 'asked'
    await p.waitForFunction((k) => !document.querySelector(`[data-test=issues-row][data-key="${k}"], [data-test=issues-card][data-key="${k}"]`), { timeout: 5000 }, a).catch(() => {})
    const archived = !(await p.$(row(a)))
    const closed = await waitModal(p, false)
    ok(`4 ${W}: Archive ${W > 820 ? 'confirms for the open issue, then archives' : 'archives the open issue at once (no confirm)'} it and closes the dialog`, archKey === a && archived && closed, { archKey, archived, closed })

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

    // 8) Archive of an issue with a live sub-issue: the confirm states it and
    //    offers the cascade, the count in the button; confirming archives both
    const d = await newIssue(p, W, `buttons D ${W}`)
    await openIssue(p, W, d)
    const dSub = await addSub(p, `sub of D ${W}`)
    await p.click('[data-test=issues-detail-archive]')
    const dAsk = await cascadeAsk(p)
    await p.screenshot({ path: `${shot}/HUM-10-archive-with-subs-${W}.png` })
    const dRes = await confirmCascade(p, d)
    ok(`8 ${W}: Archive of an issue with a sub-issue offers "Archive with its 1 subtask"; confirming archives it`,
      dSub && offers(dAsk, d, 'Archive') && dRes.gone && dRes.closed && !dRes.error, { dSub, dAsk, dRes })
    if (await p.$('[data-test=issues-detail]')) await closeIssue(p, W)

    // 9) the same for Delete
    const e = await newIssue(p, W, `buttons E ${W}`)
    await openIssue(p, W, e)
    const eSub = await addSub(p, `sub of E ${W}`)
    await p.click('[data-test=issues-detail-delete]')
    const eAsk = await cascadeAsk(p)
    const eRes = await confirmCascade(p, e)
    ok(`9 ${W}: Delete of an issue with a sub-issue offers "Delete with its 1 subtask"; confirming deletes it`,
      eSub && offers(eAsk, e, 'Delete') && eRes.gone && eRes.closed && !eRes.error, { eSub, eAsk, eRes })
    if (await p.$('[data-test=issues-detail]')) await closeIssue(p, W)

    // 10) from the list's row menu, the issue closed (its sub-issues are not
    //     loaded): the same offer, never a bare "That change did not save"
    const f = await newIssue(p, W, `buttons F ${W}`)
    await openIssue(p, W, f)
    const fSub = await addSub(p, `sub of F ${W}`)
    await closeIssue(p, W)
    const fBox = await p.$eval(row(f), (el) => { const b = el.getBoundingClientRect(); return { x: b.x + Math.min(40, b.width / 2), y: b.y + b.height / 2 } })
    await p.mouse.click(fBox.x, fBox.y, { button: 'right' })
    await p.waitForSelector('[data-test=issues-ctxmenu-archive]', { visible: true, timeout: 5000 })
    await p.click('[data-test=issues-ctxmenu-archive]')
    const fAsk = await cascadeAsk(p)
    const fRes = await confirmCascade(p, f)
    ok(`10 ${W}: the row menu's Archive of a closed issue with a sub-issue offers the cascade; confirming archives it`,
      fSub && offers(fAsk, f, 'Archive') && fRes.gone && fRes.closed && !fRes.error, { fSub, fAsk, fRes })

    // 11) the subtask + of an issue just opened, NOT scrolled: the docked
    //     composer (collapsed, then expanded) never lies over it, and a tap
    //     where it lies opens the subtask dialog
    const g = await newIssue(p, W, `buttons G ${W}`)
    await openIssue(p, W, g)
    const gCollapsed = await subtaskTap(p)
    const gGrown = W > 820 ? null : await growDock(p)
    const gExpanded = W > 820 ? null : await subtaskTap(p)
    await growDock(p, 0)
    await p.screenshot({ path: `${shot}/phone-subtask-plus-${W}.png` })
    ok(`11 ${W}: the subtask + is clear of the docked composer (collapsed${W > 820 ? '' : ', expanded'}) and a tap opens its dialog`,
      gCollapsed.clear && gCollapsed.opened && (W > 820 || (gExpanded.dockTop < gCollapsed.dockTop && gExpanded.clear && gExpanded.opened)), { gCollapsed, gGrown, gExpanded })
    if (await p.$('[data-test=issues-detail]')) await closeIssue(p, W)

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
