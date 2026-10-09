// Owner HUM-10 (t1 41881574, msg e3ce4c34): a signed-out visitor reads the
// docs marked public. The build-time copy of those docs, a twin of the blog's
// (src/node/blog/sync-blog.mjs), run INSIDE `pnpm run generate`, so it is
// made by the build that ships and never committed (src/public/docs-public/
// is git-ignored). Signed out, the /docs page reads only this copy; no hub
// call runs, and a doc that is not in it goes to /login.
//
//   src/public/docs-public/index.json      { files: [{ path, title }] }
//   src/public/docs-public/<repo path>     the doc, its frontmatter taken out
//
// - A doc is public ONLY when its leading frontmatter says `public: true`;
//   the default is not public. No frontmatter, `public: false` or any other
//   value: not copied.
// - The candidates are the docs do_publish_docs publishes (spl_docs_stage):
//   tracked *.md, minus the agent-instruction files, node_modules/, tpl-gen/,
//   bin/ and the WUI's help copy, each a path the hub would serve.
// - No git (a bare copy of csi-spl-wui): no public docs, never all of them.
//
// Usage (in csi-spl-wui):
//   node src/node/docs/sync-public-docs.mjs          # write the copy
//   node src/node/docs/sync-public-docs.mjs --check  # exit 1 when stale
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { validDocsPath } from '../../utils/docs.mjs'
import { docsBody } from '../../utils/public-docs.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
/* PUBLIC_DOCS_ROOT / PUBLIC_DOCS_OUT_DIR: for tests/unit/public-docs-sync.test.mjs */
export const PUBLIC_DOCS_ROOT = process.env.PUBLIC_DOCS_ROOT || join(WUI, '..')
export const PUBLIC_DOCS_OUT = process.env.PUBLIC_DOCS_OUT_DIR || join(WUI, 'src/public/docs-public')

/** Is this path one do_publish_docs skips (spl_docs_stage)? */
export function skippedPath(p) {
  const s = '/' + p
  return /\/(CLAUDE|GEMINI|AGENTS)\.md$/.test(s) ||
    /\/(node_modules|bin)\//.test(s) || s.startsWith('/tpl-gen/') ||
    s.startsWith('/csi-spl-wui/src/public/help-md/')
}

/** Does the doc's leading frontmatter say `public: true`? */
export function markedPublic(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(String(text))
  return Boolean(m && /^public:[ \t]*true[ \t]*(?:#.*)?$/m.test(m[1]))
}

/** The doc title: the first "# " heading, else the file name. */
export function docTitle(md, path) {
  return (/^#\s+(.+?)\s*$/m.exec(md) || [])[1] || path.split('/').pop()
}

/** The tracked *.md of the repo ([] without git). */
function trackedDocs(root) {
  const r = spawnSync('git', ['-C', root, 'ls-files', '-z', '--', '*.md'], { maxBuffer: 1 << 26 })
  if (r.status !== 0) return []
  return r.stdout.toString('utf8').split('\0').filter(Boolean).sort()
}

/** Every file the copy must hold: name -> content. */
export function publicDocsFiles(root = PUBLIC_DOCS_ROOT, paths = trackedDocs(root)) {
  const out = new Map()
  const files = []
  for (const p of paths) {
    if (skippedPath(p) || !validDocsPath(p)) continue
    let text
    try { text = readFileSync(join(root, p), 'utf8') } catch { continue }
    if (!markedPublic(text)) continue
    const md = docsBody(text)
    out.set(p, md)
    files.push({ path: p, title: docTitle(md, p) })
  }
  out.set('index.json', JSON.stringify({ files }, null, 2) + '\n')
  return out
}

function listOut(dir, pre = '') {
  if (!existsSync(dir)) return []
  return readdirSync(dir, { withFileTypes: true })
    .flatMap((d) => d.isDirectory() ? listOut(join(dir, d.name), `${pre}${d.name}/`) : [`${pre}${d.name}`])
}

/** The names whose copy is missing, stale or extra. */
export function publicDocsDrift(want, dst = PUBLIC_DOCS_OUT) {
  const bad = []
  for (const [n, body] of want) {
    const p = join(dst, n)
    if (!existsSync(p) || readFileSync(p, 'utf8') !== body) bad.push(n)
  }
  for (const n of listOut(dst)) if (!want.has(n)) bad.push(n)
  return bad
}

/** Write the copy: dst then holds exactly `want`. */
export function writePublicDocs(want, dst = PUBLIC_DOCS_OUT) {
  rmSync(dst, { recursive: true, force: true })
  for (const [n, body] of want) {
    mkdirSync(dirname(join(dst, n)), { recursive: true })
    writeFileSync(join(dst, n), body)
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const want = publicDocsFiles()
  if (process.argv.includes('--check')) {
    const bad = publicDocsDrift(want)
    if (bad.length) {
      console.error(`public docs copy is stale (${bad.join(', ')}): run node src/node/docs/sync-public-docs.mjs in csi-spl-wui`)
      process.exit(1)
    }
    console.log('public docs copy matches the docs marked public: true')
  } else {
    writePublicDocs(want)
    console.log(`wrote ${want.size - 1} public doc(s) to src/public/docs-public`)
  }
}
