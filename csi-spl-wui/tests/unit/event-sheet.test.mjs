// SPL-3366: sort and filter the rows the event log already holds.
// The page never sends a new hub query. This module is the whole rule.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  applyEventSheet,
  emptyEventFilters,
  emptyEventSort,
  eventSortDirKey,
  eventSortLabel,
  filtersActive,
  nextEventSort,
  presentValues,
  sortEvents,
} from '../../src/utils/event-sheet.mjs'

function ev(over = {}) {
  return {
    id: 1,
    error_id: 'e-1',
    at: '2026-10-24T08:00:00Z',
    received_at: '2026-10-24T08:00:01Z',
    source: 'wui',
    status: 500,
    message: 'event 1',
    route: '/events',
    ...over,
  }
}

const ids = (rows) => rows.map((r) => r.id)

describe('nextEventSort', () => {
  it('cycles one column ascending, descending, then back to newest-first', () => {
    const start = emptyEventSort()
    const asc = nextEventSort('message', start)
    const desc = nextEventSort('message', asc)
    const back = nextEventSort('message', desc)
    assert.deepEqual(start, { col: '', dir: '' })
    assert.deepEqual(asc, { col: 'message', dir: 'asc' })
    assert.deepEqual(desc, { col: 'message', dir: 'desc' })
    assert.deepEqual(back, { col: '', dir: '' })
  })

  it('starts a different column at ascending and rejects an unknown column', () => {
    const cur = { col: 'message', dir: 'asc' }
    assert.deepEqual(nextEventSort('source', cur), { col: 'source', dir: 'asc' })
    assert.deepEqual(cur, { col: 'message', dir: 'asc' })
    assert.deepEqual(nextEventSort('nope', cur), emptyEventSort())
    assert.deepEqual(nextEventSort('message', null), { col: 'message', dir: 'asc' })
  })
})

describe('eventSortLabel', () => {
  it('names When, newest first, while no column is selected', () => {
    assert.deepEqual(eventSortLabel(emptyEventSort()), {
      colKey: 'events.col_when',
      dirKey: 'issues_mobile.dir_date_desc',
      active: false,
    })
    assert.equal(eventSortDirKey('when', 'asc'), 'issues_mobile.dir_date_asc')
    assert.equal(eventSortDirKey('when', 'desc'), 'issues_mobile.dir_date_desc')
  })

  it('uses text direction words for status, not a number word', () => {
    assert.deepEqual(eventSortLabel({ col: 'status', dir: 'desc' }), {
      colKey: 'events.col_status',
      dirKey: 'issues_mobile.dir_text_desc',
      active: true,
    })
    assert.equal(eventSortDirKey('message', 'asc'), 'issues_mobile.dir_text_asc')
    assert.equal(eventSortLabel(null).active, false)
  })
})

describe('sortEvents', () => {
  it('defaults to newest instant, then the higher id', () => {
    const rows = [
      ev({ id: 1, at: '2026-10-24T08:00:00Z' }),
      ev({ id: 3, at: '2026-10-24T08:00:00Z' }),
      ev({ id: 2, at: '2026-10-24T09:00:00Z' }),
    ]
    const snap = JSON.parse(JSON.stringify(rows))
    assert.deepEqual(ids(sortEvents(rows, emptyEventSort())), [2, 3, 1])
    assert.deepEqual(rows, snap)
  })

  it('sorts When ascending and reads received_at when at is empty', () => {
    const rows = [
      ev({ id: 1, at: null, received_at: '2026-10-24T10:00:00Z' }),
      ev({ id: 2, at: '2026-10-24T09:00:00Z' }),
    ]
    assert.deepEqual(ids(sortEvents(rows, { col: 'when', dir: 'asc' })), [2, 1])
    assert.deepEqual(ids(sortEvents(rows, { col: 'when', dir: 'desc' })), [1, 2])
    assert.deepEqual(ids(sortEvents(rows, emptyEventSort())), [1, 2])
  })

  it('sorts message as text and status as a number', () => {
    const rows = [
      ev({ id: 1, message: 'event 9', status: 20 }),
      ev({ id: 2, message: 'event 1', status: 500 }),
      ev({ id: 3, message: 'event 10', status: 100 }),
      ev({ id: 4, message: '', status: 0 }),
    ]
    assert.deepEqual(ids(sortEvents(rows, { col: 'message', dir: 'asc' })), [4, 2, 3, 1])
    assert.deepEqual(ids(sortEvents(rows, { col: 'message', dir: 'desc' })), [1, 3, 2, 4])
    assert.deepEqual(ids(sortEvents(rows, { col: 'status', dir: 'asc' })), [4, 1, 3, 2])
  })
})

