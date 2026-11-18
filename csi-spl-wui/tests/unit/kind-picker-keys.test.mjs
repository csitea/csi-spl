// SPL-5836 (HUM-10, t1 0cd27035): the Kind picker's letter keys. One unique
// letter per kind, each picks its own kind, only a plain letter does, and a
// kind the picker does not offer is never picked. The component wires the
// map and its hint to the Keyboard shortcuts setting.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MSG_KINDS } from '../../src/utils/msg-kind.mjs'
import { importTs } from './lib/load-ts.mjs'

const { KIND_KEYS, kindForKey, kindKeyHint } = await importTs('src/utils/kind-picker-keys.ts')
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const PICKER = readFileSync(join(WUI, 'src/components/KindPicker.vue'), 'utf8')

describe('kind picker letter keys (SPL-5836)', () => {
  it('every kind the hub accepts has one letter, and no two kinds share one', () => {
    assert.deepEqual(Object.keys(KIND_KEYS).sort(), [...MSG_KINDS].sort())
    const letters = Object.values(KIND_KEYS)
    for (const l of letters) assert.match(l, /^[A-Z]$/)
    assert.equal(new Set(letters).size, letters.length, `unique letters: ${letters.join(' ')}`)
  })

  it('the owner-facing letters: M message, N note, T task, B blocker, R result, J reject', () => {
    assert.deepEqual({ ...KIND_KEYS }, { msg: 'M', note: 'N', task: 'T', blocker: 'B', result: 'R', reject: 'J' })
  })

  it('each letter picks its own kind, lower or upper case', () => {
    for (const k of MSG_KINDS) {
      const l = KIND_KEYS[k]
      assert.equal(kindForKey({ key: l.toLowerCase() }, MSG_KINDS), k, `${l} -> ${k}`)
      assert.equal(kindForKey({ key: l }, MSG_KINDS), k, `${l} (caps lock) -> ${k}`)
      assert.equal(kindKeyHint(k), l)
    }
  })

  it('a kind the picker does not offer is not picked', () => {
    const offered = MSG_KINDS.filter((k) => k !== 'blocker')
    assert.equal(kindForKey({ key: 'b' }, offered), '')
    assert.equal(kindForKey({ key: 't' }, offered), 'task')
    assert.equal(kindForKey({ key: 'm' }, []), '')
  })

  it('only a plain letter picks: no modifier, no held key, no composition, no other key', () => {
    for (const mod of ['shiftKey', 'ctrlKey', 'metaKey', 'altKey', 'isComposing', 'repeat']) {
      assert.equal(kindForKey({ key: 't', [mod]: true }, MSG_KINDS), '', mod)
    }
    for (const key of ['x', 'Enter', 'Escape', 'ArrowDown', 'Home', 'End', 'Tab', '1', ' ', '']) {
      assert.equal(kindForKey({ key }, MSG_KINDS), '', JSON.stringify(key))
    }
    assert.equal(kindForKey(null, MSG_KINDS), '')
    assert.equal(kindKeyHint('nope'), '')
  })

  it('a non-Latin layout picks by the physical key: ev.code KeyT is task, a non-letter code is nothing (R7 W1)', () => {
    assert.equal(kindForKey({ key: 'т', code: 'KeyT' }, MSG_KINDS), 'task')
    assert.equal(kindForKey({ key: 'μ', code: 'KeyM' }, MSG_KINDS), 'msg')
    assert.equal(kindForKey({ key: 'т', code: 'Digit1' }, MSG_KINDS), '')
    assert.equal(kindForKey({ key: 'т' }, MSG_KINDS), '')
    assert.equal(kindForKey({ key: 'т', code: 'KeyT', shiftKey: true }, MSG_KINDS), '')
    assert.equal(kindForKey({ key: 'и', code: 'KeyB' }, MSG_KINDS.filter((k) => k !== 'blocker')), '')
  })

  it('the picker gates the letters and their hint on the Keyboard shortcuts setting', () => {
    assert.match(PICKER, /const keysOn = useMsgShortcutsOn\(\)/)
    assert.match(PICKER, /keysOn\.value \? kindForKey\(e, MSG_KINDS\) : ''/)
    assert.match(PICKER, /v-if="keysOn && kindKeyHint\(k\)"/)
  })
})
