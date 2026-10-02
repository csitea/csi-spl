// #tasks is gone, issues replace it (SPL-68, specs/039 §Discussion space) —
// live proof, signed in, against a deployed WUI + hub.
//
// Owner, 2026-09-26: "the tasks channel should be removed - issues should be
// used for it".
//
// Steps (n = 1 per run):
//   1. GET /v1/view/channels lists lobby, alerts and feedback, and neither
//      tasks nor the reserved issues id
//   2. the sidebar's channel list shows no #tasks (and no #issues)
//   3. an existing issue whose discussion predates the move (ISSUE=<key>, or
//      the oldest issue with a comment) still shows every comment the hub
//      holds for its topic
//   4. a comment posted from the issue's right pane shows and reaches the
//      hub's topic read, signed with channel `issues`
// The STORED channel (messages.channel, what the read door uses) is not on
// the view API - the topic read returns the signed envelope, and a comment
// signed before rdb 0050 still says `tasks` there. The JSON lists the
// msg_ids so do_spl_db_query can show the stored channel.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [ISSUE=SPL-n] [COMMENT=0]
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/tasks-gone-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const COMMENT = process.env.COMMENT !== '0'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
}

const envOf = (m) => { try { return typeof m.env === 'string' ? JSON.parse(m.env) : (m.env || {}) } catch { return {} } }
const idOf = (m) => envOf(m).msg?.msg_id || ''
const hub = (p, path) => p.evaluate(async (api, pa) => {
  const r = await fetch(api + pa, { credentials: 'include' })
  return { status: r.status, body: r.ok ? await r.json() : null }
}, API, path)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  headless: true,
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed, { url: p.url() })
  if (!signed) throw new Error('not signed in')
  res.hub = await fetch(API + '/version').then((r) => r.json()).catch((e) => ({ error: String(e) }))

  // 1. the channel list the hub answers
  const ch = await hub(p, '/v1/view/channels')
  const ids = (ch.body?.channels || []).map((c) => c.channel)
  step('1 hub channel list: defaults, no tasks, no issues', ch.status === 200 &&
    ['lobby', 'alerts', 'feedback'].every((d) => ids.includes(d)) && !ids.includes('tasks') && !ids.includes('issues'), { ids })

  // 2. the sidebar
  const rows = await until(() => p.$$eval('[data-testid="sidebar-panel-channels"] .nav-row', (els) => els.map((e) => e.getAttribute('data-order') || e.innerText.trim())).then((r) => r.length ? r : null), 20000) || []
  const text = await p.$eval('[data-testid="sidebar-panel-channels"]', (e) => e.innerText).catch(() => '')
  step('2 sidebar: no #tasks, no #issues', rows.includes('lobby') && !rows.includes('tasks') && !rows.includes('issues') &&
    !/(^|\s)#?tasks(\s|$)/m.test(text) && !/(^|\s)#?issues(\s|$)/m.test(text), { rows })
  await shot(p, '2-sidebar')

  // 3. an existing issue's discussion
  const list = await hub(p, '/v1/view/issues')
  const issues = list.body?.issues || []
  let pickKey = process.env.ISSUE || ''
  let topic = null
  const byNumber = issues.slice().sort((a, b) => a.number - b.number)
  for (const i of byNumber) {
    if (pickKey && i.key !== pickKey) continue
    const t = await hub(p, `/v1/view/topics/${i.task_id}`)
    const msgs = t.body?.messages || []
    if (msgs.length && Date.parse(msgs[0].received_at || msgs[0].ts) < Date.parse('2026-09-26T09:29:00Z')) {
      pickKey = i.key
      topic = { issue: i, msgs }
      break
    }
  }
  if (!topic) {
    step('3 an existing issue with a pre-move comment', false, { pickKey, issues: issues.length })
  } else {
    const chans = [...new Set(topic.msgs.map((m) => envOf(m).channel || ''))]
    await nav(p, `${BASE}/issues?issue=${encodeURIComponent(topic.issue.key)}`)
    const shown = await until(() => p.$$eval('[data-test=issues-comment]', (els) => els.length).then((n) => n >= topic.msgs.length ? n : 0), 20000)
    step('3 existing issue: every comment the hub holds is shown', shown >= topic.msgs.length && topic.issue.channel === 'issues',
      { key: topic.issue.key, hub_comments: topic.msgs.length, shown, signed_channels: chans, issue_channel: topic.issue.channel, msg_ids: topic.msgs.map(idOf) })
    await shot(p, '3-existing-issue')

    // 4. a new comment
    if (COMMENT) {
      const note = `SPL-68 proof comment ${Date.now().toString(36)}`
      await p.click('[data-test=issues-comment-input]')
      await p.type('[data-test=issues-comment-input]', note)
      await p.keyboard.press('Enter') /* SPL-973: Enter sends, there is no Comment button */
      const said = await until(() => p.$$eval('[data-test=issues-comment]', (els, n) => els.some((c) => c.innerText.includes(n)), note), 15000)
      const stored = await until(async () => {
        const t = await hub(p, `/v1/view/topics/${topic.issue.task_id}`)
        return (t.body?.messages || []).find((m) => String(envOf(m).msg?.body || '').includes(note)) || null
      }, 15000)
      step('4 a new comment shows and is signed into issues', !!said && envOf(stored || {}).channel === 'issues', { signed_channel: stored ? envOf(stored).channel : null, msg_id: stored ? idOf(stored) : '' })
      await shot(p, '4-comment')
    }
  }
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/tasks-gone-live.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAILED ${failed}` : 'ALL PASS')
process.exit(failed ? 1 : 0)
