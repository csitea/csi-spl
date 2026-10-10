/**
 * Copy link on a calendar event (t1 #spool-hub-ui 9dec05c3, owner msg
 * cbfaaefc): the address that opens the event, `<origin>/calendar?d=<day>&event=<id>`.
 * The path is roadmap-goals' goalCalendarHref (the one builder; spec 089
 * T006 opens it); the day is the one the grid shows the event on.
 */
import { calEventDay } from './calendar-drag.mjs'
import { goalCalendarHref } from './roadmap-goals.mjs'

/**
 * The event's full link on `origin` (the workspace host); '' for an event
 * with no id or no start.
 * @param {{ id?: string, all_day?: boolean, starts_at?: string } | null | undefined} ev
 * @param {string} origin
 * @returns {string}
 */
export function calEventLink(ev, origin) {
  if (!ev || !ev.id || !ev.starts_at) return ''
  const day = calEventDay(ev)
  const path = goalCalendarHref(ev.starts_at, ev.id, () => day)
  return path ? new URL(path, origin).href : ''
}
