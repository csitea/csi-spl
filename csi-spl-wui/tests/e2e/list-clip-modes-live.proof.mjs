// SPL-963 (owner 2026-09-26): "clicking on the titles, 5 rows and full does
// not work for all of the listings". Live proof, signed in, against a
// deployed WUI: for each list, click Titles / 5 rows / Full on that list's
// control and read what the list draws. Prints one table row per list.
//
//   BASE=https://<wui-host> EMAIL=<test member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [DM=<id@box>] [CHANNEL=<id>] [SEARCH=<query>] [CHROME_PATH=...] \
//     node tests/e2e/list-clip-modes-live.proof.mjs
//
// The password is read from PW_FILE and never printed. The browser profile
// lives in OUT/profile, so a rerun inside the login window reuses the session
// instead of spending one of the 10 sign-ins per 15 minutes.
// Exit 0 = every list that has rows switched on all three buttons. A list
// with no rows on that tenant is reported as `n/a`, never as a pass.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = process.env.EMAIL || readFileSync(need('EMAIL_FILE'), 'utf8').trim()
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const SEARCH = process.env.SEARCH || 'the'
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, lists: [], console: [] }

async function goto(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try { await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 }); return } catch (e) { last = e; await sleep(1500) }
  }
  throw last
}

/** What one list draws now. Runs in the page. */
const READ = (scope, kind) => {
  const root = document.querySelector(scope)
  if (!root) return { n: 0, missing: true }
  if (kind === 'cards') {
    const arts = [...root.querySelectorAll('article.msg')]
    return {
      n: arts.length,
      titles: arts.filter((a) => a.querySelector('[data-testid=card-title]')).length,
      clipped: arts.filter((a) => a.querySelector('[data-testid=card-body][data-clip]')).length,
      whole: arts.filter((a) => a.querySelector('[data-testid=card-body]:not([data-clip])')).length,
    }
  }
  if (kind === 'search') {
    const ps = [...root.querySelectorAll('[data-test=search-msg-snippet]')]
    const one = (el) => {
      const cs = getComputedStyle(el)
      return { lines: Math.round(el.getBoundingClientRect().height / parseFloat(cs.lineHeight)), nowrap: cs.whiteSpace === 'nowrap', clamp: cs.webkitLineClamp }
    }
    const all = ps.map(one)
    return {
      n: ps.length,
      titles: all.filter((x) => x.nowrap && x.lines <= 1).length,
      clipped: all.filter((x) => !x.nowrap && String(x.clamp) === '5').length,
      whole: all.filter((x) => !x.nowrap && String(x.clamp) === 'none').length,
    }
  }
  /* issue comments */
  const cs = [...root.querySelectorAll('[data-test=issues-comment]')]
  return {
    n: cs.length,
    titles: cs.filter((c) => c.querySelector('[data-test=issues-comment-title]')).length,
    clipped: cs.filter((c) => c.classList.contains('list-clip--rows') && c.querySelector('.issues-comment__body')).length,
    whole: cs.filter((c) => c.classList.contains('list-clip--full') && !c.querySelector('[data-test=issues-comment-title]')).length,
  }
}

async function modes(p, name, scope, kind, ctlSel) {
  const row = { list: name, titles: 'n/a', rows: 'n/a', full: 'n/a', n: 0 }
  const ctl = await p.$(ctlSel)
  if (!ctl) {
    row.titles = row.rows = row.full = 'NO CONTROL'
    res.lists.push(row)
    return row
  }
  for (const m of ['titles', 'rows', 'full']) {
    await p.click(`${ctlSel} [data-testid=card-clip-${m}]`)
    await sleep(700)
    const s = await p.evaluate(READ, scope, kind)
    row.n = s.n
    if (!s.n) continue
    const want = m === 'titles' ? s.titles : m === 'rows' ? s.clipped : s.whole
    row[m] = want === s.n ? 'PASS' : `FAIL ${want}/${s.n}`
    row[m + '_ev'] = s
  }
  await p.screenshot({ path: `${OUT}/${name.replace(/[^a-z0-9]+/gi, '-')}.png` })
  res.lists.push(row)
  return row
}

