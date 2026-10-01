// HUM-24 (csitea ba4696c1), proved in a REAL browser: "all AI-generated
// messages should have a different background, for example, or an icon". An
// agent's card carries a faint accent tint and an "AI" badge (tooltip "AI
// agent") beside the name; a person's card is unchanged; a line the owner
// TYPED at an agent's terminal (specs/036) is the human's, so it is NOT marked.
//
// Against the mock bundle: topic bbbb... holds HUM-1's opener (2222...) and
// CLE-07's replies (3333...); #lobby holds HUM-1's post (1111...) and CLE-07's
// row typed by HUM-1 (8888...). CONTROL: the human and the typed rows have no
// badge and keep the plain background, so a selector that matches every row
// cannot read green. 1440x900 and 390x844, light and dark.
//
// Run:
//   pnpm run test:e2e ai-marker
//   BASE_URL=<generated bundle> pnpm run test:e2e ai-marker     # what CI does
//   SHOT_DIR=/tmp/shots ...                                      # keep the screenshots
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const AGENT = '33333333-3333-4333-8333-333333333333'
const OPENER = '22222222-2222-4222-8222-222222222222'
const HUMAN = '11111111-1111-4111-8111-111111111111'
const TYPED = '88888888-8888-4888-8888-888888888888'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const THEMES = ['light', 'dark']

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

/** One row: the AI flag, the badge (text, tooltip, shown), the resting fill. */
function rowFacts(page, id) {
  return page.evaluate((msgId) => {
    const row = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
    if (!row) return null
    const badge = row.querySelector('[data-testid=msg-ai-badge]')
    const r = badge ? badge.getBoundingClientRect() : null
    return {
      ai: row.getAttribute('data-ai'),
      badge: badge ? badge.textContent.trim() : null,
      title: badge ? badge.getAttribute('title') : null,
      shown: Boolean(r && r.width > 0 && r.height > 0),
      bg: getComputedStyle(row).backgroundColor,
    }
  }, id)
}

const clear = (bg) => bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent'
const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await setPageViewport(p, size)
    const open = async (path, id) => {
      await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(`article.msg[data-msg-id="${id}"]`, { timeout: NAV_TIMEOUT })
    }
    const paint = async (theme) => {
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      /* the pointer away from every card, so no row reads its hover fill */
      await p.mouse.move(1, 1)
    }
    await open(`/t/${TOPIC}`, AGENT)
    for (const theme of THEMES) {
      await paint(theme)
      const agent = await rowFacts(p, AGENT)
      const human = await rowFacts(p, OPENER)
      ok(`${tag} ${theme}: the agent card carries the "AI" badge with the "AI agent" tooltip`,
        agent?.ai === 'true' && agent.badge === 'AI' && agent.title === 'AI agent' && agent.shown, agent)
      ok(`${tag} ${theme}: the agent card is tinted, the human card is not`,
        Boolean(agent && human) && !clear(agent.bg) && agent.bg !== human.bg, { agent: agent?.bg, human: human?.bg })
      ok(`${tag} ${theme}: CONTROL a person's card has no marker`, human?.ai === null && human.badge === null, human)
      if (process.env.SHOT_DIR) {
        mkdirSync(process.env.SHOT_DIR, { recursive: true })
        await p.screenshot({ path: join(process.env.SHOT_DIR, `ai-marker-${tag}-${theme}.png`) })
      }
    }
    await open('/lobby', TYPED)
    for (const theme of THEMES) {
      await paint(theme)
      const human = await rowFacts(p, HUMAN)
      const typed = await rowFacts(p, TYPED)
      ok(`${tag} ${theme}: CONTROL a line typed at the agent terminal stays the human's`,
        Boolean(human) && typed?.ai === null && typed.badge === null && typed.bg === human.bg, { typed, human: human?.bg })
    }
    ok(`${tag}: no page error`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
