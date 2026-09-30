// CLE-77796 (owner HUM-10, prd t1 topic e09a72f7): "if a message starts with
// the @ char it cannot be sent ... which is strange". A BARE mention (`@CLE-07`
// with nothing after it) used to strip to an empty body and be refused by the
// send-path empty-send guard, so the message never left the box. Proved in a
// REAL browser (mock tenant), on /channel/alerts, driving the omnibox and the
// GO button exactly as a person does:
//
//   1 a bare mention `@CLE-07`            -> SENDS, a real row, body kept, a note
//   2 a mention with text `@CLE-07 <t>`   -> SENDS, task to CLE-07, body is <t>
//   3 unknown `@nobody <t>`               -> SENDS as plain text (note)
//   4 `@ <t>` (space after @)             -> SENDS as plain text (note)
//   5 `@` alone                           -> SENDS as plain text (note)
//
// Before the fix case 1 left no row (the guard threw); the others were never
// refused but are pinned here so "starts with @ always sends" stays true.
//
// Run:
//   node tests/e2e/at-send.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/at-send.test.mjs   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The channel rows this page holds, newest last (the store's own list). */
function rows(p) {
  return p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    return msgs.map((m) => ({ msg_id: m.msg_id, body: String(m.body || ''), to: String(m.to || ''), kind: String(m.kind || '') }))
  })
}

/** The store row whose body contains `needle`, and whether a card is drawn for it. */
async function sentRow(p, needle) {
  return p.evaluate((n) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    const m = [...msgs].reverse().find((x) => String(x.body || '').includes(n))
    if (!m) return null
    const sel = `article.msg[data-msg-id="${CSS.escape(String(m.msg_id))}"]`
    const drawn = [...document.querySelectorAll(sel)].filter((el) => el.getClientRects().length > 0).length
    return { msg_id: m.msg_id, body: String(m.body || ''), to: String(m.to || ''), kind: String(m.kind || ''), drawn }
  }, needle)
}

async function send(p, text) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.focus(ta)
  await p.type(ta, text)
  /* clear any open @ picker before the GO click (a person sees it close too) */
  await sleep(150)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(700)
}

const browser = await launch()
const server = await startServer()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(400)

  const before = (await rows(p)).length

  /* 1: THE FIX. A bare mention used to be refused as an empty send. */
  await send(p, '@CLE-07')
  const bare = await sentRow(p, '@CLE-07')
  ok('a bare @CLE-07 sends: a real row, the mention kept as its body, a note', Boolean(bare) && bare.body === '@CLE-07' && bare.to === '@channel' && bare.kind === 'note' && bare.drawn > 0, bare)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'at-send-bare.png') })

  /* 2: a mention FOLLOWED BY text still routes a task to that id, body is the text */
  await send(p, '@CLE-07 review-the-patch-7')
  const routed = await sentRow(p, 'review-the-patch-7')
  ok('@CLE-07 <text> routes a task to CLE-07, the text is the body', Boolean(routed) && routed.to === 'CLE-07' && routed.body === 'review-the-patch-7' && routed.drawn > 0, routed)

  /* 3: an id that is not a mention id is plain text - it always was, still is */
  await send(p, '@nobody plain-unknown-text-8')
  const unknown = await sentRow(p, 'plain-unknown-text-8')
  ok('@nobody <text> sends as a plain note, the @ kept in the body', Boolean(unknown) && unknown.to === '@channel' && unknown.body.includes('@nobody') && unknown.drawn > 0, unknown)

  /* 4: a space right after @ is not a mention */
  await send(p, '@ space-after-at-9')
  const spaced = await sentRow(p, 'space-after-at-9')
  ok('@ <text> sends as a plain note', Boolean(spaced) && spaced.to === '@channel' && spaced.body.includes('@ ') && spaced.drawn > 0, spaced)

  /* 5: `@` alone is a one-character message, and it sends */
  await send(p, '@')
  const only = await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    return [...msgs].reverse().find((x) => String(x.body || '').trim() === '@') || null
  })
  ok('`@` alone sends as a one-character note', Boolean(only) && String(only.to || '') === '@channel', only)

  const after = (await rows(p)).length
  ok('every case added a row (five sends, five new rows)', after - before === 5, { before, after })
  /* `nuxi dev` occasionally fails a lazy chunk fetch ("Failed to fetch
     dynamically imported module"); that is the dev server, not the send path,
     and never happens on the generated bundle CI drives. Only a real send
     error counts here. */
  const sendErrors = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page error from the send path while sending @-messages', sendErrors.length === 0, sendErrors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.error('FAILED:', failed.map((r) => r.name).join(' | '))
  process.exit(1)
}