describe('filterEvents', () => {
  const rows = [
    ev({ id: 5, message: 'Hello', source: 'wui', status: 0, route: '/lobby', error_id: 'E-5' }),
    ev({ id: 12, message: 'event 12', source: 'api', status: 200, route: '/events', error_id: 'e-12' }),
    ev({ id: 4, at: '2026-10-25T00:00:00Z', message: 'later', source: 'hub', status: 404 }),
  ]

  it('matches text by contains, trims, and keeps source exact', () => {
    const hit = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), message: '  hello ' },
      pinId: '',
    })
    assert.deepEqual(ids(hit), [5])
    const src = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), source: 'api' },
      pinId: '',
    })
    assert.deepEqual(ids(src), [12])
    const wrongCase = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), source: 'API' },
      pinId: '',
    })
    assert.deepEqual(ids(wrongCase), [])
    const st = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), status: '0' },
      pinId: '',
    })
    assert.deepEqual(ids(st), [5])
    const all = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), status: '' },
      pinId: '',
    })
    assert.equal(all.length, 3)
  })

  it('matches When as text and as a UTC day', () => {
    const day = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), when: 'Wed, 24 Oct 2026 08:00:00 GMT' },
      pinId: '',
    })
    assert.deepEqual(ids(day), [12, 5])
    const raw = applyEventSheet(rows, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), when: '2026-10-25' },
      pinId: '',
    })
    assert.deepEqual(ids(raw), [4])
  })

  it('keeps a pinned row that the filter would hide, in sort order', () => {
    const out = applyEventSheet(rows, {
      sort: { col: 'message', dir: 'asc' },
      filters: { ...emptyEventFilters(), message: 'event 12' },
      pinId: '5',
    })
    assert.deepEqual(ids(out), [12, 5])
  })

  it('filters the rows of two pages together and does not mutate them', () => {
    const page = rows.concat([ev({ id: 7, source: 'api', message: 'older', at: '2026-10-23T08:00:00Z' })])
    const snap = JSON.parse(JSON.stringify(page))
    const out = applyEventSheet(page, {
      sort: emptyEventSort(),
      filters: { ...emptyEventFilters(), source: 'api' },
      pinId: '',
    })
    assert.deepEqual(ids(out), [12, 7])
    assert.deepEqual(page, snap)
  })
})

describe('presentValues and filtersActive', () => {
  it('lists the values on the rows, status numeric, blanks dropped', () => {
    const rows = [
      ev({ source: 'wui', status: 500 }),
      ev({ source: 'api', status: 0 }),
      ev({ source: '', status: 100 }),
      ev({ source: 'api', status: 20 }),
    ]
    assert.deepEqual(presentValues(rows, 'source'), ['api', 'wui'])
    assert.deepEqual(presentValues(rows, 'status'), ['0', '20', '100', '500'])
  })

  it('treats a whitespace filter as no filter', () => {
    assert.equal(filtersActive(emptyEventFilters()), false)
    assert.equal(filtersActive({ ...emptyEventFilters(), when: '   ' }), false)
    assert.equal(filtersActive({ ...emptyEventFilters(), route: ' /events ' }), true)
  })
})
