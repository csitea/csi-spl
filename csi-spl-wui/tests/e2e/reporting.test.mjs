// Spec 143 T061 (SPL-2832), the Reporting section end to end in a real
// browser against the mock bundle, at 1440x900 and 390x844:
//   - /reporting replaces itself with /reporting/releases (spec 1.2: the
//     section lands on its first tab);
//   - the Releases tab draws commit rows whose short sha and version link
//     to /releases/<ref> (spec 2.2), and a click on a sha opens that page;
//   - the kind labels are a cloud (spec 143 2.2.1, SPL-3796): the most used
//     kind is the centre pill and the largest, and a click on it shows the
//     commits of that kind only, with aria-pressed set;
//   - for a workspace admin the bar shows the SQL tab; /reporting/sql runs
//     a test query and renders the result table with zebra rows
//     (.row--even / .row--odd, two different backgrounds, spec 3.6), its
//     NULL cells marked; a write is refused with the read-only message and
//     no table (spec 3.2);
//   - for a member who is not an admin the bar has no SQL tab;
//   - spec 163 B1 (SPL-4250, Q8): an admin's bar shows the Marketing tab;
//     /reporting/marketing draws the seven empty stage cards in the
//     overview's order and the Q7 attribution line (last touch, 28 days);
//     a member's bar has no Marketing tab, and the page opened by its path
//     shows the hub's refusal and no card.
//   - spec 125 B7 (SPL-4741, case C-NVS-7; C7 as rewritten, SPL-4792, owner
//     msg cfa78746): the workspace's Netvisor owner (the mock reader with no
//     spool.mock.me) sees the Finance tab; /reporting/finance draws the
//     forecast card and its items, the newest bank voucher date, the card
//     costs by vendor / cost type / cost centre with the spec-123 vendor
//     left out, "Refresh now" and the settings form (a bad account number is
//     refused, a good one saved); another person of the workspace (an admin
//     who is not the owner) sees the tab and the same figures with the same
//     vendor left out, but no Refresh now and no settings form, and sends no
//     read the hub refuses; an agent seat gets no Finance tab, and the page
//     opened by its path shows the refusal and no figure.
//   - SPL-4697 (spec 143 incomes.md): the workspace owner's bar shows the
//     Incomes tab; /reporting/incomes draws twelve month rows, a dash for a
//     month with no invoice and the year total row; an admin's and a
//     member's bar have no Incomes tab, and the member who opens it by its
//     path gets the refusal line, no table and no refused read.
//   - SPL-4789 (owner HUM-10, t1 ef94396b): a commit row shows its issue
//     links (/issues?issue=<key>) and discussion links (/t/<id>), or
//     "unknown" for a commit with neither; the links do not widen the page
//     past the viewport, and a click on an issue opens it.
// RED CONTROL: a tab, a link or the table missing fails a check, and the
// file exits 1. For Finance: the page reading the settings for every reader
// (SPL-4741's load) fails "a member sends 0 refused reads"; the tab rule
// widened to every role (no netvisorReader in reporting-tabs.mjs) fails "an
// agent seat's bar has no Finance tab"; a key missing in en.json renders its
// raw key and fails "no raw i18n key".
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
const OWNER = { role: 'biz_owner', permissions: [] }
const pathOf = (p) => new URL(p.url()).pathname
const at = (p, want) => p.waitForFunction((w) => location.pathname === w, { timeout: 15000 }, want).then(() => true, () => false)
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
const tabIds = (p) => p.$$eval('[data-test^=reporting-tab-]', (els) => els.map((e) => e.getAttribute('data-test').slice('reporting-tab-'.length)))

/** A fresh signed-in mock page at this size, as `me` (the opt-in mock role;
 *  null = none, the unrestricted reader), plus extra localStorage keys. */
