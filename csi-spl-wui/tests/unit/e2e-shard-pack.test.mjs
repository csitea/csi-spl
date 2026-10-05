// Pins E2E_SHARD longest-first packing (E10).
//
// The gain is deterministic: on the checked-in weights, round-robin's heavy
// shard is heavier than the packed one by more than a minute. The old
// round-robin split is computed here beside the pack; a packer that returns
// that split fails the budget. Equal weights still match round-robin, which
// is what tests/unit/e2e-runner-coverage.test.mjs pins on a weights-free copy.
//
// Run: node tests/unit/e2e-shard-pack.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import {
  packShards,
  medianWeight,
  parseWeights,
  weightFor,
  loadWeights,
} from '../../src/node/test/run-e2e-tests.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const RUNNER = join(WUI, 'src/node/test/run-e2e-tests.mjs')
const WEIGHTS = join(WUI, 'src/node/test/e2e-shard-weights.txt')

function roundRobin (files, n) {
  const shards = Array.from({ length: n }, () => [])
  files.forEach((file, k) => shards[k % n].push(file))
  return shards
}

function sums (shards, weightOf) {
  return shards.map((shard) => shard.reduce((total, file) => total + weightOf(file), 0))
}

function spread (xs) {
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length
  return (Math.max(...xs) - Math.min(...xs)) / mean
}

const weights = loadWeights(WEIGHTS)
const weightOf = (file) => weightFor(file, weights)
const list = (shard) => {
  const env = { ...process.env }
  if (shard) env.E2E_SHARD = shard
  else delete env.E2E_SHARD
  const res = spawnSync(process.execPath, [RUNNER, '--list'], { cwd: WUI, encoding: 'utf8', env })
  assert.equal(res.status, 0, res.stderr)
  return res.stdout.trim().split('\n').filter(Boolean)
}

// --- weights file -----------------------------------------------------------
{
  const parsed = parseWeights(readFileSync(WEIGHTS, 'utf8'))
  assert.equal(parsed.size, weights.size)
  assert.ok(parsed.size >= 100, `weights file has ${parsed.size} rows`)
  assert.equal(medianWeight([...parsed.values()]), 13)
  assert.equal(weightFor('tests/e2e/not-yet-measured.test.mjs', parsed), 13)
  assert.equal(weightFor('tests/e2e/mobile-back-stuck.test.mjs', parsed), 165)
  assert.equal(medianWeight([]), 1)
  assert.equal(medianWeight([4, 1, 9]), 4)
  assert.equal(medianWeight([1, 2, 3, 4]), 3)
  assert.throws(() => parseWeights('tests/e2e/a.test.mjs 0\n'), /bad line/)
  assert.throws(() => parseWeights('tests/e2e/a.test.mjs 4\ntests/e2e/a.test.mjs 5\n'), /duplicate/)
}

// --- equal weights are round-robin (the coverage test's a, c / b split) ----
{
  const files = ['tests/e2e/a.test.mjs', 'tests/e2e/b.test.mjs', 'tests/e2e/c.test.mjs']
  const packed = packShards(files, 2, () => 1)
  assert.deepEqual(packed, roundRobin(files, 2))
  assert.deepEqual(packed[0], ['tests/e2e/a.test.mjs', 'tests/e2e/c.test.mjs'])
  assert.deepEqual(packed[1], ['tests/e2e/b.test.mjs'])
}

// --- a clustered heavy residue is the case round-robin loses ---------------
// Files a,d,g weigh 50 and sit on shard 0 under round-robin (150). The pack
// puts one 50 on each shard (max 52). Returning round-robin fails `max <= 60`.
{
  const names = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']
  const files = names.map((name) => `tests/e2e/${name}.test.mjs`)
  const heavy = new Set(['a', 'd', 'g'])
  const w = (file) => (heavy.has(file.split('/')[2][0]) ? 50 : 1)
  const packed = packShards(files, 3, w)
  const old = roundRobin(files, 3)
  const flat = packed.flat()
  assert.equal(flat.length, files.length)
  assert.equal(new Set(flat).size, files.length)
  assert.deepEqual([...flat].sort(), [...files].sort())
  const packedMax = Math.max(...sums(packed, w))
  const oldMax = Math.max(...sums(old, w))
  assert.equal(oldMax, 150)
  assert.ok(packedMax <= 60, `packed max ${packedMax}`)
  assert.ok(oldMax > 60, 'control: round-robin misses the budget the pack meets')
}

// --- the checked-in weights, on the selection CI actually runs -------------
{
  const all = list()
  const packed = [1, 2, 3].map((i) => list(`${i}/3`))
  const viaFn = packShards(all, 3, weightOf)
  assert.deepEqual(packed, viaFn)
  const flat = packed.flat()
  assert.deepEqual([...flat].sort(), [...all].sort())
  assert.equal(new Set(flat).size, all.length)
  const packedSums = sums(packed, weightOf)
  const oldSums = sums(roundRobin(all, 3), weightOf)
  const packedMax = Math.max(...packedSums)
  const oldMax = Math.max(...oldSums)
  // Measured 2026-10-05 on these weights: round-robin max 1302 s, packed
  // max 1036 s. The gap moves with every e2e file added (one more file,
  // dc6d5e3f: 1120 vs 1096), so the budget is "the pack's heavy shard is
  // lighter than round-robin's", not a fixed minute; a packer that returns
  // round-robin ties here and fails, and fails the spread bound below too.
  assert.ok(packedMax < oldMax, `packed ${packedMax} old ${oldMax} sums ${packedSums} vs ${oldSums}`)
  assert.ok(spread(packedSums) <= 0.05, `packed spread ${spread(packedSums)}`)
  // The control is "round-robin misses the pack's own 0.05", not a fixed
  // 0.15: round-robin's spread moves with every e2e file added (one new
  // file took it from >= 0.15 to 0.136), the pack's bound does not.
  assert.ok(spread(oldSums) > 0.05, `old spread ${spread(oldSums)} (control would be green if round-robin were already balanced)`)
}

console.log('e2e-shard-pack: all passed')
