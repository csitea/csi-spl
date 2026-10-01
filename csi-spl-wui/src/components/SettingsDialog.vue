<!-- Settings (GitHub-style since specs/023 §3.4): a left nav of sections, the
     selected section on the right.
     CLE-77853 (bug 49568e8b; HUM-24: "profile, settings: there is no exit";
     owner pick "B. - a pop-up modal dialog - similar to the one of edit
     epic"): a large modal OVER the current view, the same UiDialog as the
     Edit epic/feature dialog. It closes with the X, Escape or a click outside,
     and focus goes back to where it was. Its state is ?settings=<section> on
     whatever route is open (utils/settings-nav.mjs), so the view behind keeps
     its scroll, open topic and drafts; a section change replaces that entry,
     so browser Back closes the modal. The old /settings[/<section>] addresses
     arrive here through middleware/settings-modal.global.ts.
     SPL-993: on a phone (<= 820 px) the bare ?settings= is the LIST of
     sections and a section opens full width with a "Settings" back row; at
     <= 600 px the dialog is a full-screen sheet that keeps its X (UiDialog
     `routed`). A settled signed-out session never reaches it: the shared
     redirect replaces the view with /login. -->
<template>
  <UiDialog :open="open" :title="heading" size="lg" routed @update:open="onOpen">
    <div class="settings-page" data-test="settings">
      <p v-if="session.state === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <template v-else-if="signedIn">
        <!-- CLE-35099: these settings are PER TENANT (rdb 0078). Say which
             tenant they apply to when the person belongs to more than one. -->
        <p v-if="perTenantNote" class="settings-tenant-note" data-test="settings-tenant-note">{{ perTenantNote }}</p>
      </template>
      <div v-if="signedIn" class="settings-layout" :class="{ 'settings-layout--list': !active }">
        <nav class="settings-nav" :aria-label="t('settings.nav_label')" data-test="settings-nav">
          <ul>
            <li v-for="s in SETTINGS_SECTIONS" :key="s.id">
              <NuxtLink
                :to="sectionTo(s.id)"
                replace
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': active === s.id }"
                :aria-current="active === s.id ? 'page' : undefined"
                :data-test="'settings-nav-' + s.id"
              >{{ t(s.label) }}<UiIcon v-if="stack.isMobile.value" name="chevron-left" :size="18" class="settings-nav__chev" /></NuxtLink>
            </li>
          </ul>
        </nav>
        <div class="settings-content" data-test="settings-content">
          <NuxtLink
            v-if="stack.isMobile.value && active"
            :to="sectionTo('')"
            replace
            class="settings-back"
            data-test="settings-back-list"
          ><UiIcon name="chevron-left" :size="18" class="settings-back__chev" />{{ t('settings.title') }}</NuxtLink>
          <component :is="SECTION_COMPONENTS[active]" v-if="active" />
        </div>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import type { Component } from 'vue'
import { useSessionStore } from '~/stores/session'
import { useMobileStack } from '~/composables/useMobileStack'
import {
  SETTINGS_QUERY,
  SETTINGS_SECTIONS,
  settingsCloseStep,
  settingsQuerySection,
  settingsShownSection,
  withoutSettings,
} from '~/utils/settings-nav.mjs'
import { fixedTenantOption, tenantSwitchOptions } from '~/utils/tenant-switcher.mjs'
/* CLE-77874: each section is its own async chunk. The dialog is mounted in
   app.vue on every page, so static imports put all seven sections (and their
   settings widgets) in the initial JS: ci_initial_gzip_kb went 151 -> 197 KB
   over the 160 KB budget (perf-budgets.json). As the old /settings route they
   were lazy; they load again only when the modal opens on a section. */
const SECTION_COMPONENTS: Record<string, Component> = {
  profile: defineAsyncComponent(() => import('~/components/settings/profile.vue')),
  language: defineAsyncComponent(() => import('~/components/settings/language.vue')),
  appearance: defineAsyncComponent(() => import('~/components/settings/appearance.vue')),
  behaviour: defineAsyncComponent(() => import('~/components/settings/behaviour.vue')),
  notifications: defineAsyncComponent(() => import('~/components/settings/notifications.vue')),
  security: defineAsyncComponent(() => import('~/components/settings/security.vue')),
  keys: defineAsyncComponent(() => import('~/components/settings/keys.vue')),
}

const session = useSessionStore()
const route = useRoute()
const router = useRouter()
const { t } = useI18n({ useScope: 'global' })
const stack = useMobileStack()
const signedIn = computed(() => session.state === 'in' && !!session.claims)
const section = computed(() => settingsQuerySection(route.query as Record<string, unknown>))
const open = computed(() => section.value !== null)
/* the section on screen; '' = the list (a phone only) */
const active = computed(() => settingsShownSection(section.value, stack.isMobile.value) || '')
/* CLE-35099: the settings are per tenant (rdb 0078). Name the tenant they
   apply to, but only for a person in more than one (canSwitch): for a single
   tenant it is noise. */
const perTenantNote = computed(() => {
  if (!signedIn.value) return ''
  if (!tenantSwitchOptions(session.claims).canSwitch) return ''
  const label = fixedTenantOption(session.claims).label
  return label ? t('settings.per_tenant_note', { tenant: label }) : ''
})
/* on a phone the open section names the sheet; the desktop keeps "Settings" */
const heading = computed(() => {
  const s = stack.isMobile.value && SETTINGS_SECTIONS.find((x) => x.id === active.value)
  return s ? t(s.label) : t('settings.title')
})

/** The same view with another section open (a replace: Back still closes). */
function sectionTo(id: string) {
  return { path: route.path, query: { ...route.query, [SETTINGS_QUERY]: id }, hash: route.hash }
}

/* the element that opened Settings: the user menu's entry is gone by the
   time the dialog opens, so fall back to the menu's own button */
let opener: HTMLElement | null = null
watch(open, (isOpen) => {
  if (!import.meta.client) return
  if (isOpen) {
    const el = document.activeElement as HTMLElement | null
    opener = el && el !== document.body && !el.closest('[data-test="user-menu-panel"]') ? el : null
    return
  }
  const back = opener
  opener = null
  void nextTick(() => {
    if (document.activeElement && document.activeElement !== document.body) return
    const target = back?.isConnected ? back : document.querySelector<HTMLElement>('[data-test="user-menu-trigger"]')
    target?.focus?.()
  })
}, { immediate: true, flush: 'sync' })

/** Close: back to the view without ?settings=, by Back when that view is the entry under us. */
function close() {
  const to = { path: route.path, query: withoutSettings(route.query), hash: route.hash }
  const viewFullPath = router.resolve(to).fullPath
  const historyBack = (window.history.state as { back?: unknown } | null)?.back
  if (settingsCloseStep(typeof historyBack === 'string' ? historyBack : null, viewFullPath) === 'back') router.back()
  else void router.replace(to)
}

function onOpen(next: boolean) {
  if (!next && open.value) close()
}
</script>

<style scoped>
.settings-page { padding: 16px 20px 24px; min-width: 0; }
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
/* the active nav item is a SELECTED item — a step DARKER than the
   hover fill, and its 3px edge is the one ring colour the whole WUI uses. */
.settings-nav__link--active {
  background: var(--color-selected);
  border-inline-start-color: var(--focus-ring);
  font-weight: 600;
}
/* CLE-35099: the per-tenant scope banner — a quiet, full-width line above the
   sections. */
.settings-tenant-note {
  margin: 0 0 12px;
  padding: 8px 12px;
  border-radius: var(--radius-sm, 8px);
  background: var(--color-bg-2);
  color: var(--color-muted);
  font-size: 0.9rem;
}
.settings-content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
.settings-back { display: none; }
/* SPL-993: phones and small tablets. The bare ?settings= is the list, full
   width, one 44 px row per section; an open section hides the list and gets
   a back row to it. */
@media (max-width: 820px) {
  .settings-page { padding: 12px; }
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
  .settings-back {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    align-self: flex-start;
    min-height: var(--tap, 44px);
    padding: 0 8px 0 0;
    border-radius: var(--radius-sm, 8px);
    color: var(--color-accent);
    text-decoration: none;
  }
  .settings-back__chev:dir(rtl) { transform: scaleX(-1); }
  .settings-content :deep(input),
  .settings-content :deep(textarea),
  .settings-content :deep(select) { font-size: max(16px, 1rem); }
}
</style>
