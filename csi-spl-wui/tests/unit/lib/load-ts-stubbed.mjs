// Import a src/ .ts module whose imports a node test cannot load (r52-01).
//
// importTs (load-ts.mjs) has no answer for a composable: a runtime `from 'vue'`
// fails on a data: URL, and its real imports reach vue-router and pinia. Here
// `vue` is resolved from this package, each specifier named in `stubs` becomes
// a module exporting that object's keys, other `~/` imports stay real, and any
// other specifier throws, so a new import fails the test instead of hiding.
// Not cached: each call is its own instance with its own stubs.
//
// Usage:
//   import { importTsStubbed } from './lib/load-ts-stubbed.mjs'
//   const { fn } = await importTsStubbed('src/composables/<name>.ts', { '~/composables/useMove': { useMove } })
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
const asModule = (js) => 'data:text/javascript,' + encodeURIComponent(js).replace(/'/g, '%27')
/* a data: module reaches its stub's values only through a global */
const live = (globalThis.__tsStubs ??= [])

/** A module exporting the keys of `stub`. */
function stubUrl(stub) {
  const at = live.push(stub) - 1
  return asModule(`export const { ${Object.keys(stub).join(', ')} } = globalThis.__tsStubs[${at}]`)
}

/** The .ts at absolute `file`, transpiled, its specifiers swapped, as a data: URL. */
function linkTs(file, stubs) {
  const swap = (spec) => {
    if (Object.hasOwn(stubs, spec)) return stubUrl(stubs[spec])
    if (spec === 'vue') return import.meta.resolve('vue')
    const path = spec.startsWith('~/') ? join(WUI, 'src', spec.slice(2)) : ''
    if (path && existsSync(path)) return pathToFileURL(path).href
    if (path && existsSync(path + '.ts')) return linkTs(path + '.ts', stubs)
    throw new Error(`importTsStubbed: ${file} imports ${spec}: stub it, or import a real ~/ file`)
  }
  const { outputText } = ts.transpileModule(readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
    fileName: file,
  })
  return asModule(outputText.replace(/(\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)(['"])([^'"]+)\2/g,
    (_, head, q, spec) => head + q + swap(spec) + q))
}

/** The module at `rel` (relative to csi-spl-wui) with the imports named in `stubs` swapped. */
export async function importTsStubbed(rel, stubs = {}) {
  return import(linkTs(join(WUI, rel), stubs))
}
