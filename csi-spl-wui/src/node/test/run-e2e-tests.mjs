// WUI browser-e2e runner — discovers tests instead of hardcoding them.
//
// Why this exists, twice over:
//   • `test:e2e` used to be one `node a && node b && …` chain, so the first
//     red stopped it and every file after it never ran (CLE-77827).
//   • Then it was an explicit list in package.json, plus ~95
//     `test:e2e:<name>` scripts, plus a script loop in workflows 10 and 11.
//     48 lanes edited package.json in the 72 h before 2026-10-01 to add one
//     line each, and a file nobody listed never ran: local-time and
//     open-parent-section sat on disk unexercised, and the script
//     `node a.test.mjs b.test.mjs` only ever ran a (CLE-77915).
//
// Discovery removes that failure mode by construction: every
// tests/e2e/*.test.mjs on disk runs, the moment it lands, unless
// tests/e2e/ci-skip.txt names it with a reason (live hub, credentials,
// Hosting headers). *.proof.mjs files are never discovered — they drive live
// sites.
//
// Contract (`10_ci-quality.yml` / `11_ci-public.yml` run `pnpm run test:e2e`):
//   • every selected file runs, in sorted order, whatever the ones before did
//   • a file that fails runs ONCE more, alone, straight after; never the
//     suite, and never with a longer timeout. Fails then passes: FLAKY —
//     its name and the tail of the first failure go to the log and to
//     $GITHUB_STEP_SUMMARY, and it counts as a pass. Fails twice: red.
//     (Trunk wf 10 was red on ~1 file a run, a different file each time,
//     each green locally and in other runs: chime-mute, phone-message-link-
//     tap, topic-send-target; task 7ec0c6a0, 2026-10-07.)
//   • exit 0 only when every file exits 0 on its first run or its retry
//   • exit 1 when any file fails twice, when nothing is selected, when a path given
//     is missing, or when a ci-skip.txt line names no file on disk or gives
//     no reason — an empty run must never read as a pass
//   • the last lines name every failed file, so the job log says it once
//   • after each file, one line `<file> <secs>` (integer seconds) so a later
//     refresh of e2e-shard-weights.txt can be read off the job log
//
// Usage:
//   node src/node/test/run-e2e-tests.mjs                     # the CI suite
//   node src/node/test/run-e2e-tests.mjs msg-edit csp        # names containing these (skipped ones too)
//   node src/node/test/run-e2e-tests.mjs tests/e2e/a.test.mjs # exact paths
//   node src/node/test/run-e2e-tests.mjs --list              # print the selection, run none
//   FAIL_FAST=1 node src/node/test/run-e2e-tests.mjs         # stop at first failure
//   E2E_SHARD=2/3 node src/node/test/run-e2e-tests.mjs       # shard 2 of a longest-first pack of 3
//   E2E_LOCAL_SLOTS=1 node src/node/test/run-e2e-tests.mjs   # box-wide cap on local runs (default 2, e2e-slots.mjs)
import { appendFileSync, existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawn } from 'node:child_process'
import { acquireSlot } from './e2e-slots.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const E2E_REL = 'tests/e2e'
const SKIP_REL = `${E2E_REL}/ci-skip.txt`
const WEIGHTS_REL = 'e2e-shard-weights.txt'
// Lines of a failed first run kept for the FLAKY report and step summary.
const TAIL_LINES = 30

// True when node was started on this file. An import (the pack test) must
// not discover files, take a slot, or exit.
export function invokedDirectly() {
  const arg = process.argv[1]
  if (!arg) return false
  return import.meta.url === pathToFileURL(resolve(arg)).href
}

