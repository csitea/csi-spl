// Guards the perf round 6 harness (row 12, SPL-2051): the seeded large tenant
// of src/node/test/perf-fixture.mjs and the pure parts of
// src/node/test/measure-wui-perf.mjs. The browser run itself needs a
// generated bundle and Chrome; this file needs neither.
//
//   1  the fixture has the plan's counts: 300 issue rows, 30 feed messages, 20 channels
//   2  it is deterministic: two builds are byte-equal (no clock, no random)
//   3  its storage keys are the mock's own hooks (utils/issues.mjs, utils/spool-client.mjs)
//   4  the channel patch extends MOCK_CHANNELS of the real mock-data.mjs
//      once, and REFUSES a chunk without the anchor (a renamed literal must
//      fail loudly, never measure the small tenant as the large one)
//   5  the runner's flags, median and table
//
// Run: node tests/unit/perf-fixture.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PERF_FIXTURE, perfChannels, perfMessages, perfStorage, patchMockChannels, isMockChannelsChunk, MOCK_CHANNELS_ANCHOR } from '../../src/node/test/perf-fixture.mjs'
import { parseArgs, median, metricsOf, renderTable, ROUTES } from '../../src/node/test/measure-wui-perf.mjs'
import { MOCK_ISSUES_SEED_KEY } from '../../src/utils/issues.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')

let failed = 0
const check = (n, ok, m) => { if (ok) console.log(`  OK   ${n}`); else { failed++; console.log(`  FAIL ${n}: ${m}`) } }

console.log('perf-fixture (perf round 6 row 12: seeded large tenant + runner)')

// --- 1 counts ---------------------------------------------------------------------
check('1 plan counts 300 / 30 / 20', PERF_FIXTURE.issues === 300 && PERF_FIXTURE.messages === 30 && PERF_FIXTURE.channels === 20, JSON.stringify(PERF_FIXTURE))
const msgs = perfMessages()
check('1 30 feed messages', msgs.length === 30, msgs.length)
check('1 20 channels, unique ids', new Set(perfChannels().map((c) => c.channel_id)).size === 20, perfChannels().length)
check('1 messages split over #lobby and #alerts', msgs.filter((m) => m.channel === 'lobby').length === 15 && msgs.filter((m) => m.channel === 'alerts').length === 15, 'uneven')
check('1 unique msg and task ids', new Set(msgs.map((m) => m.msg_id)).size === 30 && new Set(msgs.map((m) => m.task_id)).size === 30, 'duplicate id')
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/
check('1 ids are v4-shaped uuids', msgs.every((m) => UUID.test(m.msg_id) && UUID.test(m.task_id)), msgs[0].msg_id)
check('1 timestamps ascend', msgs.every((m, i) => !i || m.ts > msgs[i - 1].ts), 'out of order')

// --- 2 deterministic ---------------------------------------------------------------
check('2 two builds are byte-equal', JSON.stringify(perfStorage()) === JSON.stringify(perfStorage()), 'differ')

// --- 3 the mock's own hooks ---------------------------------------------------------
const st = perfStorage()
check('3 issues hook key is utils/issues.mjs MOCK_ISSUES_SEED_KEY', st[MOCK_ISSUES_SEED_KEY] === '300', JSON.stringify(Object.keys(st)))
const client = readFileSync(join(WUI, 'src/utils/spool-client.mjs'), 'utf8')
check('3 messages hook key is read by utils/spool-client.mjs', client.includes("'spool.mock.extra-messages'") && JSON.parse(st['spool.mock.extra-messages']).length === 30, 'hook gone')
const seedCap = /mockStoredCount\(MOCK_ISSUES_SEED_KEY, (\d+)\)/.exec(readFileSync(join(WUI, 'src/utils/issues.mjs'), 'utf8'))
check('3 the issues hook caps at or above 300', seedCap && Number(seedCap[1]) >= PERF_FIXTURE.issues, seedCap && seedCap[1])

