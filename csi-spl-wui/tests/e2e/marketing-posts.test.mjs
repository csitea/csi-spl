// Spec 090 section 22 (SPL-5240): Workspace settings -> Posts, proved in a
// REAL browser against the mock bundle (tenant-settings-mock.mjs
// mockMarketingDrafts: the hub's rules, one draft by another admin seeded).
// At 1440 and at 390:
//   1. with marketing off the section says so in one line (the hub's 404);
//   2. marketing on: the other admin's draft is listed, marked, with no
//      Edit, Delete or Publish;
//   3. write a draft: Save adds it, marked Draft, the counter counts it;
//   4. Edit, change the text, Save changes: the row shows the new text;
//   5. publish on LinkedIn and Instagram: one line per account (published;
//      Instagram needs a JPEG), the draft is Published, lists where it went,
//      and offers no Edit or Delete;
//   6. RED CONTROL: a second draft is deleted after the confirm; a refused
//      confirm keeps it.
//
// Plant the defect and watch it go red:
//   PROVE_RED=confirm node tests/e2e/marketing-posts.test.mjs   (step 6: the confirm is accepted both times)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-posts
// SHOT_DIR=<dir> writes marketing-posts-<width>.png.
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const SHOT_DIR = process.env.SHOT_DIR || ''

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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const TOGGLE = '[data-test=tenant-marketing-toggle]'
const ROW = '[data-test=marketing-posts-row]'
const row = (id) => `${ROW}[data-draft="${id}"]`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function tap(p, sel) {
  await p.$eval(sel, (e) => e.scrollIntoView({ block: 'center' }))
  await p.click(sel)
}
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const rows = (p) => p.$$eval(ROW, (es) => es.map((e) => ({
  id: e.getAttribute('data-draft'),
  published: e.getAttribute('data-published') === '1',
  body: e.querySelector('.mpe-body')?.textContent.trim(),
  other: Boolean(e.querySelector('[data-test=marketing-posts-other]')),
  edit: Boolean(e.querySelector('[data-test=marketing-posts-edit]')),
  del: Boolean(e.querySelector('[data-test=marketing-posts-delete]')),
  publish: Boolean(e.querySelector('[data-test=marketing-posts-publish]')),
  sent: [...e.querySelectorAll('[data-test=marketing-posts-sent]')].map((x) => x.textContent.trim()),
})))

// open a Workspace settings section in the app (a client-side route
// change, as the nav link makes one): the mock keeps its state. The phone
// layout hides the nav while a section is open, so the router is used.
async function openSection(p, id) {
  await p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), '/tenant-settings/' + id)
  await sleep(800)
}

async function flipOn(p) {
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  if (!(await p.$eval(TOGGLE, (e) => e.checked).catch(() => true))) await tap(p, TOGGLE)
  await p.waitForFunction((s) => document.querySelector(s)?.checked === true, { timeout: 5000 }, TOGGLE).catch(() => null)
  await sleep(300)
}

async function writeSteps(p, w) {
  await p.waitForSelector('[data-test=marketing-posts-form]', { visible: true, timeout: 10000 }).catch(() => null)
  const first = await rows(p)
  ok(`2 ${w}px: the other admin's draft is listed, marked, with no Edit, Delete or Publish`, first.length === 1 &&
    first[0].other && !first[0].edit && !first[0].del && !first[0].publish, first)
  await p.type('[data-test=marketing-posts-body]', 'Workshop on Friday')
  const count = await text(p, '[data-test=marketing-posts-count]')
  await tap(p, '[data-test=marketing-posts-save]')
  await p.waitForFunction((s) => document.querySelectorAll(s).length === 2, { timeout: 5000 }, ROW).catch(() => null)
  const after = await rows(p)
  ok(`3 ${w}px: Save adds the draft, marked Draft; the counter counts it`, count === '18 / 3000 characters' && after.length === 2 &&
    after[0].body === 'Workshop on Friday' && !after[0].published && after[0].edit && after[0].publish &&
    (await text(p, '[data-test=marketing-posts-notice]')) === 'Draft saved.', { count, after })
  return after[0].id
}

