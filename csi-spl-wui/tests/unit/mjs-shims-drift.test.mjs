// src/types/mjs-shims.d.ts is the output of src/node/generate-mjs-shims.mjs
// for the .mjs code on disk (SPL-1751, ui panel 2026-10-13 item 10): a module
// that drops an export, gains one the SFC side imports, or takes a parameter
// the shim does not declare fails here, not later in typecheck or at runtime.
// The controls plant each drift and prove the generator sees it.
//
// Run: node tests/unit/mjs-shims-drift.test.mjs
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { HEADER, reconcile, scanModule, tscInfer } from '../../src/node/generate-mjs-shims.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const GEN = join(__dirname, '../../src/node/generate-mjs-shims.mjs')

let failed = 0
let passed = 0
const ok = (cond, msg) => {
  if (cond) passed++
  else { failed++; console.log(`  FAIL ${msg}`) }
}

// 1. The real tree: the shim on disk is the generator's output, no drift.
const run = spawnSync(process.execPath, [GEN, '--check'], { encoding: 'utf8' })
ok(run.status === 0, `generate-mjs-shims --check exits ${run.status}:\n${run.stdout}${run.stderr}`)

// 2. Controls on a synthetic shim.
const SHIM = HEADER + `declare module '~/utils/a.mjs' {
  /** one */
  export function keep(x: string, y?: number): string
  export function gone(): void
  export const LIMIT: number
  export type Row = { id: string }
}

// between blocks
declare module '~/utils/b.mjs' {
  export function rest(...args: unknown[]): void
}

declare module '~/utils/missing.mjs' {
  export const X: number
}
`
const mods = {
  '~/utils/a.mjs': scanModule('export function keep(x, y = 1) {}\nexport const LIMIT = 3\nexport function fresh(a) { return a }\n'),
  '~/utils/b.mjs': scanModule('export function rest(a, b, c) {}\n'),
  '~/utils/missing.mjs': null,
}
const env = (over = {}) => ({ loadModule: (s) => mods[s], imports: new Map(), ...over })

{
  const { text, problems } = reconcile(SHIM, env())
  ok(problems.some((p) => p.includes('declares gone')), 'a removed export is reported')
  ok(!text.includes('gone()') && text.includes('/** one */\n  export function keep'), 'a removed export is dropped, its neighbours kept')
  ok(text.includes('export type Row'), 'a type has no runtime twin and stays')
  ok(problems.some((p) => p.startsWith('~/utils/missing.mjs')) && !text.includes('missing.mjs'), 'a block for a missing file is removed')
  ok(!problems.some((p) => p.includes('rest takes')), 'a rest parameter covers any arity')
  ok(text.includes('// between blocks'), 'text between blocks is kept')
}
{
  const { problems } = reconcile(SHIM.replace('keep(x: string, y?: number)', 'keep(x: string)'), env())
  ok(problems.some((p) => p.includes('keep takes 1..2 parameters, the shim declares 1..1')), 'a parameter the shim does not declare is reported')
}
{
  const imports = new Map([['~/utils/a.mjs', new Set(['fresh', 'keep', 'notExported'])]])
  const { problems } = reconcile(SHIM, env({ imports }))
  const added = problems.filter((p) => p.includes('not declared'))
  ok(added.length === 1 && added[0].includes('fresh'), `an imported, undeclared export is reported once (${added.length})`)
  const fill = reconcile(SHIM, env({ imports, infer: () => 'export function fresh(a: unknown): unknown;' }))
  ok(fill.text.includes('  export const LIMIT: number\n  export type Row = { id: string }\n  export function fresh(a: unknown): unknown;\n}'), 'the inferred declaration lands at the end of its block')
  const elsewhere = new Map([['~/utils/a.mjs', []]])
  ok(reconcile(SHIM, env({ imports, elsewhere })).problems.some((p) => p.includes('fresh')), 'another .d.ts without the name does not hide it')
}
{
  const clean = HEADER + `declare module '~/utils/a.mjs' {\n  export function keep(x: string, y?: number): string\n}\n`
  const r = reconcile(clean, env())
  ok(r.text === clean && r.problems.length === 0, 'a shim in step with its code is its own output')
  ok(reconcile(clean.slice(HEADER.length), env()).text === clean, 'the header is added when missing')
}

// 3. The export scanner and tsc inference on real JS.
{
  const m = scanModule('export { a as b, c }\nexport default function () {}\nexport * from "./x.mjs"\nexport const f = (p, q) => p\n', 'm.mjs', () => new Map([['fromX', { arity: null }]]))
  ok(['b', 'c', 'default', 'fromX', 'f'].every((n) => m.has(n)) && !m.has('a'), `scanModule names: ${[...m.keys()]}`)
  ok(m.get('f').arity.total === 2, 'an exported arrow function has its arity')
  const dir = mkdtempSync(join(tmpdir(), 'mjs-shims-'))
  try {
    writeFileSync(join(dir, 'x.mjs'), 'export function add(a = 1, b = 2) { return a + b }\n')
    const decl = tscInfer(dir)('~/x.mjs', 'add')
    ok(decl === 'export function add(a?: number, b?: number): number;', `tsc infers a typed declaration: ${decl}`)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

console.log(failed
  ? `\nmjs-shims-drift: ${failed} FAILED, ${passed} passed`
  : `mjs-shims-drift: all ${passed} checks passed`)
process.exit(failed ? 1 : 0)