// --- 4 the channel patch ------------------------------------------------------------
const mockSrc = readFileSync(join(WUI, 'src/utils/mock-data.mjs'), 'utf8')
const lastRow = /\{ channel_id: '(\w+)', name: '(\w+)', created_by: '(\w+)' \},\s*\]/.exec(mockSrc)
const minified = lastRow && `{channel_id:"${lastRow[1]}",name:"${lastRow[2]}",created_by:"${lastRow[3]}"}`
check('4 the anchor is the last MOCK_CHANNELS row of mock-data.mjs, minified', minified === MOCK_CHANNELS_ANCHOR, `${minified} vs ${MOCK_CHANNELS_ANCHOR}`)
const chunk = `const a=[{channel_id:"lobby",name:"lobby",created_by:"HUM-1"},${MOCK_CHANNELS_ANCHOR}],b=1;`
const patched = patchMockChannels(chunk)
const rows = JSON.parse(patched.slice(patched.indexOf('['), patched.indexOf(']') + 1).replace(/(\w+):/g, '"$1":'))
check('4 the patch appends 20 rows after the anchor', rows.length === 22 && rows[2].channel_id === 'perf-01' && rows[21].channel_id === 'perf-20', rows.length)
check('4 the rest of the chunk is untouched', patched.endsWith('],b=1;') && patched.startsWith('const a=['), patched.slice(-12))
check('4 isMockChannelsChunk finds it', isMockChannelsChunk(chunk) && !isMockChannelsChunk('const a=1'), 'wrong')
let refused = ''
try { patchMockChannels('const a=[{channel_id:"lobby"}]') } catch (e) { refused = e.message }
check('4 CONTROL: a chunk without the anchor is refused', /anchor found 0 times/.test(refused), refused || 'accepted')
refused = ''
try { patchMockChannels(chunk + chunk) } catch (e) { refused = e.message }
check('4 CONTROL: a chunk with the anchor twice is refused', /more than once/.test(refused), refused || 'accepted')

// --- 5 the runner -------------------------------------------------------------------
const def = parseArgs([])
check('5 defaults: n=3, both profiles, the plan routes, fixture on', def.n === 3 && def.profiles.join() === 'desktop,mobile' && def.routes === ROUTES && def.fixture, JSON.stringify(def))
const o = parseArgs(['--n', '5', '--routes', '/issues,/', '--profiles', 'mobile', '--no-fixture'])
check('5 flags parse', o.n === 5 && o.routes.join() === '/issues,/' && o.profiles.join() === 'mobile' && !o.fixture, JSON.stringify(o))
for (const bad of [['--n', '0'], ['--n'], ['--profiles', 'tablet'], ['--routes', 'issues'], ['--bogus']]) {
  let threw = false
  try { parseArgs(bad) } catch { threw = true }
  check(`5 refuses ${bad.join(' ')}`, threw, 'accepted')
}
check('5 median odd / even / NaN dropped', median([3, 1, 2]) === 2 && median([1, 2, 3, 5]) === 3 && median([NaN, 4]) === 4, 'wrong')
const m = metricsOf({ fp: 10.4, fcp: 100.2, lcp: 0, dom: 50, longtasks: [{ start: 120, duration: 80 }, { start: 300, duration: 40 }] }, { LayoutDuration: 0.0123, ScriptDuration: 0.2 })
check('5 metrics: LCP falls back to FCP, TTI = last long task end, TBT over 50 ms', m.lcp === 100 && m.tti === 340 && m.tbt === 30 && m.layout === 12 && m.script === 200, JSON.stringify(m))
const table = renderTable([1, 2, 3].map((k) => ({ profile: 'desktop', route: '/login', landed: '/', m: { fp: k, fcp: k, lcp: k, tti: k, tbt: k, dom: k, layout: k, script: k } })))
check('5 table: one row per profile x route, median, landed route, raw samples', table.split('\n').length === 3 && table.includes('| desktop | `/login` (`/`) | 2 | 2 |') && table.includes('1/1/1/1 2/2/2/2 3/3/3/3'), table)

const s = runsInUnitSuite(import.meta.url)
check('pnpm test runs this suite', s.ok, s.why)

console.log(failed ? `\n${failed} failure(s)` : '\nall passed')
process.exit(failed ? 1 : 0)
