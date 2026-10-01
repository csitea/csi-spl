<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
  <LazyTenantNotMember v-if="tenantNotMember.tenant" />
  <!-- SPL-1006: a newer deploy while a draft is open; eager, never Lazy -->
  <BuildUpdateBar />
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { hostTenant } from '~/composables/useSpoolApi'
import { tabTitle, tenantTabName, unreadTotal, withUnread } from '~/utils/tab-title.mjs'
import { useNotificationStore } from '~/stores/notification'
import { loadMutedChannels } from '~/utils/notify.mjs'
import { parseCloseButtons } from '~/utils/view-prefs.mjs'

// Site-wide head, shaped like the donor WUI's app.vue: the version stamp is a
// <meta name="version"> so a deployed page says which build it is without a
// fetch, and the document lang/dir + hreflang alternates come from
// useLocaleHead exactly as the donor does (spec 021). The rest of the SEO
// shell is left out on purpose — the WUI is noindex.
const appVersion = String(useRuntimeConfig().public.appVersion || '')
/* SPL-959: set by plugins/tenant-host.client.ts on a tenant host the viewer is not a member of */
const tenantNotMember = useState<{ tenant: string, home: string, pending?: string }>('tenant-host-not-member', () => ({ tenant: '', home: '', pending: '' }))

const { locale } = useI18n({ useScope: 'global' })

const rtlLocales: Record<string, true> = { he: true }

// @nuxtjs/i18n v9: options are { dir, lang, seo, key } — not the v8 add* names.
const i18nHead = useLocaleHead({
  dir: true,
  lang: true,
  seo: true,
})

function docDir(): 'ltr' | 'rtl' {
  const fromI18n = i18nHead.value.htmlAttrs?.dir
  if (fromI18n === 'rtl' || fromI18n === 'ltr') return fromI18n
  return rtlLocales[locale.value] ? 'rtl' : 'ltr'
}

/* Owner (topic d1f76e76): the tab reads "<tenant display name>.spool-hub";
   the apex tenant is plain "spool-hub". A page's own title stays in front. */
const session = useSessionStore()
const apexTenant = String(useRuntimeConfig().public.tenant || '')
const tabName = computed(() => tenantTabName(session.claims, (import.meta.client && hostTenant()) || apexTenant, apexTenant))

const notes = useNotificationStore()
const unreadCount = computed(() => (import.meta.client ? unreadTotal(notes.unread, loadMutedChannels()) : 0))

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
    link: [...(i18nHead.value.link || [])],
    meta: appVersion ? [{ name: 'version', content: appVersion }] : [],
  }
})
</script>