async function editSteps(p, w, id) {
  await tap(p, `${row(id)} [data-test=marketing-posts-edit]`)
  // the form holds the draft before it is changed (a phone tap lands a frame later)
  await p.waitForFunction((s) => document.querySelector(s)?.value === 'Workshop on Friday', { timeout: 5000 }, '[data-test=marketing-posts-body]').catch(() => null)
  await p.$eval('[data-test=marketing-posts-body]', (e) => { e.value = ''; e.dispatchEvent(new Event('input')) })
  await p.type('[data-test=marketing-posts-body]', 'Workshop on Friday at 10')
  await tap(p, '[data-test=marketing-posts-save]')
  await p.waitForFunction((s) => document.querySelector(s)?.textContent.trim() === 'Workshop on Friday at 10', { timeout: 5000 }, `${row(id)} .mpe-body`).catch(() => null)
  ok(`4 ${w}px: Save changes shows the new text`, (await text(p, `${row(id)} .mpe-body`)) === 'Workshop on Friday at 10')
}

async function publishSteps(p, w, id) {
  for (const ch of ['mch-li-1', 'mch-ig-1']) await tap(p, `${row(id)} [data-test=marketing-posts-channel][data-channel="${ch}"]`)
  await tap(p, `${row(id)} [data-test=marketing-posts-publish-button]`)
  await p.waitForFunction((s) => document.querySelector(s)?.getAttribute('data-published') === '1', { timeout: 5000 }, row(id)).catch(() => null)
  await sleep(200)
  const notice = await text(p, '[data-test=marketing-posts-notice]')
  const r = (await rows(p)).find((x) => x.id === id)
  ok(`5 ${w}px: one line per account: LinkedIn published, Instagram needs a JPEG`,
    notice === 'LinkedIn · FirstName LastName: published · Instagram · mock.studio: Instagram needs a JPEG picture', notice)
  ok(`5b ${w}px: the draft is Published, lists where it went, and offers no Edit or Delete`, r?.published && !r.edit && !r.del &&
    r.sent.join() === 'LinkedIn · FirstName LastName: published', r)
}

// RED CONTROL: a refused confirm keeps the draft, an accepted one deletes it
async function deleteSteps(p, w) {
  await p.type('[data-test=marketing-posts-body]', 'Never sent')
  await tap(p, '[data-test=marketing-posts-save]')
  await p.waitForFunction((s) => document.querySelectorAll(s).length === 3, { timeout: 5000 }, ROW).catch(() => null)
  const id = (await rows(p))[0].id
  let accept = RED === 'confirm'
  const onDialog = (d) => (accept ? d.accept() : d.dismiss())
  p.on('dialog', onDialog)
  await tap(p, `${row(id)} [data-test=marketing-posts-delete]`)
  await sleep(400)
  const kept = Boolean(await p.$(row(id)))
  accept = true
  await tap(p, `${row(id)} [data-test=marketing-posts-delete]`)
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, row(id)).catch(() => null)
  p.off('dialog', onDialog)
  ok(`6 ${w}px: RED CONTROL a refused confirm keeps the draft, an accepted one deletes it`,
    kept && !(await p.$(row(id))) && (await text(p, '[data-test=marketing-posts-notice]')) === 'Draft deleted.', { kept })
}

async function run(browser, base, w) {
  const phone = w < 600
  const p = await browser.newPage()
  await p.setViewport({ width: w, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.marketing.publish')
    localStorage.setItem('spool-theme', 'light')
  })
  await p.goto(base + '/tenant-settings/posts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=marketing-posts-off]', { visible: true, timeout: 10000 }).catch(() => null)
  ok(`1 ${w}px: with marketing off the section says so in one line`, (await text(p, '[data-test=marketing-posts-off]')).startsWith('Marketing is off in this workspace.') &&
    !(await p.$('[data-test=marketing-posts-form]')))
  await openSection(p, 'general')
  await flipOn(p)
  await openSection(p, 'posts')
  const id = await writeSteps(p, w)
  await editSteps(p, w, id)
  await publishSteps(p, w, id)
  await deleteSteps(p, w)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.screenshot({ path: `${SHOT_DIR}/marketing-posts-${w}.png`, fullPage: true })
  }
  ok(`7 ${w}px: no page errors`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const w of [1440, 390]) await run(browser, server.base, w)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nmarketing-posts: ${results.length - failed.length}/${results.length} ok`)
if (failed.length) process.exit(1)
