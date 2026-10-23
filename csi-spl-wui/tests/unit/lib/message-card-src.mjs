// MessageCard's source, as the tests that read it need it.
//
// r13-01 split the card's <script> over composables (src/composables/useCard*.ts):
// the card wires them, each holds one part. A test that pins a line of the
// card's code reads this instead of MessageCard.vue alone, so the line is
// found whichever of those files holds it now. The SFC comes first: a test
// that looks for its <template> or <style> still finds them where they were.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')

export const MESSAGE_CARD_FILES = [
  'src/components/MessageCard.vue',
  'src/composables/useCardEdit.ts',
  'src/composables/useCardReactions.ts',
  'src/composables/useCardHeight.ts',
  'src/composables/useCardTopicActions.ts',
  'src/composables/useCardMenuActions.ts',
  'src/composables/useCardNotes.ts',
  'src/composables/useCardSwipe.ts',
  'src/composables/useCardMove.ts',
  'src/composables/useCardTouchLift.ts',
  'src/composables/useCardKeys.ts',
  'src/composables/useCardPointer.ts',
]

/** MessageCard.vue, then every composable it was split into, one string. */
export function messageCardSrc() {
  return MESSAGE_CARD_FILES.map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
}
