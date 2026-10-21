// Import a src/ .ts module from a node test (SPL-2170).
//
// The unit suite runs on plain node 20, which cannot load .ts. A util moved
// from .mjs to .ts keeps its node test by transpiling the file with
// typescript and importing the JS from a data: URL. A data: URL has no
// directory to resolve an import against, so each `~/` or relative
// specifier in the output is rewritten to the file: URL it names; the
// module may import .mjs files that way (they load as themselves, the same
// instance a test importing them directly gets). An extensionless specifier
// naming a .ts (SPL-2798: ws-doc-download -> save-blob, tree-drag ->
// touch-ui) is transpiled the same way and linked as its own data: URL, one
// per file, so a test importing that .ts too gets the same instance.
//
// Usage:
//   import { importTs } from './lib/load-ts.mjs'
//   const { fn } = await importTs('src/utils/<name>.ts')
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
const SRC = join(WUI, 'src')

/** The file `spec` names when it is `~/...` or relative to `from`, else null. */
function localPath(spec, from) {
  if (spec.startsWith('~/')) return join(SRC, spec.slice(2))
  if (spec.startsWith('./') || spec.startsWith('../')) return resolve(dirname(from), spec)
  return null
}

/** data: URL of each transpiled .ts, by absolute path. */
const linkedTs = new Map()

/** `spec` as an absolute URL: a .ts it names transpiled, any other local file as file:. */
function absolute(spec, from) {
  const path = localPath(spec, from)
  if (path === null) return spec
  if (!existsSync(path) && existsSync(path + '.ts')) return tsDataUrl(path + '.ts')
  return pathToFileURL(path).href
}

/** The .ts at absolute `file`, transpiled, its imports linked, as a data: URL. */
function tsDataUrl(file) {
  const known = linkedTs.get(file)
  if (known) return known
  const js = ts.transpileModule(readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
    fileName: file,
  }).outputText
  const linked = js.replace(/(\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)(['"])([^'"]+)\2/g,
    (_, head, q, spec) => head + q + absolute(spec, file) + q)
  // %27: the URL sits in a quoted specifier of the importing module
  const url = 'data:text/javascript,' + encodeURIComponent(linked).replace(/'/g, '%27')
  linkedTs.set(file, url)
  return url
}

/** The module at `rel` (relative to csi-spl-wui), transpiled and imported. */
export async function importTs(rel) {
  return import(tsDataUrl(join(WUI, rel)))
}
