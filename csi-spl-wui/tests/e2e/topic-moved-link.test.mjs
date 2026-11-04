// Spec 169 row T7h (SPL-4781): an old /t/<uuid> link at the workspace a
// channel left takes the reader to the hub's moved_to. For 30 days (Q2) the
// hub answers that topic's read with 404 topic_moved and the new link,
// https://<DST_HOST>/t/<uuid> (channel_move.go topicMovedAnswer); the link
// never names the channel (case C8). After the 30 days the 404 carries no
// link and the page stays where it is, as for any topic it cannot read.
//
// The mock stands in for the hub: localStorage `spool.mock.moved-topics`
// ({ <task_id>: <link> }) makes its topic read answer that link
// (spool-client-mock.mjs mockGetTopic). The other workspace's host is
// answered by request interception, so nothing leaves the box. The env's
// apex (runtime config siteUrl, from /config.json when deployed; the mock
// bundle bakes "" and reads no config.json) is set by rewriting the inlined
// `siteUrl:""` of each served document: https://example.com makes
// dst.example.com a workspace host of this env (R7 N1); evil.test is not one.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-moved-link
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 390, height: 844 }, { width: 1440, height: 900 }]
const TASK = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const DST = 'https://dst.example.com'
const LINK = `${DST}/t/${TASK}`
const LANDED = 'moved-topic-landed'
const SITE = 'https://example.com'
const OFFSITE = 'evil.test'

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

/* a signed-in member at the old workspace; moved = the hub's answer per task id, or null */
async function fresh(browser, size, moved) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  const dst = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const u = new URL(req.url())
    if (req.resourceType() === 'document' && u.hostname !== new URL(DST).hostname && u.hostname !== OFFSITE) {
      return void fetch(req.url()).then(async (r) => req.respond({ status: r.status, contentType: r.headers.get('content-type') || 'text/html',
        body: (await r.text()).replace('siteUrl:""', `siteUrl:${JSON.stringify(SITE)}`) })).catch(() => req.continue())
    }
    if (u.hostname !== new URL(DST).hostname && u.hostname !== OFFSITE) return void req.continue()
    dst.push(req.url())
    void req.respond({ status: 200, contentType: 'text/html', body: `<!doctype html><title>${LANDED}</title><p>${LANDED}</p>` })
  })
  await p.evaluateOnNewDocument((m) => {
    try {
      if (location.origin.startsWith('https://dst.')) return
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      if (m) localStorage.setItem('spool.mock.moved-topics', JSON.stringify(m))
    } catch { /* about:blank */ }
  }, moved)
  await setPageViewport(p, size)
  return { ctx, p, errors, dst }
}

const pageErrors = (errors) => errors.filter((e) => !/dynamically imported module/.test(e))

/* open the old link and give the page time to follow it, or to settle */
async function openOld(p, base, hash = '') {
  await p.goto(`${base}/t/${TASK}${hash}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => {})
  await p.waitForFunction((l) => document.title === l, { timeout: 15000 }, LANDED).catch(() => {})
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`

    /* 1. the redirect is live: the old link lands on the new one */
    {
      const { ctx, p, errors, dst } = await fresh(browser, size, { [TASK]: LINK })
      await openOld(p, server.base)
      ok(`${tag} moved: the old link lands on the hub's moved_to (+ the hop mark)`, p.url() === `${LINK}#moved`, p.url())
      ok(`${tag} moved: the new workspace's page is drawn`, (await p.title()) === LANDED, await p.title())
      ok(`${tag} moved: the followed link names no channel`, dst.length > 0 && dst.every((u) => !new URL(u).search && !/channel/i.test(u)), dst)
      ok(`${tag} moved: no page error`, pageErrors(errors).length === 0, errors)
      await ctx.close()
    }

    /* 2. the 30 days are over (no moved_to): the page stays */
    {
      const { ctx, p, errors, dst } = await fresh(browser, size, null)
      await openOld(p, server.base)
      ok(`${tag} expired: the page stays on the old /t/<id>`, new URL(p.url()).pathname.endsWith(`/t/${TASK}`), p.url())
      ok(`${tag} expired: nothing is asked of another host`, dst.length === 0, dst)
      ok(`${tag} expired: no page error`, pageErrors(errors).length === 0, errors)
      await ctx.close()
    }

    /* 3. a moved_to that is not a topic link over https is never followed */
    {
      const { ctx, p, dst } = await fresh(browser, size, { [TASK]: `http://dst.example.com/t/${TASK}` })
      await openOld(p, server.base)
      ok(`${tag} not https: the page stays on the old /t/<id>`, new URL(p.url()).pathname.endsWith(`/t/${TASK}`), p.url())
      ok(`${tag} not https: nothing is asked of another host`, dst.length === 0, dst)
      await ctx.close()
    }

    /* 4. R7 N1: an https host that is not a workspace host of this env is never followed */
    {
      const { ctx, p, dst } = await fresh(browser, size, { [TASK]: `https://${OFFSITE}/t/${TASK}` })
      await openOld(p, server.base)
      ok(`${tag} off-site: the page stays on the old /t/<id>`, new URL(p.url()).pathname.endsWith(`/t/${TASK}`), p.url())
      ok(`${tag} off-site: nothing is asked of another host`, dst.length === 0, dst)
      await ctx.close()
    }

    /* 5. R7 N4: a page a move already opened (#moved) does not follow again */
    {
      const { ctx, p, dst } = await fresh(browser, size, { [TASK]: LINK })
      await openOld(p, server.base, '#moved')
      ok(`${tag} second hop: the page stays on the old /t/<id>`, new URL(p.url()).pathname.endsWith(`/t/${TASK}`), p.url())
      ok(`${tag} second hop: nothing is asked of another host`, dst.length === 0, dst)
      ok(`${tag} second hop: the hop mark is dropped from the address`, new URL(p.url()).hash === '', p.url())
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-moved-link: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
