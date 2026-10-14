// Guards the live interop test's target and session (SPL-1782, devops guide
// section 16, gap T5): door off stays the lde default, dev / prd run with a
// test workspace session, and ENV=prd is an opt-in that never writes in t1 or
// a customer workspace.
//
// Run: node tests/unit/live-interop-target.test.mjs
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import {
  interopTarget, cookiePair, sessionFromSetCookie, sessionTenantRefusal, openSession, readSecretFile, cookieFetch,
} from '../../src/node/test/live-interop-target.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')

let failed = 0
const check = (n, ok, m) => { if (ok) console.log(`  OK   ${n}`); else { failed++; console.log(`  FAIL ${n}: ${m}`) } }

console.log('live-interop-target (gap T5: interop with a test workspace session)')

// --- the target ------------------------------------------------------------------
const HUB = 'https://api.example.com'
const lde = interopTarget({ HUB_URL: 'http://t1.localhost:58080/' })
check('no session env = door off (lde)', lde.door === 'off' && lde.hub === 'http://t1.localhost:58080', JSON.stringify(lde))
check('no HUB_URL refuses', /HUB_URL/.test(interopTarget({}).error), 'accepted')
check('a non-http HUB_URL refuses', Boolean(interopTarget({ HUB_URL: 'ftp://x' }).error), 'accepted')
check('ENV other than dev/prd refuses', Boolean(interopTarget({ HUB_URL: HUB, ENV: 'stg' }).error), 'accepted')
check('EMAIL without PW_FILE refuses', /PW_FILE/.test(interopTarget({ HUB_URL: HUB, EMAIL: 'a@example.com' }).error), 'accepted')
check('cookie file and EMAIL together refuse', Boolean(interopTarget({ HUB_URL: HUB, SESSION_COOKIE_FILE: 'f', EMAIL: 'e', PW_FILE: 'p' }).error), 'accepted')
check('dev with a cookie file = session', interopTarget({ HUB_URL: HUB, ENV: 'dev', SESSION_COOKIE_FILE: 'f' }).door === 'session', 'not session')
const prd = { HUB_URL: HUB, ENV: 'prd', SESSION_COOKIE_FILE: 'f' }
check('prd without LIVE_INTEROP_PRD_GO refuses', /LIVE_INTEROP_PRD_GO=1/.test(interopTarget(prd).error), 'accepted')
check('prd with the door off refuses', /session/.test(interopTarget({ HUB_URL: HUB, ENV: 'prd', LIVE_INTEROP_PRD_GO: '1' }).error), 'accepted')
check('prd TENANT defaults to e2e', interopTarget({ ...prd, LIVE_INTEROP_PRD_GO: '1' }).tenant === 'e2e', 'not e2e')
check('prd TENANT=e2e-2 passes', interopTarget({ ...prd, LIVE_INTEROP_PRD_GO: '1', TENANT: 'e2e-2' }).tenant === 'e2e-2', 'refused')
for (const t of ['t1', 'acme', 'e2e_x', 'xe2e'])
  check(`prd TENANT=${t} refuses`, /test workspace/.test(interopTarget({ ...prd, LIVE_INTEROP_PRD_GO: '1', TENANT: t }).error), 'accepted')

// --- the cookie ------------------------------------------------------------------
check('cookie pair reads name=value', cookiePair(' spool_session_dev=abc.def\n') === 'spool_session_dev=abc.def', 'wrong pair')
check('cookie pair takes a pasted Cookie: header', cookiePair('Cookie: spool_session=x') === 'spool_session=x', 'refused')
let threw = false
try { cookiePair('just-a-value') } catch { threw = true }
check('a bare value refuses (the cookie name differs per env)', threw, 'accepted')
check('Set-Cookie picks spool_session*', sessionFromSetCookie(['a=1; Path=/', 'spool_session_dev=v1; HttpOnly']) === 'spool_session_dev=v1', 'missed')
check('an emptied spool_session is no session', sessionFromSetCookie(['spool_session=; Max-Age=0']) === '', 'took it')
threw = false
try { readSecretFile('f', { stat: () => ({ mode: 0o100644 }), read: () => 'x' }) } catch { threw = true }
check('a 0644 credential file refuses', threw, 'read it')
check('a 0600 credential file reads', readSecretFile('f', { stat: () => ({ mode: 0o100600 }), read: () => 'pw\n' }) === 'pw', 'refused')

