// Spec 072 A3: the WUI reads its env values from a served /config.json.
// This suite runs the merge rules, the exact inline head script nuxt.config
// embeds (against a fake window), the compose container's start script, and
// static guards on the wiring and the A3 acceptance greps. The browser half
// (one bundle, two config.json files, two api hosts) is
// tests/e2e/runtime-config.proof.mjs.
// Run: node tests/unit/runtime-config.test.mjs
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import vm from 'node:vm'
import {
  applyRuntimeConfig, buildEarlyConfigScript, defaultApiBase, EARLY_CONFIG_KEY, readConfigResponse,
  RUNTIME_CONFIG_KEYS, RUNTIME_CONFIG_PATH, takeParkedConfig,
} from '../../src/utils/runtime-config.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const REPO = join(WUI, '..')
let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }
const eq = (got, want, n) => {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  return g === w ? pass(n) : fail(n, `got ${g}, want ${w}`)
}
const read = (rel) => readFileSync(join(REPO, rel), 'utf8')

// ── merge rules ──────────────────────────────────────────────────────────
{
  const pub = { apiBase: 'http://{tenant}.localhost:58080', tenant: 't1', appVersion: 'v1.2.3', useMock: '0' }
  const r = applyRuntimeConfig(pub, {
    apiBase: 'https://api.example.org/', tenant: 'main', appVersion: 'v9.9.9', useMock: '1', unknown: 'x',
  })
  eq(pub.apiBase, 'https://api.example.org', 'the file sets the api base (trailing slash dropped)')
  eq(pub.tenant, 'main', 'and the tenant')
  eq(pub.appVersion, 'v1.2.3', 'never the build version')
  eq(pub.useMock, '0', 'never the mock switch')
  eq(r.applied, ['apiBase', 'tenant'], 'applied names only the allowed keys')
}
{
  const pub = { apiBase: 'https://baked.example.org', authBase: '', tenantHosts: '0', perfRum: '0' }
  const r = applyRuntimeConfig(pub, {
    apiBase: 'javascript:alert(1)', authBase: 'https://auth.example.org', tenantHosts: true, perfRum: 'yes',
  })
  eq(pub.apiBase, 'https://baked.example.org', 'a non-http base keeps the baked one')
  eq(pub.authBase, 'https://auth.example.org', 'a good key beside a bad one still applies')
  eq(pub.tenantHosts, '1', 'a boolean flag reads as "1"')
  eq(pub.perfRum, '0', 'an unknown flag value keeps the baked one')
  eq(r.rejected, ['apiBase', 'perfRum'], 'rejected names the skipped keys')
}
{
  const pub = { apiBase: 'https://baked.example.org' }
  eq(applyRuntimeConfig(pub, null).applied, [], 'no file: nothing applied')
  eq(applyRuntimeConfig(pub, ['x']).applied, [], 'an array is not a config')
  eq(pub.apiBase, 'https://baked.example.org', 'and the baked config stays')
  eq(applyRuntimeConfig(pub, { tenant: 'a"b' }).rejected, ['tenant'], 'a quote in a text value is refused')
  eq(applyRuntimeConfig(pub, { apiBase: 'http://{tenant}.localhost:58080' }).applied, ['apiBase'], 'the lde {tenant} template is a legal base')
}
eq(Object.keys(RUNTIME_CONFIG_KEYS).includes('defaultLocale'), false, 'the default locale stays a build value (it shapes the routes)')

{
  const pub = { apiBase: '' }
  defaultApiBase(pub, 'https://chat.example.org')
  eq(pub.apiBase, 'https://chat.example.org', 'no api base anywhere: the page origin (compose: the hub is behind the same Caddy)')
  const set = { apiBase: 'https://api.example.org' }
  defaultApiBase(set, 'https://chat.example.org')
  eq(set.apiBase, 'https://api.example.org', 'a named api base is kept')
  const odd = { apiBase: '' }
  defaultApiBase(odd, 'null')
  eq(odd.apiBase, '', 'an opaque origin is not a base')
}

// ── responses ────────────────────────────────────────────────────────────
eq(await readConfigResponse({ ok: false, json: async () => ({ a: 1 }) }), null, 'a 404 reads as no file')
eq(await readConfigResponse({ ok: true, json: async () => { throw new SyntaxError('<!doctype') } }), null, 'the SPA fallback (HTML, status 200) reads as no file')
eq(await readConfigResponse({ ok: true, json: async () => ({ tenant: 'main' }) }), { tenant: 'main' }, 'a JSON object is the config')
eq(await readConfigResponse(undefined), null, 'no response: no file')

// ── the inline head script ───────────────────────────────────────────────
function run(script, fetchImpl) {
  const calls = []
  const win = {}
  win.window = win
  win.Array = Array
  win.fetch = fetchImpl ? (u, init) => { calls.push({ u, init }); return fetchImpl(u, init) } : undefined
  vm.runInNewContext(script, win)
  return { win, calls }
}
const res = (ok, body) => ({ ok, json: async () => body })
{
  const { win, calls } = run(buildEarlyConfigScript(), async () => res(true, { apiBase: 'https://api.a.example.org' }))
  eq(calls.length, 1, 'the head script fetches once')
  eq(calls[0].u, RUNTIME_CONFIG_PATH, 'the served /config.json')
  eq(calls[0].init.cache, 'no-cache', 'revalidated: a domain change reaches the next load')
  eq(typeof win[EARLY_CONFIG_KEY]?.then, 'function', 'and parks the promise')
  let own = 0
  const got = await takeParkedConfig(win, async () => { own++; return res(true, {}) })
  eq(got, { apiBase: 'https://api.a.example.org' }, 'the plugin adopts the parked body')
  eq(own, 0, 'without a second request')
  eq(win[EARLY_CONFIG_KEY], undefined, 'taken once')
}
{
  const { win } = run(buildEarlyConfigScript(), async () => res(false, null))
  eq(await takeParkedConfig(win, undefined), null, 'a 404 parks null')
}
{
  const { win } = run(buildEarlyConfigScript(), async () => { throw new TypeError('offline') })
  eq(await takeParkedConfig(win, undefined), null, 'a network error parks null, never a rejection')
}
{
  const { win, calls } = run(buildEarlyConfigScript(), undefined)
  eq(calls.length, 0, 'no fetch in the browser: the script does nothing')
  const got = await takeParkedConfig(win, async (u) => res(true, { tenant: u === RUNTIME_CONFIG_PATH ? 'own' : 'x' }))
  eq(got, { tenant: 'own' }, 'nothing parked: the plugin fetches /config.json itself')
}

