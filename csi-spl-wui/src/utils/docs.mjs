/**
 * The Docs section (owner, prd t1 9f0d751c): every .md of the repo, published
 * at each WUI deploy to the env's docs bucket (do_publish_docs) and read
 * through the hub, GET /v1/docs/<repo path> and GET /v1/docs/tree.json.
 * A doc's page is /docs/<repo path> - a stable URL a topic can link to, and
 * the one the git-spec linking lane resolves "spec 072" to. Here: the folder
 * tree out of tree.json and the link rewrite. Node tests import this file.
 */

/** Where a relative link to a repo file that is not a published doc resolves. */
export const DOCS_REPO_BASE = 'https://github.com/csitea/csi-spl/blob/master/'

/** The doc /docs opens on when no path is given. */
export const DOCS_HOME = 'README.md'

/** A repo path the publish writes (the hub's ValidDocsPath, minus tree.json). */
export function validDocsPath(p) {
  return typeof p === 'string' && p.length <= 512 &&
    /^[A-Za-z0-9_-][A-Za-z0-9._-]*(\/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$/.test(p)
}

/** The in-app route of a doc. */
export function docsRoute(path) {
  return '/docs/' + path
}

/** a/b/./c/../d -> a/b/d; null when it climbs above the repo root */
function normalize(parts) {
  const out = []
  for (const s of parts) {
    if (s === '' || s === '.') continue
    if (s === '..') {
      if (!out.length) return null
      out.pop()
    } else out.push(s)
  }
  return out.join('/')
}

/**
 * One link target as a doc at `from` shows it: a relative link to a .md
 * becomes its /docs route, any other relative link points at the file in
 * the public repository; absolute, mailto, anchors and site paths stay.
 * `route(path)` builds the in-app path (the page passes its locale-aware one).
 */
export function docsHref(raw, from, route = docsRoute) {
  const s = String(raw ?? '').trim()
  if (!s) return s
  if (/^[a-z][a-z0-9+.-]*:/i.test(s) || s.startsWith('#') || s.startsWith('/')) return s
  const m = /^([^#?]*)([?#].*)?$/.exec(s)
  const target = m ? m[1] : s
  const dir = String(from || '').split('/').slice(0, -1)
  let joined
  try {
    joined = normalize([...dir, ...decodeURI(target).split('/')])
  } catch {
    return s
  }
  if (joined === null) return s
  if (validDocsPath(joined)) return route(joined)
  return DOCS_REPO_BASE + joined + (m && m[2] ? m[2] : '')
}

/*
 * SPL-1291 (owner, t1 2b25c535): a link to a doc in a MESSAGE opens our own
 * docs store. A link to a .md file of THIS repository, <repoWebUrl>/blob/
 * <ref>/<path>.md (GitLab: /-/blob/), and a bare repo-relative <path>.md
 * become /docs/<path>, the anchor kept. The repository is cnf
 * env.wui.repo_web_url (/config.json repoWebUrl), never a literal host;
 * unset = only the relative form rewrites. Commit, PR, tree, raw, a non-.md
 * file, a ?query (?plain=1 line links) and any other host stay as written.
 */
const BLOB_RE = /^(?:\/-)?\/blob\/[^/]+\/([^?#]+)$/

/**
 * The /docs route for a link to a doc of the repository at `webUrl`, or null
 * when the link is not one (it then stays as written).
 */
export function docsLinkHref(raw, webUrl, route = docsRoute) {
  const s = String(raw ?? '').trim()
  if (!s || s.startsWith('/') || s.startsWith('#') || s.startsWith('?')) return null
  if (/^[a-z][a-z0-9+.-]*:/i.test(s)) {
    let u, base
    try {
      u = new URL(s)
      base = new URL(String(webUrl ?? '').trim())
    } catch {
      return null
    }
    if (!/^https?:$/.test(u.protocol) || !/^https?:$/.test(base.protocol) || u.search) return null
    const host = (h) => h.toLowerCase().replace(/^www\./, '')
    if (host(u.host) !== host(base.host)) return null
    const root = base.pathname.replace(/\/+$/, '')
    if (!root || !u.pathname.startsWith(root + '/')) return null
    const m = BLOB_RE.exec(u.pathname.slice(root.length))
    if (!m) return null
    let path
    try { path = decodeURIComponent(m[1]) } catch { return null }
    return validDocsPath(path) ? route(path) + u.hash : null
  }
  const m = /^(?:\.\/)?([^?#]+)(#.*)?$/.exec(s)
  if (!m || !validDocsPath(m[1])) return null
  return route(m[1]) + (m[2] || '')
}

/**
 * The page of a doc in the repository at `webUrl`, on the branch named by
 * `helpPath` (cnf repo_help_path, "/blob/<branch>/..."), for a doc the store
 * has not published; '' when either is unset.
 */
export function docsRepoUrl(path, webUrl, helpPath) {
  const b = String(webUrl ?? '').trim().replace(/\/+$/, '')
  const m = /^((?:\/-)?\/blob\/[^/?#\s]+\/)/.exec(String(helpPath ?? '').trim())
  if (!/^https?:\/\/[^\s"'<>]+$/i.test(b) || !m || !validDocsPath(path)) return ''
  return b + m[1] + path
}

/** The markdown with every inline link target rewritten by docsHref. */
export function rewriteDocsLinks(md, from, route) {
  return String(md ?? '').replace(/\]\(([^)\s]+)((?:\s+"[^"]*")?)\)/g, (_, href, title) => '](' + docsHref(href, from, route) + title + ')')
}

/**
 * The explorer tree of tree.json's files: folders first, then files, each by
 * name. A node is { name, path, dirs, files } (the root's path is '');
 * a file is { name, path, title }.
 */
export function buildDocsTree(files) {
  const root = { name: '', path: '', dirs: [], files: [] }
  const index = new Map([['', root]])
  for (const f of Array.isArray(files) ? files : []) {
    const p = f && f.path
    if (!validDocsPath(p)) continue
    const parts = p.split('/')
    let node = root
    for (let i = 0; i < parts.length - 1; i++) {
      const at = parts.slice(0, i + 1).join('/')
      let next = index.get(at)
      if (!next) {
        next = { name: parts[i], path: at, dirs: [], files: [] }
        index.set(at, next)
        node.dirs.push(next)
      }
      node = next
    }
    node.files.push({ name: parts[parts.length - 1], path: p, title: typeof f.title === 'string' && f.title ? f.title : parts[parts.length - 1] })
  }
  const byName = (a, b) => a.name.localeCompare(b.name)
  const sort = (n) => { n.dirs.sort(byName); n.files.sort(byName); n.dirs.forEach(sort) }
  sort(root)
  return root
}

/** The folders a doc sits in, outermost first: a/b/c.md -> ['a', 'a/b']. */
export function docsAncestors(path) {
  const parts = String(path || '').split('/').slice(0, -1)
  return parts.map((_, i) => parts.slice(0, i + 1).join('/'))
}

/** The tree flattened to the rows on screen, given the open folders. */
export function visibleDocsRows(root, open) {
  const rows = []
  const walk = (n, depth) => {
    for (const d of n.dirs) {
      const isOpen = open.has(d.path)
      rows.push({ kind: 'dir', path: d.path, name: d.name, depth, open: isOpen })
      if (isOpen) walk(d, depth + 1)
    }
    for (const f of n.files) rows.push({ kind: 'file', path: f.path, name: f.name, title: f.title, depth })
  }
  walk(root, 0)
  return rows
}
