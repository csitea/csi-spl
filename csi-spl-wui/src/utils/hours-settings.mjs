/**
 * Hours tracking settings (spec 107 section 4.2, T016), the WUI side: the
 * four registered workspace keys of tenants.settings (spec 098) with the
 * hub's defaults and ranges (store/hours.go), and the member's own
 * "Count my reading time" switch (section 1.2). Rides only with the lazy
 * General page and the Settings dialog, never the initial chunk. Node tests
 * import this file.
 */

export const HOURS_KEY_PERIOD = 'hours.period'
export const HOURS_KEY_GRACE = 'hours.freeze_grace_days'
export const HOURS_KEY_IDLE = 'hours.idle_minutes'
export const HOURS_KEY_TZ = 'hours.tz'

/** The hours.period choices, in the order the select lists them. */
export const HOURS_PERIOD_OPTIONS = Object.freeze(['week', 'two_weeks', 'month'])

/** Ranges as the hub registers them; a value outside is refused 400 bad_setting. */
export const HOURS_GRACE_RANGE = Object.freeze({ min: 0, max: 7 })
export const HOURS_IDLE_RANGE = Object.freeze({ min: 5, max: 30 })

export const HOURS_DEFAULTS = Object.freeze({ period: 'week', graceDays: 2, idleMinutes: 10, tz: 'UTC' })

const intIn = (v, r, d) => (Number.isInteger(v) && v >= r.min && v <= r.max ? v : d)

/**
 * The four values in force from a GET/PATCH /v1/tenant/settings `settings`
 * map. Absent or junk is the hub's default, so the form always has a value.
 */
export function hoursSettingsOf(settings) {
  const s = settings && typeof settings === 'object' && !Array.isArray(settings) ? settings : {}
  const tz = typeof s[HOURS_KEY_TZ] === 'string' && s[HOURS_KEY_TZ].trim() ? s[HOURS_KEY_TZ].trim() : HOURS_DEFAULTS.tz
  return {
    period: HOURS_PERIOD_OPTIONS.includes(s[HOURS_KEY_PERIOD]) ? s[HOURS_KEY_PERIOD] : HOURS_DEFAULTS.period,
    graceDays: intIn(s[HOURS_KEY_GRACE], HOURS_GRACE_RANGE, HOURS_DEFAULTS.graceDays),
    idleMinutes: intIn(s[HOURS_KEY_IDLE], HOURS_IDLE_RANGE, HOURS_DEFAULTS.idleMinutes),
    tz,
  }
}

/**
 * The PATCH `settings` map for the fields of `form` that differ from
 * `stored`; {} when nothing changed. A number field arrives from a number
 * input and may be a string or NaN: the hub validates the range, this only
 * makes it an integer (a non-integer is sent as is and refused there).
 */
export function hoursSettingsPatch(stored, form) {
  const out = {}
  if (form.period !== stored.period) out[HOURS_KEY_PERIOD] = form.period
  const grace = Number(form.graceDays)
  if (grace !== stored.graceDays) out[HOURS_KEY_GRACE] = Number.isFinite(grace) ? grace : form.graceDays
  const idle = Number(form.idleMinutes)
  if (idle !== stored.idleMinutes) out[HOURS_KEY_IDLE] = Number.isFinite(idle) ? idle : form.idleMinutes
  const tz = String(form.tz || '').trim()
  if (tz !== stored.tz) out[HOURS_KEY_TZ] = tz
  return out
}

/** The mock hub's check of one hours key (the hub's rule, store/hours.go); false = 400 bad_setting. */
export function hoursSettingValid(key, v) {
  if (key === HOURS_KEY_PERIOD) return HOURS_PERIOD_OPTIONS.includes(v)
  if (key === HOURS_KEY_GRACE) return Number.isInteger(v) && v >= HOURS_GRACE_RANGE.min && v <= HOURS_GRACE_RANGE.max
  if (key === HOURS_KEY_IDLE) return Number.isInteger(v) && v >= HOURS_IDLE_RANGE.min && v <= HOURS_IDLE_RANGE.max
  if (key === HOURS_KEY_TZ) return typeof v === 'string' && /^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/.test(v) && v.length <= 64
  return false
}

/** The `hours_reading` session claim: only a literal false turns it off (null = never picked = on). */
export function hoursReadingOn(claim) {
  return claim !== false
}
