import {
  HIDDEN_CARDS_KEY,
  readHiddenCards,
  withHiddenIds,
  withoutHiddenIds,
  writeHiddenCards,
} from '~/utils/hidden-cards.mjs'

/**
 * HUM-10 (owner, t1 topics 6fc56905 / 3e073a95): the replies this viewer hid
 * by a swipe left, on this device (utils/hidden-cards.mjs). The server render
 * hides nothing; the stored list is read on mount.
 */
export function useHiddenCards() {
  const ids = useState<string[]>(HIDDEN_CARDS_KEY, () => [])
  const hydrated = useState<boolean>(HIDDEN_CARDS_KEY + '-hydrated', () => false)

  onMounted(() => {
    if (hydrated.value) return
    ids.value = readHiddenCards()
    hydrated.value = true
  })

  const set = computed(() => new Set(ids.value))

  function isHidden(id: string) {
    return Boolean(id) && set.value.has(id)
  }
  function hide(id: string) {
    if (!id) return
    ids.value = withHiddenIds(ids.value, [id])
    writeHiddenCards(ids.value)
  }
  function show(drop: string[]) {
    ids.value = withoutHiddenIds(ids.value, drop)
    writeHiddenCards(ids.value)
  }

  return { ids, isHidden, hide, show }
}
