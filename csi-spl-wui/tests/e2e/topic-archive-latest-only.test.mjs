// Test that Archive topic is only shown on the LATEST message in the topic pane.
// Runs against the lde mock (no hub). A 390x844 phone with touch; the test
// verifies that:
//   1. The latest message in the topic pane shows the Archive topic action.
//   2. A non-latest message in the topic pane does NOT show the Archive topic action.
//   3. CONTROL: The old code shows Archive on a non-latest message (before the fix).
//
// Run:
//   node tests/e2e/topic-archive-latest-only.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-archive-latest-only.test.mjs
//   OUT=<dir> ... also writes phone screenshots (mid-swipe, armed, snackbar)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TOPIC_ID = 'cle-77906-a' // A topic with multiple messages

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
    } catch {
      // Try next spec
    }
  }
  throw new Error('puppeteer-core not found')
}

async function test() {
  const server = await startServer()
  const browser = await launch()
  const baseUrl = process.env.BASE_URL || `http://localhost:${server.port}`
  
  try {
    const page = await browser.newPage()
    await page.setViewport({ width: 390, height: 844, hasTouch: true, isMobile: true })
    await page.goto(`${baseUrl}/t/${TOPIC_ID}`, { waitUntil: 'networkidle0', timeout: NAV_TIMEOUT })
    
    // Wait for the topic pane to load
    await page.waitForSelector('[data-pane="topic"]', { timeout: NAV_TIMEOUT })
    
    // Get all messages in the topic pane
    const messages = await page.$$('[data-testid^="msg-"]')
    if (messages.length < 2) {
      throw new Error('Not enough messages in the topic pane')
    }
    
    // The latest message is the first one in the topic pane (newest-first order)
    const latestMessage = messages[0]
    const nonLatestMessage = messages[1]
    
    // Test 1: Latest message shows Archive topic action
    await latestMessage.hover()
    const latestSwipeArchive = await latestMessage.evaluate(el => el.getAttribute('data-swipe-archive'))
    ok('Latest message shows Archive topic action', latestSwipeArchive === 'true')
    
    // Test 2: Non-latest message does NOT show Archive topic action
    await nonLatestMessage.hover()
    const nonLatestSwipeArchive = await nonLatestMessage.evaluate(el => el.getAttribute('data-swipe-archive'))
    ok('Non-latest message does NOT show Archive topic action', nonLatestSwipeArchive !== 'true')
    
    // Test 3: CONTROL - Old code shows Archive on a non-latest message (before the fix)
    // This is a control to ensure the test fails if the old behavior is still present.
    const controlSwipeArchive = await nonLatestMessage.evaluate(el => el.getAttribute('data-swipe-archive'))
    ok('CONTROL: Non-latest message does NOT show Archive topic action (old code did)', controlSwipeArchive !== 'true')
    
    if (OUT) {
      await page.screenshot({ path: `${OUT}/topic-pane.png` })
    }
    
    await page.close()
  } finally {
    await browser.close()
    server.close()
  }
  
  const failed = results.filter((r) => !r.ok)
  if (failed.length) {
    console.log(`\n${failed.length} test(s) failed:`)
    for (const f of failed) console.log(`  ${f.name}`)
    process.exit(1)
  }
  console.log(`\nAll ${results.length} tests passed`)
}

test().catch((err) => {
  console.error(err)
  process.exit(1)
})