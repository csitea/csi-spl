// Import a src/ .ts module from a node test (SPL-2170).
//
// The unit suite runs on plain node 20, which cannot load .ts. A util moved
// from .mjs to .ts keeps its node test by transpiling the file with
// typescript and importing the JS from a data: URL. A data: URL has no
// directory to resolve an import against, so each `~/` or relative
// specifier in the output is rewritten to the file: URL it names; the
// module may import .mjs files that way (they load as themselves, the same
// instance a test importing them directly gets), never another .ts.
//
// Usage:
//   import { importTs } from './lib/load-ts.mjs'
//   const { fn } = await importTs('src/utils/<name>.ts')
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
const SRC = join(WUI, 'src')

/** `spec` as an absolute file: URL when it is `~/...` or relative to `from`. */
function absolute(spec, from) {
  if (spec.startsWith('~/')) return pathToFileURL(join(SRC, spec.slice(2))).href
  if (spec.startsWith('./') || spec.startsWith('../')) return pathToFileURL(resolve(dirname(from), spec)).href
  return spec
}

/** The module at `rel` (relative to csi-spl-wui), transpiled and imported. */
export async function importTs(rel) {
  const file = join(WUI, rel)
  const js = ts.transpileModule(readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
    fileName: rel,
  }).outputText
  const linked = js.replace(/(\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)(['"])([^'"]+)\2/g,
    (_, head, q, spec) => head + q + absolute(spec, file) + q)
  return import('data:text/javascript,' + encodeURIComponent(linked))
}
