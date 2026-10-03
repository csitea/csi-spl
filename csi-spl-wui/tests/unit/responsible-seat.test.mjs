// Spec 068 L8: the hub carries the responsible seat (`responsible`,
// <id>@<box>, rdb 0110) beside the envelope on the view API element and the
// live `message` frame, like typed_by; both normalisers must keep it or the
// card shows no seat. An empty or absent value stays absent (no key), and the
// mock send stamps <to>@<to_box> for a message to one agent, as the hub's
// insert does.
// Run: node tests/unit/responsible-seat.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const env = { from_box: 'box-wui', to_box: 'box-a', msg: { v: 1, msg_id: 'm1', from: 'HUM-1', to: 'c-002', kind: 'note', body: 'hi' } }

describe('responsible seat on the wire', () => {
  it('the view element keeps it', () => {
    assert.equal(normalizeViewMessage({ env, responsible: 'c-002@box-a' }).responsible, 'c-002@box-a')
  })
  it('the live frame keeps it', () => {
    assert.equal(messageFromFrame({ type: 'message', task_id: 't1', env, responsible: 'c-002@box-a' }).responsible, 'c-002@box-a')
  })
  it('CONTROL: absent or empty stays absent on both paths', () => {
    for (const r of [undefined, '']) {
      assert.equal('responsible' in normalizeViewMessage({ env, responsible: r }), false)
      assert.equal('responsible' in messageFromFrame({ type: 'message', task_id: 't1', env, responsible: r }), false)
    }
  })
})

describe('the mock send stamps the seat like the hub insert', () => {
  const client = () => createSpoolClient({ mock: true })
  it('a DM to one agent names <to>@<to_box>', async () => {
    const row = await client().sendMessage({ peer: 'GRK-03@box-a', text: 'hi' })
    assert.equal(row.responsible, 'GRK-03@box-a')
  })
  it('a bare agent peer takes its box off the roster', async () => {
    const row = await client().sendMessage({ peer: 'GRK-03', text: 'hi' })
    assert.equal(row.responsible, 'GRK-03@box-a')
  })
  it('CONTROL: a post to the room or to a person has no seat', async () => {
    assert.equal('responsible' in await client().sendMessage({ channel: 'lobby', text: 'hello all' }), false)
    assert.equal('responsible' in await client().sendMessage({ peer: 'HUM-2', text: 'hi' }), false)
  })
})
