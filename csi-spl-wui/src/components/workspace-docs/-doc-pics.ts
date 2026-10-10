/* Pictures inside a section's paragraph (owner HUM-10, t1 46d9c236, msgs
   8652b147 + 3c874763): the paragraph text carries each picture as a plain
   Markdown token, ![<what this pic is>](<img_http_path>), where the path is
   one of THIS document's images (the hub's POST /{doc}/images answer). Any
   other token stays text. The view renders the parsed runs as text nodes and
   <img> elements (never v-html of user text); every picture of the document,
   inline ones and the section image, is "Figure N" in one sequence in
   document order. The `-` prefix keeps Nuxt from registering this file as a
   component. */
import type { DocItem } from './-doctree-api'

export type PicRun = { kind: 'text', text: string } | { kind: 'pic', caption: string, path: string }

/* the token: a caption without ] or a line break, then a path of the hub's image route */
const TOKEN = /!\[([^\]\n]*)\]\((\/v1\/workspace\/doctree\/([^/\s()]+)\/images\/[0-9a-f]{64}\.(?:png|jpg|gif|webp))\)/g

/** the paragraph as text runs and this doc's pictures, in order */
export function picRuns(body: string, doc: string): PicRun[] {
  const out: PicRun[] = []
  let at = 0
  for (const m of body.matchAll(TOKEN)) {
    if (m[3] !== doc) continue
    if (m.index > at) out.push({ kind: 'text', text: body.slice(at, m.index) })
    out.push({ kind: 'pic', caption: m[1].trim(), path: m[2] })
    at = m.index + m[0].length
  }
  if (at < body.length) out.push({ kind: 'text', text: body.slice(at) })
  return out
}

/** the hub paths of a paragraph's pictures */
export function picPaths(body: string, doc: string): string[] {
  return picRuns(body, doc).flatMap((r) => (r.kind === 'pic' ? [r.path] : []))
}

/** a caption a token can carry: one line, no square brackets */
export function cleanCaption(caption: string): string {
  return caption.replace(/[[\]]/g, '').replace(/\s+/g, ' ').trim()
}

/** the token of one picture */
export function picToken(caption: string, path: string): string {
  return `![${cleanCaption(caption)}](${path})`
}

/** the paragraph with its k-th picture's caption replaced */
export function setPicCaption(body: string, doc: string, k: number, caption: string): string {
  let n = -1
  return body.replace(TOKEN, (all, _c: string, path: string, d: string) => {
    if (d !== doc) return all
    n += 1
    return n === k ? picToken(caption, path) : all
  })
}

/** the figure numbers: per item, the number of its first inline picture and of its section image (0 = none) */
export function figureNumbers(items: DocItem[], doc: string): Map<string, { first: number, image: number }> {
  const out = new Map<string, { first: number, image: number }>()
  let n = 0
  for (const it of items) {
    const first = n + 1
    n += picPaths(it.body, doc).length
    const image = typeof it.attrs?.img_http_path === 'string' && it.attrs.img_http_path ? ++n : 0
    out.set(it.id, { first, image })
  }
  return out
}
