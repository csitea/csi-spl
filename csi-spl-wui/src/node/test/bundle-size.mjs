// What a page actually downloads, from a `nuxt generate` output.
//
// Two numbers, because only the first one is a cost the user pays on arrival:
//
//   initial  the chunks 200.html itself asks for — its <script src> and its
//            <link rel=modulepreload>. Vite emits a modulepreload for the
//            WHOLE static graph of the entry, so this set IS the initial
//            download. Do NOT compute it by walking imports: a walk cannot
//            tell `import "./x.js"` from `import("./x.js")`, and following
//            the dynamic ones reports every lazy chunk as initial (measured
//            2026-09-20: 179 KB gzip read as 526 KB that way).
//   all js   every client chunk on disk — initial plus everything lazy.
//
// It also answers the question a lazy-loading claim has to answer: is the
// syntax highlighter in the initial set? A chunk counts as carrying the
// highlight.js RUNTIME only if it holds strings only that runtime has
// (`versionString`, `Unknown language`), never merely the class prefix
// `hljs-`, which our own theme and emitter mention too.
//
// Usage:
//   node src/node/test/bundle-size.mjs [.output/public] [--json]
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { gzipSync } from 'node:zlib'
import { join } from 'node:path'

const args = process.argv.slice(2)
const asJson = args.includes('--json')
const PUB = args.find((a) => !a.startsWith('--')) || '.output/public'
const NUXT = join(PUB, '_nuxt')

const files = readdirSync(NUXT).filter((f) => f.endsWith('.js'))
const gz = (p) => gzipSync(readFileSync(p)).length
const raw = (p) => statSync(p).size
const sum = (list, f) => list.reduce((a, x) => a + f(join(NUXT, x)), 0)
const kb = (n) => Number((n / 1024).toFixed(1))

const html = readFileSync(join(PUB, '200.html'), 'utf8')
// <script src=> and <link rel="modulepreload" href=> only - never a
// <link rel="prefetch"> (a lazy chunk fetched at idle). Same set as
// csi-spl-orc/src/bash/scripts/perf-budget.py.
const scriptSrc = [...html.matchAll(/<script\b[^>]*\bsrc="\/_nuxt\/([A-Za-z0-9._-]+\.js)"/g)].map((m) => m[1])
const modulepreload = [...html.matchAll(/<link\b[^>]*>/g)]
  .map((m) => m[0])
  .filter((tag) => /\brel="modulepreload"/.test(tag))
  .map((tag) => (tag.match(/\bhref="\/_nuxt\/([A-Za-z0-9._-]+\.js)"/) || [])[1])
  .filter(Boolean)
const initial = [...new Set([...scriptSrc, ...modulepreload])].filter((f) => files.includes(f))

/** chunks holding the highlight.js runtime itself (not just its class names) */
const engine = files.filter((f) => {
  const src = readFileSync(join(NUXT, f), 'utf8')
  return src.includes('versionString') && src.includes('Unknown language')
})

const report = {
  initial: { chunks: initial.length, rawKB: kb(sum(initial, raw)), gzipKB: kb(sum(initial, gz)) },
  all: { chunks: files.length, rawKB: kb(sum(files, raw)), gzipKB: kb(sum(files, gz)) },
  highlightEngine: {
    chunks: engine.length,
    rawKB: kb(sum(engine, raw)),
    gzipKB: kb(sum(engine, gz)),
    inInitialSet: engine.filter((f) => initial.includes(f)),
  },
}

if (asJson) {
  console.log(JSON.stringify(report, null, 1))
} else {
  const line = (k, v) => `${k.padEnd(9)} ${String(v.chunks).padStart(3)} chunk(s)  raw ${String(v.rawKB).padStart(7)} KB  gzip ${String(v.gzipKB).padStart(6)} KB`
  console.log(line('initial', report.initial))
  console.log(line('all js', report.all))
  const e = report.highlightEngine
  console.log(`highlight.js runtime: ${e.chunks} chunk(s)  raw ${e.rawKB} KB  gzip ${e.gzipKB} KB`)
  console.log(`  in the INITIAL set: ${e.inInitialSet.length}${e.inInitialSet.length ? ' -> ' + e.inInitialSet.join(' ') : ' (lazy, as intended)'}`)
}
