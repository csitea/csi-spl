import { authErrorKey, nativeErrorKey } from '~/utils/auth-client.mjs'
import type { CopyKey, NativeResult } from '~/utils/auth-client.mjs'

/**
 * spec 021: the auth copy of utils/auth-client.mjs, rendered in the active
 * locale. '' when there is nothing to say (no error code).
 */
export function useAuthCopy() {
  const { t } = useI18n({ useScope: 'global' })
  const render = (k: CopyKey | null) => (k ? t(k.key, k.params) : '')
  return {
    authError: (code: string) => render(authErrorKey(code)),
    nativeError: (out: Partial<NativeResult> | null) => render(nativeErrorKey(out)),
  }
}
