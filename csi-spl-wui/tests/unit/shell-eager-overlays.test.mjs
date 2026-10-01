// CLE-77840 (owner, t1 topic f20c6052: "cannot see this snackbar at all").
// The shell's snackbars and the dialogs an action opens must ship WITH the
// shell. A `<LazyX>` there is fetched on first use, and on a tab older than
// the last deploy that chunk is gone: it 404s, plugins/chunk-reload.client.ts
// reloads the page, and the snackbar / confirm never shows. The browser proofs
// are archive-undo.test.mjs and merge-by-drag.test.mjs (stale-tab steps).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const layout = readFileSync(join(here, '../../src/layouts/default.vue'), 'utf8')

describe('shell overlays are eager (no lazy chunk on a stale tab)', () => {
  for (const name of ['ArchiveUndoToast', 'MoveUndoToast', 'MergeConfirmDialog']) {
    it(`${name} is mounted eagerly`, () => {
      assert.match(layout, new RegExp(`<${name}\\b`))
      assert.doesNotMatch(layout, new RegExp(`<Lazy${name}\\b`))
    })
  }
})
