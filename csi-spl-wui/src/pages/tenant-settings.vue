<!-- /tenant-settings (SPL-1037, specs/046): the tenant's settings for its
     admins and biz_owners, the SAME layout and behaviour as the personal
     Settings (owner 2026-09-28: "the UI should behave similarly to how the
     personal settings work"): a left nav of sections, the selected section on
     the right, each its own child route; at <= 820 px the list is level 2 and
     a section opens full width at level 3. A section shows only when
     /v1/view/me lists its permission; the hub answers 403 to anyone else on
     every route (046 §3). -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 id="tenant-settings-h">{{ heading }}</h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body settings-page" data-test="tenant-settings">
      <p v-if="session.state === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <p v-else-if="signedIn && accessReady && !sections.length" class="muted" role="alert" data-test="tenant-settings-forbidden">
        {{ t('tenant_settings.forbidden') }}
      </p>
      <div v-else-if="signedIn" class="settings-layout" :class="{ 'settings-layout--list': !active }">
        <nav class="settings-nav" :aria-label="t('tenant_settings.nav_label')" data-test="tenant-settings-nav">
          <ul>
            <li v-for="s in sections" :key="s.id">
              <NuxtLink
                :to="localePath('/tenant-settings/' + s.id)"
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': active === s.id }"
                :aria-current="active === s.id ? 'page' : undefined"
                :data-test="'tenant-settings-nav-' + s.id"
              >{{ t(s.label) }}<UiIcon v-if="stack.isMobile.value" name="chevron-left" :size="18" class="settings-nav__chev" /></NuxtLink>
            </li>
          </ul>
        </nav>
        <div class="settings-content" data-test="tenant-settings-content">
          <NuxtPage />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useMobileStack } from '~/composables/useMobileStack'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { tenantSettingsSections, tenantSettingsSectionOf } from '~/utils/tenant-settings-nav.mjs'

const session = useSessionStore()
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const access = useAccessStore()
const signedIn = computed(() => (session.state === 'in' && !!session.claims) || api.mock)
const accessReady = ref(false)
watch(signedIn, (v) => { if (v) void access.load().finally(() => { accessReady.value = true }) }, { immediate: true })
const sections = computed(() => tenantSettingsSections(access.me, { mock: api.mock }))
const active = computed(() => tenantSettingsSectionOf(route.path))
const stack = useMobileStack()
/* on a phone the open section names the page; the desktop keeps "Settings" */
const heading = computed(() => {
  const s = stack.isMobile.value && sections.value.find((x) => x.id === active.value)
  return s ? t(s.label) : t('tenant_settings.title')
})
/* a section open on a phone is level 3; Back from a deep link, which has
   no list entry below it in history, replaces the section with the list.
   It reads the ROUTER's route: that one has moved when router.afterEach
   tags the new history entry, the page's useRoute() only later - and a
   level that rises after the tag is pushed as an extra entry, so browser
   Back would stay on the section. */
const router = useRouter()
stack.rightPanel(
  () => stack.isMobile.value && tenantSettingsSectionOf(router.currentRoute.value.path) !== '',
  /* close runs inside a popstate whose (same-URL) navigation the router is
     still finishing, and that navigation swallows a replace started now:
     replace once it has finished (or after 250 ms when no popstate came) */
  () => {
    let done = false
    const go = () => {
      if (done) return
      done = true
      off()
      void navigateTo(localePath('/tenant-settings'), { replace: true })
    }
    const off = router.afterEach(() => { setTimeout(go, 0) })
    setTimeout(go, 250)
  },
)
</script>

<style scoped>
.settings-layout {
  display: grid;
  grid-template-columns: minmax(160px, 220px) minmax(0, 1fr);
  gap: 24px;
  align-items: start;
  min-width: 0;
}
.settings-nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.settings-nav__link {
  display: flex;
  align-items: center;
  min-height: 36px;
  padding: 6px 12px;
  border-radius: var(--radius-sm, 8px);
  border-inline-start: 3px solid transparent;
  color: var(--color-text);
  text-decoration: none;
  overflow-wrap: anywhere;
}
.settings-nav__link:hover { background: var(--color-bg-2); }
/* CLE-3427: the active nav item is a SELECTED item — a step DARKER than the
   hover fill, and its 3px edge is the one ring colour the whole WUI uses. */
.settings-nav__link--active {
  background: var(--color-selected);
  border-inline-start-color: var(--focus-ring);
  font-weight: 600;
}
.settings-content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
/* SPL-993: phones and small tablets. /settings is the list, full width, one
   44 px row per section; an open section hides the list. */
@media (max-width: 820px) {
  .settings-layout { grid-template-columns: minmax(0, 1fr); gap: 12px; }
  .settings-layout:not(.settings-layout--list) .settings-nav { display: none; }
  .settings-layout--list .settings-content { display: none; }
  .settings-nav ul { gap: 4px; }
  .settings-nav__link {
    justify-content: space-between;
    gap: 8px;
    min-height: var(--tap, 44px);
    padding: 8px 12px;
    border: 1px solid var(--color-border);
    background: var(--color-bg-2);
  }
  .settings-nav__chev { flex: none; color: var(--color-muted); transform: scaleX(-1); }
  .settings-nav__chev:dir(rtl) { transform: none; }
  .settings-content :deep(input),
  .settings-content :deep(textarea),
  .settings-content :deep(select) { font-size: max(16px, 1rem); }
}
</style>
