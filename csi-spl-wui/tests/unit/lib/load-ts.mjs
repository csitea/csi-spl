// Import a self-contained src/ .ts module from a node test (SPL-2170).
//
// The unit suite runs on plain node 20, which cannot load .ts. A util moved
// from .mjs to .ts keeps its node test by transpiling the file with
// typescript and importing the JS from a data: URL. Only a module with no
// relative or `~/` import of its own works this way: a data: URL has no
// directory to resolve one against.
//
// Usage:
//   import { importTs } from './lib/load-ts.mjs'
//   const { fn } = await importTs('src/utils/<name>.ts')
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')

/** The module at `rel` (relative to csi-spl-wui), transpiled and imported. */
export async function importTs(rel) {
  const js = ts.transpileModule(readFileSync(join(WUI, rel), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
    fileName: rel,
  }).outputText
  return import('data:text/javascript,' + encodeURIComponent(js))
}
