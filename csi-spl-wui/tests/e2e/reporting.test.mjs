// Spec 143 T061 (SPL-2832), the Reporting section end to end in a real
// browser against the mock bundle, at 1440x900 and 390x844:
//   - /reporting replaces itself with /reporting/releases (spec 1.2: the
//     section lands on its first tab);
//   - the Releases tab draws commit rows whose short sha and version link
//     to /releases/<ref> (spec 2.2), and a click on a sha opens that page;
//   - for a workspace admin the bar shows the SQL tab; /reporting/sql runs
//     a test query and renders the result table with zebra rows
//     (.row--even / .row--odd, two different backgrounds, spec 3.6), its
//     NULL cells marked; a write is refused with the read-only message and
//     no table (spec 3.2);
//   - for a member who is not an admin the bar has no SQL tab.
// RED CONTROL: a tab, a link or the table missing fails a check, and the
// file exits 1.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e reporting
//   SHOT_DIR=<dir> keeps a screenshot per size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const MOCK_ME_KEY = 'spool.mock.me'
const ADMIN = { role: 'admin', permissions: [] }
const MEMBER = { role: 'member', permissions: [] }
const pathOf = (p) => new URL(p.url()).pathname
const at = (p, want) => p.waitForFunction((w) => location.pathname === w, { timeout: 15000 }, want).then(() => true, () => false)
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const tabIds = (p) => p.$$eval('[data-test^=reporting-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('reporting-tab-'.length)))

/** A fresh signed-in mock page at this size, as `me` (the opt-in mock role). */
async function reportingPage(browser, base, { width, height, touch }, me) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.setItem(meKey, JSON.stringify(m))
  }, MOCK_ME_KEY, me)
  return { ctx, p }
}

/** Type a query into the SQL editor as a person would and press Run. */
async function runQuery(p, q) {
  await p.$eval('[data-test=reporting-sql-query]', (e) => {
    e.value = ''
    e.dispatchEvent(new Event('input', { bubbles: true }))
  })
  await p.type('[data-test=reporting-sql-query]', q)
  await p.click('[data-test=reporting-sql-run]')
}

async function releases(p, base, tag) {
  await p.goto(base + '/reporting', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: /reporting is replaced by /reporting/releases`, await at(p, '/reporting/releases'), pathOf(p))
  ok(`${tag}: the Releases tab is the current one`, await p.$eval('[data-test=reporting-tab-releases]', (e) => e.getAttribute('aria-current')).catch(() => '') === 'page')
  ok(`${tag}: commit rows render`, await waitFor(p, '[data-test=releases-commit]'))
  const rows = await p.$$eval('[data-test=releases-commit]', (els) => els.map((e) => ({
    sha: e.getAttribute('data-sha') || '',
    shaText: e.querySelector('[data-test=releases-commit-sha]')?.textContent.trim() || '',
    shaHref: e.querySelector('[data-test=releases-commit-sha]')?.getAttribute('href') || '',
    version: e.querySelector('[data-test=releases-commit-version]')?.textContent.trim() || '',
    versionHref: e.querySelector('[data-test=releases-commit-version]')?.getAttribute('href') || '',
  })))
  ok(`${tag}: there are commit rows`, rows.length > 0, { rows: rows.length })
  const bad = rows.filter((r) => !r.sha || !r.shaHref.endsWith('/releases/' + r.sha) || r.shaText !== r.sha.slice(0, 7))
  ok(`${tag}: every row's short sha links to /releases/<sha>`, rows.length > 0 && bad.length === 0, bad.slice(0, 2))
  const versioned = rows.filter((r) => r.version)
  const badV = versioned.filter((r) => !r.versionHref.endsWith('/releases/' + r.version))
  ok(`${tag}: a version badge links to /releases/<version>`, versioned.length > 0 && badV.length === 0, { versioned: versioned.length, bad: badV.slice(0, 2) })
  if (rows.length) {
    await p.click(`[data-test=releases-commit][data-sha="${rows[0].sha}"] [data-test=releases-commit-sha]`)
    ok(`${tag}: a click on the sha opens /releases/<sha>`, await at(p, '/releases/' + rows[0].sha), pathOf(p))
  }
}

async function sql(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: an admin's bar shows the SQL tab`, await waitFor(p, '[data-test=reporting-tab-sql]'), await tabIds(p))
  await p.click('[data-test=reporting-tab-sql]')
  ok(`${tag}: the SQL tab opens /reporting/sql`, await at(p, '/reporting/sql'), pathOf(p))
  ok(`${tag}: the editor renders`, await waitFor(p, '[data-test=reporting-sql-query]'))
  await runQuery(p, 'SELECT channel_id, name, created_at FROM channels ORDER BY created_at')
  ok(`${tag}: the query renders the result table`, await waitFor(p, '[data-test=reporting-sql-table]'))
  const t = await p.$eval('[data-test=reporting-sql-table]', (tb) => {
    const body = [...tb.querySelectorAll('tbody tr')]
    return {
      heads: [...tb.querySelectorAll('thead th')].map((h) => h.textContent.trim()),
      classes: body.map((r) => (r.classList.contains('row--even') ? 'even' : r.classList.contains('row--odd') ? 'odd' : '')),
      bgs: body.map((r) => getComputedStyle(r).backgroundColor),
      nulls: tb.querySelectorAll('td.sql-null').length,
    }
  }).catch(() => ({ heads: [], classes: [], bgs: [], nulls: 0 }))
  ok(`${tag}: the columns are the query's`, JSON.stringify(t.heads) === JSON.stringify(['channel_id', 'name', 'created_at']), t.heads)
  ok(`${tag}: the rows alternate even / odd`, t.classes.length >= 3 && t.classes.every((c, i) => c === (i % 2 === 0 ? 'even' : 'odd')), t.classes)
  ok(`${tag}: zebra: an odd row's background differs from an even row's`, t.bgs.length >= 2 && t.bgs[0] !== t.bgs[1] && t.bgs[0] === t.bgs[2], t.bgs)
  ok(`${tag}: a NULL cell is marked`, t.nulls >= 1, { nulls: t.nulls })
  ok(`${tag}: the status names the row count`, /3/.test(await p.$eval('[data-test=reporting-sql-status]', (e) => e.textContent).catch(() => '')))
  await runQuery(p, 'DELETE FROM channels')
  ok(`${tag}: a write is refused with the error line`, await waitFor(p, '[data-test=reporting-sql-error]'))
  ok(`${tag}: a refused write shows no table`, !(await p.$('[data-test=reporting-sql-table]')))
  ok(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
}

async function nonAdmin(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await waitFor(p, '[data-test=reporting-tab-releases]')
  await new Promise((r) => setTimeout(r, 500))
  const tabs = await tabIds(p)
  ok(`${tag}: a member's bar has Releases and no SQL tab`, tabs.includes('releases') && !tabs.includes('sql'), tabs)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const size of [{ width: 1440, height: 900, touch: false }, { width: 390, height: 844, touch: true }]) {
    const tag = `${size.width}px`
    let { ctx, p } = await reportingPage(browser, server.base, size, ADMIN)
    await releases(p, server.base, tag)
    await sql(p, server.base, tag)
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-sql-${size.width}.png` })
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, MEMBER))
    await nonAdmin(p, server.base, tag)
    await ctx.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nreporting: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length || !results.length ? 1 : 0))
