// DB payload cut 4 live proof (owner t1 66233cdc): the view message JSON
// leaves out env.sig, empty files/reactions, the default [box-wui sent] and
// the topic's own task_id; the WUI defaults them back. READ-ONLY: one member
// signs in and opens Flow (/), #lobby (/channel/lobby) and one topic (/t/<id>);
// it never posts, edits or deletes.
//
// Per page it records: every /v1/view/topics* response (bytes, how many
// elements still carry sig / an empty reactions / the default delivery - all
// 0 once the cut is live, >0 before), the rendered messages ([data-msg-id]),
// reactions ([data-testid=msg-reactions]), file previews ([data-test=file-kind])
// and the page's console errors, plus a screenshot.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [TOPIC=<task_id>] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/view-json-trims-live.proof.mjs
//
// Exit 0 = every page rendered messages with no console error. The password
// is read from PW_FILE and never printed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

function trimStats(body) {
  const els = []
  const take = (ms) => { for (const m of ms || []) els.push(m) }
  take(body && body.messages)
  for (const t of (body && body.topics) || []) take(t.messages)
  return {
    topics: ((body && body.topics) || []).map((t) => t.task_id).filter(Boolean),
    elements: els.length,
    withSig: els.filter((m) => m && m.env && 'sig' in m.env).length,
    emptyReactions: els.filter((m) => Array.isArray(m.reactions) && m.reactions.length === 0).length,
    defaultDelivery: els.filter((m) => Array.isArray(m.deliveries) && m.deliveries.length === 1 &&
      m.deliveries[0].to_box === 'box-wui' && m.deliveries[0].state === 'sent').length,
  }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const res = { base: BASE, at: new Date().toISOString(), pages: {} }
let failed = false
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  const p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1440, height: 900 })
  let errors = [], views = []
  p.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  p.on('pageerror', (e) => errors.push(String(e && e.message || e)))
  p.on('response', async (r) => {
    if (!/\/v1\/view\/topics/.test(r.url()) || r.request().method() !== 'GET' || r.status() !== 200) return
    try { const t = await r.text(); views.push({ url: r.url().replace(/^https?:\/\/[^/]+/, ''), bytes: t.length, ...trimStats(JSON.parse(t)) }) } catch { /* body gone */ }
  })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/'), { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  if (!await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)) throw new Error('sign-in failed at ' + p.url())
  await sleep(2000)

  async function page(name, path, prep) {
    errors = []; views = []
    await p.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 60000 })
    await sleep(3000)
    const extra = prep ? await prep() : {}
    const dom = await p.evaluate(() => ({
      messages: document.querySelectorAll('[data-msg-id]').length,
      reactions: document.querySelectorAll('[data-testid=msg-reaction]').length,
      files: document.querySelectorAll('[data-test=file-kind],[data-testid=card-title-file]').length,
      firstTask: (document.querySelector('[data-task-id]') || {}).dataset?.taskId || '',
    }))
    await p.screenshot({ path: `${OUT}/${name}.png` })
    Object.assign(dom, extra)
    const ok = dom.messages > 0 && errors.length === 0
    if (!ok) failed = true
    res.pages[name] = { path, ...dom, consoleErrors: errors.slice(), views: views.slice(), ok }
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name} ${path} ${extra.flowEntries !== undefined ? 'flowEntries=' + extra.flowEntries + ' ' : ''}messages=${dom.messages} reactions=${dom.reactions} files=${dom.files} consoleErrors=${errors.length} views=${JSON.stringify(views.map(({ url, topics, ...v }) => v))}`)
    return dom
  }
  // Flow: the rail tab's message entries; the first one opened in place
  await page('flow', '/', async () => {
    await p.click('#sidebar-tab-flow')
    await p.waitForSelector('#sidebar-panel-flow li, #sidebar-panel-flow [role=option]', { timeout: 20000 }).catch(() => null)
    const sel = '#sidebar-panel-flow li, #sidebar-panel-flow [role=option]'
    const flowEntries = await p.$$eval(sel, (els) => els.length)
    const first = await p.$(sel + ' button, ' + sel)
    if (first) { await first.click(); await sleep(3000) }
    return { flowEntries }
  })
  await page('channel', '/channel/lobby')
  const topic = process.env.TOPIC || ((res.pages.channel.views.find((v) => v.topics.length) || {}).topics || [])[0]
  if (topic) await page('topic', '/t/' + encodeURIComponent(topic))
  else { failed = true; console.log('FAIL topic: no task id found on Flow; pass TOPIC=') }
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/view-json-trims.json`, JSON.stringify(res, null, 1))
console.log('build', JSON.stringify(res.build || {}))
process.exit(failed ? 1 : 0)
