// Perf round 3, P3-06: split each locale catalogue at build time into the
// messages the first screen can show (core, loaded with the entry) and the
// rest (loaded by src/plugins/i18n-more.client.ts before any other page, and
// when the browser is idle). i18n/locales/<code>.json stays the one place a
// message is written; nuxt.config.ts writes the split copies to
// i18n/.split/ (git-ignored) and points the i18n module at the core ones.
// The rest is written as a module of already compiled messages, the same
// code @nuxtjs/i18n's unplugin-vue-i18n makes of a locale file it loads:
// vue-i18n ships runtime-only (CLE-35075) and cannot compile a message.
//
// Core = every key a file reachable from the first screen names: the
// first-screen pages (src/utils/i18n-first-screen.mjs), app.vue, error.vue,
// the layouts, plugins, middleware and src/app, and everything they import,
// render as a component (lazy ones too) or call as an auto-imported
// composable or store. A literal keeps every key that starts with it: a
// subtree (`'issues.status.'`), a template literal cut at `${`
// (`` `social_auth.continue_${p}` ``), a suffixed sibling (`..._enter`). The graph
// over-approximates on purpose: a key wrongly in core costs bytes, a key
// wrongly left out renders as its key until the rest arrives.
//
// Usage:
//   node src/node/i18n/split-catalogue.mjs           # print the split per locale
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { generateJSON } from "@intlify/bundle-utils"
import { FIRST_SCREEN_PAGES, ON_DEMAND_COMPONENTS } from "../../utils/i18n-first-screen.mjs"

const __dirname = dirname(fileURLToPath(import.meta.url))
export const WUI = join(__dirname, "../../..")
export const SRC = join(WUI, "src")
export const LOCALES_DIR = join(WUI, "i18n/locales")
export const SPLIT_DIR = join(WUI, "i18n/.split")

const CODE_EXT = /\.(vue|ts|mjs|js)$/
// Not app code: build/test tooling, python, docker, static files.
const SKIP_DIRS = new Set(["node", "python", "docker", "public"])

function walk(dir, out = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n)
    if (statSync(p).isDirectory()) {
      if (dir === SRC && SKIP_DIRS.has(n)) continue
      walk(p, out)
    } else if (CODE_EXT.test(n) && !n.endsWith(".d.ts")) out.push(p)
  }
  return out
}

function pascal(seg) {
  return seg.split(/[-_]/).filter(Boolean).map((s) => s[0].toUpperCase() + s.slice(1)).join("")
}
function kebab(name) {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase()
}

/** Nuxt's auto-import name of a component file (components/common/DebugPanel.vue -> CommonDebugPanel). */
function componentName(file) {
  const rel = relative(join(SRC, "components"), file).replace(/\.vue$/, "")
  const segs = rel.split("/").map(pascal)
  // Nuxt drops a directory prefix the file name already starts with.
  const last = segs.pop()
  const prefix = segs.join("")
  return last.startsWith(prefix) ? last : prefix + last
}

const IMPORT_RE = /(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)["'`]([^"'`]+)["'`]/g
const EXPORT_RE = /\bexport\s+(?:default\s+)?(?:async\s+)?(?:function\*?|const|let|class)\s+([A-Za-z_$][\w$]*)/g

function resolveImport(from, spec) {
  let base
  if (spec.startsWith("~/") || spec.startsWith("@/")) base = join(SRC, spec.slice(2))
  else if (spec.startsWith(".")) base = resolve(dirname(from), spec)
  else return null
  for (const cand of [base, ...[".ts", ".mjs", ".js", ".vue"].map((e) => base + e), join(base, "index.ts"), join(base, "index.mjs")]) {
    if (existsSync(cand) && statSync(cand).isFile()) return cand
  }
  return null
}

/**
 * Every source file the first screen can execute or render.
 * @returns {Set<string>} absolute paths
 */
export function firstScreenFiles() {
  const all = walk(SRC)
  const text = new Map(all.map((f) => [f, readFileSync(f, "utf8")]))
  const pages = all.filter((f) => f.startsWith(join(SRC, "pages") + "/"))
  const comps = new Map()
  for (const f of all.filter((f) => f.startsWith(join(SRC, "components") + "/") && f.endsWith(".vue"))) {
    const n = componentName(f)
    comps.set(n, f)
    comps.set(kebab(n), f)
  }
  // Auto-imported composables and stores, by exported name.
  const autos = new Map()
  for (const f of all) {
    const r = relative(SRC, f)
    if (!/^(composables|stores|utils)\/[^/]+$/.test(r)) continue
    for (const m of text.get(f).matchAll(EXPORT_RE)) if (m[1].length > 3) autos.set(m[1], f)
  }
  const entries = [
    ...Object.values(FIRST_SCREEN_PAGES).map((p) => join(SRC, p)),
    ...all.filter((f) => /^(app\.vue|error\.vue|(layouts|plugins|middleware|app)\/)/.test(relative(SRC, f))),
  ]
  // Mounted only behind a gate the runtime loader awaits (i18n-first-screen.mjs).
  const onDemand = new Set(Object.keys(ON_DEMAND_COMPONENTS).map((p) => join(SRC, p)))
  const seen = new Set()
  const queue = [...entries]
  while (queue.length) {
    const f = queue.pop()
    if (seen.has(f) || !text.has(f)) continue
    seen.add(f)
    const src = text.get(f)
    const next = []
    for (const m of src.matchAll(IMPORT_RE)) next.push(resolveImport(f, m[1]))
    for (const m of src.matchAll(/<(?:Lazy|lazy-)?([A-Za-z][\w-]*)/g)) next.push(comps.get(m[1]))
    for (const m of src.matchAll(/resolveComponent\(\s*["'](?:Lazy)?([\w-]+)["']/g)) next.push(comps.get(m[1]))
    for (const m of src.matchAll(/\b([A-Za-z_$][\w$]{3,})\s*\(/g)) next.push(autos.get(m[1]))
    for (const n of next) {
      // Another page is reached through the router, never by the first screen.
      if (n && !seen.has(n) && !onDemand.has(n) && !(pages.includes(n) && !entries.includes(n))) queue.push(n)
    }
  }
  return seen
}

/** Dotted leaf keys of a catalogue object. */
export function leafKeys(obj, prefix = "", out = []) {
  for (const [k, v] of Object.entries(obj)) {
    const key = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === "object" && !Array.isArray(v)) leafKeys(v, key, out)
    else out.push(key)
  }
  return out
}

/**
 * The keys of `catalogue` the given files name: every key that starts with a
 * quoted literal naming a key or a key prefix.
 */
export function keysNamedBy(files, catalogue) {
  const leaves = leafKeys(catalogue)
  const ns = Object.keys(catalogue).sort((a, b) => b.length - a.length).map((n) => n.replace(/[-]/g, "\\-"))
  const lit = new RegExp(`["'\`]((?:${ns.join("|")})(?:\\.[A-Za-z0-9_-]+)*\\.?)(?=["'\`]|\\$\\{)`, "g")
  // Every key that starts with a literal: a subtree (`'issues.status.' + s`),
  // a template cut at `${` (`` `social_auth.continue_${p}` ``) and a suffixed
  // sibling (useSubmitKey: `search.placeholder_target` -> `..._enter`).
  const starts = new Set()
  for (const f of files) {
    const src = readFileSync(f, "utf8")
    for (const m of src.matchAll(lit)) {
      const p = m[1]
      if (p.includes(".") || src[m.index + 1 + p.length] === "$") starts.add(p)
    }
  }
  const keep = new Set()
  for (const k of leaves) if ([...starts].some((p) => k.startsWith(p))) keep.add(k)
  return keep
}

/** Split a catalogue into the kept keys (core) and the rest (more). */
export function splitCatalogue(catalogue, keep, prefix = "") {
  const core = {}
  const more = {}
  for (const [k, v] of Object.entries(catalogue)) {
    const key = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const sub = splitCatalogue(v, keep, key)
      if (Object.keys(sub.core).length) core[k] = sub.core
      if (Object.keys(sub.more).length) more[k] = sub.more
    } else if (keep.has(key)) core[k] = v
    else more[k] = v
  }
  return { core, more }
}

