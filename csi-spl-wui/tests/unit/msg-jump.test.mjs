// msg-jump.mjs (owner t1 48d09034): every in-app link that names a message
// asks the thread feed to bring it into view, also when the address does not
// change (the same link clicked twice).
//
// Run: node --test tests/unit/msg-jump.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { messageIdOfPath, navigateAndJump, onMessageJump, requestMessageJump } from '../../src/utils/msg-jump.mjs'
import { followSameTabLink } from '../../src/utils/link-target.mjs'

const ID = 'f5010000-0000-4000-8000-000000000000'
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const tick = () => new Promise((r) => setTimeout(r, 0))

describe('messageIdOfPath', () => {
  it('reads the #<msg_id> of a place link and the id of /m/<msg_id>', () => {
    assert.equal(messageIdOfPath(`/channel/lobby?topic=${TASK}#${ID}`), ID)
    assert.equal(messageIdOfPath(`/t/${TASK}#${ID.toUpperCase()}`), ID)
    assert.equal(messageIdOfPath(`/m/${ID}`), ID)
    assert.equal(messageIdOfPath(`/de/m/${ID}`), ID)
  })
  it('a topic link, a non-uuid hash or nothing names no message', () => {
    assert.equal(messageIdOfPath(`/channel/lobby?topic=${TASK}`), '')
    assert.equal(messageIdOfPath('/help#section-2'), '')
    assert.equal(messageIdOfPath(''), '')
  })
})

describe('requestMessageJump', () => {
  it('tells every listener, the same id twice runs twice, and off stops it', () => {
    const got = []
    const off = onMessageJump((id) => got.push(id))
    assert.equal(requestMessageJump(ID), true)
    assert.equal(requestMessageJump(ID.toUpperCase()), true)
    off()
    requestMessageJump(ID)
    assert.deepEqual(got, [ID, ID])
  })
  it('refuses what is not a message id', () => {
    assert.equal(requestMessageJump('nope'), false)
  })
})

describe('a same-tab link click asks for the jump', () => {
  it('navigateAndJump routes, then asks', async () => {
    const got = []
    const off = onMessageJump((id) => got.push(id))
    const went = []
    navigateAndJump(`/channel/lobby?topic=${TASK}#${ID}`, (p) => went.push(p))
    await tick()
    off()
    assert.deepEqual(went, [`/channel/lobby?topic=${TASK}#${ID}`])
    assert.deepEqual(got, [ID])
  })
  it('followSameTabLink on the address already shown still asks', async () => {
    const got = []
    const off = onMessageJump((id) => got.push(id))
    const page = `https://ws.example.com/channel/lobby?topic=${TASK}#${ID}`
    const ev = { button: 0, preventDefault() { this.defaultPrevented = true } }
    assert.equal(followSameTabLink(ev, page, page, () => {}), true)
    await tick()
    off()
    assert.deepEqual(got, [ID])
  })
})