async function reportingPage(browser, base, { width, height, touch }, me, extra = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((meKey, m, x) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (m) localStorage.setItem(meKey, JSON.stringify(m))
    for (const [k, v] of Object.entries(x)) localStorage.setItem(k, v)
  }, MOCK_ME_KEY, me, extra)
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
    time: e.querySelector('[data-test=releases-commit-time]')?.textContent.trim() || '',
    datetime: e.querySelector('[data-test=releases-commit-time]')?.getAttribute('datetime') || '',
    issues: [...e.querySelectorAll('[data-test=release-links-issue]')].map((a) => [a.textContent.trim(), a.getAttribute('href') || '']),
    topics: [...e.querySelectorAll('[data-test=release-links-discussion]')].map((a) => a.getAttribute('href') || ''),
    unknown: e.querySelector('[data-test=release-links-unknown]')?.textContent.trim() || '',
  })))
  ok(`${tag}: there are commit rows`, rows.length > 0, { rows: rows.length })
  // SPL-4789: an issue link per cited issue, a discussion link per topic, else "unknown"
  const linked = rows.filter((r) => r.issues.length)
  const badI = linked.filter((r) => r.issues.some(([k, h]) => !/^SPL-\d+$/.test(k) || !h.endsWith('/issues?issue=' + k)) || !r.topics.length || r.topics.some((h) => !/\/t\/[0-9a-f-]{36}$/.test(h)))
  ok(`${tag}: a commit's issues link to /issues?issue=<key>, its discussions to /t/<id>`, linked.length > 0 && badI.length === 0, { linked: linked.length, bad: badI.slice(0, 2) })
  const unknown = rows.filter((r) => !r.issues.length)
  ok(`${tag}: a commit with no issue reads "unknown"`, unknown.length > 0 && unknown.every((r) => r.unknown === 'unknown'), { unknown: unknown.length, bad: unknown.filter((r) => r.unknown !== 'unknown').slice(0, 2) })
  const wide = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
  ok(`${tag}: the links keep the page within the viewport`, wide <= 1, { overflow: wide })
  // SPL-4417 (owner, t1 6c689c19): every row shows its time, HH:MM UTC of its datetime
  const badT = rows.filter((r) => !/^\d\d:\d\d UTC$/.test(r.time) || new Date(r.datetime).toISOString().slice(11, 16) + ' UTC' !== r.time)
  ok(`${tag}: every commit row carries its HH:MM UTC time`, rows.length > 0 && badT.length === 0, badT.slice(0, 2))
  const bad = rows.filter((r) => !r.sha || !r.shaHref.endsWith('/releases/' + r.sha) || r.shaText !== r.sha.slice(0, 7))
  ok(`${tag}: every row's short sha links to /releases/<sha>`, rows.length > 0 && bad.length === 0, bad.slice(0, 2))
  const versioned = rows.filter((r) => r.version)
  const badV = versioned.filter((r) => !r.versionHref.endsWith('/releases/' + r.version))
  ok(`${tag}: a version badge links to /releases/<version>`, versioned.length > 0 && badV.length === 0, { versioned: versioned.length, bad: badV.slice(0, 2) })
  if (rows.length) {
    // The mock builds its commits from Date.now(), so the label cloud above
    // the rows changes height with the UTC hour; at 390x844 the first sha can
    // sit under the fixed bottom composer, where puppeteer's click (it only
    // scrolls an element that is off screen) lands on the composer. Centre
    // the sha first, as a person scrolls a row into view before a tap.
    const sha = `[data-test=releases-commit][data-sha="${rows[0].sha}"] [data-test=releases-commit-sha]`
    await p.$eval(sha, (e) => e.scrollIntoView({ block: 'center' }))
    await p.click(sha)
    ok(`${tag}: a click on the sha opens /releases/<sha>`, await at(p, '/releases/' + rows[0].sha), pathOf(p))
  }
  if (linked.length) {
    await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await waitFor(p, '[data-test=release-links-issue]')
    const first = '[data-test=release-links-issue]'
    const key = await p.$eval(first, (e) => { e.scrollIntoView({ block: 'center' }); return e.textContent.trim() })
    await p.click(first)
    ok(`${tag}: a click on an issue link opens it in Issues`, await at(p, '/issues'), pathOf(p))
    ok(`${tag}: ... with ?issue=<key>`, await p.evaluate(() => new URL(location.href).searchParams.get('issue')) === key, { key })
  }
}