// ── the compose container's start script ─────────────────────────────────
const SCRIPT = join(WUI, 'src/docker/wui-config.sh')
const sh = spawnSync('sh', ['-c', 'command -v sh'], { encoding: 'utf8' })
if (sh.status !== 0) {
  fail('wui-config.sh', 'no sh on this machine')
} else {
  const dir = mkdtempSync(join(tmpdir(), 'wui-config-'))
  const out = join(dir, 'config.json')
  const start = (env, args = []) => spawnSync('sh', [SCRIPT, ...args], {
    encoding: 'utf8', env: { PATH: process.env.PATH, WUI_CONFIG_OUT: out, ...env },
  })
  try {
    let r = start({})
    eq(r.status, 0, 'wui-config.sh: no env at all is a valid start')
    eq(JSON.parse(readFileSync(out, 'utf8')), {
      apiBase: '', authBase: '', siteUrl: '', tenant: 'main', lobbyTaskId: '', envName: '',
    }, 'and writes the same-origin defaults')

    r = start({ SPOOL_PUBLIC_URL: 'https://chat.example.org//', SPOOL_TENANT: 'acme', SPOOL_LOBBY_TASK_ID: '00000000-0000-4000-8000-000000000001', SPOOL_ENV_NAME: 'dev' })
    const cfg = JSON.parse(readFileSync(out, 'utf8'))
    eq([cfg.apiBase, cfg.siteUrl, cfg.tenant, cfg.envName], ['https://chat.example.org', 'https://chat.example.org', 'acme', 'dev'], 'the env values reach config.json')
    const pub = { apiBase: '' }
    eq(applyRuntimeConfig(pub, cfg).rejected, [], 'and every one passes the page\'s own merge rules')

    r = start({ SPOOL_PUBLIC_URL: 'http://localhost:8080' })
    eq(JSON.parse(readFileSync(out, 'utf8')).siteUrl, '', 'a plain-http URL is no site URL (tenant hosts are https)')

    r = start({ SPOOL_PUBLIC_URL: 'chat.example.org' })
    eq(r.status !== 0 && /SPOOL_PUBLIC_URL/.test(r.stderr), true, 'a URL with no scheme fails, naming the variable')
    r = start({ SPOOL_TENANT: 'a"b' })
    eq(r.status !== 0 && /SPOOL_TENANT/.test(r.stderr), true, 'a quote fails, naming the variable')

    r = start({}, ['sh', '-c', 'echo ran-$0', 'caddy'])
    eq(r.status === 0 && /ran-caddy/.test(r.stdout), true, 'then it execs the command it was given (Caddy)')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// ── wiring and the A3 acceptance greps ───────────────────────────────────
const dockerfile = read('csi-spl-wui/src/docker/wui.Dockerfile')
const wf30 = read('.github/workflows/30_wui-build-deploy.yml')
const nuxtConfig = read('csi-spl-wui/nuxt.config.ts')
const plugin = read('csi-spl-wui/src/plugins/0.0.runtime-config.client.ts')
const count = (s, needle) => s.split(needle).length - 1
eq(count(dockerfile, 'ARG SPOOL_PUBLIC_URL'), 0, "A3: grep -c 'ARG SPOOL_PUBLIC_URL' wui.Dockerfile -> 0")
eq(count(wf30, 'NUXT_PUBLIC_API_BASE'), 0, 'A3: grep -c NUXT_PUBLIC_API_BASE 30_wui-build-deploy.yml -> 0')
eq(/NUXT_PUBLIC_(API_BASE|TENANT|LOBBY_TASK_ID)=/.test(dockerfile), false, 'the image build bakes no api base, tenant or lobby')
eq(/ENTRYPOINT \["\/usr\/local\/bin\/wui-config\.sh"\]/.test(dockerfile), true, 'the image writes config.json at start')
eq(/config\.json/.test(wf30) && /\.output\/public\/config\.json/.test(wf30), true, 'wf 30 writes config.json into the deployed bundle')
eq(/csi-spl-cnf/.test(nuxtConfig), false, 'the build reads no cnf path (research 06 W8)')
eq(/isDev \? "http:\/\/\{tenant\}\.localhost:58080" : ""/.test(nuxtConfig), true, 'a production build never bakes the lde localhost api base')
eq(/buildEarlyConfigScript\(\)/.test(nuxtConfig), true, 'the head carries the early config fetch')
eq(/order: -30/.test(plugin), true, 'the plugin runs before every pre plugin (the early session probe)')

if (failed) {
  console.log(`\n${failed} failed`)
  process.exit(1)
}
console.log('\nruntime-config: all passed')
