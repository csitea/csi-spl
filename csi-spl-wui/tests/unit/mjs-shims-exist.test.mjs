// Every name src/types/mjs-shims.d.ts declares for a `~/…/*.mjs` module is
// really exported by that module (CLE-77915, refactor item 2). The shim is
// hand-written, so typecheck trusts it blindly: on 2026-10-01 it declared 17
// names their modules did not export (16 of them under `~/utils/issues.mjs`,
// copies of issues-view.mjs), and a caller would have typechecked green and
// crashed at runtime.
//
// Run: node tests/unit/mjs-shims-exist.test.mjs
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SRC = join(__dirname, '../../src')

const shim = readFileSync(join(SRC, 'types/mjs-shims.d.ts'), 'utf8')
const modules = [...shim.matchAll(/declare module '~\/([^']+\.mjs)' \{([\s\S]*?)\n\}/g)]

let failed = 0
let names = 0
const exported = (src, n) =>
  new RegExp(`export\\s+(?:async\\s+)?(?:function\\*?|const|let|class)\\s+${n}\\b`).test(src)
  || new RegExp(`export\\s*\\{[^}]*\\b${n}\\b`).test(src)

if (modules.length === 0) {
  console.log('  FAIL no `declare module` block found — the check would pass vacuously')
  failed++
}
for (const [, rel, body] of modules) {
  if (!existsSync(join(SRC, rel))) {
    console.log(`  FAIL ~/${rel}: declared, but no such file`)
    failed++
    continue
  }
  const src = readFileSync(join(SRC, rel), 'utf8')
  for (const [, n] of body.matchAll(/^\s*export (?:function|const|let|class) (\w+)/gm)) {
    names++
    if (!exported(src, n)) {
      console.log(`  FAIL ~/${rel}: declares ${n}, the module does not export it`)
      failed++
    }
  }
}

// Control: the matcher must see a missing name as missing.
if (exported('export const a = 1', 'b') || !exported('export function b() {}', 'b')) {
  console.log('  FAIL control: the export matcher is broken')
  failed++
}

console.log(failed
  ? `\nmjs-shims-exist: ${failed} FAILED`
  : `mjs-shims-exist: all ${names} declared names exist in ${modules.length} modules`)
process.exit(failed ? 1 : 0)
