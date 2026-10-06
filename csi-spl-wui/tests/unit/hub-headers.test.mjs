// hubJsonHeaders (refactor r4-04): the one builder of a hub JSON read's
// headers. The helper is .ts, so the test transpiles it with typescript.
//
// Run: node tests/unit/hub-headers.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

const js = ts.transpileModule(read('src/utils/hub-headers.ts'), {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText
const { hubJsonHeaders } = await import('data:text/javascript,' + encodeURIComponent(js))

const SITES = [
  'src/utils/calendar-reminder-timer.ts',
  'src/components/CalendarMainView.vue',
  'src/components/CalendarYearStrip.vue',
]

describe('hubJsonHeaders', () => {
  it('sends accept JSON and the bearer token', () => {
    assert.deepEqual(hubJsonHeaders('tok'), { accept: 'application/json', authorization: 'Bearer tok' })
  })
  it('leaves authorization out when there is no token (a cookie session)', () => {
    assert.deepEqual(hubJsonHeaders(''), { accept: 'application/json' })
  })
  it('returns a fresh object each call', () => {
    assert.notEqual(hubJsonHeaders('tok'), hubJsonHeaders('tok'))
  })
})

describe('the calendar reads build their headers with the helper', () => {
  for (const f of SITES) {
    it(f, () => {
      const src = read(f)
      assert.match(src, /import \{ hubJsonHeaders \} from '~\/utils\/hub-headers'/)
      assert.match(src, /const headers = hubJsonHeaders\(api\.token\)/)
      assert.doesNotMatch(src, /headers\.authorization = `Bearer/)
    })
  }
})
