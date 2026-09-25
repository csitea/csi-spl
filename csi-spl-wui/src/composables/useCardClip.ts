import { CARD_CLIP_DEFAULT, parseCardClipMode, readCardClipMode, writeCardClipMode } from '~/utils/card-clip.mjs'

export type CardClipMode = 'titles' | 'rows' | 'full'

/**
 * CLE-34989 — the middle pane's card height mode, one value for the whole tab
 * (every middle-pane surface shows the same control and reads the same mode),
 * kept per browser. The server render always paints the default; the stored
 * mode is read on mount, so hydration never disagrees with the HTML.
 */
export function useCardClip() {
  const mode = useState<CardClipMode>('spool-card-clip', () => CARD_CLIP_DEFAULT as CardClipMode)
  const hydrated = useState<boolean>('spool-card-clip-hydrated', () => false)

  function setMode(next: string) {
    const m = parseCardClipMode(next) as CardClipMode
    mode.value = m
    if (import.meta.client) writeCardClipMode(m)
  }

  onMounted(() => {
    if (hydrated.value) return
    hydrated.value = true
    mode.value = readCardClipMode() as CardClipMode
  })

  return { mode, setMode }
}
