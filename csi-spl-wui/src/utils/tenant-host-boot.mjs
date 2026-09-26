/**
 * SPL-959 tenant hosts: the hops on arrival (plugins/tenant-host.client.ts
 * loads this only when NUXT_PUBLIC_TENANT_HOSTS=1).
 *   1. apex + ?tenant=<t>: the sign-in return (the OAuth callbacks are
 *      registered on the apex) and a tenant-tagged link go to t's host.
 *   2. apex + an old link's topic / message uuid (?topic=, ?thread=, ?in=,
 *      /t/<uuid>) that belongs to another of the viewer's tenants: that
 *      tenant's host, same path (GET /v1/view/locate/{id}). An issue key on
 *      the apex keeps meaning t1.
 *   3. signed in, not a member of the page's tenant: on the apex, go to the
 *      last used tenant; on a tenant host, say "not a member" (never data:
 *      the hub answers 403 not_member either way).
 */
import { watch } from 'vue'
import { apiBaseFor } from './tenant.mjs'
import { setLinkSite } from './link-target.mjs'
import { homeTenant, oldLinkId, tenantParamHop, tenantUrl } from './tenant-host.mjs'

export function bootTenantHost({ pub, page, session, notMember, win = window, fetchFn = globalThis.fetch }) {
  const site = String(pub.siteUrl || '')
  const apex = String(pub.tenant || '')
  setLinkSite(site)
  const hop = tenantParamHop(win.location.href, site, apex)
  if (hop) {
    win.location.replace(hop)
    return
  }
  if (!page) return
  const here = () => win.location.pathname + win.location.search + win.location.hash

  async function locate(id) {
    const { base } = apiBaseFor(String(pub.apiBase || ''), page)
    if (!base) return ''
    try {
      const res = await fetchFn(`${base}/v1/view/locate/${id}`, { credentials: 'include', cache: 'no-store' })
      if (!res.ok) return ''
      const body = await res.json()
      return body && typeof body.tenant === 'string' ? body.tenant : ''
    } catch {
      return ''
    }
  }

  let done = false
  watch(() => session.state, async (state) => {
    if (state !== 'in' || done) return
    done = true
    if (page === apex) {
      const id = oldLinkId(here())
      const owner = id ? await locate(id) : ''
      if (owner && owner !== apex) {
        win.location.replace(tenantUrl(owner, site, apex, here()))
        return
      }
    }
    const home = homeTenant(session.claims, page)
    if (!home) return
    if (page === apex) {
      win.location.replace(tenantUrl(home, site, apex, '/'))
      return
    }
    notMember.value = { tenant: page, home: tenantUrl(home, site, apex, '/') }
  }, { immediate: true })
}
