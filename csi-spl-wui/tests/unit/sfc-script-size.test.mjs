// The WUI SFC script-size ratchet (r13-02): cleancode.test.mjs caps every
// function at MAX_LINES, but nothing capped the <script> of a .vue file, so a
// component could grow one short function at a time into a 2000-line script.
//
//   • a .vue whose <script> lines are over MAX_SCRIPT fails, unless BIG lists it
//   • a listed file that grows past its ceiling fails
//   • a listed file under its ceiling, or no longer over MAX_SCRIPT, is
//     reported so its ceiling comes down or its line goes
//
// Script lines of a file = every <script ...> block, opening and closing tag
// lines included, summed (a file may carry <script> and <script setup>).
//
// Run: node tests/unit/sfc-script-size.test.mjs
//      SFC_SCRIPT_PRINT=1 node tests/unit/sfc-script-size.test.mjs   # print today's big set
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const SRC = join(WUI, 'src')

const MAX_SCRIPT = 500

// `<file>` -> ceiling: its script lines on origin/master 2026-10-16 (r13-02).
// It may only shrink: decompose the component and lower or delete its line; a
// NEW file over MAX_SCRIPT fails.
const BIG = new Map([
  ['src/pages/issues.vue', 876],
  ['src/components/workspace-docs/WorkspaceDocView.vue', 677],
  ['src/components/workspace-docs/QtoFileTree.vue', 654],
  ['src/components/CalendarMainView.vue', 612],
])

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.vue')) out.push(p)
  }
  return out
}

// scriptLines(text) -> lines of every block that opens with `<script` and
// closes with `</script>` at the start of a line. Anchored at the line start
// so a `<script>` quoted in a template or comment is not a block.
export function scriptLines(text) {
  let total = 0
  let open = -1
  text.split('\n').forEach((line, i) => {
    if (open < 0 && /^<script\b/.test(line)) open = i
    if (open >= 0 && /^<\/script>/.test(line)) { total += i - open + 1; open = -1 }
  })
  return total
}

export function scan() {
  return walk(SRC).map((file) => ({ file: relative(WUI, file), lines: scriptLines(readFileSync(file, 'utf8')) }))
}

// checkScripts(sfcs, ceilings) -> { fails, notes, big }: a file over
// MAX_SCRIPT fails unless `ceilings` lists it, and fails above its ceiling.
export function checkScripts(sfcs, ceilings) {
  const fails = []
  const notes = []
  const big = new Map()
  for (const s of sfcs) {
    if (s.lines <= MAX_SCRIPT) continue
    big.set(s.file, s.lines)
    const cap = ceilings.get(s.file)
    if (cap === undefined) fails.push(`${s.file} has ${s.lines} script lines (> ${MAX_SCRIPT}): move logic into composables / subcomponents`)
    else if (s.lines > cap) fails.push(`${s.file} has ${s.lines} script lines, over its BIG ceiling ${cap}: decompose it, never raise the ceiling`)
  }
  for (const [f, cap] of ceilings) {
    const lines = big.get(f)
    if (lines === undefined) notes.push(`NOTE BIG: '${f}' is no longer over ${MAX_SCRIPT} script lines - delete its line`)
    else if (lines < cap) notes.push(`NOTE BIG: '${f}' has ${lines} script lines, under its ceiling ${cap} - lower the ceiling to ${lines}`)
  }
  return { fails, notes, big }
}

const sfcs = scan()
if (process.env.SFC_SCRIPT_PRINT) {
  for (const s of sfcs.filter((x) => x.lines > MAX_SCRIPT).sort((a, b) => b.lines - a.lines)) {
    console.log(`  ['${s.file}', ${s.lines}],`)
  }
  process.exit(0)
}

let failed = 0
const fail = (m) => { failed++; console.log(`  FAIL ${m}`) }
if (sfcs.length < 100) fail(`scanned only ${sfcs.length} .vue files under src: the walk is broken, not the code`)
if (!sfcs.some((s) => s.lines > 0)) fail('no .vue file has a <script> block: the measure is broken, not the code')

const { fails, notes, big } = checkScripts(sfcs, BIG)
for (const m of fails) fail(m)
for (const m of notes) console.log(`  ${m}`)

// Controls: the measure sees what it claims to.
const block = (n) => ['<script setup lang="ts">', ...Array(n - 2).fill('x'), '</script>'].join('\n')
if (scriptLines(`<template>\n</template>\n${block(10)}\n<style>\n</style>\n`) !== 10) fail('control: a 10-line <script> block did not read 10')
if (scriptLines(`${block(3)}\n${block(4)}\n`) !== 7) fail('control: two <script> blocks were not summed')
if (scriptLines('<template>\n  <p>a <script> in text</script></p>\n</template>\n') !== 0) fail('control: a <script> quoted mid-line counted as a block')

// Red control (r13-02): a new SFC with MAX_SCRIPT + 1 lines fails, MAX_SCRIPT
// passes; a listed one over its ceiling fails, under it prints the NOTE.
const fresh = (lines) => checkScripts([{ file: 'src/N.vue', lines }], new Map())
if (fresh(MAX_SCRIPT + 1).fails.length !== 1) fail(`control: a new SFC with ${MAX_SCRIPT + 1} script lines did not fail`)
if (fresh(MAX_SCRIPT).fails.length) fail(`control: a new SFC with ${MAX_SCRIPT} script lines did not pass`)
const grown = (lines) => checkScripts([{ file: 'src/G.vue', lines }], new Map([['src/G.vue', 900]]))
if (grown(901).fails.length !== 1) fail('control: a listed SFC grown 1 line past its ceiling did not fail')
if (grown(900).fails.length || grown(900).notes.length) fail('control: a listed SFC at its ceiling did not pass clean')
if (grown(899).fails.length || !grown(899).notes.some((n) => n.includes('lower the ceiling to 899'))) fail('control: a listed SFC under its ceiling printed no NOTE')

console.log(failed
  ? `\nsfc-script-size: ${failed} FAILED`
  : `sfc-script-size: ${sfcs.length} SFCs, ${big.size} listed over ${MAX_SCRIPT} script lines, none past its ceiling`)
process.exit(failed ? 1 : 0)
