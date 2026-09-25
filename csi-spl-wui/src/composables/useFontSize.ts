import {
  applyFontSizeAttr,
  FONT_SIZE_DEFAULT,
  parseFontSize,
  readStoredFontSize,
  stepFontSize,
  writeStoredFontSize,
} from '~/utils/font-size.mjs'

function apply(level: number) {
  if (!import.meta.client) return
  applyFontSizeAttr(level, document.documentElement)
  writeStoredFontSize(level)
}

export function useFontSize() {
  const level = useState<number>('spool-font-size', () => FONT_SIZE_DEFAULT)

  function setLevel(next: number | string) {
    const n = parseFontSize(next)
    level.value = n
    apply(n)
  }

  function step(delta: number) {
    setLevel(stepFontSize(level.value, delta))
  }

  function hydrate() {
    if (!import.meta.client) return
    const n = readStoredFontSize()
    level.value = n
    applyFontSizeAttr(n, document.documentElement)
  }

  return { level, setLevel, step, hydrate }
}
