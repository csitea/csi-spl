// SPL-952: message kind badges. Every kind the hub accepts has a glyph, a
// word in all 19 locales, and the composer's pick wins over the automatic kind.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MSG_KINDS, PICK_KINDS, kindIcon, sendKind } from '../../src/utils/msg-kind.mjs'
import { V1_KINDS, verbosityOf } from '../../src/utils/verbosity.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const API_MSG = join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go')
const ICONS = readFileSync(join(WUI, 'src/utils/uiIcons.ts'), 'utf8')
const LOCALES = join(WUI, 'i18n/locales')

describe('msg kinds (SPL-952)', () => {
  it('the WUI knows exactly the hub validKinds', () => {
    const src = readFileSync(API_MSG, 'utf8')
    const block = src.match(/var validKinds = map\[string\]bool\{([\s\S]*?)\n\}/)
    assert.ok(block, 'validKinds block found in msg.go')
    const hub = [...block[1].matchAll(/"([a-z]+)": true/g)].map((m) => m[1]).sort()
    assert.deepEqual([...MSG_KINDS].sort(), hub)
    assert.deepEqual([...V1_KINDS].sort(), hub)
  })

  it('every kind has a glyph in uiIcons', () => {
    for (const k of MSG_KINDS) {
      const icon = kindIcon(k)
      assert.ok(icon, `${k} has an icon`)
      assert.ok(ICONS.includes(`"${icon}": [`), `${icon} is in UI_ICON_PATHS`)
    }
    assert.equal(kindIcon('bogus'), '')
    assert.equal(kindIcon(undefined), '')
  })

  it('every locale names every kind and the picker', () => {
    const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(LOCALES, f), 'utf8'))
      for (const k of MSG_KINDS) assert.ok(d.feed.kind[k], `${f} feed.kind.${k}`)
      assert.ok(d.composer.kind_label, `${f} composer.kind_label`)
      assert.ok(d.composer.kind_auto, `${f} composer.kind_auto`)
    }
  })

  it('the pick wins; empty or unknown falls back to automatic', () => {
    assert.equal(sendKind('note', ''), 'note')
    assert.equal(sendKind('task', undefined), 'task')
    assert.equal(sendKind('note', 'blocker'), 'blocker')
    assert.equal(sendKind('task', 'msg'), 'msg')
    assert.equal(sendKind('note', 'result'), 'note', 'result is not a person\'s pick')
    assert.equal(sendKind('note', 'bogus'), 'note')
    assert.ok(PICK_KINDS.includes(''))
  })

  it('a blocker shows even at minimal verbosity; msg is normal', () => {
    assert.equal(verbosityOf('blocker'), 'minimal')
    assert.equal(verbosityOf('msg'), 'normal')
  })
})
