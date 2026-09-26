import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  V1_KINDS,
  verbosityOf,
  messageVisible,
  applyVerbosity,
  loadVerbosity,
  saveVerbosity,
  parseLevel,
  STORAGE_KEY,
  DEFAULT_LEVEL,
} from '../../src/utils/verbosity.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const REPO = join(dirname(fileURLToPath(import.meta.url)), '../../..')

function v1KindsFromMsgGo() {
  const src = readFileSync(join(REPO, 'csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go'), 'utf8')
  const block = src.match(/validKinds\s*=\s*map\[string\]bool\{([^}]+)\}/)
  assert.ok(block, 'validKinds map in msg.go')
  return [...block[1].matchAll(/"([^"]+)":\s*true/g)].map((m) => m[1]).sort()
}

describe('verbosity from kind', () => {
  it('covers every v:1 kind from msg.go validKinds (inner of wire.Envelope.Msg)', () => {
    const fromGo = v1KindsFromMsgGo()
    assert.deepEqual(fromGo, ['blocker', 'msg', 'note', 'reject', 'result', 'task'])
    assert.deepEqual([...V1_KINDS].sort(), fromGo)
    for (const kind of fromGo) {
      assert.equal(['minimal', 'normal', 'verbose'].includes(verbosityOf(kind)), true, kind)
    }
  })

  it('maps task/result/reject to minimal, note to normal, unknown to verbose', () => {
    const rows = [
      { kind: 'task', want: 'minimal' },
      { kind: 'result', want: 'minimal' },
      { kind: 'reject', want: 'minimal' },
      { kind: 'note', want: 'normal' },
      { kind: 'debug', want: 'verbose' },
      { kind: 'log', want: 'verbose' },
      { kind: '', want: 'verbose' },
    ]
    for (const { kind, want } of rows) {
      assert.equal(verbosityOf(kind), want, kind)
    }
  })

  it('table: visibility at each selector level for every v:1 kind plus unknown', () => {
    const table = [
      { kind: 'task', minimal: true, normal: true, verbose: true },
      { kind: 'result', minimal: true, normal: true, verbose: true },
      { kind: 'reject', minimal: true, normal: true, verbose: true },
      { kind: 'note', minimal: false, normal: true, verbose: true },
      { kind: 'debug', minimal: false, normal: false, verbose: true },
    ]
    for (const row of table) {
      const msg = { kind: row.kind, body: 'x' }
      assert.equal(messageVisible(msg, 'minimal'), row.minimal, `${row.kind} minimal`)
      assert.equal(messageVisible(msg, 'normal'), row.normal, `${row.kind} normal`)
      assert.equal(messageVisible(msg, 'verbose'), row.verbose, `${row.kind} verbose`)
    }
  })

  it('does not treat a [verbose] body prefix as a filter', () => {
    const notes = [
      { kind: 'note', body: 'Applying patch' },
      { kind: 'note', body: '[verbose] ran pnpm test:unit' },
    ]
    const norm = applyVerbosity(notes, 'normal')
    assert.equal(norm.length, 2)
    assert.equal(applyVerbosity(notes, 'minimal').length, 0)
  })

  it('persists the selector in storage and survives junk values', () => {
    const store = memoryStore()
    assert.equal(loadVerbosity(store), DEFAULT_LEVEL)
    assert.equal(saveVerbosity('minimal', store), 'minimal')
    assert.equal(store.getItem(STORAGE_KEY), 'minimal')
    assert.equal(loadVerbosity(store), 'minimal')
    assert.equal(saveVerbosity('nope', store), DEFAULT_LEVEL)
    assert.equal(parseLevel('verbose'), 'verbose')
    const boom = {
      getItem() { throw new Error('denied') },
      setItem() { throw new Error('denied') },
    }
    assert.equal(loadVerbosity(boom), DEFAULT_LEVEL)
    assert.equal(saveVerbosity('minimal', boom), 'minimal')
  })
})
