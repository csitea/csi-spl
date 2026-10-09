// Spec 111 T002 (4.1, 4.2, 6.2): the blog's build-time copy. A twin of
// src/node/help/sync-help.mjs, run INSIDE `pnpm run generate`, so the copy is
// made by the build that ships and is never committed (src/public/blog-md/ is
// git-ignored). It reads csi-spl-doc/blog/posts/<lang>/<id>.md and writes
//
//   src/public/blog-md/index.json         per locale, newest first: the list
//   src/public/blog-md/<lang>/<id>.html   one escaped fragment per post copy
//
// - The frontmatter of every copy is validated; a bad copy fails the sync.
// - `draft: true` is skipped.
// - THE CAP (6.2) holds here, in code the posting agent does not run: per
//   publish day (env.blog.tz) at most env.blog.cap_per_day posts render, the
//   digest first; other posts take at most cap - digest_reserved. A
//   non-digest post tagged with one of env.blog.cap_exempt_tags (owner
//   HUM-10 d940f865: the feature series) is neither counted nor held. A post
//   counts once, by its `en` file. The day and the order come from GIT, never
//   from the frontmatter: the first-parent commit that made the `en` file
//   live (added, or flipped from `draft: true`), committer time. So a
//   back-dated `published`, a draft flipped later and an edit that changes
//   `id` (a new file) each count on their commit day. A digest only takes
//   the reserved slot when that commit falls in the digest hour. A post past
//   the cap stays in git, unrendered, and is named in the log.
// - Fragments come ONLY from markdownToHtml (src/utils/markdown.mjs: escaped,
//   allow-listed, http(s) links, no images); there is no second sanitiser.
//   On top of it, every copy whose body or fragment holds `<script`, an
//   `on*=` attribute or a `javascript:` / `data:` URL is refused - after
//   entity decoding, so even escaped text counts (fail closed).
//
// Usage (in csi-spl-wui):
//   node src/node/blog/sync-blog.mjs          # write the copy (pnpm run generate)
//   node src/node/blog/sync-blog.mjs --check  # exit 1 when refused or stale
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isKnownTimeZone } from '../../utils/date-iso.mjs'
import { isoDateTimeIn } from '../../utils/date-iso-zone.mjs'
import { markdownToHtml } from '../../utils/markdown.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const REPO = join(WUI, '..')
/* BLOG_POSTS_DIR / BLOG_GIT_ROOT / BLOG_OUT_DIR: for tests/unit/blog-sync.test.mjs */
export const BLOG_REPO = process.env.BLOG_GIT_ROOT || REPO
export const BLOG_SRC = process.env.BLOG_POSTS_DIR || join(REPO, 'csi-spl-doc/blog/posts')
export const BLOG_OUT = process.env.BLOG_OUT_DIR || join(WUI, 'src/public/blog-md')
export const BLOG_CNF = join(REPO, 'csi-spl-cnf/csi-spl/all.env.yaml')
export const BLOG_LOCALES = join(WUI, 'i18n/locales')

/** The spec's values (D-Q1, 6.2), used for a key env.blog does not carry. */
export const BLOG_DEFAULTS = Object.freeze({ tz: 'Europe/Helsinki', cap_per_day: 7, digest_reserved: 1, digest_at: '23:00', cap_exempt_tags: Object.freeze([]) })

