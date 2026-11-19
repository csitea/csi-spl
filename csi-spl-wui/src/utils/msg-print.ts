// csi-spl-wui/src/utils/msg-print.ts
//
// SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020): "Export
// to PDF" of one message card or of a whole topic. The PDF is the browser's own
// print-to-PDF of a print-only render (components/MessagePrint.vue, mounted on
// the click by utils/msg-print-run.ts), so no PDF library ships. Pure: the Node
// tests import it (tests/unit/lib/load-ts.mjs).

/** the longest slug a file name carries, in characters */
export const PRINT_SLUG_MAX = 60

/**
 * A title as a file-name slug: letters and digits of any script kept and
 * lower-cased, every other run of characters one dash, no dash at either end,
 * at most PRINT_SLUG_MAX characters. An empty result is `topic`.
 */
export function printSlug(title: unknown): string {
  const flat = String(title ?? '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
  const cut = Array.from(flat).slice(0, PRINT_SLUG_MAX).join('').replace(/-+$/, '')
  return cut || 'topic'
}

/**
 * The PDF's file name, without `.pdf` (the browser's Save as PDF adds it to
 * the document title it offers): `<topic-title>-<msg8>` for one card,
 * `<topic-title>` for a whole topic.
 *
 * @param title the topic's title
 * @param msgId the card's id; absent = the whole topic
 */
export function printFileName(title: unknown, msgId?: unknown): string {
  const id = String(msgId ?? '').replace(/[^0-9a-zA-Z]/g, '').slice(0, 8).toLowerCase()
  return id ? `${printSlug(title)}-${id}` : printSlug(title)
}

/**
 * The rows a topic export prints: the ids of the cards on screen, in the order
 * they are shown, each matched to its message. An id with no message is left
 * out, a repeated id printed once.
 *
 * @param ids data-msg-id of each card, top to bottom
 * @param rows every message the pane holds (opener rows included)
 */
export function rowsInShownOrder<T = Record<string, unknown>>(ids: unknown, rows: unknown): T[] {
  const byId = new Map<string, T>()
  for (const m of Array.isArray(rows) ? rows : []) {
    const id = m && typeof m === 'object' ? String((m as { msg_id?: unknown }).msg_id || '') : ''
    if (id && !byId.has(id)) byId.set(id, m)
  }
  const seen = new Set<string>()
  const out: T[] = []
  for (const raw of Array.isArray(ids) ? ids : []) {
    const id = String(raw || '')
    if (!id || seen.has(id) || !byId.has(id)) continue
    seen.add(id)
    out.push(byId.get(id) as T)
  }
  return out
}

/**
 * The key a card's attachment is found by in the print's picture map: its
 * file id, else its sha256, path or name.
 *
 * @param f a v:1 file ref
 */
export function printFileKey(f: unknown): string {
  const r = (f && typeof f === 'object' ? f : {}) as { file_id?: unknown, sha256?: unknown, path?: unknown, name?: unknown }
  return String(r.file_id || r.sha256 || r.path || r.name || '')
}
