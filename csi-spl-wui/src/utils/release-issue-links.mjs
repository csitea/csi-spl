/**
 * The issue and discussion links of one release note (SPL-4789; owner
 * HUM-10, t1 ef94396b msg 61bf7791: "at least 1 link for an issue ... and at
 * least 1 discussion where this issue originated from and the links must be
 * clickable"). The hub answers each note with issues[]:
 *
 *   { key, tenant, found, member, discussions: [{ task_id?, title?, state?, can_open }] }
 *
 * tenant is the workspace that OWNS the issue (t1 for this repo), not the
 * viewer's. A discussion carries task_id and title only when the viewer may
 * open it there. A note with no issue that resolves to a discussion is
 * "unknown" (msg dd164168: the older commits, from before the rule).
 *
 * Pure: the caller passes the page's workspace, the site URL (tenant hosts
 * on, else '') and the apex workspace, and pathFor (the locale path).
 */
import { tenantUrl } from './tenant-host.mjs'

/**
 * The href of path in tenant: the page's own path when it is the page's
 * workspace (or '' = the page's, as the mock answers), else the absolute URL
 * on the tenant's host; '' when there is none (tenant hosts off).
 * @param {string} tenant
 * @param {string} path
 * @param {{ pageTenant?: string, siteUrl?: string, apexTenant?: string, pathFor?: (p: string) => string }} ctx
 */
function hrefIn(tenant, path, ctx) {
  if (!tenant || tenant === ctx.pageTenant) {
    return { href: typeof ctx.pathFor === 'function' ? String(ctx.pathFor(path) || path) : path, external: false }
  }
  return { href: tenantUrl(tenant, String(ctx.siteUrl || ''), String(ctx.apexTenant || ''), path), external: true }
}

/**
 * The links to render, issues first, then each distinct discussion.
 * @param {unknown} issues the note's issues[]
 * @param {{ pageTenant?: string, siteUrl?: string, apexTenant?: string, pathFor?: (p: string) => string }} ctx
 * @returns {{ unknown: boolean, issues: { key: string, tenant: string, found: boolean, href: string, external: boolean }[],
 *   discussions: { id: string, key: string, tenant: string, title: string, canOpen: boolean, href: string, external: boolean }[] }}
 */
export function releaseIssueLinks(issues, ctx = {}) {
  const list = Array.isArray(issues) ? issues : []
  const out = { unknown: true, issues: [], discussions: [] }
  const seen = new Set()
  for (const raw of list) {
    const key = String(raw?.key || '')
    if (!key) continue
    const tenant = String(raw?.tenant || '')
    const found = raw?.found === true
    const ds = Array.isArray(raw?.discussions) ? raw.discussions : []
    if (found && ds.length) out.unknown = false
    const at = found ? hrefIn(tenant, '/issues?issue=' + encodeURIComponent(key), ctx) : { href: '', external: false }
    out.issues.push({ key, tenant, found, href: at.href, external: at.external })
    ds.forEach((d, i) => {
      const id = String(d?.task_id || '')
      const canOpen = d?.can_open === true && id !== ''
      const dedupe = canOpen ? 't:' + id : 'k:' + key + ':' + i
      if (seen.has(dedupe)) return
      seen.add(dedupe)
      const to = canOpen ? hrefIn(tenant, '/t/' + id, ctx) : { href: '', external: false }
      out.discussions.push({ id, key, tenant, title: canOpen ? String(d?.title || '') : '', canOpen, href: to.href, external: to.external })
    })
  }
  return out
}
