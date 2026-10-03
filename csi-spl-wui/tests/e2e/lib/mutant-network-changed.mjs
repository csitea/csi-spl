// MUTANT, never used by CI: a puppeteer-core stand-in that plants the runner
// network churn retryOnNetworkChanged (lib/page-log.mjs) exists for.
//
// The FIRST page.goto of the run whose url contains E2E_PLANT_AT (default:
// any) loses every /_nuxt/*.js chunk, so the page stays blank, and those
// requests report net::ERR_NETWORK_CHANGED as their failure. Chrome cannot
// raise that error on demand (CDP's Fetch/Network error reasons have no such
// value), so the chunks are blocked and the failure text is relabelled; the
// page sees exactly what churn leaves behind: no chunk, no app.
//
//   PUPPETEER_CORE=$PWD/tests/e2e/lib/mutant-network-changed.mjs \
//     BASE_URL=<generated bundle> node tests/e2e/avatars-visible.test.mjs
//
// Expected: the test prints RETRY and passes; a test without the retry fails.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)
const mod = await import(pathToFileURL(require.resolve('puppeteer-core')).href)
const real = mod.default ?? mod
const PLANT_AT = process.env.E2E_PLANT_AT || ''
const CHUNKS = '*/_nuxt/*.js'
let planted = false
const plantedReqs = new WeakSet()

const ownerOf = (obj, key) => {
  for (let p = Object.getPrototypeOf(obj); p; p = Object.getPrototypeOf(p)) if (Object.hasOwn(p, key)) return p
  return null
}

function patchFailure(req) {
  const proto = ownerOf(req, 'failure')
  if (!proto || proto.__planted) return
  const orig = proto.failure
  proto.failure = function () { return plantedReqs.has(this) ? { errorText: 'net::ERR_NETWORK_CHANGED' } : orig.call(this) }
  proto.__planted = true
}

function patchGoto(page) {
  const proto = ownerOf(page, 'goto')
  if (!proto || proto.__planted) return
  const orig = proto.goto
  proto.goto = async function (url, opts) {
    if (planted || !String(url).includes(PLANT_AT)) return orig.call(this, url, opts)
    planted = true
    console.log(`  MUTANT ${url}: every ${CHUNKS} of this navigation fails as net::ERR_NETWORK_CHANGED`)
    const s = await this.createCDPSession()
    await s.send('Network.enable')
    await s.send('Network.setBlockedURLs', { urls: [CHUNKS] })
    const mark = (r) => { if (/\/_nuxt\/[^?]*\.js(\?|$)/.test(r.url())) { patchFailure(r); plantedReqs.add(r) } }
    this.on('request', mark)
    try {
      return await orig.call(this, url, opts)
    } finally {
      this.off('request', mark)
      await s.send('Network.setBlockedURLs', { urls: [] }).catch(() => {})
      await s.detach().catch(() => {})
    }
  }
  proto.__planted = true
}

export default {
  async launch(opts) {
    const browser = await real.launch(opts)
    const probe = await browser.newPage()
    patchGoto(probe)
    await probe.close()
    return browser
  },
}
