export type SpoolTheme = 'dark' | 'light'

const KEY = 'spool-theme'

function apply(theme: SpoolTheme) {
  if (!import.meta.client) return
  document.documentElement.setAttribute('data-theme', theme)
  try {
    localStorage.setItem(KEY, theme)
  } catch {
    /* private mode */
  }
}

export function useTheme() {
  const theme = useState<SpoolTheme>('spool-theme', () => 'dark')

  function setTheme(next: SpoolTheme) {
    theme.value = next
    apply(next)
  }

  function toggle() {
    setTheme(theme.value === 'dark' ? 'light' : 'dark')
  }

  function hydrate() {
    if (!import.meta.client) return
    let next: SpoolTheme = 'dark'
    try {
      const stored = localStorage.getItem(KEY)
      if (stored === 'light' || stored === 'dark') next = stored
    } catch {
      /* ignore */
    }
    setTheme(next)
  }

  return { theme, setTheme, toggle, hydrate }
}
