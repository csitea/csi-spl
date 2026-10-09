// Tenant settings (SPL-1037, specs/046), proved in a REAL browser. Owner
// 2026-09-28: "the UI should behave similarly to how the personal settings
// work, but the icon should be in the bottom-left corner of the screen on
// desktop" ... "a section for users where the admins and the biz_owners of
// the tenant can CRUD users".
//
// Against the mock bundle (the mock plays an admin, tenant-settings.mjs +
// tenant-users.mjs): the building icon is the bottom-left of the screen; it
// opens /tenant-settings, which is the Settings layout with Members, Agents,
// Channels and General; Members invites, disables and removes; Agents edits
// the responder order; Channels flips a no-fallback flag and archives
// (confirmed); General saves the tenant name. On a phone the list of
// sections is level 2 and a section is level 3. Performance (spec 066 L7)
// renders the mock's canned summary, ranked by p75 with n beside every
// percentile, a 30-day window and a build A / B compare, on desktop and as
// cards on a phone. The non-admin half (no
// entry, hub 403) is tests/unit/tenant-settings.test.mjs plus hub
// TestTenantSettingsForbidden.
//
// Plant the defect and watch it go red (the proof cancels the archive
// confirmation, so the row stays):
//   PROVE_RED=no-archive node tests/e2e/tenant-settings.test.mjs
// (Performance: the compare is skipped, so step 16d goes red)
//   PROVE_RED=no-compare node tests/e2e/tenant-settings.test.mjs
// (Vendor split per kind: agy 10 in simple coding is saved, so step 8o goes red)
//   PROVE_RED=agy-coding node tests/e2e/tenant-settings.test.mjs
// (Join tokens: the biz_owner mock is not set, so step 17 goes red)
//   PROVE_RED=biz-sees-join node tests/e2e/tenant-settings.test.mjs
//
// Run:
//   pnpm run test:e2e tenant-settings
//   BASE_URL=<generated bundle> pnpm run test:e2e tenant-settings
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const attrs = (p, sel, a) => p.$$eval(sel, (els, a) => els.map((e) => e.getAttribute(a)), a)
const path = (p) => new URL(p.url()).pathname

/* spec 061 FR-004: the mock ids are legacy (CLE-01); pin the browser's
   agent-id clock before LEGACY_ID_UNTIL so the run never turns red at it */
