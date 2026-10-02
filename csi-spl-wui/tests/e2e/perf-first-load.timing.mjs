// CLE-77934 (owner topic 87eaa57b, 2026-10-02: "investigate whether or not
// something else could be decreased as well"; method from 73c9704c: before /
// after with empiric evidence). The repeatable RUNTIME timing e2e of the WUI's
// first load against a DEPLOYED host: what the main thread does between the
// first byte and an interactive rail with the Flow list painted. Read-only: it
// clicks and reads, it never posts. CLE-77914's perf-flow-events.timing.mjs
// times later clicks; this one times the load itself.
//
// ONE native sign-in (USER_DATA_DIR keeps the session between runs), then per
// PROFILE one discarded warm-up tab and N rounds, each in a FRESH tab (so the
// CDP counters start at 0):
//
//   rail        navigation start -> the rail's Flow tab visible.
//   flow        the Flow tab clicked the moment it shows -> the first Flow entry
//               painted, measured from navigation start (rail + the click's work).
//   home        (desktop) navigation start -> the first topic row of / painted.
//   tbtRail     total blocking time (sum of long-task ms over 50) before rail.
//   tbt         ... until 2.5 s after the Flow list (the load's whole tail).
//   longN       long tasks (>= 50 ms) in that window; longMax the biggest.
//   scriptMs    CDP Performance ScriptDuration: JS compile + execute.
//   layoutMs    LayoutDuration + RecalcStyleDuration.
//   taskMs      TaskDuration: every main-thread task.
//   wsNew/wsOpen/wsMsg  the hub socket: constructed / open / first frame (ms).
//   nodes, heapMB  DOM nodes and JS heap once settled.
//
// Profiles: d1440 = 1440x900 desktop; m390 = 390x844 phone (touch, CPU 4x, the
// "mid phone"). COLD_CACHE=1 clears the HTTP cache before each round (default
// warm: the bytes are CLE-77933's network lane, the CPU is this one's).
// CPU_PROFILE=1 adds one extra, untimed round per profile under the V8
// sampling profiler and prints self time per script and the top functions.
// TRACE=1 adds one extra, untimed round per profile under a Chrome trace and
// prints the renderer main thread's self ms per event type (EvaluateScript,
// v8 compile, style recalc, Layout, Paint, GC, ...) before rail, rail -> Flow
// and the 2.5 s after: what the long tasks are made of.
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [N=10] [PROFILES=d1440,m390] [COLD_CACHE=0] [CPU_PROFILE=0] \
//     [USER_DATA_DIR=<dir>] [LOCAL_MAP=127.0.0.1:8443] [CHROME_PATH=...] \
//     [LOCAL_MAP_B=127.0.0.1:8444 USER_DATA_DIR_B=<dir>] \
//     [PUPPETEER_CORE=<path>] node tests/e2e/perf-first-load.timing.mjs
//
// A/B without deploying: generate both bundles with the env's NUXT_PUBLIC_*
// values, serve each with tests/e2e/lib/serve-hosting-h2.mjs, and set LOCAL_MAP
// (A) and LOCAL_MAP_B (B): the rounds interleave A,B / B,A in one run, so a
// loaded box slows both alike, and the table has a column per variant.
//
// The action csi-spl-orc `do_spl_wui_perf_first_load` runs it per env. The
// password is read from PW_FILE and never printed. Output: OUT/first-load.json
// (every sample) and a median / p90 markdown table on stdout. Exit 0 unless
// the sign-in fails (a measurement, not a gate).
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
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const N = Number(process.env.N || 10)
const COLD_CACHE = process.env.COLD_CACHE === '1'
const CPU_PROFILE = process.env.CPU_PROFILE === '1'
const TRACE = process.env.TRACE === '1'
const PROFILES = (process.env.PROFILES || 'd1440,m390').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const PROFILE = {
  d1440: { vp: { width: 1440, height: 900 }, cpu: 1, home: true },
  m390: { vp: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 }, cpu: 4, home: false },
}
const KEYS = ['rail', 'flow', 'home', 'tbtRail', 'tbt', 'longN', 'longMax', 'scriptMs', 'layoutMs', 'taskMs', 'wsNew', 'wsOpen', 'wsMsg', 'nodes', 'heapMB']

