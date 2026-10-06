// *.client.ts plugins are client-only by file suffix. Nuxt never loads them
// on the server, so `if (!import.meta.client) return` as the first statement
// of the default export is dead. A guard nested in an object-form setup
// (0.0.runtime-config.client.ts) stays; this scan does not treat that as the
// opening of the default export.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGINS = join(dirname(fileURLToPath(import.meta.url)), '../../src/plugins')

// Later round. These three still open with the dead guard.
const LATER_ROUND = [
  'locale-cookie.client.ts',
  'spool-live.client.ts',
  'tenant-host.client.ts',
]

// error-journal.test.mjs requires the source token `import.meta.client` in
// error-journal.client.ts. This scan does not ask that file to drop the guard.
const PINNED = ['error-journal.client.ts']

const CLEANED = [
  'chunk-reload.client.ts',
  'event-log.client.ts',
  'lobby-warm.client.ts',
  'preferred-locale.client.ts',
  'preferred-theme.client.ts',
]

const KEYS = {
  'chunk-reload.client.ts': ['KEY', 'spool.chunk-reload-at'],
  'preferred-locale.client.ts': ['MARK', 'csi-spl-pref-locale-applied'],
  'preferred-theme.client.ts': ['MARK', 'csi-spl-pref-theme-applied'],
}

function read(name) {
  return readFileSync(join(PLUGINS, name), 'utf8')
}

// True when the arrow callback of defineNuxtPlugin opens with the guard.
// Object-form plugins (setup()) do not match.
function opensWithClientGuard(src) {
  const m = src.match(/export default defineNuxtPlugin\s*\(\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>\s*\{/)
  if (!m) return false
  const rest = src.slice(m.index + m[0].length)
  const body = rest.replace(/^(?:\s|\/\/[^\n]*(?:\n|$))*/, '')
  return /^if\s*\(\s*!\s*import\.meta\.client\s*\)\s*return\b/.test(body)
}

describe('client plugins do not open on a dead import.meta.client guard', () => {
  const files = readdirSync(PLUGINS).filter((f) => f.endsWith('.client.ts')).sort()

  it('sees the client plugins', () => {
    assert.ok(files.length > 10, String(files.length))
    for (const name of CLEANED.concat(LATER_ROUND, PINNED)) {
      assert.ok(files.includes(name), name)
    }
  })

  it('only the later-round allow-list and the pinned journal plugin open with the guard', () => {
    const open = files.filter((f) => opensWithClientGuard(read(f)))
    assert.deepEqual(open, LATER_ROUND.concat(PINNED).sort())
  })

  it('the five cleaned plugins do not open with the guard', () => {
    for (const name of CLEANED) {
      assert.equal(opensWithClientGuard(read(name)), false, name)
    }
  })

  it('preferred-theme says client-only by file suffix in the header', () => {
    const header = read('preferred-theme.client.ts').split(/^import /m)[0]
    assert.match(header, /client-only by file suffix/i)
  })

  it('the nested runtime-config guard stays inside setup, not at the export', () => {
    const src = read('0.0.runtime-config.client.ts')
    assert.equal(opensWithClientGuard(src), false)
    assert.match(src, /if \(!import\.meta\.client\) return/)
  })

  it('storage keys are unique module constants, visible above the export', () => {
    const seen = new Map()
    for (const [file, [name, value]] of Object.entries(KEYS)) {
      const src = read(file)
      const exportAt = src.indexOf('export default')
      assert.ok(exportAt > 0, file)
      const head = src.slice(0, exportAt)
      const literal = value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      assert.match(head, new RegExp(`^const ${name} = '${literal}'`, 'm'), file)
      assert.doesNotMatch(src.slice(exportAt), new RegExp(`const ${name} =`), file)
      assert.equal(seen.has(value), false, `${value} also in ${seen.get(value)}`)
      seen.set(value, file)
    }
  })
})
