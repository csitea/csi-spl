// The pulse field's pure parts (spec 111 section 12, SPL-6140): the theme-token
// reader takes its three stops from the CSS tokens (every theme of
// variables.css, read from the file itself), falls back stop by stop, and
// draws nothing when no token parses; the dash placement stays under its cap
// on any screen; the ring is empty at the centre and the corners; the DPR is
// capped.
//
// Run: node tests/unit/pulse-field.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  PULSE_MAX_DASHES, PULSE_MAX_DPR, PULSE_TOKENS, mixPulseStops, parsePulseColor,
  placePulseDashes, pulseDpr, pulseRingWeight, readPulseColors,
} from '../../src/utils/pulse-field.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

/* the colour parser: the forms getComputedStyle hands back */
ok('#rrggbb parses', same(parsePulseColor(' #34D5F0 '), [52, 213, 240]))
ok('#rgb parses', same(parsePulseColor('#0f8'), [0, 255, 136]))
ok('#rrggbbaa keeps the colour', same(parsePulseColor('#a06bff80'), [160, 107, 255]))
ok('rgb(r, g, b) parses', same(parsePulseColor('rgb(10, 151, 196)'), [10, 151, 196]))
ok('rgba(r g b / a) parses', same(parsePulseColor('rgba(1 2 3 / 0.5)'), [1, 2, 3]))
ok('an empty or unknown value is null', parsePulseColor('') === null && parsePulseColor('var(--x)') === null && parsePulseColor(undefined) === null)

/* the reader, against every theme block of the real token file */
const css = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
const blocks = [...css.matchAll(/(:root(?:\[data-theme="([a-z-]+)"\])?)\s*\{([^}]*)\}/g)]
  .map((m) => ({ name: m[2] || 'default', body: m[3] }))
  .filter((b) => PULSE_TOKENS.every((t) => new RegExp(`${t}\\s*:\\s*#`).test(b.body)))
ok('variables.css has the default (dark) and the light theme with all three tokens', ['default', 'light'].every((n) => blocks.some((b) => b.name === n)), blocks.map((b) => b.name).join())
for (const b of blocks) {
  const tokens = Object.fromEntries([...b.body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]))
  const got = readPulseColors((name) => tokens[name] || '')
  const want = PULSE_TOKENS.map((t) => parsePulseColor(tokens[t]))
  ok(`theme ${b.name}: the stops are its own ${PULSE_TOKENS.join(', ')}`, same(got, want), JSON.stringify(got))
}

/* fallbacks */
const only = { '--color-accent': '#112233' }
ok('a missing stop takes the one before it', same(readPulseColors((n) => only[n] || ''), [[17, 34, 51], [17, 34, 51], [17, 34, 51]]))
const late = { '--color-accent-2': '#445566' }
ok('a missing first stop takes the first readable one', same(readPulseColors((n) => late[n] || ''), [[68, 85, 102], [68, 85, 102], [68, 85, 102]]))
ok('no readable token: null (nothing is drawn)', readPulseColors(() => '') === null)
ok('a reader that throws counts as missing', readPulseColors(() => { throw new Error('x') }) === null)

/* the mix */
const stops = [[0, 0, 0], [100, 100, 100], [200, 0, 0]]
ok('mix at 0, 0.5 and 1 hits the stops', same(mixPulseStops(stops, 0), [0, 0, 0]) && same(mixPulseStops(stops, 0.5), [100, 100, 100]) && same(mixPulseStops(stops, 1), [200, 0, 0]))
ok('mix clamps outside 0..1', same(mixPulseStops(stops, -1), [0, 0, 0]) && same(mixPulseStops(stops, 2), [200, 0, 0]))

/* the placement cap and its spread */
for (const [w, h] of [[390, 844], [1280, 800], [2560, 1600], [7680, 4320]]) {
  const d = placePulseDashes(w, h)
  const inside = d.every((p) => p.x >= 0 && p.x <= w && p.y >= 0 && p.y <= h)
  ok(`${w}x${h}: 1..${PULSE_MAX_DASHES} dashes, all inside`, d.length > 0 && d.length <= PULSE_MAX_DASHES && inside, d.length)
}
ok('the same size places the same field (seeded)', same(placePulseDashes(800, 600), placePulseDashes(800, 600)))
ok('a zero size places none', placePulseDashes(0, 600).length === 0)

/* the ring */
ok('no dash at the centre', pulseRingWeight(0, 500) === 0)
ok('no dash past the corner', pulseRingWeight(530, 500) === 0)
ok('full on the ring', pulseRingWeight(250, 500) === 1)

/* the DPR cap */
ok(`DPR capped at ${PULSE_MAX_DPR}`, pulseDpr(3) === PULSE_MAX_DPR && pulseDpr(1.5) === 1.5 && pulseDpr(undefined) === 1)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)
if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\npulse-field: ok')
