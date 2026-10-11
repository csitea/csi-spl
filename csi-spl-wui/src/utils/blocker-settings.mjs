/**
 * "Blocker to issue after N minutes", the WUI side: the registered workspace
 * key of tenants.settings (spec 098) that the hub's blocker sweep reads
 * (store/blocker_issue.go). A blocker that tags a person or an agent who does
 * not answer in its topic within N minutes becomes an issue assigned to them;
 * 0 turns it off. Rides only with the lazy General page. Node tests import
 * this file.
 */

export const BLOCKER_KEY_MINUTES = 'blocker.issue_after_minutes'

/** The range as the hub registers it; a value outside is refused 400 bad_setting. */
export const BLOCKER_MINUTES_RANGE = Object.freeze({ min: 0, max: 1440 })
export const BLOCKER_MINUTES_DEFAULT = 3

/** Whether v is a value the hub takes for the key. */
export function blockerMinutesValid(v) {
  return Number.isInteger(v) && v >= BLOCKER_MINUTES_RANGE.min && v <= BLOCKER_MINUTES_RANGE.max
}

/** N in force from a GET/PATCH /v1/tenant/settings `settings` map; absent or junk = the default. */
export function blockerMinutesOf(settings) {
  const v = settings && typeof settings === 'object' ? settings[BLOCKER_KEY_MINUTES] : undefined
  return blockerMinutesValid(v) ? v : BLOCKER_MINUTES_DEFAULT
}

/** The PATCH settings map for the form value: {} when unchanged or invalid. */
export function blockerMinutesPatch(stored, form) {
  const n = typeof form === 'string' && form.trim() !== '' ? Number(form) : form
  if (!blockerMinutesValid(n) || n === stored) return {}
  return { [BLOCKER_KEY_MINUTES]: n }
}