// `<path> <seconds>` per line, `#` comments. A bad line is an error: a
// silent skip would pack that file at the median and hide a typo.
export function parseWeights(text) {
  const map = new Map()
  for (const raw of String(text).split('\n')) {
    const line = raw.replace(/#.*/, '').trim()
    if (!line) continue
    const parts = line.split(/\s+/)
    if (parts.length !== 2 || !/^[1-9]\d*$/.test(parts[1])) {
      throw new Error(`e2e shard weights: bad line "${raw.trim()}"`)
    }
    if (map.has(parts[0])) throw new Error(`e2e shard weights: duplicate "${parts[0]}"`)
    map.set(parts[0], Number(parts[1]))
  }
  return map
}

export function loadWeights(path) {
  if (!existsSync(path)) return new Map()
  return parseWeights(readFileSync(path, 'utf8'))
}

// Odd count: the middle value. Even count: the nearest integer to the mean
// of the two middle values. No weights at all (file missing): 1, so every
// file ties and the pack matches round-robin.
export function medianWeight(values) {
  if (!values.length) return 1
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  if (sorted.length % 2) return sorted[mid]
  return Math.round((sorted[mid - 1] + sorted[mid]) / 2)
}

export function weightFor(file, weights) {
  if (weights.has(file)) return weights.get(file)
  return medianWeight([...weights.values()])
}

// Longest file first; a weight tie keeps discovery order. The lightest shard
// takes the next file; a sum tie takes the lowest index. With equal weights
// that is round-robin over the sorted list (shard k gets indexes k, k+n, …),
// which the coverage test pins. Within a shard, discovery order, so a failure
// is reproducible. Returns n arrays; a short list leaves the tail empty.
export function packShards(files, n, weightOf) {
  const shards = Array.from({ length: n }, () => [])
  const sums = Array(n).fill(0)
  const order = files.map((file, index) => ({ file, index, w: weightOf(file) }))
  order.sort((a, b) => (b.w - a.w) || (a.index - b.index))
  for (const item of order) {
    let best = 0
    for (let j = 1; j < n; j++) {
      if (sums[j] < sums[best]) best = j
    }
    shards[best].push(item)
    sums[best] += item.w
  }
  return shards.map((items) => items.sort((a, b) => a.index - b.index).map((item) => item.file))
}

const die = (msg) => {
  console.error(`e2e runner: ${msg}`)
  process.exit(1)
}

function discoveredFiles() {
  // Sorted so a failure is reproducible in the same order on every machine.
  const discovered = existsSync(join(WUI, E2E_REL))
    ? readdirSync(join(WUI, E2E_REL)).filter((f) => f.endsWith('.test.mjs')).sort().map((f) => `${E2E_REL}/${f}`)
    : []
  if (discovered.length === 0) die(`no *.test.mjs found in ${E2E_REL} — refusing to pass`)
  return discovered
}

function skipSet(discovered) {
  // ci-skip.txt: `<file name> <reason>` per line, `#` comments. A stale line is
  // an error, not a no-op: it would hide the file that replaced it.
  const skipped = new Set()
  if (existsSync(join(WUI, SKIP_REL))) {
    for (const raw of readFileSync(join(WUI, SKIP_REL), 'utf8').split('\n')) {
      const line = raw.replace(/#.*/, '').trim()
      if (!line) continue
      const [name, ...reason] = line.split(/\s+/)
      if (!reason.length) die(`${SKIP_REL}: "${name}" gives no reason`)
      if (!discovered.includes(`${E2E_REL}/${name}`)) die(`${SKIP_REL}: "${name}" is not a file in ${E2E_REL}`)
      skipped.add(`${E2E_REL}/${name}`)
    }
  }
  // E2E_SKIP: more names to leave out of THIS run only, space-separated, same
  // rule as a ci-skip.txt line (must exist). Workflow 11 sets it for a check
  // whose verdict depends on the hosted runner's fonts; the workflow carries
  // the reason next to it.
  for (const name of (process.env.E2E_SKIP || '').split(/\s+/).filter(Boolean)) {
    if (!discovered.includes(`${E2E_REL}/${name}`)) die(`E2E_SKIP: "${name}" is not a file in ${E2E_REL}`)
    skipped.add(`${E2E_REL}/${name}`)
  }
  return skipped
}

function selectedFiles(discovered, skipped, paths, filters) {
  if (paths.length) {
    const missing = paths.filter((f) => !existsSync(join(WUI, f)))
    if (missing.length) die(`file(s) not found: ${missing.join(', ')}`)
    return paths
  }
  if (filters.length) {
    const files = discovered.filter((f) => filters.some((s) => f.slice(E2E_REL.length + 1).includes(s)))
    if (files.length === 0) die(`filter [${filters.join(', ')}] matched none of ${discovered.length} files`)
    return files
  }
  const files = discovered.filter((f) => !skipped.has(f))
  if (files.length === 0) die('every discovered file is in ci-skip.txt — refusing to pass')
  return files
}

// E2E_SHARD=<i>/<n>: shard i of a longest-first pack of the selection
// (1-based). Weights are e2e-shard-weights.txt beside this file; a file
// with no weight takes the median, and a missing weights file gives every
// file weight 1 (the same split as round-robin). One serial job took 35 min
// green and hit its 45 min timeout under load, so the gate finished once
// per ~45 min and every push in between was cancelled while pending
// (CLE-77945, 2026-10-02). The union of shards 1..n is exactly the
// unsharded selection; a shard that gets nothing refuses to pass.
function sharded(files, shard) {
  if (!shard) return files
  const m = /^(\d+)\/(\d+)$/.exec(shard)
  const [i, n] = m ? [Number(m[1]), Number(m[2])] : [0, 0]
  if (!m || n < 1 || i < 1 || i > n) die(`E2E_SHARD="${shard}" is not <i>/<n> with 1 <= i <= n`)
  let weights
  try {
    weights = loadWeights(join(__dirname, WEIGHTS_REL))
  } catch (e) {
    die(e.message)
  }
  const packed = packShards(files, n, (file) => weightFor(file, weights))[i - 1]
  if (packed.length === 0) die(`E2E_SHARD=${shard} selects no file — refusing to pass`)
  return packed
}

// Runs one file with its output streamed through as it comes, keeping the
// last TAIL_LINES lines for the report. Resolves { status, signal, tail }.
function runFile(file) {
  return new Promise((done) => {
    const child = spawn(process.execPath, [join(WUI, file)], { cwd: WUI, stdio: ['inherit', 'pipe', 'pipe'] })
    let tail = []
    let partial = ''
    const keep = (chunk) => {
      const lines = (partial + chunk).split('\n')
      partial = lines.pop()
      tail = tail.concat(lines).slice(-TAIL_LINES)
    }
    child.stdout.on('data', (b) => { process.stdout.write(b); keep(b.toString('utf8')) })
    child.stderr.on('data', (b) => { process.stderr.write(b); keep(b.toString('utf8')) })
    const finish = (status, signal) => {
      if (partial) tail = tail.concat(partial).slice(-TAIL_LINES)
      done({ status, signal, tail })
    }
    child.on('error', (e) => { keep(`spawn error: ${e.message}\n`); finish(null, null) })
    child.on('close', finish)
  })
}

const why = (r) => (r.signal ? `signal ${r.signal}` : `exit ${r.status}`)

function stepSummary(lines) {
  const path = process.env.GITHUB_STEP_SUMMARY
  if (!path) return
  try {
    appendFileSync(path, lines.join('\n') + '\n')
  } catch (e) {
    console.error(`e2e runner: cannot write GITHUB_STEP_SUMMARY: ${e.message}`)
  }
}

async function runSelected(files, { skipped, narrowed, shard, failFast }) {
  // One of E2E_LOCAL_SLOTS box-wide slots before any browser starts: lanes'
  // parallel local runs drove a 16-cpu box to load 50. GitHub Actions is not
  // capped. Waiting prints the holders; the slot frees on exit, signal or crash.
  try {
    await acquireSlot()
  } catch (e) {
    die(e.message)
  }
  const scope = narrowed ? '' : ` (${skipped.size} skipped by ${SKIP_REL}${process.env.E2E_SKIP ? ' + E2E_SKIP' : ''})`
  console.log(`e2e runner: ${files.length} file(s)${scope}${shard ? `, shard ${shard}` : ''}\n`)
  const failures = []
  const flaky = []
  for (const [i, file] of files.entries()) {
    const tag = `${i + 1}/${files.length}`
    console.log(`──[${tag}] ${file}`)
    const started = Date.now()
    const first = await runFile(file)
    const secs = Math.round((Date.now() - started) / 1000)
    // `<file> <secs>` once per file, first run, pass or fail, for the next
    // weights refresh (a retry's time would be a duplicate line).
    console.log(`${file} ${secs}`)
    // A killing signal (OOM, timeout) leaves status null — that is a failure too.
    if (first.status !== 0) {
      console.log(`──[${tag}] RETRY ${file} (first run ${why(first)}, ${secs}s) — one retry, alone`)
      const t0 = Date.now()
      const second = await runFile(file)
      const secs2 = Math.round((Date.now() - t0) / 1000)
      if (second.status === 0) {
        flaky.push({ file, first })
        console.log(`──[${tag}] FLAKY ${file} (first run ${why(first)}, retry passed in ${secs2}s)`)
      } else {
        failures.push({ file, first, second })
        console.log(`──[${tag}] FAIL ${file} (${why(first)}, then ${why(second)} on retry)`)
        if (failFast) break
      }
    }
    console.log('')
  }
  report(files.length, flaky, failures)
  if (failures.length) process.exit(1)
}

// The last lines of the job log and the step summary: every FLAKY file with
// the tail of its first failure (green, but visible), then every red one.
function report(total, flaky, failures) {
  const md = []
  if (flaky.length) {
    console.log(`\ne2e runner: ${flaky.length} file(s) FLAKY — failed, then passed on the one retry:`)
    md.push(`### e2e: ${flaky.length} FLAKY file(s) — failed, then passed on retry${process.env.E2E_SHARD ? ` (shard ${process.env.E2E_SHARD})` : ''}`, '')
    for (const f of flaky) {
      console.log(`  FLAKY ${f.file} (first run ${why(f.first)}); tail of the first failure:`)
      for (const line of f.first.tail) console.log(`    | ${line}`)
      md.push(`**FLAKY \`${f.file}\`** (first run ${why(f.first)}), tail of the first failure:`, '', '```text', ...f.first.tail, '```', '')
    }
  }
  if (!failures.length) {
    console.log(`\ne2e runner: all ${total} file(s) passed${flaky.length ? ` (${flaky.length} on retry, FLAKY above)` : ''}`)
  } else {
    console.log(`\ne2e runner: ${failures.length} of ${total} file(s) FAILED (twice: first run and retry)`)
    md.push(`### e2e: ${failures.length} of ${total} file(s) FAILED twice${process.env.E2E_SHARD ? ` (shard ${process.env.E2E_SHARD})` : ''}`, '')
    for (const f of failures) {
      console.log(`  FAIL ${f.file} (${why(f.first)}, then ${why(f.second)})`)
      md.push(`- \`${f.file}\` (${why(f.first)}, then ${why(f.second)})`)
    }
    md.push('')
  }
  if (md.length) stepSummary(md)
}

async function main() {
  const argv = process.argv.slice(2)
  const listOnly = argv.includes('--list')
  const args = argv.filter((a) => !a.startsWith('--'))
  const paths = args.filter((a) => a.includes('/'))
  const filters = args.filter((a) => !a.includes('/'))
  const discovered = discoveredFiles()
  const skipped = skipSet(discovered)
  const shard = process.env.E2E_SHARD || ''
  const files = sharded(selectedFiles(discovered, skipped, paths, filters), shard)
  if (listOnly) {
    for (const f of files) console.log(f)
    process.exit(0)
  }
  await runSelected(files, {
    skipped,
    narrowed: paths.length > 0 || filters.length > 0,
    shard,
    failFast: process.env.FAIL_FAST === '1',
  })
}

if (invokedDirectly()) await main()
