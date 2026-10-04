// The search syntax help says how a search starts, and a copied example
// works as typed: `/search:` at the very start of the bar.
//
//   node tests/e2e/search-help-start.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/search-help-start.test.mjs
import { createRequire } from 'node:module'
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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const btn = await p.waitForSelector('form.composer.omnibox--global [data-test=search-syntax-help]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  ok('the omnibox has the search syntax button', Boolean(btn))
  if (btn) {
    await btn.click()
    await p.waitForSelector('[data-test=search-syntax-panel]', { visible: true, timeout: 5000 }).catch(() => null)
    const pop = await p.evaluate(() => {
      const panel = document.querySelector('[data-test=search-syntax-panel]')
      if (!panel) return null
      const first = (panel.querySelector('p') || {}).textContent || ''
      const example = (panel.querySelector('.search-syntax__op span.muted') || {}).textContent || ''
      return { first, example }
    })
    ok('the syntax popover leads with the /search: start line', Boolean(pop && pop.first.includes('/search:') && pop.first.includes('/search ') && pop.first.includes('/s ')), pop && pop.first)
    ok('one popover example starts with /search:', Boolean(pop && pop.example.startsWith('/search:')), pop && pop.example)
  }

  await p.goto(server.base + '/search', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=search-help]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const page = await p.evaluate(() => {
    const help = document.querySelector('[data-test=search-help]')
    if (!help) return null
    const first = (help.querySelector('p') || {}).textContent || ''
    const example = (help.querySelector('code') || {}).textContent || ''
    return { first, example }
  })
  ok('the search page leads with the /search: start line', Boolean(page && page.first.includes('/search:') && page.first.includes('/search ') && page.first.includes('/s ')), page && page.first)
  ok('one search-page example starts with /search:', Boolean(page && page.example.startsWith('/search:')), page && page.example)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `search-help-start: ${failed} FAILED` : `search-help-start: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
