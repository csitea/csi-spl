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

/** A failed picker wait's evidence: the field and caret, the reader the roster knows, how many lists are open. */
const pickerState = (p) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  return {
    field: el?.value, caret: el?.selectionStart, focused: document.activeElement === el,
    rosterSelf: pinia?._s.get('roster')?.self?.id ?? null,
    draftPlace: pinia?._s.get('omnibox')?.target?.place?.() ?? null,
    lists: document.querySelectorAll('[data-test=mention-list]').length,
  }
}, OMNI).then((st) => ({ ...st, loads, refocused }))

/* keys after which the field had lost the focus: under nuxi dev (origin/master too) the first @ makes
   Vue's keyed patch MOVE the omnibox textarea (patchKeyedChildren -> move -> insert), the browser drops
   its focus to <body>, and the next keys went nowhere; the generated bundle keeps it */
let refocused = 0

/** Type into the omnibox from empty, a key at a time; a key that left the field blurred gets it back, caret at the end. */
async function typeOmni(p, text) {
  await p.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.click(OMNI)
  for (const key of text) {
    await p.keyboard.type(key)
    await sleep(50)
    /* nuxi dev only: a typed @ makes Vue move the textarea and drop its focus (orch finding msg ed8eb595, no lane) */
    refocused += await p.$eval(OMNI, (el) => {
      if (document.activeElement === el) return 0
      el.focus()
      el.setSelectionRange(el.value.length, el.value.length)
      return 1
    })
  }
  await sleep(300)
}

/** The lobby is settled: the roster knows the reader and the box knows its draft place. */
const settle = (p) => p.waitForFunction((me) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  return pinia?._s.get('roster')?.self?.id === me && Boolean(pinia?._s.get('omnibox')?.target?.place?.())
}, { timeout: NAV_TIMEOUT }, ME).then(() => true, () => false)

/* main-frame loads: under nuxi dev the first @ fetches the lazy status line (MessageComposer
   LazyComposerStatusLine), and a reload there would leave the box "@", restored and blurred */
let loads = 0

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) loads++ })
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector(OMNI, { visible: true, timeout: NAV_TIMEOUT })
  /* type only once the roster knows the reader and the box knows its draft place: a place that arrives
     later swaps the box for that place's stored draft (useComposerDraft) and eats what was typed */
  const settled = await settle(page)
  ok('the lobby knows the reader and its draft place before the test types', settled, settled ? undefined : await pickerState(page))
  /* load the chunks a typed @ needs (the status line) before the measured typing; settle again if that reloaded */
  const before = loads
  await typeOmni(page, '@')
  await page.waitForNetworkIdle({ idleTime: 1000, timeout: NAV_TIMEOUT }).catch(() => {})
  if (loads !== before) await page.waitForSelector(OMNI, { visible: true, timeout: NAV_TIMEOUT }).then(() => settle(page))
  await page.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  await sleep(600)

  /* the picker: @me offers the reader first, marked as me */
  await typeOmni(page, '@me')
  const typed = await page.$eval(OMNI, (el) => el.value)
  ok('the box holds the typed @me', typed === '@me', typed === '@me' ? { refocused } : await pickerState(page))
  /* under load the list can still show the bare-@ roster 300 ms after the keys: wait for the `me` row; a
     timeout is a FAIL, and its evidence says why (the field, the reader the roster knows, the rows) */
  const meShown = await page.waitForFunction(() => Boolean(document.querySelector('[data-test=mention-option] [data-testid=mention-self]')),
    { timeout: 8000 }).then(() => true, () => false)
  const meRows = await options(page)
  ok('@me: the first row is the reader, marked me', meShown && meRows.length > 0 && meRows[0][0] === ME && meRows[0][1],
    { rows: meRows, ...(meShown ? {} : await pickerState(page)) })
  await page.evaluate(() => document.querySelector('[data-test=mention-option]')
    ?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })))
  await sleep(200)
  const picked = await page.$eval(OMNI, (el) => el.value)
  ok('picking me writes the reader into the field, not "@me"', picked === `@${ME} `, { picked })

  /* CONTROL: a bare @ never offers the reader */
  await typeOmni(page, '@')
  /* the roster must be listed first: an empty list would pass the control on nothing */
  const bareShown = await page.waitForFunction(() => document.querySelectorAll('[data-test=mention-option]').length > 0 &&
    !document.querySelector('[data-test=mention-option] [data-testid=mention-self]'), { timeout: 8000 }).then(() => true, () => false)
  const bare = await options(page)
  ok('CONTROL: a bare @ lists the roster, with no me row and not the reader',
    bareShown && bare.length > 0 && !bare.some(([id, me]) => me || id === ME),
    { rows: bare, ...(bareShown ? {} : await pickerState(page)) })
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
