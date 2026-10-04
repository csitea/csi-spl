// The Docs section (owner, prd t1 9f0d751c): the rail's book opens /docs,
// an explorer tree of the repo's folders on the left (doc/md, doc/help,
// specs), the doc rendered on the right in the current theme; a relative
// .md link opens the target doc at its stable /docs/<repo path>; an unknown
// doc says so; on a phone the tree folds behind its Folders button.
// The mock tenant serves a small repo-shaped tree (src/utils/docs-mock.mjs).
//
// t1 c13e8023 (owner): on a desktop Docs is two panes, the explorer in the
// left-most pane and the document in the second, and a topic panel open
// beside the channel the reader came from closes. The sidebar keeps its
// icon rail only. Each pane scrolls on its own. A phone stays one pane.
//
// Control: before the section there is no [data-testid=docs-open].
// Before the two-pane change the channel list and the topic panel both
// stay beside Docs, so the 1440 px pane checks FAIL.
//
// Run:
//   pnpm run test:e2e docs
//   BASE_URL=<generated bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e docs
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `docs-${name}.png`) })
}

const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SPEC = 'csi-spl-doc/specs/072-rapid-deployability/spec.md'
const FEATURE = 'csi-spl-doc/doc/md/csi-spl.feature.md'
const POST = 'csi-spl-doc/doc/help/how-to-post.md'
const page = (p, path) => p.waitForFunction((want) => {
  const c = document.querySelector('[data-test=docs-content]')
  return c && c.getAttribute('data-page') === want && c.querySelector('[data-testid=md-block][data-rendered=true]')
}, { timeout: 15000 }, path).then(() => true, () => false)
const h1 = (p) => p.$eval('[data-test=docs-content]', (el) => el.querySelector('h1')?.textContent || '')
const dirs = (p) => p.$$eval('[data-test=docs-tree] [data-test=docs-dir]', (els) => els.map((e) => e.getAttribute('data-path')))
const clickDir = async (p, path) => {
  const d = await p.$(`[data-test=docs-dir][data-path="${path}"]`)
  if (d) await d.click()
  return Boolean(d)
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* every visible column of the shell, left to right, wider than the icon rail */
const panes = (pg) => pg.evaluate(() => {
  const shown = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    const st = getComputedStyle(el)
    return r.width > 40 && r.height > 40 && st.display !== 'none' && st.visibility !== 'hidden' ? r : null
  }
  const cols = []
  const add = (name, el) => { const r = shown(el); if (r) cols.push({ name, left: Math.round(r.left), right: Math.round(r.right) }) }
  add('sidebar-list', document.querySelector('.sidebar-body'))
  add('docs-tree', document.querySelector('[data-test=docs-tree]'))
  add('docs-content', document.querySelector('[data-test=docs-content]'))
  add('topic', document.querySelector('[data-test=topic-section]'))
  return cols.sort((a, b) => a.left - b.left)
})
/* one phone pane: the tree is hidden, or it stacks above the doc */
const phoneStack = (pg) => pg.evaluate(() => {
  const tree = document.querySelector('[data-test=docs-tree]')
  const doc = document.querySelector('[data-test=docs-content]')
  if (!tree || !doc) return { ok: false }
  if (getComputedStyle(tree).display === 'none') return { ok: true, mode: 'doc-only' }
  const tr = tree.getBoundingClientRect()
  const dr = doc.getBoundingClientRect()
  const sideBySide = tr.width > 80 && dr.width > 80 && tr.right <= dr.left + 4 && Math.abs(tr.top - dr.top) < 40
  return { ok: !sideBySide, mode: sideBySide ? 'side-by-side' : 'stacked', treeTop: Math.round(tr.top), docTop: Math.round(dr.top) }
})
const scrollBox = (pg) => pg.evaluate(() => {
  const box = (sel) => {
    const el = document.querySelector(sel)
    if (!el) return null
    const st = getComputedStyle(el)
    return { overflowY: st.overflowY, scrollTop: Math.round(el.scrollTop) }
  }
  return {
    tree: box('[data-test=docs-tree]'),
    doc: box('[data-test=docs-content]'),
    body: box('[data-test=docs]'),
    page: Math.round(document.scrollingElement ? document.scrollingElement.scrollTop : 0),
  }
})

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1280x800')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const open = await p.waitForSelector('[data-testid=docs-open]', { visible: true, timeout: 15000 }).catch(() => null)
  ok('the left rail carries a Docs entry', Boolean(open))
  if (open) {
    ok('it is named for assistive tech', (await open.evaluate((el) => el.getAttribute('aria-label'))) === 'Docs')
    await open.click()
    await p.waitForFunction(() => location.pathname === '/docs', { timeout: 10000 }).catch(() => {})
    ok('one click lands on /docs', new URL(p.url()).pathname === '/docs', p.url())
    ok('/docs renders the repo README', await page(p, 'README.md'))
    ok('the doc path is shown', (await p.$eval('[data-test=docs-path]', (e) => e.textContent.trim())) === 'README.md')
    await p.waitForSelector('[data-test=docs-tree] [data-test=docs-dir]', { timeout: 10000 }).catch(() => null)
    ok('the tree opens on csi-spl-doc', (await dirs(p)).includes('csi-spl-doc/doc'))
    ok('a folder expands on click', await clickDir(p, 'csi-spl-doc/doc') && (await dirs(p)).includes('csi-spl-doc/doc/md'))
    const shown = await dirs(p)
    ok('the tree lists doc/md, doc/help and specs',
      ['csi-spl-doc/doc/md', 'csi-spl-doc/doc/help', 'csi-spl-doc/specs'].every((d) => shown.includes(d)), shown)
    await clickDir(p, 'csi-spl-doc/doc')
    ok('CONTROL it folds again on a second click', !(await dirs(p)).includes('csi-spl-doc/doc/md'))
    await clickDir(p, 'csi-spl-doc/specs')
    await clickDir(p, 'csi-spl-doc/specs/072-rapid-deployability')
    const file = await p.$(`[data-test=docs-file][data-path="${SPEC}"]`)
    ok('a spec is a file in the tree', Boolean(file))
    if (file) {
      await file.click()
      ok('a click opens it at its stable /docs/<repo path>', await page(p, SPEC) && new URL(p.url()).pathname === '/docs/' + SPEC, p.url())
      ok('it renders as markdown', /Spec 072/.test(await h1(p)))
      ok('the open doc is marked in the tree', await p.$eval(`[data-test=docs-file][data-path="${SPEC}"]`, (e) => e.getAttribute('aria-current')) === 'page')
    }
    await p.goto(server.base + '/docs/' + FEATURE, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok('a deep link opens the doc', await page(p, FEATURE))
    ok('a table renders', Boolean(await p.$('[data-test=docs-content] table')))
    const link = await p.$(`[data-test=docs-content] a[href="/docs/${POST}"]`)
    ok('a relative ../help/x.md link became the target doc\'s /docs route', Boolean(link))
    if (link) {
      await link.click()
      ok('it opens the target doc in the app', await page(p, POST) && new URL(p.url()).pathname === '/docs/' + POST, p.url())
      ok('it is How to Post', /How to Post/.test(await h1(p)))
      ok('the tree opened the folders the doc sits in', await p.$(`[data-test=docs-file][data-path="${POST}"]`).then(Boolean))
    }
    const paint = async (theme) => {
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await new Promise((r) => setTimeout(r, 150))
      return p.$eval('[data-test=docs-content]', (el) => {
        const c = getComputedStyle(el.querySelector('h1') || el).color
        const bg = getComputedStyle(document.body).backgroundColor
        return { c, bg }
      })
    }
    const light = await paint('light')
    await shot(p, 'desktop-light')
    const dark = await paint('dark')
    await shot(p, 'desktop-dark')
    const lum = (rgb) => { const [r, g, b] = rgb.match(/\d+/g).map(Number); return (r + g + b) / 3 }
    ok('dark theme: the doc follows the theme (light text on a dark page)', lum(dark.c) > lum(dark.bg) && lum(light.c) < lum(light.bg), { light, dark })
    await paint('light')
  }
  await p.goto(server.base + '/docs/csi-spl-doc/no-such.md', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('an unknown doc says so', Boolean(await p.waitForSelector('[data-test=docs-missing]', { timeout: 10000 }).catch(() => null)))
  ok('CONTROL the toggle is hidden on a desktop', await p.$eval('[data-test=docs-tree-toggle]', (e) => getComputedStyle(e).display === 'none'))
  await p.close()

  /* t1 c13e8023: desktop, light and dark. From the channel view with its
     topic panel open, Docs is the explorer then the document, and the
     topic panel is gone. */
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const d = await browser.newPage()
    await d.setViewport({ width: 1440, height: 900 })
    await d.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await d.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await d.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await d.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await sleep(600)
    const armed = await d.evaluate((id) => {
      const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
      if (!topic) return 'no-store'
      topic.openTopic(id)
      return 'ok'
    }, TASK)
    const third = await d.waitForSelector('[data-test=topic-section]', { visible: true, timeout: 8000 }).catch(() => null)
    ok(`${theme}: setup - a right pane is open on the channel view`, armed === 'ok' && Boolean(third), armed)

    await d.click('[data-testid=docs-open]')
    await d.waitForFunction(() => location.pathname === '/docs', { timeout: 10000 }).catch(() => {})
    await d.waitForSelector('[data-test=docs-content] [data-testid=md-block][data-rendered=true]', { timeout: 15000 }).catch(() => null)
    await d.waitForSelector('[data-test=docs-tree] [data-test=docs-file]', { timeout: 10000 }).catch(() => null)
    await sleep(500)
    ok(`${theme}: Docs opens /docs`, new URL(d.url()).pathname === '/docs', d.url())
    const cols = await panes(d)
    const names = cols.map((c) => c.name)
    const tree = cols.find((c) => c.name === 'docs-tree')
    const content = cols.find((c) => c.name === 'docs-content')
    ok(`${theme}: the tree is the left pane and the document is the second`, names.join(',') === 'docs-tree,docs-content' && tree.right <= content.left, cols)
    ok(`${theme}: opening Docs leaves no right pane`, !(await d.$('[data-test=topic-section]')))
    ok(`${theme}: the sidebar keeps its icon rail`, Boolean(await d.$('[data-testid=sidebar-rail]')) && (await d.$eval('nav.sidebar', (el) => el.getAttribute('data-docs-rail'))) === '1')
    const scrolls = await scrollBox(d)
    const own = (m) => Boolean(m) && (m.overflowY === 'auto' || m.overflowY === 'scroll')
    const fixed = (m) => Boolean(m) && (m.overflowY === 'hidden' || m.overflowY === 'clip') && m.scrollTop === 0
    ok(`${theme}: each pane scrolls on its own and the page body does not`, own(scrolls.tree) && own(scrolls.doc) && fixed(scrolls.body) && scrolls.page === 0, scrolls)

    ok(`${theme}: the tree can be expanded to a file`, await clickDir(d, 'csi-spl-doc/specs') && await clickDir(d, 'csi-spl-doc/specs/072-rapid-deployability'))
    const file = await d.$(`[data-test=docs-file][data-path="${SPEC}"]`)
    ok(`${theme}: a file is in the tree`, Boolean(file))
    if (file) {
      await file.click()
      ok(`${theme}: clicking a file loads it in pane 2`, await page(d, SPEC) && new URL(d.url()).pathname === '/docs/' + SPEC, d.url())
      const after = await panes(d)
      const an = after.map((c) => c.name)
      const at = after.find((c) => c.name === 'docs-tree')
      const ac = after.find((c) => c.name === 'docs-content')
      ok(`${theme}: the loaded doc stays in the second pane`, an.join(',') === 'docs-tree,docs-content' && at.right <= ac.left && (await d.$eval('[data-test=docs-content]', (el) => el.getAttribute('data-page'))) === SPEC, after)
      ok(`${theme}: the open file is highlighted`, await d.$eval(`[data-test=docs-file][data-path="${SPEC}"]`, (e) => e.getAttribute('aria-current')) === 'page')
    }
    const sw = await d.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok(`${theme}: no sideways scroll`, sw)
    await d.close()
  }

  console.log('-- 390x740 phone')
  const m = await browser.newPage()
  await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const mo = await m.waitForSelector('[data-testid=docs-open]', { timeout: 15000 }).catch(() => null)
  ok('the phone strip carries Docs', Boolean(mo))
  /* the phone strip rolls endlessly (CLE-77886): swipe until a Docs link is in view, tap it */
  const spot = async () => m.evaluate(() => {
    const rail = document.querySelector('[data-testid=sidebar-rail]')
    const rb = rail.getBoundingClientRect()
    for (const h of document.querySelectorAll('.sidebar-rail__docs')) {
      const r = h.getBoundingClientRect()
      if (r.width && r.left >= Math.max(rb.left, 0) && r.right <= Math.min(rb.right, window.innerWidth)) {
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
      }
    }
    return null
  })
  let at = await spot()
  for (let i = 0; !at && i < 60; i++) {
    await m.evaluate(() => { document.querySelector('[data-testid=sidebar-rail]').scrollLeft += 40 })
    await new Promise((r) => setTimeout(r, 50))
    at = await spot()
  }
  ok('a swipe brings Docs into view, a 44 px target', Boolean(at && at.w >= 44 && at.h >= 44), at)
  if (at) await m.touchscreen.tap(at.x, at.y)
  await m.waitForFunction(() => location.pathname === '/docs', { timeout: 10000 }).catch(() => {})
  ok('one tap lands on /docs', new URL(m.url()).pathname === '/docs', m.url())
  ok('the README renders on a phone', await page(m, 'README.md'))
  ok('phone: still one pane (the tree stacks, it is not a column beside the doc)', (await phoneStack(m)).ok, await phoneStack(m))
  ok('/docs on a phone shows the folders', await m.$eval('[data-test=docs-tree]', (e) => getComputedStyle(e).display !== 'none'))
  await m.goto(server.base + '/docs/' + SPEC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  ok('a doc renders on a phone', await page(m, SPEC))
  ok('the tree is folded under a doc', await m.$eval('[data-test=docs-tree]', (e) => getComputedStyle(e).display === 'none'))
  ok('phone: a doc is still one pane', (await phoneStack(m)).ok, await phoneStack(m))
  const tog = await m.$('[data-test=docs-tree-toggle]')
  const tb = tog ? await tog.boundingBox() : null
  ok('the Folders button is a 44 px target', Boolean(tb && tb.height >= 44), tb)
  if (tog) {
    await tog.tap()
    ok('a tap unfolds the tree', await m.waitForFunction(() => getComputedStyle(document.querySelector('[data-test=docs-tree]')).display !== 'none', { timeout: 5000 }).then(() => true, () => false))
    ok('it is marked expanded', (await tog.evaluate((e) => e.getAttribute('aria-expanded'))) === 'true')
    const f = await m.$(`[data-test=docs-file][data-path="${SPEC}"]`)
    ok('the open doc is in the unfolded tree', Boolean(f))
  }
  ok('no sideways scroll on a phone', await m.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  await shot(m, 'phone')
  await m.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `docs: ${failed} FAILED` : `docs: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
