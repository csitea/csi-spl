/**
 * The mock workspace's calendar reminders (NUXT_PUBLIC_USE_MOCK), so the
 * reminder pop-up (spec 089 T006) and its e2e run without a hub. It answers
 * GET /v1/calendar/reminders in the 6.1 wire format: `event` items whose
 * `remind_at` is in [from, to), by `remind_at`. Empty by default (the events
 * and marks of the section are calendar-mock.mjs, T007); a test seeds it
 * through localStorage `spool.mock.calendar-reminders` (an array of event
 * objects) before the page loads. Loaded lazily by the reminder timer only.
 */

export const MOCK_REMINDERS_SEED_KEY = 'spool.mock.calendar-reminders'

/** One 6.1.1 event object with every field set, the seed's fields winning. */
function eventOf(s) {
  return {
    id: '', source: 'event', title: '', description: '', kind: 'other', starts_at: '', ends_at: '', all_day: false,
    audience: 'public', mentions: [], creator_type: 'human', creator_id: 'HUM-1', remind_at: '', topic_id: '',
    release_version: '', issue_key: '', created_at: '', updated_at: '',
    ...s,
  }
}

/** The reminders answer over `seed` (event objects). */
export function createMockReminders(seed = []) {
  const rows = (Array.isArray(seed) ? seed : []).filter((s) => s && typeof s === 'object' && s.id).map(eventOf)
  const t = (v) => Date.parse(v)
  return {
    /** GET /v1/calendar/reminders?from=&to= (every mock event is the viewer's own) */
    reminders(from, to) {
      const list = rows
        .filter((e) => e.remind_at && t(e.remind_at) >= t(from) && t(e.remind_at) < t(to))
        .sort((a, b) => t(a.remind_at) - t(b.remind_at) || a.id.localeCompare(b.id))
        .map((e) => ({ ...e, mentions: [...e.mentions] }))
      return { from, to, reminders: list }
    },
  }
}

let shared = null

/** The page's one answer, seeded from localStorage (a test's seed), empty without one. */
export function sharedMockReminders() {
  if (shared) return shared
  let seed = []
  try { seed = JSON.parse(localStorage.getItem(MOCK_REMINDERS_SEED_KEY) || '[]') } catch { seed = [] }
  shared = createMockReminders(seed)
  return shared
}
