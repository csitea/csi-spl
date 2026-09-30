// CLE-77795 (owner HUM-10, prd #spool-hub-bugs topic 4b0ba40a, 2026-09-30):
// "It should be possible to upload an image to a msg, which does not have any
// text, aka when clicking the Play/go button it would just upload the pic."
//
// A message that is ONLY an attachment (no text) must send on GO and on Enter,
// with the file appearing as the message. The composer must clear afterwards.
// CONTROL: on the pre-fix build the attachment-only GO/Enter dropped the file.
//
// Run:
//   pnpm run test:e2e:attach-only
//   BASE_URL=<generated bundle> pnpm run test:e2e:attach-only   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// a throwaway file to attach (never committed; not an image, any bytes upload)
const FIXTURE = join(tmpdir(), `cle77795-attach-${process.pid}.txt`)
writeFileSync(FIXTURE, 'attachment-only payload')

const rows = (p) => p.evaluate(() =>
  [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
    .map((el) => ({ id: el.getAttribute('data-msg-id'), files: el.querySelectorAll('.file-card, .file-icon, [data-testid=card-title-file], [data-test=file-kind]').length })))

async function openChannel(browser, path, vp) {
  const p = await browser.newPage()
  if (vp) await p.setViewport(vp)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.omnibox--global [data-testid=attach-input]', { timeout: NAV_TIMEOUT })
  await sleep(500)
  return { p, errors }
}

async function attach(p) {
  const input = await p.$('form.omnibox--global [data-testid=attach-input]')
  await input.uploadFile(FIXTURE)
  await sleep(400)
  return p.$eval('form.omnibox--global', (f) => f.querySelectorAll('.file-chips li').length)
}

async function sendCase(browser, how, vp) {
  const { p, errors } = await openChannel(browser, '/channel/alerts', vp)
  const start = await rows(p)
  const startIds = new Set(start.map((r) => r.id))
  const chips = await attach(p)
  // no text typed at all
  const text = await p.$eval('form.omnibox--global textarea', (t) => t.value)
  if (how === 'go') await p.click('form.omnibox--global [data-testid=send]')
  else { await p.focus('form.omnibox--global textarea'); await p.keyboard.press('Enter') }
  let fresh = []
  for (let i = 0; i < 20 && fresh.length === 0; i++) {
    await sleep(250)
    fresh = (await rows(p)).filter((r) => !startIds.has(r.id))
  }
  const grew = fresh.length > 0
  const sentHasFile = grew && fresh.some((r) => r.files > 0)
  const cleared = await p.$eval('form.omnibox--global', (f) => f.querySelector('textarea').value === '' && f.querySelectorAll('.file-chips li').length === 0)
  const tag = vp ? `phone ${how}` : `${how}`
  ok(`${tag}: an attachment-only message sends`, chips === 1 && text === '' && grew, { chips, text, fresh })
  ok(`${tag}: the sent row carries the file`, sentHasFile, fresh)
  ok(`${tag}: the composer clears after send`, cleared)
  ok(`${tag}: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const server = await startServer()
const browser = await launch()
try {
  await (await openChannel(browser, '/channel/alerts')).p.close() // warm chunks
  await sendCase(browser, 'go')
  await sendCase(browser, 'enter')
  await sendCase(browser, 'go', PHONE)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
