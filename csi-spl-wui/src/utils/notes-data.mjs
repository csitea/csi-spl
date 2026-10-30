/**
 * Spec 155 row B10 (SPL-4331): Settings -> Notes, the person's own copy and
 * erase of every note (2.8):
 *   GET    /v1/me/realm/notes/export   every note, archived ones too, as one
 *                                      JSON file notes-<date>.json
 *   DELETE /v1/me/realm/notes          every note of the person; 204
 * Realm routes: the person comes from the session alone and no workspace is
 * named (X-Spool-Tenant is never sent). On the mock bundle there is no hub:
 * the export and the erase go through the notes store's own calls (load,
 * get, remove), so the list the Notes page shows is the one erased.
 */
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

/** The file name of an export taken at `now` (the hub's, notes-<UTC date>.json). */
export function notesExportName(now = new Date()) {
  const d = now instanceof Date && !Number.isNaN(now.getTime()) ? now : new Date()
  return `notes-${d.toISOString().slice(0, 10)}.json`
}

/** The file name the hub's Content-Disposition offers, else `fallback`. */
export function notesDownloadName(disposition, fallback) {
  const m = String(disposition || '').match(/filename="?(notes-\d{4}-\d{2}-\d{2}\.json)"?/)
  return m ? m[1] : fallback
}

/** True only when the typed text is the confirmation word (case and outer spaces aside). */
export function eraseConfirmed(typed, word) {
  const w = String(word || '').trim().toLowerCase()
  return w !== '' && String(typed || '').trim().toLowerCase() === w
}

function realmUrl(api, tail) {
  return `${String(api.base || '').replace(/\/+$/, '')}/v1/me/realm/notes${tail}`
}

function headersOf(api) {
  const h = { accept: 'application/json' }
  if (api.token) h.authorization = `Bearer ${api.token}`
  return h
}

/** A refusal as an Error with the hub's `status` and `error` token. */
async function refusal(r, what) {
  let token = ''
  try { token = String((await r.json())?.error || '') } catch { /* not json */ }
  return Object.assign(new Error(`${what} ${r.status}`), { status: r.status, token })
}

/**
 * The export as { blob, name }. `notes` is the notes store, read on the mock
 * bundle only: every note whole, in the hub's { exported_at, notes } shape.
 */
export async function exportNotes(api, notes, now = new Date()) {
  if (api.mock) {
    await notes.load()
    const whole = []
    for (const row of notes.notes) {
      const got = await notes.get(row.id)
      if (got && got.note) whole.push(got.note)
    }
    const text = JSON.stringify({ exported_at: now.toISOString(), notes: whole }, null, 2)
    return { blob: new Blob([text], { type: 'application/json' }), name: notesExportName(now) }
  }
  const r = await fetch(realmUrl(api, '/export'), {
    credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'notes export')
  return { blob: await r.blob(), name: notesDownloadName(r.headers.get('content-disposition'), notesExportName(now)) }
}

/**
 * Erase every note; the store's list is read again after, so it shows none.
 * A note deleted on the Notes page and still waiting on its Undo toast (the
 * store's `hidden`, D2) is erased too: the list leaves it out, so on the mock
 * bundle it is removed by its id; on the hub the DELETE took it, so it is no
 * longer held. An Undo after the erase brings nothing back (the store's
 * unhide refuses a note it no longer holds).
 */
export async function eraseNotes(api, notes) {
  if (api.mock) {
    await notes.load()
    const ids = new Set([...notes.notes.map((row) => row.id), ...(notes.hidden || [])])
    for (const id of ids) await notes.remove(id)
  } else {
    const r = await fetch(realmUrl(api, ''), {
      method: 'DELETE', credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
    })
    if (!r.ok) throw await refusal(r, 'notes erase')
    notes.hidden = []
  }
  await notes.load()
}
