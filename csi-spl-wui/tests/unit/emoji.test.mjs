// Emoji on a message. The same chips for an opening message (is_parent 1)
// and a reply (is_parent 0). The card does not look at the flag.
// Run: node tests/unit/emoji.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { applyReactions, canonicalEmoji, normalizeReactions, reactionChips, reactionOp, validEmoji, EMOJI_CHOICES } from '../../src/utils/emoji.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { mergeById } from '../../src/utils/feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const card = readFileSync(join(WUI, 'src/components/MessageCard.vue'), 'utf8')

describe('emoji reactions', () => {
  it('offers the glyphs the hub allow-list is copied from', () => {
    assert.ok(EMOJI_CHOICES.includes('👍'))
    assert.ok(EMOJI_CHOICES.includes('🎉'))
    assert.equal(validEmoji('👍'), true)
    assert.equal(validEmoji('hello'), false)
    assert.equal(validEmoji('👍👍'), false)
    assert.equal(new Set(EMOJI_CHOICES).size, EMOJI_CHOICES.length)
    assert.equal(EMOJI_CHOICES.length, 48)
    assert.equal(validEmoji('🥳'), true)
    assert.equal(validEmoji('🤯'), true)
  })

  /* SPL-1002 (owner, topic 9c10b31f): "the angry emoji is displayed twice"
     and "2 empty emoji places" */
  it('offers every glyph once, even across U+FE0F spellings, in full rows', () => {
    const bare = EMOJI_CHOICES.map((e) => e.replace(/\uFE0F/g, ''))
    assert.equal(new Set(bare).size, EMOJI_CHOICES.length, 'a glyph is listed twice')
    for (const e of EMOJI_CHOICES) assert.equal(canonicalEmoji(e), e)
    for (const cols of [8, 6, 12, 16]) assert.equal(EMOJI_CHOICES.length % cols, 0, `${cols} columns leave a hole`)
  })

  it('maps the other spelling of a glyph onto the picker spelling', () => {
    assert.equal(canonicalEmoji('\u2764'), '\u2764\uFE0F')
    assert.equal(canonicalEmoji('👍\uFE0F'), '👍')
    assert.equal(canonicalEmoji('😠'), '')
    assert.equal(canonicalEmoji('hello'), '')
    assert.equal(canonicalEmoji(''), '')
  })

  it('is the same list as the hub allow-list (internal/hub/emoji.go)', () => {
    const go = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/hub/emoji.go'), 'utf8')
    const block = go.match(/var emojiChoices = \[\]string\{([\s\S]*?)\n\}/)
    assert.ok(block, 'emojiChoices not found in emoji.go')
    const hub = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1])
    assert.deepEqual(hub, EMOJI_CHOICES)
  })

  it('the picker is one grid: no Recent row that shows glyphs a second time', () => {
    const picker = readFileSync(join(WUI, 'src/components/EmojiPicker.vue'), 'utf8')
    assert.equal((picker.match(/class="emoji-picker__grid"/g) || []).length, 1)
    assert.doesNotMatch(picker, /emoji-recent|readRecent/)
  })

  it('groups actors and marks the viewer, for either is_parent', () => {
    const list = [{ emoji: '👍', actors: ['HUM-2', 'HUM-1'] }]
    for (const flag of [0, 1]) {
      const msg = { msg_id: 'm' + flag, is_parent: flag, reactions: list }
      const chips = reactionChips(msg.reactions, 'HUM-1')
      assert.equal(chips.length, 1)
      assert.equal(chips[0].emoji, '👍')
      assert.equal(chips[0].count, 2)
      assert.equal(chips[0].mine, true)
      assert.equal(reactionOp(msg.reactions, '👍', 'HUM-1'), 'remove')
      assert.equal(reactionOp(msg.reactions, '🎉', 'HUM-1'), 'add')
    }
  })

  it('drops an empty chip and keeps emoji order', () => {
    const out = normalizeReactions([
      { emoji: '🎉', actors: ['HUM-4'] },
      { emoji: '👍', actors: [] },
      { emoji: '', actors: ['HUM-1'] },
      null,
    ])
    assert.deepEqual(out, [{ emoji: '🎉', actors: ['HUM-4'] }])
  })

  it('patches the one row and leaves the other', () => {
    const rows = [
      { msg_id: 'open', is_parent: 1, body: 'topic', reactions: [] },
      { msg_id: 'reply', is_parent: 0, body: 'line', reactions: [] },
    ]
    const next = applyReactions(rows, { msg_id: 'reply', reactions: [{ emoji: '🔥', actors: ['HUM-9'] }] })
    assert.equal(next[0].reactions.length, 0)
    assert.equal(next[1].reactions[0].emoji, '🔥')
    assert.equal(applyReactions(rows, { msg_id: 'missing', reactions: [] }), rows)
  })

  it('a topic read keeps reactions on both levels', () => {
    const el = {
      is_parent: 0,
      reactions: [{ emoji: '✅', actors: ['HUM-3'] }],
      env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'r', body: 'reply' } },
    }
    const row = normalizeViewMessage(el)
    assert.equal(row.is_parent, 0)
    assert.equal(row.reactions[0].emoji, '✅')
    const parent = normalizeViewMessage({ ...el, is_parent: 1, reactions: [{ emoji: '👍', actors: ['HUM-1'] }] })
    assert.equal(parent.is_parent, 1)
    assert.equal(parent.reactions[0].actors[0], 'HUM-1')
  })

  it('a later read of a held row picks up the emoji list', () => {
    const held = [{ msg_id: 'a', body: 'old', pending: false }]
    const incoming = [{ msg_id: 'a', body: 'old', pending: false, reactions: [{ emoji: '👀', actors: ['HUM-1'] }] }]
    const merged = mergeById(held, incoming)
    assert.equal(merged.rows[0].reactions[0].emoji, '👀')
    assert.equal(merged.rows[0].body, 'old')
  })

  it('a repeat message frame without reactions does not clear a chip', () => {
    const held = [{ msg_id: 'a', pending: false, reactions: [{ emoji: '👀', actors: ['HUM-1'] }] }]
    const incoming = [{ msg_id: 'a', pending: false, body: 'same' }]
    const merged = mergeById(held, incoming)
    assert.equal(merged.rows[0].reactions[0].emoji, '👀')
  })

  it('the card shows the control with no is_parent gate', () => {
    assert.match(card, /data-testid="msg-emoji-btn"/)
    assert.match(card, /data-testid="msg-reactions"/)
    assert.match(card, /<EmojiPicker/)
    const at = card.indexOf('data-testid="msg-emoji-btn"')
    const start = card.lastIndexOf('<button', at)
    const btn = card.slice(start, card.indexOf('</button>', at))
    assert.equal(/v-if|is_parent/.test(btn), false)
    const live = readFileSync(join(WUI, 'src/components/LiveFeed.vue'), 'utf8')
    const born = readFileSync(join(WUI, 'src/components/BornTopics.vue'), 'utf8')
    assert.match(live, /<MessageCard/)
    assert.match(born, /<MessageCard/)
  })
})

describe('SPL-982 chip count and who', () => {
  it('one chip per emoji; the count shows from 2 people on; actors kept for the tooltip', async () => {
    const { reactionChips: chipsOf } = await import('../../src/utils/emoji.mjs')
    const c = chipsOf([{ emoji: '👍', actors: ['HUM-1', 'HUM-2', 'CLE-7'] }, { emoji: '🎉', actors: ['HUM-1'] }], 'HUM-1')
    assert.deepEqual(c.map((x) => [x.emoji, x.count, x.showCount, x.mine]), [['👍', 3, true, true], ['🎉', 1, false, true]])
    assert.deepEqual(c[0].actors, ['HUM-1', 'HUM-2', 'CLE-7'])
  })
})
