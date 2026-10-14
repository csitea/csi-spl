/* Qto's "export to md" / "export to xls" for one branch of a workspace
   document (spec 113 T006, the Qto view-doc port): built in the browser
   from the items the doc view already holds, then saved as a file. The
   spreadsheet is CSV (Excel and every sheet app open it); the `-` prefix
   keeps Nuxt from registering this file as a component. */
import type { DocItem } from './-doctree-api'
import { picRuns, picToken } from './-doc-pics'
import { headingText } from './-doc-outline'

/** the figures to keep: the doc whose picture tokens count, the figure numbers and their label */
export type MdFigures = { doc: string, figs: Map<string, { first: number, image: number }>, figure: (n: number) => string }

/** the paragraph with each picture's token followed by its "Figure N: caption" line */
function bodyWithFigures(it: DocItem, f: MdFigures): string {
  let n = f.figs.get(it.id)?.first ?? 1
  return picRuns(it.body, f.doc).map((r) => (r.kind === 'text' ? r.text : `${picToken(r.caption, r.path)}\n\n*${f.figure(n++)} ${r.caption}*\n`)).join('')
}

/** a body's lines under its heading's blank line, kept as stored (SPL-1900): one trailing newline ends
    the last line, every other blank line and the first line's indent are the author's; a body with text
    closes with a blank line (none when tightEnd, attrs.tight_end), a blank body is its blank lines alone
    (cmd/spool docTreeBodyLines) */
export function bodyLines(body: string, tightEnd = false): string[] {
  if (!body) return []
  const lines = (body.endsWith('\n') ? body.slice(0, -1) : body).split('\n')
  return body.trim() && !tightEnd ? [...lines, ''] : lines
}

/** the branch as Markdown: the preamble first when given (the hidden root's body, the text before section 1:
    a whole-document export, SPL-1612), then one heading per item (# by level, no number when unnumbered,
    "1." when attrs.outline_dot), a blank line (none when attrs.tight), its text as stored, its code
    (fenced with its lang), its image */
export function branchToMarkdown(items: DocItem[], untitled: string, f?: MdFigures, preamble?: DocItem): string {
  const out: string[] = []
  const pre = preamble ? (f ? bodyWithFigures(preamble, f) : preamble.body).trim() : ''
  if (pre) out.push(pre, '')
  if (!items.length) return out.join('\n')
  const base = Math.min(...items.map((it) => it.depth))
  for (const it of items) {
    const level = Math.min(6, it.depth - base + 1)
    out.push(`${'#'.repeat(level)} ${headingText(it.outline, it.title || untitled, it.attrs?.outline_dot === true)}`)
    if (it.attrs?.tight !== true) out.push('')
    out.push(...bodyLines(f ? bodyWithFigures(it, f) : it.body, it.attrs?.tight_end === true))
    const src = typeof it.attrs?.src === 'string' ? it.attrs.src : ''
    const lang = typeof it.attrs?.lang === 'string' ? it.attrs.lang.trim() : ''
    if (src) out.push('```' + lang, src, '```', '')
    const img = typeof it.attrs?.img_http_path === 'string' ? it.attrs.img_http_path : ''
    const n = f?.figs.get(it.id)?.image
    if (img && f && n) {
      const name = typeof it.attrs?.img_name === 'string' ? it.attrs.img_name : ''
      out.push(picToken(name, img), '', `*${f.figure(n)} ${name}*`, '')
    }
  }
  return out.join('\n')
}

const cell = (v: string) => (/[",\n\r]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v)

/** the branch as CSV: number, level, title, text */
export function branchToCsv(items: DocItem[], cols: [string, string, string, string]): string {
  const rows = [cols.map(cell).join(',')]
  for (const it of items) rows.push([it.outline, String(it.depth), it.title, it.body].map(cell).join(','))
  return '﻿' + rows.join('\r\n') + '\r\n'
}

/** a file name from the document title and the branch number */
export function exportName(title: string, outline: string, ext: string): string {
  const stem = `${title}-${outline}`.replace(/[^\p{L}\p{N}._-]+/gu, '-').replace(/-+/g, '-').replace(/^-|-$/g, '')
  return `${stem || 'document'}.${ext}`
}

export function saveText(name: string, text: string, type: string) {
  const url = URL.createObjectURL(new Blob([text], { type }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
