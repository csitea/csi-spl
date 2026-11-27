/**
 * SPL-6675 (HUM-5, topic ea3ea4a3, poll c3e059ea BTH): a type:calendar search
 * lists only real entries, nearest upcoming first. The hub answers the
 * calendars section by start, oldest first, from a year back (hub
 * search_calendar.go), a few a page: its first page was last year's entries.
 * So the WUI reads the section to its end (at most CALENDAR_MAX_PAGES pages),
 * drops the week-number markers a synced calendar carries ("Week 48", a title
 * that is only the week), and orders the rest: upcoming by start, then the
 * past newest first. Loaded with the search answer, never on the first paint.
 */

/** The section's pages read for one search. */
export const CALENDAR_MAX_PAGES = 10

/* "Week 48", "Week 48 of 2026" (spec 097 5.2: an imported or connected
   calendar's week-number entry; spec 197 v1.2), and the same in the short and
   local forms a synced calendar sends: "W48", "KW 48", "Viikko 48" ... A
   real entry that only starts so ("Week 48 sprint planning") stays. */
const WEEK_MARKER_RE = /^\s*(?:week|wk|w|kw|viikko|vecka|uke|uge|semaine|semana|settimana|woche|неделя|седмица|тиждень)\s*(?:#|no\.?|nr\.?)?\s*\d{1,2}(?:\s+(?:of|\/)\s*\d{4})?\s*$/i

type Row = Record<string, unknown>
type Group = { type: string, items: Row[], next?: unknown }

function titleText(row: Row): string {
  const t = row && row.title
  if (t && typeof t === 'object') return String((t as { text?: unknown }).text ?? '')
  return String(t ?? '')
}

/** A week-number marker: its title is only "Week <n>" (or a locale's word for it). */
export function isWeekMarker(row: Row): boolean {
  return WEEK_MARKER_RE.test(titleText(row))
}

/**
 * The real entries, nearest upcoming first: an entry that has not ended yet,
 * by start ascending; then the past ones, the latest first.
 */
export function orderCalendarRows<T extends Row>(rows: T[], nowMs: number): T[] {
  const at = (r: Row) => Date.parse(String(r.starts_at || '')) || 0
  const end = (r: Row) => Date.parse(String(r.ends_at || '')) || at(r)
  const real = (rows || []).filter((r) => !isWeekMarker(r))
  const ahead = real.filter((r) => end(r) >= nowMs).sort((a, b) => at(a) - at(b))
  const past = real.filter((r) => end(r) < nowMs).sort((a, b) => at(b) - at(a))
  return [...ahead, ...past]
}

/**
 * The answer with its calendars section read whole, filtered and ordered;
 * `next` cleared, since the order spans every page. Unchanged without one.
 */
export async function completeCalendarSection<R extends { groups: Group[] }>(result: R, nextPage: (cursor: string) => Promise<{ groups: Group[] }>, nowMs: number): Promise<R> {
  const g = result && Array.isArray(result.groups) ? result.groups.find((x) => x.type === 'calendars') : null
  if (!g) return result
  const items = [...g.items]
  const seen = new Set(items.map((x) => x.key))
  let cursor = g.next ? String(g.next) : ''
  for (let i = 0; cursor && i < CALENDAR_MAX_PAGES; i++) {
    const page = await nextPage(cursor)
    const pg = page && Array.isArray(page.groups) ? page.groups.find((x) => x.type === 'calendars') : null
    if (!pg) break
    for (const it of pg.items) if (!seen.has(it.key)) { seen.add(it.key); items.push(it) }
    cursor = pg.next ? String(pg.next) : ''
  }
  const groups = result.groups
    .map((x) => (x === g ? { ...g, items: orderCalendarRows(items, nowMs), next: null } : x))
    .filter((x) => x.type !== 'calendars' || x.items.length)
  return { ...result, groups }
}
