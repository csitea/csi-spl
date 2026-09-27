<!-- /settings (CLE-3402; GitHub-style since specs/023 §3.4) — the user
     dropdown's Settings entry. A left nav of sections, the selected section on
     the right; each section is its own child route (pages/settings/*.vue), so
     /settings/keys and /fi/settings/keys deep-link. /settings itself redirects
     to /settings/profile. A settled signed-out session never reaches this
     screen: the shared redirect replaces it with /login.
     SPL-993 (epic SPL-988): at <= 820 px /settings is the LIST of sections
     (the mobile stack's level 2) and a section opens full width on its own
     (level 3, registered with useMobileStack.rightPanel), so Back - the top
     bar's chevron, a right swipe or the browser - returns to the list. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <h2 id="settings-h">{{ heading }}</h2>
    </header>
    <div class="feed-body settings-page" data-test="settings">
      <p v-if="session.state === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <div v-else-if="signedIn" class="settings-layout" :class="{ 'settings-layout--list': !active }">
        <nav class="settings-nav" :aria-label="t('settings.nav_label')" data-test="settings-nav">
          <ul>
            <li v-for="s in SETTINGS_SECTIONS" :key="s.id">
              <NuxtLink
                :to="localePath('/settings/' + s.id)"
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': active === s.id }"
                :aria-current="active === s.id ? 'page' : undefined"
                :data-test="'settings-nav-' + s.id"
              >{{ t(s.label) }}<UiIcon v-if="stack.isMobile.value" name="chevron-left" :size="18" class="settings-nav__chev" /></NuxtLink>
            </li>
          </ul>
        </nav>
        <div class="settings-content" data-test="settings-content">
          <NuxtPage />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useMobileStack } from '~/composables/useMobileStack'
import { SETTINGS_SECTIONS, settingsSectionOf } from '~/utils/settings-nav.mjs'

const session = useSessionStore()
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const signedIn = computed(() => session.state === 'in' && !!session.claims)
const active = computed(() => settingsSectionOf(route.path))
const stack = useMobileStack()
/* on a phone the open section names the page; the desktop keeps "Settings" */
const heading = computed(() => {
  const s = stack.isMobile.value && SETTINGS_SECTIONS.find((x) => x.id === active.value)
  return s ? t(s.label) : t('settings.title')
})
/* a section open on a phone is level 3; Back from a deep link, which has
   no list entry below it in history, replaces the section with the list.
   It reads the ROUTER's route: that one has moved when router.afterEach
   tags the new history entry, the page's useRoute() only later - and a
   level that rises after the tag is pushed as an extra entry, so browser
   Back would stay on the section. */
const router = useRouter()
stack.rightPanel(
  () => stack.isMobile.value && settingsSectionOf(router.currentRoute.value.path) !== '',
  /* close runs inside a popstate whose (same-URL) navigation the router is
     still finishing, and that navigation swallows a replace started now:
     replace once it has finished (or after 250 ms when no popstate came) */
  () => {
    let done = false
    const go = () => {
      if (done) return
      done = true
      off()
      void navigateTo(localePath('/settings'), { replace: true })
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
