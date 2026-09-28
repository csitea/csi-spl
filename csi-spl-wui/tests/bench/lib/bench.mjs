// Micro-benchmark harness for the WUI perf lane (CLE-35075, epic SPL-1093).
//
// One probe, two trees: every bench imports the code under test from
// `SRC` (default: this checkout's src/), so BEFORE and AFTER are the same
// probe run against two trees:
//
//   git archive <base-sha> csi-spl-wui/src | tar -x -C /tmp/base
//   SRC=/tmp/base/csi-spl-wui/src node tests/bench/<name>.bench.mjs   # before
//   node tests/bench/<name>.bench.mjs                                 # after
//
// Prints one line per case: n rounds, p50 / p95 in ms per round. Not part of
// the unit suite (tests/unit only): timings are not assertions.
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { execSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
export const SRC = resolve(process.env.SRC || join(HERE, '../../../src'))
export const ROUNDS = Math.max(5, Number(process.env.ROUNDS || 15))

/** import a module of the tree under test, e.g. src('utils/msg-menu.mjs') */
export function src(rel) {
  return import(pathToFileURL(join(SRC, rel)).href)
}

function pct(xs, p) {
  const s = [...xs].sort((a, b) => a - b)
  const k = (s.length - 1) * p / 100
  const lo = Math.floor(k)
  const hi = Math.min(lo + 1, s.length - 1)
  return s[lo] + (s[hi] - s[lo]) * (k - lo)
}

function tree() {
  try {
    return execSync('git rev-parse --short HEAD', { cwd: SRC, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
  } catch {
    return 'archive'
  }
}

/**
 * Run `fn` `ROUNDS` times after two warm-up calls and print p50 / p95.
 * `fn` returns anything; it is kept so the work is not optimised away.
 */
export function bench(name, fn) {
  let sink = 0
  for (let i = 0; i < 2; i++) sink ^= Number(Boolean(fn()))
  const ms = []
  for (let i = 0; i < ROUNDS; i++) {
    const t0 = performance.now()
    sink ^= Number(Boolean(fn()))
    ms.push(performance.now() - t0)
  }
  const line = `${name}  src=${SRC} tree=${tree()} node=${process.version} n=${ROUNDS} p50=${pct(ms, 50).toFixed(3)}ms p95=${pct(ms, 95).toFixed(3)}ms`
  console.log(line)
  return { name, p50: pct(ms, 50), p95: pct(ms, 95), sink }
}
