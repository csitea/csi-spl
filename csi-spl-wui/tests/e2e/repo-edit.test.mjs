// spec 075 repo-edit T11: an editable repo doc (tree.json's editable flag)
// shows Edit; the editor is a lazy chunk; Save sends If-Match and the first
// save shows the author notice of §4.2 with the identity git will publish;
// Cancel there saves nothing; "I understand, save" consents and saves, and
// the doc shows the new text. A planted secret is refused with its line. A
// denied doc (the help pages) shows no Edit, nor does a member without
// docs.write. Desktop light + dark. The mock tenant answers as the hub
// (src/utils/docs-mock.mjs).
//
// Control: before T11 there is no [data-test=repo-edit-open]; every edit
// check fails.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e repo-edit
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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `repo-edit-${name}.png`) })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DOC = 'csi-spl-doc/doc/md/csi-spl.feature.md'
const DENIED = 'csi-spl-doc/doc/help/how-to-post.md'

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const setMe = (p, me) => p.evaluate((me) => {
  const access = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('access')
  if (!access) return false
  access.me = me
  return true
}, me)
const has = (p, sel) => p.$(sel).then(Boolean)
const waitFor = (p, sel, timeout = 10000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
/** the repo doc at `path` is shown, rendered, with no editor open (its preview is an md-block too) */
const docShown = (p, path) => p.waitForFunction((want) => {
  const c = document.querySelector('[data-test=docs-content]')
  return Boolean(c && c.getAttribute('data-page') === want && document.querySelector('[data-test=docs][data-state=ready]') &&
    !c.querySelector('[data-test=repo-edit]') && c.querySelector('[data-testid=md-block][data-rendered=true]'))
}, { timeout: 15000 }, path).then(() => true, () => false)
const h1 = (p) => p.$eval('[data-test=docs-content]', (el) => el.querySelector('h1')?.textContent?.trim() || '').catch(() => '')
const typeSource = (p, text) => p.$eval('[data-test=repo-edit-source]', (el, text) => {
  el.value = text
  el.dispatchEvent(new Event('input', { bubbles: true }))
}, text)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/docs/' + DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok(`${theme}: the repo doc opens`, await docShown(p, DOC) && (await h1(p)) === 'Spool feature')
    ok(`${theme}: an editable doc shows Edit`, await waitFor(p, '[data-test=repo-edit-open]'))
    await shot(p, `${theme}-view`)

    await p.click('[data-test=repo-edit-open]')
    ok(`${theme}: Edit opens the editor (lazy chunk)`, await waitFor(p, '[data-test=repo-edit-source]'))
    ok(`${theme}: the textarea holds the markdown source`, /^# Spool feature/.test(await p.$eval('[data-test=repo-edit-source]', (e) => e.value).catch(() => '')))

    /* the first save: the author notice, Cancel saves nothing */
    await typeSource(p, `# Spool feature ${theme}\n\nEdited **here**.\n`)
    await p.click('[data-test=repo-edit-save]')
    ok(`${theme}: the first save shows the author notice`, await waitFor(p, '[data-test=repo-edit-notice]'))
    const body = await text(p, '[data-test=repo-edit-notice]')
    ok(`${theme}: it names the identity git will publish`, (await text(p, '[data-test=repo-edit-notice-identity]')) === 'FirstName LastName <member@example.com>', body)
    ok(`${theme}: it says the edit is public and cannot be removed`, body.includes('public GitHub repository') && body.includes('cannot be removed later'), body)
    ok(`${theme}: the title is the spec text`, await p.evaluate(() => [...document.querySelectorAll('[role=dialog] h2, [role=dialog] [id]')].some((e) => e.textContent.trim() === 'Your edit will be public, with your name and email')))
    ok(`${theme}: the buttons are Cancel and I understand, save`,
      (await text(p, '[data-test=repo-edit-notice-cancel]')) === 'Cancel' && (await text(p, '[data-test=repo-edit-notice-confirm]')) === 'I understand, save')
    await shot(p, `${theme}-notice`)
    await p.click('[data-test=repo-edit-notice-cancel]')
    await sleep(300)
    ok(`${theme}: CONTROL Cancel closes the notice and keeps the editor`, !(await has(p, '[data-test=repo-edit-notice]')) && await has(p, '[data-test=repo-edit-source]'))

    /* consent: saved */
    await p.click('[data-test=repo-edit-save]')
    await waitFor(p, '[data-test=repo-edit-notice-confirm]')
    await p.click('[data-test=repo-edit-notice-confirm]')
    ok(`${theme}: consent saves and leaves the editor`, await docShown(p, DOC) && !(await has(p, '[data-test=repo-edit-source]')))
    ok(`${theme}: the doc shows the new text`, (await h1(p)) === `Spool feature ${theme}`, await h1(p))
    ok(`${theme}: it says the push follows`, await waitFor(p, '[data-test=repo-edit-saved]', 3000))
    await shot(p, `${theme}-saved`)

    /* a refused save says why and keeps the draft */
    await p.click('[data-test=repo-edit-open]')
    await waitFor(p, '[data-test=repo-edit-source]')
    ok(`${theme}: the editor reopens on the saved text`, (await p.$eval('[data-test=repo-edit-source]', (e) => e.value)).startsWith(`# Spool feature ${theme}`))
    await typeSource(p, '# x\n\nMOCK-SECRET\n')
    await p.click('[data-test=repo-edit-save]')
    ok(`${theme}: a planted secret is refused with its line`, await waitFor(p, '[data-test=repo-edit-error]', 5000) && (await text(p, '[data-test=repo-edit-error]')).includes('Line 3'), await text(p, '[data-test=repo-edit-error]'))
    ok(`${theme}: CONTROL a refused save shows no notice and keeps the draft`, !(await has(p, '[data-test=repo-edit-notice]')) && (await p.$eval('[data-test=repo-edit-source]', (e) => e.value)).includes('MOCK-SECRET'))
    await p.click('[data-test=repo-edit-cancel]')
    ok(`${theme}: Cancel leaves the editor with the saved text`, await docShown(p, DOC) && (await h1(p)) === `Spool feature ${theme}`)

    /* the second save: consent is once per identity */
    await p.click('[data-test=repo-edit-open]')
    await waitFor(p, '[data-test=repo-edit-source]')
    await typeSource(p, `# Again ${theme}\n`)
    await p.click('[data-test=repo-edit-save]')
    ok(`${theme}: once consented, a save asks no more`, await docShown(p, DOC) && (await h1(p)) === `Again ${theme}` && !(await has(p, '[data-test=repo-edit-notice]')))

    /* a denied doc; a reader without docs.write */
    await go(p, '/docs/' + DENIED)
    ok(`${theme}: setup - the help doc opens`, await docShown(p, DENIED) && (await h1(p)) === 'How to Post')
    await sleep(300)
    ok(`${theme}: a denied doc shows no Edit`, !(await has(p, '[data-test=repo-edit-open]')))
    await go(p, '/docs/' + DOC)
    ok(`${theme}: CONTROL the editable doc shows Edit again`, await docShown(p, DOC) && await waitFor(p, '[data-test=repo-edit-open]', 5000))
    await setMe(p, { humanId: 'HUM-2', role: 'regular_user', tenantOwner: false, permissions: ['topics.read'], channelOrder: null })
    await sleep(200)
    ok(`${theme}: a member without docs.write sees no Edit`, !(await has(p, '[data-test=repo-edit-open]')))
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `repo-edit: ${failed} FAILED` : `repo-edit: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
