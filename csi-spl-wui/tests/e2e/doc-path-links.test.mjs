// SPL-1592 (owner HUM-10, t1 cda174ef): "All of the references in the internal
// MD docs or the QTO docs should be converted to clickable links ... in all of
// the message cards and in all of the issues' parts". A repo doc path written
// as text, "Source: <path>", is a link to /docs/<path> (utils/doc-paths.mjs);
// an unknown path stays text.
//
// 1. An issue description (MessageBody forced to markdown, MarkdownBlock):
//    the listed path is a link, the unknown one is not; a click lands on the
//    doc, rendered, in this tab. SPL-2425: a spec folder written as text,
//    "Spec: csi-spl-doc/specs/<NNN-slug>", links to its spec.md.
// 2. A plain message card (parseBody -> MessageRuns): a path in text and a
//    path as a whole `code` span link; a fenced one stays code.
//
// Control: before SPL-1592 the description holds no a[href^="/docs/"], so
// check 1 FAILS; before SPL-2425 the spec folder is text, so 1e FAILS.
//
// Run: node tests/e2e/doc-path-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* a doc the mock store lists (docs-mock.mjs), and one it does not */
const DOC = 'csi-spl-doc/specs/072-rapid-deployability/spec.md'
const GONE = 'csi-spl-doc/specs/999-not-a-spec/tasks.md'
/* the folder of DOC, as an issue's Spec: line names it (SPL-2425) */
const DIR = 'csi-spl-doc/specs/072-rapid-deployability'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
        defaultViewport: { width: 1280, height: 860 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const MSG_ID = 'f5920000-0000-4000-8000-000000000001'
const carrier = {
  v: 1, files: [], channel: 'lobby', parent_task_id: null, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', is_parent: 1, msg_id: MSG_ID,
  task_id: 'f5920000-0000-4000-8000-0000000000a1',
  body: `Source: ${DOC} and \`${DOC}\`, not ${GONE}\n\`\`\`\n${DOC}\n\`\`\``,
  ts: '2026-12-31T23:59:00Z',
}

const docLinks = (p, scope) => p.evaluate((sel) => {
  const r = document.querySelector(sel)
  return [...(r ? r.querySelectorAll('a[href^="/docs/"]') : [])].map((a) => ({
    text: a.textContent || '', href: a.getAttribute('href') || '', target: a.getAttribute('target') || '', code: Boolean(a.querySelector('code')),
  }))
}, scope)
const linksIn = (p, scope, min) => p.waitForFunction((sel, n) => {
  const r = document.querySelector(sel)
  return r && r.querySelectorAll('a[href^="/docs/"]').length >= n
}, { timeout: 20000 }, scope, min).then(() => true, () => false)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 300)))

  /* 1. an issue description */
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  const title = 'SPL-1592 doc path link'
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  const key = await p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
  await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  await p.waitForSelector('[data-test=issues-detail-rendered]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail-rendered]')
  await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-body]', `Source: ${DOC} and ${GONE}, Spec: ${DIR}`)
  await p.click('[data-test=issues-detail-title]')
  const DESC = '[data-test=issues-detail-rendered]'
  ok('1a the description renders a listed doc path as a link', await linksIn(p, DESC, 1))
  await linksIn(p, DESC, 2)
  const desc = await docLinks(p, DESC)
  ok('1b it opens /docs/<path> in this tab, the text as written', desc.length === 2 && desc[0].href === `/docs/${DOC}` && desc[0].text === DOC && !desc[0].target, desc)
  ok('1e the Spec: folder is a link to its spec.md, the text as written', desc[1]?.href === `/docs/${DOC}` && desc[1]?.text === DIR && !desc[1]?.target, desc)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/issue-spec-link.png` })
  ok('1c CONTROL an unknown path stays text', !desc.some((a) => a.text.includes('999')) &&
    await p.$eval(DESC, (el, g) => el.textContent.includes(g), GONE), desc)
  await p.click(`${DESC} a[href="/docs/${DOC}"]`)
  const landed = await p.waitForFunction((want) => {
    const c = document.querySelector('[data-test=docs-content]')
    return c && c.getAttribute('data-page') === want && c.querySelector('[data-testid=md-block][data-rendered=true]')
  }, { timeout: 15000 }, DOC).then(() => true, () => false)
  ok('1d a click lands on the doc, rendered', landed && new URL(p.url()).pathname.endsWith(`/docs/${DOC}`), p.url())

  /* 2. a plain message card */
  await p.evaluate((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, [carrier])
  await p.goto(server.base + '/channel/lobby', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  const CARD = `article.msg[data-msg-id="${MSG_ID}"]`
  ok('2a a message card links the path in text and in a whole code span', await linksIn(p, CARD, 2))
  const card = await docLinks(p, CARD)
  ok('2b both open /docs/<path>; the code span stays code inside the link', card.length === 2 && card.every((a) => a.href === `/docs/${DOC}` && !a.target) && card.some((a) => a.code) && card.some((a) => !a.code), card)
  ok('2c CONTROL the fenced copy and the unknown path stay text', await p.$eval(CARD, (el) => el.querySelectorAll('pre a, .code-block a').length === 0), card)
  ok('no page errors', errors.length === 0, errors)
  try { await p.evaluate(() => localStorage.removeItem('spool.mock.extra-messages')) } catch { /* gone */ }
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
if (failed.length) {
  console.log(`doc-path-links: ${failed.length} of ${results.length} FAILED`)
  process.exit(1)
}
console.log(`doc-path-links: all ${results.length} passed`)
