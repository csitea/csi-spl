// Pins E2E_SHARD longest-first packing (E10).
//
// The gain is deterministic: on a fixed, checked-in file set per CI shard
// count, round-robin's heavy shard is heavier than the packed one. The old
// round-robin split is computed here beside the pack; a packer that returns
// that split fails the budget. Equal weights still match round-robin, which
// is what tests/unit/e2e-runner-coverage.test.mjs pins on a weights-free copy.
//
// Run: node tests/unit/e2e-shard-pack.test.mjs
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer, connect } from 'node:net'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
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
  assert.equal(medianWeight([...parsed.values()]), 10)
  assert.equal(weightFor('tests/e2e/not-yet-measured.test.mjs', parsed), 10)
  assert.equal(weightFor('tests/e2e/mobile-back-stuck.test.mjs', parsed), 29)
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

// --- the pack beats round-robin on a fixed file set, per CI shard count ---
// 3 shards (the split the weights were measured under), 5 (wf 10's
// wui-e2e matrix L5, 2026-10-12), 6 (round 27) and 8 (its matrix since
// spec 133 round 30).
//
// The control lives here, on checked-in names and weights, not on the live
// e2e list: round-robin's balance there depends on the alphabetical order
// of the file names, so adding one e2e file could make round-robin balanced
// by accident and turn this test red for a lane that only added a test
// (SPL-2551: 28 of 277 one-file additions did, on 3 shards). Per n: 10n
// files, the n heavy ones (300) on the indexes k*n, which round-robin all
// puts on shard 0; the light ones weigh 5..13 in a fixed cycle. A packer
// that returns round-robin fails all three asserts.
const SHARD_COUNTS = [3, 5, 6, 8]
for (const n of SHARD_COUNTS) {
  const files = Array.from({ length: 10 * n }, (_, i) => `tests/e2e/f${String(i).padStart(3, '0')}.test.mjs`)
  const w = (file) => {
    const i = Number(file.slice('tests/e2e/f'.length, -'.test.mjs'.length))
    return i % n === 0 && i < n * n ? 300 : 5 + (i * 7) % 9
  }
  const packed = packShards(files, n, w)
  const flat = packed.flat()
  assert.deepEqual([...flat].sort(), [...files].sort())
  assert.equal(new Set(flat).size, files.length)
  const packedSums = sums(packed, w)
  const oldSums = sums(roundRobin(files, n), w)
  assert.ok(Math.max(...packedSums) < Math.max(...oldSums), `n=${n} packed ${packedSums} old ${oldSums}`)
  assert.ok(spread(packedSums) <= 0.05, `n=${n} packed spread ${spread(packedSums)}`)
  assert.ok(spread(oldSums) > 0.5, `n=${n} old spread ${spread(oldSums)} (control: round-robin must miss the bound by far)`)
}

// --- the checked-in weights, on the selection CI actually runs -------------
// Only properties that hold whatever the e2e file names are: the CLI split
// is packShards, every file is on exactly one shard, and the pack is within
// 0.05 of even. Measured 2026-10-05 on these weights: round-robin max
// 1302 s, packed max 1036 s; how much the pack wins on the live list moves
// with every file added, so it is not asserted here (the fixed set above is).
for (const n of SHARD_COUNTS) {
  const all = list()
  const packed = Array.from({ length: n }, (_, k) => list(`${k + 1}/${n}`))
  assert.deepEqual(packed, packShards(all, n, weightOf))
  const flat = packed.flat()
  assert.deepEqual([...flat].sort(), [...all].sort())
  assert.equal(new Set(flat).size, all.length)
  const packedSums = sums(packed, weightOf)
  assert.ok(spread(packedSums) <= 0.05, `n=${n} packed spread ${spread(packedSums)} sums ${packedSums}`)
}

// --- a reader slow to drain still gets the whole list ----------------------
// --list on a loaded box: stdout is a unix stream socket the reader drains
// late, so the runner's writes go async. It used to process.exit right after
// one console.log per file, which dropped the queued tail with rc 0, and the
// unsharded list above came back short (c-034's pre-push, 2026-10-27: the
// last 7 of 293 files). Here the reader starts 500 ms late.
{
  const dir = mkdtempSync(join(tmpdir(), 'e2e-shard-pack-'))
  const server = createServer({ pauseOnConnect: true })
  await new Promise((resolve) => server.listen(join(dir, 's'), resolve))
  const accepted = new Promise((resolve) => server.once('connection', resolve))
  const out = connect(join(dir, 's'))
  await new Promise((resolve) => out.once('connect', resolve))
  const env = { ...process.env }
  delete env.E2E_SHARD
  const child = spawn(process.execPath, [RUNNER, '--list'], { cwd: WUI, env, stdio: ['ignore', out, 'inherit'] })
  out.destroy()
  const status = await new Promise((resolve) => child.once('exit', resolve))
  const peer = await accepted
  await new Promise((resolve) => setTimeout(resolve, 500))
  const chunks = []
  peer.on('data', (chunk) => chunks.push(chunk))
  peer.resume()
  await new Promise((resolve) => peer.once('end', resolve))
  server.close()
  rmSync(dir, { recursive: true, force: true })
  assert.equal(status, 0)
  const slow = Buffer.concat(chunks).toString('utf8').trim().split('\n').filter(Boolean)
  assert.deepEqual(slow, list(), `a slow reader got ${slow.length} line(s)`)
}

console.log('e2e-shard-pack: all passed')
