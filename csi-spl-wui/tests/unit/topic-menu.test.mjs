// CLE-77891 (HUM-24): every topic card's menu has the same shape. An entry the
// viewer may not use is listed DISABLED with the reason, never hidden - the
// starter, a member and an admin see the same entries in the same order.
// Run: node tests/unit/topic-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { topicCardMenuOpts, topicMenuLocks } from '../../src/utils/topic-menu.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const WHY = 'feed.msg_menu.why.'
const card = { msg_id: 'm1', task_id: 't1', is_parent: 1, channel: 'dev', from: 'HUM-1', from_box: 'box-wui' }
const member = { role: 'member', tenantOwner: false, topicArchivePolicy: 'everyone' }
const admin = { role: 'admin', tenantOwner: false, topicArchivePolicy: 'everyone' }

/** The card menu exactly as MessageCard builds it for this viewer. */
function menu(msg, viewer, me, { editable = viewer === msg.from, lobby = '' } = {}) {
  return msgMenuItems(topicCardMenuOpts(msg, viewer, me, { editable, lobbyTaskId: lobby }))
}
const ids = (items) => items.map((i) => i.id)
const off = (items) => items.filter((i) => i.disabled).map((i) => i.id)
const SHAPE = ['open', 'copy', 'edit', 'move-channel', 'merge-topic', 'archive', 'delete-topic']

