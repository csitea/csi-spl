// SPL-5012: no bundle holds the blog's pictures (do_copy_blog_media brings them
// at deploy), so serve-generated.mjs answers a placeholder for a picture the
// blog index names. Any other /blog/img/ path must stay a 404, or the browser
// e2e gates can no longer see a page asking for a picture that does not exist.
import { describe, it, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const SERVER = join(dirname(fileURLToPath(import.meta.url)), '../../src/node/test/serve-generated.mjs')
const ID = '2026-10-09-x'

const freePort = () => new Promise((resolve) => {
  const s = createServer().listen(0, '127.0.0.1', () => {
    const { port } = s.address()
    s.close(() => resolve(port))
  })
})

async function startServer(root) {
  const port = await freePort()
  const proc = spawn(process.execPath, [SERVER, '--root', root, '--port', String(port)], { stdio: 'ignore' })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(`${base}/`)
      return { proc, base }
    } catch {
      await new Promise((r) => setTimeout(r, 100))
    }
  }
  proc.kill()
  throw new Error('serve-generated.mjs did not start')
}

function bundle(index) {
  const root = mkdtempSync(join(tmpdir(), 'serve-generated-pictures-'))
  writeFileSync(join(root, '200.html'), '<html>shell</html>')
  writeFileSync(join(root, '404.html'), '<html>not found</html>')
  if (index) {
    mkdirSync(join(root, 'blog-md'))
    writeFileSync(join(root, 'blog-md/index.json'), JSON.stringify(index))
  }
  return root
}

describe('serve-generated.mjs blog pictures', () => {
  const roots = []
  const procs = []
  let base
  let noIndexBase

  before(async () => {
    const index = { locales: { en: [{ id: ID, image: `${ID}.webp`, gallery: [{ image: `${ID}-g1.jpg` }] }, { id: '2026-10-09-y' }] } }
    roots.push(bundle(index), bundle(null))
    const a = await startServer(roots[0])
    const b = await startServer(roots[1])
    procs.push(a.proc, b.proc)
    base = a.base
    noIndexBase = b.base
  })
  after(() => {
    for (const p of procs) p.kill()
    for (const r of roots) rmSync(r, { recursive: true, force: true })
  })

  for (const name of [`${ID}.webp`, `${ID}-og.webp`, `${ID}-g1.jpg`]) {
    it(`a named picture answers an image: ${name}`, async () => {
      const r = await fetch(`${base}/blog/img/${name}`)
      assert.equal(r.status, 200)
      assert.match(r.headers.get('content-type'), /^image\//)
    })
  }

  for (const path of ['/blog/img/no-such.webp', `/blog/img/${ID}-g1-og.jpg`, `/x/${ID}.webp`, '/no-such.png']) {
    it(`an unnamed path stays a 404: ${path}`, async () => {
      assert.equal((await fetch(`${base}${path}`)).status, 404)
    })
  }

  it('a bundle with no blog index has no pictures', async () => {
    assert.equal((await fetch(`${noIndexBase}/blog/img/${ID}.webp`)).status, 404)
  })

  it('a route still gets the SPA page', async () => {
    const r = await fetch(`${base}/lobby`)
    assert.equal(r.status, 200)
    assert.match(await r.text(), /shell/)
  })
})