/** env.blog from the cnf, each missing key at its BLOG_DEFAULTS value. */
export function blogCnf(cnf = BLOG_CNF) {
  const out = { ...BLOG_DEFAULTS }
  let text = ''
  try { text = readFileSync(cnf, 'utf8') } catch { return out }
  const m = /^( +)blog:[ \t]*\n((?:\1 +.*\n?|[ \t]*\n)*)/m.exec(text)
  if (!m) return out
  for (const line of m[2].split('\n')) {
    const ex = /^\s+cap_exempt_tags:\s*\[([^\]]*)\]\s*(#.*)?$/.exec(line)
    if (ex) { out.cap_exempt_tags = ex[1].split(',').map((t) => t.trim().replace(/^["']|["']$/g, '')).filter(Boolean); continue }
    const kv = /^\s+(tz|cap_per_day|digest_reserved|digest_at):\s*["']?([^"'#\s]+)["']?\s*(#.*)?$/.exec(line)
    if (!kv) continue
    out[kv[1]] = /^(cap_per_day|digest_reserved)$/.test(kv[1]) ? Number.parseInt(kv[2], 10) : kv[2]
  }
  return out
}

/** The supported locale codes: one per i18n/locales/<code>.json (locales_from: i18n). */
export function blogLocales(dir = BLOG_LOCALES) {
  return readdirSync(dir).filter((n) => /^[a-z]{2,3}\.json$/.test(n)).map((n) => n.slice(0, -5)).sort()
}

const KEYS = new Set(['id', 'lang', 'type', 'title', 'summary', 'date', 'published', 'author', 'agy_review',
  'tags', 'image', 'image_alt', 'image_prompt', 'draft', 'event_start', 'event_end'])
const REQUIRED = ['id', 'lang', 'type', 'title', 'summary', 'date', 'author']
const TYPES = new Set(['digest', 'news', 'event'])
const ID_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$/
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z$/
const AGENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

function scalar(raw) {
  const s = raw.trim()
  if (s.startsWith('"')) {
    const m = /^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$/.exec(s)
    if (!m) throw new Error('unterminated "string"')
    return m[1].replace(/\\(.)/g, (_, c) => ({ n: '\n', t: '\t' })[c] ?? c)
  }
  if (s.startsWith("'")) {
    const m = /^'((?:[^']|'')*)'\s*(?:#.*)?$/.exec(s)
    if (!m) throw new Error("unterminated 'string'")
    return m[1].replace(/''/g, "'")
  }
  const v = s.replace(/\s+#.*$/, '')
  if (v === 'true') return true
  if (v === 'false') return false
  return v
}

/**
 * `---` frontmatter + body. The frontmatter is flat `key: value` lines; a
 * value is a scalar, a quoted string or a `[a, b]` list. Throws on anything
 * else, so a typo (`draf: true`) never turns into a silently ignored key.
 */
export function parseFrontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)([\s\S]*)$/.exec(String(text))
  if (!m) throw new Error('no --- frontmatter --- block')
  const meta = {}
  for (const line of m[1].split(/\r?\n/)) {
    if (!line.trim() || /^\s*#/.test(line)) continue
    const kv = /^([a-z_]+):(?:\s+(.*))?$/.exec(line)
    if (!kv) throw new Error(`not a "key: value" line: ${JSON.stringify(line.slice(0, 60))}`)
    const [, key, raw = ''] = kv
    if (!KEYS.has(key)) throw new Error(`unknown key ${key}`)
    if (key in meta) throw new Error(`duplicate key ${key}`)
    const list = /^\[(.*)\]\s*(?:#.*)?$/.exec(raw.trim())
    meta[key] = list ? (list[1].trim() ? list[1].split(',').map((x) => String(scalar(x))) : []) : scalar(raw)
  }
  return { meta, body: m[2] }
}

/** Every problem with one copy's frontmatter ([] = valid). */
export function validateMeta(meta, { id, lang, locales }) {
  const bad = []
  for (const k of REQUIRED) if (meta[k] === undefined || meta[k] === '') bad.push(`missing ${k}`)
  for (const k of KEYS) {
    if (k !== 'tags' && k !== 'draft' && meta[k] !== undefined && typeof meta[k] !== 'string') bad.push(`${k} is not a string`)
  }
  if (meta.id !== undefined && meta.id !== id) bad.push(`id ${meta.id} is not the file name ${id}`)
  if (!ID_RE.test(id)) bad.push(`file name ${id} is not <yyyy-mm-dd>-<slug>`)
  if (meta.lang !== undefined && meta.lang !== lang) bad.push(`lang ${meta.lang} is not the dir ${lang}`)
  if (!locales.includes(lang)) bad.push(`dir ${lang} is not a supported locale`)
  if (meta.type !== undefined && !TYPES.has(meta.type)) bad.push(`unknown type ${meta.type}`)
  if (typeof meta.date === 'string' && !(DATE_RE.test(meta.date) && !Number.isNaN(Date.parse(meta.date)))) bad.push(`date ${meta.date} is not yyyy-mm-dd`)
  if (typeof meta.summary === 'string' && meta.summary.length > 160) bad.push('summary over 160 chars')
  if (typeof meta.author === 'string' && !AGENT_RE.test(meta.author)) bad.push(`author ${meta.author} is not an id`)
  if (meta.draft !== undefined && typeof meta.draft !== 'boolean') bad.push('draft is not true/false')
  if (meta.tags !== undefined && !(Array.isArray(meta.tags) && meta.tags.every((t) => /^[a-z0-9-]+$/.test(t)))) bad.push('tags is not a [a, b] list of lowercase words')
  if (meta.image !== undefined) {
    if (!new RegExp(`^${id}(-og)?\\.webp$`).test(String(meta.image))) bad.push(`image ${meta.image} is not ${id}.webp`)
    if (!meta.image_alt) bad.push('image without image_alt')
  }
  for (const k of ['published', 'event_start', 'event_end']) {
    if (typeof meta[k] === 'string' && !ISO_RE.test(meta[k])) bad.push(`${k} is not ISO 8601 UTC (Z)`)
  }
  if (meta.type === 'event' && !meta.event_start) bad.push('event without event_start')
  return bad
}

const ENT = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', colon: ':', tab: '\t', newline: '\n' }
function decode(s) {
  let prev
  let out = String(s)
  for (let i = 0; i < 4 && out !== prev; i++) {
    prev = out
    out = out.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);?/gi, (all, e) => {
      if (e[0] !== '#') return ENT[e.toLowerCase()] ?? all
      const n = e[1] === 'x' || e[1] === 'X' ? Number.parseInt(e.slice(2), 16) : Number.parseInt(e.slice(1), 10)
      return n > 0 && n < 0x110000 ? String.fromCodePoint(n) : ''
    })
  }
  return out
}

const HOSTILE = [
  [/<\s*script/i, '<script'],
  [/\bon[a-z]+\s*=/i, 'an on*= attribute'],
  [/\b(?:javascript|vbscript)\s*:/i, 'a javascript: URL'],
  [/\bdata\s*:(?!\s)/i, 'a data: URL'],
]

/** What makes `text` unshippable ('' = nothing), after entity decoding. */
export function hostile(text) {
  const s = decode(text).replace(/[\u0000-\u0008\u000b-\u001f]/g, '')
  for (const [re, why] of HOSTILE) if (re.test(s)) return why
  return ''
}

const live = (meta) => meta.draft !== true

/** Is a committed file text live (not `draft: true`)? Unreadable counts as live. */
function textLive(text) {
  try { return live(parseFrontmatter(text).meta) } catch { return true }
}

function git(root, args, input) {
  const r = spawnSync('git', ['-C', root, ...args], { input, maxBuffer: 1 << 30 })
  return r.status === 0 ? r.stdout : null
}

/**
 * When each `en` post went live, from git: id -> { at (epoch s), seq }.
 * The first-parent commit of HEAD that made `en/<id>.md` live (added live,
 * or flipped from draft); seq orders commits (oldest = 0). A live file that
 * git has not seen live yet (an uncommitted edit) goes live at `now`. A
 * shallow clone counts every older post on its boundary day: stricter,
 * never looser.
 * @param {Array<[string, string]>} ids [id, the working-tree text]
 */
export function publishTimes(root, enDir, ids, now = Date.now()) {
  const rel = relative(root, enDir) || '.'
  const log = git(root, ['log', '--first-parent', '-m', '--no-renames', '--format=C %H %ct', '--name-status', '--', rel])
  const events = new Map() // id -> [{ sha, ct, seq, status, path, live }], oldest first
  if (log) {
    const lines = log.toString('utf8').split('\n')
    const shas = lines.filter((l) => l.startsWith('C ')).map((l) => l.split(' ')[1])
    let sha = ''
    let ct = 0
    let seq = 0
    for (const l of lines) {
      if (l.startsWith('C ')) {
        const p = l.split(' ')
        sha = p[1]
        ct = Number(p[2])
        seq = shas.length - 1 - shas.indexOf(sha)
        continue
      }
      const f = /^([AMD])\t(.+)$/.exec(l)
      if (!f || !f[2].startsWith(rel + '/')) continue
      const name = f[2].slice(rel.length + 1)
      if (!/^[^/]+\.md$/.test(name)) continue
      const id = name.slice(0, -3)
      if (!events.has(id)) events.set(id, [])
      events.get(id).unshift({ sha, ct, seq, status: f[1], path: f[2], live: false })
    }
    /* one cat-file for every committed version of every post */
    const want = [...events.values()].flat().filter((e) => e.status !== 'D')
    const batch = want.length ? git(root, ['cat-file', '--batch'], want.map((e) => `${e.sha}:${e.path}\n`).join('')) : null
    let at = 0
    for (const e of want) {
      if (!batch) { e.live = true; continue }
      const nl = batch.indexOf(10, at)
      const head = batch.subarray(at, nl).toString('utf8').split(' ')
      if (head[1] !== 'blob') { at = nl + 1; continue }
      const size = Number(head[2])
      e.live = textLive(batch.subarray(nl + 1, nl + 1 + size).toString('utf8'))
      at = nl + 1 + size + 1
    }
  }
  const out = new Map()
  for (const [id, text] of ids) {
    let prev = false
    let pub = null
    for (const e of events.get(id) || []) {
      if (e.live && !prev) pub = { at: e.ct, seq: e.seq }
      prev = e.live
    }
    if (textLive(text) && !prev) pub = { at: Math.floor(now / 1000), seq: Number.MAX_SAFE_INTEGER }
    if (pub) out.set(id, pub)
  }
  return out
}

/* the day and hour of an instant in the blog zone (date-iso-zone: the one zone-explicit formatter) */
function zoned(epochS, tz) {
  const s = isoDateTimeIn(epochS * 1000, tz)
  return { day: s.slice(0, 10), hour: Number(s.slice(11, 13)) }
}

/**
 * The cap (6.2). posts: [{ id, type, at, seq, tags }], the live `en` posts.
 * A non-digest post with a tag in cnf.cap_exempt_tags always renders and
 * takes no slot.
 * Returns { keep: Set<id>, dropped: [{ id, day, why }] }.
 */
export function applyCap(posts, cnf = BLOG_DEFAULTS) {
  /* an unknown zone would silently become the box's: refuse it */
  if (!isKnownTimeZone(cnf.tz)) throw new Error(`env.blog.tz ${cnf.tz} is not an IANA zone`)
  const digestHour = Number.parseInt(String(cnf.digest_at).split(':')[0], 10)
  const reserved = Math.max(0, cnf.digest_reserved)
  const others = Math.max(0, cnf.cap_per_day - reserved)
  const exempt = new Set(cnf.cap_exempt_tags || [])
  const days = new Map()
  for (const p of posts) {
    const z = zoned(p.at, cnf.tz)
    if (!days.has(z.day)) days.set(z.day, [])
    days.get(z.day).push({ ...p, hour: z.hour })
  }
  const keep = new Set()
  const dropped = []
  for (const [day, list] of days) {
    list.sort((a, b) => a.at - b.at || a.seq - b.seq || a.id.localeCompare(b.id))
    let digests = 0
    let rest = 0
    for (const p of list) {
      if (p.type === 'digest') {
        if (p.hour !== digestHour) dropped.push({ id: p.id, day, why: `a digest outside ${cnf.digest_at}-24:00 ${cnf.tz}` })
        else if (digests >= reserved) dropped.push({ id: p.id, day, why: 'a second digest for the day' })
        else { digests++; keep.add(p.id) }
      } else if ((p.tags || []).some((t) => exempt.has(t))) {
        keep.add(p.id)
      } else if (rest >= others) {
        dropped.push({ id: p.id, day, why: `over the cap of ${cnf.cap_per_day} a day (${others} besides the digest)` })
      } else { rest++; keep.add(p.id) }
    }
  }
  return { keep, dropped }
}

const ENTRY_KEYS = ['id', 'type', 'title', 'summary', 'date', 'published', 'author', 'tags', 'image', 'image_alt', 'event_start', 'event_end']

/**
 * Every file the copy must hold (name -> content), what is refused
 * (`errors`: the sync fails) and what the cap leaves out (`dropped`: logged).
 */
export function blogFiles({ src = BLOG_SRC, root = BLOG_REPO, cnf = blogCnf(), locales = blogLocales(), now = Date.now() } = {}) {
  const files = new Map()
  const errors = []
  const copies = new Map() // lang -> Map(id -> { meta, body, file, text })
  const langs = existsSync(src) ? readdirSync(src, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort() : []
  for (const lang of langs) {
    const m = new Map()
    for (const n of readdirSync(join(src, lang)).filter((x) => x.endsWith('.md')).sort()) {
      const file = `${lang}/${n}`
      const id = n.slice(0, -3)
      const text = readFileSync(join(src, lang, n), 'utf8')
      let parsed
      try { parsed = parseFrontmatter(text) } catch (e) { errors.push(`${file}: ${e.message}`); continue }
      if (!live(parsed.meta)) continue
      const bad = validateMeta(parsed.meta, { id, lang, locales })
      if (bad.length) { errors.push(`${file}: ${bad.join('; ')}`); continue }
      m.set(id, { ...parsed, file, text })
    }
    copies.set(lang, m)
  }
  const en = copies.get('en') || new Map()
  for (const lang of langs) for (const id of copies.get(lang).keys()) {
    if (!en.has(id)) errors.push(`${lang}/${id}.md: no live en/${id}.md it translates`)
  }
  const times = publishTimes(root, join(src, 'en'), [...en].map(([id, c]) => [id, c.text]), now)
  const posts = [...en].filter(([id]) => times.has(id)).map(([id, c]) => ({ id, type: c.meta.type, tags: c.meta.tags, ...times.get(id) }))
  const { keep, dropped } = applyCap(posts, cnf)
  const order = posts.filter((p) => keep.has(p.id))
    .sort((a, b) => b.at - a.at || b.seq - a.seq || b.id.localeCompare(a.id)).map((p) => p.id)
  const index = {}
  for (const lang of langs) {
    const list = []
    for (const id of order) {
      const c = copies.get(lang).get(id)
      if (!c) continue
      const html = markdownToHtml(c.body)
      const entry = Object.fromEntries(ENTRY_KEYS.filter((k) => c.meta[k] !== undefined).map((k) => [k, c.meta[k]]))
      const why = hostile(c.body) || hostile(html) || hostile(Object.values(entry).flat().join('\n'))
      if (why) { errors.push(`${c.file}: refused, it holds ${why}`); continue }
      files.set(`${lang}/${id}.html`, html + '\n')
      list.push(entry)
    }
    if (list.length) index[lang] = list
  }
  files.set('index.json', JSON.stringify({ locales: index }, null, 2) + '\n')
  return { files, errors, dropped }
}

function listOut(dir, pre = '') {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true })
    .flatMap((d) => d.isDirectory() ? listOut(join(dir, d.name), `${pre}${d.name}/`) : [`${pre}${d.name}`])
}

