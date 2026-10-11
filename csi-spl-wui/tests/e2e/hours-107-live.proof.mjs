// Spec 107 T018: the live proof of hours tracking (spec 9 acceptance), signed
// in, against a deployed WUI + hub, in a TEST workspace only (dev and prd: e2e).
//
// One member who is also the workspace's biz owner (the m3-e2e human of the
// e2e workspace). Steps, n = 1 per run:
//   seed     tab minutes on this week's Monday (a topic and a channel), a
//            meeting (kind other) on Monday, and a post today from the composer
//   line     /calendar at 1440 and 390, light and dark: Monday's Working hours
//            line shows GET /v1/me/hours's total; a click opens the dialog
//            (phone: the sheet) with the hub's rows, the topic as a link
//   approve  at 390: the line (tap 1), [Approve N days] (tap 2) approves every
//            closed day; today stays open until Approve so far
//   freeze   the week freezes: by the clock (no sweep row yet), then with the
//            sweep's row: read-only, no open suggestion, a minute write is 409
//   review   the biz owner returns the week with a note (Team tab), the member
//            resubmits, the biz owner approves
//   export   CSV and XLSX from the Download tab hold exactly the approved
//            lines, every one period_state = approved
//   privacy  the hours.read answer carries no raw minute nor a suggestion; a
//            reader of a second workspace (OTHER_*) is refused here and its
//            own export holds none of these lines (OTHER_ANY_ROLE=1: a
//            member there without hours.read, refused its own export too);
//            that context aborts every write: the second workspace is not a
//            test workspace
//   version  build.json and the sidebar footer show the deployed version
//
// The freeze: a live week freezes at end + hours.freeze_grace_days in
// hours.tz. FREEZE=tz (the default) sets grace 0 and hours.tz to UTC+14
// (Pacific/Kiritimati) on the test workspace, so the week holding today
// freezes now instead of in days; it works while it is already the next
// Monday in UTC+14, i.e. on a Sunday from 10:00Z. The settings are put back
// at the end. FREEZE=wait waits for the clock instead (FREEZE_WAIT_MIN).
//
//   BASE=https://<test tenant host> TENANT=e2e EMAIL=<member> PW_FILE=<0600>
//   OTHER_BASE=https://<second workspace host> OTHER_TENANT=<its id>
//   OTHER_EMAIL=<reader there>
//   OTHER_PW_FILE=<0600> [OTHER_ANY_ROLE=1] OUT=<dir> [FREEZE=tz|wait] [SWEEP_WAIT_MIN=25] [TAIL=1]
//   [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/hours-107-live.proof.mjs
//
// Refuses to write unless the session's tenant claim AND the page host's
// tenant are TENANT. Passwords are read from the files and never printed.
// Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { inflateRawSync } from 'node:zlib'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 'e2e'
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const OTHER_BASE = need('OTHER_BASE').replace(/\/+$/, '')
const OTHER_TENANT = need('OTHER_TENANT')
const OTHER_EMAIL = need('OTHER_EMAIL')
const OTHER_PW = readFileSync(need('OTHER_PW_FILE'), 'utf8').trim()
const OTHER_ANY_ROLE = process.env.OTHER_ANY_ROLE === '1' /* prd: no test login holds hours.read in a second workspace */
const FREEZE = process.env.FREEZE || 'tz'
const TAIL = process.env.TAIL === '1' /* only the read-only steps after the approval, on a week already done */
const SWEEP_WAIT_MS = Number(process.env.SWEEP_WAIT_MIN || 25) * 60000
const FREEZE_TZ = 'Pacific/Kiritimati'
const NOTE = 'T018 proof: please split Monday by topic'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, tenant: TENANT, other: OTHER_BASE, freeze: FREEZE, at: new Date().toISOString(), recorder_flushes_blocked: 0, other_writes_blocked: [], steps: [], console: [] }
let ownMinutes = false
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok: Boolean(ok), ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev).slice(0, 600)) }
const save = () => writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))

const iso = (d) => d.toISOString().slice(0, 10)
const addDays = (day, n) => iso(new Date(Date.parse(day + 'T00:00:00Z') + n * 86400000))
const TODAY = iso(new Date())
const MON = addDays(TODAY, -((new Date(TODAY + 'T00:00:00Z').getUTCDay() + 6) % 7))
const hhmm = (m) => `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`
const DLG = '[data-test=calendar-event-form][data-mode=hours]'
const SHEET = '[data-test=calphone-sheet][data-mode=hours]'
const PHONE = '[data-test=calendar-phone] [data-test=calphone-page][data-dir="0"]'
const line = (root, day) => `${root} [data-test=calendar-hours-line][data-day="${day}"]`.trim()

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })

