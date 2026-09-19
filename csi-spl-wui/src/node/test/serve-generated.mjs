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
//      Nuxt's error page renders a client-side 404.
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

/** render-wui-firebase-json.sh ends with `"source": "**" -> /200.html`. */
const SPA_FALLBACK = [/^\//]

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
  if (SPA_FALLBACK.some((re) => re.test(path))) {
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
