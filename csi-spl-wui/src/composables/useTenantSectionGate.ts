/**
 * SPL-4452 (row 4 of SPL-4422): a Tenant settings section reads its
 * admin-only route only once /v1/view/me says the caller holds the
 * section's permission. Before, each section read on mount, and a member
 * who opened it by URL got the hub's 403 and a console line per read.
 *
 * `id` is the section's id in TENANT_SETTINGS_SECTIONS, whose `perm` (or one
 * of its `also`, spec 107 FR-41) the hub checks on that section's routes. `onAllowed` runs each time the session
 * is in (or the mock) and the caller may read; `denied` is true once me()
 * answered without the permission, for the no-access line. Like the access
 * store it fails open: no me() answer reads, and the hub's 403 decides.
 */
import { computed, ref, watch } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { TENANT_SETTINGS_SECTIONS } from '~/utils/tenant-settings-nav'

export function useTenantSectionGate(id: string, onAllowed?: () => void) {
  const api = useSpoolApi()
  const session = useSessionStore()
  const access = useAccessStore()
  const sec = TENANT_SETTINGS_SECTIONS.find((s) => s.id === id)
  const perms = sec ? [sec.perm, ...(sec.also || [])] : ['']
  const may = () => perms.some((p) => access.can(p))
  const ready = ref(false)
  const allowed = computed(() => ready.value && may())
  const denied = computed(() => ready.value && !may())
  watch(() => session.state, (st) => {
    if (st !== 'in' && !api.mock) return
    void access.load().finally(() => {
      ready.value = true
      if (may()) onAllowed?.()
    })
  }, { immediate: true })
  return { allowed, denied }
}
