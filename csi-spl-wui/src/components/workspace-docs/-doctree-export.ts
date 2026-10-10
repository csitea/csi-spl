/* Qto's "export to md" / "export to xls" for one branch of a workspace
   document (spec 113 T006, the Qto view-doc port): built in the browser
   from the items the doc view already holds, then saved as a file. The
   spreadsheet is CSV (Excel and every sheet app open it); the `-` prefix
   keeps Nuxt from registering this file as a component. */
import type { DocItem } from './-doctree-api'
import { picRuns, picToken } from './-doc-pics'

/** the figures to keep: the doc whose picture tokens count, the figure numbers and their label */
export type MdFigures = { doc: string, figs: Map<string, { first: number, image: number }>, figure: (n: number) => string }

/** the paragraph with each picture's token followed by its "Figure N: caption" line */
function bodyWithFigures(it: DocItem, f: MdFigures): string {
  let n = f.figs.get(it.id)?.first ?? 1
  return picRuns(it.body, f.doc).map((r) => (r.kind === 'text' ? r.text : `${picToken(r.caption, r.path)}\n\n*${f.figure(n++)} ${r.caption}*\n`)).join('')
}

/** the branch as Markdown: one heading per item (# by level), its text, its code, its image */
export function branchToMarkdown(items: DocItem[], untitled: string, f?: MdFigures): string {
  const base = Math.min(...items.map((it) => it.depth))
  const out: string[] = []
  for (const it of items) {
    const level = Math.min(6, it.depth - base + 1)
    out.push(`${'#'.repeat(level)} ${it.outline} ${it.title || untitled}`, '')
    const body = f ? bodyWithFigures(it, f) : it.body
    if (body.trim()) out.push(body.trim(), '')
    const src = typeof it.attrs?.src === 'string' ? it.attrs.src : ''
    if (src) out.push('```', src, '```', '')
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
