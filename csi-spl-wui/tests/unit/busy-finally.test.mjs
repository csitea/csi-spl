// Refactor round 3, row 9: a settings / picker handler that sets its busy flag
// (`saving` / `busy`) and then awaits must reset the flag in a `finally`. With
// a bare reset on the line after the await, one thrown call leaves the control
// disabled until a reload (and IssuesSortSetting would keep its optimistic
// sort). This is a source guard over the five handlers that were fixed.
// Run: node tests/unit/busy-finally.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const FILES = [
  'src/components/LanguageSetting.vue',
  'src/components/IssuesSortSetting.vue',
  'src/components/DisplayNameSetting.vue',
  'src/components/ViewPrefsSetting.vue',
  'src/components/MovePickerDialog.vue',
]

/** The body of the function enclosing `at`: from the `{` that opens the
 *  nearest preceding `function` to its matching `}`. */
function enclosingBody(src, at) {
  const fn = src.lastIndexOf('function ', at)
  if (fn < 0) return ''
  const open = src.indexOf('{', src.indexOf(')', fn))
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}' && --depth === 0) return src.slice(open, i + 1)
  }
  return ''
}

/** Each `<flag>.value = true` whose function has no later
 *  `finally { … <flag>.value = false`, as "<flag>@<offset>". */
function unguarded(src) {
  const bad = []
  for (const m of src.matchAll(/\b(saving|busy)\.value = true\b/g)) {
    const body = enclosingBody(src, m.index)
    const after = body.slice(body.indexOf(m[0]) + m[0].length)
    const reset = new RegExp(`finally\\s*\\{[^}]*\\b${m[1]}\\.value = false`)
    if (!reset.test(after)) bad.push(`${m[1]}@${m.index}`)
  }
  return bad
}

describe('busy flags reset in finally', () => {
  for (const rel of FILES) {
    it(rel, () => {
      const src = readFileSync(join(WUI, rel), 'utf8')
      assert.ok(/\b(saving|busy)\.value = true\b/.test(src), `${rel}: no busy flag set (guard would pass vacuously)`)
      assert.deepEqual(unguarded(src), [], `${rel}: busy flag set without a finally reset`)
    })
  }

  it('CONTROL: a bare reset after the await is caught', () => {
    const bad = 'async function pick() {\n  saving.value = true\n  await go()\n  saving.value = false\n}\n'
    assert.equal(unguarded(bad).length, 1)
    const good = 'async function pick() {\n  saving.value = true\n  try {\n    await go()\n  } finally {\n    saving.value = false\n  }\n}\n'
    assert.equal(unguarded(good).length, 0)
  })
})
