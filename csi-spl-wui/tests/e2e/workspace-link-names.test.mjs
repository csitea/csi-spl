// Owner t1 cf09a010: a pasted link to another workspace names it the way the
// workspace drop-down does (its display name), never by its tenant id. The
// mock bundle is served under tenant hosts of a reserved test domain (the
// requests are answered from the local server). A mock build reads no
// /config.json, so the served page's baked public config is rewritten to
// turn tenant hosts on: the page is the csi-rel workspace, the apex is t1.
// A workspace the viewer is not a member of keeps its id.
//
// Run: BASE_URL=<generated bundle> node tests/e2e/workspace-link-names.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SITE_HOST = 'hub.example'
const SITE = `https://${SITE_HOST}`
const PAGE_ORIGIN = `https://csi-rel.${SITE_HOST}`
const PEER = 'CLE-07@box-a'
const TOPIC = '170c444e-db05-4e2f-9af4-fceb716a557a'
const MSG = '2ad2a99f-db05-4e2f-9af4-fceb716a557a'
const DM_TASK = 'fe510000-0000-4000-8000-0000000000b7'
const DOT = ' · '

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const LINKS = {
  apexMessage: `${SITE}/channel/spool-hub-bugs?topic=${TOPIC}#${MSG}`,
  otherTopic: `https://csitea.${SITE_HOST}/t/${TOPIC}`,
  stranger: `https://stranger.${SITE_HOST}/t/${TOPIC}`,
  sameTopic: `${PAGE_ORIGIN}/channel/feedback?topic=${TOPIC}`,
}

function rows() {
  const baseRow = { v: 1, files: [], kind: 'note', is_parent: 1, parent_task_id: null }
  return [
    { ...baseRow, msg_id: 'fe540000-0000-4000-8000-0000000000b7', task_id: DM_TASK, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: Object.values(LINKS).join('\n'), ts: '2026-12-31T23:59:00Z' },
  ]
}

const CLAIMS = {
  hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 'csi-rel', active_tenant: 'csi-rel',
  tenants: [
    { tenant_id: 't1', display_name: 'spool-hub' },
    { tenant_id: 'csi-rel', display_name: 'relishbg' },
    { tenant_id: 'csitea', display_name: 'csitea-ws' },
  ],
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

/* Every request to a test tenant host is answered from the local server;
   an HTML page gets this env's public config with tenant hosts on. */
function withTenantHosts(html) {
  return html
    .replace(/([{,]tenantHosts:)"0"/, '$1"1"')
    .replace(/([{,]siteUrl:)""/, `$1"${SITE}"`)
    .replace(/([{,]tenant:)""/, '$1"t1"')
}

async function serveAsTenantHosts(p, base) {
  await p.setRequestInterception(true)
  p.on('request', async (req) => {
    let u
    try { u = new URL(req.url()) } catch { return req.continue() }
    const h = u.hostname
    if (u.protocol !== 'https:' || (h !== SITE_HOST && !h.endsWith('.' + SITE_HOST))) return req.continue()
    try {
      const res = await fetch(base + u.pathname + u.search, { method: req.method(), redirect: 'manual' })
      const headers = {}
      res.headers.forEach((v, k) => { if (!/^(content-encoding|content-length|transfer-encoding|connection)$/i.test(k)) headers[k] = v })
      const body = Buffer.from(await res.arrayBuffer())
      const html = /text\/html/i.test(res.headers.get('content-type') || '')
      return req.respond({ status: res.status, headers, body: html ? withTenantHosts(body.toString('utf8')) : body })
    } catch {
      return req.respond({ status: 502, contentType: 'text/plain', body: 'unreachable' })
    }
  })
}

const look = (p, hrefs) => p.evaluate((want) => {
  const links = [...document.querySelectorAll('a.msg-link')]
  const out = {}
  for (const [k, href] of Object.entries(want)) {
    const a = links.find((el) => el.getAttribute('title') === href)
    out[k] = a ? { text: (a.textContent || '').trim(), test: a.getAttribute('data-test') || '' } : null
  }
  return out
}, hrefs)

const srv = await startServer()
const browser = await launch()
try {
  for (const [label, vp] of [['1440px', { width: 1440, height: 900 }], ['390px', { width: 390, height: 844, isMobile: true, hasTouch: true }]]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport(vp)
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
    await serveAsTenantHosts(p, srv.base)
    await p.evaluateOnNewDocument((extra, claims) => {
      try {
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
        localStorage.setItem('spool.mock.session', JSON.stringify(claims))
      } catch { /* private mode */ }
    }, rows(), CLAIMS)
    let shell = false
    for (let attempt = 0; attempt < 2 && !shell; attempt++) {
      await p.goto(`${PAGE_ORIGIN}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : 120000 }).then(() => true, () => false)
    }
    ok(`${label} the shell is up on the csi-rel host`, shell, errors.slice(0, 3))
    if (!shell) { await p.close(); continue }
    const want = {
      apexMessage: 'workspace: spool-hub' + DOT + 'message: ' + MSG.slice(0, 8),
      otherTopic: 'workspace: csitea-ws' + DOT + 'topic: ' + TOPIC.slice(0, 8),
      stranger: 'workspace: stranger' + DOT + 'topic: ' + TOPIC.slice(0, 8),
      sameTopic: 'topic: ' + TOPIC.slice(0, 8),
    }
    let s = null
    const start = Date.now()
    while (Date.now() - start < 45000) {
      s = await look(p, LINKS).catch(() => null)
      if (s && Object.keys(want).every((k) => s[k] && s[k].text === want[k])) break
      await sleep(200)
    }
    ok(`${label} the apex message link reads its display name, not t1`, !!(s && s.apexMessage && s.apexMessage.text === want.apexMessage && s.apexMessage.test === 'app-link'), s && s.apexMessage)
    ok(`${label} another member workspace reads its display name`, !!(s && s.otherTopic && s.otherTopic.text === want.otherTopic), s && s.otherTopic)
    ok(`${label} a workspace the viewer is not in keeps its id`, !!(s && s.stranger && s.stranger.text === want.stranger), s && s.stranger)
    ok(`${label} the same workspace has no workspace segment`, !!(s && s.sameTopic && s.sameTopic.text === want.sameTopic), s && s.sameTopic)
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nworkspace-link-names: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log('FAILED:', failed.map((f) => f.name).join('; '))
  process.exit(1)
}
