// WUI live-proof runner — the picker for tests/e2e/*.proof.mjs (SPL-1771,
// devops guide section 16, gap T4).
//
// Why this exists: `pnpm test:e2e` never discovers a *.proof.mjs (they drive
// live sites), and only one proof (parent-level-live, do_spl_wui_live_proof)
// had a wrapper. The owner (HUM-10, t1 cd592c84): tests are never run in prd
// by default, but an operator can pick any of them and run them there.
//
// Contract:
//   • lists every tests/e2e/*.proof.mjs on disk (`--list`), each marked `ro`
//     when its header says WRITES NOTHING, else `rw?` (read the file first)
//   • runs only what is picked: name filters, exact paths, or `--all`; no
//     pick refuses — running every proof is a choice, never the default
//   • ENV=dev|prd is required; BASE_URL is the deployed WUI (no default:
//     no host is baked in) and reaches each proof as BASE and BASE_URL
//   • ENV=prd also needs LIVE_PROOF_PRD_GO=1, and runs in a test workspace
//     only: TENANT defaults to e2e and must be e2e or e2e-<x>; a BASE_URL
//     host with a workspace label (more labels than BASE_DOMAIN, or than
//     two without it) must carry a test label too. t1 and customer
//     workspaces are refused.
//   • one proof at a time, no retry (a live run is not re-fired on red),
//     LIVE_PROOF_GAP_S between proofs (default 5 on prd, 0 on dev),
//     LIVE_PROOF_TIMEOUT_S per proof (default 900)
//   • each proof gets OUT=<LIVE_PROOF_OUT or a temp dir>/<proof name>;
//     EMAIL, PW_FILE, CHANNEL and the rest pass through from the caller
//   • exit 0 when every picked proof exits 0, 1 when any fails, 2 on a
//     refusal; the last lines name every failed proof
//
// Usage:
//   node src/node/test/run-live-proofs.mjs --list
//   ENV=dev BASE_URL=https://dev.<BASE_DOMAIN> EMAIL=<m> PW_FILE=<0600 file> \
//     node src/node/test/run-live-proofs.mjs p2-smoke build-watch
//   ENV=prd LIVE_PROOF_PRD_GO=1 BASE_URL=https://<BASE_DOMAIN> TENANT=e2e \
//     EMAIL=<m> PW_FILE=<0600 file> node src/node/test/run-live-proofs.mjs p2-smoke
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync } from 'node:fs'
import { join, dirname, resolve, basename } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawn } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const E2E_REL = 'tests/e2e'
const SUFFIX = '.proof.mjs'
// The test workspaces a prd run may touch (devops guide 16.1).
export const TEST_WORKSPACE_RX = /^e2e(-[a-z0-9][a-z0-9-]*)?$/

export function invokedDirectly() {
  const arg = process.argv[1]
  if (!arg) return false
  return import.meta.url === pathToFileURL(resolve(arg)).href
}

// Sorted, so a run is reproducible on every machine.
export function discoverProofs(wui = WUI) {
  const dir = join(wui, E2E_REL)
  if (!existsSync(dir)) return []
  return readdirSync(dir).filter((f) => f.endsWith(SUFFIX)).sort().map((f) => `${E2E_REL}/${f}`)
}

// `ro` when the proof's header comment says it writes nothing.
export function writesNothing(text) {
  const header = String(text).split('\n').filter((l) => l.startsWith('//')).slice(0, 40).join('\n')
  return /WRITES NOTHING/i.test(header)
}

// Returns { files } or { error }. Paths (a `/` in the arg) must be proofs on
// disk; a filter must match at least one proof; nothing picked is an error.
export function selectProofs(discovered, args, { all = false } = {}) {
  const paths = args.filter((a) => a.includes('/'))
  const filters = args.filter((a) => !a.includes('/'))
  if (all && args.length) return { error: '--all takes no names: pick names, or run --all alone' }
  if (all) return discovered.length ? { files: discovered } : { error: `no *${SUFFIX} in ${E2E_REL}` }
  if (!args.length) return { error: 'nothing picked: name proofs (substring or path), or pass --all; --list shows them' }
  const missing = paths.filter((p) => !discovered.includes(p))
  if (missing.length) return { error: `not a proof in ${E2E_REL}: ${missing.join(', ')}` }
  const picked = new Set(paths)
  for (const s of filters) {
    const hit = discovered.filter((f) => f.slice(E2E_REL.length + 1).includes(s))
    if (!hit.length) return { error: `"${s}" matches none of ${discovered.length} proofs` }
    hit.forEach((f) => picked.add(f))
  }
  return { files: discovered.filter((f) => picked.has(f)) }
}

