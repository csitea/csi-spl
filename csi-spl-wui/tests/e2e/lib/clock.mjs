// A fixed clock and zone for the calendar e2e tests (spec 133 action 4).
//
// The calendar draws today, its week and its month, so a test that reads the
// real date passes on some days and fails on others: wf 10 was red every
// Sunday 20-23Z (msg-ai-actions), on Monday 00-02Z (calendar-drag "tab A
// moves it to 09:00", calendar-phone-month's grid cell) and whenever the
// runner's zone put the Node side on another day than the browser.
//
// E2E_NOW is the instant every calendar test starts at: a Wednesday in the
// middle of a month, at 10:00Z, so today, its week and its month are the
// same in UTC and in every zone the tests emulate (UTC-5 .. UTC+9).
// The clock still ticks from there; timers and waits are real time.
//   - Node side: E2E_TODAY / e2eNow() instead of Date.now().
//   - browser: pinClock(page) before the first goto; it also sets the
//     page's zone (UTC unless the test names one), so the runner's TZ never
//     reaches the page.
// CAL_E2E_NOW=<ISO instant> starts the clock at another instant: it is how
// a red day is reproduced on purpose (CAL_E2E_NOW=2026-10-12T01:20:00Z).
import { calIsoDay } from '../../../src/utils/calendar-year.mjs'

export const E2E_NOW_DEFAULT = '2026-10-14T10:00:00Z'
export const E2E_NOW = Date.parse(process.env.CAL_E2E_NOW || E2E_NOW_DEFAULT)
if (Number.isNaN(E2E_NOW)) throw new Error(`CAL_E2E_NOW is not an ISO instant: ${process.env.CAL_E2E_NOW}`)

/** ms to add to the real clock to read the pinned one; the same in Node and in every page */
export const E2E_CLOCK_OFFSET = E2E_NOW - Date.now()
/** the pinned clock, ticking */
export const e2eNow = () => Date.now() + E2E_CLOCK_OFFSET
/** today (UTC day) on the pinned clock */
export const E2E_TODAY = calIsoDay(E2E_NOW)

/** Pin `page`'s Date to the e2e clock and its zone to `zone` (null keeps the browser's). */
export async function pinClock(page, zone = 'UTC') {
  if (zone) await page.emulateTimezone(zone)
  await page.evaluateOnNewDocument((off) => {
    const Real = globalThis.Date
    if (Real.e2ePinned) return
    function PinnedDate(...a) {
      if (!new.target) return new Real(Real.now() + off).toString()
      return Reflect.construct(Real, a.length ? a : [Real.now() + off], new.target)
    }
    PinnedDate.prototype = Real.prototype
    Object.setPrototypeOf(PinnedDate, Real)
    PinnedDate.now = () => Real.now() + off
    PinnedDate.e2ePinned = true
    globalThis.Date = PinnedDate
  }, E2E_CLOCK_OFFSET)
}