const FLOW_TAB = '[data-testid=sidebar-tab-flow]'
const FLOW_ENTRY = '[data-testid=sidebar-panel-flow] [data-testid=left-entry]'
const HOME_ROW = 'a.topic-row'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Installed before any page script: long tasks and the hub socket's timeline. */
function instrument() {
  window.__rtLong = []
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) window.__rtLong.push({ start: e.startTime, dur: e.duration })
    }).observe({ type: 'longtask', buffered: true })
  } catch { /* unsupported */ }
  window.__rtWs = {}
  const Native = window.WebSocket
  if (!Native) return
  window.WebSocket = class extends Native {
    constructor(...a) {
      super(...a)
      const w = window.__rtWs
      if (!w.new) {
        w.new = performance.now()
        this.addEventListener('open', () => { w.open ??= performance.now() })
        this.addEventListener('message', () => { w.msg ??= performance.now() })
      }
    }
  }
}

/** performance.now() once a VISIBLE element matches `sel`; -1 on timeout. */
const whenSel = (p, sel, timeout = 30000) => p.waitForFunction((s) => {
  for (const el of document.querySelectorAll(s)) {
    const r = el.getBoundingClientRect()
    if (r.width > 0 && r.height > 0) return performance.now()
  }
  return 0
}, { timeout, polling: 'raf' }, sel).then((h) => h.jsonValue()).catch(() => -1)
const clickAt = (p, sel) => p.evaluate((s) => {
  const el = [...document.querySelectorAll(s)].find((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 })
  if (!el) return -1
  el.click()
  return performance.now()
}, sel)

async function round(ctx, prof, profile, trace = false) {
  const p = await ctx.newPage()
  try {
    await p.setViewport(prof.vp)
    await p.evaluateOnNewDocument(instrument)
    const cdp = await p.createCDPSession()
    await cdp.send('Performance.enable', { timeDomain: 'timeTicks' })
    await cdp.send('Network.enable')
    if (COLD_CACHE) await cdp.send('Network.clearBrowserCache')
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: prof.cpu })
    if (trace) await p.tracing.start({ categories: TRACE_CATEGORIES })
    if (profile) { await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 200 }); await cdp.send('Profiler.start') }
    await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 90000 })
    const rail = await whenSel(p, FLOW_TAB, 45000)
    if (rail < 0) throw new Error('no Flow rail tab at ' + p.url())
    const home = prof.home ? whenSel(p, HOME_ROW, 20000) : Promise.resolve(-1)
    const clicked = await clickAt(p, FLOW_TAB)
    const flow = clicked < 0 ? -1 : await whenSel(p, FLOW_ENTRY)
    const homeAt = await home
    await sleep(2500)
    const cpuProfile = profile ? (await cdp.send('Profiler.stop')).profile : null
    const traceSummary = trace ? mainThreadSelf(JSON.parse(new TextDecoder().decode(await p.tracing.stop())), BASE, rail, flow) : null
    const end = (flow > 0 ? flow : rail) + 2500
    const page = await p.evaluate((rail, end) => {
      const lt = (window.__rtLong || []).filter((e) => e.start < end)
      const tbt = (xs) => Math.round(xs.reduce((a, e) => a + Math.max(0, e.dur - 50), 0))
      const w = window.__rtWs || {}
      return {
        tbtRail: tbt(lt.filter((e) => e.start < rail)),
        tbt: tbt(lt),
        longN: lt.length,
        longMax: Math.round(lt.reduce((a, e) => Math.max(a, e.dur), 0)),
        long: lt.map((e) => `${Math.round(e.start)}+${Math.round(e.dur)}`),
        wsNew: Math.round(w.new ?? -1), wsOpen: Math.round(w.open ?? -1), wsMsg: Math.round(w.msg ?? -1),
        nodes: document.getElementsByTagName('*').length,
      }
    }, rail, end)
    const m = Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map((x) => [x.name, x.value]))
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 })
    return {
      sample: {
        rail: Math.round(rail), flow: Math.round(flow), home: Math.round(homeAt), ...page,
        scriptMs: Math.round((m.ScriptDuration || 0) * 1000),
        layoutMs: Math.round(((m.LayoutDuration || 0) + (m.RecalcStyleDuration || 0)) * 1000),
        taskMs: Math.round((m.TaskDuration || 0) * 1000),
        heapMB: Math.round((m.JSHeapUsedSize || 0) / 104857.6) / 10,
      },
      cpuProfile,
      traceSummary,
    }
  } finally {
    await p.close().catch(() => {})
  }
}

