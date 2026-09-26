import { CARD_CLIP_DEFAULT, cardClipKey, parseCardClipMode, readCardClipMode, writeCardClipMode } from '~/utils/card-clip.mjs'

export type CardClipMode = 'titles' | 'rows' | 'full'

export type CardClipPane = 'msgs' | 'thread'

/**
 * CLE-34989 — a pane's card height mode, one value for the whole tab
 * (every middle-pane surface shows the same control and reads the same mode),
 * kept per browser. The server render always paints the default; the stored
 * mode is read on mount, so hydration never disagrees with the HTML.
 * SPL-945: the thread pane (`thread`) has its own mode beside the middle
 * pane's (`msgs`).
 */
export function useCardClip(pane: CardClipPane = 'msgs') {
  const key = cardClipKey(pane)
  const mode = useState<CardClipMode>(key, () => CARD_CLIP_DEFAULT as CardClipMode)
  const hydrated = useState<boolean>(key + '-hydrated', () => false)

  function setMode(next: string) {
    const m = parseCardClipMode(next) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipMode(m, undefined, pane)
  }

  onMounted(() => {
    if (hydrated.value) return
    hydrated.value = true
    mode.value = readCardClipMode(undefined, pane) as CardClipMode
  })

  return { mode, setMode }
}
