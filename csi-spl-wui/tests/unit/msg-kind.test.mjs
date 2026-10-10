// SPL-952: message kind badges. Every kind the hub accepts has a glyph, a
// word in all 19 locales.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { MSG_KINDS, KIND_SETTER_ROLES, canSetKind, kindIcon } from '../../src/utils/msg-kind.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'

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

  it('every locale names every kind', () => {
    const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(LOCALES, f), 'utf8'))
      for (const k of MSG_KINDS) assert.ok(d.feed.kind[k], `${f} feed.kind.${k}`)
      assert.equal(d.composer.kind_auto, undefined, `${f} the composer picker is gone`)
      for (const k of ['change', 'menu', 'failed']) assert.ok(d.feed.kind_set[k], `${f} feed.kind_set.${k}`)
      assert.ok(d.feed.kind_set.change.includes('{kind}'), `${f} feed.kind_set.change names the kind`)
    }
  })

  it('who may set a kind: the author, a biz_owner or an admin (the hub rule)', () => {
    const m = { msg_id: 'm1', from: 'HUM-1' }
    assert.equal(canSetKind(m, 'HUM-1', 'developer'), true)
    assert.equal(canSetKind(m, 'HUM-2', 'developer'), false)
    for (const r of KIND_SETTER_ROLES) assert.equal(canSetKind(m, 'HUM-2', r), true)
    assert.equal(canSetKind({ ...m, pending: true }, 'HUM-1', 'admin'), false)
    assert.equal(canSetKind({ from: 'HUM-1' }, 'HUM-1', 'admin'), false)
    const hub = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/hub/message_kind.go'), 'utf8')
    assert.match(hub, /kindSetterRoles = map\[string\]bool\{rbac\.BizOwner: true, rbac\.Admin: true\}/)
  })

  it('a kind set after sending wins over the envelope, on reload and live', () => {
    const env = { from_box: 'box-a', to_box: 'box-wui', msg: { msg_id: 'm1', kind: 'note', body: 'x' } }
    assert.equal(normalizeViewMessage({ env }).kind, 'note')
    const set = normalizeViewMessage({ env, kind: 'blocker', kind_set_by: 'HUM-1', kind_set_at: '2026-09-26T12:00:00Z' })
    assert.deepEqual([set.kind, set.kind_set_by], ['blocker', 'HUM-1'])
    const f = messageFromFrame({ type: 'message_edited', msg_id: 'm1', env, kind: 'task' })
    assert.equal(f.kind, 'task')
    assert.equal(messageFromFrame({ type: 'message_edited', env }).kind, 'note')
  })
})