/** Self time per script and per function from a V8 sampling profile (ms, throttled clock). */
function attribute(prof) {
  const byId = new Map(prof.nodes.map((n) => [n.id, n]))
  const self = new Map()
  for (let i = 0; i < prof.samples.length; i++) {
    const dt = (prof.timeDeltas[i + 1] ?? 0) / 1000
    self.set(prof.samples[i], (self.get(prof.samples[i]) || 0) + dt)
  }
  const perScript = {}, perFn = {}
  for (const [id, ms] of self) {
    const f = byId.get(id).callFrame
    const script = f.url ? f.url.replace(/^https?:\/\/[^/]+/, '') : `(${f.functionName || 'native'})`
    perScript[script] = (perScript[script] || 0) + ms
    if (f.url) {
      const k = `${f.functionName || '(anon)'} ${script}:${f.lineNumber + 1}:${f.columnNumber + 1}`
      perFn[k] = (perFn[k] || 0) + ms
    }
  }
  const top = (o, n) => Object.entries(o).sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => [k, Math.round(v * 10) / 10])
  return { perScript: top(perScript, 25), perFn: top(perFn, 40) }
}

const TRACE_CATEGORIES = ['toplevel', 'devtools.timeline', 'disabled-by-default-devtools.timeline', 'v8', 'v8.execute', 'disabled-by-default-v8.compile', 'blink.user_timing', 'loading']
/** Event names folded into one row of the trace table. */
const TRACE_KIND = {
  EvaluateScript: 'script: evaluate', FunctionCall: 'script: call', TimerFire: 'script: timer', FireAnimationFrame: 'script: rAF',
  EventDispatch: 'script: event', RunMicrotasks: 'script: microtasks', 'v8.run': 'script: v8.run', V8Execute: 'script: v8.run',
  'v8.compile': 'compile', 'v8.compileModule': 'compile', 'v8.parseOnBackground': 'compile', 'V8.CompileCode': 'compile', CompileScript: 'compile', CompileModule: 'compile',
  'v8.evaluateModule': 'script: evaluate', 'v8.callFunction': 'script: call', 'v8.newInstance': 'script: call', 'v8.produceModuleCache': 'compile',
  'V8.DeoptimizeCode': 'compile', ParseHTML: 'parse html', ParseAuthorStyleSheet: 'parse css',
  UpdateLayoutTree: 'style', RecalculateStyles: 'style', Layout: 'layout', PrePaint: 'paint', Paint: 'paint', Layerize: 'paint',
  UpdateLayerTree: 'paint', 'Document::updateStyleAndLayout': 'style+layout (forced)',
  MinorGC: 'gc', MajorGC: 'gc', 'V8.GCScavenger': 'gc', 'V8.GCFinalizeMC': 'gc', 'V8.GC_MC_BACKGROUND_MARKING': 'gc', BlinkGC: 'gc',
}
/**
 * The page renderer's main-thread self time per kind (ms, at the profile's
 * CPU rate), split at rail and flow (performance.now() ms of the page).
 */
