// Shared preamble of the live proofs (tests/e2e/*.proof.mjs). Over 100 of them
// carried the same loadPuppeteer / need / sleep, copied (CLE-77928, clean-code
// round, item 34). A proof imports what it uses:
//   import { loadPuppeteer, need, sleep } from './lib/proof.mjs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// puppeteer-core from PUPPETEER_CORE (a path or a package spec), else from the
// WUI's node_modules. Throws when neither resolves: a proof never runs without
// a browser driver.
export async function loadPuppeteer() {
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

// need(k) - the env var k, or exit 2 naming it.
export const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// relayPlus(box, tag) - a plus-address of the relay mailbox box (user@domain):
// user+tag@domain. The verify mail to it lands where MAIL_TOKEN_CMD reads.
export const relayPlus = (box, tag) => box.replace('@', `+${tag}@`)

export const NO_TOKEN = 'the hub answered no debug_token (lde only since SPL-2157) and no MAIL_TOKEN_CMD is set to read the verify mail: ' +
  'set MAIL_TOKEN_CMD="cd <repo>/csi-spl-orc && ENV=<env> ./run -a do_spl_mail_verify_token" and register a fresh relay plus-address'

// verifyToken(body, email) - the token that verifies a register (SPL-2411):
// the hub's debug_token when it answers one (lde), else the link in the verify
// mail to email, which MAIL_TOKEN_CMD (a shell command) writes to the file
// MAIL_TOKEN_FILE it is given, with MAIL_TOKEN_EMAIL. Never throws:
// { token, via } or { token: '', via, error }. The token is never printed.
export function verifyToken(body, email) {
  const dbg = body && typeof body.debug_token === 'string' ? body.debug_token : ''
  if (dbg) return { token: dbg, via: 'debug_token' }
  const cmd = process.env.MAIL_TOKEN_CMD
  if (!cmd) return { token: '', via: 'none', error: NO_TOKEN }
  const dir = mkdtempSync(join(tmpdir(), 'mail-token-'))
  const file = join(dir, 'token')
  try {
    const r = spawnSync('sh', ['-c', cmd], {
      env: { ...process.env, MAIL_TOKEN_EMAIL: email, MAIL_TOKEN_FILE: file }, encoding: 'utf8', timeout: 600000,
    })
    const token = existsSync(file) ? readFileSync(file, 'utf8').trim() : ''
    if (token) return { token, via: 'mail' }
    const last = `${r.stdout || ''}${r.stderr || ''}`.trim().split('\n').slice(-1)[0]
    return { token: '', via: 'mail', error: `MAIL_TOKEN_CMD exit ${r.status}: ${last}` }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}
