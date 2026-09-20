import {
  applyThemeAttr,
  nextTheme,
  parseTheme,
  readStoredTheme,
  writeStoredTheme,
  type SpoolTheme,
} from '~/utils/theme.mjs'

export type { SpoolTheme }

function apply(theme: SpoolTheme) {
  if (!import.meta.client) return
  applyThemeAttr(theme, document.documentElement)
  writeStoredTheme(theme)
}

export function useTheme() {
  const theme = useState<SpoolTheme>('spool-theme', () => 'dark')

  function setTheme(next: SpoolTheme) {
    const t = parseTheme(next)
    theme.value = t
    apply(t)
  }

  function toggle() {
    setTheme(nextTheme(theme.value))
  }

  function hydrate() {
    if (!import.meta.client) return
    setTheme(readStoredTheme())
  }

  return { theme, setTheme, toggle, hydrate }
}
