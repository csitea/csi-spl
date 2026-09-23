#!/usr/bin/env node
// dm-verbatim-prompt.proof.mjs — the owner's own acceptance test for
// specs/028 FR-009: a human types a DM in the WUI and the AGENT's prompt
// receives those exact words.
//
// Owner, 2026-09-22: "the input should be set on THIS here input where a human
// would type this and an enter hit", "so that the communication would be as a
// human would be typing into this chat textbox".
//
// It proves the WHOLE chain, which no unit test can: browser -> hub -> the box
// `spool hub-run` sidecar -> SPOOL_NOTIFY_CMD -> tmux send-keys into the
// agent's prompt. The two assertions that matter are deliberately separate:
//
//   dm row visible      the hub accepted the send and echoed it back
//   pane carries body   the agent's PROMPT got the human's words, verbatim
//
// and a CONTROL that the wrapper is gone, because "the message reached the
// pane" was true before this change too - it reached it dressed as a shell
// no-op, which is the whole defect the owner reported.
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
//
//   BASE       the WUI origin, e.g. https://dev.<fqdn>
//   EMAIL      the bot member (never the owner's account)
//   PW_FILE    0600 file holding that member's password
//   PEER       the desk agent, e.g. CLE-44@box-desk
//   OUT        evidence dir (screenshots + results.json)
//   PANE_CMD   shell command asserting the pane; $AGENT $NEEDLE $TIMEOUT $WHERE
//              are set. It MUST pass $WHERE through to pane-seen.sh --where:
//              the default `any` searches the notice strip first and returns on
//              the first hit, so a prompt assertion made without it passes on
//              the SHOW leg. Measured 2026-09-22: this proof read PASS on the
//              notice strip while the prompt leg had been refused ten times.
//   TENANT     default t1
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { execFile } from 'node:child_process'
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
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const PEER = process.env.PEER || 'CLE-00@box-desk'
const TENANT = process.env.TENANT || 't1'
const PANE_CMD = process.env.PANE_CMD || ''
const PANE_TIMEOUT = process.env.PANE_TIMEOUT || '45'
const AGENT = PEER.split('@')[0]
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()

const res = { base: BASE, peer: PEER, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  if (!ok) failed++
  res.steps.push({ name, ok, ...ev })
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const WHERE_AGENT = 'agent'
const sh = (cmd, env) => new Promise((resolve) => {
  execFile('bash', ['-c', cmd], { env: { ...process.env, ...env }, timeout: 120000 },
    (err, stdout, stderr) => resolve({ code: err ? (err.code ?? 1) : 0, stdout: String(stdout), stderr: String(stderr) }))
})

// The body carries an apostrophe ON PURPOSE. The old renderer turned `'` into
// `"` to keep the line inside a single-quoted shell argument; a TUI prompt has
// no shell, so a surviving apostrophe is the evidence that the prompt path -
// not the poke-line path - is what typed this.
const nonce = Date.now().toString(36)
const BODY = `owner's verbatim check ${nonce} — no wrapper please`

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  // NOT networkidle2. This WUI holds a live hub websocket open, so the network
  // never goes idle and every goto burns its whole budget before throwing
  // (measured 2026-09-22: 3 runs, ERR/timeout at 30 s, while the page itself
  // answered 200 in 6.6 s). domcontentloaded plus an explicit waitForSelector
  // waits for the thing we actually need instead of for silence that a live
  // socket guarantees will never come.
  p.setDefaultNavigationTimeout(60000)
  p.setDefaultTimeout(60000)

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 40000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('not signed in (a repeated run earns 429 rate_limited)')
  await sleep(2000)

  await p.goto(`${BASE}/dm/${encodeURIComponent(PEER)}`, { waitUntil: 'domcontentloaded' })
  await sleep(2500)
  await p.screenshot({ path: `${OUT}/1-dm-open.png` })

  // The omnibox IS the composer on a DM page. Ctrl+Enter sends; Enter
  // only inserts a line.
  const OMNI = '[data-test=top-bar-omnibox] textarea, textarea'
  await p.waitForSelector(OMNI, { timeout: 20000 })
  await p.click(OMNI)
  await p.type(OMNI, BODY)
  const t0 = Date.now()
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')

  // the sender's own row coming back
  const seen = await p.waitForFunction(
    (needle) => document.body && document.body.innerText.includes(needle),
    { timeout: 30000 }, nonce).catch(() => null)
  const wui_ms = Date.now() - t0
  step('dm row visible in the WUI', !!seen, { wui_ms, body: BODY })
  await p.screenshot({ path: `${OUT}/2-dm-sent.png` })

  // the leg this spec is about: the AGENT's prompt
  if (PANE_CMD) {
    const r = await sh(PANE_CMD, { AGENT, NEEDLE: nonce, TIMEOUT: PANE_TIMEOUT, WHERE: WHERE_AGENT })
    let kind = null
    try { kind = JSON.parse(r.stdout.trim().split('\n').pop()).kind } catch { /* not json */ }
    // `seen` alone is not enough: it must have been seen on the AGENT pane.
    step('the agent PROMPT carries the body', r.code === 0 && kind === 'agent',
      { agent: AGENT, needle: nonce, kind, out: r.stdout.trim().slice(0, 400) })

    // CONTROL: the words arrived WITHOUT the shell-inert wrapper. Before
    // FR-009 the pane matched the needle too - inside `: 'SPOOL …'` - so a
    // needle-only assertion would have passed against the very defect the
    // owner reported. This is the assertion that tells the two apart.
    const w = await sh(PANE_CMD, { AGENT, NEEDLE: `: 'SPOOL ${AGENT}:`, TIMEOUT: '5', WHERE: WHERE_AGENT })
    step('CONTROL: no `: \'SPOOL …\'` wrapper around it', w.code !== 0, { wrapper_found: w.code === 0 })
  } else {
    step('the agent PROMPT carries the body', false, { skipped: 'PANE_CMD unset' })
  }
} catch (e) {
  step('run completed', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'OK every step PASS', OUT)
  process.exit(failed ? 1 : 0)
}
