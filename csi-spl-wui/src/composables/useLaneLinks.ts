// SPL-4798 (owner HUM-10, t1 0c2d08a2, msg ea369ab0): a lane row's discussion,
// issue and dispatch task as links on Monitoring -> Lanes and -> Topics. The
// row gives a typed ref (utils/monitoring-lanes.mjs laneTopicRef /
// laneIssueRef); where it opens is note-links.mjs noteLinkHref, the one
// renderer of `type:id` objects (how-to-post.md rule 11): on its workspace's
// host, or text when no host is known. The context is NoteLinks.vue's.
import { useSessionStore } from '~/stores/session'
import { hostTenant, useSpoolApi } from '~/composables/useSpoolApi'
import { noteLinkHref, type NoteLinkRef } from '~/utils/note-links.mjs'

export type LaneLink = { href: string, external: boolean, here: boolean, path: string }
const NONE: LaneLink = { href: '', external: false, here: false, path: '' }

export function useLaneLinks() {
  const session = useSessionStore()
  const api = useSpoolApi()
  const localePath = useLocalePath()
  const pub = useRuntimeConfig().public
  /* the page's workspace (its host, else the client's, else the session's) */
  const pageTenant = computed(() => hostTenant() || String(api.tenant || '') || String(session.claims?.t || ''))
  const ctx = computed(() => ({
    tenant: pageTenant.value,
    siteUrl: String(pub.tenantHosts || '0') === '1' ? String(pub.siteUrl || '') : '',
    apexTenant: String(pub.tenant || ''),
    pageOrigin: import.meta.client ? window.location.origin : '',
    pathFor: (p: string) => localePath(p),
  }))
  /** Where a ref opens; href '' = shown as text. A link here goes through the router (`path`). */
  function linkOf(ref: NoteLinkRef | null): LaneLink {
    return ref ? noteLinkHref(ref, ctx.value) : NONE
  }
  return { pageTenant, linkOf }
}
