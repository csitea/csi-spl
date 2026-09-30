// SPL-959 tenant hosts (owner option B, 2026-09-26), on by NUXT_PUBLIC_TENANT_HOSTS=1.
// The apex https://<fqdn> is the apex tenant (t1). Every other tenant is
// https://<tenant>.<fqdn>. The hops a host cannot make by itself live in
// utils/tenant-host-boot.mjs, loaded only when the feature is on: the
// initial chunk is at its 027 budget.
import { useSessionStore } from '~/stores/session'
import { hostTenant } from '~/composables/useSpoolApi'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const pub = useRuntimeConfig().public
  if (String(pub.tenantHosts || '0') !== '1') return
  const notMember = useState<{ tenant: string, home: string, pending?: string }>('tenant-host-not-member', () => ({ tenant: '', home: '', pending: '' }))
  const session = useSessionStore()
  const page = hostTenant()
  void import('~/utils/tenant-host-boot.mjs').then((m) => m.bootTenantHost({ pub, page, session, notMember }))
})
