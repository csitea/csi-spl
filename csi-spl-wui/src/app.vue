<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
  <LazyTenantNotMember v-if="tenantNotMember.tenant" />
  <!-- CLE-77853: Settings is a modal over whatever view is open (?settings=).
       CLE-77925: its own chunk, mounted the first time ?settings= appears and
       kept mounted after (close, focus return), not in the initial JS. -->
  <ClientOnly><LazySettingsDialog v-if="settingsMounted" /></ClientOnly>
  <!-- SPL-1006: a newer deploy while a draft is open; eager, never Lazy -->
  <BuildUpdateBar />
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { hostTenant } from '~/composables/useSpoolApi'
import { tabTitle, tenantTabName, withUnread } from '~/utils/tab-title.mjs'
import { useUnread } from '~/composables/useUnread'
import { loadMutedChannels } from '~/utils/notify.mjs'
import { parseCloseButtons } from '~/utils/view-prefs.mjs'
import { setTimeZoneSource } from '~/utils/date-iso.mjs'
import { settingsQuerySection } from '~/utils/settings-nav.mjs'
import { displayVersion } from '~/utils/display-version.mjs'

// Site-wide head, shaped like the donor WUI's app.vue: the version stamp is a
// <meta name="version"> so a deployed page says which build it is without a
// fetch, and the document lang/dir come from useLocaleHead (spec 021). The
// SEO shell is left out on purpose — the WUI is noindex, nofollow — and that
// now includes the 39 hreflang alternates + canonical link useLocaleHead's
// `seo` wrote into every document (perf round 3 P3-22: ~1.9 KB raw each).
const appVersion = String(useRuntimeConfig().public.appVersion || '')
/* SPL-959: set by plugins/tenant-host.client.ts on a tenant host the viewer is not a member of */
const tenantNotMember = useState<{ tenant: string, home: string, pending?: string }>('tenant-host-not-member', () => ({ tenant: '', home: '', pending: '' }))

const { locale } = useI18n({ useScope: 'global' })

const route = useRoute()
const settingsMounted = ref(false)
watch(() => settingsQuerySection(route.query as Record<string, unknown>) !== null, (open) => {
  if (open) settingsMounted.value = true
}, { immediate: true })

const rtlLocales: Record<string, true> = { he: true }

// @nuxtjs/i18n v9: options are { dir, lang, seo, key } — not the v8 add* names.
const i18nHead = useLocaleHead({
  dir: true,
  lang: true,
  seo: false,
})

function docDir(): 'ltr' | 'rtl' {
  const fromI18n = i18nHead.value.htmlAttrs?.dir
  if (fromI18n === 'rtl' || fromI18n === 'ltr') return fromI18n
  return rtlLocales[locale.value] ? 'rtl' : 'ltr'
}

/* Owner (topic d1f76e76): the tab reads "<tenant display name>.spool-hub";
   the apex tenant is plain "spool-hub". A page's own title stays in front. */
const session = useSessionStore()
/* CLE-77908: every printed time follows the person's zone for this workspace
   (Settings -> Appearance), else the browser's. A reactive read, so every
   clock re-renders the moment the zone changes. */
setTimeZoneSource(() => String(session.claims?.time_zone || ''))
const apexTenant = String(useRuntimeConfig().public.tenant || '')
const tabName = computed(() => tenantTabName(session.claims, (import.meta.client && hostTenant()) || apexTenant, apexTenant))

/* spec 079 FR-006 (Q1, Q2): the title's "(n)" is the sum of the row numbers
   the person can see, muted channels left out - one model with the rows and
   the rail, no longer the Flow total (that stays on the Flow badge). Each
   unread line sits on one channel or DM row; its topic row (t:) shows the
   same line again (flow-v1 section 2), so topic rows are not added twice. */
const unreadRows = useUnread()
const unreadCount = computed(() => {
  if (!import.meta.client) return 0
  let muted = 0
  for (const c of new Set(loadMutedChannels())) muted += unreadRows.rowOf('ch:' + c)
  return Math.max(0, unreadRows.section('channels') - muted) + unreadRows.section('dms')
})

useHead(() => {
  /* read here, not inside titleTemplate, so a new unread re-runs the head */
  const name = tabName.value
  const unread = unreadCount.value
  return {
    /* bug A: the unread total leads the tab title */
    titleTemplate: (page) => withUnread(tabTitle(page, name), unread),
    htmlAttrs: {
      lang: i18nHead.value.htmlAttrs?.lang || locale.value,
      dir: docDir(),
      /* SPL-1133: which corner the close buttons sit in (UiCloseButton) */
      'data-close-buttons': parseCloseButtons(session.claims?.close_buttons),
    },
    meta: appVersion ? [{ name: 'version', content: displayVersion(appVersion) }] : [],
  }
})
</script>
