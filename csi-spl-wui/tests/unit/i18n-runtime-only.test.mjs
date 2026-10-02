// CLE-35075 (P2, epic SPL-1093): vue-i18n ships runtime-only, without its
// message compiler. Every catalogue is a JSON file under i18n/locales that the
// build precompiles (unplugin-vue-i18n), so the browser never compiles a
// message; the compiler was ~5 KB gzip of first-paint JS for nothing
// (mock bundle 159.8 -> 154.9 KB on e1040f41).
//
// The one way to break this is a message that only exists at runtime: a
// setLocaleMessage / mergeLocaleMessage call or an inline `messages:` object.
// Runtime-only vue-i18n cannot compile those and would print the key instead
// of the text, so this test refuses them.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const MERGES_COMPILED = 'src/plugins/i18n-more.client.ts'

function files(dir, out = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n)
    if (statSync(p).isDirectory()) files(p, out)
    else if (/\.(vue|ts|mjs|js)$/.test(n)) out.push(p)
  }
  return out
}

describe('vue-i18n runtime-only', () => {
  it('nuxt.config bundles vue-i18n without the message compiler', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    const bundle = /\bbundle:\s*\{([^}]*)\}/.exec(cfg)
    assert.ok(bundle, 'i18n.bundle block not found in nuxt.config.ts')
    assert.match(bundle[1], /\bruntimeOnly:\s*true\b/)
    assert.match(bundle[1], /\bdropMessageCompiler:\s*true\b/)
  })

  it('no source adds a message at runtime (it would need the compiler)', () => {
    const bad = []
    for (const f of files(join(WUI, 'src'))) {
      const rel = f.slice(WUI.length + 1)
      if (rel === MERGES_COMPILED) continue
      const src = readFileSync(f, 'utf8')
      if (/\b(setLocaleMessage|mergeLocaleMessage)\s*\(/.test(src)) bad.push(rel)
    }
    assert.deepEqual(bad, [])
  })

  // Perf round 3, P3-06: the one merge, of the second catalogue, which the
  // build writes already compiled (src/node/i18n/split-catalogue.mjs).
  it('the catalogue-split loader merges only the build-compiled second catalogues', () => {
    const src = readFileSync(join(WUI, MERGES_COMPILED), 'utf8')
    assert.match(src, /import\.meta\.glob<[^>]*>\('\.\.\/\.\.\/i18n\/\.split\/more\/\*\.mjs'\)/)
    assert.equal([...src.matchAll(/\bmergeLocaleMessage\s*\(/g)].length, 1)
    assert.match(src, /mergeLocaleMessage\(code, m\.default\)/)
    const split = readFileSync(join(WUI, 'src/node/i18n/split-catalogue.mjs'), 'utf8')
    assert.match(split, /generateJSON\(/)
  })
})
