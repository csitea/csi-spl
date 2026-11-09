<!-- SPL-4789 (owner HUM-10, t1 ef94396b msg 61bf7791): a release note's
     issues and the discussions they came from, each a link into the
     workspace that owns them (release-issue-links.mjs). A link the viewer
     cannot open says so instead of linking; a note with neither shows
     "unknown" (msg dd164168: the older commits, from before the rule). -->
<template>
  <span class="ril" role="group" :aria-label="t('reporting.releases.links_label')" data-test="release-links">
    <span v-if="links.unknown && !links.issues.length" class="ril-chip ril-chip--unknown" :title="t('reporting.releases.links_unknown_title')" data-test="release-links-unknown">{{ t('reporting.releases.links_unknown') }}</span>
    <template v-for="i in links.issues" :key="'i' + i.key">
      <a
        v-if="i.href"
        class="ril-chip ril-chip--issue"
        :href="i.href"
        :target="i.external ? '_blank' : undefined"
        :rel="i.external ? 'noopener' : undefined"
        :title="t('reporting.releases.links_issue_title', { key: i.key, ws: wsName(i.tenant) })"
        data-test="release-links-issue"
        @click="go($event, i)"
      >{{ i.key }}</a>
      <span v-else-if="i.found" class="ril-chip ril-chip--plain" :title="t('reporting.releases.links_issue_title', { key: i.key, ws: wsName(i.tenant) })" data-test="release-links-issue-plain">{{ i.key }}</span>
      <span v-else class="ril-chip ril-chip--missing" :title="t('reporting.releases.links_issue_missing', { key: i.key, ws: wsName(i.tenant) })" data-test="release-links-issue-missing">{{ i.key }}</span>
    </template>
    <template v-for="(d, k) in links.discussions" :key="'d' + k">
      <a
        v-if="d.href"
        class="ril-chip ril-chip--topic"
        :href="d.href"
        :target="d.external ? '_blank' : undefined"
        :rel="d.external ? 'noopener' : undefined"
        :title="d.title || t('reporting.releases.links_discussion')"
        data-test="release-links-discussion"
        @click="go($event, d)"
      >{{ d.title || t('reporting.releases.links_discussion') }}</a>
      <span v-else-if="d.canOpen" class="ril-chip" :title="d.title" data-test="release-links-discussion-plain">{{ d.title || t('reporting.releases.links_discussion') }}</span>
      <span v-else-if="d.membersOnly" class="ril-chip ril-chip--locked" data-test="release-links-discussion-members-only">{{ t('issue_discussions.members_only') }}</span>
      <span v-else class="ril-chip ril-chip--locked" :title="t('reporting.releases.links_discussion_locked', { ws: wsName(d.tenant) })" data-test="release-links-discussion-locked">{{ t('reporting.releases.links_discussion_locked', { ws: wsName(d.tenant) }) }}</span>
    </template>
  </span>
</template>

<script setup lang="ts">
import { releaseIssueLinks } from '~/utils/release-issue-links.mjs'
import { hostTenant, useSpoolApi } from '~/composables/useSpoolApi'

const props = defineProps<{ issues?: unknown }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const pub = useRuntimeConfig().public
const api = useSpoolApi() as unknown as { tenant?: string }

const pageTenant = computed(() => hostTenant() || String(api.tenant || ''))
const links = computed(() => releaseIssueLinks(props.issues, {
  pageTenant: pageTenant.value,
  siteUrl: String(pub.tenantHosts || '0') === '1' ? String(pub.siteUrl || '') : '',
  apexTenant: String(pub.tenant || ''),
  pathFor: (p: string) => localePath(p),
}))
/* a workspace id as the reader sees it: this one needs no name */
const wsName = (ws: string) => ws || pageTenant.value

/* an in-app link opens through the router, a plain or modified click on another host stays a link */
function go(e: MouseEvent, l: { href: string, external: boolean }) {
  if (l.external || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
  e.preventDefault()
  void router.push(l.href)
}
</script>

<style scoped>
.ril { display: inline-flex; flex-wrap: wrap; align-items: baseline; gap: 4px 6px; min-width: 0; }
.ril-chip {
  display: inline-block; max-width: 100%; padding: 0 8px; border: 1px solid var(--color-border); border-radius: var(--radius-pill);
  font-size: 0.75rem; line-height: 1.5rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--color-fg); background: var(--color-bg-2);
}
.ril-chip--issue { font-family: var(--font-mono, ui-monospace, monospace); color: var(--color-accent); text-decoration: none; }
.ril-chip--topic { color: var(--color-accent); text-decoration: none; max-width: 22rem; }
.ril-chip--plain { font-family: var(--font-mono, ui-monospace, monospace); }
.ril-chip--missing { font-family: var(--font-mono, ui-monospace, monospace); color: var(--color-muted); text-decoration: line-through; }
.ril-chip--locked, .ril-chip--unknown { color: var(--color-muted); }
</style>
