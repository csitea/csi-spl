// HUM-10: a git commit hash written in a message links to this instance's
// repository, <repoWebUrl><repoCommitPath><hash> (cnf env.wui.repo_*). The
// e2e bundle bakes example values (wf 10/11 mock generate:
// NUXT_PUBLIC_REPO_WEB_URL + NUXT_PUBLIC_REPO_COMMIT_PATH); the deployed one
// reads them from /config.json. The uuid, the plain number and the hash in
// inline code in the same body are the controls: they stay text.
//
// Run: node tests/e2e/commit-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset; export the
// two NUXT_PUBLIC_REPO_* values first)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const HASH = '785470e9c'
const CODED = 'c90606372'
const UUID = '00000000-0000-4000-8000-0000000000aa'
const BODY = `landed in ${HASH} on master\nnot a commit ${UUID} or 20261004\ncode \`${CODED}\``

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

const carrier = {
  v: 1,
  files: [],
  channel: 'lobby',
  parent_task_id: null,
  from: 'HUM-1',
  from_box: 'box-wui',
  to: '@channel',
  to_box: 'box-wui',
  kind: 'note',
  is_parent: 1,
  msg_id: 'f4010000-0000-4000-8000-000000000001',
  task_id: 'f4020000-0000-4000-8000-000000000001',
  body: BODY,
  ts: '2026-12-31T23:59:00Z',
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

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.evaluateOnNewDocument((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, [carrier])
  await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${carrier.msg_id}"]`, { timeout: NAV_TIMEOUT })

  const cfg = await p.evaluate(() => {
    const pub = (window.__NUXT__ && window.__NUXT__.config && window.__NUXT__.config.public) || {}
    return { web: String(pub.repoWebUrl || ''), path: String(pub.repoCommitPath || '') }
  })
  ok('the bundle names a repository (NUXT_PUBLIC_REPO_* baked for e2e)', Boolean(cfg.web && cfg.path), cfg)
  const want = cfg.web.replace(/\/+$/, '') + cfg.path + HASH

  /* the matcher is its own chunk: wait for it, a body re-renders once it lands */
  const link = await p.waitForSelector(`article.msg[data-msg-id="${carrier.msg_id}"] a.msg-link[href$="${HASH}"]`, { visible: true, timeout: 15000 })
    .then(() => true, () => false)
  const s = await p.evaluate((id, uuid, coded) => {
    const row = document.querySelector(`article.msg[data-msg-id="${id}"]`)
    const links = [...(row ? row.querySelectorAll('a.msg-link') : [])].map((a) => ({
      text: a.textContent || '', href: a.getAttribute('href') || '', target: a.getAttribute('target') || '',
    }))
    return {
      links,
      uuidLinked: links.some((a) => a.text.includes(uuid)),
      numberLinked: links.some((a) => a.text === '20261004'),
      codedLinked: links.some((a) => a.text === coded),
      codedShown: !!(row && [...row.querySelectorAll('code')].some((c) => c.textContent === coded)),
    }
  }, carrier.msg_id, UUID, CODED)
  const hashLink = s.links.find((a) => a.text === HASH)
  ok('a commit hash links to <repoWebUrl><repoCommitPath><hash>', link && hashLink && hashLink.href === want, { want, links: s.links })
  ok('the repository opens in a new tab', hashLink && hashLink.target === '_blank', hashLink)
  ok('a uuid and a plain number stay text', !s.uuidLinked && !s.numberLinked, s)
  ok('a hash in inline code stays code', !s.codedLinked && s.codedShown, s)
  ok('no page error', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncommit-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
