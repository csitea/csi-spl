/**
 * The viewer's picked time zone source, the part of date-iso.mjs the first
 * screen needs (SPL-5780): app.vue hands in the source at start, and nothing
 * on the first screen prints a date. date-iso.mjs reads the source from here
 * and re-exports setZoneSource as setTimeZoneSource (one name in two utils/
 * files would collide in the auto-imports), so its callers and tests are
 * unchanged; the formatters load with the first chunk that prints a date.
 */

/* Read through a getter so a Vue app can hand in a reactive source: a
   computed that prints a time then re-renders when the zone changes.
   "" = the browser's zone. Node tests use process.env.TZ for that. */
let zoneSource = () => ""

/**
 * Where the zone comes from. `source` is a function answering an IANA zone or
 * "" (the browser's). An unknown zone falls back to the browser's.
 * @param {() => string} source
 */
export function setZoneSource(source) {
  zoneSource = typeof source === "function" ? source : () => ""
}

/** The picked zone as the source answers it now ("" = the browser's). */
export function pickedTimeZone() {
  return String(zoneSource() || "")
}