/** a page in ctx, UTC (the recorder's zone), the theme pinned */
async function page(ctx, { vp, theme, hum, readOnly }) {
  const p = await ctx.newPage()
  await p.emulateTimezone('UTC')
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
  await p.evaluateOnNewDocument((t, h) => {
    try {
      localStorage.setItem('spool-theme', t)
      localStorage.setItem('spool-calendar-phone-view', 'day')
      if (h) sessionStorage.setItem('csi-spl-pref-theme-applied', h) /* the account's theme does not win */
    } catch { /* about:blank */ }
  }, theme, hum || '')
  await p.setViewport(vp.width < 800 ? { ...vp, isMobile: true, hasTouch: true } : vp)
  /* the T012 recorder's own flushes would move the week's total under the
     proof (and the sweep approves open suggestions): only the proof's calls
     write minutes */
  await p.setRequestInterception(true)
  p.on('request', (r) => {
    if (r.method() === 'PUT' && /\/v1\/me\/hours\/minutes(\?|$)/.test(r.url()) && !ownMinutes) { res.recorder_flushes_blocked++; r.abort().catch(() => {}); return }
    /* the second workspace is not a test workspace: its reader only reads */
    if (readOnly && !['GET', 'HEAD', 'OPTIONS'].includes(r.method()) && !/\/api\/v1\/auth\//.test(r.url())) { res.other_writes_blocked.push(`${r.method()} ${r.url().replace(/\?.*$/, '')}`); r.abort().catch(() => {}); return }
    r.continue().catch(() => {})
  })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 200)) })
  return p
}

async function nav(p, url) {
  for (let i = 0; i < 4; i++) {
    try { await p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 }); return } catch (e) { if (i === 3) throw e; await sleep(3000) }
  }
}

/** a hub call from the page (cookie session, the page host's tenant) */
async function call(p, api, method, path, body) {
  ownMinutes = /\/v1\/me\/hours\/minutes/.test(path)
  try { return await callRaw(p, api, method, path, body) } finally { ownMinutes = false }
}
function callRaw(p, api, method, path, body) {
  return p.evaluate(async (a, m, u, b) => {
    try {
      const r = await fetch(a + u, { method: m, credentials: 'include', headers: b ? { 'content-type': 'application/json' } : {}, body: b ? JSON.stringify(b) : undefined })
      const text = await r.text()
      let json = null
      try { json = JSON.parse(text) } catch { /* not json */ }
      return { status: r.status, body: json, text: json ? '' : text.slice(0, 4000), type: r.headers.get('content-type') || '' }
    } catch (e) { return { status: 0, body: null, text: String(e) } }
  }, api, method, path, body || null)
}

/** sign in through the WUI form; the hub origin and the claims */
async function signIn(p, base, tenant, email, pw) {
  let api = ''
  p.on('request', (r) => { const m = r.url().match(/^(https:\/\/[^/]+)\/v1\//); if (m && !api) api = m[1] })
  await nav(p, `${base}/login?tenant=${encodeURIComponent(tenant)}&redirect=${encodeURIComponent('/calendar')}`)
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 30000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.startsWith('/login'), { timeout: 30000 }).catch(() => null)
  for (let i = 0; i < 40 && !api; i++) await sleep(250)
  const claims = api ? await call(p, api, 'GET', '/api/v1/auth/session') : { status: 0 }
  return { api, claims: claims.body || {} }
}

const shot = (p, name) => p.screenshot({ path: join(OUT, `${name}.png`) }).catch(() => {})
const myHours = async (p, api, day) => (await call(p, api, 'GET', `/v1/me/hours?period=${day}`)).body
const dayOf = (h, day) => (h?.days || []).find((d) => d.date === day)
const dayTotal = (d) => (d ? d.suggested_minutes + d.approved_minutes : 0)

/** open the desktop calendar on day, the hours panel shown */
async function desktop(p, day) {
  await nav(p, `${BASE}/calendar?d=${day}`)
  await p.waitForSelector(line('', day), { visible: true, timeout: 20000 }).catch(() => null)
  if (!(await p.$('[data-test=hours-panel]'))) await p.click('[data-test=calendar-hours-toggle]').catch(() => {})
  await p.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-mine]', { visible: true, timeout: 15000 }).catch(() => null)
  await sleep(800)
}

/** the line's total, then its dialog (desktop) or sheet (phone): rows + link */
async function openLine(p, root, form, day, want) {
  await p.waitForFunction((s, w) => document.querySelector(s)?.getAttribute('data-total') === String(w), { timeout: 15000 }, line(root, day), want).catch(() => {})
  const ln = await p.$eval(line(root, day), (el) => ({ total: el.getAttribute('data-total'), state: el.getAttribute('data-state'), text: el.textContent.replace(/\s+/g, ' ').trim() })).catch(() => null)
  await p.$eval(line(root, day), (el) => el.scrollIntoView({ block: 'center' })).catch(() => {})
  await p.click(line(root, day)).catch(() => {})
  await p.waitForSelector(`${form} [data-test=hours-day-row]`, { visible: true, timeout: 15000 }).catch(() => null)
  await sleep(500)
  const body = await p.evaluate((f) => {
    const s = document.querySelector(f)
    return {
      rows: [...(s?.querySelectorAll('[data-test=hours-day-row]') || [])].map((r) => `${r.getAttribute('data-target')}:${r.getAttribute('data-minutes')}:${r.getAttribute('data-row-state')}`).sort(),
      link: s?.querySelector('[data-test=hours-day-link]')?.getAttribute('href') || '',
      total: s?.querySelector('[data-test=hours-day-total] strong')?.textContent?.trim() || '',
      frozen: Boolean(s?.querySelector('[data-test=hours-day-frozen], [data-test=hours-day-final]')),
      edits: s ? s.querySelectorAll('[data-test=hours-row-min], [data-test=hours-row-reject], [data-test=hours-add], [data-test=hours-approve-week], [data-test=hours-approve-open], [data-test=hours-approve-today], [data-test=hours-approve-day]').length : -1,
    }
  }, form)
  return { line: ln, ...body }
}

async function closeDialog(p, phone) {
  if (phone) await p.click(`${SHEET} [data-test=calphone-sheet-cancel]`).catch(() => p.keyboard.press('Escape'))
  else await p.click('[data-test=calendar-hours-close]').catch(() => p.keyboard.press('Escape'))
  await sleep(500)
}

const apiRows = (d) => (d?.rows || []).filter((r) => r.state !== 'rejected').map((r) => `${r.target}:${r.minutes}:${r.state}`).sort()

/* ---- CSV / XLSX readers ---- */
function csvRows(text) {
  const rows = []
  let row = [], cell = '', q = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++ } else if (c === '"') q = false; else cell += c; continue }
    if (c === '"') q = true
    else if (c === ',') { row.push(cell); cell = '' } else if (c === '\n') { row.push(cell.replace(/\r$/, '')); rows.push(row); row = []; cell = '' } else cell += c
  }
  if (cell || row.length) { row.push(cell); rows.push(row) }
  return rows.filter((r) => r.some((c) => c !== ''))
}
function unzip(buf) {
  const files = {}
  let eocd = buf.length - 22
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--
  let off = buf.readUInt32LE(eocd + 16)
  for (let i = 0; i < buf.readUInt16LE(eocd + 10); i++) {
    const method = buf.readUInt16LE(off + 10), size = buf.readUInt32LE(off + 20), nlen = buf.readUInt16LE(off + 28)
    const name = buf.toString('utf8', off + 46, off + 46 + nlen)
    const local = buf.readUInt32LE(off + 42)
    const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28)
    const raw = buf.subarray(start, start + size)
    files[name] = method === 8 ? inflateRawSync(raw) : raw
    off += 46 + nlen + buf.readUInt16LE(off + 30) + buf.readUInt16LE(off + 32)
  }
  return files
}
const xmlText = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&')
function xlsxRows(buf) {
  const files = unzip(buf)
  const sheet = files['xl/worksheets/sheet1.xml']?.toString('utf8') || ''
  const rows = [...sheet.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)].map((m) => [...m[1].matchAll(/<c\b[^>]*>([\s\S]*?)<\/c>/g)].map((c) => {
    const t = c[1].match(/<t[^>]*>([\s\S]*?)<\/t>/)
    return xmlText(t ? t[1] : (c[1].match(/<v>([\s\S]*?)<\/v>/)?.[1] || ''))
  }))
  return { parts: Object.keys(files).sort(), sheets: Object.keys(files).filter((n) => n.startsWith('xl/worksheets/')).length, rows }
}

