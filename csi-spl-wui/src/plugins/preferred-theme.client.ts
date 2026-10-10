// A signed-in human's stored colour theme wins once per tab, unless they
// picked one on the sign-in page: that pick stays and goes to the account.
// 'light' is the light-blue palette. After that the palette picker is free
// to change it, and a reload does not undo that choice.
// The plugin is client-only by file suffix: Nuxt loads a *.client.ts plugin
// only in the client bundle, so an import.meta.client guard here is dead.
import { useSessionStore } from '~/stores/session'
import { useTheme } from '~/composables/useTheme'
import { useAuthClient } from '~/composables/useAuthClient'
import { parseTheme, saveThemeToAccount, takeSignedOutPick, THEME_IDS } from '~/utils/theme.mjs'

const MARK = 'csi-spl-pref-theme-applied'

export default defineNuxtPlugin(() => {
  const session = useSessionStore()
  const { theme, setTheme } = useTheme()
  const auth = useAuthClient()
  let applied = false
  const read = () => { try { return sessionStorage.getItem(MARK) || '' } catch { return '' } }
  const mark = (v: string) => { try { sessionStorage.setItem(MARK, v) } catch { /* private mode */ } }

  watch(
    () => [session.state, session.claims?.preferred_theme] as const,
    ([state, pref]) => {
      if (applied || state !== 'in') return
      applied = true
      const who = String(session.claims?.hum || session.claims?.email || 'in')
      if (takeSignedOutPick()) {
        mark(who)
        void saveThemeToAccount(theme.value, {
          claims: session.claims,
          save: (t) => auth.saveTheme(t),
          apply: (t) => session.setPreferredTheme(t),
        })
        return
      }
      if (read() === who) return
      mark(who)
      const want = String(pref || '')
      if (!want || !(THEME_IDS as readonly string[]).includes(want) || want === theme.value) return
      setTheme(parseTheme(want))
    },
    { immediate: true },
  )
})