/** The names whose copy is missing, stale or extra. */
export function blogDrift(want, dst = BLOG_OUT) {
  const bad = []
  for (const [n, body] of want) {
    const p = join(dst, n)
    if (!existsSync(p) || readFileSync(p, 'utf8') !== body) bad.push(n)
  }
  for (const n of listOut(dst)) if (!want.has(n)) bad.push(n)
  return bad
}

/** Write the copy: dst then holds exactly `want`. */
export function writeBlog(want, dst = BLOG_OUT) {
  rmSync(dst, { recursive: true, force: true })
  for (const [n, body] of want) {
    mkdirSync(dirname(join(dst, n)), { recursive: true })
    writeFileSync(join(dst, n), body)
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const shallow = git(BLOG_REPO, ['rev-parse', '--is-shallow-repository'])
  if (shallow && shallow.toString().trim() === 'true') console.warn('blog: shallow clone - every older post counts on the boundary day (a stricter cap)')
  const { files, errors, dropped } = blogFiles()
  for (const d of dropped) console.warn(`blog cap: ${d.id} not rendered (${d.day}: ${d.why})`)
  if (errors.length) {
    for (const e of errors) console.error(`blog: ${e}`)
    process.exit(1)
  }
  if (process.argv.includes('--check')) {
    const bad = blogDrift(files)
    if (bad.length) {
      console.error(`blog copy is stale (${bad.join(', ')}): run node src/node/blog/sync-blog.mjs in csi-spl-wui`)
      process.exit(1)
    }
    console.log('blog copy matches csi-spl-doc/blog/posts')
  } else {
    writeBlog(files)
    console.log(`wrote ${files.size} files to src/public/blog-md`)
  }
}