async function openThread(p) {
  const card = await p.$('[data-pane=msgs] article.msg .msg-time')
  if (!card) return false
  await card.click()
  return p.waitForSelector('aside[data-pane=topic] article.msg', { timeout: 15000 }).then(() => true, () => false)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 90000,
  userDataDir: `${OUT}/profile`,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))

  await goto(p, BASE + '/lobby?tenant=' + encodeURIComponent(TENANT))
  let signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 12000 }).then(() => true, () => false)
  if (!signedIn) {
    await goto(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  }
  if (!signedIn) throw new Error('not signed in (a 429 on /api/v1/auth/login is the login limit)')
  await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 20000 }).catch(() => {})
  await sleep(1500)

  const MID = '[data-pane=msgs] [data-testid=card-clip-control]'
  const THREAD = 'aside[data-pane=topic] [data-testid=card-clip-control][data-clip-pane=thread]'
  await modes(p, 'lobby', '[data-pane=msgs]', 'cards', MID)
  if (await openThread(p)) await modes(p, 'thread pane (root + replies)', 'aside[data-pane=topic]', 'cards', THREAD)
  else res.lists.push({ list: 'thread pane (root + replies)', titles: 'n/a', rows: 'n/a', full: 'n/a', n: 0 })

  /* the named one, else the first of the sidebar's that has rows */
  const links = (kind) => p.evaluate((k) => [...new Set([...document.querySelectorAll(`a[href*="/${k}/"]`)]
    .map((a) => decodeURIComponent(a.getAttribute('href').split(`/${k}/`)[1] || '')))]
    .filter((x) => x && x !== 'lobby'), kind)
  const chans = process.env.CHANNEL ? [process.env.CHANNEL] : await links('channel')
  const dms = process.env.DM ? [process.env.DM] : await links('dm')
  for (const [label, kind, names] of [['channel #', 'channel', chans], ['DM ', 'dm', dms]]) {
    let done = false
    for (const x of names.slice(0, 12)) {
      try { await goto(p, BASE + `/${kind}/` + encodeURIComponent(x)) } catch { continue }
      const has = await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 8000 }).then(() => true, () => false)
      if (!has) continue
      await sleep(1200)
      await modes(p, label + x, '[data-pane=msgs]', 'cards', MID)
      done = true
      break
    }
    if (!done) res.lists.push({ list: label.trim() + ' (none with rows)', titles: 'n/a', rows: 'n/a', full: 'n/a', n: 0 })
  }

  /* the /t page: a topic from the lobby */
  await goto(p, BASE + '/lobby')
  await p.waitForSelector('[data-pane=msgs] article.msg', { timeout: 20000 }).catch(() => {})
  const task = await p.evaluate(() => document.querySelector('[data-pane=msgs] article.msg')?.getAttribute('data-task-id') || '')
  if (task) {
    await goto(p, BASE + '/t/' + encodeURIComponent(task))
    await p.waitForSelector('[data-test=topic-root] article.msg', { timeout: 20000 }).catch(() => {})
    await sleep(1200)
    await modes(p, '/t page', '[data-test=topic-root]', 'cards', '.feed-header [data-testid=card-clip-control][data-clip-pane=thread]')
  }

  await goto(p, BASE + '/search?q=' + encodeURIComponent(SEARCH))
  await p.waitForSelector('[data-test=search-msg-snippet], [data-test=search-empty]', { timeout: 25000 }).catch(() => {})
  await sleep(800)
  await modes(p, 'search results', '[data-test=search-results]', 'search', '.feed-header [data-testid=card-clip-control]')

  await goto(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-row]', { timeout: 20000 }).catch(() => {})
  let issueDone = false
  const nIssues = await p.$$eval('[data-test=issues-row]', (xs) => xs.length)
  /* a click re-renders the list, so each row is looked up again by index */
  for (let i = 0; i < Math.min(nIssues, 25); i++) {
    await p.evaluate((k) => document.querySelectorAll('[data-test=issues-row]')[k]?.click(), i)
    await sleep(1500)
    if (await p.$('[data-test=issues-comment]')) {
      await modes(p, 'issue discussion', '[data-test=issues-talk]', 'issues', '[data-test=issues-talk] [data-testid=card-clip-control]')
      issueDone = true
      break
    }
  }
  if (!issueDone) res.lists.push({ list: 'issue discussion', titles: 'n/a', rows: 'n/a', full: 'n/a', n: 0 })

  /* leave the account on the default */
  await goto(p, BASE + '/lobby')
  await p.waitForSelector(MID, { timeout: 15000 }).then(() => p.click(`${MID} [data-testid=card-clip-rows]`)).catch(() => {})

  const fails = res.lists.filter((l) => [l.titles, l.rows, l.full].some((v) => v !== 'PASS' && v !== 'n/a'))
  console.log('| list | n | titles | 5 rows | full |')
  console.log('|---|---|---|---|---|')
  for (const l of res.lists) console.log(`| ${l.list} | ${l.n} | ${l.titles} | ${l.rows} | ${l.full} |`)
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(fails.length ? `FAILED ${fails.length}` : 'ALL PASS', 'pageerrors', res.console.length)
  process.exitCode = fails.length ? 1 : 0
} finally {
  await browser.close()
}
