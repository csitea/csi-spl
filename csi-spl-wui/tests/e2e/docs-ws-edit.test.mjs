// spec 075 T010 (owner, prd t1 9f0d751c: "simple editing functionality"
// first): the Docs explorer gets a Workspace docs section ABOVE the repo
// tree (t1 199cafc7: under it the owner could not find it), New doc is a
// labelled button in the first screen, and a workspace doc at /docs/ws/<path> opens, edits in a plain
// markdown textarea with a live preview, saves (last write wins), cancels,
// is created with New doc and deleted after a confirm. Edit and New doc are
// hidden from a reader who cannot write (a member without docs.write, a
// guest); the repo docs stay read-only. Desktop light + dark, and a phone.
// The mock tenant serves an in-memory bucket (src/utils/ws-docs-mock.mjs).
//
// Control: before T010 there is no [data-test=ws-docs]; every check fails.
//
// Run:
//   pnpm run test:e2e docs-ws-edit
//   BASE_URL=<generated bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e docs-ws-edit
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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `docs-ws-${name}.png`) })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const WELCOME = 'welcome.md'
const DEPLOY = 'runbooks/deploy.md'

/* in-app navigation keeps the page (and the mock bucket) alive */
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const setMe = (p, me) => p.evaluate((me) => {
  const access = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')
  if (!access) return false
  access.me = me
  return true
}, me)
const has = (p, sel) => p.$(sel).then(Boolean)
const shown = (p, sel) => p.$eval(sel, (el) => {
  const r = el.getBoundingClientRect()
  return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'
}).catch(() => false)
const wsDoc = (p, path, mode = 'view') => p.waitForFunction((want, mode) => {
  const c = document.querySelector('[data-test=docs-content]')
  const d = document.querySelector('[data-test=ws-doc]')
  if (!c || !d || c.getAttribute('data-page') !== 'ws/' + want || d.getAttribute('data-mode') !== mode) return false
  return mode === 'edit' || Boolean(d.querySelector('[data-testid=md-block][data-rendered=true]'))
}, { timeout: 15000 }, path, mode).then(() => true, () => false)
const h1 = (p, sel = '[data-test=ws-doc]') => p.$eval(sel, (el) => el.querySelector('h1')?.textContent?.trim() || '').catch(() => '')
/** The New doc button's label and box, null when it is not rendered. */
const newDocButton = (p) => p.$eval('[data-test=ws-docs-new]', (e) => {
  const r = e.getBoundingClientRect()
  return { text: e.textContent.trim(), bottom: Math.round(r.bottom), right: Math.round(r.right), h: Math.round(r.height) }
}).catch(() => null)
const wsFiles = (p) => p.$$eval('[data-test=ws-docs-file]', (els) => els.map((e) => e.getAttribute('data-path')))
/* v-model listens for input: set the value as typing would */
const typeSource = (p, text) => p.$eval('[data-test=ws-doc-source]', (el, text) => {
  el.value = text
  el.dispatchEvent(new Event('input', { bubbles: true }))
}, text)
const previewH1 = (p, want) => p.waitForFunction((want) => {
  const h = document.querySelector('[data-test=ws-doc-preview] h1')
  return h && h.textContent.trim() === want
}, { timeout: 5000 }, want).then(() => true, () => false)
const openDir = async (p, path) => {
  if (await has(p, `[data-test=ws-docs-file][data-path^="${path}/"]`)) return true
  const d = await p.$(`[data-test=ws-docs-dir][data-path="${path}"]`)
  if (d) await d.click()
  return Boolean(d)
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const section = await p.waitForSelector('[data-test=ws-docs][data-state=ready]', { timeout: 15000 }).catch(() => null)
    ok(`${theme}: the explorer has a Workspace docs section`, Boolean(section))
    ok(`${theme}: it sits above the repo tree, in the left pane`, await p.$eval('[data-test=docs-tree]', (t) => {
      const ws = t.querySelector('[data-test=ws-docs]')
      const repo = t.querySelector('[data-test=docs-dir], [data-test=docs-file]')
      return Boolean(ws && repo && (ws.compareDocumentPosition(repo) & Node.DOCUMENT_POSITION_FOLLOWING))
    }).catch(() => false))
    const nb = await newDocButton(p)
    ok(`${theme}: New doc is a labelled button in the first screen`, Boolean(nb && nb.text === 'New doc' && nb.bottom <= 900), nb)
    ok(`${theme}: it lists the workspace's docs`, (await wsFiles(p)).includes(WELCOME), await wsFiles(p))
    ok(`${theme}: CONTROL a repo doc offers no Edit`, !(await has(p, '[data-test=ws-doc-edit]')))

    /* open */
    await p.waitForSelector(`[data-test=ws-docs-file][data-path="${WELCOME}"]`, { visible: true, timeout: 10000 })
    await p.click(`[data-test=ws-docs-file][data-path="${WELCOME}"]`)
    ok(`${theme}: a click opens it at /docs/ws/<path>`, await wsDoc(p, WELCOME) && new URL(p.url()).pathname === '/docs/ws/' + WELCOME, p.url())
    ok(`${theme}: it renders as markdown`, (await h1(p)) === 'Welcome')
    ok(`${theme}: the open doc is marked in the tree`, await p.$eval(`[data-test=ws-docs-file][data-path="${WELCOME}"]`, (e) => e.getAttribute('aria-current')) === 'page')
    await shot(p, `desktop-${theme}-view`)

    /* edit + live preview + cancel */
    ok(`${theme}: a writer sees Edit`, await shown(p, '[data-test=ws-doc-edit]'))
    await p.click('[data-test=ws-doc-edit]')
    ok(`${theme}: Edit opens the editor`, await wsDoc(p, WELCOME, 'edit'))
    ok(`${theme}: the textarea holds the markdown source`, /^# Welcome/.test(await p.$eval('[data-test=ws-doc-source]', (e) => e.value)))
    ok(`${theme}: the preview renders it`, await previewH1(p, 'Welcome'))
    const panes = await p.evaluate(() => {
      const a = document.querySelector('[data-test=ws-doc-source]').getBoundingClientRect()
      const b = document.querySelector('[data-test=ws-doc-preview]').getBoundingClientRect()
      return { srcRight: Math.round(a.right), prevLeft: Math.round(b.left), dy: Math.round(Math.abs(a.top - b.top)) }
    })
    ok(`${theme}: source and preview sit side by side`, panes.srcRight <= panes.prevLeft && panes.dy < 40, panes)
    await typeSource(p, '# Welcome draft\n\nnot kept')
    ok(`${theme}: the preview follows the typing`, await previewH1(p, 'Welcome draft'))
    await shot(p, `desktop-${theme}-edit`)
    await p.click('[data-test=ws-doc-cancel]')
    ok(`${theme}: Cancel leaves the editor`, await wsDoc(p, WELCOME))
    ok(`${theme}: CONTROL Cancel keeps the saved text`, (await h1(p)) === 'Welcome')

    /* save, read back */
    await p.click('[data-test=ws-doc-edit]')
    await wsDoc(p, WELCOME, 'edit')
    await typeSource(p, `# Welcome ${theme}\n\nSaved **here**.\n`)
    await p.click('[data-test=ws-doc-save]')
    ok(`${theme}: Save shows the new text`, await wsDoc(p, WELCOME) && (await h1(p)) === `Welcome ${theme}`)
    ok(`${theme}: the saved markdown renders (bold)`, await p.$eval('[data-test=ws-doc]', (el) => el.querySelector('strong')?.textContent === 'here'))
    await openDir(p, 'runbooks')
    await p.click(`[data-test=ws-docs-file][data-path="${DEPLOY}"]`)
    ok(`${theme}: another doc opens`, await wsDoc(p, DEPLOY) && (await h1(p)) === 'Deploy')
    await go(p, '/docs/ws/' + WELCOME)
    ok(`${theme}: reopened, the doc reads back as saved`, await wsDoc(p, WELCOME) && (await h1(p)) === `Welcome ${theme}`)

    /* new doc */
    await p.click('[data-test=ws-docs-new]')
    await p.waitForSelector('[data-test=ws-docs-new-path]', { visible: true, timeout: 5000 })
    await p.type('[data-test=ws-docs-new-path]', '../bad')
    await p.click('[data-test=ws-docs-new-create]')
    ok(`${theme}: CONTROL a path the hub would refuse is refused`, await has(p, '[data-test=ws-docs-new-bad]'))
    await p.$eval('[data-test=ws-docs-new-path]', (e) => { e.value = '' })
    await p.type('[data-test=ws-docs-new-path]', 'notes/today')
    await p.click('[data-test=ws-docs-new-create]')
    ok(`${theme}: New doc opens the editor on <path>.md`, await wsDoc(p, 'notes/today.md', 'edit') && new URL(p.url()).pathname === '/docs/ws/notes/today.md', p.url())
    ok(`${theme}: a new doc starts with a heading`, (await p.$eval('[data-test=ws-doc-source]', (e) => e.value)).startsWith('# today'))
    await typeSource(p, '# Today\n\nA new page.\n')
    await p.click('[data-test=ws-doc-save]')
    ok(`${theme}: the first Save creates it`, await wsDoc(p, 'notes/today.md') && (await h1(p)) === 'Today')
    await sleep(300)
    await openDir(p, 'notes')
    ok(`${theme}: it appears in the tree`, (await wsFiles(p)).includes('notes/today.md'), await wsFiles(p))

    /* delete */
    await p.click('[data-test=ws-doc-delete]')
    await p.waitForSelector('[data-testid=ws-doc-delete-confirm-confirm]', { visible: true, timeout: 5000 })
    ok(`${theme}: Delete asks first, naming the doc`, (await p.$eval('[data-testid=ws-doc-delete-confirm-body]', (e) => e.textContent)).includes('notes/today.md'))
    await p.click('[data-testid=ws-doc-delete-confirm-confirm]')
    await p.waitForFunction(() => location.pathname === '/docs', { timeout: 8000 }).catch(() => {})
    await sleep(300)
    ok(`${theme}: confirmed, it is gone from the tree`, new URL(p.url()).pathname === '/docs' && !(await wsFiles(p)).includes('notes/today.md'), await wsFiles(p))

    /* non-writers */
    await go(p, '/docs/ws/' + WELCOME)
    await wsDoc(p, WELCOME)
    ok(`${theme}: setup - a member with docs.write sees Edit and New doc`,
      await setMe(p, { humanId: 'HUM-1', role: 'developer', tenantOwner: false, permissions: ['topics.read', 'docs.write'], channelOrder: null }) &&
      await sleep(200).then(() => shown(p, '[data-test=ws-doc-edit]')) && await shown(p, '[data-test=ws-docs-new]'))
    await setMe(p, { humanId: 'HUM-2', role: 'regular_user', tenantOwner: false, permissions: ['topics.read'], channelOrder: null })
    await sleep(200)
    ok(`${theme}: a member without docs.write sees no Edit, no Delete, no New doc`,
      !(await has(p, '[data-test=ws-doc-edit]')) && !(await has(p, '[data-test=ws-doc-delete]')) && !(await has(p, '[data-test=ws-docs-new]')))
    ok(`${theme}: and still reads the doc`, (await h1(p)) === `Welcome ${theme}`)
    await setMe(p, { humanId: null, role: null, tenantOwner: false, permissions: null, channelOrder: null })
    await sleep(200)
    ok(`${theme}: a guest sees no Edit`, !(await has(p, '[data-test=ws-doc-edit]')) && !(await has(p, '[data-test=ws-docs-new]')))
    await go(p, '/docs/ws/' + DEPLOY + '?edit=1')
    await sleep(500)
    ok(`${theme}: CONTROL ?edit=1 does not open the editor for a guest`, !(await has(p, '[data-test=ws-doc-editor]')))
    ok(`${theme}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    await p.close()
  }

  console.log('-- 390x740 phone')
  for (const theme of ['light', 'dark']) {
    const m = await browser.newPage()
    await m.setViewport({ width: 390, height: 740, isMobile: true, hasTouch: true })
    await m.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await m.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await m.goto(server.base + '/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok(`phone ${theme}: the folded-open tree shows Workspace docs`, Boolean(await m.waitForSelector('[data-test=ws-docs][data-state=ready]', { visible: true, timeout: 15000 }).catch(() => null)))
    const mb = await newDocButton(m)
    ok(`phone ${theme}: New doc is labelled, in the first screen, a 44 px target`, Boolean(mb && mb.text === 'New doc' && mb.bottom <= 740 && mb.right <= 390 && mb.h >= 44), mb)
    const f = await m.$(`[data-test=ws-docs-file][data-path="${WELCOME}"]`)
    const fb = f ? await f.boundingBox() : null
    ok(`phone ${theme}: a workspace doc is a 44 px target`, Boolean(fb && fb.height >= 44), fb)
    if (f) await f.tap()
    ok(`phone ${theme}: it opens`, await wsDoc(m, WELCOME))
    await shot(m, `phone-${theme}-view`)
    const eb = await m.$('[data-test=ws-doc-edit]')
    const ebb = eb ? await eb.boundingBox() : null
    ok(`phone ${theme}: Edit is a 44 px target`, Boolean(ebb && ebb.height >= 44), ebb)
    if (eb) await eb.tap()
    ok(`phone ${theme}: the editor opens`, await wsDoc(m, WELCOME, 'edit'))
    await typeSource(m, '# Phone edit\n\nShort.')
    ok(`phone ${theme}: the preview follows`, await previewH1(m, 'Phone edit'))
    const stack = await m.evaluate(() => {
      const a = document.querySelector('[data-test=ws-doc-source]').getBoundingClientRect()
      const b = document.querySelector('[data-test=ws-doc-preview]').getBoundingClientRect()
      return { srcBottom: Math.round(a.bottom), prevTop: Math.round(b.top), w: Math.round(a.width) }
    })
    ok(`phone ${theme}: source and preview stack, full width`, stack.prevTop >= stack.srcBottom && stack.w > 300, stack)
    ok(`phone ${theme}: no sideways scroll`, await m.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
    await shot(m, `phone-${theme}-edit`)
    await m.tap('[data-test=ws-doc-save]')
    ok(`phone ${theme}: Save works`, await wsDoc(m, WELCOME) && (await h1(m)) === 'Phone edit')

    // Verify omnibox visibility on phone during edit mode
    const omniboxVisible = async (p) => {
      return p.evaluate(() => {
        const omnibox = document.querySelector('[data-test=top-bar-omnibox]');
        if (!omnibox) return false;
        const style = window.getComputedStyle(omnibox);
        return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
      });
    };

    // Control: omnibox visible when NOT editing
    let visible = await omniboxVisible(m);
    ok(`phone ${theme}: omnibox visible when NOT editing`, visible);

    // Focus the title (edit mode)
    await m.tap('[data-test=ws-doc-doctitle]');
    await sleep(500); // Wait for focus to settle
    visible = await omniboxVisible(m);
    ok(`phone ${theme}: omnibox hidden when editing`, !visible);

    // Blur (exit edit mode)
    await m.tap('[data-test=ws-doc-search]');
    await sleep(500);
    visible = await omniboxVisible(m);
    ok(`phone ${theme}: omnibox visible after editing`, visible);
    await m.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `docs-ws-edit: ${failed} FAILED` : `docs-ws-edit: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