const pinAgentIdClock = (p) => p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await pinAgentIdClock(p)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // specs/054 (CLE-77781): the mock is signed-OUT by default and its /session no
  // longer rides the network. Opt into a signed-in admin (HUM-1 is the mock's
  // admin viewer) exactly as act-as.test.mjs does — set the localStorage session
  // on the real origin, then reload — else the rail and the tenant-settings gear
  // never render and every step below fails at the empty rail.
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the entry: bottom-left of the screen
  await p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: NAV_TIMEOUT })
  const box = await p.$eval('[data-testid=tenant-settings-open]', (e) => {
    const r = e.getBoundingClientRect()
    return { left: r.left, bottom: r.bottom, vw: window.innerWidth, vh: window.innerHeight }
  })
  ok('1 the Tenant settings icon sits in the bottom-left corner', box.left < 80 && box.vh - box.bottom < 80, box)
  await p.click('[data-testid=tenant-settings-open]')
  await p.waitForSelector('[data-test=tenant-settings-nav]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => location.pathname.endsWith('/tenant-settings/members'), { timeout: 10000 }).catch(() => null)
  ok('2 it opens the first section, Members', path(p).endsWith('/tenant-settings/members'), path(p))
  const nav = await attrs(p, '[data-test=tenant-settings-nav] a', 'data-test')
  ok('3 the Settings layout lists Members, Agents, Vendor split, Channels, General, Hours, Performance', nav.join() === 'tenant-settings-nav-members,tenant-settings-nav-agents,tenant-settings-nav-split,tenant-settings-nav-channels,tenant-settings-nav-general,tenant-settings-nav-hours,tenant-settings-nav-performance', nav)

  // 2. Members: the users list and edit pane, embedded
  await p.waitForSelector('[data-test=tenant-settings-members] [data-test=users-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-members] [data-test=users-invite-open]')
  await p.type('[data-test=users-invite-email]', 'ts-invitee@example.com')
  await p.select('[data-test=users-invite-role]', 'tester')
  await p.click('[data-test=users-invite-send]')
  await p.waitForSelector('[data-test=users-row][data-key="i:ts-invitee@example.com"]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('4 Members invites', Boolean(await p.$('[data-test=users-row][data-key="i:ts-invitee@example.com"]')))
  // CLE-77780: a pending invite offers "Send the invite email" until it has been
  // mailed, then "Resend" — the mock's pending invite is unmailed, so it shows
  // Send. Accept either so the check follows the invite's mailed state.
  ok('4b a pending invite offers Send / Resend', Boolean(await p.$('[data-test=users-pane-send-mail], [data-test=users-pane-resend]')))
  await p.click('[data-test=users-row][data-key="m:HUM-3"]')
  await p.waitForSelector('[data-test=users-pane-suspend]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-pane-suspend]')
  await p.waitForSelector('[data-test=users-row][data-key="m:HUM-3"] [data-test=users-row-suspended]', { timeout: 5000 }).catch(() => null)
  ok('5 Members disables a member in this tenant', Boolean(await p.$('[data-test=users-row][data-key="m:HUM-3"] [data-test=users-row-suspended]')))
  ok('5b the member pane shows last seen', Boolean(await p.$('[data-test=users-pane-last-seen]')))
  await p.click('[data-test=users-pane-remove]')
  await p.waitForSelector('[data-test=users-confirm-ok]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-confirm-ok]')
  await sleep(500)
  ok('6 Members removes (after the confirmation)', !(await attrs(p, '[data-test=users-row]', 'data-key')).includes('m:HUM-3'))

  // 3. Agents: seated agents + the responder list
  await p.click('[data-test=tenant-settings-nav-agents]')
  await p.waitForSelector('[data-test=tenant-agent-row]', { visible: true, timeout: 10000 })
  const agents = await attrs(p, '[data-test=tenant-agent-row]', 'data-agent')
  ok('7 Agents lists the seated agents, box-wui humans excluded', agents.includes('CLE-07') && !agents.some((a) => a.startsWith('HUM-')), agents)
  await p.type('[data-test=tenant-responder-input]', 'grk-03')
  await p.click('[data-test=tenant-responder-add]')
  await p.click('[data-test=tenant-responder-row][data-agent="GRK-03"] [data-test=tenant-responder-up]')
  await p.click('[data-test=tenant-responders-save]')
  await p.waitForSelector('[data-test=tenant-responders-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  const order = await attrs(p, '[data-test=tenant-responder-row]', 'data-agent')
  ok('8 Agents adds a responder, moves it up and saves', order.join() === 'GRK-03,CLE-01', order)

  // 3a. Join tokens (spec 073 4.6, 108 T010): the mock plays an admin (me()
  // null = unrestricted), so the panel shows. Mint, copy, close (the token
  // leaves the page), revoke the open token, revoke one seat after a confirm
  // naming the box. The biz_owner half is step 17 below.
  await p.waitForSelector('[data-test=join-tokens]', { visible: true, timeout: 10000 }).catch(() => null)
  ok('8g Agents shows the join-token controls to an admin', Boolean(await p.$('[data-test=join-token-new]')))
  await p.click('[data-test=join-token-new]')
  await p.waitForSelector('[data-test=join-token-label]', { visible: true, timeout: 5000 })
  await p.type('[data-test=join-token-label]', 'e2e laptop')
  await p.click('[data-test=join-token-mint]')
  await p.waitForSelector('[data-test=join-token-line]', { visible: true, timeout: 5000 }).catch(() => null)
  const line = await text(p, '[data-test=join-token-line]')
  const count = await text(p, '[data-test=join-token-countdown]')
  ok('8h mint shows the join line once, with a countdown', /^SPOOL_JOIN_TOKEN=spj1\.\S+ spool join \S+$/.test(line) && /[0-9]:[0-9]{2}/.test(count), { line, count })
  await p.click('[data-test=join-token-copy]')
  await p.waitForSelector('[data-test=join-token-copied]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('8i copy confirms', Boolean(await p.$('[data-test=join-token-copied]')), await text(p, '[data-test=join-token-copied]'))
  await p.click('[data-test=join-token-close]')
  await sleep(200)
  const leaked = await p.evaluate(() => document.body.innerText.includes('spj1.'))
  const rowState = await attrs(p, '[data-test=join-token-row]', 'data-state')
  ok('8j close drops the token; the open list shows it, never its value', !leaked && rowState.join() === 'open', { leaked, rowState })
  await p.click('[data-test=join-token-row] [data-test=join-token-revoke]')
  await p.waitForSelector('[data-test=join-token-row][data-state=revoked]', { timeout: 5000 }).catch(() => null)
  ok('8k Revoke marks the token revoked', (await attrs(p, '[data-test=join-token-row]', 'data-state')).join() === 'revoked')
  const seatBox = (await attrs(p, '[data-test=join-seat-row]', 'data-box'))[0] || ''
  await p.click(`[data-test=join-seat-row][data-box="${seatBox}"] [data-test=join-seat-revoke]`)
  const confirmText = await text(p, `[data-test=join-seat-row][data-box="${seatBox}"] [data-test=join-seat-confirm-text]`)
  await p.click(`[data-test=join-seat-row][data-box="${seatBox}"] [data-test=join-seat-confirm]`)
  await p.waitForFunction((b) => !document.querySelector(`[data-test=join-seat-row][data-box="${b}"]`), { timeout: 5000 }, seatBox).catch(() => null)
  const seatsLeft = await attrs(p, '[data-test=join-seat-row]', 'data-box')
  ok('8l Revoke seat asks first, naming the box, then drops it', Boolean(seatBox) && confirmText.includes(seatBox) && !seatsLeft.includes(seatBox), { seatBox, confirmText, seatsLeft })

  // 3b. Vendor split: five numbers (spec 110), a live sum, the guideline note
  await p.click('[data-test=tenant-settings-nav-split]')
  await p.waitForSelector('[data-test=tenant-split-note]', { visible: true, timeout: 10000 })
  const note = await text(p, '[data-test=tenant-split-note]')
  const sum0 = await text(p, '[data-test=tenant-split-sum]')
  ok('8c Vendor split says it is a guideline and starts at 100', note === 'guideline, not a quota' && sum0.includes('100'), { note, sum0 })
  const setNum = async (sel, value) => {
    await p.$eval(sel, (el, v) => {
      el.value = v
      el.dispatchEvent(new Event('input', { bubbles: true }))
      el.dispatchEvent(new Event('change', { bubbles: true }))
    }, value)
  }
  await setNum('[data-test=tenant-split-qwen]', '9')
  await sleep(100)
  const off = { sum: await text(p, '[data-test=tenant-split-sum]'), disabled: await p.$eval('[data-test=tenant-split-save]', (el) => el.disabled) }
  ok('8d a sum other than 100 keeps Save off', off.sum.includes('109') && off.disabled === true, off)
  await setNum('[data-test=tenant-split-claude]', '30')
  await setNum('[data-test=tenant-split-qwen]', '10')
  await sleep(100)
  const enabled = await p.$eval('[data-test=tenant-split-save]', (el) => el.disabled)
  ok('8e a sum of 100 enables Save', enabled === false)
  await p.click('[data-test=tenant-split-save]')
  await p.waitForSelector('[data-test=tenant-split-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  const savedSplit = {
    notice: await text(p, '[data-test=tenant-split-notice]'),
    claude: await p.$eval('[data-test=tenant-split-claude]', (el) => el.value),
    qwen: await p.$eval('[data-test=tenant-split-qwen]', (el) => el.value),
  }
  ok('8f Vendor split saves', savedSplit.notice !== '' && savedSplit.claude === '30' && savedSplit.qwen === '10', savedSplit)

  // spec 110 7g (D1): grok's share moves to mistral; sum 99 is the control.
  const splitOf = () => p.$$eval('[data-test^=tenant-split-]', (els) => els.filter((e) => e.tagName === 'INPUT')
    .map((e) => `${e.getAttribute('data-test').slice(13)}=${e.value}`).join(' '))
  await setNum('[data-test=tenant-split-claude]', '25')
  await setNum('[data-test=tenant-split-grok]', '0')
  await setNum('[data-test=tenant-split-mistral]', '54')
  await sleep(100)
  const s99 = { sum: await text(p, '[data-test=tenant-split-sum]'), disabled: await p.$eval('[data-test=tenant-split-save]', (el) => el.disabled) }
  ok('8g CONTROL: mistral 54 sums to 99 and keeps Save off', s99.sum.includes('99') && s99.disabled === true, s99)
  await setNum('[data-test=tenant-split-mistral]', '55')
  await sleep(100)
  await p.click('[data-test=tenant-split-save]')
  await p.waitForFunction(() => document.querySelector('[data-test=tenant-split-save]')?.disabled === true, { timeout: 5000 }).catch(() => null)
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-nav-split]')
  await p.waitForSelector('[data-test=tenant-split-mistral]', { visible: true, timeout: 10000 })
  await sleep(100)
  const moved = await splitOf()
  ok('8h mistral 55, grok 0 is saved and read back', moved === 'claude=25 grok=0 agy=10 qwen=10 mistral=55', moved)

  // spec 115 HUB-1: the split per task kind. The table shows the section 2
  // defaults; agy in a coding kind is refused before Save (the CONTROL:
  // PROVE_RED=agy-coding saves it anyway and the mock hub refuses it, 8o
  // red); new weights save and read back after a section change.
  await p.waitForSelector('[data-test=split-kind-simple_coding-mistral]', { visible: true, timeout: 10000 })
  const kindRow = (k) => p.$$eval(`[data-test^=split-kind-${k}-]`, (els, kk) => els.filter((e) => e.tagName === 'INPUT' || e.tagName === 'SELECT')
    .map((e) => `${e.getAttribute('data-test').slice(12 + kk.length)}=${e.value}`).join(' '), k)
  const kinds0 = { simple: await kindRow('simple_coding'), main: await text(p, '[data-test=split-kind-simple_coding-main]'), i18n: await text(p, '[data-test=split-kind-i18n-main]') }
  ok('8m the per-kind table shows the spec 115 defaults and the main', kinds0.simple === 'claude=20 grok=0 agy=0 qwen=0 mistral=80 backup=claude' && kinds0.main === 'Mistral' && kinds0.i18n === 'Antigravity', kinds0)
  await setNum('[data-test=split-kind-simple_coding-mistral]', '70')
  await setNum('[data-test=split-kind-simple_coding-agy]', '10')
  await sleep(100)
  const agy = { rule: await text(p, '[data-test=split-kind-simple_coding-main]'), disabled: await p.$eval('[data-test=split-kinds-save]', (el) => el.disabled) }
  ok('8n CONTROL: agy 10 in simple coding names the rule and keeps Save off', agy.rule === 'Antigravity writes no code' && agy.disabled === true, agy)
  if (RED === 'agy-coding') {
    await p.$eval('[data-test=split-kinds-save]', (el) => { el.disabled = false })
    await p.click('[data-test=split-kinds-save]')
    await sleep(300)
  } else {
    await setNum('[data-test=split-kind-simple_coding-agy]', '0')
    await setNum('[data-test=split-kind-simple_coding-mistral]', '60')
    await setNum('[data-test=split-kind-simple_coding-claude]', '30')
    await setNum('[data-test=split-kind-simple_coding-grok]', '10')
    await sleep(100)
    await p.click('[data-test=split-kinds-save]')
    await p.waitForSelector('[data-test=split-kinds-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  }
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-nav-split]')
  await p.waitForSelector('[data-test=split-kind-simple_coding-mistral]', { visible: true, timeout: 10000 })
  await sleep(100)
  const kinds1 = { simple: await kindRow('simple_coding'), reset: Boolean(await p.$('[data-test=split-kind-simple_coding-reset]')), tests: await kindRow('tests') }
  ok('8o new per-kind weights save and read back', kinds1.simple === 'claude=30 grok=10 agy=0 qwen=0 mistral=60 backup=claude' && kinds1.reset && kinds1.tests === 'claude=70 grok=0 agy=0 qwen=0 mistral=30 backup=mistral', kinds1)
  if (process.env.SPLIT_SHOT) await p.screenshot({ path: process.env.SPLIT_SHOT, fullPage: true })

  // 4. Channels: no-fallback + archive
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  const chans = await attrs(p, '[data-test=tenant-channel-row]', 'data-channel')
  ok('9 Channels lists default and private channels', chans.includes('lobby') && chans.includes('secret'), chans)
  ok('9b a default channel offers no Archive', !(await p.$('[data-test=tenant-channel-row][data-channel=lobby] [data-test=tenant-channel-archive]')))
  await p.click('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-fallback]')
  await sleep(400)
  const flag = await p.$eval('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-fallback]', (e) => e.checked)
  ok('10 Channels switches fallback off', flag === false)
  await p.click('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-archive]')
  await p.waitForSelector('[data-test=tenant-channel-archive-ok]', { visible: true, timeout: 5000 })
  await p.click(RED === 'no-archive' ? '[data-test=tenant-channel-archive-cancel]' : '[data-test=tenant-channel-archive-ok]')
  await sleep(500)
  ok('11 Channels archives (after the confirmation)', !(await attrs(p, '[data-test=tenant-channel-row]', 'data-channel')).includes('design'))

  // 5. General: the tenant name
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-general-name]', { visible: true, timeout: 10000 })
  await p.focus('[data-test=tenant-general-name]')
  await p.$eval('[data-test=tenant-general-name]', (e) => e.select())
  await p.type('[data-test=tenant-general-name]', 'Renamed tenant')
  await p.click('[data-test=tenant-general-save]')
  await p.waitForSelector('[data-test=tenant-general-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  const general = { value: await p.$eval('[data-test=tenant-general-name]', (e) => e.value), notice: await text(p, '[data-test=tenant-general-notice]'), error: await text(p, '[data-test=tenant-general-error]') }
  ok('12 General saves the tenant name', general.value === 'Renamed tenant' && general.notice !== '', general)
  // CLE-77819: General -> "Who can archive topics" (default everyone), saved
  const policy0 = await p.$eval('[data-test=tenant-general-archive-policy]', (e) => ({ value: e.value, options: [...e.options].map((o) => o.value), labels: [...e.options].map((o) => o.textContent.trim()) }))
  await p.select('[data-test=tenant-general-archive-policy]', 'admins')
  await p.click('[data-test=tenant-general-save]')
  await sleep(500)
  const policy1 = { value: await p.$eval('[data-test=tenant-general-archive-policy]', (e) => e.value), error: await text(p, '[data-test=tenant-general-error]') }
  ok('12b General: Who can archive topics defaults to everyone, offers the three, saves admins',
    policy0.value === 'everyone' && policy0.options.join() === 'everyone,admins,starter' && policy0.labels.every((l) => l && !l.startsWith('tenant_settings.')) &&
    policy1.value === 'admins' && policy1.error === '', { policy0, policy1 })

  // 5b. Performance (spec 066 L7): the canned summary, ranked by p75
  const perfRows = () => p.$$eval('[data-test=tenant-perf-row]', (els) => els.map((e) => ({
    metric: e.getAttribute('data-metric'),
    label: e.querySelector('[data-test=tenant-perf-metric]')?.textContent.trim(),
    n: Number(e.querySelector('[data-test=tenant-perf-n]')?.textContent.trim()),
    p75: Number(e.querySelector('[data-test=tenant-perf-p75]')?.textContent.trim()),
    p95: e.querySelector('[data-test=tenant-perf-p95]')?.textContent.trim(),
    change: e.querySelector('[data-test=tenant-perf-change]')?.textContent.trim(),
  })))
  await p.click('[data-test=tenant-settings-nav-performance]')
  await p.waitForSelector('[data-test=tenant-perf-row]', { visible: true, timeout: 10000 })
  const perf7 = await perfRows()
  ok('16 Performance shows the canned summary, slowest p75 first, readable labels', perf7.length === 6 && perf7[0].metric === 'load_messages' &&
    perf7.every((r, i) => i === 0 || perf7[i - 1].p75 >= r.p75) && perf7.every((r) => r.label && !r.label.startsWith('tenant_settings.')), perf7)
  ok('16b n beside every percentile; p95 hidden under n = 50', perf7.every((r) => r.n > 0) &&
    perf7.filter((r) => r.n < 50).every((r) => r.p95 === '—') && perf7.filter((r) => r.n >= 50).every((r) => /^[0-9]+$/.test(r.p95)), perf7)
  await p.select('[data-test=tenant-perf-days]', '30')
  await p.waitForFunction((n0) => Number(document.querySelector('[data-test=tenant-perf-n]')?.textContent) === n0 * 4, { timeout: 5000 }, perf7[0].n).catch(() => null)
  const perf30 = await perfRows()
  ok('16c the 30-day window reads again', perf30.length === 6 && perf30[0].n === perf7[0].n * 4, { n7: perf7[0].n, n30: perf30[0].n })
  await p.type('[data-test=tenant-perf-build]', '1.3.11')
  if (RED !== 'no-compare') await p.type('[data-test=tenant-perf-build-b]', '1.3.12')
  await p.click('[data-test=tenant-perf-apply]')
  await p.waitForSelector('[data-test=tenant-perf-table][data-compare="1"]', { visible: true, timeout: 5000 }).catch(() => null)
  const perfAB = await perfRows()
  ok('16d a second build compares the two (B minus A at p75)', perfAB.length === 6 && perfAB.every((r) => /^[-+]?[0-9]+$/.test(r.change || '')) && perfAB[0].change.startsWith('-'), perfAB)

  // 6. phone: the list is level 2, a section level 3
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/tenant-settings', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-settings-nav-general]', { visible: true, timeout: 10000 })
  ok('13 phone: /tenant-settings is the list of sections', path(p).endsWith('/tenant-settings') && !(await p.$('[data-test=tenant-settings-content] [data-test=tenant-settings-general]')))
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-settings-general]', { visible: true, timeout: 10000 })
  const navHidden = await p.$eval('[data-test=tenant-settings-nav]', (e) => getComputedStyle(e).display === 'none')
  ok('14 phone: a section opens full width, the list hidden', navHidden)
  await p.goto(server.base + '/tenant-settings/performance', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-perf-row]', { visible: true, timeout: 10000 })
  const phonePerf = await p.evaluate(() => {
    const rows = [...document.querySelectorAll('[data-test=tenant-perf-row]')]
    const head = document.querySelector('[data-test=tenant-perf-table] thead')
    return {
      rows: rows.length,
      fits: rows.every((r) => r.getBoundingClientRect().right <= window.innerWidth + 1),
      pageScrollX: document.documentElement.scrollWidth > window.innerWidth + 1,
      headHidden: !!head && getComputedStyle(head).display === 'none',
    }
  })
  ok('14b phone: Performance shows one card per group, no sideways scroll', phonePerf.rows === 6 && phonePerf.fits && !phonePerf.pageScrollX && phonePerf.headHidden, phonePerf)
  ok('15 no page errors', errors.length === 0, errors)

  // 7. spec 073 4.7: a biz_owner (keys.manage, no agents.join) sees the
  // Agents list but no join-token controls. The mock me() plays one when
  // spool.mock.me is set (PROVE_RED=biz-sees-join leaves it unset: red).
  const q = await browser.newPage()
  await pinAgentIdClock(q)
  await q.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await q.evaluate((red) => {
    if (red !== 'biz-sees-join') {
      localStorage.setItem('spool.mock.me', JSON.stringify({ role: 'biz_owner', permissions: ['members.invite', 'members.roles', 'tenant.settings', 'keys.manage', 'audit.read'] }))
    }
  }, RED)
  await q.goto(server.base + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await q.waitForSelector('[data-test=tenant-agent-row]', { visible: true, timeout: 10000 }).catch(() => null)
  await sleep(500)
  const bizRows = (await attrs(q, '[data-test=tenant-agent-row]', 'data-agent')).length
  const bizJoin = Boolean(await q.$('[data-test=join-tokens], [data-test=join-token-new], [data-test=join-seat-revoke]'))
  ok('17 a biz_owner sees the agents but no join-token or Revoke seat control', bizRows > 0 && !bizJoin, { bizRows, bizJoin })
  await q.evaluate(() => localStorage.removeItem('spool.mock.me'))
  await q.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
