// specs/036 FR-011: a line a human typed at an agent's terminal shows as that
// HUMAN, with a "via terminal <agent>" badge. The hub carries the verified
// `typed_by` beside the envelope (view API element and live frame), like
// edited_by; both normalisers must keep it or the row renders as the agent.
// Run: node tests/unit/typed-by.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { typedByAuthor } from '../../src/utils/typed-by.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'
import { MOCK_MESSAGES } from '../../src/utils/mock-data.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const env = { from_box: 'box-desk', to_box: 'box-wui', msg: { v: 1, msg_id: 'm1', from: 'CLE-07', to: 'HUM-9', kind: 'note', body: 'hi' } }

describe('typedByAuthor', () => {
  it('shows a typed line as the human, via the agent', () => {
    assert.deepEqual(typedByAuthor({ from: 'CLE-07', from_box: 'box-desk', typed_by: 'HUM-9' }),
      { id: 'HUM-9', box: 'box-wui', via: 'CLE-07', viaBox: 'box-desk' })
  })
  it('CONTROL: an ordinary row keeps its sender and has no badge', () => {
    assert.deepEqual(typedByAuthor({ from: 'CLE-07', from_box: 'box-desk' }),
      { id: 'CLE-07', box: 'box-desk', via: '', viaBox: '' })
    assert.deepEqual(typedByAuthor(null), { id: '', box: '', via: '', viaBox: '' })
  })
  it('ignores a malformed or self typed_by', () => {
    assert.equal(typedByAuthor({ from: 'CLE-07', typed_by: 'bob' }).id, 'CLE-07')
    assert.equal(typedByAuthor({ from: 'HUM-9', from_box: 'box-wui', typed_by: 'HUM-9' }).via, '')
  })
})

describe('normalisers keep typed_by', () => {
  it('view API element (view-v1 §4.4)', () => {
    assert.equal(normalizeViewMessage({ cursor: 'c', env, typed_by: 'HUM-9' }).typed_by, 'HUM-9')
    assert.equal('typed_by' in normalizeViewMessage({ cursor: 'c', env }), false)
  })
  it('live frame', () => {
    assert.equal(messageFromFrame({ type: 'message', env, typed_by: 'HUM-9' }).typed_by, 'HUM-9')
    assert.equal('typed_by' in messageFromFrame({ type: 'message', env }), false)
  })
})

describe('MessageCard', () => {
  const card = src('src/components/MessageCard.vue')
  it('renders avatar, name and aria from the author, not raw msg.from', () => {
    assert.match(card, /<SpoolAvatar class="avatar" :id="author.id"/)
    assert.match(card, /<AgentBadge :id="author.id"/)
    assert.match(card, /data-testid="msg-typed-by"/)
    assert.match(card, /t\('feed.typed_by.badge', \{ agent: author.via \}\)/)
  })
  it('the mock tenant carries one typed row for the e2e', () => {
    const rows = MOCK_MESSAGES.filter((m) => m.typed_by)
    assert.equal(rows.length, 1)
    assert.notEqual(rows[0].from, rows[0].typed_by)
  })
})
