#!/usr/bin/env node
// serve-generated.mjs — serve `.output/public` the way Firebase Hosting does,
// so a generated bundle can be driven in a real browser before it is deployed.
//
// WHY this exists rather than `npx serve` (ported from the donor WUI): the
// WUI's routing depends on Hosting behaviours a plain static server lacks.
//
//   1. SPA FALLBACK. render-wui-firebase-json.sh rewrites `**` to /200.html
//      after the /api/v1/auth/** run rewrite, so every route without its own
//      document (channels, DMs, /t/<id>, unknown URLs) boots the SPA shell and
//      Nuxt's error page renders a client-side 404. A missing /_nuxt/ file is
//      the exception: a /_nuxt/** rewrite to a missing sentinel answers 404
//      first (SPL-2770), so an old tab's lost chunk is a 404, not the shell.
//      A missing picture, font or manifest 404s the same way (SPL-5012).
//      The one stand-in: a blog picture its index names. do_copy_blog_media
//      brings those at deploy and refuses a missing one, and no bundle holds
//      them, so they answer a placeholder. Any other /blog/img/ path 404s.
//   2. DIRECTORY INDEXES. `nuxt generate` writes `<route>/index.html`.
//   3. A SAME-ORIGIN /api/** and /v1/**. `--api <origin>` proxies them to a
//      hub (lde: the auth-demo or the spool hub), the way the Hosting rewrite
//      and the 031 load balancer do in dev/prd.
//
// Usage:
//   node src/node/test/serve-generated.mjs [--root .output/public] [--port 4321]
//                                          [--api http://127.0.0.1:58181]
//
// Prints the URL it is listening on and stays in the foreground. It is a test
// harness: no caching, no compression negotiation, localhost only.
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { join, extname, normalize } from 'node:path'

const args = process.argv.slice(2)
const argOf = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}
const ROOT = argOf('--root', '.output/public')
const PORT = Number(argOf('--port', '4321'))
const API = String(argOf('--api', '')).replace(/\/+$/, '')

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.xml': 'application/xml; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
}

/** render-wui-firebase-json.sh ends with `"source": "**" -> /200.html`;
 *  `/_nuxt/**` and a missing media file go to a missing sentinel (404) before it. */
const MEDIA_PATH = /\.(?:avif|webp|png|jpg|jpeg|gif|svg|ico|woff2|webmanifest)$/
const SPA_FALLBACK = [/^\/(?!_nuxt\/)/]
const BLOG_IMG = '/blog/img/'
const PICTURE_PLACEHOLDER = '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675"><rect width="100%" height="100%" fill="#888"/></svg>'

/** The file names do_copy_blog_media copies: each entry's image, its -og crop
 *  and its gallery. No index: an empty set, so every picture is a 404. */
async function indexedPictures() {
  const names = new Set()
  let locales
  try {
    locales = JSON.parse(await readFile(join(ROOT, 'blog-md/index.json'), 'utf8')).locales
  } catch {
    return names
  }
  for (const entry of Object.values(locales || {}).flat()) {
    if (entry.image) names.add(entry.image).add(entry.image.replace(/\.(webp|jpg)$/, '-og.$1'))
    for (const g of entry.gallery || []) if (g.image) names.add(g.image)
  }
  return names
}
const PICTURES = await indexedPictures()

async function readIfFile(p) {
  try {
    const s = await stat(p)
    if (!s.isFile()) return null
    return await readFile(p)
  } catch {
    return null
  }
}

createServer(async (req, res) => {
  const raw = req.url || '/'
  const path = normalize(decodeURIComponent(raw.split('?')[0]))
  if (path.includes('..')) {
    res.writeHead(400).end('bad path')
    return
  }
  if (API && (path.startsWith('/api/') || path.startsWith('/v1/'))) {
    try {
      const upstream = await fetch(`${API}${raw}`, {
        method: req.method,
        headers: {
          accept: req.headers.accept || 'application/json',
          ...(req.headers.cookie ? { cookie: req.headers.cookie } : {}),
        },
        redirect: 'manual',
      })
      const body = Buffer.from(await upstream.arrayBuffer())
      const headers = { 'Content-Type': upstream.headers.get('content-type') || 'application/json' }
      for (const h of ['location', 'set-cookie', 'cache-control']) {
        const v = upstream.headers.get(h)
        if (v) headers[h] = v
      }
      res.writeHead(upstream.status, headers)
      res.end(body)
    } catch (err) {
      res.writeHead(502, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ error: String(err) }))
    }
    return
  }
  const candidates = [join(ROOT, path), join(ROOT, path, 'index.html')]
  for (const c of candidates) {
    const body = await readIfFile(c)
    if (body) {
      res.writeHead(200, { 'Content-Type': TYPES[extname(c)] || 'application/octet-stream' })
      res.end(body)
      return
    }
  }
  if (path.startsWith(BLOG_IMG) && PICTURES.has(path.slice(BLOG_IMG.length))) {
    res.writeHead(200, { 'Content-Type': TYPES['.svg'] })
    res.end(PICTURE_PLACEHOLDER)
    return
  }
  if (!MEDIA_PATH.test(path) && SPA_FALLBACK.some((re) => re.test(path))) {
    const shell = await readIfFile(join(ROOT, '200.html'))
    if (shell) {
      res.writeHead(200, { 'Content-Type': TYPES['.html'] })
      res.end(shell)
      return
    }
  }
  const notFound = await readIfFile(join(ROOT, '404.html'))
  res.writeHead(404, { 'Content-Type': TYPES['.html'] })
  res.end(notFound || 'not found')
}).listen(PORT, '127.0.0.1', () => {
  console.log(`serving ${ROOT} on http://127.0.0.1:${PORT} (SPA fallback)`)
})
