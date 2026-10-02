/**
 * A role id's display label in the current locale, or the raw id when it has
 * no catalogue entry (a custom role).
 *
 * One copy for the member list (TenantUsers.vue) and the edit pane
 * (UserEditPane.vue), which carried byte-identical twins.
 */
import { roleLabelKey } from '~/utils/access.mjs'

export function useRoleName() {
  const { t, te } = useI18n({ useScope: 'global' })
  return function roleName(id: string) {
    const key = roleLabelKey(id)
    return key && te(key) ? t(key) : id
  }
}
