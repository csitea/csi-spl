// Spec 097 section 11.8.2, row T16: the remembered Calendar filter is the
// session claim calendar_filter, kept per member and workspace by the hub
// (auth.CalendarFilter, tenant_memberships.settings). The session store
// mirrors a save with setCalendarFilter, so the claim and the hub's shape
// must agree: {tags, labels}, null = no filter.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const store = read('src/stores/session.ts')
const goFilter = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/calendar_filter.go')
const goHandler = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')

describe('calendar_filter claim', () => {
  it('the hub answers the claim and its {tags, labels} shape, at most 20 of each', () => {
    assert.match(goHandler, /CalendarFilter \*CalendarFilter `json:"calendar_filter"`/)
    assert.match(goFilter, /Tags\s+\[\]string `json:"tags"`/)
    assert.match(goFilter, /Labels\s+\[\]string `json:"labels"`/)
    assert.match(goFilter, /CalendarFilterMax = 20\b/)
  })
  it('the session claims carry the same shape, null = no filter', () => {
    assert.match(store, /calendar_filter\?: CalendarFilter \| null/)
    const iface = store.match(/export interface CalendarFilter \{([^}]*)\}/)
    assert.ok(iface, 'CalendarFilter interface not found in session.ts')
    assert.match(iface[1], /tags: string\[\]/)
    assert.match(iface[1], /labels: string\[\]/)
  })
})

describe('setCalendarFilter', () => {
  it('mirrors the saved filter (or null) into the claim, and the store exposes it', () => {
    const fn = store.match(/function calendarFilterMirror\([^)]*\) \{([\s\S]*?)\n\}/)
    assert.ok(fn, 'calendarFilterMirror not found in session.ts')
    assert.match(fn[1], /function setCalendarFilter\(filter: CalendarFilter \| null\)/)
    assert.match(fn[1], /calendar_filter: filter/)
    assert.match(fn[1], /return \{ setCalendarFilter \}/)
    assert.match(store, /\.\.\.calendarFilterMirror\(claims\)/, 'the store must spread calendarFilterMirror')
  })
})
