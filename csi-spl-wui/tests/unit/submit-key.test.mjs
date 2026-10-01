// SPL-976: Settings -> Behaviour -> "Text fields". One key rule for every
// multi-line field, and no field keeps its own Enter handling.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SUBMIT_KEYS,
  DEFAULT_SUBMIT_KEY,
  parseSubmitKey,
  submitKeyAction,
  submitHintKey,
  applySubmitKeySetting,
} from '../../src/utils/submit-key.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const key = (k, mods = {}) => ({ key: k, ...mods })

describe('submit key ids', () => {
  it('two ids, the hub list (auth.SubmitKeys, rdb 0062) in that order', () => {
    assert.deepEqual([...SUBMIT_KEYS], ['enter', 'ctrl-enter'])
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0062_human_submit_key.sql')
    assert.match(sql, /submit_key IN \('enter','ctrl-enter'\)/)
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    assert.match(go, /SubmitKeys = \[\]string\{"enter", "ctrl-enter"\}/)
  })
  it('the default is Enter sends (owner 2026-09-27), the same as the hub default', () => {
    assert.equal(DEFAULT_SUBMIT_KEY, 'enter')
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    assert.match(go, new RegExp(`const DefaultSubmitKey = "${DEFAULT_SUBMIT_KEY}"`))
  })
  it('never picked (null) = Enter sends; an explicit ctrl-enter is kept', () => {
    assert.equal(submitKeyAction(key('Enter'), { mode: null }), 'submit')
    assert.equal(submitKeyAction(key('Enter', { shiftKey: true }), { mode: null }), 'newline')
    assert.equal(submitKeyAction(key('Enter'), { mode: 'ctrl-enter' }), 'newline')
  })
  it('the default is one of them; anything else parses to it', () => {
    assert.ok(SUBMIT_KEYS.includes(DEFAULT_SUBMIT_KEY))
    for (const id of SUBMIT_KEYS) assert.equal(parseSubmitKey(id), id)
    for (const bad of [null, undefined, '', 'Enter', 'ctrl', 7]) assert.equal(parseSubmitKey(bad), DEFAULT_SUBMIT_KEY)
  })
})

describe('submitKeyAction', () => {
  it('mode enter: Enter submits, Shift/Alt+Enter add a line, Ctrl/Cmd+Enter submit', () => {
    const mode = 'enter'
    assert.equal(submitKeyAction(key('Enter'), { mode }), 'submit')
    assert.equal(submitKeyAction(key('Enter', { shiftKey: true }), { mode }), 'newline')
    assert.equal(submitKeyAction(key('Enter', { altKey: true }), { mode }), 'newline')
    assert.equal(submitKeyAction(key('Enter', { ctrlKey: true }), { mode }), 'submit')
    assert.equal(submitKeyAction(key('Enter', { metaKey: true }), { mode }), 'submit')
  })
  it('mode ctrl-enter: Enter adds a line, Ctrl/Cmd+Enter submit', () => {
    const mode = 'ctrl-enter'
    assert.equal(submitKeyAction(key('Enter'), { mode }), 'newline')
    assert.equal(submitKeyAction(key('Enter', { shiftKey: true }), { mode }), 'newline')
    assert.equal(submitKeyAction(key('Enter', { ctrlKey: true }), { mode }), 'submit')
    assert.equal(submitKeyAction(key('Enter', { metaKey: true }), { mode }), 'submit')
    assert.equal(submitKeyAction(key('Enter', { ctrlKey: true, shiftKey: true }), { mode }), 'newline')
  })
  it('inside a ``` block a bare Enter is a line in both modes; Ctrl+Enter still sends', () => {
    for (const mode of SUBMIT_KEYS) {
      assert.equal(submitKeyAction(key('Enter'), { mode, inCode: true }), 'newline')
      assert.equal(submitKeyAction(key('Enter', { ctrlKey: true }), { mode, inCode: true }), 'submit')
    }
  })
  it('an IME composition never sends; other keys are not ours', () => {
    assert.equal(submitKeyAction(key('Enter', { isComposing: true }), { mode: 'enter' }), 'newline')
    assert.equal(submitKeyAction(key('Enter', { keyCode: 229 }), { mode: 'enter' }), 'newline')
    assert.equal(submitKeyAction(key('a'), { mode: 'enter' }), '')
    assert.equal(submitKeyAction(key('Tab'), { mode: 'enter' }), '')
    assert.equal(submitKeyAction(null), '')
  })
  it('no mode = the default mode', () => {
    assert.equal(submitKeyAction(key('Enter')), submitKeyAction(key('Enter'), { mode: DEFAULT_SUBMIT_KEY }))
  })
})

describe('submitHintKey', () => {
  it('picks the hint of the mode, the default one for an unknown mode', () => {
    const by = { enter: 'a', 'ctrl-enter': 'b' }
    assert.equal(submitHintKey('enter', by), 'a')
    assert.equal(submitHintKey('ctrl-enter', by), 'b')
    assert.equal(submitHintKey(null, by), by[DEFAULT_SUBMIT_KEY])
  })
})

describe('applySubmitKeySetting', () => {
  const rig = (ok) => {
    const log = []
    return {
      log,
      io: (current) => ({
        current,
        apply: (k) => log.push(['apply', k]),
        save: async (k) => { log.push(['save', k]); if (ok === 'throw') throw new Error('net'); return { ok } },
      }),
    }
  }
  it('mirrors first, then saves', async () => {
    const r = rig(true)
    assert.deepEqual(await applySubmitKeySetting('enter', r.io('ctrl-enter')), { ok: true, value: 'enter' })
    assert.deepEqual(r.log, [['apply', 'enter'], ['save', 'enter']])
  })
  it('a refused or failed save puts the old value back', async () => {
    for (const how of [false, 'throw']) {
      const r = rig(how)
      const out = await applySubmitKeySetting('enter', r.io('ctrl-enter'))
      assert.equal(out.ok, false)
      assert.equal(out.value, 'ctrl-enter')
      assert.deepEqual(r.log.at(-1), ['apply', 'ctrl-enter'])
    }
  })
  it('an unknown id saves nothing; the same stored id saves nothing', async () => {
    const r = rig(true)
    assert.equal((await applySubmitKeySetting('shift-enter', r.io('enter'))).ok, false)
    assert.equal((await applySubmitKeySetting('enter', r.io('enter'))).ok, true)
    assert.deepEqual(r.log, [])
  })
  it('never picked (null): picking the default still stores it', async () => {
    const r = rig(true)
    await applySubmitKeySetting(DEFAULT_SUBMIT_KEY, r.io(null))
    assert.deepEqual(r.log.map((x) => x[0]), ['apply', 'save'])
  })
})

describe('every multi-line field uses the helper', () => {
  const FIELDS = [
    'src/components/MessageComposer.vue',
    'src/components/IssueDescription.vue',
    'src/components/ChannelSidebar.vue',
    'src/pages/issues.vue',
  ]
  for (const f of FIELDS) {
    it(`${f} reads Enter through useSubmitKey`, () => {
      const src = read(f)
      assert.match(src, /useSubmitKey\(/)
      assert.doesNotMatch(src, /@keydown\.enter(\.exact)?\.prevent="send/)
      assert.doesNotMatch(src, /\benterAction\(/)
    })
  }
  it('Settings -> Behaviour is a section with the Text fields radios', () => {
    assert.match(read('src/utils/settings-nav.mjs'), /id: 'behaviour'/)
    assert.match(read('src/components/settings/behaviour.vue'), /<SubmitKeySetting/)
  })
})
