// chunk-note.ts - the vue:error hook filter for a stale chunk (SPL-4525).
//
// A tab older than a WUI deploy asks for a /_nuxt/<hash>.js the new build no
// longer has. chunk-reload.client.ts reloads the tab into the new build; that
// is an app update, not a defect. So the error journal records ONE info note
// per page load ("app updated, reloaded") instead of one error per failed
// lazy component. A reload starts a new page, with a new filter.
import { isChunkLoadError } from './chunk-reload'

/** The note's record fields (noteError input). `inline`: the snackbar skips it. */
export const APP_UPDATED_NOTE = Object.freeze({
  name: 'Info',
  code: 'info.app_updated',
  message: 'app updated, reloaded',
  inline: true,
})

export type ChunkNoteVerdict = 'error' | 'note' | 'skip'

/**
 * One filter per page load. `reloads` says whether chunk-reload will reload
 * now: offline it does not (080 T006), and then the failure stays an error.
 */
export function createChunkNoteFilter(reloads: () => boolean = () => true): (err: unknown) => ChunkNoteVerdict {
  let noted = false
  return (err) => {
    if (!isChunkLoadError(err) || !reloads()) return 'error'
    if (noted) return 'skip'
    noted = true
    return 'note'
  }
}
