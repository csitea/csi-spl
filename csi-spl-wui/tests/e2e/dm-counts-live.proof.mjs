// Live proof for DB payload cut 1 (owner t1 66233cdc, audit 2026-10-02): on a
// deployed WUI + hub, the DM rail badges seeded from the hub's own counts
// (`?dm=true&dm_counts=true`) read exactly what the old inline page gave
// (`?dm=true&per_topic=50`, counted in the browser by unreadFromDms /
// dmTotalsFromDms), peer by peer, and the seed read carries no message.
// Read-only: it signs in, reads, and types nothing.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [AUTH_BASE=https://<api host>] node tests/e2e/dm-counts-live.proof.mjs
//
// steps
//   seed      the page's DM seed asked dm_counts=true, sent no per_topic, and
//             got rows with `dm` counts and no `messages`
//   oracle    the same reader's per_topic=50 page, counted by the WUI's own
//             inline rules against the same localStorage cursors, gives the
//             same per-peer unread and total as the hub's rows
//   painted   every DM row on the rail shows the badge those counts give
//             ("<new>/<total>", or the plain total when nothing is new)
//   bytes     the seed response against the old page (JSON bytes)
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { dmTotalsFromDms, unreadFromDms } from '../../src/utils/channel-feed.mjs'
import { normalizeTopicRow, normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { dmBadgeText, dmTotalText } from '../../src/utils/notify.mjs'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} must be set`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/$/, '')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const results = []
const step = (name, pass, ev) => {
  results.push(pass)
  console.log(`  ${pass ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  const spec = process.env.PUPPETEER_CORE
  const href = spec ? pathToFileURL(spec).href : pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
}

/** the old seed's rows as spool-client listTopics({ perTopic }) shaped them */
const inlineRows = (data) => ((data && data.topics) || []).map((raw) => ({
  ...normalizeTopicRow(raw),
  inline: { messages: (raw.messages || []).map(normalizeViewMessage) },
}))

const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  let seed = null
  p.on('response', async (res) => {
    const u = res.url()
    if (seed || !u.includes('/v1/view/topics?') || !new URL(u).searchParams.get('dm')) return
    try { seed = { url: u, text: await res.text() } } catch { /* a redirect body */ }
  })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/lobby')}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('signed in', signed, { url: p.url() })
  const build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  console.log('  build.json ' + JSON.stringify(build))
  for (let i = 0; i < 60 && !seed; i++) await sleep(500)
  step('seed: the DM seed read happened', Boolean(seed), seed && { url: seed.url.replace(/dm_read=[^&]*/g, 'dm_read=…') })
  if (!seed) throw new Error('no DM seed read seen')

  const su = new URL(seed.url)
  const rows = JSON.parse(seed.text).topics || []
  step('seed: asks dm_counts=true and no per_topic', su.searchParams.get('dm_counts') === 'true' && su.searchParams.get('per_topic') === null,
    { dm_counts: su.searchParams.get('dm_counts'), per_topic: su.searchParams.get('per_topic'), dm_read: su.searchParams.getAll('dm_read').length })
  step('seed: every row carries dm counts and no messages', rows.length > 0 && rows.every((r) => r.dm && r.dm.unread && r.dm.total && !('messages' in r)),
    { rows: rows.length })

  await p.click('[data-testid=sidebar-tab-dm]').catch(() => {})
  await sleep(1500)
  const page = await p.evaluate(async (old) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    const self = (s && s.claims && s.claims.hum) || ''
    let cursors = {}
    try { cursors = JSON.parse(localStorage.getItem('spool.read-cursors') || '{}') } catch { /* */ }
    const res = await fetch(old, { credentials: 'include', headers: { accept: 'application/json' } })
    const text = await res.text()
    const badges = [...document.querySelectorAll('a.nav-item')].filter((e) => e.closest('[aria-labelledby=sidebar-tab-dm]'))
      .map((e) => ({ key: e.getAttribute('data-key'),
        badge: (e.querySelector('[data-test=dm-badge]') || {}).textContent?.trim() || '',
        total: (e.querySelector('[data-test=dm-total]') || {}).textContent?.trim() || '' }))
    return { self, cursors, status: res.status, text, badges }
  }, `${su.origin}/v1/view/topics?dm=true&limit=50&per_topic=50`)
  step('oracle: the old per_topic=50 page reads', page.status === 200 && Boolean(page.self), { status: page.status, self: page.self })

  const old = inlineRows(JSON.parse(page.text))
  const wantUnread = unreadFromDms(old, page.cursors, page.self)
  const wantTotal = dmTotalsFromDms(old, page.self)
  const hubRows = rows.map((r) => ({ ...normalizeTopicRow(r), dm: r.dm }))
  const gotUnread = unreadFromDms(hubRows, {}, page.self)
  const gotTotal = dmTotalsFromDms(hubRows, page.self)
  const same = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b).sort())
  step('oracle: per-peer unread, hub == the inline rules', same(gotUnread, wantUnread), { hub: gotUnread, inline: wantUnread })
  step('oracle: per-peer total, hub == the inline rules', same(gotTotal, wantTotal), { hub: gotTotal, inline: wantTotal })

  const bad = []
  for (const b of page.badges) {
    const k = `dm:${b.key}`
    const u = wantUnread[k] || 0
    const want = u ? { badge: dmBadgeText(u, wantTotal[k] || 0), total: '' } : { badge: '', total: dmTotalText(wantTotal[k] || 0) }
    if (b.badge !== want.badge || b.total !== want.total) bad.push({ key: b.key, got: b, want })
  }
  step('painted: every DM row shows the badge those counts give', page.badges.length > 0 && bad.length === 0,
    { rows: page.badges.length, withNew: page.badges.filter((b) => b.badge).length, mismatched: bad })
  step('bytes: the seed is smaller than the old page', seed.text.length < page.text.length,
    { seedJSON: seed.text.length, oldJSON: page.text.length })
  writeFileSync(join(OUT, 'dm-counts-live.json'), JSON.stringify({ base: BASE, build, seedBytes: seed.text.length, oldBytes: page.text.length,
    unread: gotUnread, total: gotTotal, badges: page.badges }, null, 2))
  await p.screenshot({ path: join(OUT, 'dm-counts-live.png') })
} finally {
  await browser.close()
}
const ok = results.length > 0 && results.every(Boolean)
console.log(ok ? `PASS ${results.length}/${results.length}` : `FAIL ${results.filter(Boolean).length}/${results.length}`)
process.exit(ok ? 0 : 1)
