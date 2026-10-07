// Spec 065 L6 (owner, t1 4a31aa83, Q7 + Q10 yes): the release notes are ONE
// modal, ReleaseNotesDialog, opened from the version pop-up at the bottom -
// the desktop footer's version card and the phone strip's - and from the
// stable link /releases/<sha | 8+ prefix | v<X.Y.Z>>.
//
// Owner, t1 55b6de46: one table, already expanded, the 30 latest changes;
// columns # (1 = the oldest change of all), version, short sha, title; the
// version a level-2 row carrying only the version; the title links to the
// change's why / how note.
//
// Against the mock tenant (70 versions, two commits each, 140 changes,
// every state), at 1280x800 (desktop) and 390x844 (phone):
//   1 the card's "Release notes" button opens the modal (xl on desktop, full
//     screen on a phone)
//   2 one table, 30 rows newest first under 15 version rows, nothing to
//     expand or load; the running version is first and marked "you are
//     here"; a row shows #, version, 7-char sha and title
//   3 # counts from the oldest: the newest row is 140, then 139 ... 111;
//     a version row carries only its version
//   4 the title links to /releases/<sha>; a click shows that note: plain
//     words first, technical below, the full 40-char sha
//   5 a state=backfill row says "written after the fact", in the list and in
//     the note; a state=missing row says it has no note
//   7 Escape closes it
//   8 /releases/<sha prefix> opens that note, /releases/v<X.Y.Z> that version,
//     a ref that is neither says so
//
// Owner, t1 3385cecb ("proper table, proper aligning, proper x, proper flow
// from click"):
//   6a every column's cells line up under its header (both edges), the
//      last column reaches the table's end (no empty column), # aligned to
//      the end; on a phone the version column folds into its band
//   6b the X (desktop) / the Back chevron (phone) is shown in the dialog head
//   6c the note's two halves sit side by side on desktop, stacked on a phone
//   6d Back to the list returns to the row that was clicked: same scroll,
//      focus on that title
//   9  a /releases/<sha> link followed inside the app opens the same modal,
//      and closing it returns to the page it was clicked on
// and no horizontal overflow in the modal, no page error.
//
// Run:
//   pnpm run test:e2e release-notes
//   BASE_URL=<generated bundle> pnpm run test:e2e release-notes   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHA = '0123456789abcdef0123456789abcdef01234567'
/* the mock's commit j has sha (j + 1) as 8 hex digits, five times */
const mockSha = (j) => (j + 1).toString(16).padStart(8, '0').repeat(5)
const VIEWPORTS = [
  { name: '1280', width: 1280, height: 800, mobile: false },
  { name: '390', width: 390, height: 844, mobile: true },
]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** Click (desktop) or tap (phone) the centre of the first visible match. */
async function press(p, vp, sel) {
  const c = await p.evaluate((sel) => {
    const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
    if (!e) return null
    e.scrollIntoView({ block: 'center' })
    const r = e.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }, sel)
  if (!c) return false
  if (vp.mobile) await p.touchscreen.tap(Math.round(c.x), Math.round(c.y))
  else await p.mouse.click(Math.round(c.x), Math.round(c.y))
  return true
}

