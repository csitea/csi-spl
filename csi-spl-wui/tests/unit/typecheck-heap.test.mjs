// SPL-4831: `pnpm run typecheck` carries its own heap, and nothing bypasses it.
//
// vue-tsc ends with ~2450 MB of live heap on this tree (measured 2026-11-05,
// n=3 per limit on 76ce2e9b7): --max-old-space-size=2048 OOMs 3/3, 2560 passes
// at 94% used, 3072 at 80%. A hosted ubuntu-latest runner defaults to a ~2 GB
// heap there, and wf 30 runs 41920703912 and 41761114293 and wf 10 run
// 41544796875 died in typecheck with "JavaScript heap out of memory" at
// ~2045 MB. Every caller (wf 10, wf 30 test job and its deploy-leg fallback,
// the pre-push gate, do_wui_test, do_deploy_wui) runs `pnpm run typecheck`,
// so the heap lives once, in package.json, like `generate`'s (SPL-4793).
//
//   1  the typecheck script sets NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=N}"
//      with N >= MIN_HEAP_MB
//   2  no workflow or ./run action calls nuxt / nuxi typecheck or vue-tsc
//      itself (it would run on the default heap)
//   3  no workflow or ./run action sets NODE_OPTIONS without a heap option
//      (it would replace the script's default)
//   controls: a planted script without the option, a planted direct
//      `npx nuxt typecheck` step and a planted bare NODE_OPTIONS each fail
//
// Run: node tests/unit/typecheck-heap.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')

// 3072 is the smallest measured limit with headroom (80% used); the script
// ships 4096 (~60%).
const MIN_HEAP_MB = 3072

const SCRIPT_RX = /^NODE_OPTIONS="\$\{NODE_OPTIONS:---max-old-space-size=(\d+)\}" nuxt typecheck$/
const DIRECT_RX = /\b(nuxt|nuxi)\s+typecheck\b|\bvue-tsc\b/
const NODE_OPTIONS_RX = /\bNODE_OPTIONS\s*[:=]/

function scriptHeap(script) {
  const m = SCRIPT_RX.exec(script || '')
  return m ? Number(m[1]) : 0
}

// Lines of a caller file that break rule 2 or 3; comments are skipped.
function badLines(text) {
  const out = []
  text.split('\n').forEach((line, i) => {
    const code = line.replace(/^\s*#.*$/, '').replace(/\s#\s.*$/, '')
    if (DIRECT_RX.test(code)) out.push(`${i + 1}: direct typecheck: ${line.trim()}`)
    if (NODE_OPTIONS_RX.test(code) && !/max-old-space-size/.test(code)) out.push(`${i + 1}: NODE_OPTIONS without a heap: ${line.trim()}`)
  })
  return out
}

function callerFiles() {
  const dirs = [
    ['.github/workflows', (f) => /\.ya?ml$/.test(f)],
    ['csi-spl-iac/src/bash/run', (f) => f.endsWith('.sh')],
    ['csi-spl-orc/src/bash/run', (f) => f.endsWith('.sh')],
  ]
  return dirs.flatMap(([d, keep]) => readdirSync(join(REPO, d)).filter(keep).map((f) => join(REPO, d, f)))
}

const pkg = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8'))
const heap = scriptHeap(pkg.scripts.typecheck)
ok(`1 typecheck script carries a heap >= ${MIN_HEAP_MB} MB (has ${heap})`, heap >= MIN_HEAP_MB, pkg.scripts.typecheck)

const files = callerFiles()
ok(`2+3 caller files found (${files.length})`, files.length > 10, `only ${files.length}`)
const bad = files.flatMap((f) => badLines(readFileSync(f, 'utf8')).map((b) => `${relative(REPO, f)}:${b}`))
ok('2+3 no caller bypasses the script heap', bad.length === 0, bad.join(' | '))

ok('control: a script without the option fails', scriptHeap('nuxt typecheck') < MIN_HEAP_MB)
ok('control: a 2048 MB script fails', scriptHeap('NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}" nuxt typecheck') < MIN_HEAP_MB)
ok('control: a direct npx nuxt typecheck step fails', badLines('      - run: npx nuxt typecheck').length === 1)
ok('control: a bare vue-tsc call fails', badLines('  (cd "$w" && vue-tsc --noEmit)').length === 1)
ok('control: a bare NODE_OPTIONS fails', badLines('        env:\n          NODE_OPTIONS: --enable-source-maps').length === 1)
ok('control: pnpm run typecheck and a comment pass', badLines('      - run: pnpm run typecheck\n  # nuxt typecheck in a comment').length === 0)

if (failed) { console.log(`typecheck-heap: ${failed} failed`); process.exit(1) }
console.log('typecheck-heap: all passed')
