// serve a generated bundle the way Firebase Hosting does, over TLS +
// HTTP/2, so a perf proof can A/B two bundles under the REAL WUI host name:
//
//   node tests/e2e/lib/serve-hosting-h2.mjs --root <dist> --port 8443 --cert <pem> --key <pem>
//   chrome --host-resolver-rules='MAP e2e.<domain> 127.0.0.1:8443' --ignore-certificate-errors
//
// The page keeps its origin, so the hub's CORS allow-list and the session
// cookie behave exactly as on the deployed host; only the static files come
// from disk. Like Hosting: clean URLs, `**` -> /200.html, /_nuxt/** immutable,
// everything else max-age=0 + ETag (a warm reload revalidates with a 304), and
// gzip for text. The one deliberate difference: ~0 ms to the origin, so compare
// a bundle only with another bundle served by this same server.
import { createSecureServer } from 'node:http2'
import { readFileSync, statSync, existsSync } from 'node:fs'
import { join, extname, normalize } from 'node:path'
import { gzipSync } from 'node:zlib'
import { createHash } from 'node:crypto'

const args = process.argv.slice(2)
const argOf = (n, d) => { const i = args.indexOf(n); return i >= 0 && args[i + 1] ? args[i + 1] : d }
const ROOT = argOf('--root', '.output/public')
const PORT = Number(argOf('--port', '8443'))
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json', '.txt': 'text/plain', '.woff2': 'font/woff2',
}
const cache = new Map()
function load(file) {
  let e = cache.get(file)
  if (e) return e
  const body = readFileSync(file)
  const type = TYPES[extname(file)] || 'application/octet-stream'
  const text = /^(text|application\/(json|manifest))/.test(type) || type.includes('svg')
  e = { body, gz: text ? gzipSync(body, { level: 9 }) : null, type, etag: '"' + createHash('sha1').update(body).digest('hex').slice(0, 16) + '"' }
  cache.set(file, e)
  return e
}
function resolve(pathname) {
  const p = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, '')
  for (const c of [p, p + '.html', join(p, 'index.html')]) {
    const f = join(ROOT, c)
    if (existsSync(f) && statSync(f).isFile()) return f
  }
  return join(ROOT, '200.html')
}
const server = createSecureServer({ allowHTTP1: true, cert: readFileSync(argOf('--cert')), key: readFileSync(argOf('--key')) }, (req, res) => {
  const url = new URL(req.url, 'https://x')
  const file = resolve(url.pathname)
  const e = load(file)
  const headers = {
    'content-type': e.type,
    'cache-control': url.pathname.startsWith('/_nuxt/') ? 'public, max-age=31536000, immutable' : 'public, max-age=0, must-revalidate',
    etag: e.etag,
    vary: 'Accept-Encoding',
  }
  if (req.headers['if-none-match'] === e.etag) { res.writeHead(304, headers); res.end(); return }
  const gz = e.gz && /gzip/.test(String(req.headers['accept-encoding'] || ''))
  if (gz) headers['content-encoding'] = 'gzip'
  res.writeHead(200, headers)
  res.end(gz ? e.gz : e.body)
})
server.listen(PORT, '127.0.0.1', () => console.log(`serving ${ROOT} on https://127.0.0.1:${PORT}`))