const listFacts = (p) => p.evaluate(() => {
  const dlg = document.querySelector('[data-testid=ui-dialog]')
  const vers = [...document.querySelectorAll('[data-test=release-version]')]
  const first = vers[0]
  const r = dlg?.getBoundingClientRect()
  const body = document.querySelector('[data-testid=ui-dialog-body]')
  const rows = [...document.querySelectorAll('[data-test=release-row]')]
  return {
    open: Boolean(dlg && document.querySelector('[data-test=release-notes]')),
    title: dlg?.querySelector('.ui-dialog__title')?.textContent.trim() || '',
    xl: Boolean(dlg?.classList.contains('xl')),
    rect: r ? { l: Math.round(r.left), t: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) } : null,
    vw: window.innerWidth,
    vh: window.innerHeight,
    xOverflow: body ? body.scrollWidth - body.clientWidth : -1,
    table: Boolean(document.querySelector('table[data-test=release-table]')),
    heads: [...document.querySelectorAll('[data-test=release-table] thead th')].map((th) => th.textContent.trim()),
    versions: vers.length,
    versionHeads: vers.map((v) => v.querySelector('[data-test=release-version-head]')?.textContent.replace(/\s+/g, ' ').trim() || ''),
    versionLevel: first?.querySelector('[data-test=release-version-head] [role=heading]')?.getAttribute('aria-level') || '',
    firstCurrent: first?.dataset.current === 'true',
    firstHere: first?.querySelector('[data-test=release-version-here]')?.textContent.trim() || '',
    rows: rows.map((row) => ({
      seq: row.querySelector('[data-test=release-row-seq]')?.textContent.trim() || '',
      cells: [...row.children].map((c) => c.textContent.replace(/\s+/g, ' ').trim()),
      sha: row.querySelector('[data-test=release-row-sha]')?.textContent.trim() || '',
      href: row.querySelector('[data-test=release-row-title]')?.getAttribute('href') || '',
      title: row.querySelector('[data-test=release-row-title]')?.textContent.trim() || '',
    })),
    expanders: document.querySelectorAll('[data-test=release-notes] [aria-expanded]').length,
    more: Boolean(document.querySelector('[data-test=release-notes-more]')),
    filter: Boolean(document.querySelector('[data-test=release-notes-filter]')),
  }
})

const noteFacts = (p) => p.evaluate(() => {
  const n = document.querySelector('[data-test=release-note]')
  if (!n) return null
  const lay = n.querySelector('[data-test=release-note-lay]')
  const tech = n.querySelector('[data-test=release-note-tech]')
  return {
    sha: n.dataset.sha || '',
    state: n.dataset.state || '',
    fullSha: n.querySelector('[data-test=release-note-full-sha]')?.textContent.trim() || '',
    stateText: n.querySelector('[data-test=release-note-state]')?.textContent.trim() || '',
    lay: lay?.textContent.replace(/\s+/g, ' ').trim() || '',
    tech: tech?.textContent.replace(/\s+/g, ' ').trim() || '',
    layFirst: Boolean(lay && tech && (lay.compareDocumentPosition(tech) & Node.DOCUMENT_POSITION_FOLLOWING)),
  }
})

