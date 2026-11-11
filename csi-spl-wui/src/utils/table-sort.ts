/**
 * Click-to-sort for a table in a post (md-tables panel plan v1.0 section
 * 3.2, SPL-2466 rows 04 + 05; owner HUM-10, t1 8f983920: "Make all of the
 * tables in the topics' msgs sortable"). Plain data only: the tree a table
 * node of markdown.mjs holds, never the DOM. components/MdTable.vue draws it.
 *
 * - sortModel: is this table sortable, and which rows move. A table sorts
 *   when it has a header row and at least 3 body rows (1-2 rows: a sort is a
 *   no-op or a flip), no colspan / rowspan (moving a row would tear the
 *   grid) and no no-sort hint.
 * - sortOrder: the row order for one column, a view only (Show source and
 *   the copied post keep the author's order). Each column is read as one
 *   kind: numbers with units, ISO dates, clock times, else text (Intl
 *   collation, numeric). Empty cells (-, —, N/A ...) stay last in both
 *   directions; equal keys keep the author's order.
 */

import type { MdNode } from '~/utils/markdown.mjs'

export type MdEl = Exclude<MdNode, string>
export type CellKey = { kind: 'num' | 'date' | 'clock', v: number }
/** What moves when a table sorts: its header row, the body rows, each row's cell texts. */
export type SortModel = { head: MdEl, rows: MdEl[], cells: string[][] }

/** A table sorts from this many body rows up. */
export const MIN_SORT_ROWS = 3
/* a column reads as numbers / dates / times when this share of its filled cells does */
const KIND_SHARE = 0.8

const EMPTY = new Set(['', '-', '--', '—', '–', 'n/a', 'na', 'none', 'null'])
const NUM = /^([~≈]\s*)?([€$£]\s*)?([+\-−]?)(\d{1,3}(?:[,  _ ]\d{3})+|\d+)?(\.\d+)?(?:e([+-]?\d+))?\s*([a-zµ%€$£/]{0,12})$/i
const SCALE: Record<string, number> = {
  b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4,
  ns: 1e-9, us: 1e-6, µs: 1e-6, ms: 1e-3, s: 1, sec: 1, min: 60, h: 3600,
}
const DATE = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)\s*(Z|UTC|[+-]\d{2}:?\d{2})?)?$/i
const CLOCK = /^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(?:Z|UTC)?$/i

const isEl = (n: MdNode | undefined): n is MdEl => Boolean(n) && typeof n !== 'string'
const els = (list: MdNode[], ...tags: string[]): MdEl[] => list.filter((n): n is MdEl => isEl(n) && tags.includes(n.tag))

/** The words a cell shows, spaces folded. */
export function cellText(n: MdNode | undefined): string {
  if (n == null) return ''
  if (typeof n === 'string') return n.replace(/\s+/g, ' ').trim()
  return n.children.map(cellText).filter(Boolean).join(' ').trim()
}

export function isEmptyCell(s: string): boolean {
  return EMPTY.has(String(s).trim().toLowerCase())
}

/**
 * A cell as a sort key: { kind: 'num' | 'date' | 'clock', v: number }, or
 * null for text. "-28 dBFS", "149.4 KB", "74%", "1,234", "€12", "2026-11-11",
 * "2026-11-11T08:59:30Z", "17:05Z". Sizes and durations scale to one unit
 * (1.2 MB > 900 KB, 1.5 s > 900 ms).
 */
