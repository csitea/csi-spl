// Ratchet for prose docs on exported utils (refactor round 3, row 22).
// An `export function` / `export async function` with no /** */ above it
// counts. The count per src/utils/*.mjs may not rise. The five row-22
// modules are pinned at 0. Ceilings are the other modules' counts on the
// tree where those five were still bare (pane-widths 14/24, verbosity 6/6,
// slash-focus 5/6, font-size 5/7, theme 4/7). Types stay in mjs-shims.d.ts;
// this file does not require @param tags.
//
// Run: node tests/unit/util-docs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const UTILS = join(dirname(fileURLToPath(import.meta.url)), '../../src/utils')

/** Names of exported functions whose nearest non-blank line above is not a JSDoc. */
export function bareExportNames(text) {
  const lines = text.split('\n')
  const names = []
  let total = 0
  for (let i = 0; i < lines.length; i++) {
    const m = /^export (?:async )?function (\w+)/.exec(lines[i])
    if (!m) continue
    total++
    if (!docAbove(lines, i)) names.push(m[1])
  }
  return { bare: names.length, total, names }
}

function docAbove(lines, i) {
  let j = i - 1
  while (j >= 0 && lines[j].trim() === '') j--
  if (j < 0) return false
  const prev = lines[j]
  if (/^\s*\/\*\*.*\*\/\s*$/.test(prev)) return true
  if (!/^\s*\*\/\s*$/.test(prev)) return false
  for (let k = j; k >= 0 && j - k < 80; k--) {
    if (/^\s*\/\*\*/.test(lines[k])) return true
    if (/^\s*\/\*(?!\*)/.test(lines[k])) return false
  }
  return false
}

// Pinned at 0 by this row. A new export here needs a doc in the same commit.
const PIN_ZERO = [
  'font-size.mjs',
  'pane-widths.mjs',
  'slash-focus.mjs',
  'theme.mjs',
  'verbosity.mjs',
]

// Floor on how many exports the scanner must see, so a blind walk cannot pass.
const PIN_TOTAL_AT_LEAST = {
  'font-size.mjs': 7,
  'pane-widths.mjs': 24,
  'slash-focus.mjs': 6,
  'theme.mjs': 7,
  'verbosity.mjs': 6,
}

// bare count at landing for every other module that was already above 0.
// A module absent from this map has a ceiling of 0.
const CEILING = {
  'auth-client.mjs': 2,
  'avatar.mjs': 4,
  'card-clip.mjs': 6,
  'channel-feed.mjs': 10,
  'channel-members.mjs': 2,
  'checkout-client.mjs': 2,
  'code-blocks.mjs': 1,
  'fleet-load.mjs': 1,
  'id-link-gate.mjs': 4,
  'id-links.mjs': 1,
  'issues-colw.mjs': 2,
  'issues-view.mjs': 3,
  'issues.mjs': 1,
  'link-target.mjs': 1,
  'live-ws.mjs': 3,
  'mention-autocomplete.mjs': 1,
  'mention-poke.mjs': 1,
  'mock-data.mjs': 1,
  'move.mjs': 2,
  'msg-kind.mjs': 1,
  'msg-menu.mjs': 1,
  'notify.mjs': 20,
  'parent-section-open.mjs': 1,
  'place-popover.mjs': 3,
  'prefs.mjs': 4,
  'rail-order.mjs': 1,
  'read-cursor.mjs': 6,
  'spool-client.mjs': 3,
  'tenant-host-boot.mjs': 1,
  'tenant-settings-mock.mjs': 1,
  'tenant.mjs': 1,
  'undo-timer.mjs': 1,
  'view-api.mjs': 2,
  'view-prefs.mjs': 4,
}

function readUtil(name) {
  return readFileSync(join(UTILS, name), 'utf8')
}

describe('util doc ratchet', () => {
  it('a JSDoc above an export counts; a block comment or a line comment does not', () => {
    assert.deepEqual(bareExportNames('export function a() {}\n').names, ['a'])
    assert.equal(bareExportNames('/** d */\nexport function a() {}\n').bare, 0)
    assert.equal(bareExportNames('/**\n * d\n */\nexport function a() {}\n').bare, 0)
    assert.equal(bareExportNames('/** d */\n\nexport async function a() {}\n').bare, 0)
    assert.deepEqual(bareExportNames('/* not a doc */\nexport function a() {}\n').names, ['a'])
    assert.deepEqual(bareExportNames('// note\nexport function a() {}\n').names, ['a'])
    assert.equal(bareExportNames('export const A = 1\n').total, 0)
  })

  it('the five row-22 modules export nothing without a doc', () => {
    for (const name of PIN_ZERO) {
      const r = bareExportNames(readUtil(name))
      assert.equal(r.bare, 0, `${name} undocumented: ${r.names.join(', ')}`)
      assert.ok(r.total >= PIN_TOTAL_AT_LEAST[name], `${name} saw ${r.total} exports`)
    }
  })

  it('no src/utils module has more undocumented exports than its ceiling', () => {
    const names = readdirSync(UTILS).filter((f) => f.endsWith('.mjs')).sort()
    const over = []
    for (const name of names) {
      if (PIN_ZERO.includes(name)) continue
      const r = bareExportNames(readUtil(name))
      const cap = Object.hasOwn(CEILING, name) ? CEILING[name] : 0
      if (r.bare > cap) over.push(`${name} ${r.bare} > ${cap}: ${r.names.join(', ')}`)
      else if (Object.hasOwn(CEILING, name) && r.bare < cap) {
        console.log(`  NOTE ${name} is ${r.bare}, ceiling ${cap} — the ceiling may shrink`)
      }
    }
    const onDisk = new Set(names)
    for (const name of Object.keys(CEILING)) {
      if (!onDisk.has(name)) console.log(`  NOTE ceiling ${name} is gone — delete its line`)
    }
    assert.deepEqual(over, [])
  })

  it('pins the row-22 notes that are not just a missing doc', () => {
    const verbosity = readUtil('verbosity.mjs')
    assert.match(verbosity, /export const STORAGE_KEY = 'spool\.verbosity'/)
    assert.match(verbosity, /<FEATURE>_KEY/)
    assert.match(verbosity, /Returns a copy/)
    const font = readUtil('font-size.mjs')
    const theme = readUtil('theme.mjs')
    for (const src of [font, theme]) {
      assert.match(src, /localStorage via prefs\.mjs/)
      assert.match(src, /blocked store returns fallback/)
    }
    const panes = readUtil('pane-widths.mjs')
    assert.match(panes, /No app module imports it/)
  })
})
