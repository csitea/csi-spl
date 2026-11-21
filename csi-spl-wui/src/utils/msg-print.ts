// csi-spl-wui/src/utils/msg-print.ts
//
// SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020): "Export
// to PDF" of one message card or of a whole topic. The PDF is the browser's own
// print-to-PDF of a print-only render (components/MessagePrint.vue, mounted on
// the click by utils/msg-print-run.ts), so no PDF library ships. Pure: the Node
// tests import it (tests/unit/lib/load-ts.mjs).

import { newestFirst } from '~/utils/feed.mjs'
import type { SpoolMessage } from '~/types/spool'

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

/** rows per page of a whole-topic read: the hub's own cap (viewLimitMax) */
export const TOPIC_EXPORT_PAGE = 200
/**
 * The most pages a whole-topic read takes (200 x 50 = 10 000 posts), so a
 * hub that keeps answering `next` never loops for ever. Past it the export
 * prints what it read, plus the rows the pane holds.
 */
export const TOPIC_EXPORT_PAGES_MAX = 50

type TopicPage<T> = { messages?: T[], next?: string | null }

/**
 * SPL-6205 (owner HUM-10, t1 f798e9aa msg 90afbbfd): every post of a topic,
 * read from the hub with the pane's own paging (order=desc, before=<next>)
 * until a page has no `next`, at most `max` pages. The pane holds only the
 * newest page and the opener until the reader presses Load more, so the
 * export reads the topic itself.
 *
 * @param page reads one page; `before` is the previous page's `next`
 * @param max the page cap
 */
export async function readWholeTopic<T>(page: (before?: string) => Promise<TopicPage<T>>, max = TOPIC_EXPORT_PAGES_MAX): Promise<T[]> {
  const out: T[] = []
  let before: string | undefined
  for (let i = 0; i < max; i++) {
    const data = await page(before)
    out.push(...(data?.messages || []))
    before = data?.next || undefined
    if (!before) break
  }
  return out
}

/**
 * The rows a whole-topic export prints: the rows the pane holds (its opener
 * rows, a pending send) and every row read from the hub, each id once (the
 * pane's copy wins, as on screen), minus the cards hidden on this device, in
 * the pane's order: newest first (feed.mjs newestFirst), or newest last when
 * the reader reads that way. Loop prompt rows never come: the hub's topic
 * read leaves them out (spec 183 Q4 W).
 *
 * @param held the rows the pane holds
 * @param read the rows readWholeTopic returned
 * @param o.newestLast the reader's order; o.isHidden a card hidden here
 */
export function topicPrintRows<T = Record<string, unknown>>(held: unknown, read: unknown, o: { newestLast?: boolean, isHidden?: (id: string) => boolean } = {}): T[] {
  const byId = new Map<string, T>()
  for (const m of [...(Array.isArray(held) ? held : []), ...(Array.isArray(read) ? read : [])]) {
    const id = m && typeof m === 'object' ? String((m as { msg_id?: unknown }).msg_id || '') : ''
    if (id && !byId.has(id) && !o.isHidden?.(id)) byId.set(id, m as T)
  }
  const rows = newestFirst([...byId.values()] as SpoolMessage[]) as T[]
  return o.newestLast ? rows.reverse() : rows
}

export type TopicExportRead = (taskId: string, o: { order: 'desc', limit: number, before?: string }) => Promise<TopicPage<unknown>>

/**
 * What the topic header's Export topic to PDF prints (SPL-6205): every page of
 * `taskId` read with `getTopic` (TOPIC_EXPORT_PAGE rows a page, at most
 * TOPIC_EXPORT_PAGES_MAX pages), merged with the rows the pane holds, in the
 * pane's order (topicPrintRows).
 */
export async function topicExportRows<T = Record<string, unknown>>(o: { taskId: string, held: unknown, getTopic: TopicExportRead, newestLast?: boolean, isHidden?: (id: string) => boolean }): Promise<T[]> {
  const id = String(o.taskId || '')
  const read = id ? await readWholeTopic((before) => o.getTopic(id, { order: 'desc', limit: TOPIC_EXPORT_PAGE, before })) : []
  return topicPrintRows<T>(o.held, read, { newestLast: o.newestLast, isHidden: o.isHidden })
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

/**
 * The print's picture map: each file's source, fetched by `load`, each fetch
 * bounded by `ms` (spec 005 FR-020 item 5). A fetch that fails, returns ''
 * or does not settle in time is left out, so that picture prints its name;
 * one hung download never holds the export.
 *
 * @param files the cards' file refs
 * @param load fetches one file's source ('' when it cannot be shown)
 * @param ms the bound per file
 */
export async function printImageSrcs<F>(files: F[], load: (f: F) => Promise<string>, ms: number): Promise<Record<string, string>> {
  const one = (f: F): Promise<string> => new Promise((resolve) => {
    const timer = setTimeout(() => resolve(''), ms)
    Promise.resolve().then(() => load(f)).then(
      (v) => { clearTimeout(timer); resolve(typeof v === 'string' ? v : '') },
      () => { clearTimeout(timer); resolve('') },
    )
  })
  const pairs = await Promise.all(files.map(async (f) => [printFileKey(f), await one(f)] as const))
  return Object.fromEntries(pairs.filter(([k, v]) => k && v))
}
