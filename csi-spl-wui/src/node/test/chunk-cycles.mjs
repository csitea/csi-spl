// SPL-5738 (F9 of topic 955ab0bd): no static import cycle between the built
// client chunks.
//
// WHY: a chunk that statically imports a chunk which (directly or through
// others) imports it back is evaluated before its own bindings exist on one
// of the two paths, and the browser throws
// `ReferenceError: Cannot access '<x>' before initialization` (a temporal
// dead zone). The prd error journal logged that class twice: KindBadge /
// KindPicker (CLE-77804, 568505aa2) and `wn` in TopBar / MessageComposer
// (12 rows, 2026-10-13). The build guard of 568505aa2 (nuxt.config.ts
// `onwarnFailAppCycles`) fails a MODULE cycle in app code; Rollup does not
// warn about a cycle that only the chunking creates (manualChunks, a shared
// chunk two lazy pages both pull), so this reads the emitted chunks.
//
// Only static edges count: `import ... from "./x.js"`, `import "./x.js"`,
// `export ... from "./x.js"`. A dynamic `import("./x.js")` runs after its
// importer has finished, so it cannot hit a TDZ and is not an edge.
//
// Run (CI wui-generate, after `pnpm run generate`):
//   node src/node/test/chunk-cycles.mjs .output/public/_nuxt
// Exit 0: no cycle. Exit 1: a cycle (each printed as a -> b -> a), or no
// chunk found (an empty read must never pass).
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const STATIC_IMPORT = /(?:^|[;}\s)])import\s*(?:[\w$*{][^;'"]*?from\s*)?["']\.\/([^"']+\.js)["']/g
const RE_EXPORT = /(?:^|[;}\s)])export\s*(?:\*|\{[^}]*\})\s*from\s*["']\.\/([^"']+\.js)["']/g

/** The chunks a chunk's source imports statically (file names, no "./"). */
export function staticImports(src) {
  const deps = new Set()
  for (const re of [STATIC_IMPORT, RE_EXPORT]) {
    for (const m of String(src).matchAll(re)) deps.add(m[1])
  }
  return [...deps]
}

/** Map chunk file name -> its static imports, for every *.js in dir. */
export function chunkGraph(dir) {
  const graph = new Map()
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.js')).sort()) {
    graph.set(f, staticImports(readFileSync(join(dir, f), 'utf8')))
  }
  return graph
}

/** Every strongly connected set of chunks that forms a cycle (Tarjan). */
export function findCycles(graph) {
  const index = new Map()
  const low = new Map()
  const stack = []
  const onStack = new Set()
  const cycles = []
  let next = 0
  const visit = (v) => {
    index.set(v, next); low.set(v, next); next++
    stack.push(v); onStack.add(v)
    for (const w of graph.get(v) || []) {
      if (!graph.has(w)) continue
      if (!index.has(w)) { visit(w); low.set(v, Math.min(low.get(v), low.get(w))) }
      else if (onStack.has(w)) low.set(v, Math.min(low.get(v), index.get(w)))
    }
    if (low.get(v) !== index.get(v)) return
    const scc = []
    let w
    do { w = stack.pop(); onStack.delete(w); scc.push(w) } while (w !== v)
    if (scc.length > 1 || (graph.get(v) || []).includes(v)) cycles.push(scc.sort())
  }
  for (const v of graph.keys()) if (!index.has(v)) visit(v)
  return cycles
}

/** One readable path through a cycle: a -> b -> ... -> a. */
export function cyclePath(graph, scc) {
  const inScc = new Set(scc)
  const path = [scc[0]]
  const seen = new Set(path)
  for (;;) {
    const cur = path[path.length - 1]
    const nxt = (graph.get(cur) || []).find((w) => inScc.has(w))
    if (!nxt || seen.has(nxt)) return [...path, nxt || scc[0]].join(' -> ')
    path.push(nxt); seen.add(nxt)
  }
}

/** Check dir; returns { code, lines } so the test drives it without a process. */
export function checkChunkCycles(dir) {
  if (!dir || !existsSync(dir)) return { code: 1, lines: [`chunk-cycles: no such dir: ${dir}`] }
  const graph = chunkGraph(dir)
  let edges = 0
  for (const deps of graph.values()) edges += deps.length
  if (graph.size === 0) return { code: 1, lines: [`chunk-cycles: no *.js chunk in ${dir}`] }
  const cycles = findCycles(graph)
  const head = `chunk-cycles: ${graph.size} chunks, ${edges} static imports, ${cycles.length} cycle(s)`
  if (!cycles.length) return { code: 0, lines: [head] }
  return { code: 1, lines: [head, ...cycles.map((c) => `  CYCLE (TDZ risk, SPL-5738): ${cyclePath(graph, c)}`)] }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const { code, lines } = checkChunkCycles(process.argv[2])
  for (const l of lines) (code ? console.error : console.log)(l)
  process.exit(code)
}