async function cloud(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await waitFor(p, '[data-test=releases-commit]')
  await p.waitForFunction(() => document.querySelector('[data-test=releases-kinds] .rf-step-5'), { timeout: 15000 }).catch(() => {})
  const pills = await p.$$eval('[data-test=releases-kinds] button', (els) => els.map((e) => ({
    id: e.getAttribute('data-test').slice('releases-kind-'.length),
    n: Number(e.getAttribute('data-count')),
    px: parseFloat(getComputedStyle(e).fontSize),
  })))
  const mid = pills[Math.floor((pills.length - 1) / 2)] || {}
  const top = pills.reduce((a, b) => (b.n > a.n ? b : a), { n: -1 })
  ok(`${tag}: the most used kind is the centre pill`, pills.length > 2 && mid.id === top.id, pills.map((x) => `${x.id}:${x.n}`))
  ok(`${tag}: the centre pill is the largest`, pills.every((x) => x.px <= mid.px) && pills.some((x) => x.px < mid.px), pills.map((x) => `${x.id}:${x.px}`))
  await p.click(`[data-test=releases-kind-${top.id}]`)
  await p.waitForFunction((k) => {
    const got = [...document.querySelectorAll('[data-test=releases-commit-kind]')].map((e) => e.textContent.trim())
    return got.length > 0 && got.every((x) => x === k)
  }, { timeout: 15000 }, top.id).catch(() => {})
  const kinds = await p.$$eval('[data-test=releases-commit-kind]', (els) => [...new Set(els.map((e) => e.textContent.trim()))])
  ok(`${tag}: a click on a label shows that label's commits only`, kinds.length === 1 && kinds[0] === top.id, kinds)
  ok(`${tag}: the clicked label is pressed`, await p.$eval(`[data-test=releases-kind-${top.id}]`, (e) => e.getAttribute('aria-pressed')).catch(() => '') === 'true')
  const after = await p.$$eval('[data-test=releases-kinds] button', (els) => els.map((e) => e.getAttribute('data-test')))
  ok(`${tag}: the cloud keeps its places while a label is picked`, JSON.stringify(after) === JSON.stringify(pills.map((x) => 'releases-kind-' + x.id)), after)
  ok(`${tag}: no sideways scroll on Releases`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-cloud-${tag}.png` })
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
  ok(`${tag}: a member's bar has no Marketing tab (Q8)`, !tabs.includes('marketing'), tabs)
  await p.goto(base + '/reporting/marketing', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: a member on /reporting/marketing gets the refusal line`, await waitFor(p, '[data-test=reporting-marketing-forbidden]'))
  ok(`${tag}: and no card`, (await p.$$('[data-test^=reporting-marketing-card-]')).length === 0)
  /* SPL-4453 (row 9 of SPL-4422): the page reads /v1/view/me first and sends no report read the hub refuses. the mock hub records the refusal itself (mockRefused). CONTROL: the page before it (7adacb96e) puts 'GET /v1/reporting/marketing' here */
  const refused = await p.evaluate(() => globalThis.SPOOL_MOCK_403 || [])
  ok(`${tag}: a member on /reporting/marketing sends 0 refused reads`, refused.length === 0, refused)
}

const STAGES = ['reach', 'engagement', 'acquisition', 'conversion', 'revenue', 'retention', 'content_seo']

async function marketing(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: an admin's bar shows the Marketing tab`, await waitFor(p, '[data-test=reporting-tab-marketing]'), await tabIds(p))
  await p.$eval('[data-test=reporting-tab-marketing]', (e) => e.scrollIntoView({ block: 'center', inline: 'center' }))
  await p.click('[data-test=reporting-tab-marketing]')
  ok(`${tag}: the Marketing tab opens /reporting/marketing`, await at(p, '/reporting/marketing'), pathOf(p))
  ok(`${tag}: the stage cards render`, await waitFor(p, '[data-test=reporting-marketing-cards]'))
  const cards = await p.$$eval('[data-test^=reporting-marketing-card-]:not([data-test=reporting-marketing-card-empty])', (els) => els.map((e) => ({
    id: e.getAttribute('data-test').slice('reporting-marketing-card-'.length),
    title: e.querySelector('h3')?.textContent.trim() || '',
    empty: Boolean(e.querySelector('[data-test=reporting-marketing-card-empty]')),
  })))
  ok(`${tag}: seven cards in the overview's order`, JSON.stringify(cards.map((c) => c.id)) === JSON.stringify(STAGES), cards.map((c) => c.id))
  ok(`${tag}: every card has a title and is empty`, cards.length === 7 && cards.every((c) => c.title && c.empty), cards.filter((c) => !c.title || !c.empty))
  const line = await p.$eval('[data-test=reporting-marketing-attribution]', (e) => e.textContent.trim()).catch(() => '')
  ok(`${tag}: the attribution line is last touch, 28 days (Q7)`, /Last touch/.test(line) && /28/.test(line), line)
  ok(`${tag}: no sideways scroll on Marketing`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-marketing-${tag}.png` })
}

/* spec 125 B7: an admin of the operator workspace; with no spool.mock.me
   the mock plays the Netvisor owner, with a role another person of the
   Netvisor workspace (SPL-4792) */
const OPERATOR = { 'spool.mock.operator_admin': '1' }
const AGENT = { role: 'pure_agent', permissions: [] }
const noRawKey = (p) => p.evaluate(() => !/reporting\.(finance|tab)\./.test(document.body.innerText))

async function finance(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: the Netvisor owner's bar shows the Finance tab`, await waitFor(p, '[data-test=reporting-tab-finance]'), await tabIds(p))
  await p.$eval('[data-test=reporting-tab-finance]', (e) => e.scrollIntoView({ block: 'center', inline: 'center' }))
  await p.click('[data-test=reporting-tab-finance]')
  ok(`${tag}: the Finance tab opens /reporting/finance`, await at(p, '/reporting/finance'), pathOf(p))
  ok(`${tag}: the forecast card renders`, await waitFor(p, '[data-test=finance-forecast]'))
  const head = await p.evaluate(() => ({
    voucher: document.querySelector('[data-test=finance-voucher]')?.getAttribute('data-date') || '',
    voucherText: document.querySelector('[data-test=finance-voucher]')?.textContent.trim() || '',
    env: document.querySelector('[data-test=finance-env]')?.textContent.trim() || '',
    totals: [...document.querySelectorAll('[data-test=finance-total]')].map((e) => e.textContent.trim()),
    cats: [...document.querySelectorAll('[data-test=finance-category]')].map((e) => e.getAttribute('data-category')),
    items: document.querySelectorAll('[data-test=finance-item]').length,
    overdue: document.querySelectorAll('[data-test=finance-item-overdue]').length,
  }))
  ok(`${tag}: the newest bank voucher date badge shows its date`, /^\d{4}-\d{2}-\d{2}$/.test(head.voucher) && head.voucherText.includes(head.voucher), head)
  ok(`${tag}: the env badge names the Netvisor company`, head.env.length > 0, head.env)
  ok(`${tag}: the month-end sum shows in its currency`, head.totals.length === 1 && /^-?[\d ]+\.\d\d EUR$/.test(head.totals[0]), head.totals)
  ok(`${tag}: subtotals by category, the item table with an overdue mark`, head.cats.length >= 3 && head.items >= 3 && head.overdue >= 1, head)
  for (const slice of ['vendor', 'cost_type', 'cost_centre']) {
    await p.$eval(`[data-test=finance-slice-${slice}]`, (e) => e.scrollIntoView({ block: 'center' }))
    await p.click(`[data-test=finance-slice-${slice}]`)
    await p.waitForFunction((s) => document.querySelector('[data-test=finance-costs-table]')?.getAttribute('data-slice') === s, { timeout: 15000 }, slice).catch(() => {})
    const t = await p.evaluate(() => ({
      slice: document.querySelector('[data-test=finance-costs-table]')?.getAttribute('data-slice') || '',
      pressed: document.querySelector('[data-test^=finance-slice-][aria-pressed=true]')?.getAttribute('data-test') || '',
      groups: [...document.querySelectorAll('[data-test=finance-cost-group]')].map((e) => e.textContent.trim()),
      excluded: Number(document.querySelector('[data-test=finance-costs-excluded]')?.getAttribute('data-lines') || 0),
    }))
    ok(`${tag}: card costs by ${slice}`, t.slice === slice && t.pressed === 'finance-slice-' + slice && t.groups.length > 0, t)
    if (slice === 'vendor') ok(`${tag}: the spec-123 vendor is left out (Q4) and counted in the note`, t.excluded >= 1 && !t.groups.includes('Example Cloud Ltd'), t)
  }
  await p.$eval('[data-test=finance-refresh]', (e) => e.scrollIntoView({ block: 'center' }))
  await p.click('[data-test=finance-refresh]')
  ok(`${tag}: Refresh now records the request`, await waitFor(p, '[data-test=finance-refresh-requested]'))
  const bank = '[data-test=finance-settings-bank]'
  await p.$eval(bank, (e) => e.scrollIntoView({ block: 'center' }))
  await p.$eval(bank, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(bank, '12ab')
  /* centre Save first: at 390x844 it can sit under the fixed bottom composer */
  await p.$eval('[data-test=finance-settings-save]', (e) => e.scrollIntoView({ block: 'center' }))
  await p.click('[data-test=finance-settings-save]')
  ok(`${tag}: a bad account number is refused before it is sent`, await p.waitForSelector('[data-test=finance-settings-invalid][data-field=bank_account]', { timeout: 15000 }).then(() => true, () => false))
  await p.$eval(bank, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(bank, '9011')
  await p.$eval('[data-test=finance-settings-save]', (e) => e.scrollIntoView({ block: 'center' }))
  await p.click('[data-test=finance-settings-save]')
  ok(`${tag}: the owner saves the account numbers`, await waitFor(p, '[data-test=finance-settings-saved]'))
  ok(`${tag}: no raw i18n key on Finance`, await noRawKey(p))
  ok(`${tag}: no sideways scroll on Finance`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-finance-${tag}.png`, fullPage: true })
}

async function financeMember(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: a member's bar shows the Finance tab (WS)`, await waitFor(p, '[data-test=reporting-tab-finance]'), await tabIds(p))
  await p.goto(base + '/reporting/finance', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: a member sees the forecast card`, await waitFor(p, '[data-test=finance-forecast]'))
  await waitFor(p, '[data-test=finance-costs-table]')
  const v = await p.evaluate(() => ({
    items: document.querySelectorAll('[data-test=finance-item]').length,
    groups: [...document.querySelectorAll('[data-test=finance-cost-group]')].map((e) => e.textContent.trim()),
    excluded: Number(document.querySelector('[data-test=finance-costs-excluded]')?.getAttribute('data-lines') || 0),
    refresh: document.querySelectorAll('[data-test=finance-refresh]').length,
    settings: document.querySelectorAll('[data-test=finance-settings]').length,
  }))
  ok(`${tag}: a member reads the items and the card costs, the spec-123 vendor left out`, v.items > 0 && v.groups.length > 0 && !v.groups.includes('Example Cloud Ltd') && v.excluded > 0, v)
  ok(`${tag}: a member has no Refresh now and no settings form (the owner's)`, v.refresh === 0 && v.settings === 0, v)
  const refused = await p.evaluate(() => globalThis.SPOOL_MOCK_403 || [])
  ok(`${tag}: a member sends 0 refused reads`, refused.length === 0, refused)
  ok(`${tag}: no raw i18n key for a member`, await noRawKey(p))
  ok(`${tag}: no sideways scroll on a member's Finance`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-finance-member-${tag}.png`, fullPage: true })
}

async function financeRefused(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await waitFor(p, '[data-test=reporting-tab-releases]')
  await new Promise((r) => setTimeout(r, 1000))
  const tabs = await tabIds(p)
  ok(`${tag}: an agent seat's bar has no Finance tab (agents never see the figures)`, tabs.includes('releases') && !tabs.includes('finance'), tabs)
  await p.goto(base + '/reporting/finance', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: an agent seat on /reporting/finance gets the refusal line`, await waitFor(p, '[data-test=finance-forbidden]'))
  const leak = await p.evaluate(() => ({
    figures: document.querySelectorAll('[data-test=finance-forecast], [data-test=finance-costs], [data-test=finance-settings], [data-test=finance-voucher]').length,
    labels: /Example (customer|supplier|Software|Cloud)/.test(document.body.innerText),
  }))
  ok(`${tag}: and no figure, no label, no settings`, leak.figures === 0 && !leak.labels, leak)
  ok(`${tag}: no raw i18n key on the refusal`, await noRawKey(p))
}

async function incomes(p, base, tag) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok(`${tag}: the owner's bar shows the Incomes tab`, await waitFor(p, '[data-test=reporting-tab-incomes]'), await tabIds(p))
  await p.$eval('[data-test=reporting-tab-incomes]', (e) => e.scrollIntoView({ block: 'center', inline: 'center' }))
  await p.click('[data-test=reporting-tab-incomes]')
  ok(`${tag}: the Incomes tab opens /reporting/incomes`, await at(p, '/reporting/incomes'), pathOf(p))
  ok(`${tag}: the month table renders`, await waitFor(p, '[data-test=reporting-incomes-table]'))
  const t = await p.$eval('[data-test=reporting-incomes-table]', (tb) => ({
    months: [...tb.querySelectorAll('tbody tr')].map((r) => r.getAttribute('data-test')),
    march: tb.querySelector('[data-test=reporting-incomes-month-2025-03] td')?.textContent.trim() || '',
    jan: [...(tb.querySelector('[data-test=reporting-incomes-month-2025-01]')?.querySelectorAll('td') || [])].map((c) => c.textContent.trim()),
    total: [...(tb.querySelector('[data-test=reporting-incomes-total-EUR]')?.querySelectorAll('td') || [])].map((c) => c.textContent.trim()).filter(Boolean),
    totalVisible: tb.querySelector('[data-test=reporting-incomes-total-EUR] td:last-child')?.getBoundingClientRect().right <= window.innerWidth,
  })).catch(() => ({ months: [], march: '', jan: [], total: [], totalVisible: false }))
  ok(`${tag}: twelve month rows, January first`, t.months.length === 12 && t.months[0] === 'reporting-incomes-month-2025-01' && t.months[11] === 'reporting-incomes-month-2025-12', t.months)
  ok(`${tag}: a month with no invoice shows a dash, never a zero`, t.march === '–', t.march)
  ok(`${tag}: January shows its invoice, hours and total`, t.jan[0] === 'INV-0001' && t.jan[3] === '100' && /15,625\.00/.test(t.jan[6]), t.jan)
  ok(`${tag}: the year total sums the invoices (180 h, 28,125.00)`, t.total[0] === '180' && /28,125\.00/.test(t.total[t.total.length - 1]), t.total)
  ok(`${tag}: the year's total amount is on screen without scrolling`, t.totalVisible === true)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-incomes-${tag}.png` })
  ok(`${tag}: the year picker lists the years`, JSON.stringify(await p.$$eval('[data-test=reporting-incomes-year] option', (os) => os.map((o) => o.value))) === JSON.stringify(['2025', '2024']))
  await p.select('[data-test=reporting-incomes-year]', '2024')
  ok(`${tag}: an empty year shows its line and no table`, await waitFor(p, '[data-test=reporting-incomes-empty]') && !(await p.$('[data-test=reporting-incomes-table]')))
  ok(`${tag}: no sideways scroll on Incomes`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
}

async function noIncomes(p, base, tag, who) {
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await waitFor(p, '[data-test=reporting-tab-releases]')
  await new Promise((r) => setTimeout(r, 500))
  ok(`${tag}: ${who}'s bar has no Incomes tab (owner only)`, !(await tabIds(p)).includes('incomes'), await tabIds(p))
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const size of [{ width: 1440, height: 900, touch: false }, { width: 390, height: 844, touch: true }]) {
    const tag = `${size.width}px`
    let { ctx, p } = await reportingPage(browser, server.base, size, ADMIN)
    await releases(p, server.base, tag)
    await cloud(p, server.base, tag)
    await sql(p, server.base, tag)
    await marketing(p, server.base, tag)
    await noIncomes(p, server.base, tag, 'an admin')
    if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/reporting-sql-${size.width}.png` })
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, MEMBER))
    await nonAdmin(p, server.base, tag)
    await noIncomes(p, server.base, tag, 'a member')
    await p.goto(server.base + '/reporting/incomes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok(`${tag}: a member on /reporting/incomes gets the refusal line`, await waitFor(p, '[data-test=reporting-incomes-forbidden]'))
    ok(`${tag}: and no table`, !(await p.$('[data-test=reporting-incomes-table]')))
    ok(`${tag}: a member on /reporting/incomes sends 0 refused reads`, (await p.evaluate(() => globalThis.SPOOL_MOCK_403 || [])).length === 0)
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, OWNER))
    await incomes(p, server.base, tag)
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, null, OPERATOR))
    await finance(p, server.base, tag)
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, ADMIN, OPERATOR))
    await financeMember(p, server.base, tag)
    await ctx.close();
    ({ ctx, p } = await reportingPage(browser, server.base, size, AGENT))
    await financeRefused(p, server.base, tag)
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
