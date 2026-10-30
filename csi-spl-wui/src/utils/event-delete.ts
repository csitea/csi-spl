// csi-spl-wui/src/utils/event-delete.ts
//
// Spec 162 B7 (E5): Delete selected on Monitoring -> Events. Pure, so the
// unit suite runs it. Apart from event-log.mjs because that one loads with
// the entry (the shipper) and this only with the Events page: the first
// download stays as it was (027 budget ci_initial_gzip_kb).

/** The events client's delete call: one POST /delete for `ids`. */
interface EventsDeleteClient {
  delete: (ids: number[]) => Promise<{ ok: boolean, error: string }>
}

/** What a Delete selected came to: the ids the hub answered, the first error. */
interface EventsDeleteResult {
  ok: boolean
  done: number[]
  error: string
}

/** One delete names at most this many ids (hub: 400 above it, spec 162 3.2). */
export const EVENTS_DELETE_MAX: number = 200

/**
 * Spec 162 B7: delete the selected rows, one call per EVENTS_DELETE_MAX ids,
 * in order, stopping at the first failed call. Never throws:
 * `{ ok, done: [ids of the calls the hub answered], error }`; the ids of a
 * failed or unsent call are not in `done`, so their rows stay.
 */
export async function deleteEventIds(
  client: EventsDeleteClient,
  ids: Array<number | string>,
): Promise<EventsDeleteResult> {
  const list = (Array.isArray(ids) ? ids : []).map(Number).filter((n) => Number.isInteger(n) && n > 0)
  const done: number[] = []
  for (let i = 0; i < list.length; i += EVENTS_DELETE_MAX) {
    const part = list.slice(i, i + EVENTS_DELETE_MAX)
    const res = await client.delete(part)
    if (!res.ok) return { ok: false, done, error: res.error || 'unavailable' }
    done.push(...part)
  }
  return { ok: true, done, error: '' }
}

/** A failed delete as an i18n key: signed out, else the delete sentence. */
export function eventsDeleteErrorKey(error: string): string {
  return error === 'unauthenticated' ? 'events.signed_out' : 'events.delete_failed'
}
