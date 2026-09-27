// CLE-35062: /lobby's first reads start at session 'in' (utils/lobby-warm.mjs).
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { isLobbyPath, lobbyFrames, resetLobbyWarm, startLobbyWarm, takeLobbyWarm } from '../../src/utils/lobby-warm.mjs'

const LOBBY = '00000000-0000-4000-8000-000000000001'

function bus() {
  const fns = new Set()
  return {
    onMessage: (fn) => { fns.add(fn); return () => fns.delete(fn) },
    emit: (m) => { for (const fn of [...fns]) fn(m) },
    size: () => fns.size,
  }
}

describe('lobby warm reads (CLE-35062)', () => {
  beforeEach(() => resetLobbyWarm())

  it('knows the lobby route in every locale form, and nothing else', () => {
    for (const p of ['/lobby', '/lobby/', '/bg/lobby', '/fi/lobby/']) assert.equal(isLobbyPath(p), true, p)
    for (const p of ['/', '/lobbyx', '/channel/lobby', '/t/lobby', '/bg/lobby/x', '']) assert.equal(isLobbyPath(p), false, p)
  })

  it('starts both reads once, and the page takes them once', async () => {
    const b = bus()
    let reads = 0
    const room = () => { reads++; return Promise.resolve({ messages: [{ msg_id: 'r1' }], next: null }) }
    const topics = () => { reads++; return Promise.resolve({ messages: [{ msg_id: 't1' }] }) }
    const w = startLobbyWarm({ id: LOBBY, room, topics, onMessage: b.onMessage })
    assert.equal(startLobbyWarm({ id: LOBBY, room, topics, onMessage: b.onMessage }), w, 'a second start is the same warm read')
    assert.equal(reads, 2)
    const got = takeLobbyWarm(LOBBY)
    assert.equal(got, w)
    assert.deepEqual((await got.room).messages, [{ msg_id: 'r1' }])
    assert.equal(takeLobbyWarm(LOBBY), null, 'taken once')
  })

  it('buffers every live frame until taken, then stops; the lobby keeps its room and channel frames', () => {
    const b = bus()
    startLobbyWarm({ id: LOBBY, room: () => Promise.resolve({ messages: [] }), topics: () => Promise.resolve({ messages: [] }), onMessage: b.onMessage })
    b.emit({ msg_id: 'a', task_id: LOBBY })
    b.emit({ msg_id: 'b', task_id: 'other', channel: 'lobby' })
    b.emit({ msg_id: 'c', task_id: 'other', channel: 'general' })
    const w = takeLobbyWarm(LOBBY)
    assert.equal(b.size(), 0, 'taking stops the buffer')
    b.emit({ msg_id: 'd', task_id: LOBBY })
    assert.deepEqual(lobbyFrames(w, LOBBY).map((m) => m.msg_id), ['a', 'b'])
  })

  it('is not used for another lobby id, nor once stale; a failed read stays the page\'s to handle', async () => {
    const b = bus()
    let t = 1000
    const now = () => t
    const failing = Promise.reject(new Error('boom'))
    startLobbyWarm({ id: LOBBY, room: () => failing, topics: () => Promise.resolve({ messages: [] }), onMessage: b.onMessage, now })
    assert.equal(takeLobbyWarm('another', { now }), null)
    startLobbyWarm({ id: LOBBY, room: () => Promise.resolve({ messages: [] }), topics: () => Promise.resolve({ messages: [] }), onMessage: b.onMessage, now })
    t += 16000
    assert.equal(takeLobbyWarm(LOBBY, { now }), null, 'older than 15 s')
    await assert.rejects(failing)
  })

  it('the lobby page takes the warm reads and admits the buffered frames after its own reads', () => {
    const vue = readFileSync(new URL('../../src/pages/lobby.vue', import.meta.url), 'utf8')
    assert.match(vue, /takeLobbyWarm\(id\)/)
    assert.match(vue, /store\.open\(id, warm \? \{ first: warm\.room \} : \{\}\)/)
    assert.match(vue, /store\.admit\(lobbyFrames\(warm, id\)/)
  })
})
