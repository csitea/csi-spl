// r18-04: the member edit actions of the user edit pane, moved out of
// UserEditPane.vue.
//
// Each action guards on the selected member (or invite), then runs its hub
// call through the pane's busy/error wrapper `run`, reports the change so the
// list reloads on the same row, and says what happened in `notice`. The pane
// keeps the refs, the reset watch, `run` and the invite actions; it passes
// them here as one options object.
import type { ComputedRef, Ref } from 'vue'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useAuthClient } from '~/composables/useAuthClient'
import { accessDateOf, accessUntilOfDate } from '~/utils/tenant-users.mjs'
import type { UserInvite, UserMember } from '~/utils/tenant-users.mjs'

interface EditForm {
  memberRole: Ref<string>
  profileName: Ref<string>
  profileLocale: Ref<string>
  accessDay: Ref<string>
  confirmOpen: Ref<boolean>
}

interface EditOpts {
  api: ReturnType<typeof useSpoolApi>
  auth: ReturnType<typeof useAuthClient>
  member: ComputedRef<UserMember | null>
  invite: ComputedRef<UserInvite | null>
  form: EditForm
  /** The pane's busy/error wrapper: one job at a time, a failure in words. */
  run: (job: () => Promise<void>) => Promise<void>
  /** Reload the list and select `key` ('' = nothing). */
  changed: (key: string) => void
  notice: Ref<string>
}

type Translate = ReturnType<typeof useI18n>['t']

/* role, profile and suspend: a patch of the member, then its reloaded row */
function memberSaves(o: EditOpts, t: Translate) {
  const { api, member, form, run, changed, notice } = o
  function saveRole() {
    const m = member.value
    if (!m) return
    void run(async () => {
      await api.setTenantUserRole(m.humanId, form.memberRole.value, m.role)
      changed(m.key)
      notice.value = t('users.role_saved')
    })
  }

  function saveProfile() {
    const m = member.value
    if (!m) return
    const patch: { display_name?: string, locale?: string } = {}
    if (form.profileName.value.trim() !== m.displayName) patch.display_name = form.profileName.value.trim()
    if (form.profileLocale.value) patch.locale = form.profileLocale.value
    void run(async () => {
      await api.patchTenantUser(m.humanId, patch)
      changed(m.key)
      notice.value = t('users.profile_saved')
    })
  }

  function toggleSuspend() {
    const m = member.value
    if (!m) return
    void run(async () => {
      await api.patchTenantUser(m.humanId, { disabled: !m.suspended })
      changed(m.key)
      notice.value = m.suspended ? t('users.restored') : t('users.suspended_notice')
    })
  }
  return { saveRole, saveProfile, toggleSuspend }
}

/* spec 072 A27: the member's access end date */
function memberAccess(o: EditOpts, t: Translate) {
  const { api, member, form, run, changed, notice } = o
  // The reloaded row keeps its key, so the date follows its access_until here.
  watch(() => member.value?.accessUntil, (v) => { form.accessDay.value = accessDateOf(v || '') })

  // spec 072 A27: end the member's access here after the chosen local day.
  function saveAccess() {
    const m = member.value
    const until = accessUntilOfDate(form.accessDay.value)
    if (!m || !until) return
    void run(async () => {
      await api.patchTenantUser(m.humanId, { access_until: until })
      changed(m.key)
      notice.value = t('users.access_saved', { date: form.accessDay.value })
    })
  }

  function clearAccess() {
    const m = member.value
    if (!m) return
    void run(async () => {
      await api.patchTenantUser(m.humanId, { access_until: null })
      changed(m.key)
      notice.value = t('users.access_cleared')
    })
  }
  return { saveAccess, clearAccess }
}

export function useUserEditActions(o: EditOpts) {
  const { t } = useI18n({ useScope: 'global' })
  const localePath = useLocalePath()
  const { api, auth, member, invite, form, run, changed } = o

  // specs/054: start acting as this member. On success THIS browser's cookie is
  // the clone, so a full reload re-inits every store as the clone and the
  // "Acting as X" banner shows. The hub 403s a target above the ceiling.
  function actAs() {
    const m = member.value
    if (!m) return
    void run(async () => {
      const res = await auth.actAsStart(m.humanId)
      if (!res.ok) throw { token: res.error || 'unavailable' }
      if (import.meta.client) window.location.assign(localePath('/lobby'))
    })
  }

  function destroy() {
    const m = member.value
    const i = invite.value
    void run(async () => {
      if (m) await api.removeTenantUser(m.humanId)
      else if (i) await api.revokeTenantInvite(i.email)
      form.confirmOpen.value = false
      changed('')
    })
    form.confirmOpen.value = false
  }

  return { ...memberSaves(o, t), ...memberAccess(o, t), actAs, destroy }
}
