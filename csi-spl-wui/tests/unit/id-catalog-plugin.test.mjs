// The catalog chunk loads after the first script. A second navigation can
// abort that fetch. The preload helper then resolves with no module, and
// reading installIdCatalog off it threw a page error (quality gate 10,
// run 37213750211, sha 10c8a57d0, n=1).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/plugins/id-catalog.ts'), 'utf8')

describe('id catalog plugin', () => {
  it('does not call installIdCatalog when the chunk never arrives', () => {
    assert.match(src, /m\?\.installIdCatalog\?/)
    assert.match(src, /\.catch\(/)
  })
  it('CONTROL: the plugin still loads the catalog module', () => {
    assert.match(src, /import\('~\/utils\/id-catalog-install'\)/)
    assert.match(src, /installIdCatalog/)
  })
})
