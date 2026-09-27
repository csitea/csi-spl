/**
 * The tenant switch (specs/026 §6), shared by the sidebar's drop box (desktop)
 * and the phone top bar's tenant sheet (SPL-995). The hub re-issues the
 * session cookie; a full load then reads every feed of the new tenant (no
 * store keeps the old tenant's rows). A refusal keeps the old tenant.
 */
import { tenantHint, tenantSwitchOptions } from '~/utils/tenant-switcher.mjs'
import { useSessionStore } from '~/stores/session'
import { tenantHostUrl } from '~/composables/useSpoolApi'
import { switchPath } from '~/utils/tenant-host.mjs'
import { useAuthClient } from '~/composables/useAuthClient'

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

  /** false when nothing switched (the caller shows the old tenant again) */
  async function switchTo(want: string): Promise<boolean> {
    const b = box.value
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
