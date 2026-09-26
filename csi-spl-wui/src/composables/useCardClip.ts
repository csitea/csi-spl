import {
  CARD_CLIP_DEFAULT,
  CARD_CLIP_DEFAULT_KEY,
  cardClipKey,
  parseCardClipMode,
  readCardClipDefault,
  readCardClipSession,
  readEffectiveCardClip,
  writeCardClipDefault,
  writeCardClipSession,
} from '~/utils/card-clip.mjs'

export type CardClipMode = 'titles' | 'rows' | 'full'

export type CardClipPane = 'msgs' | 'thread'

/**
 * The appearance-page default for list height. It is kept in this browser
 * and is what a fresh sign-in starts from.
 */
export function useCardClipDefault() {
  const mode = useState<CardClipMode>(CARD_CLIP_DEFAULT_KEY, () => CARD_CLIP_DEFAULT as CardClipMode)
  const hydrated = useState<boolean>(CARD_CLIP_DEFAULT_KEY + '-hydrated', () => false)

  function setDefault(next: string) {
    const m = parseCardClipMode(next) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipDefault(m)
  }

  onMounted(() => {
    if (hydrated.value) return
    hydrated.value = true
    mode.value = readCardClipDefault() as CardClipMode
  })

  return { mode, setDefault }
}

/**
 * A pane's card height for this sign-in. The header control writes a
 * session override; a pane with none follows the appearance default.
 * The server render paints the built-in default; the stored choice is
 * read on mount.
 */
export function useCardClip(pane: CardClipPane = 'msgs') {
  const key = cardClipKey(pane)
  const mode = useState<CardClipMode>(key, () => CARD_CLIP_DEFAULT as CardClipMode)
  const hydrated = useState<boolean>(key + '-hydrated', () => false)
  const fallback = useState<CardClipMode>(CARD_CLIP_DEFAULT_KEY, () => CARD_CLIP_DEFAULT as CardClipMode)

  function setMode(next: string) {
    const m = parseCardClipMode(next) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipSession(m, pane)
  }

  onMounted(() => {
    if (hydrated.value) return
    hydrated.value = true
    fallback.value = readCardClipDefault() as CardClipMode
    mode.value = readEffectiveCardClip(pane) as CardClipMode
  })

  watch(fallback, (d) => {
    if (import.meta.client && readCardClipSession(pane)) return
    mode.value = d
  })

  return { mode, setMode }
}