// --- the session's workspace -------------------------------------------------------
const tPrd = { env: 'prd', tenant: 'e2e' }
check('no member refuses', /no member/.test(sessionTenantRefusal(tPrd, { t: 'e2e' })), 'accepted')
check('prd session in e2e passes', sessionTenantRefusal(tPrd, { hum: 'HUM-9', t: 'e2e' }) === '', 'refused')
check('prd session in t1 refuses', /not a test workspace/.test(sessionTenantRefusal(tPrd, { hum: 'HUM-9', t: 't1' })), 'accepted')
check('prd session in e2e-2 with TENANT=e2e refuses', /TENANT is 'e2e'/.test(sessionTenantRefusal(tPrd, { hum: 'HUM-9', t: 'e2e-2' })), 'accepted')
check('dev session in any workspace passes', sessionTenantRefusal({ env: 'dev', tenant: '' }, { hum: 'HUM-9', t: 't1' }) === '', 'refused')

// --- openSession against a stub hub ------------------------------------------------
function stubHub(sess, { loginStatus = 200 } = {}) {
  const calls = []
  const fetchFn = async (url, init = {}) => {
    calls.push({ url, init })
    if (url.endsWith('/api/v1/auth/login')) {
      const headers = new Headers()
      if (loginStatus === 200) headers.append('set-cookie', 'spool_session=s3cr3t; HttpOnly; Path=/')
      return new Response('{}', { status: loginStatus, headers })
    }
    if (url.endsWith('/api/v1/auth/session')) return new Response(JSON.stringify(sess), { status: init.headers?.cookie ? 200 : 401 })
    return new Response('', { status: 404 })
  }
  return { calls, fetchFn }
}
const read = (p) => (p === 'pw' ? 'hunter2' : 'spool_session=fromfile')
{
  const h = stubHub({ hum: 'HUM-9', t: 'e2e' })
  const s = await openSession({ env: 'prd', hub: HUB, tenant: 'e2e' }, { EMAIL: 'p@example.com', PW_FILE: 'pw' }, { fetchFn: h.fetchFn, readSecret: read })
  const login = JSON.parse(h.calls[0].init.body)
  check('sign-in posts email, password and TENANT', login.email === 'p@example.com' && login.password === 'hunter2' && login.tenant === 'e2e', JSON.stringify(login))
  check('sign-in keeps the session cookie', s.cookie === 'spool_session=s3cr3t' && s.hum === 'HUM-9' && s.tenant === 'e2e', JSON.stringify(s))
  check('the session read carries the cookie', h.calls[1].init.headers.cookie === 'spool_session=s3cr3t', 'no cookie')
}
{
  const h = stubHub({ hum: 'HUM-9', t: 't1' })
  let msg = ''
  try { await openSession({ env: 'prd', hub: HUB, tenant: 'e2e' }, { SESSION_COOKIE_FILE: 'c' }, { fetchFn: h.fetchFn, readSecret: read }) } catch (e) { msg = e.message }
  check('a prd cookie bound to t1 refuses before any socket', /not a test workspace/.test(msg), msg || 'accepted')
  check('the cookie file is sent as is', h.calls[0].init.headers.cookie === 'spool_session=fromfile', JSON.stringify(h.calls[0]))
}
{
  const h = stubHub({}, { loginStatus: 401 })
  let msg = ''
  try { await openSession({ env: 'dev', hub: HUB, tenant: '' }, { EMAIL: 'e', PW_FILE: 'pw' }, { fetchFn: h.fetchFn, readSecret: read }) } catch (e) { msg = e.message }
  check('a refused sign-in says so, without the password', /401/.test(msg) && !msg.includes('hunter2'), msg || 'accepted')
}
{
  let seen = null
  await cookieFetch('spool_session=z', async (u, i) => { seen = i; return new Response('') })('https://x/', { headers: { accept: 'a' } })
  check('cookieFetch adds the cookie and keeps the headers', seen.headers.cookie === 'spool_session=z' && seen.headers.accept === 'a', JSON.stringify(seen))
}

// --- the test file refuses before it dials ----------------------------------------
const run = (env) => spawnSync(process.execPath, ['--experimental-websocket', 'tests/e2e/live-interop.test.mjs'], {
  cwd: WUI, encoding: 'utf8', env: { PATH: process.env.PATH, ...env }, timeout: 20000,
})
const r1 = run({ HUB_URL: HUB, ENV: 'prd', SESSION_COOKIE_FILE: '/nonexistent' })
check('interop test: prd without the go exits 2', r1.status === 2 && /LIVE_INTEROP_PRD_GO/.test(r1.stderr), `${r1.status} ${r1.stderr}`)
const r2 = run({ HUB_URL: HUB, ENV: 'prd', LIVE_INTEROP_PRD_GO: '1', TENANT: 't1', SESSION_COOKIE_FILE: '/nonexistent' })
check('interop test: prd TENANT=t1 exits 2', r2.status === 2 && /test workspace/.test(r2.stderr), `${r2.status} ${r2.stderr}`)
const r3 = run({})
check('interop test: no HUB_URL still skips', r3.status === 0 && /SKIP/.test(r3.stdout), `${r3.status} ${r3.stdout}`)

console.log(failed ? `\n${failed} failed` : '\nall passed')
process.exit(failed ? 1 : 0)
