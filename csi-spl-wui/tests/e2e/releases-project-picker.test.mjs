// B-7 (spec 143 releases-projects.md section 7, row B-7, SPL-5853): the
// project drop box, the repo pills and the URL on /reporting/releases,
// against the mock bundle (two projects, the second with two repos), at
// 1440x900 and 390x844:
//   P1 the default project: the drop box shows it, the URL stays clean,
//      no repo pills (one repo);
//   P2 pick the second project: ?project= in the URL, its commits, the repo
//      pills with counts, the repo name on rows, Unreleased > 0;
//   P3 reload keeps the pick;
//   P4 a repo pill filters to that repo and goes into the URL;
//   P5 Back undoes the repo pick, Back again the project pick;
//   P6 a stale ?project= or ?repo= falls back to the default, no error;
//   P7 the label cloud after a switch with a kind picked shows the NEW
//      project's counts (equal to a fresh read with no pick), not the old.
// RED CONTROL (row B-7): drop project and repo from the cloud's cache key
// in pages/reporting/releases.vue (`const key = base + ...` without the
// project): P7 fails, the cloud keeps the old project's counts.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e releases-project-picker
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

const SIZES = [
  { width: 1440, height: 900, touch: false },
  { width: 390, height: 844, touch: true },
]
const SHOP = 'web-shop'
const SHOP_WUI = 'example/web-shop-wui'

async function open(browser, base, { width, height, touch }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify({ role: 'admin', permissions: [] }))
  })
  return { ctx, p }
}

const goto = async (p, url) => {
  await p.goto(url, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=releases-commit]', { visible: true, timeout: 20000 })
}
/* the page as a reader sees it */
const view = (p) => p.evaluate(() => {
  const all = (sel) => [...document.querySelectorAll(sel)]
  const q = new URLSearchParams(location.search)
  return {
    project: q.get('project'), repo: q.get('repo'),
    select: document.querySelector('[data-test=releases-project]')?.value ?? null,
    repoPills: all('[data-test^=releases-repo-]').map((e) => [e.getAttribute('data-test').slice('releases-repo-'.length), Number(e.getAttribute('data-count')), e.getAttribute('aria-pressed')]),
    subjects: all('[data-test=releases-commit-subject]').map((e) => e.textContent.trim()),
    rowRepos: [...new Set(all('[data-test=releases-commit-repo]').map((e) => e.textContent.trim()))].sort(),
    unreleased: document.querySelector('[data-test=releases-kpi-unreleased-value]')?.textContent.trim() ?? null,
    kinds: Object.fromEntries(all('[data-test^=releases-kind-]').map((e) => [e.getAttribute('data-test').slice('releases-kind-'.length), Number(e.getAttribute('data-count'))])),
    error: !!document.querySelector('[data-test=releases-error]'),
    wide: document.scrollingElement.scrollWidth - document.scrollingElement.clientWidth,
  }
})
const until = (p, fn, arg) => p.waitForFunction(fn, { timeout: 15000 }, arg).then(() => true, () => false)
const shopShown = (p) => until(p, () => [...document.querySelectorAll('[data-test=releases-commit-subject]')].some((e) => e.textContent.includes('shop change')))
const settle = (p) => p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))))
const kindPill = (k) => `[data-test=releases-kind-${k}]`