export function parseCell(s: string): CellKey | null {
  const t = String(s).trim()
  const d = DATE.exec(t)
  if (d) {
    const zone = !d[3] || /utc/i.test(d[3]) ? 'Z' : d[3]
    const v = Date.parse(d[2] ? `${d[1]}T${d[2]}${zone}` : `${d[1]}T00:00:00Z`)
    return Number.isNaN(v) ? null : { kind: 'date', v }
  }
  const c = CLOCK.exec(t)
  if (c) return Number(c[1]) < 24 && Number(c[2]) < 60 ? { kind: 'clock', v: Number(c[1]) * 3600 + Number(c[2]) * 60 + Number(c[3] || 0) } : null
  const m = NUM.exec(t)
  if (!m || (m[4] === undefined && m[5] === undefined)) return null
  const v = Number(`${m[4] ? m[4].replace(/[,  _ ]/g, '') : '0'}${m[5] || ''}e${m[6] || 0}`)
  const sign = m[3] === '-' || m[3] === '−' ? -1 : 1
  return Number.isFinite(v) ? { kind: 'num', v: sign * v * (SCALE[m[7].toLowerCase()] ?? 1) } : null
}

/**
 * The kind a column sorts as: 'num' | 'date' | 'clock' when at least 80% of
 * its filled cells parse as that kind, else 'text'.
 */
export function columnKind(texts: string[]): string {
  const filled = texts.filter((s) => !isEmptyCell(s))
  const n: Record<string, number> = {}
  for (const s of filled) {
    const k = parseCell(s)?.kind
    if (k) n[k] = (n[k] || 0) + 1
  }
  const best = Object.keys(n).sort((a, b) => n[b] - n[a])[0]
  return best && n[best] / filled.length >= KIND_SHARE ? best : 'text'
}

function collator(locale?: string): Intl.Collator {
  try {
    return new Intl.Collator(locale || undefined, { numeric: true, sensitivity: 'base' })
  } catch {
    return new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })
  }
}

/**
 * The row order for a column: indices into texts. A filled cell of the
 * column's kind first, then a filled cell that is not (by text), then the
 * empty ones in the author's order; ties keep the author's order.
 */
export function sortOrder(texts: string[], dir: 'ascending' | 'descending', locale?: string): number[] {
  const kind = columnKind(texts)
  const coll = collator(locale)
  const sign = dir === 'descending' ? -1 : 1
  const keys = texts.map((s, i) => {
    if (isEmptyCell(s)) return { i, rank: 2, v: 0, s }
    const p = kind === 'text' ? null : parseCell(s)
    return p && p.kind === kind ? { i, rank: 0, v: p.v, s } : { i, rank: 1, v: 0, s }
  })
  keys.sort((a, b) => {
    if (a.rank !== b.rank) return a.rank - b.rank
    const by = a.rank === 2 ? 0 : a.rank === 0 ? a.v - b.v : coll.compare(a.s, b.s)
    return by ? sign * by : a.i - b.i
  })
  return keys.map((k) => k.i)
}

function hasSpan(n: MdNode): boolean {
  return isEl(n) && (Boolean(n.attrs.colspan || n.attrs.rowspan) || n.children.some(hasSpan))
}

/** The table's rows in the author's order, outside thead / tfoot. */
function bodyRows(table: MdEl): MdEl[] {
  return table.children.flatMap((n): MdEl[] => (!isEl(n) ? [] : n.tag === 'tr' ? [n] : n.tag === 'tbody' ? els(n.children, 'tr') : []))
}

/**
 * Whether a table sorts and what moves: its header row (the last thead row,
 * or else a first row of th only), the body rows in order, and each body
 * row's cell texts. null: the table stays as written.
 */
export function sortModel(table: MdNode): SortModel | null {
  if (!isEl(table) || table.tag !== 'table') return null
  if (/(^|\s)md-table--no-sort(\s|$)/.test(table.attrs.class || '')) return null
  if (els(table.children, 'tbody').length > 1 || hasSpan(table)) return null
  const thead = els(table.children, 'thead')[0]
  let rows = bodyRows(table)
  let head = thead ? els(thead.children, 'tr').at(-1) : undefined
  if (!head && rows[0] && els(rows[0].children, 'th', 'td').every((c) => c.tag === 'th')) {
    head = rows[0]
    rows = rows.slice(1)
  }
  if (!head || !els(head.children, 'th', 'td').length || rows.length < MIN_SORT_ROWS) return null
  return { head, rows, cells: rows.map((r) => els(r.children, 'th', 'td').map(cellText)) }
}
