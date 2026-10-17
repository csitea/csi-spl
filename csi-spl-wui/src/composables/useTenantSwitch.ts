/**
 * The tenant switch (specs/026 §6), shared by the sidebar's drop box (desktop)
 * and the phone top bar's tenant sheet (SPL-995). The hub re-issues the
 * session cookie; a full load then reads every feed of the new tenant (no
 * store keeps the old tenant's rows). A refusal keeps the old tenant.
 */
import { getCurrentScope, onScopeDispose } from 'vue'
import { tenantHint, tenantSwitchOptions } from '~/utils/tenant-switcher.mjs'
import { useSessionStore } from '~/stores/session'
import { tenantHostUrl } from '~/composables/useSpoolApi'
import { switchPath } from '~/utils/tenant-host.mjs'
import { useAuthClient } from '~/composables/useAuthClient'

function mockSwitchLoads(): boolean {
  try { return Boolean(localStorage.getItem('spool.mock.tenant-switch-loads')) } catch { return false }
}

export function useTenantSwitch() {
  const session = useSessionStore()
  const api = useSpoolApi()
  const authClient = useAuthClient()
  const localePath = useLocalePath()
  const { t } = useI18n({ useScope: 'global' })
  const box = computed(() => tenantSwitchOptions(session.claims, api.tenant))
  const hint = computed(() => tenantHint(box.value, t))
  /* the selected row's name, '' when none is named */
  const name = computed(() => {
    const row = box.value.options.find((o: { id: string, label: string }) => o.id === box.value.selected)
    return (row && row.label) || box.value.selected || ''
  })
  const switching = ref(false)
  const failed = ref(false)
  /* SPL-2418 (owner HUM-10 789b9e6c, "still doesn't work"): the tab is back
     on this page without having left it - Back restored it from the
     bfcache (pageshow persisted), or the navigation took the tab away and
     brought it back (visible again). The switch is over: `switching` left
     true keeps every row disabled for good (prd 30b3c3e0a, 390 px touch,
     n=1: switch, Back -> all rows disabled, a tap did nothing). */
  if (import.meta.client) {
    const back = (e: Event) => {
      if (!switching.value) return
      if (e.type === 'pageshow' ? (e as PageTransitionEvent).persisted : document.visibilityState === 'visible') switching.value = false
    }
    window.addEventListener('pageshow', back)
    document.addEventListener('visibilitychange', back)
    if (getCurrentScope()) {
      onScopeDispose(() => {
        window.removeEventListener('pageshow', back)
        document.removeEventListener('visibilitychange', back)
      })
    }
  }

  /** false when nothing switched (the caller shows the old tenant again) */
  async function switchTo(want: string): Promise<boolean> {
    const b = box.value
    /* HUM-10: the mock has no hub - a switch re-points the local session
       (the switcher's e2e proves the pick reaches here), no reload. */
    if (api.mock && b.canSwitch && !switching.value && want && want !== b.selected && session.claims) {
      /* SPL-2399 e2e hook (mock only): with localStorage
         `spool.mock.tenant-switch-loads` set, the mock leaves the page like
         the hub does (switching stays true), so an e2e sees whether the
         load completes. */
      if (mockSwitchLoads()) {
        switching.value = true
        window.location.assign(localePath('/') + '?tenant=' + encodeURIComponent(want))
        return true
      }
      const next = { ...session.claims, active_tenant: want, t: want }
      session.adopt(next)
      return true
    }
    if (!b.canSwitch || api.mock || switching.value || !want || want === b.selected) return false
    switching.value = true
    failed.value = false
    /* SPL-959: with tenant hosts on, a tenant IS its host: go there, same
       path - unless the path names the old tenant's channel, DM or topic
       (CLE-35057: switchPath sends those to the home page). */
    const hostUrl = await tenantHostUrl(want, switchPath(window.location.pathname))
    if (hostUrl) {
      window.location.assign(hostUrl)
      return true
    }
    const out = await authClient.switchTenant(want)
    if (out.ok) {
      window.location.assign(localePath('/'))
      return true
    }
    switching.value = false
    failed.value = true
    return false
  }

  return { box, hint, name, switching, failed, switchTo }
}
