// r13-03: the composer's draft, one per place (spec 080 FR-001..FR-003),
// moved out of MessageComposer.vue.
//
// The page's omnibox target names its place (`ch:` / `dm:` / `t:`); a change
// of place keeps the text under the old one and brings back the new one's,
// typing keeps it (300 ms), and the box a send empties drops it - a failed
// send puts the text back (TopBar restore), which keeps it again. A search
// line is never a draft. Only the top-bar box keeps drafts.
import type { Ref } from 'vue'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSessionStore } from '~/stores/session'
import { draftPlaceOf, draftText, registerDraftSource, saveDraft } from '~/utils/drafts.mjs'
import { switchPaneOf } from '~/utils/sidebar-tabs.mjs'
import { omniboxMode } from '~/utils/search.mjs'
import type { ComposerProps } from '~/composables/composerProps'

const DRAFT_SAVE_MS = 300

interface DraftOpts {
  text: Ref<string>
  /** global: the top-bar box, the only one that keeps drafts */
  props: ComposerProps
  /** puts a stored draft into the field (the composer's setText) */
  setText: (s: string) => void
}

function isDraftText(s: string) {
  return omniboxMode(s) !== 'search' && switchPaneOf(s) === null
}

/** The 300 ms save timer: a later key wins, a flush runs the pending save now. */
function useDraftTimer() {
  let timer: ReturnType<typeof setTimeout> | null = null
  let pending: (() => void) | null = null
  function cancel() {
    if (timer) clearTimeout(timer)
    timer = null
    pending = null
  }
  function flush() {
    const run = pending
    cancel()
    run?.()
  }
  function queue(run: () => void) {
    pending = run
    timer = setTimeout(flush, DRAFT_SAVE_MS)
  }
  return { cancel, flush, queue, pending: () => pending }
}

export function useComposerDraft({ text, props, setText }: DraftOpts) {
  const omniboxTargets = useOmniboxStore()
  const session = useSessionStore()
  const draftPlace = computed(() => (props.global ? draftPlaceOf(omniboxTargets.target?.place?.() ?? '') : ''))
  const draftHuman = computed(() => String(session.claims?.hum || ''))
  /* what the store holds for this place: a load is not a save */
  let draftStored = ''
  const save = useDraftTimer()
  watch(text, (s) => {
    const human = draftHuman.value
    const place = draftPlace.value
    /* a later key wins: `/` then `/s` (a search) must not keep `/` */
    save.cancel()
    if (!import.meta.client || !human || !place || !isDraftText(s) || s === draftStored) return
    save.queue(() => {
      saveDraft(undefined, human, place, s)
      draftStored = s
    })
  })
  watch([draftPlace, draftHuman], ([place, human], [, oldHuman]) => {
    if (!import.meta.client || !props.global) return
    const s = text.value
    if (human === oldHuman) save.flush()
    /* signed out or another member: nothing more is written for the old one */
    else save.cancel()
    if (!isDraftText(s)) return
    /* the session arrived after the reader started typing: keep that text */
    if (!oldHuman && s) return
    draftStored = human && place ? draftText(undefined, human, place) : ''
    if (draftStored !== s) setText(draftStored)
  }, { immediate: true })
  onBeforeUnmount(save.flush)
  onBeforeUnmount(registerDraftSource(() => save.pending() && { human: draftHuman.value, place: draftPlace.value, text: text.value }))
}
