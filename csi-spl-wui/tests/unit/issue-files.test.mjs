// HUM-10 (t1 43ebdf0b): files in an issue's comments and description.
// A description names a stored file with a markdown link (descFileLink) and
// its view reads the link back as a file card (descFileRefs).
//
// Run: node tests/unit/issue-files.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { descFileLink, descFileRefs, uploadRefs } from '../../src/utils/issue-files.mjs'

const SHA = 'a'.repeat(64)
const SHA2 = 'b'.repeat(64)
const URL_OF = (id) => `https://hub.example.com/v1/files/${id}`

describe('issue files', () => {
  it('uploadRefs: one blob ref per file, named after it', async () => {
    const files = [{ name: 'a.png' }, { name: 'b.txt' }]
    const refs = await uploadRefs(files, async (f) => ({ file_id: f.name === 'a.png' ? SHA : SHA2, sha256: f.name === 'a.png' ? SHA : SHA2, bytes: 7 }))
    assert.deepEqual(refs, [
      { mode: 'blob', kind: 'file', file_id: SHA, sha256: SHA, bytes: 7, name: 'a.png' },
      { mode: 'blob', kind: 'file', file_id: SHA2, sha256: SHA2, bytes: 7, name: 'b.txt' },
    ])
  })

  it('descFileLink -> descFileRefs round-trips name, id and size', () => {
    const md = descFileLink({ name: 'shot.png', file_id: SHA, bytes: 1234 }, URL_OF(SHA))
    assert.equal(md, `[shot.png](${URL_OF(SHA)}#bytes=1234)`)
    assert.deepEqual(descFileRefs(`see\n${md}\nthanks`), [
      { mode: 'blob', kind: 'file', file_id: SHA, sha256: SHA, bytes: 1234, name: 'shot.png' },
    ])
  })

  it('a name with brackets or a line break cannot end the link early', () => {
    const md = descFileLink({ name: 'a]b[\nc.png', file_id: SHA, bytes: 1 }, URL_OF(SHA))
    assert.equal(descFileRefs(md)[0].name, 'a b c.png')
  })

  it('a relative (mock) url still reads back; once per file, in order', () => {
    const text = `[x](/v1/files/${SHA2}) and [y](/v1/files/${SHA}#bytes=3) and [x again](/v1/files/${SHA2})`
    assert.deepEqual(descFileRefs(text).map((r) => r.name), ['x', 'y'])
  })

  it('an ordinary link or a short id is not a file', () => {
    assert.deepEqual(descFileRefs('[home](https://example.com/) [f](https://h/v1/files/abc)'), [])
    assert.deepEqual(descFileRefs(''), [])
  })
})
