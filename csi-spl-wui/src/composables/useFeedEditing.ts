import { inject, onUnmounted, provide, ref, watch, type InjectionKey, type Ref } from 'vue'

/**
 * SPL-5315: how many cards of one LiveFeed have their editor open.
 *
 * The owner (t1 ce99fef5): the phone thread arrow "is obsolete in editing
 * mode of a message because it gets in the way of the save button". The
 * arrow is LiveFeed's and the edit state is each MessageCard's own
 * (useCardEdit), so the feed provides a counter and every card under it
 * reports into it. A card outside any LiveFeed reports nowhere.
 */
const FEED_EDITING: InjectionKey<Ref<number>> = Symbol('feed-editing')

/** LiveFeed: the count of its cards that are being edited right now. */
export function provideFeedEditing(): Ref<number> {
  const open = ref(0)
  provide(FEED_EDITING, open)
  return open
}

/** MessageCard (via useCardEdit): count this card while its editor is open. */
export function reportCardEditing(editing: Ref<boolean>) {
  const open = inject(FEED_EDITING, null)
  if (!open) return
  let counted = false
  const set = (on: boolean) => {
    if (on === counted) return
    counted = on
    open.value += on ? 1 : -1
  }
  watch(editing, set, { immediate: true })
  /* a card unmounted mid-edit (a re-render, a delete) must not hold it hidden */
  onUnmounted(() => set(false))
}
