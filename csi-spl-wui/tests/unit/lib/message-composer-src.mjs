// MessageComposer's source, as the tests that read it need it.
//
// r13-03 split the composer's <script> over composables
// (src/composables/useComposer*.ts): the composer wires them, each holds one
// part. A test that pins a line of the composer's code reads this instead of
// MessageComposer.vue alone, so the line is found whichever of those files
// holds it now. The SFC comes first: a test that looks for its <template> or
// <style> still finds them where they were.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')

export const MESSAGE_COMPOSER_FILES = [
  'src/components/MessageComposer.vue',
  'src/composables/composerProps.ts',
  'src/composables/useComposerDock.ts',
  'src/composables/useComposerDraft.ts',
  'src/composables/useComposerFiles.ts',
  'src/composables/useComposerKeys.ts',
  'src/composables/useComposerPickers.ts',
  'src/composables/useComposerSend.ts',
  'src/composables/useComposerSize.ts',
  'src/composables/useComposerSyntax.ts',
  'src/composables/useComposerTarget.ts',
  'src/composables/useComposerWrap.ts',
]

/** MessageComposer.vue, then every composable it was split into, one string. */
export function messageComposerSrc() {
  return MESSAGE_COMPOSER_FILES.map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
}
