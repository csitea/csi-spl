// Spec 042 section 3a "Note to self" (SPL-5372; owner HUM-10, t1 df36f210,
// msg 76800948): the @ picker offers the reader as `me`, and a post tagged
// only to its author is marked "note to self" in the topic. The mock stands
// in for the hub (spool-client-mock.mjs mockNoteToSelf, the twin of
// internal/hub/note_to_self.go). CONTROLS: an empty @ offers no `me`, and a
// post that tags the author and another person carries no mark.
//
// Run:
//   node tests/e2e/note-to-self.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/note-to-self.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OMNI = 'form.omnibox--global textarea'
const ME = 'HUM-1' /* the mock viewer (mock-data.mjs MOCK_ME) */
const OTHER = 'HUM-2'
const MARK = '[data-testid=msg-note-to-self]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

/** Send through the channel store, as the composer does; the new topic's task id ('' = refused). */
const topicOf = (p, channel, text) => p.evaluate(async (channel, text) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const row = await pinia?._s.get('channel')?.send(text, undefined, undefined, channel)
  return String(row?.task_id || '')
}, channel, text)

/** Open /t/<task> in the app (a reload would drop the mock's sends). */
const openTopic = (p, task) => p.evaluate(async (task) => {
  const router = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router
  if (!router) return false
  await router.push(`/t/${task}`)
  return true
}, task)

/** The @ list's rows: [data-id, is the `me` row]. */
const options = (p) => p.evaluate(() => [...document.querySelectorAll('[data-test=mention-option]')]
  .map((b) => [b.getAttribute('data-id'), Boolean(b.querySelector('[data-testid=mention-self]'))]))

/** Type into the omnibox from empty. */
async function typeOmni(p, text) {
  await p.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.click(OMNI)
  await p.keyboard.type(text)
  await sleep(300)
}

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector(OMNI, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(600)

  /* the picker: @me offers the reader first, marked as me */
  await typeOmni(page, '@me')
  await page.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => null)
  /* under load the list can still show the bare-@ roster 300 ms after the keys: wait for the query to apply */
  await page.waitForFunction(() => Boolean(document.querySelector('[data-test=mention-option] [data-testid=mention-self]')),
    { timeout: 8000 }).catch(() => null)
  const meRows = await options(page)
  ok('@me: the first row is the reader, marked me', meRows.length > 0 && meRows[0][0] === ME && meRows[0][1], meRows)
  await page.evaluate(() => document.querySelector('[data-test=mention-option]')
    ?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })))
  await sleep(200)
  const picked = await page.$eval(OMNI, (el) => el.value)
  ok('picking me writes the reader into the field, not "@me"', picked.startsWith('@') && !picked.startsWith('@me ') && picked.endsWith(' '), { picked })

  /* CONTROL: a bare @ never offers the reader */
  await typeOmni(page, '@')
  await page.waitForFunction(() => !document.querySelector('[data-test=mention-option] [data-testid=mention-self]'),
    { timeout: 8000 }).catch(() => null)
  const bare = await options(page)
  ok('CONTROL: a bare @ offers no me row and not the reader', !bare.some(([id, me]) => me || id === ME), bare)
  await page.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })

  /* the mark: a post tagged only to its author */
  const note = await topicOf(page, 'lobby', `@${ME} send the zip file on Friday`)
  const both = await topicOf(page, 'lobby', `@${ME} and @${OTHER} send the zip file`)
  ok('both posts are stored', Boolean(note && both), { note, both })
  const marked = Boolean(note) && await openTopic(page, note) &&
    Boolean(await page.waitForSelector(MARK, { visible: true, timeout: 10000 }).catch(() => null))
  const markText = marked ? await page.$eval(MARK, (e) => e.textContent.trim()) : ''
  ok('the note to self is marked "note to self"', marked && markText === 'note to self', { markText })
  const bothOpen = Boolean(both) && await openTopic(page, both)
  await page.waitForFunction(() => document.body.innerText.includes('send the zip file'), { timeout: 10000 }).catch(() => null)
  await sleep(600)
  ok('CONTROL: a post tagging the author and another person has no mark', bothOpen && !(await page.$(MARK)))
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nnote-to-self: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
