// writeClipboard (CLE-77915, refactor item 25): one copy path, with the
// insecure-origin fallback, for every "copy" in the WUI.
// Run: node tests/unit/clipboard.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeClipboard } from '../../src/utils/clipboard.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

function env({ api = true, exec = true } = {}) {
  const log = []
  const ta = { style: {}, setAttribute: () => {}, select: () => log.push('select'), remove: () => log.push('remove') }
  return {
    log,
    nav: { clipboard: { writeText: async (t) => { if (!api) throw new Error('denied'); log.push('api ' + t) } } },
    doc: {
      createElement: () => ta,
      body: { appendChild: () => log.push('append') },
      execCommand: (c) => { if (exec === 'throw') throw new Error('nope'); log.push('exec ' + c); return exec },
    },
  }
}

test('the Clipboard API is used when it works, and nothing else', async () => {
  const e = env()
  assert.equal(await writeClipboard('abc', e), true)
  assert.deepEqual(e.log, ['api abc'])
})

test('a refused Clipboard API falls back to the selection copy, which cleans up after itself', async () => {
  const e = env({ api: false })
  assert.equal(await writeClipboard('abc', e), true)
  assert.deepEqual(e.log, ['append', 'select', 'exec copy', 'remove'])
})

test('both refused -> false, never a throw', async () => {
  assert.equal(await writeClipboard('x', env({ api: false, exec: false })), false)
  assert.equal(await writeClipboard('x', env({ api: false, exec: 'throw' })), false)
})

test('no component or composable calls the Clipboard API on its own', () => {
  const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])
  const own = walk(SRC).filter((f) => /\.(vue|ts|mjs)$/.test(f) && !f.endsWith('utils/clipboard.mjs') && !f.endsWith('.d.ts'))
    .filter((f) => /navigator\.clipboard|execCommand\(\s*'copy'/.test(readFileSync(f, 'utf8')))
    .map((f) => relative(SRC, f))
  assert.deepEqual(own, [])
})