function mainThreadSelf(trace, base, rail, flow) {
  const ev = trace.traceEvents || trace
  const nav = ev.filter((e) => e.name === 'navigationStart' && String(e.args?.data?.documentLoaderURL || '').startsWith(base)).at(-1)
  if (!nav) return { error: 'no navigationStart for ' + base }
  const main = ev.find((e) => e.ph === 'M' && e.name === 'thread_name' && e.pid === nav.pid && e.args?.name === 'CrRendererMain')
  const tid = main ? main.tid : nav.tid
  const xs = ev.filter((e) => e.pid === nav.pid && e.tid === tid && e.ph === 'X' && e.dur > 0).sort((a, b) => a.ts - b.ts || b.dur - a.dur)
  const cut = [rail, flow > 0 ? flow : rail, (flow > 0 ? flow : rail) + 2500]
  const win = (t) => { const ms = (t - nav.ts) / 1000; return ms < cut[0] ? 'toRail' : ms < cut[1] ? 'toFlow' : ms < cut[2] ? 'after' : null }
  const out = { toRail: {}, toFlow: {}, after: {} }
  const stack = []
  const add = (e, self) => {
    const w = win(e.ts)
    if (!w || self <= 0) return
    const k = TRACE_KIND[e.name] || (/^V8\.GC/.test(e.name) ? 'gc' : /^(DocumentLoader|DecodedDataDocumentParser|HTMLDocumentParser)/.test(e.name) ? 'parse html' : e.name === 'RunTask' || e.name === 'ThreadControllerImpl::RunTask' ? 'other (task)' : 'other: ' + e.name)
    out[w][k] = (out[w][k] || 0) + self / 1000
  }
  for (const e of xs) {
    while (stack.length && stack.at(-1).end <= e.ts) { const d = stack.pop(); add(d.e, d.self) }
    const end = e.ts + e.dur
    if (stack.length && end <= stack.at(-1).end) stack.at(-1).self -= e.dur
    stack.push({ e, end, self: e.dur })
  }
  while (stack.length) { const d = stack.pop(); add(d.e, d.self) }
  for (const w of Object.keys(out)) {
    out[w] = Object.fromEntries(Object.entries(out[w]).sort((a, b) => b[1] - a[1]).filter(([, v]) => v >= 1).map(([k, v]) => [k, Math.round(v)]))
  }
  return out
}

const pct = (xs, q) => {
  const v = xs.filter((x) => typeof x === 'number' && x >= 0).sort((a, b) => a - b)
  if (!v.length) return null
  return v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)]
}

const puppeteer = await loadPuppeteer()
const LOCAL_MAP = process.env.LOCAL_MAP || ''
const LOCAL_MAP_B = process.env.LOCAL_MAP_B || ''
/** One headless Chrome; `map` resolves the BASE host to a local bundle server. */
async function openBrowser(map, udd) {
  const args = ['--no-sandbox']
  if (map) args.push(`--host-resolver-rules=MAP ${new URL(BASE).hostname} ${map}`, '--ignore-certificate-errors')
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args, ...(udd ? { userDataDir: udd } : {}) })
  const ctx = udd ? browser.defaultBrowserContext() : await browser.createBrowserContext()
  return { browser, ctx }
}
/** The kept session, else ONE native sign-in; 'kept' | 'native'. */
async function signIn(ctx) {
  const p = await ctx.newPage()
  try {
    await p.setViewport({ width: 1440, height: 900 })
    await p.goto(BASE + '/', { waitUntil: 'domcontentloaded', timeout: 60000 })
    const already = await p.waitForSelector('[data-test=user-menu-trigger], [data-test=native-auth-email]', { timeout: 45000 })
      .then((h) => h.evaluate((e) => e.matches('[data-test=user-menu-trigger]'))).catch(() => false)
    if (!already) {
      await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2F', { waitUntil: 'domcontentloaded', timeout: 60000 })
      await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
      await p.type('[data-test=native-auth-email]', email)
      await p.type('[data-test=native-auth-password]', pw)
      await p.click('[data-test=native-auth-submit]')
      if (!(await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null))) throw new Error('sign-in failed at ' + p.url())
    }
    await sleep(1500)
    return already ? 'kept' : 'native'
  } finally {
    await p.close().catch(() => {})
  }
}

