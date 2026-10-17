// SPL-2410: the lde `wui` dev server crash-looped on
//   import Git from 'simple-git';
//   SyntaxError: The requested module 'simple-git' does not provide an export named 'default'
// pnpm.overrides forced simple-git ^4 (an advisory fix) onto @nuxt/devtools
// 3.4.2, which declares ^3.36.0 and default-imports it; v4 has no default
// export. `nuxt generate` never loads DevTools and typecheck never links
// node_modules, so only `nuxt dev` died.
//
// An override is the one place a version is forced against a dependent's
// own range. This test links every static ESM import that a dependent of an
// overridden package makes from it: each default or named binding must exist
// on the version the override installed. It needs the installed tree
// (`pnpm install`); a missing node_modules fails, never skips.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const STORE = join(WUI, 'node_modules/.pnpm')

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'))

// "a>b" and "a@1>b" select b under a: the overridden package is the last part.
const overridden = () => Object.keys(readJson(join(WUI, 'package.json')).pnpm?.overrides ?? {})
  .map((k) => k.split('>').pop().replace(/(.)@[^@/]*$/, '$1'))

// every installed package reachable from the top-level node_modules, with
// the node_modules dir its own dependencies resolve in. Reachable, not every
// .pnpm entry: an update leaves the old entry on disk until pnpm prunes it.
function installedPackages() {
  const out = []
  const seen = new Set()
  const deps = (pkg) => Object.keys({ ...pkg.dependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies })
  const queue = deps(readJson(join(WUI, 'package.json'))).map((n) => join(WUI, 'node_modules', n))
  while (queue.length) {
    const link = queue.pop()
    if (!existsSync(join(link, 'package.json'))) continue
    const dir = realpathSync(link)
    if (seen.has(dir)) continue
    seen.add(dir)
    const pkg = readJson(join(dir, 'package.json'))
    const nm = pkg.name.startsWith('@') ? dirname(dirname(dir)) : dirname(dir)
    out.push({ nm, name: pkg.name, dir, pkg })
    for (const d of deps(pkg)) queue.push(join(nm, d))
  }
  return out
}

function esmEntry(dir) {
  const pkg = readJson(join(dir, 'package.json'))
  let e = pkg.exports?.['.'] ?? pkg.exports
  while (e && typeof e === 'object') e = e.import ?? e.node ?? e.default
  return join(dir, (typeof e === 'string' && e) || pkg.module || pkg.main || 'index.js')
}

function jsFiles(dir, out = []) {
  for (const n of readdirSync(dir)) {
    if (n === 'node_modules') continue
    const p = join(dir, n)
    if (statSync(p).isDirectory()) jsFiles(p, out)
    else if (/\.m?js$/.test(n)) out.push(p)
  }
  return out
}

// the bindings a file statically imports from `spec`: 'default' and named ones
function importedBindings(code, spec) {
  const q = spec.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')
  const re = new RegExp(`import\\s+([\\w$]+)?\\s*,?\\s*(?:\\{([^}]*)\\})?\\s*from\\s*['"]${q}['"]`, 'g')
  const names = new Set()
  for (const m of code.matchAll(re)) {
    if (m[1]) names.add('default')
    for (const b of (m[2] ?? '').split(',')) {
      const n = b.trim().split(/\s+as\s+/)[0]
      if (n) names.add(n)
    }
  }
  return names
}

describe('pnpm overrides still link for their dependents (SPL-2410)', () => {
  it('the installed tree exists', () => {
    assert.ok(existsSync(STORE), `no ${STORE}: run pnpm install in csi-spl-wui first`)
  })

  it('every binding a dependent imports from an overridden package exists', async () => {
    const targets = new Set(overridden())
    assert.ok(targets.size > 0, 'package.json has no pnpm.overrides: this test guards nothing')
    const installed = installedPackages()
    assert.ok(installed.some((p) => p.name === 'nuxt'), 'the walk did not reach nuxt: the tree is not installed')
    const broken = []
    for (const { nm, name, dir, pkg } of installed) {
      if (targets.has(name)) continue
      const deps = { ...pkg.dependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies }
      for (const t of Object.keys(deps).filter((d) => targets.has(d))) {
        const tdir = join(nm, t)
        if (!existsSync(tdir)) continue
        const want = jsFiles(dir)
          .map((f) => ({ f, names: importedBindings(readFileSync(f, 'utf8'), t) }))
          .filter((x) => x.names.size)
        if (!want.length) continue
        const mod = await import(pathToFileURL(esmEntry(tdir)).href)
        const tver = readJson(join(tdir, 'package.json')).version
        for (const { f, names } of want) {
          for (const n of names) {
            if (!(n in mod)) broken.push(`${pkg.name}@${pkg.version} (${deps[t]}) imports '${n}' from ${t}@${tver}, which has no such export: ${f.slice(dir.length + 1)}`)
          }
        }
      }
    }
    assert.deepEqual(broken, [])
  })
})
