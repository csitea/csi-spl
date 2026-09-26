// A signed-in human's stored colour theme wins once per tab.
// 'light' is the light-blue palette. After that the palette picker is free
// to change it, and a reload does not undo that choice.
import { useSessionStore } from '~/stores/session'
import { useTheme } from '~/composables/useTheme'
import { parseTheme, THEME_IDS } from '~/utils/theme.mjs'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const session = useSessionStore()
  const { theme, setTheme } = useTheme()
  let applied = false
  const MARK = 'csi-spl-pref-theme-applied'
  const read = () => { try { return sessionStorage.getItem(MARK) || '' } catch { return '' } }
  const mark = (v: string) => { try { sessionStorage.setItem(MARK, v) } catch { /* private mode */ } }

  watch(
    () => [session.state, session.claims?.preferred_theme] as const,
    ([state, pref]) => {
      if (applied || state !== 'in') return
      applied = true
      const who = String(session.claims?.hum || session.claims?.email || 'in')
      if (read() === who) return
      mark(who)
      const want = String(pref || '')
      if (!want || !(THEME_IDS as readonly string[]).includes(want) || want === theme.value) return
      setTheme(parseTheme(want))
    },
    { immediate: true },
  )
})
