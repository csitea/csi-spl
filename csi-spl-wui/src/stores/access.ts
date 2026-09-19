import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { accessAllows, normalizeMe, roleLabelKey } from '~/utils/access.mjs'

/**
 * specs/025 FR-008: the signed-in member's role and permissions in the active
 * tenant (GET /v1/view/me), loaded once per page life. It only HIDES actions;
 * the hub re-checks every write, so any failure leaves everything shown.
 */
export const useAccessStore = defineStore('access', () => {
  const api = useSpoolApi()
  const me = ref<ReturnType<typeof normalizeMe> | null>(null)
  let pending: Promise<void> | null = null

  function load(force = false) {
    if (pending && !force) return pending
    pending = (async () => {
      try {
        const body = await api.me()
        me.value = body ? normalizeMe(body) : null
      } catch {
        me.value = null
      }
    })()
    return pending
  }

  const can = (perm: string) => accessAllows(me.value, perm)
  const roleKey = computed(() => roleLabelKey(me.value?.role ?? null))

  return { me, load, can, roleKey }
})
