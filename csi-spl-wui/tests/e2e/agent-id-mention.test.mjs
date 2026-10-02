// spec 061 (agent id rename), wave A: a message that names an agent by the new
// id renders it as a mention chip, with its box, and a legacy id still does:
// `@c-004@box-desk` and `@CLE-001` both become `.mention` chips in the card.
// Real browser, mock tenant, 1440 and 390.
//
// Run:
//   node tests/e2e/agent-id-mention.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/agent-id-mention.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const NEW = '@c-004@box-desk'
const LEGACY = '@CLE-001'

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

/** A fresh channel, opened, then a new topic in it; its msg_id ('' on a miss). */
const postInChannel = (p, name, text) => p.evaluate(async (name, text) => {
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const ch = app?.config?.globalProperties?.$pinia?._s.get('channel')
  if (!ch) return ''
  const row = await ch.createChannel(name)
  await app.config.globalProperties.$router.push('/channel/' + row.channel_id)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send(text, undefined, undefined, undefined, 1)
  return String(one?.msg_id || '')
}, name, text)

/** The mention chips of one card. */
const chipsOf = (p, id) => p.$$eval(`article.msg[data-msg-id="${id}"] .mention`, (els) => els.map((m) => (m.textContent || '').trim()))

const srv = await startServer()
const browser = await launch()
try {
  for (const [width, height, mobile] of [[1440, 900, false], [390, 800, true]]) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width, height, isMobile: mobile, hasTouch: mobile })
    await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
    await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(600)
    const id = await postInChannel(page, `spec061-${width}`, `please look, ${NEW} and ${LEGACY}`)
    const shown = id ? Boolean(await page.waitForSelector(`article.msg[data-msg-id="${id}"]`, { timeout: 10000 }).catch(() => null)) : false
    const chips = shown ? await chipsOf(page, id) : null
    ok(`${width}: the line is sent and shown`, shown, { id })
    ok(`${width}: ${NEW} renders as a mention chip`, Array.isArray(chips) && chips.includes(NEW), chips)
    ok(`${width}: ${LEGACY} still renders as a mention chip`, Array.isArray(chips) && chips.includes(LEGACY), chips)
    await page.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nagent-id-mention: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
