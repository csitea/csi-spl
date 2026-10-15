/**
 * SPL-2034 (design B, t1 edc177bc): /calendar?d=<day>&issue=<KEY> whose
 * shown range lacks the deadline. The calendar reads the issue once - only
 * on such a miss; a normal open paints from the hub's item - and says why:
 * - not readable (no access, unknown key): `calendar_event.not_available`,
 *   Open issue disabled (`denied`);
 * - closed (done, diss: off the calendar, SPL-37): `issue_closed`;
 * - no deadline: `issue_no_deadline`;
 * - an open deadline outside the range (`d=` went stale): `moveTo` its day.
 * Loaded lazily by the calendar views on a miss.
 */
import { isoDate } from './date-iso.mjs'

const CLOSED = new Set(['done', 'diss'])

/**
 * @param {{ getIssue: (ref: string) => Promise<{ issue?: { status?: string, deadline?: string } }> }} api
 * @param {string} key
 * @param {string} from the range's first day (YYYY-MM-DD)
 * @param {string} to the day after its last
 * @returns {Promise<{ notice: string, denied: boolean, moveTo: string }>}
 */
export async function deadlineLinkMiss(api, key, from, to) {
  let issue
  try {
    issue = (await api.getIssue(key))?.issue
  } catch {
    issue = null
  }
  if (!issue) return { notice: 'calendar_event.not_available', denied: true, moveTo: '' }
  if (CLOSED.has(String(issue.status || ''))) return { notice: 'calendar_event.issue_closed', denied: false, moveTo: '' }
  const day = issue.deadline ? isoDate(issue.deadline) : ''
  if (!day) return { notice: 'calendar_event.issue_no_deadline', denied: false, moveTo: '' }
  if (day < from || day >= to) return { notice: '', denied: false, moveTo: day }
  return { notice: 'calendar_event.not_available', denied: false, moveTo: '' }
}
