// Every name src/types/mjs-shims.d.ts declares for a `~/…/*.mjs` module is
// really exported by that module (CLE-77915, refactor item 2). The shim is
// hand-written, so typecheck trusts it blindly: on 2026-10-01 it declared 17
// names their modules did not export (16 of them under `~/utils/issues.mjs`,
// copies of issues-view.mjs), and a caller would have typechecked green and
// crashed at runtime.
//
// SHIMS_CAP (r42-09): the number of `declare module` blocks may only fall.
// Shims went 98 -> 103 in four days (retro 16, 4.1) with nothing to stop
// them; a new .mjs module that a .ts / .vue file imports now fails here unless
// it is written as .ts or another leaf is converted. Under the cap prints a
// NOTE: lower SHIMS_CAP to the new count in the same commit.
//
// Run: node tests/unit/mjs-shims-exist.test.mjs
import { readFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const SRC = join(__dirname, '../../src')

const shim = readFileSync(join(SRC, 'types/mjs-shims.d.ts'), 'utf8')
const SHIMS_CAP = 102
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

const capCheck = (n) => n > SHIMS_CAP
  ? { fail: `${n} \`declare module\` blocks in src/types/mjs-shims.d.ts, over SHIMS_CAP ${SHIMS_CAP}: it may only fall. Write the new module as .ts, or convert a leaf (node src/node/generate-mjs-shims.mjs --leaves)` }
  : n < SHIMS_CAP ? { note: `NOTE SHIMS_CAP: ${n} blocks, under SHIMS_CAP ${SHIMS_CAP} - lower SHIMS_CAP to ${n}` } : {}
const countBlocks = (text) => (text.match(/^\s*declare\s+module\b/gm) || []).length
const blocks = countBlocks(shim)
const cap = capCheck(blocks)
if (cap.fail) {
  console.log(`  FAIL ${cap.fail}`)
  failed++
}
if (cap.note) console.log(`  ${cap.note}`)

// Control: one block over the cap fails with the cap in the message; at the
// cap passes clean; one under prints the NOTE; an indented block counts.
if (countBlocks("declare module 'a' {\n}\n  declare module \"b\" {\n}\n// declare module c\n") !== 2) {
  console.log('  FAIL control: countBlocks missed an indented or double-quoted block, or counted a comment')
  failed++
}
if (!capCheck(SHIMS_CAP + 1).fail?.includes(`SHIMS_CAP ${SHIMS_CAP}`) || capCheck(SHIMS_CAP).fail
  || !capCheck(SHIMS_CAP - 1).note) {
  console.log('  FAIL control: the SHIMS_CAP check is broken')
  failed++
}

// Control: the matcher must see a missing name as missing.
if (exported('export const a = 1', 'b') || !exported('export function b() {}', 'b')) {
  console.log('  FAIL control: the export matcher is broken')
  failed++
}

console.log(failed
  ? `\nmjs-shims-exist: ${failed} FAILED`
  : `mjs-shims-exist: all ${names} declared names exist in ${modules.length} modules (${blocks} blocks <= cap ${SHIMS_CAP})`)
process.exit(failed ? 1 : 0)