async function run(p, base, tag) {
  const page = base + '/reporting/releases'
  await goto(p, page)
  let v = await view(p)
  ok(`P1 ${tag}: the drop box shows the default project, the URL stays clean`, v.select === 'spool' && v.project === null && v.repo === null, [v.select, v.project, v.repo])
  ok(`P1 ${tag}: a one-repo project shows no repo pills or repo names`, v.repoPills.length === 0 && v.rowRepos.length === 0, v.repoPills)

  await p.select('[data-test=releases-project]', SHOP)
  const shown = await shopShown(p)
  await until(p, () => document.querySelectorAll('[data-test^=releases-repo-]').length === 2)
  await settle(p)
  v = await view(p)
  ok(`P2 ${tag}: the pick goes into the URL and reads its commits`, shown && v.project === SHOP && v.subjects.every((s) => s.includes('shop change')), [v.project, v.subjects.slice(0, 2)])
  ok(`P2 ${tag}: two repo pills with counts`, v.repoPills.length === 2 && v.repoPills.every(([, n]) => n > 0), v.repoPills)
  ok(`P2 ${tag}: rows name their repo`, v.rowRepos.join() === 'web-shop-api,web-shop-wui', v.rowRepos)
  ok(`P2 ${tag}: the Unreleased card counts commits no tag carries`, Number(v.unreleased) > 0, v.unreleased)
  ok(`P2 ${tag}: no sideways scroll`, v.wide <= 0, v.wide)

  await goto(p, p.url())
  v = await view(p)
  ok(`P3 ${tag}: reload keeps the pick`, v.select === SHOP && v.project === SHOP && v.repoPills.length === 2, [v.select, v.project])

  await p.click('[data-test=releases-repo-web-shop-wui]')
  const one = await until(p, () => {
    const r = [...document.querySelectorAll('[data-test=releases-commit-repo]')].map((e) => e.textContent.trim())
    return r.length > 0 && r.every((x) => x === 'web-shop-wui')
  })
  v = await view(p)
  ok(`P4 ${tag}: a repo pill filters to that repo, in the URL`, one && v.repo === SHOP_WUI && v.project === SHOP, [v.repo, v.rowRepos])

  await p.goBack()
  const back1 = await until(p, () => !new URLSearchParams(location.search).get('repo') && document.querySelectorAll('[data-test=releases-commit-repo]').length > 0
    && new Set([...document.querySelectorAll('[data-test=releases-commit-repo]')].map((e) => e.textContent.trim())).size === 2)
  v = await view(p)
  ok(`P5 ${tag}: Back undoes the repo pick`, back1 && v.project === SHOP && v.repo === null, [v.project, v.repo, v.rowRepos])
  await p.goBack()
  const back2 = await until(p, () => !location.search.includes('project') && document.querySelector('[data-test=releases-project]')?.value === 'spool'
    && ![...document.querySelectorAll('[data-test=releases-commit-subject]')].some((e) => e.textContent.includes('shop change')))
  v = await view(p)
  ok(`P5 ${tag}: Back again undoes the project pick`, back2 && v.select === 'spool' && v.project === null, [v.select, v.project])

  for (const [qs, want] of [['?project=gone', { project: null, select: 'spool' }], [`?project=${SHOP}&repo=csitea/csi-spl`, { project: SHOP, select: SHOP }]]) {
    await goto(p, page + qs)
    const fell = await until(p, (w) => (new URLSearchParams(location.search).get('project') || null) === w.project && !new URLSearchParams(location.search).get('repo'), want)
    await settle(p)
    v = await view(p)
    ok(`P6 ${tag}: a stale ${qs} falls back with no error`, fell && v.select === want.select && !v.error && v.subjects.length > 0, [v.project, v.repo, v.select, v.error])
  }

  await cloudAfterSwitch(p, page, tag)
}

/* P7: the row's red control: the cloud's counts after a switch with a kind picked */
async function cloudAfterSwitch(p, page, tag) {
  await goto(p, page)
  await until(p, (s) => document.querySelector(s)?.getAttribute('data-count') > 0, kindPill('fix'))
  await p.click(kindPill('fix'))
  await until(p, (s) => document.querySelector(s)?.getAttribute('aria-pressed') === 'true', kindPill('fix'))
  await settle(p)
  const before = (await view(p)).kinds
  await p.select('[data-test=releases-project]', SHOP)
  await shopShown(p)
  await settle(p)
  const picked = (await view(p)).kinds
  await p.click(kindPill('fix'))
  await until(p, (s) => document.querySelector(s)?.getAttribute('aria-pressed') === 'false', kindPill('fix'))
  await settle(p)
  const fresh = (await view(p)).kinds
  ok(`P7 ${tag}: the two projects' label counts differ`, JSON.stringify(before) !== JSON.stringify(fresh), { before, fresh })
  ok(`P7 ${tag}: after a switch with a kind picked the cloud shows the new project's counts`, JSON.stringify(picked) === JSON.stringify(fresh), { picked, fresh })
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const size of SIZES) {
    const { ctx, p } = await open(browser, server.base, size)
    await run(p, server.base, `${size.width}px`)
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
console.log(`\nreleases-project-picker: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length || !results.length ? 1 : 0))
