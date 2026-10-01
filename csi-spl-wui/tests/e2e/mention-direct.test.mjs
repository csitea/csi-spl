// CLE-77852 (owner bug t1 e6c13767): an @-mention of an agent that is seated
// in the workspace but not a member of the channel shows "Sent to <agent> as a
// direct message: not a member of this channel" - not the old "Not told, they
// cannot read this". Gate-run (mock bundle) control; the poke itself is a real
// DM only on a live tenant (mention-poke-live.proof.mjs).
//
// The mock roster (src/utils/mock-data.mjs) seats CLE-11 on box-desk; a fresh
// channel has HUM-1 as its only member and no agents. CLE-99 is seated nowhere.
//
// Run:
//   node tests/e2e/mention-direct.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/mention-direct.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = 'cle-77852-direct'
const SEATED = 'CLE-11'
const UNSEATED = 'CLE-99'
const TOAST = '[data-testid=mention-direct-toast-text]'

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

/** Send through the channel store, as the composer does. */
const post = (p, channel, text) => p.evaluate(async (channel, text) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const ch = pinia?._s.get('channel')
  if (!ch) return false
  await ch.send(text, undefined, undefined, channel)
  return true
}, channel, text)

const toastText = (p) => p.$eval(TOAST, (e) => e.textContent.trim()).catch(() => '')

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* control: #lobby is open to every agent, so nobody goes "direct" */
  const sentLobby = await post(page, 'lobby', `please look, @${SEATED}`)
  await sleep(1200)
  ok('a mention in the open #lobby shows no direct notice', sentLobby && !(await toastText(page)), { sentLobby })

  const made = await page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const row = await ch.createChannel(name)
    return String(row?.channel_id || '')
  }, CHANNEL)
  ok('a members-only channel is created (no agents in it)', Boolean(made), { made })

  const sent = made ? await post(page, made, `check this one @${SEATED} and @${UNSEATED}`) : false
  const shown = Boolean(await page.waitForSelector(TOAST, { timeout: 10000 }).catch(() => null))
  const text = await toastText(page)
  ok(`the seated non-member ${SEATED} gets the direct notice`, sent && shown && text.includes(SEATED) && /direct message/i.test(text), { text })
  ok(`the unseated ${UNSEATED} is not named as sent`, !text.includes(UNSEATED), { text })
  const errs = await page.$$eval('.error-snackbar__text', (els) => els.map((e) => e.textContent || '').join(' ')).catch(() => '')
  ok('no "cannot read this" error for the seated agent', !/cannot read this/i.test(errs), { errs: errs.slice(0, 200) })

  /* the close button dismisses it */
  await page.click('[data-testid=mention-direct-toast-close]').catch(() => {})
  await sleep(300)
  ok('the notice closes', !(await toastText(page)))
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmention-direct: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