describe('topic card menu: one shape for every viewer (HUM-24)', () => {
  it('the starter, a member and an admin see the same entries in the same order', () => {
    assert.deepEqual(ids(menu(card, 'HUM-1', member)), SHAPE)
    assert.deepEqual(ids(menu(card, 'HUM-2', member)), SHAPE)
    assert.deepEqual(ids(menu(card, 'HUM-3', admin, { editable: true })), SHAPE)
  })

  it('the starter and an admin: nothing disabled', () => {
    assert.deepEqual(off(menu(card, 'HUM-1', member)), [])
    assert.deepEqual(off(menu(card, 'HUM-3', admin, { editable: true })), [])
  })

  it('a member on someone else\'s topic: Edit, Move, Merge, Delete disabled with the reason; Archive (policy everyone) enabled', () => {
    const items = menu(card, 'HUM-2', member)
    assert.deepEqual(off(items), ['edit', 'move-channel', 'merge-topic', 'delete-topic'])
    const hint = Object.fromEntries(items.map((i) => [i.id, i.hintKey || '']))
    assert.equal(hint.edit, WHY + 'edit')
    assert.equal(hint['move-channel'], WHY + 'move')
    assert.equal(hint['merge-topic'], WHY + 'merge')
    assert.equal(hint['delete-topic'], WHY + 'delete')
    assert.equal(hint.archive, '')
  })

  it('archive follows the workspace setting: starter / admins lock it with the matching reason', () => {
    const starter = { ...member, topicArchivePolicy: 'starter' }
    const admins = { ...member, topicArchivePolicy: 'admins' }
    assert.equal(topicMenuLocks(card, 'HUM-2', starter).archive, WHY + 'archive_starter')
    assert.equal(topicMenuLocks(card, 'HUM-2', admins).archive, WHY + 'archive_admins')
    assert.equal(topicMenuLocks(card, 'HUM-1', admins).archive, WHY + 'archive_admins', 'admins-only binds the starter too')
    assert.equal(topicMenuLocks(card, 'HUM-1', starter).archive, '')
    assert.deepEqual(ids(menu(card, 'HUM-2', admins)), SHAPE)
  })

  it('an admin on an agent\'s card: Edit disabled because only its agent edits it', () => {
    const agent = { ...card, from: 'AGT-1', from_box: 'box-7' }
    assert.equal(topicMenuLocks(agent, 'HUM-3', admin, { editable: false }).edit, WHY + 'edit_agent')
  })

  it('a topic that cannot move at all (DM, lobby, issues) says so, also to the starter', () => {
    const dm = { ...card, channel: '' }
    assert.equal(topicMenuLocks(dm, 'HUM-1', member, { editable: true }).move, WHY + 'move_place')
    assert.equal(topicMenuLocks({ ...card, channel: 'issues' }, 'HUM-1', member).merge, WHY + 'move_place')
    assert.equal(topicMenuLocks(card, 'HUM-1', member, { lobbyTaskId: 't1' }).move, WHY + 'move_place')
    assert.deepEqual(ids(menu(dm, 'HUM-2', member)), SHAPE)
  })

  it('no /v1/view/me yet: the author-only fallback, still the full shape', () => {
    assert.deepEqual(ids(menu(card, 'HUM-2', null)), SHAPE)
    assert.deepEqual(off(menu(card, 'HUM-1', null)), [])
  })

  it('a reply / not a card: no locks, the menu is unchanged', () => {
    assert.deepEqual(topicMenuLocks({ ...card, is_parent: 0 }, 'HUM-2', member), { edit: '', move: '', merge: '', archive: '', delete: '' })
    assert.deepEqual(ids(msgMenuItems({ editable: false })), ['open', 'copy'])
    assert.deepEqual(ids(msgMenuItems({ editable: true, locks: {} })), ['open', 'copy', 'edit', 'delete'])
  })

  it('a channel card has no Open-in-channels item; that item is a thread line', () => {
    const opts = topicCardMenuOpts(card, 'HUM-1', member, { editable: true })
    assert.equal(opts.parent, false)
    assert.equal(ids(msgMenuItems(opts)).includes('parent'), false)
  })

  it('the topic list reuses the channel card menu, it does not keep its own item list', () => {
    const page = readFileSync(join(root, 'src/pages/t/[task_id].vue'), 'utf8')
    assert.match(page, /topicCardMenuOpts/)
    assert.match(page, /<LazyMessageMenu/)
    assert.match(page, /@contextmenu="onRowContext\(row\.task_id, \$event\)"/)
    assert.match(page, /data-testid="topic-list-menu"/)
    assert.match(page, /@archive="onMenuArchive"/)
    assert.doesNotMatch(page, /rowMenuItems/)
    assert.doesNotMatch(page, /<SidebarRowMenu/)
  })

  it('every reason exists in all 19 locales, and the Bulgarian ones are translated', () => {
    const keys = ['edit', 'edit_agent', 'move', 'move_place', 'merge', 'archive_admins', 'archive_starter', 'delete']
    const locales = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    const en = JSON.parse(readFileSync(join(root, 'i18n/locales/en.json'), 'utf8')).feed.msg_menu.why
    for (const l of locales) {
      const why = JSON.parse(readFileSync(join(root, `i18n/locales/${l}.json`), 'utf8')).feed.msg_menu.why
      for (const k of keys) {
        assert.ok(why && typeof why[k] === 'string' && why[k].trim(), `${l}: feed.msg_menu.why.${k}`)
        if (l !== 'en') assert.notEqual(why[k], en[k], `${l}: feed.msg_menu.why.${k} is still English`)
      }
    }
  })

  it('the menu draws a locked entry disabled, with its reason, and a click on it does nothing', () => {
    const vue = readFileSync(join(root, 'src/components/UiPointMenu.vue'), 'utf8')
    assert.match(readFileSync(join(root, 'src/components/MessageMenu.vue'), 'utf8'), /<UiPointMenu\b/)
    assert.match(vue, /:aria-disabled="item\.disabled \? 'true' : undefined"/)
    assert.match(vue, /:title="item\.disabled && item\.hintKey \? t\(item\.hintKey\) : undefined"/)
    assert.match(vue, /if \(disabled\) return/)
    const cardVue = readFileSync(join(root, 'src/components/MessageCard.vue'), 'utf8')
    assert.match(cardVue, /:locks="menuLocks"/)
  })
})
