// Shared preamble of the live proofs (tests/e2e/*.proof.mjs). Over 100 of them
// carried the same loadPuppeteer / need / sleep, copied (CLE-77928, clean-code
// round, item 34). A proof imports what it uses:
//   import { loadPuppeteer, need, sleep } from './lib/proof.mjs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

// puppeteer-core from PUPPETEER_CORE (a path or a package spec), else from the
// WUI's node_modules. Throws when neither resolves: a proof never runs without
// a browser driver.
export async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// need(k) - the env var k, or exit 2 naming it.
export const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