/** the Download tab: the bytes it fetched from the export (what it hands
    the browser as the file), saved into OUT and read back */
async function download(p, format) {
  await p.click('[data-test=hours-panel] [data-test=hours-panel-tab-download]').catch(() => {})
  await p.waitForSelector('[data-test=hours-dl-day]', { visible: true, timeout: 10000 }).catch(() => null)
  await p.$eval('[data-test=hours-dl-day]', (el, d) => { el.value = d; el.dispatchEvent(new Event('input', { bubbles: true })) }, MON).catch(() => {})
  await p.click(`[data-test=hours-dl-format-${format}]`).catch(() => {})
  const fin = await p.$eval('[data-test=hours-dl-final]', (el) => el.checked).catch(() => false)
  if (!fin) await p.click('[data-test=hours-dl-final]').catch(() => {})
  const got = p.waitForResponse((r) => r.request().method() === 'GET' && /\/v1\/hours\/export\?/.test(r.url()), { timeout: 20000 })
    .then((r) => ({ origin: r.url().match(/^https:\/\/[^/]+/)[0], url: r.url().replace(/^https:\/\/[^/]+/, ''), status: r.status(), headers: r.headers() }), () => null)
  await p.click('[data-test=hours-dl-go]').catch(() => {})
  const resp = await got
  /* the same request again from the page: its body (an intercepted
     response's body is not kept by the browser) */
  if (resp) resp.buf = Buffer.from(await p.evaluate(async (u) => {
    const r = await fetch(u, { credentials: 'include' })
    const b = new Uint8Array(await r.arrayBuffer())
    let bin = ''
    for (const x of b) bin += String.fromCharCode(x)
    return btoa(bin)
  }, resp.origin + resp.url).catch(() => ''), 'base64')
  const done = await p.waitForFunction((f) => {
    const e = document.querySelector('[data-test=hours-dl-done]')
    return e && e.getAttribute('data-name')?.endsWith('.' + f) ? { name: e.getAttribute('data-name'), type: e.getAttribute('data-type'), bytes: Number(e.getAttribute('data-bytes')), lines: Number(e.getAttribute('data-lines')) } : null
  }, { timeout: 20000 }, format).then((h) => h.jsonValue(), () => null)
  const name = (resp?.headers['content-disposition'] || '').match(/filename="([^"]+)"/)?.[1] || done?.name || `hours.${format}`
  const file = resp?.buf ? join(OUT, name) : ''
  if (file) writeFileSync(file, resp.buf)
  return { done, file, buf: resp?.status === 200 && resp.buf?.length ? resp.buf : null, http: resp && { url: resp.url, status: resp.status, type: resp.headers['content-type'], disposition: resp.headers['content-disposition'] || '' } }
}