// Perf round 3, P3-20: the compiled form of a message without a placeholder,
// link, plural or escape is a fixed AST around its text. 1 123 of 1 271 `en`
// messages are that; as the plain string they are about a third the bytes,
// and nothing for vue-i18n to deep-copy or proxy. i18n/i18n.config.ts gives
// vue-i18n a message compiler that turns such a string back into exactly
// what the AST would have produced.
const STATIC_AST = /\{"t":0,"b":\{"t":2,"i":\[\{"t":3\}\],"s":("(?:[^"\\]|\\.)*")\}\}/g

/** Compiled-catalogue module code with every static message as its plain string. */
export function plainStatics(code) {
  return code.replace(STATIC_AST, "$1")
}

/** A catalogue as the ES module unplugin-vue-i18n would make of it (compiled messages). */
export function compiledModule(catalogue, filename) {
  return plainStatics(generateJSON(JSON.stringify(catalogue), {
    type: "plain",
    filename,
    env: "production",
    jit: true,
    isGlobal: false,
    allowDynamic: true,
    strictMessage: true,
    escapeHtml: false,
    forceStringify: false,
    onlyLocales: [],
    onError: (msg) => {
      throw new Error(`${filename}: ${msg}`)
    },
  }).code) + "\n"
}

/**
 * Write i18n/.split/<code>.json (core) and i18n/.split/more/<code>.mjs (the rest, compiled) for
 * every locale. The core key set comes from the `en` catalogue and is the same
 * for every locale. Unchanged files are not rewritten (no needless rebuild).
 * @param {string[]} files locale file names, e.g. ["en.json", "bg.json"]
 * @returns {{ core: number, more: number }} key counts
 */
export function writeSplitCatalogues(files, { sourceLocale = "en.json", outDir = SPLIT_DIR } = {}) {
  const keep = keysNamedBy(firstScreenFiles(), JSON.parse(readFileSync(join(LOCALES_DIR, sourceLocale), "utf8")))
  mkdirSync(join(outDir, "more"), { recursive: true })
  let counts = { core: 0, more: 0 }
  for (const file of files) {
    const cat = JSON.parse(readFileSync(join(LOCALES_DIR, file), "utf8"))
    const { core, more } = splitCatalogue(cat, keep)
    if (file === sourceLocale) counts = { core: leafKeys(core).length, more: leafKeys(more).length }
    const morePath = join(outDir, "more", file.replace(/\.json$/, ".mjs"))
    for (const [p, body] of [[join(outDir, file), JSON.stringify(core, null, 1) + "\n"], [morePath, compiledModule(more, morePath)]]) {
      if (!existsSync(p) || readFileSync(p, "utf8") !== body) writeFileSync(p, body)
    }
  }
  return counts
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const files = readdirSync(LOCALES_DIR).filter((n) => n.endsWith(".json"))
  const counts = writeSplitCatalogues(files)
  console.log(`core ${counts.core} keys, more ${counts.more} keys (en); written to ${relative(WUI, SPLIT_DIR)}/`)
}
