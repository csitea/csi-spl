// SPL-1291 (owner, t1 2b25c535): a link to a doc in a message opens our own
// docs store. Two lobby messages carry links to this instance's repository
// (cnf repo_web_url; the e2e bundle bakes an example one, wf 10's mock
// generate): a markdown body (MarkdownBlock) and a plain body with bare URLs
// (MessageRuns). A blob link to a .md and a bare repo-relative .md path
// become /docs/<path> in this tab, the anchor kept; a click (desktop) or a
// tap (390 px phone) opens the doc. A doc the store has not published opens
// to a short note plus the repository link, never a dead page.
//
// Control: the commit link in the same bodies stays on the repository, in a
// new tab. Before SPL-1291 the doc links point at the repository too, so the
// /docs checks FAIL.
//
// Run: node tests/e2e/docs-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset; export
// NUXT_PUBLIC_REPO_WEB_URL and NUXT_PUBLIC_REPO_HELP_PATH first)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const DOC = 'csi-spl-doc/doc/help/how-to-post.md'
const REL = 'csi-spl-doc/specs/072-rapid-deployability/spec.md'
const GONE = 'csi-spl-doc/doc/md/not-published-yet.md'
const SHA = '0c6c9e0f'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const MD_ID = 'f5120000-0000-4000-8000-000000000001'
const PLAIN_ID = 'f5120000-0000-4000-8000-000000000002'
const row = (msgId, taskId, body, ts) => ({
  v: 1, files: [], channel: 'lobby', parent_task_id: null, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', is_parent: 1, msg_id: msgId, task_id: taskId, body, ts,
})
const carriers = (repo) => [
  row(MD_ID, 'f5120000-0000-4000-8000-0000000000a1',
    `## Docs\n\nRead [how to post](${repo}/blob/master/${DOC}#a-post-is-markdown), the [spec](${REL}) and [the new doc](${repo}/blob/master/${GONE}).\n\nLanded in [${SHA}](${repo}/commit/${SHA}).`,
    '2026-12-31T23:58:00Z'),
  row(PLAIN_ID, 'f5120000-0000-4000-8000-0000000000a2',
    `see ${repo}/blob/master/${DOC} and ${repo}/commit/${SHA}`,
    '2026-12-31T23:59:00Z'),
]

const links = (p, id) => p.evaluate((msgId) => {
  const r = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
  return [...(r ? r.querySelectorAll('a.msg-link') : [])].map((a) => ({
    text: a.textContent || '', href: a.getAttribute('href') || '', target: a.getAttribute('target') || '',
  }))
}, id)
const docShown = (p, path) => p.waitForFunction((want) => {
  const c = document.querySelector('[data-test=docs-content]')
  return c && c.getAttribute('data-page') === want && c.querySelector('[data-testid=md-block][data-rendered=true]')
}, { timeout: 15000 }, path).then(() => true, () => false)

async function run(browser, base, phone) {
  const tag = phone ? '390 phone' : '1280 desktop'
  console.log(`-- ${tag}`)
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport(phone ? { width: 390, height: 740, isMobile: true, hasTouch: true } : { width: 1280, height: 800 })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.goto(`${base}/`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  const cfg = await p.evaluate(() => {
    const pub = (window.__NUXT__ && window.__NUXT__.config && window.__NUXT__.config.public) || {}
    return { web: String(pub.repoWebUrl || '').replace(/\/+$/, ''), help: String(pub.repoHelpPath || '') }
  })
  ok(`${tag}: the bundle names a repository (NUXT_PUBLIC_REPO_* baked for e2e)`, Boolean(cfg.web && cfg.help), cfg)
  await p.evaluate((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, carriers(cfg.web))
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${MD_ID}"] [data-testid=md-block][data-rendered=true]`, { timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForSelector(`article.msg[data-msg-id="${PLAIN_ID}"] a.msg-link`, { timeout: NAV_TIMEOUT }).catch(() => null)

  const md = await links(p, MD_ID)
  const post = md.find((a) => a.text === 'how to post')
  ok(`${tag}: a markdown doc link opens /docs/<path>, anchor kept, this tab`,
    post && post.href === `/docs/${DOC}#a-post-is-markdown` && !post.target, md)
  const spec = md.find((a) => a.text === 'spec')
  ok(`${tag}: a bare repo-relative .md path opens /docs/<path>`, spec && spec.href === `/docs/${REL}`, md)
  const commit = md.find((a) => a.text === SHA)
  ok(`${tag}: CONTROL the commit link stays on the repository, new tab`,
    commit && commit.href === `${cfg.web}/commit/${SHA}` && commit.target === '_blank', md)
  const plain = await links(p, PLAIN_ID)
  ok(`${tag}: a bare blob URL in a plain body opens /docs/<path>`,
    plain.some((a) => a.href === `/docs/${DOC}` && !a.target), plain)
  ok(`${tag}: CONTROL a bare commit URL in a plain body stays on the repository`,
    plain.some((a) => a.href === `${cfg.web}/commit/${SHA}` && a.target === '_blank'), plain)

  /* open the doc the way the reader would */
  const a = await p.$(`article.msg[data-msg-id="${MD_ID}"] a.msg-link[href^="/docs/${DOC}"]`)
  if (a) {
    await a.scrollIntoView()
    if (phone) await a.tap()
    else await a.click()
  }
  await p.waitForFunction((want) => location.pathname === want, { timeout: 10000 }, `/docs/${DOC}`).catch(() => {})
  ok(`${tag}: one ${phone ? 'tap' : 'click'} opens the doc in the app`, new URL(p.url()).pathname === `/docs/${DOC}` && await docShown(p, DOC), p.url())
  ok(`${tag}: the anchor rides along`, new URL(p.url()).hash === '#a-post-is-markdown', p.url())

  await p.goto(`${base}/docs/${GONE}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const gone = await p.waitForSelector('[data-test=docs-repo-link]', { visible: true, timeout: 15000 }).then(() => true, () => false)
  const repo = gone ? await p.$eval('[data-test=docs-repo-link]', (e) => ({ href: e.getAttribute('href'), target: e.getAttribute('target') })) : null
  const want = cfg.web + (/^((?:\/-)?\/blob\/[^/]+\/)/.exec(cfg.help) || [])[1] + GONE
  ok(`${tag}: a doc the store has not published shows a note and the repository link`,
    gone && repo.href === want && repo.target === '_blank' && Boolean(await p.$('[data-test=docs-missing]')), { repo, want })
  ok(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const srv = await startServer()
const browser = await launch()
try {
  await run(browser, srv.base, false)
  await run(browser, srv.base, true)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ndocs-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