/** put the test workspace's grace and hours.tz back to the values read
    before the change, then read them back; once, from finally or a signal */
let restored = false
async function restore() {
  if (restored || !freezeSet || !pA || !A) return
  restored = true
  const back = await call(pA, A.api, 'PATCH', '/v1/tenant/settings', { settings: freezeSet })
  const now = ((await call(pA, A.api, 'GET', '/v1/tenant/settings')).body || {}).settings || {}
  const same = Object.keys(freezeSet).every((k) => now[k] === freezeSet[k])
  step('the test workspace\'s grace and hours.tz are put back (read back)', back.status === 200 && same,
    { status: back.status, read_back: { 'hours.freeze_grace_days': now['hours.freeze_grace_days'], 'hours.tz': now['hours.tz'] }, recorded: freezeSet })
  if (!same) console.error('RESTORE FAILED: the test workspace keeps grace / hours.tz', JSON.stringify(now))
}
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, async () => {
    step(`killed by ${sig}`, false)
    try { await restore() } finally { save(); await browser.close().catch(() => {}); process.exit(1) }
  })
}

const hostTenant = (base) => new URL(base).hostname.split('.')[0]
let freezeSet = null
let pA = null, A = null

try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  if (hostTenant(BASE) !== TENANT) throw new Error(`BASE host ${new URL(BASE).hostname} is not the ${TENANT} workspace's host`)

  /* ---- sign in: the member (and biz owner) of TENANT ---- */
  const ctxA = await browser.createBrowserContext()
  pA = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'light' })
  A = await signIn(pA, BASE, TENANT, EMAIL, PW)
  const hum = A.claims.hum || ''
  step('member signs in on the test workspace', A.claims.t === TENANT && hum && A.api, { t: A.claims.t, hum, api: A.api })
  if (A.claims.t !== TENANT) throw new Error('refusing to write: the session is not in ' + TENANT)
  const me = (await call(pA, A.api, 'GET', '/v1/view/me')).body || {}
  step('the member holds hours.read and hours.approve here (biz owner)', me.tenant_id === TENANT && (me.permissions || []).includes('hours.read') && (me.permissions || []).includes('hours.approve'), { role: me.role, tenant: me.tenant_id })
  if (me.tenant_id !== TENANT) throw new Error('refusing to write: the page host tenant is ' + me.tenant_id)

  let needle = '', tTopic = ''
  if (TAIL) {
    /* re-check the read-only tail on a week an earlier run approved */
    const h = await myHours(pA, A.api, MON)
    tTopic = (dayOf(h, MON)?.rows || []).map((r) => r.target).find((t) => t.startsWith('t:')) || ''
    step('TAIL: the week an earlier run left is approved', h?.period?.state === 'approved' && tTopic, { period: h?.period, topic: tTopic })
    needle = 'T018 hours proof post'
  } else {
    /* ---- the week must be fresh: nothing approved, no period row ---- */
    const before = await myHours(pA, A.api, MON)
    const fresh = before?.period?.state === 'open' && (before?.days || []).every((d) => d.approved_minutes === 0 && !d.rows.some((r) => r.state !== 'suggested'))
    step(`the week ${MON}..${before?.period?.end} is open and has no entries yet`, fresh, { period: before?.period })
    if (!fresh) throw new Error('the week was used by an earlier run: hours rows cannot be deleted, run it next week')
    const settings0 = ((await call(pA, A.api, 'GET', '/v1/tenant/settings')).body || {}).settings || {}
    res.settings_before = settings0

    /* ---- seed: a post today (composer), tab minutes and a meeting on Monday ---- */
    const pPost = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'light', hum })
    await nav(pPost, `${BASE}/lobby`)
    const ta = await pPost.waitForSelector('form.composer textarea', { visible: true, timeout: 20000 }).catch(() => null)
    needle = `T018 hours proof post ${Date.now().toString(36)}`
    if (ta) { await ta.focus(); await pPost.keyboard.type(needle); await pPost.keyboard.press('Enter') }
    const posted = await pPost.waitForFunction((n) => [...document.querySelectorAll('.msg-body')].some((e) => e.textContent.includes(n)), { timeout: 20000 }, needle).then(() => true, () => false)
    await shot(pPost, '0-seed-post-1440-light')
    await pPost.close()
    /* the post's topic, then today's suggestion covers the post's minute (a
       day under 5 min folds every target into "ws", spec 1.3) */
    let post = null
    for (let i = 0; i < 20 && !post; i++) {
      post = ((await call(pA, A.api, 'GET', '/v1/view/topics?limit=20')).body?.topics || []).find((t) => t.subject === needle) || null
      if (!post) await sleep(1500)
    }
    const postMin = post ? Date.parse(post.first_ts) - (Date.parse(post.first_ts) % 60000) : 0
    const td = dayOf(await myHours(pA, A.api, TODAY), TODAY)
    const covered = (td?.rows || []).some((r) => r.blocks.some((b) => Date.parse(b.start) <= postMin && postMin < Date.parse(b.end)))
    step('a post from the composer today lands, and today\'s suggestion covers its minute', posted && post && covered, { needle, topic: post?.task_id, at: post?.first_ts, today: apiRows(td) })
    if (!post) throw new Error('the post did not land: no topic to book Monday on')
    tTopic = `t:${post.task_id}`
    const mins = []
    for (let m = 0; m < 20; m++) mins.push({ at: `${MON}T09:${String(m).padStart(2, '0')}:00Z`, target: tTopic })
    for (let m = 0; m < 10; m++) mins.push({ at: `${MON}T11:${String(m).padStart(2, '0')}:00Z`, target: 'ch:lobby' })
    const put = await call(pA, A.api, 'PUT', '/v1/me/hours/minutes', { tz: 'UTC', minutes: mins })
    step('Monday tab minutes are stored (20 on the topic, 10 on #lobby)', put.status === 200 && put.body?.stored === 30, { status: put.status, body: put.body })
    const ev = await call(pA, A.api, 'POST', '/v1/calendar/events', { title: 'T018 proof meeting', kind: 'other', starts_at: `${MON}T10:00:00Z`, ends_at: `${MON}T10:45:00Z` })
    step('a 45-minute meeting (kind other) on Monday is created', ev.status >= 200 && ev.status < 300, { status: ev.status, body: ev.body?.error ? ev.body : undefined })
    const seeded = await myHours(pA, A.api, MON)
    const mon = dayOf(seeded, MON)
    const kinds = (mon?.rows || []).map((r) => r.target)
    step('GET /v1/me/hours suggests Monday from the topic, the meeting and the channel', kinds.includes(tTopic) && kinds.some((k) => k.startsWith('cal:')) && kinds.some((k) => k.startsWith('ch:') || k === 'ws'), { rows: apiRows(mon), total: dayTotal(mon) })
    res.monday = { rows: apiRows(mon), total: dayTotal(mon) }

    /* ---- line + dialog at 1440 and 390, light and dark (read only) ---- */
    for (const theme of ['light', 'dark']) {
      const p = await page(ctxA, { vp: { width: 1440, height: 900 }, theme, hum })
      await desktop(p, MON)
      const got = await openLine(p, '', DLG, MON, dayTotal(mon))
      step(`1440 ${theme}: Monday's Working hours line shows ${hhmm(dayTotal(mon))}; its dialog has the hub's rows and a topic link`,
        got.line?.total === String(dayTotal(mon)) && got.total === hhmm(dayTotal(mon)) && got.rows.join() === apiRows(mon).join() && /\/t\//.test(got.link),
        { line: got.line, rows: got.rows, total: got.total, link: got.link })
      await shot(p, `1-monday-dialog-1440-${theme}`)
      await closeDialog(p, false)
      const panel = await p.$$eval('[data-test=hours-panel] [data-test=hours-panel-day]', (els) => els.map((e) => `${e.getAttribute('data-day')}:${e.getAttribute('data-total')}`)).catch(() => [])
      step(`1440 ${theme}: the hours panel (Mine) lists Monday with its total`, panel.includes(`${MON}:${dayTotal(mon)}`), { panel })
      await shot(p, `1-panel-1440-${theme}`)
      await p.close()
    }
    for (const theme of ['light', 'dark']) {
      const p = await page(ctxA, { vp: { width: 390, height: 844 }, theme, hum })
      await nav(p, `${BASE}/calendar?d=${MON}`)
      await p.waitForSelector(line(PHONE, MON), { visible: true, timeout: 20000 }).catch(() => null)
      const got = await openLine(p, PHONE, SHEET, MON, dayTotal(mon))
      const wide = await p.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)
      step(`390 ${theme}: Monday's line shows ${hhmm(dayTotal(mon))}; the sheet has the hub's rows; no sideways scroll`,
        got.line?.total === String(dayTotal(mon)) && got.rows.join() === apiRows(mon).join() && wide, { line: got.line, rows: got.rows, wide })
      await shot(p, `1-monday-sheet-390-${theme}`)
      await p.close()
    }
    if (process.env.STOP === 'look') throw new Error('STOP=look: read-only steps done')

    /* ---- approve the closed days in 2 taps at 390 ---- */
    const pPh = await page(ctxA, { vp: { width: 390, height: 844 }, theme: 'light', hum })
    await nav(pPh, `${BASE}/calendar?d=${MON}`)
    await pPh.waitForSelector(line(PHONE, MON), { visible: true, timeout: 20000 }).catch(() => null)
    await pPh.tap(line(PHONE, MON)).catch(() => pPh.click(line(PHONE, MON)))
    const openBtn = await pPh.waitForSelector(`${SHEET} [data-test=hours-approve-open]`, { visible: true, timeout: 15000 }).catch(() => null)
    const nOpen = openBtn ? await openBtn.evaluate((b) => b.textContent.trim()) : ''
    await sleep(800) /* the sheet's open transition */
    await shot(pPh, '2-approve-before-390-light')
    const putSeen = pPh.waitForResponse((r) => r.request().method() === 'PUT' && /\/v1\/me\/hours(\?|$)/.test(r.url()), { timeout: 15000 }).then((r) => r.status(), () => 0)
    if (openBtn) await pPh.tap(`${SHEET} [data-test=hours-approve-open]`).catch(() => openBtn.click())
    const putStatus = await putSeen
    await pPh.waitForFunction((s) => document.querySelector(`${s} [data-test=hours-day-banner]`)?.getAttribute('data-open') === '0' || !document.querySelector(`${s} [data-test=hours-approve-open]`), { timeout: 15000 }, SHEET).catch(() => {})
    await sleep(1000)
    await shot(pPh, '2-approve-after-390-light')
    const after = await myHours(pA, A.api, MON)
    const closed = (after?.days || []).filter((d) => d.closed)
    const t0 = dayOf(after, TODAY)
    step('2 taps (the line, then Approve N days) approve every closed day', Boolean(openBtn) && closed.every((d) => d.open === 0 && d.suggested_minutes === 0) && dayOf(after, MON)?.approved_minutes === dayTotal(mon),
      { button: nOpen, put: putStatus, monday: dayOf(after, MON)?.approved_minutes, closedOpen: closed.map((d) => d.open) })
    step('today stays open (its post minute is still a suggestion)', t0 && t0.open > 0 && t0.suggested_minutes > 0, { today: t0 && { open: t0.open, suggested: t0.suggested_minutes } })
    await closeDialog(pPh, true)
    await pPh.close()

    /* ---- Approve so far, today, at 1440 ---- */
    const pT = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'light', hum })
    await desktop(pT, TODAY)
    await pT.click(line('', TODAY)).catch(() => {})
    const sofar = await pT.waitForSelector(`${DLG} [data-test=hours-approve-today]`, { visible: true, timeout: 15000 }).catch(() => null)
    await shot(pT, '3-today-open-1440-light')
    if (sofar) await sofar.click()
    await sleep(2500)
    const t1 = dayOf(await myHours(pA, A.api, TODAY), TODAY)
    step('Approve so far approves today', Boolean(sofar) && t1?.approved_minutes > 0 && t1?.suggested_minutes === 0, { today: t1 && { approved: t1.approved_minutes, open: t1.open } })
    await shot(pT, '3-today-approved-1440-light')
    await closeDialog(pT, false)
    await pT.close()
    const approved = await myHours(pA, A.api, MON)
    const weekMinutes = (approved?.days || []).reduce((s, d) => s + d.approved_minutes, 0)
    res.week_minutes = weekMinutes

    /* ---- the freeze ---- */
    if (FREEZE === 'tz') {
      const pre = ((await call(pA, A.api, 'GET', '/v1/tenant/settings')).body || {}).settings || {}
      if (pre['hours.freeze_grace_days'] === undefined || pre['hours.tz'] === undefined) throw new Error('cannot read hours.freeze_grace_days / hours.tz before the change')
      freezeSet = { 'hours.freeze_grace_days': pre['hours.freeze_grace_days'], 'hours.tz': pre['hours.tz'] }
      res.settings_recorded = freezeSet
      const pt = await call(pA, A.api, 'PATCH', '/v1/tenant/settings', { settings: { 'hours.freeze_grace_days': 0, 'hours.tz': FREEZE_TZ } })
      step(`the test workspace freezes now: grace 0, hours.tz ${FREEZE_TZ}`, pt.status === 200, { status: pt.status, body: pt.status === 200 ? undefined : pt.body })
    } else {
      const at = Date.parse(approved?.period?.freezes_at || '')
      const wait = Number(process.env.FREEZE_WAIT_MIN || 0) * 60000
      if (at - Date.now() > wait) throw new Error(`the week freezes at ${approved?.period?.freezes_at}, past FREEZE_WAIT_MIN`)
      while (Date.now() < at + 5000) await sleep(10000)
    }
    const fz = await myHours(pA, A.api, MON)
    const team0 = (await call(pA, A.api, 'GET', `/v1/hours?period=${MON}`)).body
    const rowNow = (team0?.members || []).find((m) => m.member_id === hum)
    const noRow = !(fz?.period?.minutes > 0)
    step('frozen by the clock: every day frozen, no open suggestion', fz?.period?.state === 'frozen' && (fz?.days || []).every((d) => d.frozen && d.open === 0 && d.suggested_minutes === 0), { period: fz?.period, sweepRow: !noRow })
    const w1 = await call(pA, A.api, 'PUT', '/v1/me/hours/minutes', { tz: 'UTC', minutes: [{ at: `${MON}T15:00:00Z`, target: tTopic }] })
    const w2 = await call(pA, A.api, 'PUT', '/v1/me/hours', { entries: [{ day: MON, target: 'ch:lobby', minutes: 60, state: 'approved' }] })
    step('frozen: a minute and an entry write are 409 period_frozen', w1.status === 409 && w1.body?.error === 'period_frozen' && w2.status === 409 && w2.body?.error === 'period_frozen', { minutes: w1.status, entries: w2.status })
    if (noRow) {
      const early = await call(pA, A.api, 'PUT', '/v1/hours/periods', { period: MON, action: 'approve', members: [hum] })
      step('without the sweep row: the team sees it frozen; a decision waits for the row (409)', rowNow?.state === 'frozen' && early.status === 409, { team: rowNow?.state, decide: early.status })
    } else step('without the sweep row: not observed, the sweep had already run', false, { period: fz?.period })
    const pF = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'dark', hum })
    await desktop(pF, MON)
    const ro = await openLine(pF, '', DLG, MON, dayTotal(mon))
    step('1440: the frozen week is read-only in the dialog (a lock, no edit or approve control)', ro.frozen && ro.edits === 0, { frozen: ro.frozen, edits: ro.edits })
    await shot(pF, '4-frozen-clock-1440-dark')
    await closeDialog(pF, false)
    await pF.close()

    let row = null
    for (const end = Date.now() + SWEEP_WAIT_MS; Date.now() < end;) {
      const h = await myHours(pA, A.api, MON)
      if (h?.period?.minutes > 0) { row = h.period; break }
      await sleep(30000)
    }
    step('the sweep writes the frozen row (period minutes = the approved week)', row && row.state === 'frozen' && row.minutes === weekMinutes, { row, weekMinutes })
    const fz2 = await myHours(pA, A.api, MON)
    step('with the sweep row: still read-only, no open suggestion', (fz2?.days || []).every((d) => d.frozen && d.open === 0), { period: fz2?.period })
    const pF2 = await page(ctxA, { vp: { width: 390, height: 844 }, theme: 'light', hum })
    await nav(pF2, `${BASE}/calendar?d=${MON}`)
    await pF2.waitForSelector(line(PHONE, MON), { visible: true, timeout: 20000 }).catch(() => null)
    const ro2 = await openLine(pF2, PHONE, SHEET, MON, dayTotal(mon))
    step('390: the frozen week is read-only in the sheet', ro2.frozen && ro2.edits === 0, { frozen: ro2.frozen, edits: ro2.edits })
    await shot(pF2, '4-frozen-swept-390-light')
    await pF2.close()

    /* ---- the biz owner returns it, the member resubmits, the biz owner approves ---- */
    const pB = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'light', hum })
    await desktop(pB, MON)
    await pB.click('[data-test=hours-panel] [data-test=hours-panel-tab-team]').catch(() => {})
    await pB.waitForSelector(`[data-test=hours-team][data-state=ready] [data-test=hours-team-row][data-member="${hum}"]`, { visible: true, timeout: 15000 }).catch(() => null)
    await shot(pB, '5-team-frozen-1440-light')
    await pB.click(`[data-test=hours-team-return][data-member="${hum}"]`).catch(() => {})
    await pB.waitForSelector('[data-test=hours-team-note]', { visible: true, timeout: 10000 }).catch(() => null)
    await pB.type('[data-test=hours-team-note]', NOTE).catch(() => {})
    await pB.click('[data-test=hours-team-return-send]').catch(() => {})
    const returned = await pB.waitForFunction((h) => document.querySelector(`[data-test=hours-team-row][data-member="${h}"]`)?.getAttribute('data-state') === 'returned', { timeout: 15000 }, hum).then(() => true, () => false)
    const r1 = await myHours(pA, A.api, MON)
    step('the biz owner returns the week with a note (Team tab)', returned && r1?.period?.state === 'returned' && r1?.period?.note === NOTE, { period: r1?.period })
    await shot(pB, '5-team-returned-1440-light')
    await pB.close()
    const pM = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'dark', hum })
    await desktop(pM, MON)
    const note = await pM.waitForSelector('[data-test=hours-panel] [data-test=hours-panel-returned]', { visible: true, timeout: 15000 }).then((el) => el.evaluate((e) => e.textContent.trim()), () => '')
    await shot(pM, '6-member-returned-1440-dark')
    await pM.click('[data-test=hours-panel-resubmit]').catch(() => {})
    await sleep(2500)
    const r2 = await myHours(pA, A.api, MON)
    step('the member sees the note and resubmits: the week is frozen again', note.includes(NOTE) && r2?.period?.state === 'frozen', { note, period: r2?.period })
    await shot(pM, '6-member-resubmitted-1440-dark')
    await pM.close()
    const pB2 = await page(ctxA, { vp: { width: 390, height: 844 }, theme: 'dark', hum })
    await nav(pB2, `${BASE}/calendar?d=${MON}`)
    await pB2.click('[data-test=calendar-phone] [data-test=calphone-menu]').catch(() => {})
    await pB2.waitForSelector('[data-test=calphone-menu-hours]', { visible: true, timeout: 10000 }).then((el) => el.click(), () => null)
    await pB2.waitForSelector('[data-test=calphone-hours-sheet] [data-test=hours-panel-tab-team]', { visible: true, timeout: 15000 }).then((el) => el.click(), () => null)
    const ap = `[data-test=calphone-hours-sheet] [data-test=hours-team-approve][data-member="${hum}"]`
    await pB2.waitForSelector(ap, { visible: true, timeout: 15000 }).catch(() => null)
    await shot(pB2, '7-team-frozen-390-dark')
    await pB2.tap(ap).catch(() => pB2.click(ap).catch(() => {}))
    const fin = await pB2.waitForFunction((h) => document.querySelector(`[data-test=calphone-hours-sheet] [data-test=hours-team-row][data-member="${h}"]`)?.getAttribute('data-state') === 'approved', { timeout: 15000 }, hum).then(() => true, () => false)
    const r3 = await myHours(pA, A.api, MON)
    step('390: the biz owner approves the resubmitted week (Team, phone)', fin && r3?.period?.state === 'approved', { period: r3?.period })
    await shot(pB2, '7-team-approved-390-dark')
    await pB2.close()
  }

  /* ---- the hours.read answer: approved entries only, never a raw minute ---- */
  const team = await call(pA, A.api, 'GET', `/v1/hours?period=${MON}`)
  const raw = JSON.stringify(team.body || {})
  const entries = (team.body?.entries || []).filter((e) => e.member_id === hum)
  step('GET /v1/hours (hours.read) carries no raw minute, block or suggestion', team.status === 200 && !/"(at|src|blocks)"\s*:/.test(raw) && !/"suggested"/.test(raw), { entries: entries.length })
  /* the export's target_id: the target without its kind; "other" (ws) has none */
  const want = entries.map((e) => `${e.day}|${e.target === 'ws' ? '' : e.target.replace(/^[a-z]+:/, '')}|${e.minutes}`).sort()

  /* ---- CSV and XLSX from the Download tab ---- */
  const pD = await page(ctxA, { vp: { width: 1440, height: 900 }, theme: 'light', hum })
  await desktop(pD, MON)
  const csv = await download(pD, 'csv')
  const cr = csv.buf ? csvRows(csv.buf.toString('utf8')) : []
  const ch = cr[0] || []
  const ci = (k) => ch.indexOf(k)
  const cLines = cr.slice(1).filter((r) => r[ci('member_id')] === hum)
  const cGot = cLines.map((r) => `${r[ci('date')]}|${r[ci('target_id')]}|${r[ci('minutes')]}`).sort()
  step('the CSV holds exactly the approved lines, every one period_state = approved', csv.buf && want.length && cGot.join() === want.join() && cLines.every((r) => r[ci('period_state')] === 'approved') && cr.length - 1 === cLines.length,
    { file: csv.file, ui: csv.done, http: csv.http, lines: cLines.length, got: cGot, want })
  await shot(pD, '8-download-csv-1440-light')
  const xl = await download(pD, 'xlsx')
  let xr = { rows: [], sheets: 0, parts: [] }
  try { if (xl.buf) xr = xlsxRows(xl.buf) } catch (e) { xr.error = String(e) }
  const xh = xr.rows[0] || []
  const xi = (k) => xh.indexOf(k)
  const xLines = xr.rows.slice(1).filter((r) => r[xi('member_id')] === hum)
  const xGot = xLines.map((r) => `${r[xi('date')]}|${r[xi('target_id')]}|${r[xi('minutes')]}`).sort()
  step('the XLSX (one sheet) holds the same lines, every one period_state = approved', xl.buf && want.length && xr.sheets === 1 && xGot.join() === want.join() && xLines.every((r) => r[xi('period_state')] === 'approved'),
    { file: xl.file, ui: xl.done, http: xl.http, parts: xr.parts, error: xr.error, lines: xLines.length, got: xGot })
  await shot(pD, '8-download-xlsx-1440-light')

  /* ---- version: build.json and the footer ---- */
  await nav(pD, `${BASE}/lobby`)
  const foot = await pD.waitForSelector('[data-test=app-version]', { timeout: 15000 }).then((el) => el.evaluate((e) => e.textContent.trim()), () => '')
  res.build_at_footer = await (await fetch(BASE + '/build.json')).json().catch(() => null) /* a deploy may land during the run */
  const ver = String(res.build_at_footer?.version || '')
  step('the footer shows build.json\'s version', ver && foot.includes(ver.replace(/^v/, '')), { footer: foot, build: res.build_at_footer })
  await shot(pD, '9-footer-version-1440-light')
  await pD.close()

  /* ---- a second workspace's reader ---- */
  const ctxB = await browser.createBrowserContext()
  const pO = await page(ctxB, { vp: { width: 1440, height: 900 }, theme: 'light', readOnly: true })
  const O = await signIn(pO, OTHER_BASE, OTHER_TENANT, OTHER_EMAIL, OTHER_PW)
  const ome = (await call(pO, O.api, 'GET', '/v1/view/me')).body || {}
  const reads = (ome.permissions || []).includes('hours.read')
  step(`the second workspace's reader signs in there${OTHER_ANY_ROLE ? '' : ' and holds hours.read'}`, O.claims.t && O.claims.t !== TENANT && (reads || OTHER_ANY_ROLE), { t: O.claims.t, role: ome.role, hoursRead: reads })
  const own = await call(pO, O.api, 'GET', `/v1/hours/export?period=${MON}&format=csv&final=false`)
  const ownText = own.text || JSON.stringify(own.body || '')
  const ownClean = !ownText.includes(tTopic.replace(/^t:/, '')) && !ownText.includes(needle)
  step(reads ? 'its own export holds none of these lines' : 'its own workspace refuses it the export (no hours.read) and shows none of these lines',
    (reads ? own.status === 200 : own.status === 403) && ownClean, { status: own.status, lines: reads ? csvRows(ownText).length - 1 : undefined })
  await nav(pO, `${BASE}/calendar?d=${MON}`)
  const cross = await call(pO, O.api, 'GET', `/v1/hours?period=${MON}`)
  const crossX = await call(pO, O.api, 'GET', `/v1/hours/export?period=${MON}&format=csv`)
  const crossMe = await call(pO, O.api, 'GET', `/v1/me/hours?period=${MON}`)
  const leak = [cross, crossX, crossMe].some((r) => (r.text + JSON.stringify(r.body || '')).includes(tTopic.replace(/^t:/, '')))
  step(`the reader of ${O.claims.t} is refused on ${TENANT}'s hours and export`, cross.status >= 400 && crossX.status >= 400 && !leak, { hours: cross.status, export: crossX.status, me: crossMe.status, body: cross.body })
  await shot(pO, '10-cross-workspace-1440-light')
} catch (e) {
  step('the run finished', false, { error: String(e?.stack || e).slice(0, 800) })
} finally {
  await restore()
  save()
  await browser.close()
}
process.exit(res.steps.length && res.steps.every((s) => s.ok) ? 0 : 1)
