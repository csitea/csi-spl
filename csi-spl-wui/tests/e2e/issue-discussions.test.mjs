// SPL-1593 (owner HUM-10, t1 topic fcf09921, msgs 3e75e13e, 9a8e4764,
// 28b479fd): every issue links to one or more discussions, listed in the
// issue's bottom panel above the comment box, each one a click away; a
// deleted one opens the "no longer exists" note in place.
//
// In a real browser on the mock tenant, desktop (1440 px) and phone (390 px):
//   1 SPL-1 (the mock seed links a live topic and a deleted one) shows both in
//     the Discussions section, above the comment box, the live one by its title
//   2 a click on the live one opens its topic (/t/<id>, the thread on screen)
//   3 a click on the deleted one opens the "no longer exists" note in the panel,
//     the page stays on SPL-1; Close shuts it
//   4 (desktop) a new issue starts linked to the workspace's default
//     discussion and is created with it; its panel then lists it
//   5 no page errors
//   6 (spec 153 C23, SPL-3354) the topic SPL-1 links shows a chip "SPL-1" to
//     /issues?issue=SPL-1, with its aria-label
//   7 (C24) a topic no issue links shows no chip and no empty chip row
// CONTROL: before SPL-1593 the issue view had no [data-test=issue-discussions]
// and no "no longer exists" note, so 1-4 fail. Before SPL-3354 the topic page
// had no [data-test=topic-issue-chip], so 6 fails; with the chips but without
// the `discussion` filter (origin/master's issues.mjs) every topic lists every
// issue, so 7 fails.
//
// Run:
//   node tests/e2e/issue-discussions.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/issue-discussions.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, setPageViewport, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const WIDTHS = [1440, 390]
const LIVE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SECTION = '[data-test=issue-discussions]'
const ROW = '[data-test=issue-discussion]'
/* C24: a mock topic that no seeded issue links */
const UNLINKED = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
const CHIPS = '[data-test=topic-issue-chips]'
const CHIP = '[data-test=topic-issue-chip]'

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
        headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the section's rows once their state is read: [task, state, label] */
const rowsOf = (p) => p.waitForFunction((sec, row) => {
  const s = document.querySelector(sec)
  const rows = s ? [...s.querySelectorAll(row)] : []
  return rows.length ? rows.map((r) => [r.dataset.task, r.dataset.state, r.querySelector('a, span')?.textContent.trim() || '']) : false
}, { timeout: 10000 }, SECTION, ROW).then((h) => h.jsonValue()).catch(() => [])

/* the section sits above the comment box, in the same panel */
const aboveComposer = (p) => p.evaluate((sec) => {
  const s = document.querySelector(sec)
  const box = document.querySelector('[data-test=issues-comment-input]')
  if (!s || !box) return false
  return Boolean(s.compareDocumentPosition(box) & Node.DOCUMENT_POSITION_FOLLOWING) && s.closest('[data-test=issues-talk]') === box.closest('[data-test=issues-talk]')
}, SECTION)

async function openSpl1(p, base) {
  await p.goto(base + '/issues?issue=SPL-1', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(SECTION, { timeout: NAV_TIMEOUT })
}

/* click a link inside the section's row for task, scrolled into view */
const clickRow = (p, state) => p.evaluate((sec, row, state) => {
  const r = [...document.querySelectorAll(`${sec} ${row}`)].find((x) => x.dataset.state === state)
  const a = r && r.querySelector('[data-test=issue-discussion-link]')
  if (!a) return false
  a.scrollIntoView({ block: 'center' })
  a.click()
  return true
}, SECTION, ROW, state)

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
    await openSpl1(p, server.base)
    await applyViewport(p, vp)

    const rows = await rowsOf(p)
    ok(`1 ${W}: SPL-1 lists its live and its deleted discussion, the live one by its title, above the comment box`,
      rows.length === 2 && rows[0][0] === LIVE && rows[0][1] === 'live' && rows[0][2].startsWith('Review the spool WUI') &&
      rows[1][1] === 'gone' && await aboveComposer(p), rows)

    const clicked = await clickRow(p, 'live')
    const topic = await p.waitForFunction((id) => location.pathname.endsWith(`/t/${id}`) && document.querySelector('[data-test=topic-browse]'),
      { timeout: 10000 }, LIVE).then(() => true).catch(() => false)
    ok(`2 ${W}: a click on the live discussion opens its topic`, clicked && topic, await p.evaluate(() => location.pathname))

    await openSpl1(p, server.base)
    await rowsOf(p)
    const clickedGone = await clickRow(p, 'gone')
    const gone = await p.waitForSelector('[data-test=discussion-gone]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
    const where = await p.evaluate(() => location.pathname + location.search)
    if (gone) await p.click('[data-test=discussion-gone-close]')
    const shut = gone ? await p.waitForSelector('[data-test=discussion-gone]', { hidden: true, timeout: 5000 }).then(() => true).catch(() => false) : false
    ok(`3 ${W}: a click on the deleted discussion opens the "no longer exists" note in place, Close shuts it`,
      clickedGone && gone && /\/issues\?issue=SPL-1$/.test(where) && shut, { where, shut })

    if (W > 820) {
      await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
      await p.click('[data-test=issues-new]')
      await p.waitForSelector('[data-test=issues-newrow-discussions] [data-test=issue-discussion-draft]', { visible: true, timeout: 8000 })
      const chip = await p.$eval('[data-test=issues-newrow-discussions] [data-test=issue-discussion-draft]', (e) => e.textContent.trim())
      await p.type('[data-test=issues-newrow-title]', 'linked by default')
      await p.keyboard.press('Enter')
      const key = await p.waitForFunction(() => {
        const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === 'linked by default')
        return r ? r.getAttribute('data-key') : false
      }, { timeout: 8000 }).then((h) => h.jsonValue()).catch(() => '')
      if (key) await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
      const made = key ? await rowsOf(p) : []
      ok(`4 ${W}: a new issue starts linked to the workspace default and is created with it`,
        chip === 'Workspace default' && made.length === 1 && made[0][1] === 'live', { chip, key, made })
    }

    await p.goto(`${server.base}/t/${LIVE}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const chips = await p.waitForFunction((sel) => {
      const cs = [...document.querySelectorAll(sel)]
      return cs.length ? cs.map((c) => ({ key: c.dataset.key, href: c.getAttribute('href') || '', aria: c.getAttribute('aria-label') || '' })) : false
    }, { timeout: 10000 }, CHIP).then((h) => h.jsonValue()).catch(() => [])
    const spl1 = chips.find((c) => c.key === 'SPL-1')
    ok(`6 ${W}: the topic SPL-1 links shows the chip SPL-1 to /issues?issue=SPL-1, with its aria-label`,
      Boolean(spl1) && /\/issues\?issue=SPL-1$/.test(spl1.href) && /^Linked issue SPL-1: \S+/.test(spl1.aria), chips)

    await p.goto(`${server.base}/t/${UNLINKED}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const shown = await p.waitForFunction(() => document.querySelector('[data-test=topic-browse]'), { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
    /* the chips read after mount: give that read its time before counting none */
    await new Promise((r) => setTimeout(r, 1500))
    const none = await p.evaluate((a, b) => ({ row: document.querySelectorAll(a).length, chip: document.querySelectorAll(b).length }), CHIPS, CHIP)
    ok(`7 ${W}: a topic no issue links shows no chip and no empty row`, shown && none.row === 0 && none.chip === 0, { shown, ...none })

        const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
    ok(`5 ${W}: no page errors`, mine.length === 0, mine)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
