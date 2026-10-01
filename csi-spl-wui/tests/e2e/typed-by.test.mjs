// specs/036 FR-011, proved in a REAL browser: a line the owner TYPED at an
// agent's terminal (from=CLE-07, hub-verified typed_by=HUM-1) renders as the
// HUMAN - avatar and name are HUM-1's - with a small "via terminal CLE-07"
// badge (owner 2026-09-25: "whenever I type anyting in the terminal prompot of
// the ai agents it should be visible as me typing it here on the web ui").
//
// Against the mock bundle: src/utils/mock-data.mjs carries one such row in
// #lobby (8888...). CONTROL: the ordinary lobby row (1111..., HUM-1's own
// post) has no badge, so a selector that matches every row cannot read green;
// and the typed row's name must NOT be the agent's.
//
// Run:
//   pnpm run test:e2e typed-by
//   BASE_URL=<generated bundle> pnpm run test:e2e typed-by     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TYPED = '88888888-8888-4888-8888-888888888888'
const PLAIN = '11111111-1111-4111-8111-111111111111'

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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** What one lobby row shows: author name + tooltip, avatar alt, the badge. */
function rowFacts(page, id) {
  return page.evaluate((msgId) => {
    const row = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
    if (!row) return null
    const author = row.querySelector('.msg-meta .msg-author')
    const badge = row.querySelector('[data-testid=msg-typed-by]')
    return {
      name: author ? author.textContent.trim() : null,
      nameTitle: author ? author.getAttribute('title') : null,
      avatarAlt: row.querySelector('img.avatar')?.getAttribute('alt') || null,
      aria: row.getAttribute('aria-label'),
      badge: badge ? badge.textContent.trim() : null,
      typedBy: badge ? badge.getAttribute('data-typed-by') : null,
      via: badge ? badge.getAttribute('data-via') : null,
    }
  }, id)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${TYPED}"]`, { timeout: NAV_TIMEOUT })

  const typed = await rowFacts(p, TYPED)
  ok('1 the typed row carries the "via terminal" badge for CLE-07, typed by HUM-1',
    typed?.typedBy === 'HUM-1' && typed?.via === 'CLE-07' && /terminal/i.test(typed?.badge || '') && (typed?.badge || '').includes('CLE-07'), typed)
  ok('2 the typed row is shown as the human, not the agent',
    Boolean(typed?.name) && typed.name !== 'CLE-07' && (typed.nameTitle || typed.name).includes('HUM-1') && (typed.aria || '').includes('HUM-1'), typed)

  const plain = await rowFacts(p, PLAIN)
  ok('3 CONTROL: an ordinary row has no badge', Boolean(plain) && plain.badge === null, plain)
  ok('4 no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
