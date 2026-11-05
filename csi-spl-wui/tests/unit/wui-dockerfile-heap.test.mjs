// SPL-4782: `pnpm run generate` in wui.Dockerfile died with "Reached heap
// limit ... JavaScript heap out of memory" in the nitro prerenderer on a
// smaller Docker host, where node's default old-space limit (a share of the
// host's memory) sits near 2 GB. The image build must get the generate
// script's own heap default (package.json, SPL-4793), never a lower one the
// Dockerfile pins, and a build ARG must still let a host set its own limit.
// Run: node tests/unit/wui-dockerfile-heap.test.mjs
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const dockerfile = readFileSync(join(WUI, 'src/docker/wui.Dockerfile'), 'utf8')
const generateScript = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8')).scripts.generate

let failed = 0
const check = (ok, name, detail) => {
  if (ok) console.log('  OK  ', name)
  else { failed++; console.log('  FAIL', name + ':', detail) }
}

// one logical instruction per entry: continuation lines joined
const instructions = dockerfile.replace(/\\\n/g, ' ').split('\n')
const generateRun = instructions.find((l) => /^RUN\b/.test(l) && /pnpm run generate/.test(l))
check(Boolean(generateRun), 'the build stage has a RUN with pnpm run generate', 'no such RUN')

const arg = dockerfile.match(/^ARG WUI_BUILD_HEAP_MB=(\S*)\s*$/m)
check(Boolean(arg), 'ARG WUI_BUILD_HEAP_MB is declared', 'no ARG WUI_BUILD_HEAP_MB=')
check(arg && arg[1] === '', 'ARG WUI_BUILD_HEAP_MB has no default (the generate script owns it)', arg && arg[1])
if (arg) {
  const argAt = instructions.findIndex((l) => /^ARG WUI_BUILD_HEAP_MB=/.test(l))
  const runAt = instructions.indexOf(generateRun)
  check(argAt >= 0 && argAt < runAt, 'the ARG is declared before the generate RUN', `ARG at ${argAt}, RUN at ${runAt}`)
}

// the NODE_OPTIONS word of the RUN, then the generate script's own default
const word = generateRun && generateRun.match(/NODE_OPTIONS="([^"]*)"/)
check(Boolean(word), 'the generate RUN passes NODE_OPTIONS', generateRun)
const scriptDefault = generateScript.match(/NODE_OPTIONS="(\$\{NODE_OPTIONS:-[^}]*\})"/)
check(Boolean(scriptDefault), 'package.json generate defaults NODE_OPTIONS with ${NODE_OPTIONS:-...}', generateScript)

// what nuxt generate sees, through sh as in the image, with the ARG unset and set
const seen = (heapArg) => execFileSync('sh', ['-c',
  `WUI_BUILD_HEAP_MB='${heapArg}'; NODE_OPTIONS="${word[1]}"; printf %s "${scriptDefault[1]}"`,
], { encoding: 'utf8' })
if (word && scriptDefault) {
  // 6144 is a floor, the package.json generate default (SPL-4793): lowering
  // that default on purpose means lowering this literal too
  const def = seen('').match(/--max-old-space-size=(\d+)/)
  check(def && Number(def[1]) >= 6144, 'ARG unset: generate gets the script default (>= 6144 MiB)', seen(''))
  check(seen('3072') === '--max-old-space-size=3072', 'ARG 3072: generate gets --max-old-space-size=3072', seen('3072'))
}

if (failed) {
  console.log(`\n${failed} failed`)
  process.exit(1)
}
console.log('\nall passed')
