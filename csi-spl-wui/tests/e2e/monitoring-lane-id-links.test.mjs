// SPL-4798 (owner HUM-10, t1 0c2d08a2, msgs e7009f10 and ea369ab0: "there are
// still lanes created without a proper link to their discusions" ... "a
// renderer on the page ... which continas those to links"). In a REAL
// browser, mock bundle, at 1440 and 390, the mock fleet with the ids an agent
// writes ('links'): c-791 on dispatch-5e7b15c9 with SPL-4791 (wip) and DVN-3
// (another prefix), c-792 an old row whose discussion and issue are lane (c)'s
// `unknown`. Monitoring -> Lanes and -> Topics render them through the one
// renderer (utils/note-links.mjs noteLinkHref):
//
//   1  Lanes: dispatch-<topic8> links the task /t/dispatch-5e7b15c9
//   2  Lanes: SPL-4791 links /issues?issue=SPL-4791
//   3  Lanes CONTROL: DVN-3 of the page's own workspace (another prefix, no
//      host for it) stays text; `unknown` stays text in both cells
//   4  Topics: the same three cells, the same way
//   5  no page error
//
// RED on master: 1 and 4 (the task is plain text there).
// The other workspace's host (tenant hosts on) is not in a mock bundle: the
// unit tests (monitoring-lane-links.test.mjs) cover it.
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e monitoring-lane-id-links
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { LANES_MOCK_KEY } from '../../src/utils/monitoring-lanes.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined || pass ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const VIEWPORTS = [
  { tag: '1440', vp: { width: 1440, height: 900 } },
  { tag: '390', vp: { width: 390, height: 844, isMobile: true, hasTouch: true } },
]
const TASK = 'dispatch-5e7b15c9'
const SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })
const SEED = { 'spool.mock.session': SESSION, [TOKENS_MOCK_OPERATOR_KEY]: '1', [LANES_MOCK_KEY]: 'links' }

async function open(browser, vp, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
  }, SEED)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

/* the anchors and the text of one cell */
const cell = (p, sel) => p.$eval(sel, (e) => ({
  text: e.textContent.replace(/\s+/g, ' ').trim(),
  links: [...e.querySelectorAll('a')].map((a) => decodeURIComponent(a.getAttribute('href') || '') + '=' + a.textContent.replace(/\s+/g, ' ').trim()),
})).catch(() => ({ text: '', links: [] }))
const waitRows = (p, sel, n) => p.waitForFunction((s, k) => document.querySelectorAll(s).length === k, { timeout: 20000 }, sel, n).then(() => true, () => false)

const server = await startServer()
const browser = await launch()
try {
  for (const { tag, vp } of VIEWPORTS) {
    const a = await open(browser, vp, '/monitoring/lanes')
    const { p } = a
    ok(`0 ${tag}: Lanes shows the five mock lanes`, await waitRows(p, '[data-test=lanes-row]', 5))
    const row = (agent, col) => cell(p, `[data-test=lanes-row][data-agent="${agent}"] [data-test=lanes-${col}]`)
    const topic = await row('c-791', 'topic')
    ok(`1 ${tag}: Lanes: dispatch-<topic8> links the task`, topic.links.join() === `/t/${TASK}=${TASK}`, topic)
    const issues = await row('c-791', 'issues')
    ok(`2 ${tag}: Lanes: SPL-4791 links its issue`, issues.links.join() === '/issues?issue=SPL-4791=SPL-4791', issues)
    ok(`3 ${tag}: Lanes CONTROL: DVN-3 of this workspace's page stays text`, issues.text === 'SPL-4791DVN-3' && !issues.links.some((l) => l.includes('DVN-3')), issues)
    const oldTopic = await row('c-792', 'topic')
    const oldIssues = await row('c-792', 'issues')
    ok(`3b ${tag}: Lanes CONTROL: \`unknown\` stays text in the discussion and the issue cell`, oldTopic.text === 'unknown' && oldTopic.links.length === 0
      && oldIssues.text === 'unknown' && oldIssues.links.length === 0, { oldTopic, oldIssues })
    await a.ctx.close()

    const b = await open(browser, vp, '/monitoring/topics')
    const q = b.p
    ok(`4 ${tag}: Topics shows a row per topic (3 + the task + unknown)`, await waitRows(q, '[data-test=topics-row]', 5))
    const trow = (id, col) => cell(q, `[data-test=topics-row][data-topic="${id}"] [data-test=topics-${col}]`)
    const ttopic = await trow(TASK, 'topic')
    ok(`4a ${tag}: Topics: dispatch-<topic8> links the task`, ttopic.links.join() === `/t/${TASK}=${TASK}`, ttopic)
    const tissues = await trow(TASK, 'issues')
    ok(`4b ${tag}: Topics: SPL-4791 links, DVN-3 stays text`, tissues.links.length === 1 && tissues.links[0].startsWith('/issues?issue=SPL-4791=SPL-4791')
      && tissues.text.includes('DVN-3'), tissues)
    const tunk = await trow('unknown', 'topic')
    const tunkIssues = await trow('unknown', 'issues')
    ok(`4c ${tag}: Topics CONTROL: \`unknown\` stays text`, tunk.text === 'unknown' && tunk.links.length === 0 && tunkIssues.text === 'unknown' && tunkIssues.links.length === 0, { tunk, tunkIssues })
    await b.ctx.close()
    ok(`5 ${tag}: no page error`, a.errors.length === 0 && b.errors.length === 0, [...a.errors, ...b.errors])
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmonitoring-lane-id-links: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
