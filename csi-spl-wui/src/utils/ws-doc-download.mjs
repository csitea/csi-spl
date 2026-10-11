/**
 * Download a workspace doc (owner HUM-10, sienna msg 814fe6e1: the business
 * owner downloads the spec to compare it with his own AI): the stored
 * markdown as GET /v1/workspace/docs/<path> returned it, UTF-8, saved as
 * <basename>.md. Its own module, imported on the click, so none of it ships
 * in the first screen (ws-docs.mjs is preloaded by index.html).
 * Node tests import this file.
 */

import { saveBlob } from './save-blob.mjs'

/** The file name a downloaded doc is saved as: its basename, ending in .md. */
export function wsDocFileName(path) {
  const name = String(path || '').split('/').pop() || 'doc'
  return /\.md$/i.test(name) ? name : name + '.md'
}

/** The downloaded file: the stored markdown, not the rendered HTML. */
export function wsDocBlob(md) {
  return new Blob([String(md ?? '')], { type: 'text/markdown;charset=utf-8' })
}

/** Hand the browser the doc to save. */
export function downloadWsDoc(path, md) {
  saveBlob(wsDocBlob(md), wsDocFileName(path))
}
