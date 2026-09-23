// CLE-3433 — /dm and /channel offered the 📎 attach control and then sent a
// frame with NO files. Measured on the deployed dev build bb20552, signed in
// as the t1 test member, WS `send` frames captured and held back so nothing
// reached the hub (n=1 per route):
//
//     /lobby           1 send frame, 1 file  ["cle3433-attach.txt"]
//     /dm/<peer>       1 send frame, 0 files []
//     /channel/lobby   1 send frame, 0 files []
//
// and the file chip disappeared from the composer in all three, so it LOOKED
// sent. Two independent causes, both pinned below.
//
// TYPES COULD NOT CATCH THIS. `OmniboxTarget.send` is
// `(text: string, files: File[]) => unknown`, and a handler declaring FEWER
// parameters is assignable to it — `onSend(text: string)` typechecked
// perfectly while dropping the argument it never named.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

/* every page that registers a send target for the top-bar Omnibox */
const OMNIBOX_PAGES = [
  'src/pages/dm/[peer].vue',
  'src/pages/channel/[name].vue',
  'src/pages/lobby.vue',
]
/* thread panes no longer have their own composer; the top bar sends the reply */

describe('cause 1: the handler has to ACCEPT the files (CLE-3433)', () => {
  for (const page of OMNIBOX_PAGES) {
    it(`${page}: what it registers takes (text, files)`, () => {
      const s = src(page)
      /* a fixed window, not up to the first `})`: the registration contains
         nested calls like t('…', { target }) and slicing at those cut the
         `send:` line off and made this test fail on correct code */
      const block = s.slice(s.indexOf('useOmniboxTarget('), s.indexOf('useOmniboxTarget(') + 400)
      /* either `send: onSend` where onSend names files, or an inline adapter
         that passes them on — both are fine, silence is not */
      const inlineAdapter = /send:\s*\(text: string, files: File\[\]\)\s*=>[^\n]*files/.test(block)
      const named = /send:\s*onSend\b/.test(block) && /function onSend\([^)]*files\??:\s*File\[\]/.test(s)
      assert.ok(inlineAdapter || named, `${page}: the registered send drops its files argument`)
    })
  }

})

describe('cause 2: a picked File is not a wire value (CLE-3433)', () => {
  const store = () => src('src/stores/channel.ts')

  it('the channel store uploads a Blob before it puts it on the frame', () => {
    const s = store()
    assert.match(s, /async function toFileRefs\(/)
    assert.match(s, /f instanceof Blob/)
    assert.match(s, /api\.uploadFile\(f, await live\.freshUploadToken\(\)\)/)
    assert.match(s, /files: await toFileRefs\(files\)/)
  })

  it('an already-uploaded ref passes through, so the auto-resend cannot upload twice', () => {
    const s = store()
    const fn = s.slice(s.indexOf('async function toFileRefs('))
    const body = fn.slice(0, fn.indexOf('\n  }'))
    assert.match(body, /else if \(f\) \{[\s\S]*?refs\.push\(f as FileRef\)/)
  })

  /* stores/live.ts is where this shape was already right; if it ever stops
     being the reference, this test is reading a fossil */
  it('CONTROL: stores/live.ts still uploads the same way', () => {
    assert.match(src('src/stores/live.ts'), /api\.uploadFile\(f, await live\.freshUploadToken\(\)\)/)
  })
})

describe('the composer offers attach on exactly the routes that can honour it', () => {
  it('MessageComposer still renders the attach control outside search mode', () => {
    /* if this ever goes away the tests above are guarding a control nobody
       can reach, and should be deleted rather than left passing */
    assert.match(src('src/components/MessageComposer.vue'), /data-testid="attach"/)
  })
})
