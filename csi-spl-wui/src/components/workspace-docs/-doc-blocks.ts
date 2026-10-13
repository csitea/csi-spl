/* The paragraph toolbar's block inserts (spec 137 T010 / T011, owner HUM-10,
   t1 bed3ed0a msgs 2c82489a "tables in the paragraphs" and b1661d1c
   "citates"). The paragraph stays plain markdown (P-Q3 and P-Q4, choice A):
   Insert table puts a pipe-table skeleton at the cursor, Insert quote a
   blockquote with its attribution line. Either is its own block, a blank
   line before and after, so it never runs on into the text around it, and
   the first placeholder comes back selected to type over. Pure: the view
   (WorkspaceDocView) reads the textarea and writes the answer back. The `-`
   prefix keeps Nuxt from registering this file as a component. */

/** the text and the selection after an insert */
export type BlockInsert = { value: string, selStart: number, selEnd: number }

/** a block and the part of it to select, [from, to) offsets into it */
export type Block = { text: string, pick: [number, number] }

/** a pipe table: one header row, the rule, `rows` body rows; the first header is picked */
export function tableBlock(head: (n: number) => string, cell: (n: number) => string, cols = 3, rows = 1): Block {
  const line = (cells: string[]) => `| ${cells.join(' | ')} |`
  const n = Array.from({ length: cols }, (_, i) => i + 1)
  const out = [line(n.map(head)), `|${n.map(() => '---').join('|')}|`]
  for (let r = 0; r < rows; r++) out.push(line(n.map((c) => cell(r * cols + c))))
  return { text: out.join('\n'), pick: [2, 2 + head(1).length] }
}

/** a quotation and its source: "> passage", ">", "> — [source](https://)".
    Selected text is the passage (each of its lines quoted) and the source is
    picked; else the passage placeholder is. */
export function quoteBlock(selected: string, passage: string, source: string): Block {
  const said = selected.replace(/\r\n?/g, '\n').replace(/^\n+|\n+$/g, '')
  const lines = (said || passage).split('\n').map((l) => (l ? `> ${l}` : '>'))
  const body = lines.join('\n')
  const cite = `> — [${source}](https://)`
  const text = `${body}\n>\n${cite}`
  if (!said) return { text, pick: [2, 2 + passage.length] }
  const at = body.length + 3 + cite.indexOf('[') + 1
  return { text, pick: [at, at + source.length] }
}

/** `block` in place of value[start, end), on lines of its own: a blank line before and after */
export function insertBlock(value: string, start: number, end: number, make: (selected: string) => Block): BlockInsert {
  const lo = Math.max(0, Math.min(start, end, value.length))
  const hi = Math.min(value.length, Math.max(start, end))
  const { text, pick } = make(value.slice(lo, hi))
  const pre = value.slice(0, lo).replace(/[ \t]*\n*$/, '')
  const post = value.slice(hi).replace(/^[ \t]*\n*/, '')
  const before = pre ? pre + '\n\n' : ''
  const after = post ? '\n\n' + post : ''
  return { value: before + text + after, selStart: before.length + pick[0], selEnd: before.length + pick[1] }
}
