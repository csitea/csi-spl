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
 * 047 B5 (SPL-1161): a hop goes only to a host that answers. A paid tenant's
 * host is provisioned after the payment (workflow 40: custom domain + DNS +
 * certificate, ~30 min), and a hop before that lands on NXDOMAIN. So each
 * hop to another host first reads <host>/build.json (no-cors: reaching it is
 * the answer). Not reachable: the sign-in return (1) stays where it is, and a
 * signed-in hop (2, 3) shows "your address is being prepared" and retries
 * every PENDING_POLL_MS. The page's CSP admits only the mapped tenant hosts,
 * so an unmapped host is refused before DNS; the WUI re-deploy that maps it
 * reloads an open tab (SPL-1006 build watch), and the retry then gets through.
 */
import { watch } from 'vue'
import { apiBaseFor, validTenant } from './tenant.mjs'
import { setLinkSite } from './link-target.mjs'
import { homeTenant, oldLinkId, tenantParamHop, tenantUrl } from './tenant-host.mjs'

export const PENDING_POLL_MS = 30000
const PROBE_TIMEOUT_MS = 8000

/** true when url's host answers (any response; no-cors, so reaching it is enough). */
export async function hostAnswers(url, fetchFn = globalThis.fetch) {
  let origin
  try {
    origin = new URL(String(url || '')).origin
  } catch {
    return false
  }
  const ctl = typeof AbortController === 'function' ? new AbortController() : null
  const timer = ctl ? setTimeout(() => ctl.abort(), PROBE_TIMEOUT_MS) : null
  try {
    await fetchFn(`${origin}/build.json`, { mode: 'no-cors', cache: 'no-store', credentials: 'omit', signal: ctl?.signal })
    return true
  } catch {
    return false
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * The session's active tenant `t` when it is not the page's and the claims
 * carry no `tenants` list. A native sign-in adopts the login answer's claims,
 * which name `t` but not the list (GET /session adds it), so right after a
 * buyer signs in on the apex homeTenant() has nothing to go on (measured on
 * dev 2026-09-30, b5paid1: t=b5paid1, tenants=[]). A list, when present, is
 * the authority: then this answers ''.
 */
export function activeElsewhere(claims, page) {
  const c = claims && typeof claims === 'object' ? claims : {}
  if (Array.isArray(c.tenants) && c.tenants.length) return ''
  const t = typeof c.t === 'string' ? c.t.trim() : ''
  return validTenant(t) && t !== page ? t : ''
}

export function bootTenantHost({ pub, page, session, notMember, win = window, fetchFn = globalThis.fetch, pollMs = PENDING_POLL_MS }) {
  const site = String(pub.siteUrl || '')
  const apex = String(pub.tenant || '')
  const apexOrigin = tenantUrl(apex, site, apex, '/').replace(/\/$/, '')
  setLinkSite(site)
  /** Hop to url when its host answers (the apex always does). */
  const answers = (url) => (apexOrigin && String(url).startsWith(apexOrigin + '/')) ? Promise.resolve(true) : hostAnswers(url, fetchFn)

  /** A signed-in hop: go now, or say the address is being prepared and retry. */
  async function hopWhenReady(url, tenant) {
    if (await answers(url)) {
      win.location.replace(url)
      return
    }
    notMember.value = { tenant, home: '', pending: new URL(url).host }
    const tick = async () => {
      if (await answers(url)) {
        win.location.replace(url)
        return
      }
      win.setTimeout(tick, pollMs)
    }
    win.setTimeout(tick, pollMs)
  }

  const hop = tenantParamHop(win.location.href, site, apex)
  if (hop) {
    /* the sign-in return: to a host that is not up yet it stays here, and the
       session watch below says why once the viewer is signed in */
    void answers(hop).then((ok) => (ok ? win.location.replace(hop) : watchSession()))
    return
  }
  watchSession()

  function watchSession() {
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
          await hopWhenReady(tenantUrl(owner, site, apex, here()), owner)
          return
        }
      }
      const home = homeTenant(session.claims, page) || activeElsewhere(session.claims, page)
      if (!home) return
      if (page === apex) {
        await hopWhenReady(tenantUrl(home, site, apex, '/'), home)
        return
      }
      notMember.value = { tenant: page, home: tenantUrl(home, site, apex, '/'), pending: '' }
    }, { immediate: true })
  }
}
