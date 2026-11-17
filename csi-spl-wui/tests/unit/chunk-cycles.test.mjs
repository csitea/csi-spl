// SPL-5738 (F9, topic 955ab0bd): the built-chunk import-cycle check
// (src/node/test/chunk-cycles.mjs) sees the minified import forms, ignores a
// dynamic import, and fails a cycle and an empty read. CI runs the check
// itself on the generated bundle (10_ci-quality.yml, job wui-generate).
import { describe, it, after } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { staticImports, findCycles, checkChunkCycles } from '../../src/node/test/chunk-cycles.mjs'

const dirs = []
function bundle(files) {
  const dir = mkdtempSync(join(tmpdir(), 'chunk-cycles-'))
  dirs.push(dir)
  for (const [name, src] of Object.entries(files)) writeFileSync(join(dir, name), src)
  return dir
}
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }) })

describe('staticImports reads the minified forms Rollup emits', () => {
  it('named, bare, namespace and re-export imports are edges', () => {
    const src = 'import{a as b,c}from"./A1.js";import"./B2.js";import*as n from"./C3.js";export{x}from"./D4.js";export*from"./E5.js";'
    assert.deepEqual(staticImports(src).sort(), ['A1.js', 'B2.js', 'C3.js', 'D4.js', 'E5.js'])
  })
  it('a dynamic import() and a preload list are not edges', () => {
    const src = 'const m=()=>import("./L1.js");const d=["./L2.js"];__vitePreload(()=>import("./L3.js"),d)'
    assert.deepEqual(staticImports(src), [])
  })
})

describe('findCycles', () => {
  it('finds a two-chunk and a three-chunk cycle, and only those', () => {
    const g = new Map([['a', ['b']], ['b', ['a']], ['c', ['d']], ['d', ['e']], ['e', ['c']], ['f', ['a']]])
    assert.deepEqual(findCycles(g).map((c) => c.join(',')).sort(), ['a,b', 'c,d,e'])
  })
  it('an acyclic graph has none (an edge to a missing chunk is ignored)', () => {
    assert.deepEqual(findCycles(new Map([['a', ['b', 'vendor.js']], ['b', []]])), [])
  })
})

describe('checkChunkCycles on a bundle dir', () => {
  it('GREEN: entry -> lazy page chunks with no way back', () => {
    const dir = bundle({
      'entry.js': 'import{v}from"./vendor-vue.js";const p=()=>import("./page.js");',
      'page.js': 'import{v}from"./vendor-vue.js";import{h}from"./entry.js";',
      'vendor-vue.js': 'export const v=1;',
    })
    const r = checkChunkCycles(dir)
    assert.equal(r.code, 0, r.lines.join('\n'))
  })
  it('RED (control): one static back-edge makes a cycle and names it', () => {
    const dir = bundle({
      'TopBar.js': 'import{c}from"./Composer.js";export const wn=1;',
      'Composer.js': 'import{wn}from"./TopBar.js";export const c=wn;',
    })
    const r = checkChunkCycles(dir)
    assert.equal(r.code, 1)
    assert.match(r.lines.join('\n'), /CYCLE .*Composer\.js -> TopBar\.js -> Composer\.js/)
  })
  it('an empty or missing dir never passes', () => {
    assert.equal(checkChunkCycles(bundle({ 'x.css': '' })).code, 1)
    assert.equal(checkChunkCycles(join(tmpdir(), 'chunk-cycles-no-such-dir')).code, 1)
  })
})
