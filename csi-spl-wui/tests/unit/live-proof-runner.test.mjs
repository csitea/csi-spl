// Guards the live-proof picker (SPL-1771, devops guide section 16, gap T4):
// it lists every *.proof.mjs, runs only what is picked, and ENV=prd is an
// opt-in that never targets t1 or a customer workspace.
//
// Run: node tests/unit/live-proof-runner.test.mjs
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { discoverProofs, selectProofs, guardTarget, writesNothing } from '../../src/node/test/run-live-proofs.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const RUNNER = join(WUI, 'src/node/test/run-live-proofs.mjs')

let failed = 0
const check = (n, ok, m) => { if (ok) console.log(`  OK   ${n}`); else { failed++; console.log(`  FAIL ${n}: ${m}`) } }

console.log('live-proof-runner (the prd opt-in picker)')

// --- discovery and --list ------------------------------------------------------
const onDisk = readdirSync(join(WUI, 'tests/e2e')).filter((f) => f.endsWith('.proof.mjs'))
const found = discoverProofs()
check('discovers every *.proof.mjs on disk', found.length === onDisk.length && found.length > 0, `${found.length} found, ${onDisk.length} on disk`)
check('discovers no *.test.mjs', !found.some((f) => f.endsWith('.test.mjs')), 'a test file was discovered')
const list = spawnSync(process.execPath, [RUNNER, '--list'], { cwd: WUI, encoding: 'utf8', env: { PATH: process.env.PATH } })
const lines = list.stdout.trim().split('\n').filter(Boolean)
check('--list exits 0 with no ENV', list.status === 0, list.stderr)
check('--list prints one line per proof', lines.length === onDisk.length, `${lines.length} lines`)
check('--list marks ro / rw?', lines.every((l) => /^(ro |rw\?) tests\/e2e\/\S+\.proof\.mjs$/.test(l)), lines.find((l) => !/^(ro |rw\?) /.test(l)))
check('WRITES NOTHING header reads ro', writesNothing('// x\n// WRITES NOTHING.\nimport a'), 'not ro')
check('no header claim reads rw?', !writesNothing('// posts a message\nconst x = "WRITES NOTHING"'), 'code text counted')
check('p2-smoke is listed ro', lines.includes('ro  tests/e2e/p2-smoke-live.proof.mjs'), 'p2-smoke not ro')

// --- the pick --------------------------------------------------------------------
const d = ['tests/e2e/a-live.proof.mjs', 'tests/e2e/b-live.proof.mjs', 'tests/e2e/ab-live.proof.mjs']
check('nothing picked refuses', /nothing picked/.test(selectProofs(d, []).error), 'ran without a pick')
check('--all picks every proof', selectProofs(d, [], { all: true }).files?.length === 3, 'not all')
check('--all with names refuses', Boolean(selectProofs(d, ['a'], { all: true }).error), 'accepted')
check('a filter picks by substring, in discovery order', JSON.stringify(selectProofs(d, ['b']).files) === JSON.stringify([d[1], d[2]]), JSON.stringify(selectProofs(d, ['b'])))
check('a filter matching nothing refuses', /matches none/.test(selectProofs(d, ['zz']).error), 'accepted')
check('an exact path picks it', JSON.stringify(selectProofs(d, [d[0]]).files) === JSON.stringify([d[0]]), 'path ignored')
check('a path outside the proofs refuses', /not a proof/.test(selectProofs(d, ['tests/e2e/x.test.mjs']).error), 'accepted')

// --- the target guard --------------------------------------------------------------
const B = 'https://example.net'
check('no ENV refuses', /ENV must be/.test(guardTarget({ BASE_URL: B }).error), 'accepted')
check('no BASE_URL refuses (no default)', /BASE_URL must be set/.test(guardTarget({ ENV: 'dev' }).error), 'accepted')
check('dev keeps the proofs\' own TENANT default', guardTarget({ ENV: 'dev', BASE_URL: `${B}/` }).tenant === '' && guardTarget({ ENV: 'dev', BASE_URL: `${B}/` }).base === B, 'changed')
check('prd without LIVE_PROOF_PRD_GO=1 refuses', /opt-in/.test(guardTarget({ ENV: 'prd', BASE_URL: B }).error), 'accepted')
const go = { ENV: 'prd', BASE_URL: B, LIVE_PROOF_PRD_GO: '1' }
check('prd defaults TENANT to e2e', guardTarget(go).tenant === 'e2e', JSON.stringify(guardTarget(go)))
check('prd takes e2e-<x>', guardTarget({ ...go, TENANT: 'e2e-2' }).tenant === 'e2e-2', 'refused')
for (const t of ['t1', 'acme', 'e2ex', 'E2E']) check(`prd refuses TENANT=${t}`, /test workspace only/.test(guardTarget({ ...go, TENANT: t }).error || ''), 'accepted')
check('prd refuses a t1 host', /names workspace 't1'/.test(guardTarget({ ...go, BASE_URL: 'https://t1.example.net' }).error || ''), 'accepted')
check('prd takes an e2e host', !guardTarget({ ...go, BASE_URL: 'https://e2e.example.net' }).error, 'refused')
check('prd with BASE_DOMAIN takes the apex', !guardTarget({ ...go, BASE_URL: 'https://app.example.co.uk', BASE_DOMAIN: 'app.example.co.uk' }).error, 'refused')
check('prd with BASE_DOMAIN refuses a customer label', /names workspace 'acme'/.test(guardTarget({ ...go, BASE_URL: 'https://acme.example.net', BASE_DOMAIN: 'example.net' }).error || ''), 'accepted')
check('prd with BASE_DOMAIN refuses another domain', /not under BASE_DOMAIN/.test(guardTarget({ ...go, BASE_URL: 'https://e2e.other.org', BASE_DOMAIN: 'example.net' }).error || ''), 'accepted')

// --- the runner refuses before any proof runs --------------------------------------
const cli = (env, ...args) => spawnSync(process.execPath, [RUNNER, ...args], { cwd: WUI, encoding: 'utf8', env: { PATH: process.env.PATH, ...env } })
let r = cli({ ENV: 'prd', BASE_URL: B }, 'p2-smoke')
check('cli: prd without go exits 2', r.status === 2 && /opt-in/.test(r.stderr) && !/──\[/.test(r.stdout), `status ${r.status} ${r.stderr}`)
r = cli({ ENV: 'prd', BASE_URL: B, LIVE_PROOF_PRD_GO: '1', TENANT: 't1' }, 'p2-smoke')
check('cli: prd TENANT=t1 exits 2', r.status === 2 && /test workspace only/.test(r.stderr), `status ${r.status}`)
r = cli({ ENV: 'dev', BASE_URL: B })
check('cli: no pick exits 2', r.status === 2 && /nothing picked/.test(r.stderr), `status ${r.status}`)

// --- package.json carries the one script ---------------------------------------------
const scripts = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8')).scripts ?? {}
check('scripts.test:live:proofs is the picker', scripts['test:live:proofs'] === 'node src/node/test/run-live-proofs.mjs', `got: ${scripts['test:live:proofs']}`)

if (failed) { console.log(`\nlive-proof-runner: ${failed} FAILED`); process.exit(1) }
console.log('\nlive-proof-runner: all passed')
