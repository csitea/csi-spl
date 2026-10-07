// msg-jump.mjs (owner t1 48d09034): every in-app link that names a message
// asks the thread feed to bring it into view, also when the address does not
// change (the same link clicked twice).
//
// Run: node --test tests/unit/msg-jump.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { linkPath, messageIdOfPath, navigateAndJump, onMessageJump, requestMessageJump, setLinkOpenHook } from '../../src/utils/msg-jump.mjs'
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

describe('HUM-10 (t1 36ea84a6): no link opens the Topics view', () => {
  it('a topic page link goes through /m/<msg>, or /m/<task> without a message', () => {
    assert.equal(linkPath(`/t/${TASK}#${ID}`), `/m/${ID}`)
    assert.equal(linkPath(`/t/${TASK}`), `/m/${TASK}`)
    assert.equal(linkPath(`/et/t/${TASK.toUpperCase()}`), `/et/m/${TASK}`)
  })
  it('a place link naming only a topic goes through /m/<task>, so its card is marked', () => {
    assert.equal(linkPath(`/channel/lobby?topic=${TASK}`), `/m/${TASK}`)
    assert.equal(linkPath(`/dm/GRK-03%40box-a?topic=${TASK}`), `/m/${TASK}`)
  })
  it('a place link with its message, a lobby ?in= link and other pages stay as written', () => {
    for (const p of [`/channel/lobby?topic=${TASK}#${ID}`, `/channel/lobby?topic=${TASK}&in=${ID}`, `/m/${ID}`, '/issues', '/t', '/docs?p=t/x']) {
      assert.equal(linkPath(p), p)
    }
  })
  it('navigateAndJump tells the hook, then routes the rewritten path', async () => {
    const seen = []
    setLinkOpenHook((p) => seen.push(p))
    const went = []
    navigateAndJump(`/t/${TASK}#${ID}`, (p) => went.push(p))
    setLinkOpenHook(null)
    navigateAndJump('/issues', (p) => went.push(p))
    await tick()
    assert.deepEqual(seen, [`/m/${ID}`])
    assert.deepEqual(went, [`/m/${ID}`, '/issues'])
  })
})
