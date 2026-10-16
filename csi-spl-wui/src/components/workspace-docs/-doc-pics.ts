/* Pictures inside a section's paragraph (owner HUM-10, t1 46d9c236, msgs
   8652b147 + 3c874763): the paragraph text carries each picture as a plain
   Markdown token, ![<what this pic is>](<img_http_path>), where the path is
   one of THIS document's images (the hub's POST /{doc}/images answer). Any
   other token stays text. The view renders the parsed runs as text nodes and
   <img> elements (never v-html of user text); every picture of the document,
   inline ones and the section image, is "Figure N" in one sequence in
   document order. A picture an md page brought in keeps its link as the page
   wrote it, ![..](<page>.assets/NN-name.ext) (gap G6, SPL-2201, spec 137
   unified-fs.md section 7): the read view shows it (kind 'asset', read from
   the doc's asset route), but it is no numbered figure, so every export
   writes it back as written and the md round trip stays byte-stable. The
   `-` prefix keeps Nuxt from registering this file as a component. */
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

export type ParaRun = { kind: 'text', text: string } | { kind: 'pic', caption: string, path: string, k: number, n: number }
  | { kind: 'asset', caption: string, path: string }

/* a picture of the doc's own asset folder as the md page wrote it (the hub's store.DocAssetPath) */
const ASSET = /!\[([^\]\n]*)\]\(([A-Za-z0-9][A-Za-z0-9._-]{0,199}\.assets\/[0-9]{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.(?:png|jpg|jpeg|gif|webp))\)/g

/** a text run split around its asset pictures: the breaks around a picture are not text */
function assetRuns(text: string): ParaRun[] {
  const out: ParaRun[] = []
  let at = 0
  for (const m of text.matchAll(ASSET)) {
    const before = text.slice(at, m.index).replace(/\n$/, '')
    if (before) out.push({ kind: 'text', text: before })
    out.push({ kind: 'asset', caption: m[1].trim(), path: m[2] })
    at = m.index + m[0].length
    if (text[at] === '\n') at += 1
  }
  if (at < text.length) out.push({ kind: 'text', text: text.slice(at) })
  return out
}

/** the asset pictures of a paragraph, each path as written */
export function assetPaths(body: string): string[] {
  return [...body.matchAll(ASSET)].map((m) => m[2])
}

/** the hub route an asset picture is read from: the doc's /assets/<path as written> */
export function assetRoute(doc: string, path: string): string {
  return `/v1/workspace/doctree/${encodeURIComponent(doc)}/assets/${path}`
}

/** the hub routes of a paragraph's pictures to read: this doc's figures, then its asset pictures */
export function imagePaths(body: string, doc: string): string[] {
  return [...picPaths(body, doc), ...assetPaths(body).map((a) => assetRoute(doc, a))]
}

/** a section body as the read view shows it (owner HUM-10, t1 09a69b01: the
    text renders as markdown, a click edits the raw text): its text runs and
    this doc's figures (k = the picture's index, n = its figure number counted
    from first). null = a blank body, which stays its textarea (the placeholder,
    a level-1 section's closed paragraph). */
export function paraRuns(body: string, doc: string, first = 1): ParaRun[] | null {
  if (!body.trim()) return null
  const runs = picRuns(body, doc)
  let k = 0
  return runs.flatMap((r, i): ParaRun[] => {
    if (r.kind === 'pic') return [{ ...r, k, n: first + k++ }]
    /* a figure is its own block: the line breaks around it are not text */
    let text = r.text
    if (i > 0) text = text.replace(/^\n/, '')
    if (i < runs.length - 1) text = text.replace(/\n$/, '')
    return text ? assetRuns(text) : []
  })
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
