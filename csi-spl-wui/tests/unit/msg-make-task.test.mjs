// SPL-3344 (owner HUM-10, t1 2a9e18c7 msgs 3e7fc3b7, 0c510ff7): a blocker
// becomes a task in one step - a top-level "Make it a task" menu item and
// Shift + X, offered only where Kind -> Task is.
// Run: node --test tests/unit/msg-make-task.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { MSG_SHORTCUTS, offeredItems, shortcutFor, shortcutHint, shortcutItem } from '../../src/utils/msg-shortcuts.mjs'
import { canMakeTask } from '../../src/utils/msg-kind.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const shiftX = { key: 'X', code: 'KeyX', shiftKey: true }

describe('Make it a task: the menu item', () => {
  it('is offered with toTask, desktop and phone, right before Make an issue', () => {
    for (const touch of [false, true]) {
      const items = msgMenuItems({ touch, toTask: true, makeIssue: true })
      const at = items.findIndex((i) => i.id === 'make-task')
      assert.deepEqual(items[at], { id: 'make-task', icon: 'tag', labelKey: 'feed.msg_menu.make_task' })
      assert.equal(items[at + 1].id, 'make-issue')
      assert.equal(msgMenuItems({ touch }).some((i) => i.id === 'make-task'), false, 'CONTROL: no toTask, no entry')
    }
  })
})

describe('Make it a task: offered only on a blocker the viewer may re-type', () => {
  const blocker = { msg_id: 'm1', from: 'a-1', kind: 'blocker' }
  it('the author or a biz_owner / admin, on a blocker', () => {
    assert.equal(canMakeTask(blocker, 'a-1', null), true)
    assert.equal(canMakeTask(blocker, 'x-9', 'admin'), true)
    assert.equal(canMakeTask(blocker, 'x-9', 'biz_owner'), true)
  })
  it('never on another kind, a stranger\'s message or a message in flight', () => {
    for (const kind of ['task', 'note', 'msg', 'result', 'reject', '']) {
      assert.equal(canMakeTask({ ...blocker, kind }, 'a-1', 'admin'), false, kind)
    }
    assert.equal(canMakeTask(blocker, 'x-9', 'member'), false)
    assert.equal(canMakeTask({ ...blocker, pending: true }, 'a-1', null), false)
    assert.equal(canMakeTask(null, 'a-1', 'admin'), false)
  })
})

describe('Shift + X runs Make it a task', () => {
  it('is a free letter: one map row, and no other row takes make-task', () => {
    const rows = MSG_SHORTCUTS.filter((s) => s.key === 'X')
    assert.equal(rows.length, 1)
    assert.deepEqual([...rows[0].items], ['make-task'])
    assert.equal(rows[0].labelKey, 'feed.msg_menu.make_task')
    assert.equal(MSG_SHORTCUTS.filter((s) => s.items.includes('make-task')).length, 1)
    assert.equal(shortcutHint('make-task'), '⇧X')
  })
  it('the key maps to the item only when the menu offers it', () => {
    assert.deepEqual(shortcutFor(shiftX), { type: 'action', key: 'X' })
    assert.equal(shortcutItem('X', offeredItems({ toTask: true })), 'make-task')
    assert.equal(shortcutItem('X', offeredItems({ kind: true })), '', 'a task (no toTask) offers nothing')
    assert.equal(shortcutItem('X', offeredItems({})), '')
  })
  it('follows the setting, the phone rule, a text field and a chord like the other keys', () => {
    assert.equal(shortcutFor(shiftX, { enabled: false }), null)
    assert.equal(shortcutFor(shiftX, { phone: true }), null)
    assert.equal(shortcutFor({ ...shiftX, ctrlKey: true }), null)
    assert.equal(shortcutFor({ key: 'x', code: 'KeyX' }), null, 'plain x is no shortcut')
    const input = { closest: (sel) => (sel.includes('input') ? {} : null) }
    assert.equal(shortcutFor({ ...shiftX, target: input }), null)
  })
  it('changes no other key', () => {
    const keys = MSG_SHORTCUTS.map((s) => `${s.key}:${s.items.join(',')}`)
    assert.deepEqual(keys, ['H:hide-flow', 'R:', 'E:edit', 'A:archive', 'O:open', 'P:parent', 'B:', 'U:', 'L:copy', 'C:copy-text', 'K:kind', 'X:make-task', 'T:promote-topic', 'M:move-channel,move-topic,merge-topic', 'D:delete-topic,delete'])
  })
})

describe('Make it a task: the card runs what Kind -> Task runs', () => {
  const card = src('src/components/MessageCard.vue')
  const keys = src('src/composables/useCardKeys.ts')
  const acts = src('src/composables/useCardTopicActions.ts')
  const menu = src('src/components/MessageMenu.vue')
  it('the menu and the key share the flag and the handler', () => {
    assert.match(card, /:to-task="canMakeTask"/)
    assert.match(card, /@make-task="onMakeTask"/)
    assert.match(card, /mayMakeTask\(props\.msg, editorId\.value, access\.me\?\.role \?\? null\)/)
    assert.match(menu, /toTask: props\.toTask/)
    assert.match(menu, /id === 'make-task'\) emit\('make-task'\)/)
    assert.match(keys, /toTask: canMakeTask\.value/)
    assert.match(keys, /'make-task': a\.onMakeTask/)
  })
  it('the handler is KindBadge\'s pick: setMessageKind(id, \'task\') then applyKind', () => {
    assert.match(acts, /setMessageKind\(id, 'task'\)/)
    assert.match(acts, /applyKind\(from, row, props\.msg\)/)
    assert.match(src('src/components/KindBadge.vue'), /setMessageKind\(String\(m\.msg_id\), kind\)[\s\S]*edit\.applyKind\(from, row, m\)/)
  })
})

describe('Make it a task: every locale has its own words', () => {
  const dir = join(WUI, 'i18n/locales')
  const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).feed.msg_menu.make_task
  it('en and the other 18', () => {
    assert.equal(en, 'Make it a task')
    const codes = readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'en.json')
    assert.ok(codes.length >= 18)
    for (const f of codes) {
      const v = JSON.parse(readFileSync(join(dir, f), 'utf8')).feed.msg_menu.make_task
      assert.ok(v && v !== en, f)
    }
  })
})