// Returns { env, base, tenant } or { error }. The opt-in and the test
// workspace rule live here, so the unit test pins them.
export function guardTarget({ ENV, BASE_URL, TENANT, LIVE_PROOF_PRD_GO, BASE_DOMAIN } = {}) {
  if (ENV !== 'dev' && ENV !== 'prd') return { error: `ENV must be dev or prd, got: '${ENV ?? ''}'` }
  if (!BASE_URL) return { error: 'BASE_URL must be set (no default), e.g. https://<BASE_DOMAIN>' }
  let url
  try {
    url = new URL(BASE_URL)
  } catch {
    return { error: `BASE_URL is not a URL: '${BASE_URL}'` }
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return { error: `BASE_URL must be http(s): '${BASE_URL}'` }
  const base = BASE_URL.replace(/\/+$/, '')
  if (ENV === 'dev') return { env: ENV, base, tenant: TENANT || '' }
  if (LIVE_PROOF_PRD_GO !== '1') return { error: 'ENV=prd is opt-in: set LIVE_PROOF_PRD_GO=1 to run live proofs against prd' }
  const tenant = TENANT || 'e2e'
  if (!TEST_WORKSPACE_RX.test(tenant)) return { error: `ENV=prd runs in a test workspace only (e2e or e2e-<x>), got TENANT=${tenant}` }
  const host = url.hostname.toLowerCase()
  const apex = (BASE_DOMAIN || '').toLowerCase().replace(/^\.+|\.+$/g, '')
  let label = ''
  if (apex) {
    if (host !== apex && !host.endsWith(`.${apex}`)) return { error: `BASE_URL host ${host} is not under BASE_DOMAIN ${apex}` }
    if (host !== apex) label = host.slice(0, -(apex.length + 1))
  } else if (host.split('.').length > 2) {
    label = host.split('.')[0]
  }
  if (label && !TEST_WORKSPACE_RX.test(label)) return { error: `ENV=prd: BASE_URL host ${host} names workspace '${label}', not a test workspace (e2e or e2e-<x>)` }
  return { env: ENV, base, tenant }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function runProof(file, env, timeoutS) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [join(WUI, file)], { cwd: WUI, env, stdio: 'inherit' })
    let timedOut = false
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGTERM') }, timeoutS * 1000)
    child.on('error', (e) => { clearTimeout(timer); done({ status: null, why: `spawn error: ${e.message}` }) })
    child.on('close', (status, signal) => {
      clearTimeout(timer)
      done({ status, why: timedOut ? `timeout ${timeoutS}s` : signal ? `signal ${signal}` : `exit ${status}` })
    })
  })
}

async function main() {
  const argv = process.argv.slice(2)
  const refuse = (msg) => { console.error(`live-proof runner: ${msg}`); process.exit(2) }
  const discovered = discoverProofs()
  if (!discovered.length) refuse(`no *${SUFFIX} found in ${E2E_REL}`)
  const all = argv.includes('--all')
  const args = argv.filter((a) => !a.startsWith('--'))
  if (argv.includes('--list')) {
    const sel = args.length || all ? selectProofs(discovered, args, { all }) : { files: discovered }
    if (sel.error) refuse(sel.error)
    // one write, exit once it is out (see run-e2e-tests.mjs --list)
    const lines = sel.files.map((f) => `${writesNothing(readFileSync(join(WUI, f), 'utf8')) ? 'ro ' : 'rw?'} ${f}\n`)
    await new Promise((resolve) => process.stdout.write(lines.join(''), resolve))
    process.exit(0)
  }
  const sel = selectProofs(discovered, args, { all })
  if (sel.error) refuse(sel.error)
  const target = guardTarget(process.env)
  if (target.error) refuse(target.error)
  const gapS = Number(process.env.LIVE_PROOF_GAP_S ?? (target.env === 'prd' ? 5 : 0))
  const timeoutS = Number(process.env.LIVE_PROOF_TIMEOUT_S || 900)
  const outRoot = process.env.LIVE_PROOF_OUT || mkdtempSync(join(tmpdir(), 'live-proofs-'))
  const env = { ...process.env, BASE: target.base, BASE_URL: target.base }
  if (target.tenant) env.TENANT = target.tenant
  console.log(`live-proof runner: ${sel.files.length} proof(s), ENV=${target.env}, ${target.base}${target.tenant ? `, workspace ${target.tenant}` : ''}, evidence ${outRoot}\n`)
  const failures = []
  for (const [i, file] of sel.files.entries()) {
    if (i && gapS > 0) await sleep(gapS * 1000)
    const out = join(outRoot, basename(file, SUFFIX))
    mkdirSync(out, { recursive: true })
    console.log(`──[${i + 1}/${sel.files.length}] ${file}`)
    const t0 = Date.now()
    const r = await runProof(file, { ...env, OUT: out }, timeoutS)
    const secs = Math.round((Date.now() - t0) / 1000)
    console.log(`──[${i + 1}/${sel.files.length}] ${r.status === 0 ? 'PASS' : 'FAIL'} ${file} (${r.why}, ${secs}s)\n`)
    if (r.status !== 0) failures.push({ file, why: r.why })
  }
  if (!failures.length) {
    console.log(`live-proof runner: all ${sel.files.length} proof(s) passed`)
    return
  }
  console.log(`live-proof runner: ${failures.length} of ${sel.files.length} proof(s) FAILED`)
  for (const f of failures) console.log(`  FAIL ${f.file} (${f.why})`)
  process.exit(1)
}

if (invokedDirectly()) await main()
