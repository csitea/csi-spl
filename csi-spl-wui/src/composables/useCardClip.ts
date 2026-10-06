import {
  cardClipBuiltinDefault,
  cardClipDefaultKey,
  cardClipKey,
  migrateCardClip,
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
 * One pane's appearance-page default for list height. It is kept in this
 * browser and is what a fresh sign-in starts from for that pane.
 */
export function useCardClipDefault(pane: CardClipPane = 'msgs') {
  const key = cardClipDefaultKey(pane)
  const builtin = cardClipBuiltinDefault(pane) as CardClipMode
  const mode = useState<CardClipMode>(key, () => builtin)
  const hydrated = useState<boolean>(key + '-hydrated', () => false)

  function setDefault(next: string) {
    const m = parseCardClipMode(next, builtin) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipDefault(m, undefined, pane)
  }

  onMounted(() => {
    if (import.meta.client) migrateCardClip()
    mode.value = readCardClipDefault(undefined, pane) as CardClipMode
    hydrated.value = true
  })

  return { mode, setDefault }
}

/**
 * A pane's card height for this sign-in. The header control writes a
 * session override; a pane with none follows that pane's appearance default.
 * The server render paints the built-in default; the stored choice is
 * read on mount.
 */
export function useCardClip(pane: CardClipPane = 'msgs') {
  const key = cardClipKey(pane)
  const builtin = cardClipBuiltinDefault(pane) as CardClipMode
  const mode = useState<CardClipMode>(key, () => builtin)
  const hydrated = useState<boolean>(key + '-hydrated', () => false)
  const fallback = useState<CardClipMode>(cardClipDefaultKey(pane), () => builtin)

  function setMode(next: string) {
    const m = parseCardClipMode(next) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipSession(m, pane)
  }

  onMounted(() => {
    if (import.meta.client) migrateCardClip()
    fallback.value = readCardClipDefault(undefined, pane) as CardClipMode
    mode.value = readEffectiveCardClip(pane) as CardClipMode
    hydrated.value = true
  })

  watch(fallback, (d) => {
    if (import.meta.client && readCardClipSession(pane)) return
    mode.value = d
  })

  return { mode, setMode }
}