async function openFromCard(p, vp) {
  if (vp.mobile) {
    await until(p, () => Boolean(document.querySelector('[data-test=status-strip-version]')), null, 15000)
    await press(p, vp, '[data-test=status-strip-version]')
    await until(p, () => Boolean(document.querySelector('[data-test=status-strip-version-notes]')), null, 3000)
    return press(p, vp, '[data-test=status-strip-version-notes]')
  }
  await p.click('[data-test=app-version-wrap]').catch(() => null)
  await until(p, () => {
    const b = document.querySelector('[data-test=app-version-notes]')
    return Boolean(b && getComputedStyle(b.closest('[data-test=app-version-card]')).visibility === 'visible')
  }, null, 3000)
  return press(p, vp, '[data-test=app-version-notes]')
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of VIEWPORTS) {
    console.log(`-- ${vp.name}x${vp.height}`)
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    await p.setRequestInterception(true)
    p.on('request', (req) => {
      if (new URL(req.url()).pathname === '/build.json') {
        return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: SHA, built_at: '2026-10-03T10:30:00Z', run: '1' }) })
      }
      req.continue()
    })
    await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
    await signIn(p)
    await sleep(800)

    /* 1 the button opens the modal */
    ok(`${vp.name} 1a the version card has a "Release notes" button`, await openFromCard(p, vp))
    const opened = await until(p, () => document.querySelectorAll('[data-test=release-version]').length > 0, null, 10000)
    const f = await listFacts(p)
    ok(`${vp.name} 1b it opens the release notes modal`, opened && f.open && f.title === 'Release notes', { title: f.title })
    if (vp.mobile) ok(`${vp.name} 1c full screen on a phone`, f.rect && f.rect.l <= 0 && f.rect.w >= f.vw - 1 && f.rect.h >= f.vh - 60, f.rect)
    else ok(`${vp.name} 1c the xl size on desktop`, f.xl && f.rect && f.rect.w >= f.vw * 0.8, f.rect)

    /* 2 one expanded table of the 30 latest, the running version first */
    /* a phone folds the version column into the band above its rows */
    const wantHeads = vp.mobile ? '#|Commit|Change' : '#|Version|Commit|Change'
    ok(`${vp.name} 2a one table: ${wantHeads.replaceAll('|', ', ')}`, f.table && f.heads.join('|') === wantHeads, f.heads)
    ok(`${vp.name} 2b 30 rows under 15 version rows, nothing to expand, filter or load`,
      f.rows.length === 30 && f.versions === 15 && f.expanders === 0 && !f.more && !f.filter, { rows: f.rows.length, versions: f.versions, expanders: f.expanders, more: f.more, filter: f.filter })
    ok(`${vp.name} 2c the running version is first and marked "you are here"`, f.firstCurrent && f.firstHere === 'you are here', { here: f.firstHere })
    const r0 = f.rows[0] || {}
    ok(`${vp.name} 2d a row shows #, ${vp.mobile ? '' : 'version, '}7-char sha and title`,
      r0.cells?.length === (vp.mobile ? 3 : 4) && r0.cells[0] === '140' && (vp.mobile || /^v[0-9]+\.[0-9]+\.[0-9]+$/.test(r0.cells[1])) && r0.sha === mockSha(0).slice(0, 7) && /^mock change 1:/.test(r0.title), r0)

    /* 3 # counts from the oldest change: newest first, 140 down to 111 */
    const seqs = f.rows.map((x) => Number(x.seq))
    ok(`${vp.name} 3a # runs 140, 139 ... 111 (1 = the oldest change)`, seqs.length === 30 && seqs.every((n, i) => n === 140 - i), seqs)
    ok(`${vp.name} 3b newest first: row i is the mock's change i`, f.rows.every((x, i) => x.sha === mockSha(i).slice(0, 7)), f.rows.slice(0, 3).map((x) => x.sha))
    ok(`${vp.name} 3c a version row is a level-2 heading carrying only the version`,
      f.versionLevel === '2' && f.versionHeads.slice(1).every((h) => /^v[0-9]+\.[0-9]+\.[0-9]+$/.test(h)) && f.versionHeads[1] === 'v0.1.69', f.versionHeads.slice(0, 3))
    ok(`${vp.name} 3d no horizontal overflow in the modal`, f.xOverflow <= 0, f.xOverflow)

    /* 6a proper table: each column's cells start where its header starts */
    const align = await p.evaluate(() => {
      const heads = [...document.querySelectorAll('[data-test=release-table] thead th')]
      const shown = (e) => e.getClientRects().length > 0
      const rows = [...document.querySelectorAll('[data-test=release-row]')]
      const table = document.querySelector('[data-test=release-table]').getBoundingClientRect()
      const cols = heads.map((h) => h.getBoundingClientRect())
      let worst = rows.some((row) => row.children.length !== heads.length) ? 999 : 0
      for (const row of rows) {
        cols.forEach((c, i) => {
          const td = row.children[i]?.getBoundingClientRect()
          if (td) worst = Math.max(worst, Math.abs(td.left - c.left), Math.abs(td.right - c.right))
        })
      }
      /* the band row spans the whole table: no column left over beside it */
      const band = document.querySelector('[data-test=release-version-head] th')?.getBoundingClientRect()
      const bandGap = band ? Math.abs(band.right - (cols[cols.length - 1]?.right ?? 0)) : 999
      const seq = rows[0]?.querySelector('[data-test=release-row-seq]')
      return { worst: Math.round(worst * 10) / 10, bandGap: Math.round(bandGap), fill: Math.round(table.right - (cols[cols.length - 1]?.right ?? 0)), seqAlign: seq ? getComputedStyle(seq).textAlign : '' }
    })
    ok(`${vp.name} 6a every column's cells line up under its header, # aligned to the end`,
      align.worst <= 1 && align.bandGap <= 1 && align.fill <= 1 && align.seqAlign === 'end', align)

    /* 6b proper X: the dialog head shows its close control */
    const closeShown = await p.evaluate((sel) => [...document.querySelectorAll(sel)].some((e) => e.getClientRects().length && getComputedStyle(e).visibility === 'visible'),
      vp.mobile ? '[data-testid=ui-dialog-back]' : '[data-testid=ui-dialog-close]')
    ok(`${vp.name} 6b the dialog shows its ${vp.mobile ? 'Back chevron' : 'X'}`, closeShown)

    /* 5a the backfill row says so in the list; 5c the missing one says no note */
    const rowBadge = (sha) => p.evaluate((sha) => {
      const row = document.querySelector(`[data-test=release-row-title][data-sha="${sha}"]`)?.closest('[data-test=release-row]')
      return row ? { state: row.dataset.state, badge: row.querySelector('[data-test=release-row-badge]')?.textContent.trim() || '' } : null
    }, sha)
    const backfillBadge = await rowBadge(mockSha(1))
    ok(`${vp.name} 5a a state=backfill row reads "written after the fact"`, backfillBadge?.state === 'backfill' && /written after the fact/i.test(backfillBadge.badge), backfillBadge)
    const missing = await rowBadge(mockSha(2))
    ok(`${vp.name} 5c a state=missing row says it has no note`, missing?.state === 'missing' && missing.badge === 'no note', missing)

    /* 4 the title links to the change's note */
    ok(`${vp.name} 4a the title links to /releases/<sha>`, r0.href?.endsWith('/releases/' + mockSha(0)), r0.href)
    await press(p, vp, `[data-test=release-row-title][data-sha="${mockSha(0)}"]`)
    await until(p, () => Boolean(document.querySelector('[data-test=release-note]')), null, 3000)
    const n0 = await noteFacts(p)
    ok(`${vp.name} 4b a click on the title shows that change's note`, n0?.sha === mockSha(0) && n0.state === 'ok', n0 && { sha: n0.sha, state: n0.state })
    ok(`${vp.name} 4c plain words first (What / How / Why), technical below`,
      n0?.layFirst && /What/.test(n0.lay) && /How/.test(n0.lay) && /Why/.test(n0.lay) && /Mock module 1/.test(n0.tech), n0 && { lay: n0.lay, tech: n0.tech })
    ok(`${vp.name} 4d the full 40-char sha`, n0?.fullSha === mockSha(0), n0?.fullSha)
    const halves = await p.evaluate(() => {
      const a = document.querySelector('[data-test=release-note-lay]')?.getBoundingClientRect()
      const b = document.querySelector('[data-test=release-note-tech]')?.getBoundingClientRect()
      return a && b ? { sameTop: Math.abs(a.top - b.top) < 1, below: b.top >= a.bottom - 1 } : null
    })
    ok(`${vp.name} 6c the note's halves sit ${vp.mobile ? 'stacked' : 'side by side'}`, halves && (vp.mobile ? halves.below : halves.sameTop), halves)

    /* 6d Back to the list comes back to the row that was clicked */
    await press(p, vp, '[data-test=release-note-back]')
    await until(p, () => document.querySelectorAll('[data-test=release-row]').length === 30, null, 3000)
    const deep = mockSha(24)
    const before = await p.evaluate((sha) => {
      document.querySelector(`[data-test=release-row-title][data-sha="${sha}"]`)?.scrollIntoView({ block: 'center' })
      return document.querySelector('[data-testid=ui-dialog-body]')?.scrollTop || 0
    }, deep)
    await press(p, vp, `[data-test=release-row-title][data-sha="${deep}"]`)
    await until(p, (sha) => document.querySelector('[data-test=release-note]')?.dataset.sha === sha, deep, 3000)
    await press(p, vp, '[data-test=release-note-back]')
    await until(p, () => document.querySelectorAll('[data-test=release-row]').length === 30, null, 3000)
    await sleep(100)
    const back = await p.evaluate(() => ({
      top: document.querySelector('[data-testid=ui-dialog-body]')?.scrollTop || 0,
      focus: document.activeElement?.dataset?.sha || '',
    }))
    ok(`${vp.name} 6d Back to the list returns to the clicked row (scroll + focus)`,
      before > 0 && Math.abs(back.top - before) <= 2 && back.focus === deep, { before, ...back })

    /* 5b the backfill note itself */
    await press(p, vp, '[data-test=release-note-back]')
    await until(p, () => document.querySelectorAll('[data-test=release-row]').length === 30, null, 3000)
    await press(p, vp, `[data-test=release-row-title][data-sha="${mockSha(1)}"]`)
    await until(p, (sha) => document.querySelector('[data-test=release-note]')?.dataset.sha === sha, mockSha(1), 3000)
    const n1 = await noteFacts(p)
    ok(`${vp.name} 5b the backfill note says "written after the fact"`, n1?.state === 'backfill' && /written after the fact/i.test(n1.stateText), n1 && { state: n1.state, text: n1.stateText })

    /* 7 Escape closes it */
    await p.keyboard.press('Escape')
    ok(`${vp.name} 7 Escape closes the modal`, await until(p, () => !document.querySelector('[data-test=release-notes]'), null, 3000))

    /* 8 the stable link */
    await p.goto(server.base + '/releases/' + mockSha(9).slice(0, 8), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await signIn(p)
    const viaSha = await until(p, (sha) => document.querySelector('[data-test=release-note]')?.dataset.sha === sha, mockSha(9), 15000)
    ok(`${vp.name} 8a /releases/<8-char prefix> opens that note in the modal`, viaSha, await noteFacts(p).then((x) => x && x.sha))
    await p.goto(server.base + '/releases/v0.1.60', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const viaVer = await until(p, () => {
      const vers = [...document.querySelectorAll('[data-test=release-version]')]
      return vers.length === 1 && vers[0].dataset.version === 'v0.1.60' && vers[0].querySelectorAll('[data-test=release-row]').length === 2
    }, null, 15000)
    ok(`${vp.name} 8b /releases/v<X.Y.Z> opens that version with its changes`, viaVer)
    await p.goto(server.base + '/releases/not-a-ref', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const bad = await until(p, () => /Not a commit or a version/.test(document.querySelector('[data-test=release-notes-message]')?.textContent || ''), null, 15000)
    ok(`${vp.name} 8c a ref that is neither says so`, bad)
    await press(p, vp, vp.mobile ? '[data-testid=ui-dialog-back]' : '[data-testid=ui-dialog-close]')
    const left = await until(p, () => !document.querySelector('[data-test=release-notes]') && !location.pathname.includes('/releases/'), null, 8000)
    ok(`${vp.name} 8d closing the linked modal leaves /releases/`, left, await p.evaluate(() => location.pathname))

    /* 9 a link followed inside the app: the same modal, closing returns there */
    await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
    await signIn(p)
    await sleep(500)
    await p.evaluate((sha) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/releases/' + sha), mockSha(3))
    const inApp = await until(p, (sha) => document.querySelector('[data-test=release-note]')?.dataset.sha === sha, mockSha(3), 15000)
    ok(`${vp.name} 9a an in-app /releases/<sha> link opens that note in the modal`, inApp)
    await sleep(300)
    await press(p, vp, vp.mobile ? '[data-testid=ui-dialog-back]' : '[data-testid=ui-dialog-close]')
    const home = await until(p, () => !document.querySelector('[data-test=release-notes]') && location.pathname.endsWith('/lobby'), null, 8000)
    ok(`${vp.name} 9b closing it returns to the page it was clicked on`, home, await p.evaluate(() => location.pathname))

    ok(`${vp.name} no page error`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nrelease-notes: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