// LOCAL_MAP_B: an A/B of two local bundles in ONE run. Two browsers (A at
// LOCAL_MAP, B at LOCAL_MAP_B, USER_DATA_DIR_B for B's session), rounds
// interleaved A,B / B,A so a busy box slows both variants alike.
const variants = [{ tag: '', map: LOCAL_MAP, udd: process.env.USER_DATA_DIR }]
if (LOCAL_MAP_B) {
  variants[0].tag = ':A'
  variants.push({ tag: ':B', map: LOCAL_MAP_B, udd: process.env.USER_DATA_DIR_B })
}
const res = { base: BASE, tenant: TENANT, n: N, coldCache: COLD_CACHE, at: new Date().toISOString(), profiles: {}, cpu: {} }
let failed = false
try {
  res.build = LOCAL_MAP ? { local: variants.map((v) => v.map).join(' vs ') } : await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  res.signIn = []
  for (const v of variants) {
    Object.assign(v, await openBrowser(v.map, v.udd))
    res.signIn.push(await signIn(v.ctx))
  }
  for (const name of PROFILES) {
    const prof = PROFILE[name]
    if (!prof) { console.error('unknown profile', name); continue }
    // one discarded round each: the first tab of a profile pays Chrome's own warm-up
    for (const v of variants) await round(v.ctx, prof, false).catch(() => {})
    const samples = Object.fromEntries(variants.map((v) => [name + v.tag, []]))
    for (let i = 0; i < N; i++) {
      const order = i % 2 ? [...variants].reverse() : variants
      for (const v of order) {
        const xs = samples[name + v.tag]
        try { xs.push((await round(v.ctx, prof, false)).sample) } catch (e) { xs.push({ error: String(e?.message || e) }) }
        const s = xs.at(-1)
        console.log(name + v.tag, 'round', i, s.error ? 'ERROR ' + s.error : KEYS.map((k) => `${k}=${s[k]}`).join(' '))
      }
    }
    Object.assign(res.profiles, samples)
    if (TRACE) {
      res.trace ??= {}
      for (const v of variants) {
        const r = await round(v.ctx, prof, false, true).catch((e) => ({ traceSummary: { error: String(e?.message || e) } }))
        res.trace[name + v.tag] = r.traceSummary
      }
    }
    if (CPU_PROFILE) {
      for (const v of variants) {
        const r = await round(v.ctx, prof, true).catch((e) => ({ error: String(e?.message || e) }))
        if (r.cpuProfile) {
          writeFileSync(`${OUT}/${name}${v.tag.replace(':', '-')}.cpuprofile`, JSON.stringify(r.cpuProfile))
          res.cpu[name + v.tag] = attribute(r.cpuProfile)
        } else res.cpu[name + v.tag] = { error: r.error }
      }
    }
  }
} catch (e) {
  failed = true
  res.error = String((e && e.message) || e)
  console.log('FAIL', res.error)
} finally {
  for (const v of variants) await v.browser?.close().catch(() => {})
}

const summary = {}
for (const [name, samples] of Object.entries(res.profiles)) {
  summary[name] = {}
  for (const k of KEYS) {
    const xs = samples.map((s) => s[k])
    summary[name][k] = { median: pct(xs, 0.5), p90: pct(xs, 0.9), n: xs.filter((x) => typeof x === 'number' && x >= 0).length }
  }
}
res.summary = summary
writeFileSync(`${OUT}/first-load.json`, JSON.stringify(res, null, 1))
const b = res.build || {}
console.log(`build ${b.version || b.local || '?'} sha ${String(b.sha || b.commit || '?').slice(0, 8)} at ${BASE} cache=${COLD_CACHE ? 'cold' : 'warm'}`)
const names = Object.keys(summary)
console.log(`| metric | ${names.map((n) => `${n} median / p90 (n)`).join(' | ')} |`)
console.log(`|---|${names.map(() => '---|').join('')}`)
for (const k of KEYS) console.log(`| ${k} | ${names.map((n) => { const m = summary[n][k]; return m.median === null ? '-' : `${m.median} / ${m.p90} (${m.n})` }).join(' | ')} |`)
for (const [n, t] of Object.entries(res.trace || {})) {
  if (t.error) { console.log(`\n${n} trace: ERROR ${t.error}`); continue }
  console.log(`\n${n} main-thread self ms by kind (one traced round)`)
  const kinds = [...new Set(Object.values(t).flatMap((w) => Object.keys(w)))]
  console.log('| kind | to rail | rail -> flow | 2.5 s after |')
  console.log('|---|---|---|---|')
  for (const k of kinds) console.log(`| ${k} | ${t.toRail[k] ?? 0} | ${t.toFlow[k] ?? 0} | ${t.after[k] ?? 0} |`)
}
for (const [n, c] of Object.entries(res.cpu)) {
  if (c.error) { console.log(`\n${n} cpu profile: ERROR ${c.error}`); continue }
  console.log(`\n${n} self ms per script (one profiled round)`)
  for (const [k, v] of c.perScript) console.log(`  ${v}  ${k}`)
  console.log(`${n} top functions (self ms)`)
  for (const [k, v] of c.perFn) console.log(`  ${v}  ${k}`)
}
process.exit(failed ? 1 : 0)
