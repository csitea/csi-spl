// 047 Wave 1 onboarding live proof (CLE-35094: W12 SPL-1166, W14 SPL-1169,
// W15 SPL-1172, W16 SPL-1175) - a fresh tenant's biz_owner, from the first
// sign-in to an agent answering in #lobby, against a deployed WUI + hub:
//
//   0  (dev) register + verify the buyer with the debug token only a dev hub
//      answers; a random password kept in memory only. (prd: EMAIL + PW_FILE)
//   1  native sign-in on BASE                                        t0
//   2  W15  / shows the first-run checklist, its 3 steps
//   3  W14  the ? at the foot of the rail opens /help, rendered (1 click)
//   4  W16  Tenant settings -> General shows the issue prefix; /issues makes
//           an issue with no epic through the WUI form
//   5  W12  Tenant settings -> Agents: the Connect an agent block, copied from
//           the page as shown, runs in a FRESH HOME (the root key file placed
//           where the block expects it); the agent appears; Add to #lobby
//   6       a post in #lobby; `claude -p` with the spool MCP the block
//           registered answers it; the answer is read back from the hub  t1
//
//   BASE=https://<wui> API=https://<api> TENANT=<t> OUT=<dir> WORK=<dir>
//   ROOT_KEY_FILE=<claim JSON with root_private_key, or the bare key>
//   (dev) BUYER_EMAIL=<address with no account yet, invited as biz_owner>
//   (prd) EMAIL=<biz_owner> PW_FILE=<0600 file>
//   [AGENT=CLE-01] [BOX=box-w12-live] [CLAUDE=claude] [CHROME_PATH] [PUPPETEER_CORE]
//   [SKIP_CLAUDE=1]  stop after the #lobby post (the agent leg run by hand:
//     the claude login of the proof's OS user may differ from the box user's)
//   [FIRST_RUN=shown|hidden]  hidden: a tenant that is set up already - the
//     checklist must NOT show (the control); default shown (a fresh tenant)
//   node tests/e2e/onboarding-live.proof.mjs
//
// Prints one JSON line per step and a verdict; exit 0 only when every step
// held. No password, key or cookie is printed. The fresh HOME keeps a
// running `spool hub-run`: stop it and revoke the pin after the proof.
import { spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const TENANT = need('TENANT')
const OUT = need('OUT')
const WORK = need('WORK')
const AGENT = process.env.AGENT || 'CLE-01'
const BOX = process.env.BOX || 'box-w12-live'
const CLAUDE = process.env.CLAUDE || 'claude'
mkdirSync(OUT, { recursive: true })

const steps = []
let failed = false
const step = (name, ok, ev = {}) => {
  steps.push({ step: name, ok, ...ev })
  if (!ok) failed = true
  console.log(JSON.stringify({ step: name, ok, ...ev }))
}

/* the root key text: a claim JSON (root_private_key) or the bare key file */
function rootKeyText() {
  const raw = readFileSync(need('ROOT_KEY_FILE'), 'utf8').trim()
  try { const j = JSON.parse(raw); if (j && j.root_private_key) return String(j.root_private_key) } catch { /* bare key */ }
  return raw
}

async function post(path, body) {
  const r = await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  let out = null
  try { out = await r.json() } catch { /* empty */ }
  return { status: r.status, out }
}

/* dev: a fresh account for the buyer address (debug token = dev hub only) */
async function devAccount(email) {
  const pw = randomBytes(18).toString('base64url')
  const reg = await post('/api/v1/auth/register', { email, password: pw, name: 'FirstName LastName' })
  const tok = reg.out && reg.out.debug_token
  if (reg.status >= 300 || !tok) return { ok: false, where: 'register', status: reg.status, error: reg.out && reg.out.error }
  const ver = await post('/api/v1/auth/email/verify', { token: tok, password: pw })
  if (ver.status >= 300) return { ok: false, where: 'verify', status: ver.status, error: ver.out && ver.out.error }
  return { ok: true, pw }
}

/* the hub's answer to a signed-in read, from the page (the session cookie rides along) */
const apiGet = (p, path) => p.evaluate(async (api, path) => {
  const r = await fetch(api + path, { credentials: 'include' })
  return { status: r.status, body: r.ok ? await r.json() : null }
}, API, path)

const email = process.env.BUYER_EMAIL || need('EMAIL')
let pw = ''
if (process.env.BUYER_EMAIL) {
  const a = await devAccount(email)
  step('0 buyer account (register + verify)', a.ok, a.ok ? {} : a)
  if (!a.ok) process.exit(1)
  pw = a.pw
} else {
  pw = readFileSync(need('PW_FILE'), 'utf8').trim()
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--window-size=1400,1000'],
})
let t0 = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1400, height: 1000 })

  /* 1 sign in */
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT), { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  t0 = Date.now()
  const me = signed ? await apiGet(p, '/v1/view/me') : null
  step('1 sign-in', Boolean(signed), { role: me?.body?.role, tenant: me?.body?.tenant_id })
  if (!signed) throw new Error('sign-in failed at ' + p.url())

  /* 2 W15 */
  await p.goto(BASE + '/', { waitUntil: 'networkidle2', timeout: 60000 })
  const card = await p.waitForSelector('[data-test=first-run]', { visible: true, timeout: 20000 }).catch(() => null)
  const fr = card ? await p.$$eval('[data-test^=first-run-step-]', (els) => els.map((e) => `${e.getAttribute('data-test').slice(15)}:${e.getAttribute('data-done')}`)) : []
  await p.screenshot({ path: join(OUT, '2-first-run.png') })
  if (process.env.FIRST_RUN === 'hidden') step('2 W15 CONTROL a tenant that is set up shows no checklist', !card)
  else step('2 W15 first sign-in shows the next 3 steps', fr.length === 3, { steps: fr })

  /* 3 W14 */
  const help = await p.waitForSelector('[data-testid=help-open]', { visible: true, timeout: 10000 }).catch(() => null)
  if (help) await help.click()
  const helpOk = await p.waitForSelector('[data-test=help-content] [data-testid=md-block][data-rendered=true]', { timeout: 20000 }).then(() => true, () => false)
  step('3 W14 help reachable in 1 click', Boolean(help) && helpOk, { path: new URL(p.url()).pathname })

  /* 4 W16 */
  await p.goto(BASE + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: 60000 })
  const prefix = await p.waitForSelector('[data-test=tenant-general-issue-prefix]', { timeout: 20000 }).then((h) => h.evaluate((i) => i.value), () => '')
  step('4a W16 issue prefix in Tenant settings -> General', /^[A-Z][A-Z0-9]{0,9}$/.test(prefix), { prefix })
  await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  const title = `First issue, no epic ${Date.now().toString(36)}`
  await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: 30000 }).catch(() => {})
  await sleep(800)
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 10000 })
  await p.type('[data-test=issues-newrow-title]', title)
  /* a tenant with epics pre-picks one: choose "No epic" (the menu's first option) */
  const pill = await p.$('[data-test=issues-newrow] [data-test=issues-epic]')
  const noEpicLabel = pill ? await pill.evaluate((b) => b.getAttribute('title')) : ''
  if (pill) {
    await pill.click()
    const first = await p.waitForSelector('[data-test=issues-menu-option]', { visible: true, timeout: 5000 }).catch(() => null)
    if (first) await first.click()
    await sleep(300)
  }
  step('4b- the new row offers No epic', !pill || (await p.$eval('[data-test=issues-newrow] [data-test=issues-epic]', (b) => b.textContent.trim()).catch(() => '')) !== '', { before: noEpicLabel })
  await p.focus('[data-test=issues-newrow-title]')
  await p.keyboard.press('Enter')
  let made = null
  for (let i = 0; i < 20 && !made; i++) {
    await sleep(500)
    const list = await apiGet(p, '/v1/view/issues')
    made = (list.body?.issues || []).find((x) => x.title === title) || null
  }
  step('4b W16 first issue created without an epic', Boolean(made && made.epic === '' && made.level === 2), { key: made?.key, epic: made?.epic, level: made?.level })
  if (made && process.env.KEEP_ISSUE !== '1') {
    const del = await p.evaluate(async (api, key) => (await fetch(api + '/v1/issues/' + key, { method: 'DELETE', credentials: 'include' })).status, API, made.key)
    step('4c the proof issue is deleted again', del >= 200 && del < 300, { status: del })
  }

  /* 5 W12 */
  await p.goto(BASE + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=connect-agent]', { timeout: 20000 })
  const open = await p.$eval('[data-test=connect-agent]', (d) => d.open)
  if (!open) await p.click('[data-test=connect-agent-summary]')
  const setField = async (sel, v) => { await p.$eval(sel, (el) => { el.focus(); el.select() }); await p.keyboard.press('Backspace'); await p.type(sel, v) }
  await setField('[data-test=connect-agent-id]', AGENT)
  await setField('[data-test=connect-agent-box]', BOX)
  await sleep(300)
  const block = await p.$eval('[data-test=connect-agent-script] pre', (el) => el.innerText).catch(() => '')
  await p.screenshot({ path: join(OUT, '5-connect-agent.png'), fullPage: true })
  step('5a W12 the Connect an agent block', /claude mcp add spool/.test(block) && block.includes(`--as ${AGENT}`), { open, lines: block.split('\n').length })
  const home = join(WORK, 'home')
  mkdirSync(join(home, 'Downloads'), { recursive: true })
  const keyPath = join(home, 'Downloads', `${TENANT}.root.key`)
  writeFileSync(keyPath, rootKeyText() + '\n', { mode: 0o600 })
  chmodSync(keyPath, 0o600)
  writeFileSync(join(WORK, 'block.sh'), block + '\n')
  const b0 = Date.now()
  const run = spawnSync('bash', ['-i'], {
    input: block + '\n',
    cwd: home,
    env: { HOME: home, PATH: `${process.env.GO_BIN || '/usr/local/go/bin'}:${process.env.CLAUDE_DIR || ''}:/usr/bin:/bin`, TERM: 'dumb' },
    encoding: 'utf8',
    timeout: 15 * 60 * 1000,
  })
  writeFileSync(join(OUT, '5-block.log'), (run.stdout || '') + (run.stderr || ''))
  const pinned = /"box_id":"/.test(run.stdout + run.stderr) && /Added stdio MCP server spool/.test(run.stdout + run.stderr)
  step('5b W12 the pasted block ran (fresh HOME)', run.status === 0 && pinned, { status: run.status, secs: Math.round((Date.now() - b0) / 1000) })
  let row = null
  for (let i = 0; i < 12 && !row; i++) {
    await p.goto(BASE + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: 60000 })
    row = await p.$(`[data-test=tenant-agent-row][data-agent="${AGENT}"] [data-test=tenant-agent-lobby-add]`)
    if (!row) await sleep(5000)
  }
  if (row) await row.click()
  const inLobby = row ? await p.waitForSelector(`[data-test=tenant-agent-row][data-agent="${AGENT}"] [data-test=tenant-agent-lobby-ok]`, { timeout: 15000 }).then(() => true, () => false) : false
  step('5c W12 the agent is seated and added to #lobby', inLobby)

  /* 6 the agent answers in #lobby */
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  const nonce = `w12live-${Date.now().toString(36)}`
  const ta = await p.waitForSelector('form.composer textarea', { timeout: 20000 })
  await ta.focus()
  await p.keyboard.type(`Hello ${AGENT}, this is the onboarding proof ${nonce}: please answer with one line.`)
  await p.keyboard.press('Enter')
  const task = await p.waitForFunction((n) => {
    const a = [...document.querySelectorAll('article.msg')].find((x) => x.textContent.includes(n))
    return a && a.getAttribute('data-task-id')
  }, { timeout: 30000, polling: 500 }, nonce).then((h) => h.jsonValue(), () => '')
  step('6a a post in #lobby', Boolean(task), { task })
  const mcp = { mcpServers: { spool: { command: 'bash', args: ['-c', `export HOME=${JSON.stringify(home).slice(1, -1)}; . ~/.spool/env && exec spool mcp --as ${AGENT}`] } } }
  writeFileSync(join(WORK, 'mcp.json'), JSON.stringify(mcp))
  const prompt = await p.goto(BASE + '/tenant-settings/agents', { waitUntil: 'networkidle2' })
    .then(async () => { const o = await p.$eval('[data-test=connect-agent]', (d) => d.open); if (!o) await p.click('[data-test=connect-agent-summary]'); await setField('[data-test=connect-agent-id]', AGENT); await sleep(200); return p.$eval('[data-test=connect-agent-prompt] pre', (el) => el.innerText) })
    .catch(() => '')
  const c0 = Date.now()
  if (process.env.SKIP_CLAUDE === '1') {
    writeFileSync(join(OUT, 'onboarding.json'), JSON.stringify({ base: BASE, tenant: TENANT, task, prompt, steps }, null, 1))
    console.log(JSON.stringify({ step: 'handoff', task, prompt, mcp: join(WORK, 'mcp.json') }))
    throw new Error('SKIP_CLAUDE=1: run the agent leg by hand, then read the topic back')
  }
  const cl = spawnSync(CLAUDE, ['-p', prompt, '--mcp-config', join(WORK, 'mcp.json'), '--strict-mcp-config',
    '--allowedTools', 'mcp__spool__spool_recv', 'mcp__spool__spool_send'], { encoding: 'utf8', timeout: 6 * 60 * 1000, cwd: WORK })
  writeFileSync(join(OUT, '6-claude.log'), (cl.stdout || '') + '\n--- stderr ---\n' + (cl.stderr || ''))
  let answer = null
  for (let i = 0; i < 40 && !answer && task; i++) {
    const v = await apiGet(p, '/v1/view/topics/' + task)
    /* a message signed by the agent's box (env.from_box; the body is inside the signed envelope) */
    const msgs = v.body?.messages || []
    answer = msgs.find((m) => JSON.stringify(m.env || {}).includes(`"${BOX}"`)) || null
    if (!answer) await sleep(3000)
  }
  const t1 = Date.now()
  if (task) {
    await p.goto(BASE + '/t/' + task, { waitUntil: 'networkidle2', timeout: 60000 })
    await sleep(2000)
    await p.screenshot({ path: join(OUT, '6-answer.png') })
  }
  step('6b W12 the agent answers in #lobby', Boolean(answer), { claude_exit: cl.status, claude_secs: Math.round((t1 - c0) / 1000), messages: answer ? 'from ' + BOX : 'none' })
  step('W12 metric: first sign-in to an agent answering in #lobby', Boolean(answer) && t1 - t0 < 10 * 60 * 1000, { secs: Math.round((t1 - t0) / 1000), limit_secs: 600 })
} catch (e) {
  step('run', false, { error: String((e && e.message) || e).slice(0, 300) })
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'onboarding.json'), JSON.stringify({ base: BASE, tenant: TENANT, steps }, null, 1))
console.log(failed ? 'onboarding-live: FAILED' : `onboarding-live: all ${steps.length} held`)
process.exit(failed ? 1 : 0)
