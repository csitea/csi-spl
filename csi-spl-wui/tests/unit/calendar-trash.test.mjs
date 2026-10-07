// spec 097 T017 (G13, spec 4.8): the mock workspace's soft delete, restore
// and trash (src/utils/calendar-mock.mjs), and the hub calls the Undo toast
// and the trash list make (src/utils/calendar-events-api.mjs).
import { beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mockCalendarDelete, mockCalendarItems, mockCalendarRestore, mockCalendarTrash } from '../../src/utils/calendar-mock.mjs'
import { calendarRestore, calendarTrash } from '../../src/utils/calendar-events-api.mjs'

const TODAY = '2026-10-07'
const RELEASE = '00000000-0000-4000-8000-000000000101'
const PLANNING = '00000000-0000-4000-8000-000000000103'
const ids = () => mockCalendarItems(TODAY).map((x) => x.id)

beforeEach(() => {
  const m = new Map()
  globalThis.localStorage = {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)) },
    removeItem: (k) => { m.delete(k) },
  }
})

describe('calendar mock: soft delete and restore', () => {
  it('a delete hides the event and puts it in the trash with deleted_at', () => {
    const was = mockCalendarDelete(RELEASE, TODAY)
    assert.equal(was.id, RELEASE)
    assert.ok(!ids().includes(RELEASE))
    const trash = mockCalendarTrash()
    assert.deepEqual(trash.map((x) => x.id), [RELEASE])
    assert.ok(Date.parse(trash[0].deleted_at) > 0)
  })

  it('restore brings it back with the same id and fields, and empties the trash', () => {
    const was = mockCalendarDelete(RELEASE, TODAY)
    const back = mockCalendarRestore(RELEASE)
    assert.equal(back.id, RELEASE)
    assert.equal(back.title, was.title)
    assert.equal(back.deleted_at, undefined)
    assert.ok(ids().includes(RELEASE))
    assert.equal(ids().filter((x) => x === RELEASE).length, 1)
    assert.deepEqual(mockCalendarTrash(), [])
  })

  it('restoring what is not in the trash is a 404, like the hub', () => {
    assert.throws(() => mockCalendarRestore(PLANNING), (e) => e.status === 404)
  })

  it('the trash is newest deletion first and holds 30 days only', () => {
    mockCalendarDelete(RELEASE, TODAY)
    mockCalendarDelete(PLANNING, TODAY)
    const list = JSON.parse(globalThis.localStorage.getItem('spool.mock.calendar-trash'))
    const now = Date.parse('2026-10-07T12:00:00Z')
    for (const x of list) x.deleted_at = x.id === RELEASE ? '2026-10-07T11:00:00Z' : '2026-10-06T11:00:00Z'
    globalThis.localStorage.setItem('spool.mock.calendar-trash', JSON.stringify(list))
    assert.deepEqual(mockCalendarTrash(now).map((x) => x.id), [RELEASE, PLANNING])
    assert.deepEqual(mockCalendarTrash(now + 30 * 86400000 - 3600000 * 2).map((x) => x.id), [RELEASE])
  })
})

describe('calendar api: restore and trash on the hub', () => {
  it('restore is POST .../{id}/restore and answers the event', async () => {
    const seen = []
    globalThis.fetch = async (url, init) => {
      seen.push([url, init.method])
      return new Response(JSON.stringify({ event: { id: RELEASE } }), { status: 200 })
    }
    const ev = await calendarRestore({ base: 'https://hub', token: 't' }, RELEASE, TODAY)
    assert.equal(ev.id, RELEASE)
    assert.deepEqual(seen, [[`https://hub/v1/calendar/events/${RELEASE}/restore`, 'POST']])
  })

  it('a refused restore throws with the status and token', async () => {
    globalThis.fetch = async () => new Response(JSON.stringify({ error: 'not_found' }), { status: 404 })
    await assert.rejects(calendarRestore({ base: 'https://hub' }, RELEASE, TODAY), (e) => e.status === 404 && e.token === 'not_found')
  })

  it('trash is GET /v1/calendar/trash and answers its events', async () => {
    const seen = []
    globalThis.fetch = async (url, init) => {
      seen.push([url, init.method || 'GET'])
      return new Response(JSON.stringify({ events: [{ id: RELEASE, deleted_at: '2026-10-07T11:00:00Z' }] }), { status: 200 })
    }
    const list = await calendarTrash({ base: 'https://hub' })
    assert.deepEqual(list.map((x) => x.id), [RELEASE])
    assert.deepEqual(seen, [['https://hub/v1/calendar/trash', 'GET']])
  })

  it('the mock workspace answers from the mock', async () => {
    mockCalendarDelete(RELEASE, TODAY)
    assert.deepEqual((await calendarTrash({ mock: true })).map((x) => x.id), [RELEASE])
    assert.equal((await calendarRestore({ mock: true }, RELEASE, TODAY)).id, RELEASE)
  })
})
