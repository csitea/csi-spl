// Spec 089 T006 (owner D4): the reminder pop-up's timer logic
// (utils/calendar-reminders.mjs) and the shape of its plugin: what is due
// now, when to look again, a dismiss remembered per event and reminder
// time, a missed reminder shown while its event has not ended, and no
// spool message or notification call anywhere in the reminder path.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  REMINDER_AHEAD_MS, REMINDER_BEHIND_MS, dueReminders, parseDismissed, readReminders, reminderKey, reminderWindow, withDismissed,
} from '../../src/utils/calendar-reminders.mjs'
import { createMockReminders } from '../../src/utils/calendar-reminders-mock.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const NOW = Date.parse('2026-10-05T09:00:00Z')
const iso = (offMin) => new Date(NOW + offMin * 60000).toISOString()
const ev = (id, remindMin, startMin = remindMin + 15, endMin = startMin + 60, extra = {}) => ({
  id, source: 'event', title: 'Event ' + id, starts_at: iso(startMin), ends_at: iso(endMin), all_day: false, remind_at: iso(remindMin), ...extra,
})

describe('calendar reminders: the read', () => {
  it('asks for the last and the next 24 hours, inside the 31-day limit', () => {
    const w = reminderWindow(NOW)
    assert.equal(Date.parse(w.to) - NOW, REMINDER_AHEAD_MS)
    assert.equal(NOW - Date.parse(w.from), REMINDER_BEHIND_MS)
    assert.ok(Date.parse(w.to) - Date.parse(w.from) <= 31 * 24 * 3600 * 1000)
  })
  it('keeps the event items with an id and a reminder time, by reminder time', () => {
    const body = { reminders: [ev('b', 10), ev('a', 5), { ...ev('c', 1), remind_at: '' }, { ...ev('d', 1), source: 'issue' }, null, { id: 7 }] }
    assert.deepEqual(readReminders(body).map((r) => r.id), ['a', 'b'])
  })
  it('reads a missing or broken body as no reminders', () => {
    for (const b of [null, undefined, {}, { reminders: null }, 'x']) assert.deepEqual(readReminders(b), [])
  })
})

describe('calendar reminders: what is due', () => {
  it('shows a reminder whose time has come and waits for the next one', () => {
    const list = readReminders({ reminders: [ev('now', 0), ev('later', 30), ev('soon', 5)] })
    const { show, next } = dueReminders(list, NOW, {})
    assert.deepEqual(show.map((r) => r.id), ['now'])
    assert.equal(next, 5 * 60000)
  })
  it('says -1 when nothing is left to wait for', () => {
    assert.equal(dueReminders([], NOW, {}).next, -1)
    assert.equal(dueReminders(readReminders({ reminders: [ev('x', -1)] }), NOW, {}).next, -1)
  })
  it('shows a missed reminder while its event has not ended, never after', () => {
    const list = readReminders({ reminders: [ev('running', -120, -60, 30), ev('over', -120, -90, -10)] })
    assert.deepEqual(dueReminders(list, NOW, {}).show.map((r) => r.id), ['running'])
  })
  it('does not show a dismissed reminder again, but does show the same event at a new time', () => {
    const [r] = readReminders({ reminders: [ev('e', -1)] })
    const dismissed = withDismissed({}, r)
    assert.deepEqual(dueReminders([r], NOW, dismissed).show, [])
    const moved = { ...r, remind_at: iso(0) }
    assert.notEqual(reminderKey(moved), reminderKey(r))
    assert.deepEqual(dueReminders([moved], NOW, dismissed).show.map((x) => x.id), ['e'])
  })
})

describe('calendar reminders: the dismissed map', () => {
  it('round-trips through its stored text', () => {
    const [r] = readReminders({ reminders: [ev('e', -1)] })
    const stored = JSON.stringify(withDismissed({}, r))
    assert.deepEqual(Object.keys(parseDismissed(stored, NOW)), [reminderKey(r)])
  })
  it('drops old, malformed and broken entries', () => {
    const old = NOW - 8 * 24 * 3600 * 1000
    const raw = JSON.stringify({ 'a@x': NOW, 'b@x': old, nokey: NOW, 'c@x': 'no' })
    assert.deepEqual(Object.keys(parseDismissed(raw, NOW)), ['a@x'])
    for (const bad of [null, '', '{', '[]', '42']) assert.deepEqual(parseDismissed(bad, NOW), {})
  })
})

describe('calendar reminders: the mock answers the 6.1 shapes', () => {
  it('reminders in [from, to), by remind_at, with every event field', () => {
    const cal = createMockReminders([ev('b', 10), ev('a', 5), ev('out', 60 * 25), { ...ev('none', 0), remind_at: '' }])
    const w = reminderWindow(NOW)
    const body = cal.reminders(w.from, w.to)
    assert.equal(body.from, w.from)
    assert.deepEqual(body.reminders.map((r) => r.id), ['a', 'b'])
    for (const k of ['id', 'source', 'title', 'description', 'kind', 'starts_at', 'ends_at', 'all_day', 'audience', 'mentions', 'creator_type', 'creator_id', 'remind_at', 'topic_id', 'release_version', 'issue_key', 'created_at', 'updated_at']) {
      assert.ok(k in body.reminders[0], k)
    }
    assert.equal(body.reminders[0].audience, 'workspace')
  })
})

describe('calendar reminders: no agent, AI, spool message or notification (D4)', () => {
  const TIMER = 'src/utils/calendar-reminder-timer.ts'
  const files = ['src/utils/calendar-reminders.mjs', 'src/plugins/calendar-reminders.client.ts', TIMER, 'src/components/CalendarReminderPopup.vue']
  it('reads only GET /v1/calendar/reminders', () => {
    assert.match(read(TIMER), /\/v1\/calendar\/reminders/)
    for (const f of files) {
      const src = read(f)
      assert.doesNotMatch(src, /sendMessage|\/v1\/messages|\/v1\/notes|notify|Notification\(|serviceWorker|method:\s*['"](POST|PUT|PATCH|DELETE)/i, f)
    }
  })
  it('keeps the shell small: the plugin loads the timer lazily, the timer loads the pop-up lazily', () => {
    const plugin = read('src/plugins/calendar-reminders.client.ts')
    assert.match(plugin, /import\('~\/utils\/calendar-reminder-timer'\)/)
    assert.doesNotMatch(plugin, /^import (?!type ).*calendar-reminder/m)
    const timer = read(TIMER)
    assert.match(timer, /import\('~\/components\/CalendarReminderPopup\.vue'\)/)
    assert.doesNotMatch(timer, /^import .*CalendarReminderPopup/m)
  })
})
