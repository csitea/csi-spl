// W15 (spec 047, SPL-1172): the first-run checklist on the home screen.
// The mock tenant is set up already (members, agents, topics), so the card
// is hidden - the control. With the home list emptied (a tenant with no
// topic yet) it shows the next 3 steps, the topic one open; each step links
// its place; Hide keeps it hidden across a reload.
//
// Run:
//   pnpm run test:e2e:first-run
//   BASE_URL=<generated bundle> pnpm run test:e2e:first-run
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

/* a tenant with no topic yet: the viewer store's list, emptied */
const emptyTopics = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const viewer = pinia?._s.get('viewer')
  if (!viewer) return false
  viewer.unfollow?.()
  viewer.topics = []
  return true
})
const steps = (p) => p.$$eval('[data-test^=first-run-step-]', (els) => els.map((e) => `${e.getAttribute('data-test').slice(15)}:${e.getAttribute('data-done')}`))

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { for (const k of Object.keys(localStorage)) if (k.startsWith('spl-first-run-hidden:')) localStorage.removeItem(k) } catch {} })
  await sleep(1500)
  ok('CONTROL a tenant that is set up shows no checklist', !(await p.$('[data-test=first-run]')))
  ok('an empty home list (no topic yet)', await emptyTopics(p))
  const card = await p.waitForSelector('[data-test=first-run]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('the checklist appears', Boolean(card))
  if (card) {
    const s = await steps(p)
    ok('it names the next 3 steps, the topic one open', s.join(' ') === 'invite:true agent:true topic:false', s)
    const links = await p.$$eval('[data-test^=first-run-link-]', (as) => as.map((a) => new URL(a.href).pathname))
    ok('each step links its place', links.join() === '/tenant-settings/members,/tenant-settings/agents,/lobby', links)
    const r = await card.boundingBox()
    ok('it sits in view at the top of the home list', Boolean(r && r.y >= 0 && r.y < 400), r)
    await p.click('[data-test=first-run-hide]')
    await sleep(300)
    ok('Hide takes it away', !(await p.$('[data-test=first-run]')))
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await emptyTopics(p)
    await sleep(1500)
    ok('and it stays hidden after a reload', !(await p.$('[data-test=first-run]')))
  }
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `first-run: ${failed} FAILED` : `first-run: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
